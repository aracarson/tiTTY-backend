mod account_id;
mod auth;
mod config;
mod db;
mod error;
mod graphql;
mod models;
mod validation;

use std::{net::SocketAddr, sync::Arc};

use anyhow::Context;
use async_graphql::{http::GraphiQLSource, EmptySubscription};
use async_graphql_axum::{GraphQLRequest, GraphQLResponse};
use axum::{
    extract::{DefaultBodyLimit, State},
    http::{header, HeaderValue, Method, StatusCode},
    response::{Html, IntoResponse},
    routing::{get, post},
    Router,
};
use config::Config;
use graphql::{build_schema, AppSchema};
use tower_http::{
    cors::CorsLayer,
    request_id::{MakeRequestUuid, PropagateRequestIdLayer, SetRequestIdLayer},
    trace::TraceLayer,
};
use tracing::info;

// MARK: - Task list
// [x] Expose a small GraphQL identity API
// [x] Bind privately by default for reverse-proxy TLS termination
// [x] Apply request-size, CORS, tracing and request-ID middleware

#[derive(Clone)]
struct AppState {
    schema: AppSchema,
}

#[tokio::main]
async fn main() -> anyhow::Result<()> {
    dotenvy::dotenv().ok();
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "titty_backend=info,tower_http=info".into()),
        )
        .init();

    let config = Arc::new(Config::from_env()?);
    let pool = db::connect(&config.database_url).await?;
    db::migrate(&pool).await?;
    db::apply_runtime_pragmas(&pool).await?;
    db::remove_expired_challenges(&pool).await?;

    let schema = build_schema(pool, config.clone());
    let state = AppState { schema };

    let cors = CorsLayer::new()
        .allow_origin(
            config.allowed_origin.parse::<HeaderValue>()
                .context("TITTY_ALLOWED_ORIGIN is not a valid origin")?,
        )
        .allow_methods([Method::GET, Method::POST])
        .allow_headers([header::CONTENT_TYPE, header::AUTHORIZATION]);

    let app = Router::new()
        .route("/healthz", get(health))
        .route("/graphql", post(graphql_handler))
        .route("/graphiql", get(graphiql))
        .layer(DefaultBodyLimit::max(config.max_body_bytes))
        .layer(PropagateRequestIdLayer::x_request_id())
        .layer(SetRequestIdLayer::new(
            header::HeaderName::from_static("x-request-id"),
            MakeRequestUuid,
        ))
        .layer(TraceLayer::new_for_http())
        .layer(cors)
        .with_state(state);

    let address: SocketAddr = config.bind_address.parse()
        .context("TITTY_BIND_ADDRESS is invalid")?;
    let listener = tokio::net::TcpListener::bind(address).await?;
    info!(%address, "identiTTY GraphQL service listening");

    axum::serve(listener, app)
        .with_graceful_shutdown(shutdown_signal())
        .await?;

    Ok(())
}

async fn health() -> impl IntoResponse {
    (StatusCode::OK, "ok")
}

async fn graphql_handler(
    State(state): State<AppState>,
    request: GraphQLRequest,
) -> GraphQLResponse {
    state.schema.execute(request.into_inner()).await.into()
}

async fn graphiql() -> Html<String> {
    Html(
        GraphiQLSource::build()
            .endpoint("/graphql")
            .finish(),
    )
}

async fn shutdown_signal() {
    let ctrl_c = async {
        tokio::signal::ctrl_c().await.expect("failed to install Ctrl+C handler");
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
