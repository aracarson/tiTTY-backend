use anyhow::{bail, Context};

// MARK: - Task list
// [x] Keep secrets and deployment-specific values outside source control

#[derive(Debug, Clone)]
pub struct Config {
    pub bind_address: String,
    pub database_url: String,
    pub jwt_secret: String,
    pub jwt_issuer: String,
    pub session_ttl_seconds: i64,
    pub challenge_ttl_seconds: i64,
    pub max_body_bytes: usize,
    pub allowed_origin: String,
}

impl Config {
    pub fn from_env() -> anyhow::Result<Self> {
        let jwt_secret = required("TITTY_JWT_SECRET")?;
        if jwt_secret.as_bytes().len() < 32 {
            bail!("TITTY_JWT_SECRET must be at least 32 bytes");
        }

        Ok(Self {
            bind_address: optional("TITTY_BIND_ADDRESS", "127.0.0.1:8080"),
            database_url: optional("TITTY_DATABASE_URL", "sqlite://data/identity.db?mode=rwc"),
            jwt_secret,
            jwt_issuer: optional("TITTY_JWT_ISSUER", "titty-identity"),
            session_ttl_seconds: parse("TITTY_SESSION_TTL_SECONDS", 3600)?,
            challenge_ttl_seconds: parse("TITTY_CHALLENGE_TTL_SECONDS", 180)?,
            max_body_bytes: parse("TITTY_MAX_BODY_BYTES", 65_536)?,
            allowed_origin: required("TITTY_ALLOWED_ORIGIN")?,
        })
    }
}

fn required(name: &str) -> anyhow::Result<String> {
    std::env::var(name).with_context(|| format!("missing required environment variable {name}"))
}

fn optional(name: &str, default: &str) -> String {
    std::env::var(name).unwrap_or_else(|_| default.to_owned())
}

fn parse<T>(name: &str, default: T) -> anyhow::Result<T>
where
    T: std::str::FromStr + ToString,
    T::Err: std::error::Error + Send + Sync + 'static,
{
    std::env::var(name)
        .unwrap_or_else(|_| default.to_string())
        .parse()
        .with_context(|| format!("{name} is invalid"))
}
