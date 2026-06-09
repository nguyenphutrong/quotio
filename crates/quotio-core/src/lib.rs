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
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn stopped_snapshot_has_no_endpoint() {
        let snapshot = RuntimeSnapshot::stopped();

        assert_eq!(snapshot.ownership, RuntimeOwnership::Stopped);
        assert_eq!(snapshot.status.state, "stopped");
        assert_eq!(snapshot.status.endpoint, None);
    }
}
