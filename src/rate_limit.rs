use async_graphql::Context;
use std::{
    collections::HashMap,
    sync::{
        Arc,
        Mutex,
    },
    time::{
        Duration,
        Instant,
    },
};

use crate::error::ApiError;

// MARK: - Task list

// [x] Maintain separate request buckets by client and scope
// [x] Reset buckets after their configured window
// [x] Limit retained buckets to protect memory
// [x] Retrieve Arc<RateLimiter> from the GraphQL context
// [x] Return the stable RATE_LIMITED GraphQL error

// MARK: - Request Context

#[derive(
    Clone,
    Debug,
)]
pub struct RequestContext {
    pub client_key: String,
}

// MARK: - Rate Limiter

#[derive(Default)]
pub struct RateLimiter {
    buckets:
        Mutex<
            HashMap<
                String,
                Bucket,
            >,
        >,
}

// MARK: - Bucket

struct Bucket {
    started: Instant,
    count: u32,
}

// MARK: - Rate-Limit Checking

impl RateLimiter {

    pub fn check(
        &self,
        key: &str,
        limit: u32,
        window: Duration,
    ) -> bool {

        let now =
            Instant::now();

        let mut buckets =
            self.buckets
                .lock()
                .expect(
                    "rate limiter mutex poisoned"
                );

        /*
         * Remove inactive buckets to ensure the
         * in-memory limiter remains bounded.
         */
        buckets.retain(
            |_, bucket| {

                now.duration_since(
                    bucket.started
                ) < Duration::from_secs(
                    3_600
                )
            },
        );

        /*
         * Refuse to allocate additional buckets
         * after reaching the safety limit.
         */
        if !buckets.contains_key(
            key
        ) && buckets.len() >= 4_096
        {
            return false;
        }

        let bucket =
            buckets.entry(
                key.to_owned()
            )
            .or_insert(
                Bucket {
                    started:
                        now,
                    count:
                        0,
                },
            );

        /*
         * Begin a new fixed window once the
         * previous window has elapsed.
         */
        if now.duration_since(
            bucket.started
        ) >= window
        {
            bucket.started =
                now;

            bucket.count =
                0;
        }

        if bucket.count >= limit {
            return false;
        }

        bucket.count =
            bucket.count
                .saturating_add(
                    1
                );

        true
    }
}

// MARK: - GraphQL Enforcement

pub fn enforce(
    ctx: &Context<'_>,
    scope: &str,
    limit: u32,
    window: Duration,
) -> Result<
    (),
    async_graphql::Error,
> {

    let request =
        ctx.data::<
            RequestContext
        >()?;

    /*
     * build_schema stores Arc<RateLimiter>, so
     * GraphQL context lookup must use the exact
     * same concrete type.
     */
    let limiter =
        ctx.data::<
            Arc<RateLimiter>
        >()?;

    let key =
        format!(
            "{}:{}",
            request.client_key,
            scope
        );

    if limiter.check(
        &key,
        limit,
        window,
    ) {
        Ok(())
    } else {
        Err(
            ApiError::RateLimited
                .into()
        )
    }
}

// MARK: - Tests

#[cfg(test)]
mod tests {

    use super::RateLimiter;
    use std::time::Duration;

    // MARK: Allows Request Within Limit

    #[test]
    fn allows_request_within_limit() {

        let limiter =
            RateLimiter::default();

        assert!(
            limiter.check(
                "client:register",
                1,
                Duration::from_secs(
                    60
                ),
            )
        );
    }

    // MARK: Rejects Request Over Limit

    #[test]
    fn rejects_request_over_limit() {

        let limiter =
            RateLimiter::default();

        assert!(
            limiter.check(
                "client:register",
                1,
                Duration::from_secs(
                    60
                ),
            )
        );

        assert!(
            !limiter.check(
                "client:register",
                1,
                Duration::from_secs(
                    60
                ),
            )
        );
    }

    // MARK: Isolates Keys

    #[test]
    fn isolates_rate_limits_by_key() {

        let limiter =
            RateLimiter::default();

        assert!(
            limiter.check(
                "client-a:register",
                1,
                Duration::from_secs(
                    60
                ),
            )
        );

        assert!(
            limiter.check(
                "client-b:register",
                1,
                Duration::from_secs(
                    60
                ),
            )
        );
    }

    // MARK: Isolates Scopes

    #[test]
    fn isolates_rate_limits_by_scope() {

        let limiter =
            RateLimiter::default();

        assert!(
            limiter.check(
                "client:register",
                1,
                Duration::from_secs(
                    60
                ),
            )
        );

        assert!(
            limiter.check(
                "client:challenge",
                1,
                Duration::from_secs(
                    60
                ),
            )
        );
    }

    // MARK: Handles Counter Saturation

    #[test]
    fn zero_limit_rejects_request() {

        let limiter =
            RateLimiter::default();

        assert!(
            !limiter.check(
                "client:register",
                0,
                Duration::from_secs(
                    60
                ),
            )
        );
    }
}