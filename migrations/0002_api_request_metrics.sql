-- Aggregate request metrics by UTC 15-minute bucket.
CREATE TABLE IF NOT EXISTS api_request_metrics (
    bucket_start TEXT NOT NULL,
    method TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    status_class INTEGER NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 0,
    latency_ms_total REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (bucket_start, method, endpoint, status_class)
);

CREATE INDEX IF NOT EXISTS idx_api_request_metrics_bucket
ON api_request_metrics(bucket_start);
