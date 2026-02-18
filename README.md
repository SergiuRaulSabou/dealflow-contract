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
- Milestone 0.5 (Proof Slice), Milestone 1 (Schema Skeleton), and Milestone 2 (Deterministic Workflow Engine) are implemented:
  - `db/migrations/V001__milestone1_schema_skeleton.sql`
  - `db/migrations/V002__milestone0_5_proof_slice.sql`
  - `db/migrations/V003__milestone2_workflow_engine.sql`
  - `db/seeds/S001__baseline_config_seed.sql`
  - `db/verify/milestone1_verify.sql`
  - `db/verify/seed_verify.sql`
  - `db/verify/milestone0_5_verify.sql`
  - `db/verify/milestone2_verify.sql`

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
make verify
make down
make reset
```

Default connection values:
- host: `127.0.0.1`
- port: `54329`
- user: `postgres`
- password: `postgres`
- app database: `xero_integration`

Seed file currently used by `make seed`:
- `db/seeds/S001__baseline_config_seed.sql`

Verification scripts:
- `db/verify/milestone1_verify.sql` (schema/constraints)
- `db/verify/seed_verify.sql` (seed data contract)
- `db/verify/milestone0_5_verify.sql` (proof-slice checks + negative tests)
- `db/verify/milestone2_verify.sql` (promotion + checklist rules + approval materialization)

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

## Acceptance Pack (Milestone 0.5 + 1)
You can run acceptance for Milestone `0.5` and `1` either via Flyway-targeted migration or via Make.

### Option A: Flyway (targeted to V002)
```bash
make up
flyway -configFiles=flyway.conf -target=2 migrate
flyway -configFiles=flyway.seed.conf migrate
make verify_0_5_1
```

### Option B: Make (single command)
```bash
make reset_0_5_1
```

Notes:
- `make bootstrap` / `make reset` runs all currently implemented milestones (including Milestone 2).
- Use `make acceptance_0_5_1` / `make reset_0_5_1` when you want Milestone 0.5 + 1 only.

## Migration Naming Rationale
Flyway `V###` numbers represent **execution order**, not milestone labels.

- `V001__milestone1_schema_skeleton.sql` is first because it creates the base schemas/tables everything else depends on.
- `V002__milestone0_5_proof_slice.sql` is second because Proof Slice logic (promotion function/negative checks) requires tables created in `V001`.
- `V003__milestone2_workflow_engine.sql` builds on both previous migrations.

So the numbering is dependency/order-driven (Flyway-safe), while milestone names remain business labels.
