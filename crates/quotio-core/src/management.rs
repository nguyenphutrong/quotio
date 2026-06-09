use std::io::{Read, Write};
use std::net::TcpStream;
use std::time::Duration;

use quotio_contract::generated::ManagementResponse;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ManagementConnection {
    Local {
        endpoint: String,
        management_key: String,
    },
    Remote {
        endpoint: String,
        management_key: String,
    },
}

impl ManagementConnection {
    fn endpoint(&self) -> &str {
        match self {
            Self::Local { endpoint, .. } | Self::Remote { endpoint, .. } => endpoint,
        }
    }

    fn management_key(&self) -> &str {
        match self {
            Self::Local { management_key, .. } | Self::Remote { management_key, .. } => {
                management_key
            }
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct ManagementRequest {
    pub method: String,
    pub path: String,
    pub body: Option<String>,
}

impl ManagementRequest {
    pub fn get(path: impl Into<String>) -> Self {
        Self {
            method: "GET".to_string(),
            path: path.into(),
            body: None,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum ManagementError {
    InvalidUrl,
    Unavailable(String),
    Unauthorized,
    Unsupported(u16),
    InvalidData(String),
}

pub struct ManagementClient {
    connection: ManagementConnection,
    timeout: Duration,
}

impl ManagementClient {
    pub fn new(connection: ManagementConnection) -> Self {
        Self {
            connection,
            timeout: Duration::from_secs(5),
        }
    }

    pub fn with_timeout(mut self, timeout: Duration) -> Self {
        self.timeout = timeout;
        self
    }

    pub fn request(
        &self,
        request: ManagementRequest,
    ) -> Result<ManagementResponse, ManagementError> {
        let target = HttpTarget::parse(self.connection.endpoint(), &request.path)?;
        let mut stream = TcpStream::connect((&target.host[..], target.port))
            .map_err(|error| ManagementError::Unavailable(error.to_string()))?;
        stream
            .set_read_timeout(Some(self.timeout))
            .map_err(|error| ManagementError::Unavailable(error.to_string()))?;
        stream
            .set_write_timeout(Some(self.timeout))
            .map_err(|error| ManagementError::Unavailable(error.to_string()))?;

        let body = request.body.unwrap_or_default();
        let raw_request = format!(
            "{method} {path} HTTP/1.1\r\nHost: {host}\r\nAccept: application/json\r\nAuthorization: Bearer {key}\r\nConnection: close\r\nContent-Length: {length}\r\n\r\n{body}",
            method = request.method,
            path = target.path,
            host = target.authority,
            key = self.connection.management_key(),
            length = body.len(),
        );
        stream
            .write_all(raw_request.as_bytes())
            .map_err(|error| ManagementError::Unavailable(error.to_string()))?;

        let mut response = String::new();
        stream
            .read_to_string(&mut response)
            .map_err(|error| ManagementError::Unavailable(error.to_string()))?;
        parse_response(&response)
    }
}

struct HttpTarget {
    host: String,
    authority: String,
    port: u16,
    path: String,
}

impl HttpTarget {
    fn parse(endpoint: &str, path: &str) -> Result<Self, ManagementError> {
        let without_scheme = endpoint
            .strip_prefix("http://")
            .ok_or(ManagementError::InvalidUrl)?;
        let (authority, base_path) = without_scheme
            .split_once('/')
            .map_or((without_scheme, ""), |(authority, base_path)| {
                (authority, base_path)
            });
        let (host, port) = authority
            .rsplit_once(':')
            .and_then(|(host, port)| Some((host.to_string(), port.parse::<u16>().ok()?)))
            .ok_or(ManagementError::InvalidUrl)?;
        let normalized_path = if path.starts_with('/') {
            path.to_string()
        } else {
            format!("/{path}")
        };
        let full_path = if base_path.is_empty() {
            normalized_path
        } else {
            format!("/{base_path}{normalized_path}")
        };

        Ok(Self {
            host,
            authority: authority.to_string(),
            port,
            path: full_path,
        })
    }
}

fn parse_response(response: &str) -> Result<ManagementResponse, ManagementError> {
    let (head, body) = response
        .split_once("\r\n\r\n")
        .ok_or_else(|| ManagementError::InvalidData("missing response body separator".into()))?;
    let status = head
        .lines()
        .next()
        .and_then(|line| line.split_whitespace().nth(1))
        .and_then(|status| status.parse::<u16>().ok())
        .ok_or_else(|| ManagementError::InvalidData("missing HTTP status".into()))?;

    match status {
        200..=299 => Ok(ManagementResponse {
            status,
            body: if body.is_empty() {
                None
            } else {
                Some(body.to_string())
            },
        }),
        401 | 403 => Err(ManagementError::Unauthorized),
        404 | 426 => Err(ManagementError::Unsupported(status)),
        _ => Err(ManagementError::Unavailable(format!(
            "management request failed with {status}"
        ))),
    }
}

#[cfg(test)]
mod tests {
    use std::io::{Read, Write};
    use std::net::TcpListener;
    use std::thread;
    use std::time::Duration;

    use super::*;

    #[test]
    fn sends_management_auth_and_connection_close() {
        let server =
            TestServer::reply("HTTP/1.1 200 OK\r\nContent-Length: 11\r\n\r\n{\"ok\":true}");
        let client = ManagementClient::new(ManagementConnection::Local {
            endpoint: server.endpoint(),
            management_key: "test-key".to_string(),
        })
        .with_timeout(Duration::from_secs(2));

        let response = client
            .request(ManagementRequest::get("/v0/management/debug"))
            .expect("request should succeed");
        let request = server.join();

        assert_eq!(response.status, 200);
        assert_eq!(response.body.as_deref(), Some("{\"ok\":true}"));
        assert!(request.contains("Authorization: Bearer test-key"));
        assert!(request.contains("Connection: close"));
    }

    #[test]
    fn normalizes_unauthorized() {
        let server = TestServer::reply("HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
        let client = ManagementClient::new(ManagementConnection::Remote {
            endpoint: server.endpoint(),
            management_key: "bad-key".to_string(),
        });

        let error = client
            .request(ManagementRequest::get("/v0/management/debug"))
            .expect_err("401 should normalize");

        assert_eq!(error, ManagementError::Unauthorized);
        let _ = server.join();
    }

    #[test]
    fn rejects_unsupported_api() {
        let server =
            TestServer::reply("HTTP/1.1 426 Upgrade Required\r\nContent-Length: 0\r\n\r\n");
        let client = ManagementClient::new(ManagementConnection::Local {
            endpoint: server.endpoint(),
            management_key: "test-key".to_string(),
        });

        let error = client
            .request(ManagementRequest::get("/v0/management/future"))
            .expect_err("426 should normalize");

        assert_eq!(error, ManagementError::Unsupported(426));
        let _ = server.join();
    }

    struct TestServer {
        endpoint: String,
        handle: thread::JoinHandle<String>,
    }

    impl TestServer {
        fn reply(response: &'static str) -> Self {
            let listener = TcpListener::bind("127.0.0.1:0").expect("bind test server");
            let endpoint = format!("http://{}", listener.local_addr().expect("local addr"));
            let handle = thread::spawn(move || {
                let (mut stream, _) = listener.accept().expect("accept request");
                let mut buffer = [0; 4096];
                let size = stream.read(&mut buffer).expect("read request");
                stream
                    .write_all(response.as_bytes())
                    .expect("write response");
                String::from_utf8_lossy(&buffer[..size]).to_string()
            });

            Self { endpoint, handle }
        }

        fn endpoint(&self) -> String {
            self.endpoint.clone()
        }

        fn join(self) -> String {
            self.handle.join().expect("server thread")
        }
    }
}
