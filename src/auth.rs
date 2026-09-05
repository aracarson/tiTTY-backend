use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{Duration, Utc};
use ed25519_dalek::{Signature, Verifier, VerifyingKey};
use jsonwebtoken::{decode, encode, Algorithm, DecodingKey, EncodingKey, Header, Validation};

use crate::{
    config::Config,
    error::ApiError,
    models::{AuthenticationSession, SessionClaims},
};

// MARK: - Task list
// [x] Verify Ed25519 signatures over raw challenge bytes
// [x] Issue short-lived server sessions

pub fn verify_signature(
    public_key: &[u8],
    challenge: &[u8],
    signature_base64: &str,
) -> Result<(), ApiError> {
    let key_bytes: [u8; 32] = public_key
        .try_into()
        .map_err(|_| ApiError::AuthenticationFailed)?;
    let key = VerifyingKey::from_bytes(&key_bytes).map_err(|_| ApiError::AuthenticationFailed)?;
    let signature_bytes = STANDARD
        .decode(signature_base64)
        .map_err(|_| ApiError::AuthenticationFailed)?;
    let signature =
        Signature::from_slice(&signature_bytes).map_err(|_| ApiError::AuthenticationFailed)?;

    key.verify(challenge, &signature)
        .map_err(|_| ApiError::AuthenticationFailed)
}

pub fn issue_session(account_id: &str, config: &Config) -> Result<AuthenticationSession, ApiError> {
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
    )
    .map_err(|_| ApiError::Internal)?;

    Ok(AuthenticationSession { token, expires_at })
}

#[derive(Clone, Debug)]
pub struct AuthenticatedAccount {
    pub account_id: String,
}

pub fn authenticate_bearer(
    authorization: Option<&str>,
    config: &Config,
) -> Result<Option<AuthenticatedAccount>, ApiError> {
    let Some(authorization) = authorization else {
        return Ok(None);
    };

    let token = authorization
        .strip_prefix("Bearer ")
        .filter(|token| !token.is_empty())
        .ok_or(ApiError::Unauthorized)?;

    let mut validation = Validation::new(Algorithm::HS256);
    validation.set_issuer(std::slice::from_ref(&config.jwt_issuer));
    let token = decode::<SessionClaims>(
        token,
        &DecodingKey::from_secret(config.jwt_secret.as_bytes()),
        &validation,
    )
    .map_err(|_| ApiError::Unauthorized)?;

    Ok(Some(AuthenticatedAccount {
        account_id: token.claims.sub,
    }))
}

#[cfg(test)]
mod tests {
    use super::{authenticate_bearer, issue_session};
    use crate::config::Config;

    fn config() -> Config {
        Config {
            bind_address: "127.0.0.1:8080".into(),
            database_url: ":memory:".into(),
            jwt_secret: "a".repeat(32),
            jwt_issuer: "test".into(),
            session_ttl_seconds: 3600,
            challenge_ttl_seconds: 180,
            max_body_bytes: 65_536,
            allowed_origin: "https://example.com".into(),
        }
    }

    #[test]
    fn issued_session_can_be_validated() {
        let config = config();
        let session = issue_session("acct_test", &config).expect("session");
        let authenticated =
            authenticate_bearer(Some(&format!("Bearer {}", session.token)), &config)
                .expect("valid token")
                .expect("authenticated account");

        assert_eq!(authenticated.account_id, "acct_test");
    }

    #[test]
    fn malformed_bearer_token_is_rejected() {
        assert!(authenticate_bearer(Some("Bearer invalid"), &config()).is_err());
    }
}
