# dealflow-contract

## What This System Is
This project defines a **database-first deal workflow** that runs through Gates `G0` to `G3`:

1. `G0` Draft capture in `ops.*` tables
2. Promotion to immutable snapshot in `core.*`
3. Internal/external approvals (including Signwell tracking)
4. Deterministic Xero-ready payload preparation (no API posting in Phase 1)

The PostgreSQL database is the **system of record and contract boundary** for:
- validation
- versioning
- approval state
- audit trail
- Signwell integration surfaces

`n8n` is orchestration glue, and `Retool` is the UI layer.

## Core Rules
- Edits happen only in `ops.*`
- Approvals act only on immutable `core.deal_version`
- Resubmissions create a new immutable version
- Audit tables are append-only
- Signwell payloads and webhook ingestion are DB-first and deterministic/idempotent

## Additional Contract Surfaces
Operational UI read models now include:
- `core.v_deal_tracker`
- `core.get_task_list(identity_id)`
- `core.v_finance_review_summary`
- `core.get_payload_bundle(deal_version_id, gate_key)`

Compatibility schema scaffolds from the schema-definition sheets are also materialized in:
- `config.*` compatibility tables (`deal_type`, `deal_type_variant`, `field_dictionary`, `...`)
- `core.*` compatibility tables (`deal_version_property`, `deal_version_invoice_plan`, `deal_version_document`, `deal_version_gate`)
- `raw.*` compatibility tables (`invoice`, `deal_attributes`, `document_flags`, `invoice_commission_allocation`, `invoice_commission_provision`, `ref_person`, `ref_cost_center`)

## Repository Layout
- `docs/`: source requirements and schema-definition documents (`.docx`, `.xlsx`, `reqs.txt`)
- `db/migrations/`: SQL migrations
- `db/seeds/`: baseline seed data (catalogues/rules/templates)
- `db/verify/`: SQL verification harness scripts
- `flyway.conf`: Flyway config for structural migrations (`V*`)
- `flyway.seed.conf`: Flyway config for seed migrations (`S*`)
- `compose.yml`: local Postgres container runtime
- `Makefile`: local run/test commands for migration verification
- `.env.example`: local environment defaults

## Language and Technology Requirements
Based on the requirements documents in `docs/`:

- **Required programming language/runtime for core implementation**:  
  - PostgreSQL 14 SQL (including PL/pgSQL functions/triggers)
- **Migration format expected**:  
  - Flyway-style SQL migrations
- **External tools in scope**:  
  - `n8n` for orchestration calls
  - `Retool` for UI/read models
  - Signwell as external approval provider

There is **no mandatory general-purpose application language** (for example Node.js, Python, Java, or Go) specified as a core requirement for this phase.

## Current Status
- Milestones `0.5`, `1`, `2`, `3`, `4`, and `5` are implemented:
  - `db/migrations/V001__schema_skeleton.sql`
  - `db/migrations/V002__proof_slice.sql`
  - `db/migrations/V003__workflow_engine.sql`
  - `db/migrations/V004__signwell_contract.sql`
  - `db/migrations/V005__contract_extensions.sql`
  - `db/migrations/V006__security_permissions.sql`
  - `db/migrations/V007__operational_surfaces_and_compatibility.sql`
  - `db/seeds/S001__baseline_config_seed.sql`
  - `db/seeds/S002__config_extensions.sql`
  - `db/seeds/S003__compatibility_seed.sql`
  - `db/verify/schema_skeleton_verify.sql`
  - `db/verify/seed_verify.sql`
  - `db/verify/proof_slice_verify.sql`
  - `db/verify/workflow_engine_verify.sql`
  - `db/verify/signwell_contract_verify.sql`
  - `db/verify/contract_extensions_verify.sql`
  - `db/verify/security_permissions_verify.sql`
  - `db/verify/operational_surfaces_verify.sql`

## Local Execution (Podman + Make)
This project is now runnable locally with Podman Compose and Make.

1. Optional: create `.env` from `.env.example` to override defaults.
2. Start DB and run migration + verification:

```bash
make bootstrap
```

Useful targets:

```bash
make up
make migrate
make seed
make seed_boundary
make verify
make verify_gap
make down
make reset
```

Default connection values:
- host: `127.0.0.1`
- port: `54329`
- user: `postgres`
- password: `postgres`
- app database: `xero_integration`

Seed files currently used by `make seed`:
- `db/seeds/S001__baseline_config_seed.sql`
- `db/seeds/S002__config_extensions.sql`
- `db/seeds/S003__compatibility_seed.sql`

Boundary milestone runs use `make seed_boundary`, which applies only:
- `db/seeds/S001__baseline_config_seed.sql`
- `db/seeds/S002__config_extensions.sql`

Verification scripts:
- `db/verify/schema_skeleton_verify.sql` (schema/constraints)
- `db/verify/seed_verify.sql` (seed data contract)
- `db/verify/proof_slice_verify.sql` (proof-slice checks + negative tests)
- `db/verify/workflow_engine_verify.sql` (promotion + checklist rules + approval materialization)
- `db/verify/signwell_contract_verify.sql` (send eligibility + payload contract + webhook ingest)
- `db/verify/contract_extensions_verify.sql` (full regression scenarios, resubmission, deterministic payload/lock)
- `db/verify/security_permissions_verify.sql` (RLS/permissions hardening and role boundaries)
- `db/verify/operational_surfaces_verify.sql` (UI read models + payload retrieval + compatibility scaffold checks)

Operational documents and evidence artifacts:
- `docs/runbooks/runbook.md`
- `docs/runbooks/contract_surfaces.md`
- `docs/runbooks/acceptance_traceability.md`
- `docs/runbooks/n8n_contract_test_calls.sh`
- `docs/n8n/signwell_outbound_workflow.json`
- `docs/n8n/signwell_inbound_workflow.json`

## Flyway Runbook
Assumes local DB from `make up` (or any reachable Postgres instance).

1. Run structural migrations (`V*`):

```bash
flyway -configFiles=flyway.conf info
flyway -configFiles=flyway.conf migrate
```

2. Run seed migrations (`S*`):

```bash
flyway -configFiles=flyway.seed.conf info
flyway -configFiles=flyway.seed.conf migrate
```

3. Run verification suite:

```bash
make verify
```

## Boundary Acceptance Runbook
Acceptance is packaged around deterministic boundary commands from a clean DB.

### Milestone 1 (Schema Skeleton)
```bash
make reset_1
```

Equivalent manual boundary flow:
```bash
make up
make migrate_1
make verify_1
```

### Milestone 0.5 + 1 (Proof Slice at target=2)
Milestone `0.5` depends on seeded config catalog/rule data. The deterministic boundary flow is:

```bash
make reset_0_5_1
```

Equivalent manual boundary flow:
```bash
make up
make migrate_0_5_1
make seed_boundary
make verify_0_5_1
```

Equivalent Flyway-targeted boundary flow:
```bash
make up
make create-db
flyway -configFiles=flyway.conf -target=2 migrate
flyway -configFiles=flyway.seed.conf migrate
make verify_0_5_1
```

### Milestone 2 (Workflow Engine at target=3)
Milestone `2` extends promotion invariants with template-driven doc requirements and deterministic approval materialization.

```bash
make reset_2
```

Equivalent manual boundary flow:
```bash
make up
make migrate_2
make seed_boundary
make verify_2
```

Equivalent Flyway-targeted boundary flow:
```bash
make up
make create-db
flyway -configFiles=flyway.conf -target=3 migrate
flyway -configFiles=flyway.seed.conf migrate
make verify_2
```

### Milestone 3 (Signwell Contract Surface at target=4)
Milestone `3` delivers:
- `core.is_send_eligible(...)` and `core.assert_send_eligible(...)`
- `core.get_signwell_payload(...)`
- `core.ingest_signwell_webhook(...)`

```bash
make reset_3
```

Equivalent manual boundary flow:
```bash
make up
make migrate_3
make seed_boundary
make verify_3
```

Equivalent Flyway-targeted boundary flow:
```bash
make up
make create-db
flyway -configFiles=flyway.conf -target=4 migrate
flyway -configFiles=flyway.seed.conf migrate
make verify_3
```

### Milestone 4 (Full Regression Suite at target=5)
Milestone `4` adds and verifies:
- `ops.preview_draft(...)`
- `ops.create_draft_from_deal_version(...)`
- `core.record_gate_decision(...)`
- `core.record_signwell_envelope(...)`
- deterministic `core.get_signwell_payload(...)`
- `core.get_xero_payload(...)` and `core.lock_xero_payload(...)`

```bash
make reset_4
```

Equivalent manual boundary flow:
```bash
make up
make migrate_4
make seed_boundary
make verify_4
```

Equivalent Flyway-targeted boundary flow:
```bash
make up
make create-db
flyway -configFiles=flyway.conf -target=5 migrate
flyway -configFiles=flyway.seed.conf migrate
make verify_4
```

### Milestone 5 (Hardening + Documentation + Handoff at target=6)
Milestone `5` adds and verifies:
- role model + permission boundaries (`app_ops`, `app_finance`, `app_broker`, `app_ui`, `app_system`)
- RLS broker visibility boundaries
- function-level execution controls for contract surfaces
- runbook/handoff docs and n8n wiring artifacts

```bash
make reset_5
```

Equivalent manual boundary flow:
```bash
make up
make migrate_5
make seed_boundary
make verify_5
```

Equivalent Flyway-targeted boundary flow:
```bash
make up
make create-db
flyway -configFiles=flyway.conf -target=6 migrate
flyway -configFiles=flyway.seed.conf migrate
make verify_5
```

Notes:
- `make bootstrap` / `make reset` runs all implemented milestones (including Milestones 4 and 5).
- Boundary acceptance commands (`reset_1`, `reset_0_5_1`, `reset_2`, `reset_3`, `reset_4`, `reset_5`) intentionally avoid requiring later migrations.

## Migration Naming Rationale
Flyway `V###` numbers represent **execution order**, not milestone labels.

- `V001__schema_skeleton.sql` is first because it creates the base schemas/tables everything else depends on.
- `V002__proof_slice.sql` is second because Proof Slice logic (promotion function/negative checks) requires tables created in `V001`.
- `V003__workflow_engine.sql` builds on both previous migrations.
- `V004__signwell_contract.sql` adds Signwell send eligibility, payload generation, and webhook ingest contract functions.
- `V005__contract_extensions.sql` adds full regression contract surfaces and deterministic Gate 3 payload lock support.
- `V006__security_permissions.sql` adds RLS, permissions hardening, and role-restricted execution.

So the numbering is dependency/order-driven (Flyway-safe). See `db/README.md` for historical milestone-to-file provenance.
