use async_graphql::{Error, ErrorExtensions};
use thiserror::Error;

// MARK: - Task list
// [x] Return stable GraphQL error codes without leaking internals

#[derive(Debug, Error)]
pub enum ApiError {
    #[error("The identiTTY is invalid")]
    InvalidIdentitty,
    #[error("The identiTTY is already taken")]
    IdentittyTaken,
    #[error("The account registration is invalid")]
    InvalidRegistration,
    #[error("The account was not found")]
    AccountNotFound,
    #[error("The authentication challenge is invalid or expired")]
    InvalidChallenge,
    #[error("Authentication failed")]
    AuthenticationFailed,
    #[error("An internal service error occurred")]
    Internal,
}

impl ErrorExtensions for ApiError {
    fn extend(&self) -> Error {
        let code = match self {
            Self::InvalidIdentitty => "INVALID_IDENTITTY",
            Self::IdentittyTaken => "IDENTITTY_TAKEN",
            Self::InvalidRegistration => "INVALID_REGISTRATION",
            Self::AccountNotFound => "ACCOUNT_NOT_FOUND",
            Self::InvalidChallenge => "INVALID_CHALLENGE",
            Self::AuthenticationFailed => "AUTHENTICATION_FAILED",
            Self::Internal => "INTERNAL_ERROR",
        };
        Error::new(self.to_string()).extend_with(|_, extensions| {
            extensions.set("code", code);
        })
    }
}
