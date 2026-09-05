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
        RegisterAccountInput,
    },
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
