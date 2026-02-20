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
MIGRATION_FILES_1 ?= \
	db/migrations/V001__milestone1_schema_skeleton.sql
MIGRATION_FILES_0_5_1 ?= \
	db/migrations/V001__milestone1_schema_skeleton.sql \
	db/migrations/V002__milestone0_5_proof_slice.sql
MIGRATION_FILES_2 ?= \
	db/migrations/V001__milestone1_schema_skeleton.sql \
	db/migrations/V002__milestone0_5_proof_slice.sql \
	db/migrations/V003__milestone2_workflow_engine.sql

VERIFY_FILES_1 ?= \
	db/verify/milestone1_verify.sql
VERIFY_FILES_2 ?= \
	db/verify/milestone1_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/milestone2_verify.sql
VERIFY_FILES ?= \
	db/verify/milestone1_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/milestone0_5_verify.sql \
	db/verify/milestone2_verify.sql
VERIFY_FILES_0_5_1 ?= \
	db/verify/milestone1_verify.sql \
	db/verify/seed_verify.sql \
	db/verify/milestone0_5_verify.sql

export PGPASSWORD

PSQL = psql -X -v ON_ERROR_STOP=1 -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d $(PGDATABASE)
PSQL_POSTGRES = psql -X -v ON_ERROR_STOP=1 -h $(PGHOST) -p $(PGPORT) -U $(PGUSER) -d postgres

.PHONY: help up wait down ps logs create-db migrate migrate_1 migrate_0_5_1 migrate_2 seed verify verify_1 verify_0_5_1 verify_2 bootstrap acceptance_1 acceptance_0_5_1 acceptance_2 reset reset_1 reset_0_5_1 reset_2 psql

help:
	@echo "Targets:"
	@echo "  make up         - Start Postgres with Podman Compose and wait until ready"
	@echo "  make migrate    - Create app database and apply all migrations under $(MIGRATIONS_DIR)"
	@echo "  make migrate_1  - Apply Milestone 1 structural migration (V001)"
	@echo "  make migrate_0_5_1 - Apply only Milestone 0.5 + 1 structural migrations (V001, V002)"
	@echo "  make migrate_2  - Apply Milestone 2 structural boundary (V001, V002, V003)"
	@echo "  make seed       - Apply all seed scripts under $(SEEDS_DIR)"
	@echo "  make verify     - Run all verification scripts (includes Milestone 2)"
	@echo "  make verify_1   - Run Milestone 1 verification only"
	@echo "  make verify_0_5_1 - Run Milestone 0.5 + 1 verification scripts only"
	@echo "  make verify_2   - Run Milestone 2 verification pack (schema + seed + milestone2)"
	@echo "  make bootstrap  - up + migrate + seed + verify"
	@echo "  make acceptance_1 - clean contract for Milestone 1 (up + migrate_1 + verify_1)"
	@echo "  make acceptance_0_5_1 - up + migrate_0_5_1 + seed + verify_0_5_1"
	@echo "  make acceptance_2 - clean contract for Milestone 2 (up + migrate_2 + seed + verify_2)"
	@echo "  make down       - Stop services"
	@echo "  make reset      - Destroy container volumes then bootstrap again"
	@echo "  make reset_1    - Destroy volumes then run acceptance_1"
	@echo "  make reset_0_5_1 - Destroy volumes then run acceptance_0_5_1"
	@echo "  make reset_2    - Destroy volumes then run acceptance_2"
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
	@for f in $(MIGRATION_FILES); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_1: create-db
	@for f in $(MIGRATION_FILES_1); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_0_5_1: create-db
	@for f in $(MIGRATION_FILES_0_5_1); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

migrate_2: create-db
	@for f in $(MIGRATION_FILES_2); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

seed:
	@for f in $(SEED_FILES); do \
		echo "Applying $$f"; \
		$(PSQL) -f $$f; \
	done

verify:
	@for f in $(VERIFY_FILES); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_1:
	@for f in $(VERIFY_FILES_1); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_0_5_1:
	@for f in $(VERIFY_FILES_0_5_1); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

verify_2:
	@for f in $(VERIFY_FILES_2); do \
		echo "Running $$f"; \
		$(PSQL) -f $$f; \
	done

bootstrap: up migrate seed verify
acceptance_1: up migrate_1 verify_1
acceptance_0_5_1: up migrate_0_5_1 seed verify_0_5_1
acceptance_2: up migrate_2 seed verify_2

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

psql:
	$(PSQL)
