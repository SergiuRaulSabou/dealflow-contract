# Runbook

## Purpose
This runbook is the operational path for deterministic acceptance of the DB-as-contract workflow through Milestones `0.5` to `5`, plus post-milestone gap-closure checks.

## Prerequisites
- Podman + `podman compose`
- PostgreSQL client (`psql`)
- Flyway CLI (optional if using `make` targets)
- Local repo root as working directory

## Start / Stop
```bash
make up
make ps
make down
```

## Full Bootstrap (All Implemented Milestones)
```bash
make reset
```

## Milestone Acceptance Packs (Make)
- Milestone 1: `make reset_1`
- Milestone 0.5 + 1: `make reset_0_5_1`
- Milestone 2: `make reset_2`
- Milestone 3: `make reset_3`
- Milestone 4: `make reset_4`
- Milestone 5: `make reset_5`

Each target enforces the deterministic boundary flow:
1. Clean DB
2. Migrate to milestone boundary
3. Seed (if required)
4. Run verify pack

## Flyway Boundary Runs
### Structural migrations
```bash
flyway -configFiles=flyway.conf info
flyway -configFiles=flyway.conf migrate
```

### Seed migrations
```bash
flyway -configFiles=flyway.seed.conf info
flyway -configFiles=flyway.seed.conf migrate
```

### Targeted structural boundary examples
```bash
# Milestone 3 boundary (V001..V004)
flyway -configFiles=flyway.conf -target=4 migrate

# Milestone 4 boundary (V001..V005)
flyway -configFiles=flyway.conf -target=5 migrate

# Milestone 5 boundary (V001..V006)
flyway -configFiles=flyway.conf -target=6 migrate
```

Then run corresponding verify packs:
```bash
make verify_3
make verify_4
make verify_5
```

## n8n Wiring (Glue-Only Contract)
### Node-to-DB Mapping
| Workflow | Node | DB Contract Call | Required Input | Output Used by Next Node | Failure / Retry Rule |
|---|---|---|---|---|---|
| Outbound | `DB Eligibility` | `core.is_send_eligible(deal_version_id, gate_key)` | `deal_version_id`, `gate_key` | `is_eligible`, `reason` | If call fails, workflow fails and can be retried safely |
| Outbound | `DB Payload` | `core.get_signwell_payload(deal_version_id, gate_key)` | `deal_version_id`, `gate_key` | `payload` JSON | Deterministic for unchanged version |
| Outbound | `Send To Signwell` | HTTP POST to Signwell | `payload` JSON, API key secret | `envelope_id`, provider response | Retries must preserve dedupe behavior |
| Outbound | `Record Envelope` | `core.record_signwell_envelope(...)` | `deal_version_id`, `gate_key`, `envelope_id`, `dedupe_key`, `actor_identity_id` | persisted envelope mapping | Safe if retried with same envelope |
| Inbound | `DB Ingest` | `core.ingest_signwell_webhook(payload_jsonb)` | full webhook payload JSON (with `event_id`) | DB state transition + audit row | Replay-safe by dedupe key (`event_id`) |

### Outbound (Send to Signwell)
1. Check eligibility: `core.is_send_eligible(deal_version_id, gate_key)`
2. Build payload: `core.get_signwell_payload(deal_version_id, gate_key)`
3. Send payload to Signwell HTTP API
4. Persist envelope mapping: `core.record_signwell_envelope(...)`

Required outbound payload keys from DB response:
- `template_id`
- `deal_version_id`
- `gate_key`
- `fields`
- `recipients`
- `metadata`

### Inbound (Webhook)
1. Receive webhook payload in n8n webhook node
2. Forward payload directly to `core.ingest_signwell_webhook(payload_jsonb)`
3. Do not add business logic in n8n; retries are safe via DB idempotency

Minimum inbound webhook keys expected by DB:
- `provider_key`
- `event_id`
- `event_type`
- `deal_version_id` (or resolvable `envelope_id`)
- `envelope_id` (recommended for status reconciliation)

## Secrets
- Signwell API key: n8n credential store / secret manager
- DB credentials: environment variables (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`)
- Recommended environment keys for n8n:
  - `SIGNWELL_API_URL`
  - `SIGNWELL_API_KEY`
  - `PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, `PGDATABASE`

## Repeatable Integration Calls (n8n-Compatible Proof)
Use the repeatable helper script:

```bash
bash docs/runbooks/n8n_contract_test_calls.sh
```

Manual equivalents:

```bash
# Outbound eligibility + payload retrieval via DB
psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 54329 -U postgres -d xero_integration -c "SELECT * FROM core.is_send_eligible(<deal_version_id>, 'G2');"
psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 54329 -U postgres -d xero_integration -c "SELECT core.get_signwell_payload(<deal_version_id>, 'G2');"

# Inbound webhook replay-safe call
psql -X -v ON_ERROR_STOP=1 -h 127.0.0.1 -p 54329 -U postgres -d xero_integration -c "SELECT core.ingest_signwell_webhook('{\"provider_key\":\"SIGNWELL\",\"event_id\":\"demo-event-1\",\"event_type\":\"recipient.signed\"}'::jsonb);"

# Optional HTTP simulation of n8n inbound endpoint
curl -X POST http://localhost:5678/webhook/signwell/webhook \
  -H 'Content-Type: application/json' \
  -d '{"provider_key":"SIGNWELL","event_id":"demo-event-1","event_type":"recipient.signed"}'
```

## Gap-Closure Verify Pack
```bash
make verify_gap
```

## Failure Handling
- If verify fails, do not patch data manually.
- Fix migration/seed/contract code and re-run from clean boundary (`make reset_*`).
- For webhook retries, re-sending identical `event_id` is expected and safe.
