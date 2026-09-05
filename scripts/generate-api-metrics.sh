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
OUTPUT_DIR="${TITTY_API_METRICS_DIR:-/var/lib/titty-backend/api-metrics}"
S3_ROOT="${TITTY_REPORTS_S3_URI:-s3://identitty/reports}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_DIR="${OUTPUT_DIR}/${STAMP}"
JOURNAL_FILE="${REPORT_DIR}/journal.jsonl"

echo "API metrics script version: api-15m-v2"
echo "API metrics S3 destination: ${S3_ROOT%/}/api/${STAMP}/"

if ! command -v journalctl >/dev/null 2>&1; then
  echo "journalctl is required" >&2
  exit 1
fi
if ! command -v python3 >/dev/null 2>&1; then
  echo "python3 is required" >&2
  exit 1
fi
if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required for report upload" >&2
  exit 1
fi

install -d -m 0750 "${REPORT_DIR}"
journalctl -u titty-backend --since "${SINCE}" --output=json --no-pager > "${JOURNAL_FILE}"

python3 - "${JOURNAL_FILE}" "${REPORT_DIR}" "${SINCE}" <<'PY'
import csv
import html
import json
import re
import sys
from collections import defaultdict
from datetime import datetime, timezone
from pathlib import Path

journal_path = Path(sys.argv[1])
report_dir = Path(sys.argv[2])
since = sys.argv[3]

# tower_http emits fields such as method=POST uri=/graphql status=200 in the
# journal message. Keep parsing limited to request traces and never export
# headers, bodies, authorization values, or account identifiers.
method_re = re.compile(r'(?:^|\s|["{,])method(?:=|":)"?([A-Z]+)')
uri_re = re.compile(r'(?:^|\s|["{,])uri(?:=|":)"?([^"\s,}]+)')
status_re = re.compile(r'(?:^|\s|["{,])status(?:=|":)"?(\d{3})')
latency_re = re.compile(r'(?:^|\s|["{,])latency(?:=|":)"?([^"\s,}]+)')

buckets = defaultdict(lambda: {"requests": 0, "status_2xx": 0, "status_4xx": 0, "status_5xx": 0, "latency_ms": 0.0})
skipped = 0
matched = 0

for line in journal_path.read_text(errors="replace").splitlines():
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        skipped += 1
        continue

    message = entry.get("MESSAGE", "")
    search_text = message if isinstance(message, str) else json.dumps(entry, separators=(",", ":"))
    method_match = method_re.search(search_text)
    uri_match = uri_re.search(search_text)
    status_match = status_re.search(search_text)
    if not (method_match and uri_match and status_match):
        continue

    method = method_match.group(1)
    uri = uri_match.group(1).split("?", 1)[0]
    status = int(status_match.group(1))
    if uri not in {"/graphql", "/healthz"}:
        continue

    matched += 1

    timestamp_us = int(entry.get("__REALTIME_TIMESTAMP", "0"))
    if timestamp_us <= 0:
        continue
    timestamp = datetime.fromtimestamp(timestamp_us / 1_000_000, tz=timezone.utc)
    bucket_minute = (timestamp.minute // 15) * 15
    bucket = timestamp.replace(minute=bucket_minute, second=0, microsecond=0)
    key = (bucket.isoformat().replace("+00:00", "Z"), method, uri)
    item = buckets[key]
    item["requests"] += 1
    if 200 <= status < 300:
        item["status_2xx"] += 1
    elif 400 <= status < 500:
        item["status_4xx"] += 1
    elif status >= 500:
        item["status_5xx"] += 1

    latency_match = latency_re.search(search_text)
    if latency_match:
        value = latency_match.group(1).lower()
        try:
            if value.endswith("ms"):
                item["latency_ms"] += float(value[:-2])
            elif value.endswith("µs") or value.endswith("us"):
                item["latency_ms"] += float(value.rstrip("µs")) / 1000
            elif value.endswith("s"):
                item["latency_ms"] += float(value[:-1]) * 1000
        except ValueError:
            pass

csv_path = report_dir / "api-calls-by-15-minutes.csv"
with csv_path.open("w", newline="") as output:
    writer = csv.writer(output)
    writer.writerow(["bucket_utc", "method", "endpoint", "requests", "status_2xx", "status_4xx", "status_5xx", "latency_ms_total"])
    for key in sorted(buckets):
        item = buckets[key]
        writer.writerow([key[0], key[1], key[2], item["requests"], item["status_2xx"], item["status_4xx"], item["status_5xx"], round(item["latency_ms"], 3)])

chart_rows = []
for key in sorted(buckets):
    item = buckets[key]
    chart_rows.append({"bucket": key[0], "method": key[1], "endpoint": key[2], "requests": item["requests"]})

summary = {
    "since": since,
    "generated_utc": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
    "request_rows": sum(item["requests"] for item in buckets.values()),
    "buckets": len(buckets),
    "matched_requests": matched,
    "skipped_journal_lines": skipped,
}
(report_dir / "summary.json").write_text(json.dumps(summary, indent=2) + "\n")
chart_json = json.dumps(chart_rows, separators=(",", ":"))

html_report = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>tiTTY API calls</title>
<style>body{{font:16px system-ui,sans-serif;max-width:1100px;margin:2rem auto;padding:0 1rem;color:#18212b;background:#f5f7f9}}main{{background:#fff;border:1px solid #d9e0e7;border-radius:8px;padding:1.5rem}}h1{{font-size:1.4rem}}svg{{width:100%;height:420px;border:1px solid #d9e0e7;background:#fbfcfd}}.bar{{opacity:.85}}.label{{font:10px system-ui,sans-serif;fill:#334e68}}.note{{color:#52606d}}</style></head>
<body><main><h1>API calls by 15-minute UTC bucket</h1><p class="note">Window: {html.escape(since)}. Rows are derived from backend request traces. No headers, bodies, tokens, or identity values are included.</p>
<svg id="chart" viewBox="0 0 1060 420" role="img" aria-label="API calls by endpoint and 15-minute bucket"></svg>
<script>
const data={chart_json}; const svg=document.getElementById('chart'); const W=1060,H=420,p={{t:25,r:20,b:75,l:52}},pw=W-p.l-p.r,ph=H-p.t-p.b;
const max=Math.max(1,...data.map(d=>d.requests)); const colors={{'/graphql':'#276749','/healthz':'#2b6cb0'}};
if(!data.length){{svg.innerHTML='<text x="530" y="210" text-anchor="middle" class="label">No matching request traces found</text>';}}
const barW=data.length?Math.max(2,pw/data.length-2):pw;
data.forEach((d,i)=>{{const x=p.l+i*(pw/data.length)+1,h=d.requests/max*ph,y=p.t+ph-h;const r=document.createElementNS('http://www.w3.org/2000/svg','rect');r.setAttribute('class','bar');r.setAttribute('x',x);r.setAttribute('y',y);r.setAttribute('width',barW);r.setAttribute('height',h);r.setAttribute('fill',colors[d.endpoint]||'#718096');r.setAttribute('title',`${{d.bucket}} ${{d.method}} ${{d.endpoint}}: ${{d.requests}}`);svg.appendChild(r);if(data.length<=24||i%Math.ceil(data.length/24)===0){{const t=document.createElementNS('http://www.w3.org/2000/svg','text');t.setAttribute('class','label');t.setAttribute('x',x);t.setAttribute('y',H-28);t.textContent=d.bucket.slice(11,16);svg.appendChild(t);}}}});
</script></main></body></html>'''
(report_dir / "index.html").write_text(html_report)
PY

rm -f "${JOURNAL_FILE}"
ln -sfn "${REPORT_DIR}" "${OUTPUT_DIR}/latest"
chmod 0640 "${REPORT_DIR}"/*
chmod 0750 "${REPORT_DIR}" "${OUTPUT_DIR}"

REPORT_OBJECTS="$(find "${REPORT_DIR}" -type f | wc -l)"
if [[ "${REPORT_OBJECTS}" -eq 0 ]]; then
    echo "No report files were generated; refusing to upload." >&2
    exit 1
fi

aws s3 cp "${REPORT_DIR}/" "${S3_ROOT%/}/api/${STAMP}/" \
    --recursive --only-show-errors --sse AES256

find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf -- {} +

echo "Generated API metrics report: ${REPORT_DIR}"
echo "Uploaded API metrics report: ${S3_ROOT%/}/api/${STAMP}/"
echo "Uploaded objects: ${REPORT_OBJECTS}"
echo "Matched request rows: $(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["matched_requests"])' "${REPORT_DIR}/summary.json")"
