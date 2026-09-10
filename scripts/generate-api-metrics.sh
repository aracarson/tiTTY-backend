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
GEOIP_DATABASE_PATH="${TITTY_GEOIP_DATABASE_PATH:-/var/lib/GeoIP/GeoLite2-City.mmdb}"
API_LOG_DIR="${TITTY_API_LOG_DIR:-/var/log/titty-backend}"
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

python3 - "${API_LOG_DIR}" "${SQL_SINCE}" "${REPORT_DIR}/graphql-request-bodies.jsonl" <<'PY'
import json
import sys
from datetime import datetime, timezone
from pathlib import Path

log_dir = Path(sys.argv[1])
since_text = sys.argv[2]
output_path = Path(sys.argv[3])

since = datetime.fromisoformat(since_text.replace("Z", "+00:00"))
api_events = {}
body_events = []

def event_time(value):
  if not isinstance(value, str):
    return None
  try:
    parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
  except ValueError:
    return None
  return parsed if parsed.tzinfo else parsed.replace(tzinfo=timezone.utc)

if log_dir.is_dir():
  for log_path in sorted(log_dir.glob("api-access.jsonl*")):
    try:
      source = log_path.open(encoding="utf-8")
    except OSError:
      continue
    with source:
      for line in source:
        try:
          record = json.loads(line)
        except json.JSONDecodeError:
          continue
        fields = record.get("fields")
        if not isinstance(fields, dict):
          fields = record
        timestamp = event_time(record.get("timestamp") or fields.get("timestamp"))
        if timestamp is None or timestamp < since:
          continue
        request_id = fields.get("request_id")
        if not request_id:
          continue
        if fields.get("event") == "api_request":
          api_events[request_id] = {**record, **fields}
        elif fields.get("event") == "graphql_request_body":
          body_events.append({**record, **fields})

with output_path.open("w", encoding="utf-8") as output:
  for body_event in body_events:
    request_id = body_event.get("request_id")
    api_event = api_events.get(request_id, {})
    report = {
      "timestamp": body_event.get("timestamp"),
      "request_id": request_id,
      "request_url": body_event.get("request_url", api_event.get("request_url")),
      "source_ip": body_event.get("source_ip", api_event.get("source_ip", "unknown")),
      "method": body_event.get("method", api_event.get("method", "POST")),
      "endpoint": body_event.get("endpoint", api_event.get("endpoint", "/graphql")),
      "status": body_event.get("status", api_event.get("status")),
      "latency_ms": body_event.get("latency_ms", api_event.get("latency_ms")),
      "body": body_event.get("body", ""),
    }
    output.write(json.dumps(report, separators=(",", ":")) + "\n")
PY

python3 - "${REPORT_DIR}" "${SINCE}" "${GEOIP_DATABASE_PATH}" <<'PY'
import csv
import html
import json
import math
import sys
from pathlib import Path

report_dir = Path(sys.argv[1])
since = sys.argv[2]
geoip_database_path = Path(sys.argv[3])

try:
  import geoip2.database
except ImportError:
  geoip2 = None
else:
  geoip2 = geoip2.database

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

graphql_body_rows = []
graphql_body_path = report_dir / "graphql-request-bodies.jsonl"
if graphql_body_path.is_file():
  with graphql_body_path.open(encoding="utf-8") as source:
    for line in source:
      try:
        graphql_body_rows.append(json.loads(line))
      except json.JSONDecodeError:
        continue

for row in rows:
  row["requests"] = int(row["request_count"])
  row["status_class"] = int(row["status_class"])
  row["latency_ms_total"] = float(row["latency_ms_total"])
for row in endpoint_rows + bucket_rows + status_rows + source_rows + source_endpoint_rows + source_status_rows:
  row["requests"] = int(row["requests"])

geo_by_source = {}
geoip_error = ""
geoip_lookup_errors = {}
geoip_sources_seen = len({row["source_ip"] for row in rows if row["source_ip"] not in {"", "unknown"}})
geoip_sources_without_coordinates = 0
if geoip2 is None:
  geoip_error = "Python package geoip2 is not installed"
elif not geoip_database_path.is_file():
  geoip_error = f"GeoIP database not found: {geoip_database_path}"
else:
  try:
    with geoip2.Reader(str(geoip_database_path)) as reader:
      for source in {row["source_ip"] for row in rows}:
        if source in {"", "unknown"}:
          continue
        try:
          city = reader.city(source)
          latitude = city.location.latitude
          longitude = city.location.longitude
          if latitude is None or longitude is None:
            geoip_sources_without_coordinates += 1
            continue
          geo_by_source[source] = {
            "country": city.country.name or "Unknown",
            "country_code": city.country.iso_code or "",
            "region": city.subdivisions.most_specific.name or "Unknown",
            "city": city.city.name or "Unknown",
            "latitude": latitude,
            "longitude": longitude,
            "timezone": city.location.time_zone or "Unknown",
          }
        except Exception as error:
          error_name = type(error).__name__
          geoip_lookup_errors[error_name] = geoip_lookup_errors.get(error_name, 0) + 1
          continue
  except Exception as error:
    geoip_error = f"Could not read GeoIP database: {error}"

for row in rows:
  row["geo"] = geo_by_source.get(row["source_ip"])

map_cells = {}
for row in rows:
  geo = row["geo"]
  if not geo:
    continue
  cell_key = (round(geo["latitude"], 1), round(geo["longitude"], 1))
  cell = map_cells.setdefault(cell_key, {
    "latitude": cell_key[0],
    "longitude": cell_key[1],
    "requests": 0,
    "sources": set(),
    "endpoints": set(),
    "countries": set(),
  })
  cell["requests"] += row["requests"]
  cell["sources"].add(row["source_ip"])
  cell["endpoints"].add(row["endpoint"])
  cell["countries"].add(geo["country"])

map_points = []
for cell in map_cells.values():
  map_points.append({
    "latitude": cell["latitude"],
    "longitude": cell["longitude"],
    "requests": cell["requests"],
    "source_count": len(cell["sources"]),
    "endpoint_count": len(cell["endpoints"]),
    "countries": sorted(cell["countries"]),
  })
map_points.sort(key=lambda point: point["requests"], reverse=True)
geoip_diagnostics = {
  "sources_seen": geoip_sources_seen,
  "sources_geolocated": len(geo_by_source),
  "sources_without_coordinates": geoip_sources_without_coordinates,
  "lookup_errors": geoip_lookup_errors,
}

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

body_sections = []
for index, record in enumerate(graphql_body_rows, start=1):
  raw_body = record.get("body", "")
  try:
    formatted_body = json.dumps(json.loads(raw_body), indent=2, ensure_ascii=False)
  except (TypeError, json.JSONDecodeError):
    formatted_body = str(raw_body)
  metadata = table(
    ["timestamp", "request_id", "request_url", "source_ip", "status", "latency_ms"],
    [{key: record.get(key, "") for key in ["timestamp", "request_id", "request_url", "source_ip", "status", "latency_ms"]}],
  )
  body_sections.append(
    f'<details><summary>Request {index}: {html.escape(str(record.get("timestamp", "unknown")))} '
    f'({html.escape(str(record.get("request_id", "unknown")))})</summary>'
    f'{metadata}<pre>{html.escape(formatted_body)}</pre></details>'
  )
if not body_sections:
  body_sections.append('<p class="empty">No GraphQL body events were found in this report window. Enable TITTY_LOG_GRAPHQL_BODY before making requests.</p>')

body_controls = '' if not graphql_body_rows else '''<div class="controls">
<button type="button" onclick="setAllRequests(true)">Expand all</button>
<button type="button" onclick="setAllRequests(false)">Collapse all</button>
</div>'''

graphql_body_html = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1">
<title>tiTTY GraphQL request bodies</title>
<style>body{{font:15px system-ui,sans-serif;max-width:1400px;margin:2rem auto;padding:0 1rem;color:#18212b;background:#f5f7f9}}main{{background:#fff;border:1px solid #d9e0e7;border-radius:8px;padding:1.5rem}}h1{{font-size:1.5rem}}h2{{font-size:1.05rem;margin-top:2rem;border-bottom:1px solid #d9e0e7;padding-bottom:.5rem}}.note,.empty{{color:#52606d}}.controls{{display:flex;gap:.5rem;margin:1rem 0;flex-wrap:wrap}}button{{border:1px solid #9aa9b8;border-radius:5px;background:#fff;color:#18212b;padding:.55rem .8rem;cursor:pointer}}button:hover{{background:#edf2f7}}details{{border:1px solid #d9e0e7;border-radius:6px;margin:1rem 0;padding:.75rem;background:#fbfcfd}}summary{{cursor:pointer;font-weight:600}}table{{width:100%;border-collapse:collapse;margin-top:1rem;font-size:.88rem;overflow-wrap:anywhere}}th,td{{padding:.5rem;border-bottom:1px solid #e2e8f0;text-align:left;vertical-align:top}}th{{background:#f7fafc;white-space:nowrap}}pre{{white-space:pre-wrap;overflow-wrap:anywhere;background:#18212b;color:#f7fafc;border-radius:5px;padding:1rem;overflow:auto}}</style></head>
<body><main><h1>GraphQL request bodies</h1><p class="note">Window: {html.escape(since)}. Full bodies are shown because TITTY_LOG_GRAPHQL_BODY was enabled. This is a private report and may contain sensitive client data.</p>
<div><strong>{len(graphql_body_rows)}</strong> GraphQL body event(s)</div><h2>Requests</h2>{body_controls}{''.join(body_sections)}
<script>function setAllRequests(open){{document.querySelectorAll('details').forEach(function(section){{section.open=open;}});}}</script>
</main></body></html>'''
(report_dir / "graphql-request-bodies.html").write_text(graphql_body_html)

map_json = json.dumps({
  "since": since,
  "generated_utc": summary["generated_utc"],
  "geoip_database": str(geoip_database_path),
  "geoip_error": geoip_error,
  "geoip_diagnostics": geoip_diagnostics,
  "points": map_points,
}, separators=(",", ":"))
detail_rows = []
for row in rows:
  geo = row["geo"] or {}
  detail_rows.append({
    "bucket_start": row["bucket_start"],
    "source_ip": row["source_ip"],
    "method": row["method"],
    "endpoint": row["endpoint"],
    "requests": row["requests"],
    "status_class": f"{row['status_class']}xx",
    "latency_ms_total": row["latency_ms_total"],
    "country": geo.get("country", "Unknown"),
    "region": geo.get("region", "Unknown"),
    "city": geo.get("city", "Unknown"),
    "latitude": geo.get("latitude", ""),
    "longitude": geo.get("longitude", ""),
  })
detail_json = json.dumps(detail_rows, separators=(",", ":"))
if geoip_error:
  map_note = html.escape(geoip_error)
else:
  map_note = html.escape(
    f"{geoip_diagnostics['sources_geolocated']} of {geoip_diagnostics['sources_seen']} public source IPs geolocated; "
    f"{geoip_diagnostics['sources_without_coordinates']} had no coordinates; "
    f"{sum(geoip_lookup_errors.values())} lookup errors. Coordinates are approximate and grouped into 0.1 degree cells."
  )
map_html = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="origin">
<title>tiTTY API source map</title>
<link rel="stylesheet" href="https://unpkg.com/leaflet@1.9.4/dist/leaflet.css">
<style>body{{font:15px system-ui,sans-serif;margin:0;color:#18212b;background:#f5f7f9}}main{{max-width:1500px;margin:0 auto;padding:1rem}}h1{{font-size:1.5rem}}h2{{font-size:1.05rem;margin-top:1.5rem}}.note{{color:#52606d}}#map{{height:620px;border:1px solid #cbd5e0;background:#dbeafe}}table{{width:100%;border-collapse:collapse;background:#fff;font-size:.85rem}}th,td{{padding:.45rem;border-bottom:1px solid #e2e8f0;text-align:left;white-space:nowrap}}th{{position:sticky;top:0;background:#edf2f7}}.table-wrap{{max-height:600px;overflow:auto;border:1px solid #d9e0e7}}.warning{{color:#9b2c2c;font-weight:600}}</style></head>
<body><main><h1>API source map</h1><p class="note">Window: {html.escape(since)}. Each circle is an approximate location cell; larger circles represent more aggregated requests. Exact source IPs are included because this is an operator-only report. Open this file through a local HTTP server rather than using a <code>file://</code> URL so map tiles receive a valid referrer.</p><p class="{'warning' if geoip_error else 'note'}">{map_note}</p>
<div id="map" role="img" aria-label="Map of API request source locations"></div>
<h2>All source and endpoint records</h2><div class="table-wrap"><table><thead><tr><th>bucket_start</th><th>source_ip</th><th>method</th><th>endpoint</th><th>requests</th><th>status_class</th><th>latency_ms_total</th><th>country</th><th>region</th><th>city</th><th>latitude</th><th>longitude</th></tr></thead><tbody id="details"></tbody></table></div></main>
<script src="https://unpkg.com/leaflet@1.9.4/dist/leaflet.js"></script>
<script>
const points={map_json};
const details={detail_json};
const map=L.map('map').setView([20,0],2);
L.tileLayer('https://{{s}}.tile.openstreetmap.org/{{z}}/{{x}}/{{y}}.png',{{maxZoom:18,attribution:'&copy; OpenStreetMap contributors'}}).addTo(map);
const maxRequests=Math.max(1,...points.points.map(point=>point.requests));
points.points.forEach(point=>{{
  const radius=8+Math.sqrt(point.requests/maxRequests)*42;
  const marker=L.circle([point.latitude,point.longitude],{{radius:radius*10000,color:'#9b2c2c',fillColor:'#e53e3e',fillOpacity:.55,weight:1}}).addTo(map);
  marker.bindPopup(`<strong>${{point.requests.toLocaleString()}} requests</strong><br>${{point.source_count}} source(s), ${{point.endpoint_count}} endpoint(s)<br>${{point.countries.join(', ')}}`);
}});
const body=document.getElementById('details');
details.forEach(row=>{{const tr=document.createElement('tr');['bucket_start','source_ip','method','endpoint','requests','status_class','latency_ms_total','country','region','city','latitude','longitude'].forEach(key=>{{const td=document.createElement('td');td.textContent=row[key];tr.appendChild(td);}});body.appendChild(tr);}});
</script></body></html>'''
(report_dir / "api-source-map.html").write_text(map_html)
PY

chmod 0640 "${REPORT_DIR}"/*
chmod 0750 "${REPORT_DIR}" "${OUTPUT_DIR}"
REPORT_OBJECTS="$(find "${REPORT_DIR}" -type f | wc -l)"
aws s3 cp "${REPORT_DIR}/" "${S3_ROOT%/}/api/${STAMP}/" --recursive --only-show-errors --sse AES256
find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf -- {} +

echo "Generated API metrics report: ${REPORT_DIR}"
echo "Generated API source map: ${REPORT_DIR}/api-source-map.html"
echo "Uploaded API metrics report: ${S3_ROOT%/}/api/${STAMP}/"
echo "Uploaded objects: ${REPORT_OBJECTS}"
