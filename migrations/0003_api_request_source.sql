-- Track the observed client source alongside aggregate request metrics.
CREATE TABLE api_request_metrics_v3 (
    bucket_start TEXT NOT NULL,
    source_ip TEXT NOT NULL,
    method TEXT NOT NULL,
    endpoint TEXT NOT NULL,
    status_class INTEGER NOT NULL,
    request_count INTEGER NOT NULL DEFAULT 0,
    latency_ms_total REAL NOT NULL DEFAULT 0,
    PRIMARY KEY (bucket_start, source_ip, method, endpoint, status_class)
);

INSERT INTO api_request_metrics_v3
    (bucket_start, source_ip, method, endpoint, status_class, request_count, latency_ms_total)
SELECT bucket_start, 'unknown', method, endpoint, status_class, request_count, latency_ms_total
FROM api_request_metrics;

DROP TABLE api_request_metrics;
ALTER TABLE api_request_metrics_v3 RENAME TO api_request_metrics;

CREATE INDEX idx_api_request_metrics_bucket
ON api_request_metrics(bucket_start);
CREATE INDEX idx_api_request_metrics_source
ON api_request_metrics(source_ip);
