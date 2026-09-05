#!/usr/bin/env bash
set -euo pipefail

if [[ "${EUID}" -ne 0 ]]; then
  echo "Run as root: sudo bash scripts/generate-metrics.sh" >&2
  exit 1
fi

ENV_FILE="/etc/titty-backend/titty-backend.env"
if [[ -r "${ENV_FILE}" ]]; then
  # The deployment environment is root-owned and contains the backup URI.
  source "${ENV_FILE}"
fi

DATABASE_PATH="${TITTY_DATABASE_PATH:-/var/lib/titty-backend/identity.db}"
OUTPUT_DIR="${TITTY_METRICS_DIR:-/var/lib/titty-backend/metrics}"
S3_ROOT="${TITTY_REPORTS_S3_URI:-s3://identitty/reports}"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
REPORT_DIR="${OUTPUT_DIR}/${STAMP}"

if [[ ! -r "${DATABASE_PATH}" ]]; then
  echo "Database is not readable: ${DATABASE_PATH}" >&2
  exit 1
fi

if ! command -v sqlite3 >/dev/null 2>&1; then
  echo "sqlite3 is required" >&2
  exit 1
fi

if ! command -v aws >/dev/null 2>&1; then
  echo "aws CLI is required for report upload" >&2
  exit 1
fi

install -d -m 0750 "${REPORT_DIR}"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT date(created_at) AS registration_date, COUNT(*) AS registrations FROM accounts GROUP BY date(created_at) ORDER BY registration_date;" \
  > "${REPORT_DIR}/registrations-by-day.csv"

sqlite3 -header -csv "${DATABASE_PATH}" \
  "SELECT COUNT(*) AS registered_accounts, MIN(created_at) AS first_registration, MAX(created_at) AS latest_registration FROM accounts;" \
  > "${REPORT_DIR}/summary.csv"

sqlite3 "${DATABASE_PATH}" \
  "SELECT COUNT(*) || ' registered accounts' || char(10) || COALESCE('First registration: ' || MIN(created_at) || char(10), '') || COALESCE('Latest registration: ' || MAX(created_at), '') FROM accounts;" \
  > "${REPORT_DIR}/summary.txt"

DATA_JSON="["
first_row=true
while IFS=, read -r registration_date registration_count; do
  if [[ "${first_row}" == true ]]; then
    first_row=false
  else
    DATA_JSON+=","
  fi
  DATA_JSON+="{\"date\":\"${registration_date}\",\"count\":${registration_count}}"
done < <(sqlite3 -csv -noheader "${DATABASE_PATH}" \
  "SELECT date(created_at), COUNT(*) FROM accounts GROUP BY date(created_at) ORDER BY date(created_at);")
DATA_JSON+="]"
TOTAL="$(sqlite3 "${DATABASE_PATH}" "SELECT COUNT(*) FROM accounts;")"

cat > "${REPORT_DIR}/index.html" <<EOF
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>tiTTY registration metrics ${STAMP}</title>
<style>
body{font:16px system-ui,sans-serif;max-width:1000px;margin:2rem auto;padding:0 1rem;color:#18212b;background:#f5f7f9}
main{background:white;border:1px solid #d9e0e7;padding:1.5rem;border-radius:8px}
h1{font-size:1.4rem}.summary{font-size:1.8rem;font-weight:700;margin:1rem 0}svg{width:100%;height:320px;border:1px solid #d9e0e7;background:#fbfcfd}.bar{fill:#276749}.label{font:11px system-ui,sans-serif;fill:#334e68}.note{color:#52606d}
</style>
</head>
<body><main>
<h1>tiTTY registrations</h1>
<div class="summary">${TOTAL} registered accounts</div>
<p class="note">Generated ${STAMP} UTC. This report contains aggregate counts only; it does not expose identiTTY values, AccountIDs, or public keys.</p>
<svg id="chart" viewBox="0 0 960 320" role="img" aria-label="Registrations by day"></svg>
<script>
const data=${DATA_JSON};
const svg=document.getElementById('chart');
const width=960,height=320,pad={top:24,right:20,bottom:58,left:48};
const plotW=width-pad.left-pad.right,plotH=height-pad.top-pad.bottom;
const max=Math.max(1,...data.map(d=>d.count));
const barW=data.length?Math.max(2,plotW/data.length-4):plotW;
svg.innerHTML='';
if(!data.length){svg.innerHTML='<text x="480" y="160" text-anchor="middle" class="label">No registrations yet</text>';}
for(let i=0;i<data.length;i++){
 const d=data[i],x=pad.left+i*(plotW/data.length)+2,h=(d.count/max)*plotH,y=pad.top+plotH-h;
 const bar=document.createElementNS('http://www.w3.org/2000/svg','rect');
 bar.setAttribute('class','bar');bar.setAttribute('x',x);bar.setAttribute('y',y);bar.setAttribute('width',barW);bar.setAttribute('height',h);bar.setAttribute('title',d.date+': '+d.count);svg.appendChild(bar);
 if(data.length<=14||i%Math.ceil(data.length/14)===0){const label=document.createElementNS('http://www.w3.org/2000/svg','text');label.setAttribute('class','label');label.setAttribute('x',x);label.setAttribute('y',height-22);label.textContent=d.date;svg.appendChild(label);}
}
</script>
</main></body></html>
EOF

ln -sfn "${REPORT_DIR}" "${OUTPUT_DIR}/latest"
chmod 0640 "${REPORT_DIR}"/*
chmod 0750 "${REPORT_DIR}" "${OUTPUT_DIR}"

aws s3 cp "${REPORT_DIR}/" "${S3_ROOT%/}/metrics/${STAMP}/" \
  --recursive --only-show-errors --sse AES256

find "${OUTPUT_DIR}" -mindepth 1 -maxdepth 1 -type d -mtime +14 -exec rm -rf -- {} +

echo "Generated metrics report: ${REPORT_DIR}"
echo "Uploaded metrics report: ${S3_ROOT%/}/metrics/${STAMP}/"
echo "Open ${REPORT_DIR}/index.html locally after copying it from the instance."
