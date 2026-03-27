# Acceptance Evidence — Milestone M0.5 (Proof Slice)

Date (UTC+2): 2026-02-18  
Repository: dealflow-contract  
Commit: 71a429e chore: tighten milestone boundary acceptance and flyway seed baseline  
Executed by: Jarrod (VPS)  
Environment: Ubuntu VPS, PostgreSQL 14.20, Flyway Community 12.0.1, psql  

## Acceptance Objective
Milestone 0.5 — Proof Slice  
(Flyway SQL only; minimal tables + promote + webhook inbox + negative tests via verify)

## Preconditions
- Clean database created: dealflow_contract_m0_5
- No prior migrations applied
- Milestone boundary tested at target=2 (v002)

## Commands Executed & Evidence

### 1) Drop and recreate clean DB
```bash
sudo -u postgres psql -d postgres -c "DROP DATABASE IF EXISTS dealflow_contract_m0_5;"
sudo -u postgres psql -d postgres -c "CREATE DATABASE dealflow_contract_m0_5;"
Output:

text
Copy code
[sudo] password for galetti_admin:
could not change directory to "/home/galetti_admin/projects/dealflow-contract": Permission denied
DROP DATABASE
could not change directory to "/home/galetti_admin/projects/dealflow-contract": Permission denied
CREATE DATABASE
2) Flyway migrate to milestone boundary (target=2)
bash
Copy code
flyway \
  -configFiles=flyway.conf \
  -url=jdbc:postgresql://127.0.0.1:5432/dealflow_contract_m0_5 \
  -user=postgres \
  -password='<redacted>' \
  -target=2 \
  migrate
Output:

text
Copy code
Flyway Community Edition 12.0.1 by Redgate

See release notes here: https://rd.gt/416ObMi
Database: jdbc:postgresql://127.0.0.1:5432/dealflow_contract_m0_5 (PostgreSQL 14.20)
Schema history table "public"."flyway_schema_history" does not exist yet
Successfully validated 3 migrations (execution time 00:00.026s)
Creating schema "raw" ...
Creating schema "ops" ...
Creating schema "core" ...
Creating schema "audit" ...
Creating schema "config" ...
Creating schema "security" ...
Creating Schema History table "public"."flyway_schema_history" ...
Current version of schema "public": null
Migrating schema "public" to version "001 - milestone1 schema skeleton"
WARNING: DB: there is already a transaction in progress (SQL State: 25001 - Error Code: 0)
WARNING: DB: schema "raw" already exists, skipping (SQL State: 42P06 - Error Code: 0)
WARNING: DB: schema "ops" already exists, skipping (SQL State: 42P06 - Error Code: 0)
WARNING: DB: schema "core" already exists, skipping (SQL State: 42P06 - Error Code: 0)
WARNING: DB: schema "audit" already exists, skipping (SQL State: 42P06 - Error Code: 0)
WARNING: DB: schema "config" already exists, skipping (SQL State: 42P06 - Error Code: 0)
WARNING: DB: schema "security" already exists, skipping (SQL State: 42P06 - Error Code: 0)
Migrating schema "public" to version "002 - milestone0 5 proof slice"
WARNING: DB: there is already a transaction in progress (SQL State: 25001 - Error Code: 0)
Successfully applied 2 migrations to schema "public", now at version v002 (execution time 00:00.293s)

You are not signed in to Flyway, to sign in please run auth
3) Seed baseline config (required before verify)
bash
Copy code
psql -h 127.0.0.1 -p 5432 -U postgres -d dealflow_contract_m0_5 \
  -v ON_ERROR_STOP=1 \
  -f db/seeds/S001__baseline_config_seed.sql
Output:

text
Copy code
BEGIN
INSERT 0 6
INSERT 0 5
INSERT 0 4
INSERT 0 1
INSERT 0 4
INSERT 0 1
INSERT 0 2
INSERT 0 4
INSERT 0 12
INSERT 0 4
INSERT 0 4
INSERT 0 6
INSERT 0 2
COMMIT
4) Run milestone0_5 verification harness
bash
Copy code
psql -h 127.0.0.1 -p 5432 -U postgres -d dealflow_contract_m0_5 \
  -v ON_ERROR_STOP=1 \
  -f db/verify/milestone0_5_verify.sql
Output:

text
Copy code
BEGIN
DO
DO
DO
DO
DO
DO
ROLLBACK
Result
PASS

Notes
Milestone boundary validated at v002 (target=2).

Verify script completed with no uncaught exceptions (expected ROLLBACK at end).

Minor benign warnings observed (sudo cwd permission; Flyway “transaction in progress”).
