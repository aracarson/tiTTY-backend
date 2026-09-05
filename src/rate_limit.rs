use async_graphql::Context;
use std::{
    collections::HashMap,
    sync::Mutex,
    time::{Duration, Instant},
};

use crate::error::ApiError;

#[derive(Clone, Debug)]
pub struct RequestContext {
    pub client_key: String,
}

#[derive(Default)]
pub struct RateLimiter {
    buckets: Mutex<HashMap<String, Bucket>>,
}

struct Bucket {
    started: Instant,
    count: u32,
}

impl RateLimiter {
    pub fn check(&self, key: &str, limit: u32, window: Duration) -> bool {
        let now = Instant::now();
        let mut buckets = self.buckets.lock().expect("rate limiter mutex poisoned");

        buckets.retain(|_, bucket| now.duration_since(bucket.started) < Duration::from_secs(3600));
        if !buckets.contains_key(key) && buckets.len() >= 4096 {
            return false;
        }

        let bucket = buckets.entry(key.to_owned()).or_insert(Bucket {
            started: now,
            count: 0,
        });

        if now.duration_since(bucket.started) >= window {
            bucket.started = now;
            bucket.count = 0;
        }

        if bucket.count >= limit {
            return false;
        }

        bucket.count += 1;
        true
    }
}

pub fn enforce(
    ctx: &Context<'_>,
    scope: &str,
    limit: u32,
    window: Duration,
) -> Result<(), async_graphql::Error> {
    let request = ctx.data::<RequestContext>()?;
    let limiter = ctx.data::<RateLimiter>()?;
    let key = format!("{}:{}", request.client_key, scope);

    if limiter.check(&key, limit, window) {
        Ok(())
    } else {
        Err(ApiError::RateLimited.into())
    }
}

#[cfg(test)]
mod tests {
    use super::RateLimiter;
    use std::time::Duration;

    #[test]
    fn limits_requests_per_key() {
        let limiter = RateLimiter::default();
        assert!(limiter.check("client:register", 1, Duration::from_secs(60)));
        assert!(!limiter.check("client:register", 1, Duration::from_secs(60)));
        assert!(limiter.check("other:register", 1, Duration::from_secs(60)));
    }
}
