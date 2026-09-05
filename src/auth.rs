use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{Duration, Utc};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use jsonwebtoken::{encode, EncodingKey, Header};

use crate::{config::Config, error::ApiError, models::{AuthenticationSession, SessionClaims}};

// MARK: - Task list
// [x] Verify Ed25519 signatures over raw challenge bytes
// [x] Issue short-lived server sessions

pub fn verify_signature(
    public_key: &[u8],
    challenge: &[u8],
    signature_base64: &str,
) -> Result<(), ApiError> {
    let key_bytes: [u8; 32] = public_key.try_into()
        .map_err(|_| ApiError::AuthenticationFailed)?;
    let key = VerifyingKey::from_bytes(&key_bytes)
        .map_err(|_| ApiError::AuthenticationFailed)?;
    let signature_bytes = STANDARD.decode(signature_base64)
        .map_err(|_| ApiError::AuthenticationFailed)?;
    let signature = Signature::from_slice(&signature_bytes)
        .map_err(|_| ApiError::AuthenticationFailed)?;

    key.verify(challenge, &signature)
        .map_err(|_| ApiError::AuthenticationFailed)
}

pub fn issue_session(
    account_id: &str,
    config: &Config,
) -> Result<AuthenticationSession, ApiError> {
    let now = Utc::now();
    let expires_at = now + Duration::seconds(config.session_ttl_seconds);
    let claims = SessionClaims {
        sub: account_id.to_owned(),
        iss: config.jwt_issuer.clone(),
        iat: now.timestamp() as usize,
        exp: expires_at.timestamp() as usize,
    };
    let token = encode(
        &Header::default(),
        &claims,
        &EncodingKey::from_secret(config.jwt_secret.as_bytes()),
    ).map_err(|_| ApiError::Internal)?;

    Ok(AuthenticationSession { token, expires_at })
}
