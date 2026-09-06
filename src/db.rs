use chrono::{DateTime, Timelike, Utc};
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
    sqlx::query("PRAGMA journal_mode = WAL")
        .execute(pool)
        .await?;
    sqlx::query("PRAGMA synchronous = FULL")
        .execute(pool)
        .await?;
    sqlx::query("PRAGMA secure_delete = ON")
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn remove_expired_challenges(pool: &SqlitePool) -> anyhow::Result<()> {
    sqlx::query("DELETE FROM authentication_challenges WHERE expires_at <= CURRENT_TIMESTAMP OR used_at IS NOT NULL")
        .execute(pool)
        .await?;
    Ok(())
}

pub async fn record_api_request(
    pool: &SqlitePool,
    timestamp: DateTime<Utc>,
    method: &str,
    endpoint: &str,
    status: u16,
    latency_ms: f64,
) -> anyhow::Result<()> {
    let bucket_minute = (timestamp.minute() / 15) * 15;
    let bucket_start = timestamp
        .with_minute(bucket_minute)
        .and_then(|value| value.with_second(0))
        .and_then(|value| value.with_nanosecond(0))
        .unwrap_or(timestamp)
        .to_rfc3339_opts(chrono::SecondsFormat::Secs, true);
    let status_class = i64::from(status / 100);

    sqlx::query(
        "INSERT INTO api_request_metrics (bucket_start, method, endpoint, status_class, request_count, latency_ms_total) VALUES (?, ?, ?, ?, 1, ?) ON CONFLICT(bucket_start, method, endpoint, status_class) DO UPDATE SET request_count = request_count + 1, latency_ms_total = latency_ms_total + excluded.latency_ms_total",
    )
    .bind(bucket_start)
    .bind(method)
    .bind(endpoint)
    .bind(status_class)
    .bind(latency_ms)
    .execute(pool)
    .await?;

    Ok(())
}
