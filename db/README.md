# Database Schema — File Provenance

This document maps each migration, seed, and verify file to the project milestone that produced it.

## Migrations

| File | Milestone | Description |
|------|-----------|-------------|
| `V001__schema_skeleton.sql` | 1 | Base schemas, tables, audit triggers |
| `V002__proof_slice.sql` | 0.5 | Promotion function, negative-path checks |
| `V003__workflow_engine.sql` | 2 | Template-driven doc requirements, approval materialization |
| `V004__signwell_contract.sql` | 3 | Send eligibility, payload generation, webhook ingest |
| `V005__contract_extensions.sql` | 4 | Regression contract surfaces, Gate 3 payload lock |
| `V006__security_permissions.sql` | 5 | RLS, permissions hardening, role-restricted execution |
| `V007__operational_surfaces_and_compatibility.sql` | Post-milestone | UI read models, compatibility scaffolds |
| `V008__api_schema_contract_surface.sql` | Post-milestone | API contract surface definitions |

## Seeds

| File | Milestone | Description |
|------|-----------|-------------|
| `S001__baseline_config_seed.sql` | 1 | Gate catalog, doc checklist templates, base config |
| `S002__config_extensions.sql` | 4/5 | Deal type catalogues, expanded templates, commission metadata |
| `S003__compatibility_seed.sql` | Post-milestone | Compatibility scaffold seed data |

## Verify

| File | Milestone | Description |
|------|-----------|-------------|
| `schema_skeleton_verify.sql` | 1 | Schema and constraint checks |
| `seed_verify.sql` | 1 | Seed data contract verification |
| `proof_slice_verify.sql` | 0.5 | Proof-slice checks and negative tests |
| `workflow_engine_verify.sql` | 2 | Promotion, checklist rules, approval materialization |
| `signwell_contract_verify.sql` | 3 | Send eligibility, payload contract, webhook ingest |
| `contract_extensions_verify.sql` | 4 | Full regression scenarios, resubmission, deterministic payload/lock |
| `security_permissions_verify.sql` | 5 | RLS/permissions hardening and role boundaries |
| `operational_surfaces_verify.sql` | Post-milestone | UI read models, payload retrieval, compatibility scaffolds |
| `api_contract_verify.sql` | Post-milestone | API contract surface verification |
