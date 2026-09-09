use async_graphql::{Context, Object, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{DateTime, Utc};
use sqlx::{FromRow, SqlitePool};

use crate::{
    auth::AuthenticatedAccount,
    error::ApiError,
    models::{AccountIdentity, Base64Value, BlockedIdentity, LiveChatRequest},
    validation::normalise_identitty,
};

// MARK: - Task list
// [x] Check availability
// [x] Lookup public identity by identiTTY or AccountID

pub struct QueryRoot;

#[Object]
impl QueryRoot {
    #[graphql(name = "isIdentiTTYAvailable")]
    async fn is_identitty_available(
        &self,
        ctx: &Context<'_>,
        #[graphql(name = "identiTTY")] identitty: String,
    ) -> Result<bool> {
        let identitty = normalise_identitty(&identitty).map_err(async_graphql::Error::from)?;
        let pool = ctx.data::<SqlitePool>()?;
        let exists: i64 =
            sqlx::query_scalar("SELECT EXISTS(SELECT 1 FROM accounts WHERE identitty = ?)")
                .bind(identitty)
                .fetch_one(pool)
                .await
                .map_err(|_| ApiError::Internal)?;
        Ok(exists == 0)
    }

    async fn account(
        &self,
        ctx: &Context<'_>,
        #[graphql(name = "identiTTY")] identitty: String,
    ) -> Result<Option<AccountIdentity>> {
        let identitty = normalise_identitty(&identitty).map_err(async_graphql::Error::from)?;
        find_account(ctx.data::<SqlitePool>()?, "identitty", &identitty).await
    }

    #[graphql(name = "accountByID")]
    async fn account_by_id(
        &self,
        ctx: &Context<'_>,
        #[graphql(name = "accountID")] account_id: String,
    ) -> Result<Option<AccountIdentity>> {
        find_account(ctx.data::<SqlitePool>()?, "account_id", &account_id).await
    }

    async fn me(&self, ctx: &Context<'_>) -> Result<Option<AccountIdentity>> {
        let account = ctx
            .data::<AuthenticatedAccount>()
            .map_err(|_| ApiError::Unauthorized)?;
        find_account(ctx.data::<SqlitePool>()?, "account_id", &account.account_id).await
    }

    async fn blocked_identities(&self, ctx: &Context<'_>) -> Result<Vec<BlockedIdentity>> {
        let account = authenticated(ctx)?;
        let pool = ctx.data::<SqlitePool>()?;
        let rows = sqlx::query_as::<_, BlockedIdentityRow>(
            "SELECT b.blocked_account_id, a.identitty, b.created_at
             FROM blocked_accounts b JOIN accounts a ON a.account_id = b.blocked_account_id
             WHERE b.blocker_account_id = ? ORDER BY b.created_at",
        )
        .bind(&account.account_id)
        .fetch_all(pool)
        .await
        .map_err(|_| ApiError::Internal)?;

        rows.into_iter().map(BlockedIdentityRow::into_model).collect()
    }

    async fn live_chat_requests(&self, ctx: &Context<'_>) -> Result<Vec<LiveChatRequest>> {
        let account = authenticated(ctx)?;
        let pool = ctx.data::<SqlitePool>()?;
        crate::db::remove_expired_live_chat_requests(pool)
            .await
            .map_err(|_| ApiError::Internal)?;
        let rows = sqlx::query_as::<_, LiveChatRequestRow>(
            "SELECT r.request_id, r.sender_account_id, a.identitty, r.sender_public_key,
                    r.encrypted_payload, r.created_at, r.lease_expires_at
             FROM live_chat_requests r JOIN accounts a ON a.account_id = r.sender_account_id
             WHERE r.recipient_account_id = ?
                             AND julianday(r.lease_expires_at) > julianday('now')
                             AND julianday(r.hard_expires_at) > julianday('now')
             ORDER BY r.created_at",
        )
        .bind(&account.account_id)
        .fetch_all(pool)
        .await
        .map_err(|_| ApiError::Internal)?;

        rows.into_iter().map(LiveChatRequestRow::into_model).collect()
        }
    }


fn authenticated(ctx: &Context<'_>) -> Result<AuthenticatedAccount> {
    ctx.data::<AuthenticatedAccount>()
    .map(Clone::clone)
        .map_err(|_| ApiError::Unauthorized.into())
}

#[derive(FromRow)]
struct BlockedIdentityRow {
    blocked_account_id: String,
    identitty: String,
    created_at: String,
}

impl BlockedIdentityRow {
    fn into_model(self) -> Result<BlockedIdentity> {
        Ok(BlockedIdentity {
            account_id: self.blocked_account_id,
            identitty: self.identitty,
            blocked_at: parse_datetime(&self.created_at)?,
        })
    }
}

#[derive(FromRow)]
struct LiveChatRequestRow {
    request_id: String,
    sender_account_id: String,
    identitty: String,
    sender_public_key: Vec<u8>,
    encrypted_payload: Vec<u8>,
    created_at: String,
    lease_expires_at: String,
}

impl LiveChatRequestRow {
    fn into_model(self) -> Result<LiveChatRequest> {
        let request_id = self.request_id.parse().map_err(|_| ApiError::Internal)?;
        Ok(LiveChatRequest {
            request_id,
            sender_account_id: self.sender_account_id,
            sender_identitty: self.identitty,
            sender_public_key: Base64Value(STANDARD.encode(self.sender_public_key)),
            encrypted_payload: Base64Value(STANDARD.encode(self.encrypted_payload)),
            created_at: parse_datetime(&self.created_at)?,
            expires_at: parse_datetime(&self.lease_expires_at)?,
        })
    }
}

fn parse_datetime(value: &str) -> Result<DateTime<Utc>> {
    DateTime::parse_from_rfc3339(value)
        .map(|value| value.with_timezone(&Utc))
        .map_err(|_| ApiError::Internal.into())
}
#[derive(FromRow)]
struct AccountRow {
    account_id: String,
    identitty: String,
    public_key: Vec<u8>,
    created_at: String,
}

async fn find_account(
    pool: &SqlitePool,
    column: &str,
    value: &str,
) -> Result<Option<AccountIdentity>> {
    let sql = match column {
        "identitty" => "SELECT account_id, identitty, public_key, created_at FROM accounts WHERE identitty = ?",
        "account_id" => "SELECT account_id, identitty, public_key, created_at FROM accounts WHERE account_id = ?",
        _ => return Err(ApiError::Internal.into()),
    };

    let row = sqlx::query_as::<_, AccountRow>(sql)
        .bind(value)
        .fetch_optional(pool)
        .await
        .map_err(|_| ApiError::Internal)?;

    row.map(to_identity).transpose()
}

fn to_identity(row: AccountRow) -> Result<AccountIdentity> {
    let created_at = DateTime::parse_from_rfc3339(&row.created_at)
        .map_err(|_| ApiError::Internal)?
        .with_timezone(&Utc);
    Ok(AccountIdentity {
        account_id: row.account_id,
        identitty: row.identitty,
        public_key: STANDARD.encode(row.public_key),
        created_at,
    })
}
