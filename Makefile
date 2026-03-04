SHELL := /bin/bash

PGHOST ?= 127.0.0.1
PGPORT ?= 54329
PGUSER ?= postgres
PGPASSWORD ?= postgres
PGDATABASE ?= xero_integration

COMPOSE ?= podman compose
SERVICE ?= postgres

MIGRATIONS_DIR ?= db/migrations
SEEDS_DIR ?= db/seeds

MIGRATION_FILES ?= $(shell ls -1 $(MIGRATIONS_DIR)/V*.sql 2>/dev/null | sort)
SEED_FILES ?= $(shell ls -1 $(SEEDS_DIR)/S*.sql 2>/dev/null | sort)
SEED_FILES_BOUNDARY ?= \
	db/seeds/S001__baseline_config_seed.sql \
	db/seeds/S002__config_extensions.sql
MIGRATION_FILES_1 ?= \
	db/migrations/V001__schema_skeleton.sql
MIGRATION_FILES_0_5_1 ?= \
	db/migrations/V001__schema_skeleton.sql \
	db/migrations/V002__proof_slice.sql
MIGRATION_FILES_2 ?= \
	db/migrations/V001__schema_skeleton.sql \
	db/migrations/V002__proof_slice.sql \
	db/migrations/V003__workflow_engine.sql
MIGRATION_FILES_3 ?= \
	db/migrations/V001__schema_skeleton.sql \
	db/migrations/V002__proof_slice.sql \
	db/migrations/V003__workflow_engine.sql \
	db/migrations/V004__signwell_contract.sql
MIGRATION_FILES_4 ?= \
	db/migrations/V001__schema_skeleton.sql \
	db/migrations/V002__proof_slice.sql \
	db/migrations/V003__workflow_engine.sql \
	db/migrations/V004__signwell_contract.sql \
	db/migrations/V005__contract_extensions.sql
MIGRATION_FILES_5 ?= \
	db/migrations/V001__schema_skeleton.sql \
	db/migrations/V002__proof_slice.sql \
	db/migrations/V003__workflow_engine.sql \
	db/migrations/V004__signwell_contract.sql \
	db/migrations/V005__contract_extensions.sql \
	db/migrations/V006__security_permissions.sql
MIGRATION_FILES_8 ?= \
	db/migrations/V001__schema_skeleton.sql \
	db/migrations/V002__proof_slice.sql \
	db/migrations/V003__workflow_engine.sql \
	db/migrations/V004__signwell_contract.sql \
	db/migrations/V005__contract_extensions.sql \
	db/migrations/V006__security_permissions.sql \
	db/migrations/V007__operational_surfaces_and_compatibility.sql \
	db/migrations/V008__api_schema_contract_surface.sql

VERIFY_FILES_1 ?= \
	db/verify/schema_skeleton_verify.sql
VERIFY_FILES_2 ?= \
	db/verify/schema_skeleton_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/workflow_engine_verify.sql
VERIFY_FILES_3 ?= \
	db/verify/schema_skeleton_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/workflow_engine_verify.sql \
	db/verify/signwell_contract_verify.sql
VERIFY_FILES_4 ?= \
	db/verify/schema_skeleton_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/workflow_engine_verify.sql \
	db/verify/signwell_contract_verify.sql \
	db/verify/contract_extensions_verify.sql
VERIFY_FILES_5 ?= \
	db/verify/schema_skeleton_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/workflow_engine_verify.sql \
	db/verify/signwell_contract_verify.sql \
	db/verify/contract_extensions_verify.sql \
	db/verify/security_permissions_verify.sql
VERIFY_FILES ?= \
	db/verify/schema_skeleton_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/proof_slice_verify.sql \
	db/verify/workflow_engine_verify.sql \
	db/verify/signwell_contract_verify.sql \
	db/verify/contract_extensions_verify.sql \
	db/verify/security_permissions_verify.sql \
	db/verify/operational_surfaces_verify.sql \
	db/verify/api_contract_verify.sql
VERIFY_FILES_0_5_1 ?= \
	db/verify/schema_skeleton_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/proof_slice_verify.sql
VERIFY_FILES_GAP ?= \
	db/verify/operational_surfaces_verify.sql
VERIFY_FILES_8 ?= \
	db/verify/schema_skeleton_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/workflow_engine_verify.sql \
	db/verify/signwell_contract_verify.sql \
	db/verify/contract_extensions_verify.sql \
	db/verify/security_permissions_verify.sql \
	db/verify/operational_surfaces_verify.sql \
	db/verify/api_contract_verify.sql

export PGPASSWORD

PSQL = psql -X -v ON_ERROR_STOP=1 -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d $(PGDATABASE)
PSQL_POSTGRES = psql -X -v ON_ERROR_STOP=1 -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d postgres

.PHONY: help up wait down ps logs create-db migrate migrate_1 migrate_0_5_1 migrate_2 migrate_3 migrate_4 migrate_5 migrate_8 seed seed_boundary verify verify_1 verify_0_5_1 verify_2 verify_3 verify_4 verify_5 verify_8 verify_gap bootstrap acceptance_1 acceptance_0_5_1 acceptance_2 acceptance_3 acceptance_4 acceptance_5 acceptance_8 reset reset_1 reset_0_5_1 reset_2 reset_3 reset_4 reset_5 reset_8 psql

help:
	@echo "Targets:"
	@echo "  make up         - Start Postgres with Podman Compose and wait until ready"
	@echo "  make migrate    - Create app database and apply all migrations under $(MIGRATIONS_DIR)"
	@echo "  make migrate_1  - Apply Milestone 1 structural migration (V001)"
	@echo "  make migrate_0_5_1 - Apply only Milestone 0.5 + 1 structural migrations (V001, V002)"
	@echo "  make migrate_2  - Apply Milestone 2 structural boundary (V001, V002, V003)"
	@echo "  make migrate_3  - Apply Milestone 3 structural boundary (V001..V004)"
	@echo "  make migrate_4  - Apply Milestone 4 structural boundary (V001..V005)"
	@echo "  make migrate_5  - Apply Milestone 5 structural boundary (V001..V006)"
	@echo "  make migrate_8  - Apply API contract surface boundary (V001..V008)"
	@echo "  make seed       - Apply all seed scripts under $(SEEDS_DIR)"
	@echo "  make seed_boundary - Apply only milestone boundary seeds (S001, S002)"
	@echo "  make verify     - Run all verification scripts (includes Milestones 4 and 5)"
	@echo "  make verify_1   - Run Milestone 1 verification only"
	@echo "  make verify_0_5_1 - Run Milestone 0.5 + 1 verification scripts only"
	@echo "  make verify_2   - Run Milestone 2 verification pack (schema + seed + milestone2)"
	@echo "  make verify_3   - Run Milestone 3 verification pack (schema + seed + milestone2 + milestone3)"
	@echo "  make verify_4   - Run Milestone 4 verification pack (schema + seed + milestone2 + milestone3 + milestone4)"
	@echo "  make verify_5   - Run Milestone 5 verification pack (schema + seed + milestone2 + milestone3 + milestone4 + milestone5)"
	@echo "  make verify_8   - Run API contract surface verification pack (all milestones + api contract)"
	@echo "  make verify_gap - Run post-milestone gap-closure verification (new read models + compatibility scaffolds)"
	@echo "  make bootstrap  - up + migrate + seed + verify"
	@echo "  make acceptance_1 - clean contract for Milestone 1 (up + migrate_1 + verify_1)"
	@echo "  make acceptance_0_5_1 - up + migrate_0_5_1 + seed + verify_0_5_1"
	@echo "  make acceptance_2 - clean contract for Milestone 2 (up + migrate_2 + seed + verify_2)"
	@echo "  make acceptance_3 - clean contract for Milestone 3 (up + migrate_3 + seed + verify_3)"
	@echo "  make acceptance_4 - clean contract for Milestone 4 (up + migrate_4 + seed + verify_4)"
	@echo "  make acceptance_5 - clean contract for Milestone 5 (up + migrate_5 + seed + verify_5)"
	@echo "  make acceptance_8 - clean contract for API surface (up + migrate_8 + seed + verify_8)"
	@echo "  make down       - Stop services"
	@echo "  make reset      - Destroy container volumes then bootstrap again"
	@echo "  make reset_1    - Destroy volumes then run acceptance_1"
	@echo "  make reset_0_5_1 - Destroy volumes then run acceptance_0_5_1"
	@echo "  make reset_2    - Destroy volumes then run acceptance_2"
	@echo "  make reset_3    - Destroy volumes then run acceptance_3"
	@echo "  make reset_4    - Destroy volumes then run acceptance_4"
	@echo "  make reset_5    - Destroy volumes then run acceptance_5"
	@echo "  make reset_8    - Destroy volumes then run acceptance_8"
	@echo "  make logs       - Tail Postgres logs"
	@echo "  make psql       - Open psql shell to app database"

up:
	PGPORT=$(PGPORT) $(COMPOSE) up -d $(SERVICE)
	$(MAKE) wait

wait:
	@echo "Waiting for Postgres on $(PGHOST):$(PGPORT)..."
	@for i in {1..60}; do \
		if pg_isready -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) >/dev/null 2>&1; then \
			echo "Postgres is ready"; \
			exit 0; \
		fi; \
		sleep 1; \
	done; \
	echo "Postgres did not become ready in time" >&2; \
	exit 1

down:
	PGPORT=$(PGPORT) $(COMPOSE) down

ps:
	$(COMPOSE) ps

logs:
	$(COMPOSE) logs -f $(SERVICE)

create-db:
	@db_exists="$$( $(PSQL_POSTGRES) -Atc "SELECT 1 FROM pg_database WHERE datname = '$(PGDATABASE)'" )"; \
	if [[ "$$db_exists" != "1" ]]; then \
		echo "Creating database $(PGDATABASE)"; \
		$(PSQL_POSTGRES) -c "CREATE DATABASE $(PGDATABASE)"; \
	else \
		echo "Database $(PGDATABASE) already exists"; \
	fi

migrate: create-db
	@set -e; \
	for f in $(MIGRATION_FILES); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_1: create-db
	@set -e; \
	for f in $(MIGRATION_FILES_1); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_0_5_1: create-db
	@set -e; \
	for f in $(MIGRATION_FILES_0_5_1); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_2: create-db
	@set -e; \
	for f in $(MIGRATION_FILES_2); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_3: create-db
	@set -e; \
	for f in $(MIGRATION_FILES_3); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_4: create-db
	@set -e; \
	for f in $(MIGRATION_FILES_4); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_5: create-db
	@set -e; \
	for f in $(MIGRATION_FILES_5); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_8: create-db
	@set -e; \
	for f in $(MIGRATION_FILES_8); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

seed:
	@set -e; \
	for f in $(SEED_FILES); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

seed_boundary:
	@set -e; \
	for f in $(SEED_FILES_BOUNDARY); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

verify:
	@set -e; \
	for f in $(VERIFY_FILES); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_1:
	@set -e; \
	for f in $(VERIFY_FILES_1); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_0_5_1:
	@set -e; \
	for f in $(VERIFY_FILES_0_5_1); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_2:
	@set -e; \
	for f in $(VERIFY_FILES_2); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_3:
	@set -e; \
	for f in $(VERIFY_FILES_3); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_4:
	@set -e; \
	for f in $(VERIFY_FILES_4); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_5:
	@set -e; \
	for f in $(VERIFY_FILES_5); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_gap:
	@set -e; \
	for f in $(VERIFY_FILES_GAP); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_8:
	@set -e; \
	for f in $(VERIFY_FILES_8); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

bootstrap: up migrate seed verify
acceptance_1: up migrate_1 verify_1
acceptance_0_5_1: up migrate_0_5_1 seed_boundary verify_0_5_1
acceptance_2: up migrate_2 seed_boundary verify_2
acceptance_3: up migrate_3 seed_boundary verify_3
acceptance_4: up migrate_4 seed_boundary verify_4
acceptance_5: up migrate_5 seed_boundary verify_5
acceptance_8: up migrate_8 seed_boundary verify_8

reset:
	PGPORT=$(PGPORT) $(COMPOSE) down -v
	$(MAKE) bootstrap

reset_1:
	PGPORT=$(PGPORT) $(COMPOSE) down -v
	$(MAKE) acceptance_1

reset_0_5_1:
	PGPORT=$(PGPORT) $(COMPOSE) down -v
	$(MAKE) acceptance_0_5_1

reset_2:
	PGPORT=$(PGPORT) $(COMPOSE) down -v
	$(MAKE) acceptance_2

reset_3:
	PGPORT=$(PGPORT) $(COMPOSE) down -v
	$(MAKE) acceptance_3

reset_4:
	PGPORT=$(PGPORT) $(COMPOSE) down -v
	$(MAKE) acceptance_4

reset_5:
	PGPORT=$(PGPORT) $(COMPOSE) down -v
	$(MAKE) acceptance_5

reset_8:
	PGPORT=$(PGPORT) $(COMPOSE) down -v
	$(MAKE) acceptance_8

psql:
	$(PSQL)
