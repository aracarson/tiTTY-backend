use async_graphql::{InputObject, InputValueError, InputValueResult, Scalar, ScalarType, SimpleObject, Value};
use chrono::{DateTime, Utc};
use serde::{Deserialize, Serialize};
use uuid::Uuid;

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Base64Value(pub String);

#[Scalar(name = "Base64")]
impl ScalarType for Base64Value {
    fn parse(value: Value) -> InputValueResult<Self> {
        match value {
            Value::String(value) => Ok(Self(value)),
            value => Err(InputValueError::expected_type(value)),
        }
    }

    fn to_value(&self) -> Value {
        Value::String(self.0.clone())
    }
}

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

#[derive(Clone, Debug, SimpleObject)]
#[graphql(name = "BlockedIdentity")]
pub struct BlockedIdentity {
    #[graphql(name = "accountID")]
    pub account_id: String,
    #[graphql(name = "identiTTY")]
    pub identitty: String,
    #[graphql(name = "blockedAt")]
    pub blocked_at: DateTime<Utc>,
}

#[derive(Clone, Debug, SimpleObject)]
#[graphql(name = "LiveChatRequest")]
pub struct LiveChatRequest {
    #[graphql(name = "requestID")]
    pub request_id: Uuid,
    #[graphql(name = "senderAccountID")]
    pub sender_account_id: String,
    #[graphql(name = "senderIdentiTTY")]
    pub sender_identitty: String,
    #[graphql(name = "senderPublicKey")]
    pub sender_public_key: Base64Value,
    #[graphql(name = "encryptedPayload")]
    pub encrypted_payload: Base64Value,
    #[graphql(name = "createdAt")]
    pub created_at: DateTime<Utc>,
    #[graphql(name = "expiresAt")]
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, Debug, SimpleObject)]
#[graphql(name = "LiveChatRequestSubmission")]
pub struct LiveChatRequestSubmission {
    #[graphql(name = "requestID")]
    pub request_id: Uuid,
    pub accepted: bool,
    #[graphql(name = "leaseID")]
    pub lease_id: Uuid,
    #[graphql(name = "leaseExpiresAt")]
    pub lease_expires_at: DateTime<Utc>,
}

#[derive(Clone, Debug, SimpleObject)]
#[graphql(name = "LiveChatRequestLease")]
pub struct LiveChatRequestLease {
    #[graphql(name = "requestID")]
    pub request_id: Uuid,
    #[graphql(name = "leaseID")]
    pub lease_id: Uuid,
    #[graphql(name = "expiresAt")]
    pub expires_at: DateTime<Utc>,
}

#[derive(Clone, Debug, InputObject)]
#[graphql(name = "SendLiveChatRequestInput")]
pub struct SendLiveChatRequestInput {
    #[graphql(name = "recipientIdentiTTY")]
    pub recipient_identitty: String,
    #[graphql(name = "clientRequestID")]
    pub client_request_id: Uuid,
    #[graphql(name = "encryptedPayload")]
    pub encrypted_payload: Base64Value,
}

#[derive(Clone, Debug, InputObject)]
#[graphql(name = "RenewLiveChatRequestInput")]
pub struct RenewLiveChatRequestInput {
    #[graphql(name = "requestID")]
    pub request_id: Uuid,
    #[graphql(name = "leaseID")]
    pub lease_id: Uuid,
}

#[derive(Clone, Debug, InputObject)]
#[graphql(name = "CancelLiveChatRequestInput")]
pub struct CancelLiveChatRequestInput {
    #[graphql(name = "requestID")]
    pub request_id: Uuid,
    #[graphql(name = "leaseID")]
    pub lease_id: Uuid,
}

#[derive(Clone, Debug, InputObject)]
#[graphql(name = "BlockIdentityInput")]
pub struct BlockIdentityInput {
    #[graphql(name = "identiTTY")]
    pub identitty: String,
}

#[derive(Clone, Debug, InputObject)]
#[graphql(name = "UnblockIdentityInput")]
pub struct UnblockIdentityInput {
    #[graphql(name = "accountID")]
    pub account_id: String,
}

#[derive(Debug, Serialize, Deserialize)]
pub struct SessionClaims {
    pub sub: String,
    pub iss: String,
    pub iat: usize,
    pub exp: usize,
}
