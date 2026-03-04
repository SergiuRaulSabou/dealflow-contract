#!/usr/bin/env bash
set -euo pipefail

PGHOST="${PGHOST:-127.0.0.1}"
PGPORT="${PGPORT:-54329}"
PGUSER="${PGUSER:-postgres}"
PGPASSWORD="${PGPASSWORD:-postgres}"
PGDATABASE="${PGDATABASE:-xero_integration}"
GATE_KEY="${GATE_KEY:-G2}"
DEAL_VERSION_ID="${DEAL_VERSION_ID:-}"
N8N_WEBHOOK_URL="${N8N_WEBHOOK_URL:-}"

export PGPASSWORD

if [[ -z "${DEAL_VERSION_ID}" ]]; then
  echo "Set DEAL_VERSION_ID before running this script."
  echo "Example: DEAL_VERSION_ID=123 bash docs/runbooks/n8n_contract_test_calls.sh"
  exit 1
fi

event_id="contract-proof-$(date +%Y%m%d%H%M%S)"

echo "[1/4] Eligibility check"
psql -X -v ON_ERROR_STOP=1 -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
  -c "SELECT * FROM core.is_send_eligible(${DEAL_VERSION_ID}::bigint, '${GATE_KEY}'::text);"

echo "[2/4] Payload retrieval"
psql -X -v ON_ERROR_STOP=1 -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" \
  -c "SELECT core.get_signwell_payload(${DEAL_VERSION_ID}::bigint, '${GATE_KEY}'::text);"

echo "[3/4] Webhook ingest + replay-safe duplicate"
psql -X -v ON_ERROR_STOP=1 -h "${PGHOST}" -p "${PGPORT}" -U "${PGUSER}" -d "${PGDATABASE}" <<SQL
SELECT core.ingest_signwell_webhook(
  jsonb_build_object(
    'provider_key','SIGNWELL',
    'event_id','${event_id}',
    'event_type','recipient.signed',
    'deal_version_id',${DEAL_VERSION_ID}
  )
);
SELECT core.ingest_signwell_webhook(
  jsonb_build_object(
    'provider_key','SIGNWELL',
    'event_id','${event_id}',
    'event_type','recipient.signed',
    'deal_version_id',${DEAL_VERSION_ID}
  )
);
SQL

echo "[4/4] Optional HTTP simulation against n8n webhook"
if [[ -n "${N8N_WEBHOOK_URL}" ]]; then
  curl -sS -X POST "${N8N_WEBHOOK_URL}" \
    -H 'Content-Type: application/json' \
    -d "{\"provider_key\":\"SIGNWELL\",\"event_id\":\"${event_id}-http\",\"event_type\":\"recipient.signed\",\"deal_version_id\":${DEAL_VERSION_ID}}"
  echo
else
  echo "Skipped HTTP call. Set N8N_WEBHOOK_URL to execute this step."
fi

echo "Contract call proof completed."
