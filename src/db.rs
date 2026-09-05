use sqlx::{sqlite::SqliteConnectOptions, SqlitePool};
use std::str::FromStr;

// MARK: - Task list
// [x] Use WAL mode and bounded connections for a small EC2 instance
// [x] Run embedded migrations automatically

pub async fn connect(database_url: &str) -> anyhow::Result<SqlitePool> {
    let options = SqliteConnectOptions::from_str(database_url)?
        .create_if_missing(true)
        .foreign_keys(true)
        .busy_timeout(std::time::Duration::from_secs(5));

    Ok(sqlx::sqlite::SqlitePoolOptions::new()
        .max_connections(4)
        .min_connections(1)
        .connect_with(options)
        .await?)
}

pub async fn migrate(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::migrate!("./migrations").run(pool).await?;
    Ok(())
}

pub async fn apply_runtime_pragmas(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::query("PRAGMA journal_mode = WAL").execute(pool).await?;
    sqlx::query("PRAGMA synchronous = FULL").execute(pool).await?;
    sqlx::query("PRAGMA secure_delete = ON").execute(pool).await?;
    Ok(())
}

pub async fn remove_expired_challenges(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::query("DELETE FROM authentication_challenges WHERE expires_at <= CURRENT_TIMESTAMP OR used_at IS NOT NULL")
        .execute(pool)
        .await?;
    Ok(())
}
