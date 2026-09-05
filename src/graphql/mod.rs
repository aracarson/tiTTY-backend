mod mutation;
mod query;

use std::sync::Arc;

use async_graphql::{EmptySubscription, Schema};
use sqlx::SqlitePool;

use crate::config::Config;
use crate::rate_limit::RateLimiter;
pub use mutation::MutationRoot;
pub use query::QueryRoot;

pub type AppSchema = Schema<QueryRoot, MutationRoot, EmptySubscription>;

// MARK: - Task list
// [x] Keep database and configuration in GraphQL context

pub fn build_schema(
    pool: SqlitePool,
    config: Arc<Config>,
    rate_limiter: Arc<RateLimiter>,
) -> AppSchema {
    Schema::build(QueryRoot, MutationRoot, EmptySubscription)
        .data(pool)
        .data(config)
        .data(rate_limiter)
        .limit_depth(8)
        .limit_complexity(100)
        .finish()
}
