# Dealflow Contract

Database-first deal workflow engine for dealflow operations. The PostgreSQL database is the system of record — all validation, versioning, approval state, audit trails, and integration payloads are defined as SQL contracts.

## Data Contract Overview

Six schemas, each with a clear responsibility:

| Schema | Purpose |
|--------|---------|
| `ops` | Mutable draft workspace — deals are created and edited here |
| `core` | Immutable versioned snapshots — promoted from ops, never edited directly |
| `config` | Catalogues and rules — deal types, commission tiers, doc checklists, Signwell templates |
| `security` | Identity, roles, role instances, permissions, RLS policies |
| `audit` | Append-only event log for all state transitions |
| `api` | Public contract surface — views and functions consumed by UI/orchestration layers |
| `raw` | Compatibility scaffold for external system mappings |

**Key invariants:**
- Drafts live in `ops.*` and are freely editable
- `ops.promote_draft_to_core()` validates then snapshots a draft into an immutable `core.deal_version`
- Resubmissions create a new version, never mutate existing ones
- Commission splits are DB-computed from threshold rules, not user-entered
- All `api.*` functions use `SECURITY DEFINER` with locked `search_path`
- Role-based access: `app_ops`, `app_finance`, `app_broker`, `app_ui`, `app_system`

## Prerequisites

- Docker or Podman
- `psql` (PostgreSQL client)
- `make`

## Quick Start

```bash
# Clone and start — runs postgres, applies all migrations + seeds, runs verification suite
make bootstrap
```

That's it. If all verify scripts pass, the database is correctly set up.

## Connection Details

| Setting | Default |
|---------|---------|
| Host | `127.0.0.1` |
| Port | `54329` |
| User | `postgres` |
| Password | `postgres` |
| Database | `xero_integration` |

Override via `.env` (copy from `.env.example`) or environment variables.

## Common Commands

```bash
make bootstrap    # Full setup: start DB + migrate + seed + verify
make reset        # Tear down volumes and bootstrap from scratch
make up           # Start Postgres container
make down         # Stop Postgres container
make migrate      # Apply all migrations
make seed         # Apply all seed data
make verify       # Run full verification suite
make psql         # Open psql shell
make logs         # Tail Postgres logs
```

## Using Flyway

If you prefer Flyway over the Makefile:

```bash
# Structural migrations
flyway -configFiles=flyway.conf migrate

# Seed data
flyway -configFiles=flyway.seed.conf migrate
```

## Project Structure

```
db/migrations/    V001–V009 sequential SQL migrations
db/seeds/         S001–S004 seed data (catalogues, rules, identities, role instances)
db/verify/        Verification scripts — run inside transactions, assert then rollback
compose.yml       Postgres 14 container
Makefile          All run/test/reset commands
```

## Running Tests

The verify scripts are the test suite. Each runs inside a `BEGIN ... ROLLBACK` transaction — they assert correctness without leaving test data behind.

```bash
# Run everything
make verify

# Run a single verify script directly
psql -h 127.0.0.1 -p 54329 -U postgres -d xero_integration -f db/verify/api_contract_verify.sql
```

A verify run exercises: schema existence, object counts, draft lifecycle (create/edit/validate/promote), hash-mismatch guards, validation failure guards, permission boundaries, and reference data smoke tests.
