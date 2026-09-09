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
    #[error("Authentication is required")]
    Unauthorized,
    #[error("Too many requests")]
    RateLimited,
    #[error("The encrypted payload is invalid or too large")]
    InvalidPayload,
    #[error("The request limit has been reached")]
    ActiveRequestLimit,
    #[error("The chat request is invalid or expired")]
    InvalidChatRequest,
    #[error("The account cannot block itself")]
    SelfBlock,
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
            Self::Unauthorized => "UNAUTHORIZED",
            Self::RateLimited => "RATE_LIMITED",
            Self::InvalidPayload => "INVALID_PAYLOAD",
            Self::ActiveRequestLimit => "ACTIVE_REQUEST_LIMIT",
            Self::InvalidChatRequest => "INVALID_CHAT_REQUEST",
            Self::SelfBlock => "SELF_BLOCK",
            Self::Internal => "INTERNAL_ERROR",
        };
        Error::new(self.to_string()).extend_with(|_, extensions| {
            extensions.set("code", code);
        })
    }
}
