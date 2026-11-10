//! The companion CA is stored inside the credential vault, never in config or logs.
use super::{AccountError, vault::Vault};
use base64::{Engine, engine::general_purpose::STANDARD};
use rcgen::{
    BasicConstraints, CertificateParams, DistinguishedName, DnType, IsCa, Issuer, KeyPair,
    KeyUsagePurpose,
};
use serde::{Deserialize, Serialize};
use std::{net::IpAddr, sync::Arc};
use time::OffsetDateTime;

#[derive(Clone, Serialize, Deserialize)]
pub(crate) struct Identity {
    pub certificate: String,
    private_key: String,
}

fn ca_params() -> CertificateParams {
    let mut params = CertificateParams::default();
    params.distinguished_name = DistinguishedName::new();
    params
        .distinguished_name
        .push(DnType::CommonName, "Quotio Companion");
    params.is_ca = IsCa::Ca(BasicConstraints::Constrained(0));
    params.key_usages = vec![KeyUsagePurpose::KeyCertSign, KeyUsagePurpose::CrlSign];
    params
}

pub(crate) async fn identity(vault: Vault) -> Result<Identity, AccountError> {
    let mut tx = super::service::begin(vault).await?;
    if let Some(identity) = &tx.document.companion_identity {
        return Ok(identity.clone());
    }
    let key = KeyPair::generate().map_err(|_| AccountError::Storage)?;
    let mut params = ca_params();
    params.not_before = OffsetDateTime::now_utc() - time::Duration::days(1);
    params.not_after = OffsetDateTime::now_utc() + time::Duration::days(3650);
    let certificate = params
        .self_signed(&key)
        .map_err(|_| AccountError::Storage)?;
    let identity = Identity {
        certificate: STANDARD.encode(certificate.der()),
        private_key: key.serialize_pem(),
    };
    tx.document.companion_identity = Some(identity.clone());
    tx.commit()?;
    Ok(identity)
}

impl Identity {
    pub fn tls(&self, ip: IpAddr) -> Result<axum_server::tls_rustls::RustlsConfig, AccountError> {
        let create = || -> Result<_, Box<dyn std::error::Error>> {
            let issuer = Issuer::new(ca_params(), KeyPair::from_pem(&self.private_key)?);
            let key = KeyPair::generate()?;
            let mut params = CertificateParams::new(vec![ip.to_string()])?;
            params.distinguished_name = DistinguishedName::new();
            params
                .distinguished_name
                .push(DnType::CommonName, "Quotio Companion Server");
            params.use_authority_key_identifier_extension = true;
            params.not_before = OffsetDateTime::now_utc() - time::Duration::days(1);
            params.not_after = OffsetDateTime::now_utc() + time::Duration::days(90);
            params.key_usages = vec![KeyUsagePurpose::DigitalSignature];
            params.extended_key_usages = vec![rcgen::ExtendedKeyUsagePurpose::ServerAuth];
            let certificate = params.signed_by(&key, &issuer)?;
            let mut config = rustls::ServerConfig::builder_with_provider(Arc::new(
                rustls::crypto::ring::default_provider(),
            ))
            .with_safe_default_protocol_versions()?
            .with_no_client_auth()
            .with_single_cert(
                vec![certificate.der().clone()],
                rustls::pki_types::PrivatePkcs8KeyDer::from(key.serialize_der()).into(),
            )?;
            config.alpn_protocols = vec![b"http/1.1".to_vec()];
            Ok(axum_server::tls_rustls::RustlsConfig::from_config(
                Arc::new(config),
            ))
        };
        create().map_err(|_| AccountError::Storage)
    }
}
