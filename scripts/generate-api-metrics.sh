#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/generate-api-metrics.sh [since]" >&2
  exit 1
fi

ENV_FILE="/etc/titty-backend/titty-backend.env"
if [[ -r "${ENV_FILE}" ]]; then
  source "${ENV_FILE}"
fi

SINCE="${1:-24 hours ago}"
DATABASE_PATH="${TITTY_DATABASE_PATH:-/var/lib/titty-backend/identity.db}"
OUTPUT_DIR="${TITTY_API_METRICS_DIR:-/var/lib/titty-backend/api-metrics}"
S3_ROOT="${TITTY_REPORTS_S3_URI:-s3://identitty/reports}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_DIR="${OUTPUT_DIR}/${STAMP}"

if [[ ! -r "${DATABASE_PATH}" ]]; then
  echo "Database is not readable: ${DATABASE_PATH}" >&2
  exit 1
fi
for command_name in sqlite3 python3 aws; do
  if ! command -v "${command_name}" >/dev/null 2>&1; then
    echo "${command_name} is required" >&2
    exit 1
  fi
done

install -d -m 0750 "${REPORT_DIR}"

if ! sqlite3 "${DATABASE_PATH}" "SELECT 1 FROM sqlite_master WHERE type='table' AND name='api_request_metrics';" | grep -q '^1$'; then
  echo "api_request_metrics table is missing from ${DATABASE_PATH}. Deploy the new backend binary so migration 0002 can run." >&2
  exit 1
fi

ALL_TIME_REQUESTS="$(sqlite3 "${DATABASE_PATH}" "SELECT COALESCE(SUM(request_count), 0) FROM api_request_metrics;")"
echo "Metrics database: ${DATABASE_PATH}"
echo "All-time recorded API requests: ${ALL_TIME_REQUESTS}"

SQL_SINCE="$(date -u -d "${SINCE}" '+%Y-%m-%dT%H:%M:%SZ')"
sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT bucket_start, source_ip, method, endpoint, request_count, status_class, ROUND(latency_ms_total, 3) AS latency_ms_total FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}' ORDER BY bucket_start, endpoint, source_ip, method, status_class;" \
  > "${REPORT_DIR}/api-calls-by-15-minutes.csv"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT COALESCE(SUM(request_count), 0) AS total_requests, COUNT(DISTINCT bucket_start) AS buckets, MIN(bucket_start) AS first_bucket, MAX(bucket_start) AS latest_bucket FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}';" \
  > "${REPORT_DIR}/summary.csv"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT endpoint, SUM(request_count) AS requests, ROUND(SUM(latency_ms_total), 3) AS latency_ms_total FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}' GROUP BY endpoint ORDER BY requests DESC;" \
  > "${REPORT_DIR}/endpoint-summary.csv"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT bucket_start, SUM(request_count) AS requests FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}' GROUP BY bucket_start ORDER BY bucket_start;" \
  > "${REPORT_DIR}/bucket-summary.csv"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT status_class || 'xx' AS status_class, SUM(request_count) AS requests FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}' GROUP BY status_class ORDER BY status_class;" \
  > "${REPORT_DIR}/status-summary.csv"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT source_ip, SUM(request_count) AS requests, COUNT(DISTINCT endpoint) AS endpoints, ROUND(SUM(latency_ms_total), 3) AS latency_ms_total FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}' GROUP BY source_ip ORDER BY requests DESC;" \
  > "${REPORT_DIR}/source-summary.csv"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT source_ip, endpoint, SUM(request_count) AS requests FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}' GROUP BY source_ip, endpoint ORDER BY requests DESC;" \
  > "${REPORT_DIR}/source-endpoint-summary.csv"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT source_ip, status_class || 'xx' AS status_class, SUM(request_count) AS requests FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}' GROUP BY source_ip, status_class ORDER BY requests DESC;" \
  > "${REPORT_DIR}/source-status-summary.csv"

python3 - "${REPORT_DIR}" "${SINCE}" <<'PY'
import csv
import html
import json
import sys
from pathlib import Path

report_dir = Path(sys.argv[1])
since = sys.argv[2]

def read_csv(name):
  with (report_dir / name).open(newline="") as source:
    return list(csv.DictReader(source))

rows = read_csv("api-calls-by-15-minutes.csv")
endpoint_rows = read_csv("endpoint-summary.csv")
bucket_rows = read_csv("bucket-summary.csv")
status_rows = read_csv("status-summary.csv")
source_rows = read_csv("source-summary.csv")
source_endpoint_rows = read_csv("source-endpoint-summary.csv")
source_status_rows = read_csv("source-status-summary.csv")

for row in rows:
  row["requests"] = int(row["request_count"])
  row["status_class"] = int(row["status_class"])
  row["latency_ms_total"] = float(row["latency_ms_total"])
for row in endpoint_rows + bucket_rows + status_rows + source_rows + source_endpoint_rows + source_status_rows:
  row["requests"] = int(row["requests"])

total_requests = sum(row["requests"] for row in rows)
summary = {
  "since": since,
  "generated_utc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
  "total_requests": total_requests,
  "metric_rows": len(rows),
  "endpoint_count": len(endpoint_rows),
  "bucket_count": len(bucket_rows),
  "source_count": len(source_rows),
}
(report_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")

def table(headers, records):
  head = "".join(f"<th>{html.escape(header)}</th>" for header in headers)
  body = "".join("<tr>" + "".join(f"<td>{html.escape(str(record.get(header, '')))}</td>" for header in headers) + "</tr>" for record in records)
  if not body:
    body = f'<tr><td colspan="{len(headers)}" class="empty">No data in this window</td></tr>'
  return f"<table><thead><tr>{head}</tr></thead><tbody>{body}</tbody></table>"

chart_json = json.dumps([{"bucket": row["bucket_start"], "requests": row["requests"]} for row in bucket_rows], separators=(",", ":"))
html_report = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>tiTTY API calls</title>
<style>body{{font:16px system-ui,sans-serif;max-width:1200px;margin:2rem auto;padding:0 1rem;color:#18212b;background:#f5f7f9}}main{{background:#fff;border:1px solid #d9e0e7;border-radius:8px;padding:1.5rem}}h1{{font-size:1.5rem}}h2{{font-size:1.05rem;margin-top:2rem;border-bottom:1px solid #d9e0e7;padding-bottom:.5rem}}.note,.empty{{color:#52606d}}.cards{{display:flex;gap:1rem;flex-wrap:wrap}}.card{{background:#edf2f7;border-radius:6px;padding:1rem;min-width:150px}}.value{{display:block;font-size:1.7rem;font-weight:700}}table{{width:100%;border-collapse:collapse;margin-top:1rem;font-size:.92rem}}th,td{{padding:.55rem;border-bottom:1px solid #e2e8f0;text-align:left}}th{{background:#f7fafc}}svg{{width:100%;height:360px;border:1px solid #d9e0e7;background:#fbfcfd}}.bar{{fill:#276749}}.label{{font:10px system-ui,sans-serif;fill:#334e68}}</style></head>
<body><main><h1>API usage dashboard</h1><p class="note">Window: {html.escape(since)}. Source: SQLite aggregate counters. No headers, bodies, tokens, or identity values are included.</p>
<div class="cards"><div class="card"><span class="value">{total_requests}</span>Total requests</div><div class="card"><span class="value">{len(endpoint_rows)}</span>Endpoints</div><div class="card"><span class="value">{len(bucket_rows)}</span>15-minute buckets</div><div class="card"><span class="value">{len(status_rows)}</span>Status classes</div></div>
<svg id="chart" viewBox="0 0 1060 420" role="img" aria-label="API calls by endpoint and 15-minute bucket"></svg>
<h2>Requests by source</h2>{table(["source_ip", "requests", "endpoints", "latency_ms_total"], source_rows)}
<h2>Requests by endpoint</h2>{table(["endpoint", "requests", "latency_ms_total"], endpoint_rows)}
<h2>Source and endpoint traffic</h2>{table(["source_ip", "endpoint", "requests"], source_endpoint_rows)}
<h2>Source and status traffic</h2>{table(["source_ip", "status_class", "requests"], source_status_rows)}
<h2>Requests by status class</h2>{table(["status_class", "requests"], status_rows)}
<h2>Requests by 15-minute bucket</h2>{table(["bucket_start", "requests"], bucket_rows)}
<h2>Detailed metric rows</h2>{table(["bucket_start", "source_ip", "method", "endpoint", "request_count", "status_class", "latency_ms_total"], rows)}
<script>
const data={chart_json}; const svg=document.getElementById('chart'); const W=1060,H=420,p={{t:25,r:20,b:75,l:52}},pw=W-p.l-p.r,ph=H-p.t-p.b;
const max=Math.max(1,...data.map(d=>d.requests));
if(!data.length){{svg.innerHTML='<text x="530" y="210" text-anchor="middle" class="label">No API counters found in this time window</text>';}}
const barW=data.length?Math.max(2,pw/data.length-2):pw;
data.forEach((d,i)=>{{const x=p.l+i*(pw/data.length)+1,h=d.requests/max*ph,y=p.t+ph-h;const r=document.createElementNS('http://www.w3.org/2000/svg','rect');r.setAttribute('class','bar');r.setAttribute('x',x);r.setAttribute('y',y);r.setAttribute('width',barW);r.setAttribute('height',h);r.setAttribute('title',`${{d.bucket}}: ${{d.requests}} requests`);svg.appendChild(r);if(data.length<=24||i%Math.ceil(data.length/24)===0){{const t=document.createElementNS('http://www.w3.org/2000/svg','text');t.setAttribute('class','label');t.setAttribute('x',x);t.setAttribute('y',H-28);t.textContent=d.bucket.slice(11,16);svg.appendChild(t);}}}});
</script></main></body></html>'''
(report_dir / "index.html").write_text(html_report)
PY

chmod 0640 "${REPORT_DIR}"/*
chmod 0750 "${REPORT_DIR}" "${OUTPUT_DIR}"
REPORT_OBJECTS="$(find "${REPORT_DIR}" -type f | wc -l)"
aws s3 cp "${REPORT_DIR}/" "${S3_ROOT%/}/api/${STAMP}/" --recursive --only-show-errors --sse AES256
find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf -- {} +

echo "Generated API metrics report: ${REPORT_DIR}"
echo "Uploaded API metrics report: ${S3_ROOT%/}/api/${STAMP}/"
echo "Uploaded objects: ${REPORT_OBJECTS}"
