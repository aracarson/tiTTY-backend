use async_graphql::{Context, Object, Result};
use base64::{engine::general_purpose::STANDARD, Engine};
use chrono::{DateTime, Utc};
use sqlx::{FromRow, SqlitePool};

use crate::{error::ApiError, models::AccountIdentity, validation::normalise_identitty};

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
        let exists: i64 = sqlx::query_scalar(
            "SELECT EXISTS(SELECT 1 FROM accounts WHERE identitty = ?)",
        )
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
