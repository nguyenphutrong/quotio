pub mod generated;

pub fn supports_contract_version(version: u16) -> bool {
    version == generated::CONTRACT_VERSION
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn accepts_current_contract_version() {
        assert!(supports_contract_version(generated::CONTRACT_VERSION));
    }

    #[test]
    fn rejects_breaking_contract_version() {
        assert!(!supports_contract_version(generated::CONTRACT_VERSION + 1));
    }
}
