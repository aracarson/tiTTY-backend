mod account_id;
mod auth;
mod config;
mod db;
mod error;
mod graphql;
mod models;
mod rate_limit;
mod validation;

use std::{
    net::{IpAddr, SocketAddr},
    sync::Arc,
    time::Duration,
};

use anyhow::Context;
use async_graphql::Request as GraphQLRequestData;
use async_graphql_axum::{GraphQLRequest, GraphQLResponse};
use axum::{
    extract::{DefaultBodyLimit, State},
    http::{header, HeaderMap, HeaderValue, Method, StatusCode},
    middleware,
    response::{IntoResponse, Response},
    routing::{get, post},
    Router,
};
use chrono::Utc;
use config::Config;
use graphql::{build_schema, AppSchema};
use tower_http::{
    cors::CorsLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    trace::TraceLayer,
};
use tracing::{event, info, Level};
use tracing_subscriber::{layer::SubscriberExt, util::SubscriberInitExt, Layer};

// MARK: - Task list
// [x] Expose GraphQL without GraphiQL
// [x] Bind privately for HTTPS reverse-proxy termination
// [x] Apply request-size, CORS, tracing and request-ID middleware

#[derive(Clone)]
struct AppState {
    schema: AppSchema,
    pool: sqlx::SqlitePool,
    config: Arc<Config>,
    rate_limiter: Arc<rate_limit::RateLimiter>,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    let api_log_dir =
        std::env::var("TITTY_API_LOG_DIR").unwrap_or_else(|_| "/var/log/titty-backend".to_owned());
    std::fs::create_dir_all(&api_log_dir)
        .with_context(|| format!("could not create API log directory {api_log_dir}"))?;
    let api_log = tracing_appender::rolling::daily(&api_log_dir, "api-access.jsonl");
    let (api_writer, _api_log_guard) = tracing_appender::non_blocking(api_log);

    tracing_subscriber::registry()
        .with(
            tracing_subscriber::fmt::layer().with_filter(
                tracing_subscriber::EnvFilter::try_from_default_env()
                    .unwrap_or_else(|_| "titty_backend=info,tower_http=info".into()),
            ),
        )
        .with(
            tracing_subscriber::fmt::layer()
                .json()
                .with_target(true)
                .with_writer(api_writer)
                .with_filter(tracing_subscriber::EnvFilter::new("api_access=info")),
        )
        .init();

    let config = Arc::new(Config::from_env()?);
    let pool = db::connect(&config.database_url).await?;
    db::migrate(&pool).await?;
    db::apply_runtime_pragmas(&pool).await?;
    db::remove_expired_challenges(&pool).await?;
    db::remove_expired_live_chat_requests(&pool).await?;

    let cleanup_pool = pool.clone();
    tokio::spawn(async move {
        let mut interval = tokio::time::interval(Duration::from_secs(60));
        loop {
            interval.tick().await;
            if let Err(error) = db::remove_expired_live_chat_requests(&cleanup_pool).await {
                tracing::warn!(%error, "could not clean up expired live-chat requests");
            }
        }
    });

    let rate_limiter = Arc::new(rate_limit::RateLimiter::default());
    let schema = build_schema(pool.clone(), config.clone(), rate_limiter.clone());
    let state = AppState {
        schema,
        pool,
        config: config.clone(),
        rate_limiter,
    };

    let cors = CorsLayer::new()
        .allow_origin(
            config
                .allowed_origin
                .parse::<HeaderValue>()
                .context("TITTY_ALLOWED_ORIGIN is not a valid origin")?,
        )
        .allow_methods([Method::POST])
        .allow_headers([header::CONTENT_TYPE, header::AUTHORIZATION]);

    let app = Router::new()
        .route("/healthz", get(health))
        .route("/graphql", post(graphql_handler))
        .layer(DefaultBodyLimit::max(config.max_body_bytes))
        .layer(PropagateRequestIdLayer::x_request_id())
        .layer(SetRequestIdLayer::new(
            header::HeaderName::from_static("x-request-id"),
            MakeRequestUuid,
        ))
        .layer(TraceLayer::new_for_http())
        .layer(cors)
        .layer(middleware::from_fn_with_state(
            state.clone(),
            api_access_log,
        ))
        .with_state(state);

    let address: SocketAddr = config
        .bind_address
        .parse()
        .context("TITTY_BIND_ADDRESS is invalid")?;

    if !address.ip().is_loopback() {
        anyhow::bail!("TITTY_BIND_ADDRESS must use a loopback address in production");
    }

    let listener = tokio::net::TcpListener::bind(address).await?;
    info!(%address, "identiTTY GraphQL service listening privately");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

async fn api_access_log(
    State(state): State<AppState>,
    request: axum::http::Request<axum::body::Body>,
    next: middleware::Next,
) -> Response {
    let method = request.method().clone();
    let endpoint = request.uri().path().to_owned();
    let source_ip = request_source(request.headers());
    let request_id = request
        .headers()
        .get("x-request-id")
        .and_then(|value| value.to_str().ok())
        .unwrap_or("unknown")
        .to_owned();
    let started = std::time::Instant::now();
    let response = next.run(request).await;

    event!(
        target: "api_access",
        Level::INFO,
        event = "api_request",
        source_ip = %source_ip,
        method = %method,
        endpoint = %endpoint,
        status = response.status().as_u16(),
        latency_ms = started.elapsed().as_secs_f64() * 1000.0,
        request_id = %request_id,
    );

    if let Err(error) = db::record_api_request(
        &state.pool,
        Utc::now(),
        &source_ip,
        method.as_str(),
        &endpoint,
        response.status().as_u16(),
        started.elapsed().as_secs_f64() * 1000.0,
    )
    .await
    {
        tracing::warn!(%error, "could not record API request metrics");
    }

    response
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn graphql_handler(
    State(state): State<AppState>,
    headers: HeaderMap,
    request: GraphQLRequest,
) -> Response {
    let client_key = client_key(&headers);
    if !state.rate_limiter.check(
        &format!("{client_key}:graphql"),
        120,
        Duration::from_secs(60),
    ) {
        return (StatusCode::TOO_MANY_REQUESTS, "too many requests").into_response();
    }

    let authorization = headers
        .get(header::AUTHORIZATION)
        .and_then(|value| value.to_str().ok());
    let authenticated = match auth::authenticate_bearer(authorization, &state.config) {
        Ok(authenticated) => authenticated,
        Err(_) => return StatusCode::UNAUTHORIZED.into_response(),
    };

    let mut request: GraphQLRequestData = request.into_inner();
    request = request.data(rate_limit::RequestContext { client_key });
    if let Some(authenticated) = authenticated {
        request = request.data(authenticated);
    }

    let response: GraphQLResponse = state.schema.execute(request).await.into();
    response.into_response()
}

fn client_key(headers: &HeaderMap) -> String {
    request_source(headers)
}

fn request_source(headers: &HeaderMap) -> String {
    headers
        .get("x-forwarded-for")
        .and_then(|value| value.to_str().ok())
        .and_then(|value| value.split(',').next())
        .or_else(|| {
            headers
                .get("x-real-ip")
                .and_then(|value| value.to_str().ok())
        })
        .and_then(normalize_ip)
        .unwrap_or_else(|| "unknown".to_owned())
}

fn normalize_ip(value: &str) -> Option<String> {
    value
        .trim()
        .parse::<IpAddr>()
        .ok()
        .map(|address| address.to_string())
}

#[cfg(test)]
mod tests {
    use super::request_source;
    use axum::http::{HeaderMap, HeaderValue};

    #[test]
    fn normalizes_ipv4_and_ipv6_sources() {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", HeaderValue::from_static(" 192.0.2.7 "));
        assert_eq!(request_source(&headers), "192.0.2.7");

        headers.insert(
            "x-forwarded-for",
            HeaderValue::from_static("2001:0db8:0:0:0:0:0:1"),
        );
        assert_eq!(request_source(&headers), "2001:db8::1");
    }

    #[test]
    fn rejects_invalid_forwarding_values() {
        let mut headers = HeaderMap::new();
        headers.insert("x-forwarded-for", HeaderValue::from_static("not-an-ip"));
        headers.insert("x-real-ip", HeaderValue::from_static("also-not-an-ip"));
        assert_eq!(request_source(&headers), "unknown");
    }
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c()
            .await
            .expect("failed to install Ctrl+C handler");
    };

    #[cfg(unix)]
    let terminate = async {
        tokio::signal::unix::signal(tokio::signal::unix::SignalKind::terminate())
            .expect("failed to install SIGTERM handler")
            .recv()
            .await;
    };

    #[cfg(not(unix))]
    let terminate = std::future::pending::<()>();

    tokio::select! {
        _ = ctrl_c => {},
        _ = terminate => {},
    }
}
