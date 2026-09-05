use async_graphql::{InputObject, SimpleObject};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

// MARK: - Task list
// [x] Keep GraphQL transport models explicit and small

#[derive(Clone, Debug, SimpleObject)]
#[graphql(name = "AccountIdentity")]
pub struct AccountIdentity {
    #[graphql(name = "accountID")]
    pub account_id: String,
    #[graphql(name = "identiTTY")]
    pub identitty: String,
    #[graphql(name = "publicKey")]
    pub public_key: String,
    #[graphql(name = "createdAt")]
    pub created_at: DateTime<Utc>,
}

#[derive(Clone, Debug, InputObject)]
#[graphql(name = "RegisterAccountInput")]
pub struct RegisterAccountInput {
    #[graphql(name = "identiTTY")]
    pub identitty: String,
    #[graphql(name = "accountID")]
    pub account_id: String,
    #[graphql(name = "publicKey")]
    pub public_key: String,
}

#[derive(Clone, Debug, SimpleObject)]
#[graphql(name = "AuthenticationChallenge")]
pub struct AuthenticationChallenge {
    #[graphql(name = "challengeID")]
    pub challenge_id: Uuid,
    pub challenge: String,
    #[graphql(name = "expiresAt")]
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, Debug, InputObject)]
#[graphql(name = "AuthenticateInput")]
pub struct AuthenticateInput {
    #[graphql(name = "accountID")]
    pub account_id: String,
    #[graphql(name = "challengeID")]
    pub challenge_id: Uuid,
    pub signature: String,
}

#[derive(Clone, Debug, SimpleObject)]
#[graphql(name = "AuthenticationSession")]
pub struct AuthenticationSession {
    pub token: String,
    #[graphql(name = "expiresAt")]
    pub expires_at: DateTime<Utc>,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SessionClaims {
    pub sub: String,
    pub iss: String,
    pub iat: usize,
    pub exp: usize,
}
