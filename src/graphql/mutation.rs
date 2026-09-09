use std::sync::Arc;

use async_graphql::{Context, Object, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{Duration, Utc};
use rand::RngCore;
use sqlx::{FromRow, SqlitePool};
use uuid::Uuid;

use crate::{
    account_id, auth,
    config::Config,
    error::ApiError,
    models::{
        AccountIdentity, AuthenticateInput, AuthenticationChallenge, AuthenticationSession,
        BlockIdentityInput, BlockedIdentity, CancelLiveChatRequestInput,
        LiveChatRequestLease, LiveChatRequestSubmission, RegisterAccountInput,
        RenewLiveChatRequestInput, SendLiveChatRequestInput, UnblockIdentityInput,
    },
    rate_limit,
    validation::normalise_identitty,
};

// MARK: - Task list
// [x] Register public identity atomically
// [x] Generate random, short-lived challenges
// [x] Consume a challenge before returning a session

pub struct MutationRoot;

#[Object]
impl MutationRoot {
    #[graphql(name = "registerAccount")]
    async fn register_account(
        &self,
        ctx: &Context<'_>,
        input: RegisterAccountInput,
    ) -> Result<AccountIdentity> {
        rate_limit::enforce(ctx, "register", 5, std::time::Duration::from_secs(60))?;
        let pool = ctx.data::<SqlitePool>()?;
        let identitty =
            normalise_identitty(&input.identitty).map_err(async_graphql::Error::from)?;
        let public_key = STANDARD
            .decode(&input.public_key)
            .map_err(|_| ApiError::InvalidRegistration)?;

        if public_key.len() != 32 {
            return Err(ApiError::InvalidRegistration.into());
        }

        let expected_account_id = account_id::from_public_key(&public_key);
        if expected_account_id != input.account_id {
            return Err(ApiError::InvalidRegistration.into());
        }

        let created_at = Utc::now();
        let result = sqlx::query(
            "INSERT INTO accounts (account_id, identitty, public_key, created_at) VALUES (?, ?, ?, ?)",
        )
        .bind(&input.account_id)
        .bind(&identitty)
        .bind(&public_key)
        .bind(created_at.to_rfc3339())
        .execute(pool)
        .await;

        match result {
            Ok(_) => Ok(AccountIdentity {
                account_id: input.account_id,
                identitty,
                public_key: STANDARD.encode(public_key),
                created_at,
            }),
            Err(error) if is_unique_violation(&error) => Err(ApiError::IdentittyTaken.into()),
            Err(_) => Err(ApiError::Internal.into()),
        }
    }

    #[graphql(name = "requestChallenge")]
    async fn request_challenge(
        &self,
        ctx: &Context<'_>,
        #[graphql(name = "accountID")] account_id: String,
    ) -> Result<AuthenticationChallenge> {
        rate_limit::enforce(ctx, "challenge", 10, std::time::Duration::from_secs(60))?;
        let pool = ctx.data::<SqlitePool>()?;
        let config = ctx.data::<Arc<Config>>()?;

        let exists: i64 =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM accounts WHERE account_id = ?)")
                .bind(&account_id)
                .fetch_one(pool)
                .await
                .map_err(|_| ApiError::Internal)?;

        if exists == 0 {
            return Err(ApiError::AccountNotFound.into());
        }

        let challenge_id = Uuid::new_v4();
        let mut challenge = [0_u8; 32];
        rand::rngs::OsRng.fill_bytes(&mut challenge);
        let expires_at = Utc::now() + Duration::seconds(config.challenge_ttl_seconds);

        sqlx::query(
            "INSERT INTO authentication_challenges (challenge_id, account_id, challenge, expires_at) VALUES (?, ?, ?, ?)",
        )
        .bind(challenge_id.to_string())
        .bind(&account_id)
        .bind(challenge.as_slice())
        .bind(expires_at.to_rfc3339())
        .execute(pool)
        .await
        .map_err(|_| ApiError::Internal)?;

        Ok(AuthenticationChallenge {
            challenge_id,
            challenge: STANDARD.encode(challenge),
            expires_at,
        })
    }

    async fn authenticate(
        &self,
        ctx: &Context<'_>,
        input: AuthenticateInput,
    ) -> Result<AuthenticationSession> {
        rate_limit::enforce(ctx, "authenticate", 10, std::time::Duration::from_secs(60))?;
        let pool = ctx.data::<SqlitePool>()?;
        let config = ctx.data::<Arc<Config>>()?;
        let mut transaction = pool.begin().await.map_err(|_| ApiError::Internal)?;

        let row = sqlx::query_as::<_, ChallengeRow>(
            "SELECT c.challenge, c.expires_at, a.public_key              FROM authentication_challenges c              JOIN accounts a ON a.account_id = c.account_id              WHERE c.challenge_id = ? AND c.account_id = ? AND c.used_at IS NULL",
        )
        .bind(input.challenge_id.to_string())
        .bind(&input.account_id)
        .fetch_optional(&mut *transaction)
        .await
        .map_err(|_| ApiError::Internal)?
        .ok_or(ApiError::InvalidChallenge)?;

        let expires_at = chrono::DateTime::parse_from_rfc3339(&row.expires_at)
            .map_err(|_| ApiError::InvalidChallenge)?
            .with_timezone(&Utc);
        if expires_at <= Utc::now() {
            return Err(ApiError::InvalidChallenge.into());
        }

        auth::verify_signature(&row.public_key, &row.challenge, &input.signature)?;

        let updated = sqlx::query(
            "UPDATE authentication_challenges SET used_at = ? WHERE challenge_id = ? AND used_at IS NULL",
        )
        .bind(Utc::now().to_rfc3339())
        .bind(input.challenge_id.to_string())
        .execute(&mut *transaction)
        .await
        .map_err(|_| ApiError::Internal)?;

        if updated.rows_affected() != 1 {
            return Err(ApiError::InvalidChallenge.into());
        }

        transaction.commit().await.map_err(|_| ApiError::Internal)?;
        auth::issue_session(&input.account_id, config).map_err(async_graphql::Error::from)
    }

    #[graphql(name = "sendLiveChatRequest")]
    async fn send_live_chat_request(
        &self,
        ctx: &Context<'_>,
        input: SendLiveChatRequestInput,
    ) -> Result<LiveChatRequestSubmission> {
        let sender = authenticated(ctx)?;
        let pool = ctx.data::<SqlitePool>()?;
        let payload = decode_payload(&input.encrypted_payload.0)?;
        let recipient_identitty =
            normalise_identitty(&input.recipient_identitty).map_err(async_graphql::Error::from)?;
        crate::db::remove_expired_live_chat_requests(pool)
            .await
            .map_err(|_| ApiError::Internal)?;

        let sender_row = sqlx::query_as::<_, IdentityRow>(
            "SELECT public_key FROM accounts WHERE account_id = ?",
        )
        .bind(&sender.account_id)
        .fetch_optional(pool)
        .await
        .map_err(|_| ApiError::Internal)?
        .ok_or(ApiError::Unauthorized)?;

        if let Some(existing) = sqlx::query_as::<_, ExistingRequestRow>(
            "SELECT request_id, lease_id, lease_expires_at FROM live_chat_requests
             WHERE sender_account_id = ? AND client_request_id = ?",
        )
        .bind(&sender.account_id)
        .bind(input.client_request_id.to_string())
        .fetch_optional(pool)
        .await
        .map_err(|_| ApiError::Internal)?
        {
            return existing.into_submission();
        }

        let active: i64 = sqlx::query_scalar(
            "SELECT COUNT(*) FROM live_chat_requests WHERE sender_account_id = ?
             AND julianday(lease_expires_at) > julianday('now')
             AND julianday(hard_expires_at) > julianday('now')",
        )
        .bind(&sender.account_id)
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::Internal)?;
        if active >= 25 {
            return Err(ApiError::ActiveRequestLimit.into());
        }

        let now = Utc::now();
        let lease_expires_at = now + Duration::seconds(90);
        let hard_expires_at = now + Duration::minutes(15);
        let request_id = Uuid::new_v4();
        let lease_id = Uuid::new_v4();
        let recipient = sqlx::query_as::<_, RecipientRow>(
            "SELECT account_id FROM accounts WHERE identitty = ?",
        )
        .bind(&recipient_identitty)
        .fetch_optional(pool)
        .await
        .map_err(|_| ApiError::Internal)?;

        // Deliberately return the same successful shape for unknown, blocked, and unavailable recipients.
        if let Some(recipient) = recipient {
            let blocked: i64 = sqlx::query_scalar(
                "SELECT EXISTS(SELECT 1 FROM blocked_accounts
                 WHERE blocker_account_id = ? AND blocked_account_id = ?)",
            )
            .bind(&recipient.account_id)
            .bind(&sender.account_id)
            .fetch_one(pool)
            .await
            .map_err(|_| ApiError::Internal)?;

            if blocked == 0 && recipient.account_id != sender.account_id {
                sqlx::query(
                    "INSERT INTO live_chat_requests
                     (request_id, lease_id, client_request_id, sender_account_id,
                      recipient_account_id, sender_public_key, encrypted_payload,
                      created_at, lease_expires_at, hard_expires_at)
                     VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)",
                )
                .bind(request_id.to_string())
                .bind(lease_id.to_string())
                .bind(input.client_request_id.to_string())
                .bind(&sender.account_id)
                .bind(recipient.account_id)
                .bind(sender_row.public_key)
                .bind(payload)
                .bind(now.to_rfc3339())
                .bind(lease_expires_at.to_rfc3339())
                .bind(hard_expires_at.to_rfc3339())
                .execute(pool)
                .await
                .map_err(|_| ApiError::Internal)?;
            }
        }

        Ok(LiveChatRequestSubmission {
            request_id,
            accepted: true,
            lease_id,
            lease_expires_at,
        })
    }

    #[graphql(name = "renewLiveChatRequest")]
    async fn renew_live_chat_request(
        &self,
        ctx: &Context<'_>,
        input: RenewLiveChatRequestInput,
    ) -> Result<LiveChatRequestLease> {
        let sender = authenticated(ctx)?;
        let pool = ctx.data::<SqlitePool>()?;
        crate::db::remove_expired_live_chat_requests(pool)
            .await
            .map_err(|_| ApiError::Internal)?;
        let row = sqlx::query_as::<_, LeaseRow>(
            "SELECT created_at, hard_expires_at FROM live_chat_requests
             WHERE request_id = ? AND lease_id = ? AND sender_account_id = ?",
        )
        .bind(input.request_id.to_string())
        .bind(input.lease_id.to_string())
        .bind(&sender.account_id)
        .fetch_optional(pool)
        .await
        .map_err(|_| ApiError::Internal)?
        .ok_or(ApiError::InvalidChatRequest)?;
        let hard_expires_at = parse_datetime(&row.hard_expires_at)?;
        let expires_at = std::cmp::min(Utc::now() + Duration::seconds(90), hard_expires_at);
        sqlx::query("UPDATE live_chat_requests SET lease_expires_at = ? WHERE request_id = ?")
            .bind(expires_at.to_rfc3339())
            .bind(input.request_id.to_string())
            .execute(pool)
            .await
            .map_err(|_| ApiError::Internal)?;
        Ok(LiveChatRequestLease {
            request_id: input.request_id,
            lease_id: input.lease_id,
            expires_at,
        })
    }

    #[graphql(name = "cancelLiveChatRequest")]
    async fn cancel_live_chat_request(
        &self,
        ctx: &Context<'_>,
        input: CancelLiveChatRequestInput,
    ) -> Result<bool> {
        let sender = authenticated(ctx)?;
        let pool = ctx.data::<SqlitePool>()?;
        let owner: Option<String> = sqlx::query_scalar(
            "SELECT sender_account_id FROM live_chat_requests WHERE request_id = ? AND lease_id = ?",
        )
        .bind(input.request_id.to_string())
        .bind(input.lease_id.to_string())
        .fetch_optional(pool)
        .await
        .map_err(|_| ApiError::Internal)?;
        if let Some(owner) = owner {
            if owner != sender.account_id {
                return Err(ApiError::InvalidChatRequest.into());
            }
            sqlx::query("DELETE FROM live_chat_requests WHERE request_id = ? AND lease_id = ?")
                .bind(input.request_id.to_string())
                .bind(input.lease_id.to_string())
                .execute(pool)
                .await
                .map_err(|_| ApiError::Internal)?;
        }
        Ok(true)
    }

    #[graphql(name = "blockIdentity")]
    async fn block_identity(
        &self,
        ctx: &Context<'_>,
        input: BlockIdentityInput,
    ) -> Result<BlockedIdentity> {
        let blocker = authenticated(ctx)?;
        let pool = ctx.data::<SqlitePool>()?;
        let identitty = normalise_identitty(&input.identitty).map_err(async_graphql::Error::from)?;
        let target = sqlx::query_as::<_, BlockTargetRow>(
            "SELECT account_id, identitty FROM accounts WHERE identitty = ?",
        )
        .bind(&identitty)
        .fetch_optional(pool)
        .await
        .map_err(|_| ApiError::Internal)?
        .ok_or(ApiError::AccountNotFound)?;
        if target.account_id == blocker.account_id {
            return Err(ApiError::SelfBlock.into());
        }
        let blocked_at = Utc::now();
        sqlx::query(
            "INSERT INTO blocked_accounts (blocker_account_id, blocked_account_id, created_at)
             VALUES (?, ?, ?) ON CONFLICT(blocker_account_id, blocked_account_id) DO NOTHING",
        )
        .bind(&blocker.account_id)
        .bind(&target.account_id)
        .bind(blocked_at.to_rfc3339())
        .execute(pool)
        .await
        .map_err(|_| ApiError::Internal)?;
        sqlx::query(
            "DELETE FROM live_chat_requests WHERE sender_account_id = ? AND recipient_account_id = ?",
        )
        .bind(&target.account_id)
        .bind(&blocker.account_id)
        .execute(pool)
        .await
        .map_err(|_| ApiError::Internal)?;
        let created_at: String = sqlx::query_scalar(
            "SELECT created_at FROM blocked_accounts WHERE blocker_account_id = ? AND blocked_account_id = ?",
        )
        .bind(&blocker.account_id)
        .bind(&target.account_id)
        .fetch_one(pool)
        .await
        .map_err(|_| ApiError::Internal)?;
        Ok(BlockedIdentity {
            account_id: target.account_id,
            identitty: target.identitty,
            blocked_at: parse_datetime(&created_at)?,
        })
    }

    #[graphql(name = "unblockIdentity")]
    async fn unblock_identity(
        &self,
        ctx: &Context<'_>,
        input: UnblockIdentityInput,
    ) -> Result<bool> {
        let blocker = authenticated(ctx)?;
        sqlx::query(
            "DELETE FROM blocked_accounts WHERE blocker_account_id = ? AND blocked_account_id = ?",
        )
        .bind(&blocker.account_id)
        .bind(input.account_id)
        .execute(ctx.data::<SqlitePool>()?)
        .await
        .map_err(|_| ApiError::Internal)?;
        Ok(true)
    }
}

fn authenticated(ctx: &Context<'_>) -> Result<auth::AuthenticatedAccount> {
    ctx.data::<auth::AuthenticatedAccount>()
    .map(Clone::clone)
        .map_err(|_| ApiError::Unauthorized.into())
}

fn decode_payload(value: &str) -> Result<Vec<u8>> {
    let payload = STANDARD.decode(value).map_err(|_| ApiError::InvalidPayload)?;
    if payload.is_empty() || payload.len() > 16 * 1024 {
        return Err(ApiError::InvalidPayload.into());
    }
    Ok(payload)
}

fn parse_datetime(value: &str) -> Result<chrono::DateTime<Utc>> {
    chrono::DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|_| ApiError::Internal.into())
}

#[derive(FromRow)]
struct IdentityRow {
    public_key: Vec<u8>,
}

#[derive(FromRow)]
struct RecipientRow {
    account_id: String,
}

#[derive(FromRow)]
struct ExistingRequestRow {
    request_id: String,
    lease_id: String,
    lease_expires_at: String,
}

impl ExistingRequestRow {
    fn into_submission(self) -> Result<LiveChatRequestSubmission> {
        Ok(LiveChatRequestSubmission {
            request_id: self.request_id.parse().map_err(|_| ApiError::Internal)?,
            accepted: true,
            lease_id: self.lease_id.parse().map_err(|_| ApiError::Internal)?,
            lease_expires_at: parse_datetime(&self.lease_expires_at)?,
        })
    }
}

#[derive(FromRow)]
struct LeaseRow {
    #[allow(dead_code)]
    created_at: String,
    hard_expires_at: String,
}

#[derive(FromRow)]
struct BlockTargetRow {
    account_id: String,
    identitty: String,
}

#[derive(FromRow)]
struct ChallengeRow {
    challenge: Vec<u8>,
    expires_at: String,
    public_key: Vec<u8>,
}

fn is_unique_violation(error: &sqlx::Error) -> bool {
    matches!(error, sqlx::Error::Database(database_error) if database_error.is_unique_violation())
}
