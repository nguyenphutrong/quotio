use std::path::PathBuf;
use std::process::{Child, Command, Stdio};
use std::time::{Duration, Instant};

use quotio_contract::generated::RuntimeStatus;

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RuntimeOwnership {
    Managed,
    External,
    Stopped,
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeSnapshot {
    pub ownership: RuntimeOwnership,
    pub status: RuntimeStatus,
}

impl RuntimeSnapshot {
    pub fn stopped() -> Self {
        Self {
            ownership: RuntimeOwnership::Stopped,
            status: RuntimeStatus {
                state: "stopped".to_string(),
                endpoint: None,
            },
        }
    }

    pub fn managed(endpoint: String) -> Self {
        Self {
            ownership: RuntimeOwnership::Managed,
            status: RuntimeStatus {
                state: "managed".to_string(),
                endpoint: Some(endpoint),
            },
        }
    }

    pub fn external(endpoint: String) -> Self {
        Self {
            ownership: RuntimeOwnership::External,
            status: RuntimeStatus {
                state: "external".to_string(),
                endpoint: Some(endpoint),
            },
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct RuntimeConfig {
    pub binary_path: PathBuf,
    pub args: Vec<String>,
    pub endpoint: String,
    pub startup_timeout: Duration,
    pub max_crash_restarts: u8,
}

impl RuntimeConfig {
    pub fn new(binary_path: impl Into<PathBuf>, endpoint: impl Into<String>) -> Self {
        Self {
            binary_path: binary_path.into(),
            args: Vec::new(),
            endpoint: endpoint.into(),
            startup_timeout: Duration::from_secs(5),
            max_crash_restarts: 3,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub enum RuntimeEvent {
    Started(RuntimeSnapshot),
    Stopped(RuntimeSnapshot),
    Crashed { code: Option<i32> },
    RestartLimitReached,
}

pub struct ManagedRuntime {
    config: RuntimeConfig,
    child: Option<Child>,
    crash_restarts: u8,
}

impl ManagedRuntime {
    pub fn new(config: RuntimeConfig) -> Self {
        Self {
            config,
            child: None,
            crash_restarts: 0,
        }
    }

    pub fn status(&mut self, external_available: bool) -> RuntimeSnapshot {
        if self.child_is_running() {
            return RuntimeSnapshot::managed(self.config.endpoint.clone());
        }

        self.child = None;

        if external_available {
            return RuntimeSnapshot::external(self.config.endpoint.clone());
        }

        RuntimeSnapshot::stopped()
    }

    pub fn start(&mut self) -> Result<RuntimeSnapshot, String> {
        if self.child_is_running() {
            return Ok(RuntimeSnapshot::managed(self.config.endpoint.clone()));
        }

        let mut command = Command::new(&self.config.binary_path);
        command
            .args(&self.config.args)
            .stdin(Stdio::null())
            .stdout(Stdio::null())
            .stderr(Stdio::null());

        let child = command.spawn().map_err(|error| {
            format!(
                "failed to start {}: {error}",
                self.config.binary_path.display()
            )
        })?;

        self.child = Some(child);
        self.crash_restarts = 0;
        self.wait_for_startup();

        Ok(RuntimeSnapshot::managed(self.config.endpoint.clone()))
    }

    pub fn stop(&mut self) -> Result<RuntimeSnapshot, String> {
        let Some(mut child) = self.child.take() else {
            return Ok(RuntimeSnapshot::stopped());
        };

        if child
            .try_wait()
            .map_err(|error| error.to_string())?
            .is_none()
        {
            child.kill().map_err(|error| error.to_string())?;
        }
        child.wait().map_err(|error| error.to_string())?;

        Ok(RuntimeSnapshot::stopped())
    }

    pub fn restart(&mut self) -> Result<RuntimeSnapshot, String> {
        self.stop()?;
        self.start()
    }

    pub fn observe_exit(&mut self) -> Option<RuntimeEvent> {
        let child = self.child.as_mut()?;
        let status = child.try_wait().ok()??;
        self.child = None;

        Some(RuntimeEvent::Crashed {
            code: status.code(),
        })
    }

    pub fn restart_after_crash(&mut self) -> Result<RuntimeSnapshot, RuntimeEvent> {
        if self.crash_restarts >= self.config.max_crash_restarts {
            return Err(RuntimeEvent::RestartLimitReached);
        }

        self.crash_restarts += 1;
        self.start().map_err(|_| RuntimeEvent::RestartLimitReached)
    }

    fn child_is_running(&mut self) -> bool {
        let Some(child) = self.child.as_mut() else {
            return false;
        };

        matches!(child.try_wait(), Ok(None))
    }

    fn wait_for_startup(&mut self) {
        let deadline = Instant::now() + self.config.startup_timeout;
        while Instant::now() < deadline {
            if self.child_is_running() {
                return;
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use std::time::Duration;

    use super::*;

    #[test]
    fn stopped_snapshot_has_no_endpoint() {
        let snapshot = RuntimeSnapshot::stopped();

        assert_eq!(snapshot.ownership, RuntimeOwnership::Stopped);
        assert_eq!(snapshot.status.state, "stopped");
        assert_eq!(snapshot.status.endpoint, None);
    }

    #[test]
    fn external_status_does_not_create_managed_process() {
        let mut runtime = ManagedRuntime::new(test_config());

        let snapshot = runtime.status(true);

        assert_eq!(snapshot.ownership, RuntimeOwnership::External);
        assert_eq!(snapshot.status.endpoint.as_deref(), Some(test_endpoint()));
    }

    #[test]
    fn stop_without_child_does_not_touch_external_processes() {
        let mut runtime = ManagedRuntime::new(test_config());

        let snapshot = runtime.stop().expect("stop should be idempotent");

        assert_eq!(snapshot, RuntimeSnapshot::stopped());
    }

    #[test]
    fn starts_and_stops_managed_process() {
        let mut runtime = ManagedRuntime::new(test_sleep_config());

        let started = runtime.start().expect("process should start");
        assert_eq!(started.ownership, RuntimeOwnership::Managed);
        assert_eq!(runtime.status(false).ownership, RuntimeOwnership::Managed);

        let stopped = runtime.stop().expect("process should stop");
        assert_eq!(stopped, RuntimeSnapshot::stopped());
    }

    #[test]
    fn detects_crashed_child() {
        let mut config = test_command_config("true");
        config.startup_timeout = Duration::from_millis(1);
        let mut runtime = ManagedRuntime::new(config);

        runtime.start().expect("process should start");
        std::thread::sleep(Duration::from_millis(20));

        let event = runtime.observe_exit();
        assert!(matches!(
            event,
            Some(RuntimeEvent::Crashed { code: Some(0) })
        ));
    }

    fn test_config() -> RuntimeConfig {
        RuntimeConfig::new(test_binary(), test_endpoint())
    }

    fn test_sleep_config() -> RuntimeConfig {
        test_command_config("sleep 2")
    }

    fn test_command_config(command: &str) -> RuntimeConfig {
        let mut config = RuntimeConfig::new(test_binary(), test_endpoint());
        config.args = test_args(command);
        config.startup_timeout = Duration::from_millis(1);
        config
    }

    fn test_binary() -> &'static str {
        if cfg!(windows) { "cmd" } else { "/bin/sh" }
    }

    fn test_args(command: &str) -> Vec<String> {
        if cfg!(windows) {
            vec!["/C".to_string(), command.to_string()]
        } else {
            vec!["-c".to_string(), command.to_string()]
        }
    }

    fn test_endpoint() -> &'static str {
        "http://127.0.0.1:8386"
    }
}
