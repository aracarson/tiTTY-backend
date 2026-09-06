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

SQL_SINCE="$(date -u -d "${SINCE}" '+%Y-%m-%dT%H:%M:%SZ')"
sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT bucket_start, method, endpoint, request_count, status_class, ROUND(latency_ms_total, 3) AS latency_ms_total FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}' ORDER BY bucket_start, endpoint, method, status_class;" \
  > "${REPORT_DIR}/api-calls-by-15-minutes.csv"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT COALESCE(SUM(request_count), 0) AS total_requests, COUNT(DISTINCT bucket_start) AS buckets, MIN(bucket_start) AS first_bucket, MAX(bucket_start) AS latest_bucket FROM api_request_metrics WHERE bucket_start >= '${SQL_SINCE}';" \
  > "${REPORT_DIR}/summary.csv"

python3 - "${REPORT_DIR}/api-calls-by-15-minutes.csv" "${REPORT_DIR}" "${SINCE}" <<'PY'
import csv
import html
import json
import sys
from pathlib import Path

csv_path = Path(sys.argv[1])
report_dir = Path(sys.argv[2])
since = sys.argv[3]
rows = []
with csv_path.open(newline="") as source:
    for row in csv.DictReader(source):
        rows.append({
            "bucket": row["bucket_start"],
            "method": row["method"],
            "endpoint": row["endpoint"],
            "status_class": int(row["status_class"]),
            "requests": int(row["request_count"]),
            "latency_ms_total": float(row["latency_ms_total"]),
        })

(report_dir / "summary.json").write_text(json.dumps({
    "since": since,
    "generated_utc": __import__("datetime").datetime.now(__import__("datetime").timezone.utc).isoformat(),
    "total_requests": sum(row["requests"] for row in rows),
    "metric_rows": len(rows),
}, indent=2) + "\n")

chart_json = json.dumps(rows, separators=(",", ":"))
html_report = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>tiTTY API calls</title>
<style>body{{font:16px system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#18212b;background:#f5f7f9}}main{{background:#fff;border:1px solid #d9e0e7;border-radius:8px;padding:1.5rem}}h1{{font-size:1.4rem}}svg{{width:100%;height:420px;border:1px solid #d9e0e7;background:#fbfcfd}}.bar{{opacity:.85}}.label{{font:10px system-ui,sans-serif;fill:#334e68}}.note{{color:#52606d}}</style></head>
<body><main><h1>API calls by 15-minute UTC bucket</h1><p class="note">Window: {html.escape(since)}. Data comes from SQLite request counters; no headers, bodies, tokens, or identity values are included.</p>
<svg id="chart" viewBox="0 0 1060 420" role="img" aria-label="API calls by endpoint and 15-minute bucket"></svg>
<script>
const data={chart_json}; const svg=document.getElementById('chart'); const W=1060,H=420,p={{t:25,r:20,b:75,l:52}},pw=W-p.l-p.r,ph=H-p.t-p.b;
const max=Math.max(1,...data.map(d=>d.requests)); const colors={{'/graphql':'#276749','/healthz':'#2b6cb0'}};
if(!data.length){{svg.innerHTML='<text x="530" y="210" text-anchor="middle" class="label">No API counters found in this time window</text>';}}
const barW=data.length?Math.max(2,pw/data.length-2):pw;
data.forEach((d,i)=>{{const x=p.l+i*(pw/data.length)+1,h=d.requests/max*ph,y=p.t+ph-h;const r=document.createElementNS('http://www.w3.org/2000/svg','rect');r.setAttribute('class','bar');r.setAttribute('x',x);r.setAttribute('y',y);r.setAttribute('width',barW);r.setAttribute('height',h);r.setAttribute('fill',colors[d.endpoint]||'#718096');r.setAttribute('title',`${{d.bucket}} ${{d.method}} ${{d.endpoint}} status ${{d.status_class}}xx: ${{d.requests}}`);svg.appendChild(r);if(data.length<=24||i%Math.ceil(data.length/24)===0){{const t=document.createElementNS('http://www.w3.org/2000/svg','text');t.setAttribute('class','label');t.setAttribute('x',x);t.setAttribute('y',H-28);t.textContent=d.bucket.slice(11,16);svg.appendChild(t);}}}});
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
