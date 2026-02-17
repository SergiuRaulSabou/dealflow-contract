-- Milestone 1 verification script.
-- Expected result: zero failing checks. The script raises an exception if any check fails.

DROP TABLE IF EXISTS tmp_milestone1_checks;

CREATE TEMP TABLE tmp_milestone1_checks AS
WITH
required_schemas(schema_name) AS (
    VALUES
        ('raw'),
        ('ops'),
        ('core'),
        ('audit'),
        ('config'),
        ('security')
),
schema_checks AS (
    SELECT
        'schema_exists:' || schema_name AS check_name,
        EXISTS (
            SELECT 1
            FROM information_schema.schemata s
            WHERE s.schema_name = required_schemas.schema_name
        ) AS ok
    FROM required_schemas
),
required_tables(schema_name, table_name) AS (
    VALUES
        ('config', 'gate_catalog'),
        ('config', 'reason_code'),
        ('config', 'role_catalog'),
        ('config', 'approval_rule_set'),
        ('config', 'approval_rule'),
        ('config', 'doc_checklist_template'),
        ('config', 'doc_checklist_template_item'),
        ('config', 'doc_checklist_conditional_rule'),
        ('config', 'versioning_rule_set'),
        ('config', 'versioning_rule'),
        ('config', 'signwell_template'),
        ('config', 'signwell_field_dictionary'),
        ('config', 'signwell_recipient_role_map'),
        ('security', 'identity'),
        ('security', 'role_assignment'),
        ('security', 'broker_division_map'),
        ('raw', 'source_file'),
        ('raw', 'source_file_sheet'),
        ('raw', 'source_row'),
        ('ops', 'deal_draft'),
        ('ops', 'deal_draft_party'),
        ('ops', 'deal_draft_broker'),
        ('ops', 'deal_draft_economics'),
        ('ops', 'deal_draft_doc_status'),
        ('ops', 'validation_result'),
        ('ops', 'exception_queue'),
        ('ops', 'correction_task'),
        ('core', 'deal'),
        ('core', 'deal_version'),
        ('core', 'deal_version_party'),
        ('core', 'deal_version_broker'),
        ('core', 'deal_version_economics'),
        ('core', 'deal_version_doc_checklist_status'),
        ('core', 'approval_requirement'),
        ('core', 'approval_response'),
        ('core', 'signwell_envelope'),
        ('core', 'signwell_envelope_recipient'),
        ('core', 'signwell_document_artifact'),
        ('audit', 'event_log'),
        ('audit', 'workflow_run'),
        ('audit', 'webhook_event'),
        ('audit', 'deal_version_diff')
),
table_checks AS (
    SELECT
        'table_exists:' || schema_name || '.' || table_name AS check_name,
        EXISTS (
            SELECT 1
            FROM information_schema.tables t
            WHERE t.table_schema = required_tables.schema_name
              AND t.table_name = required_tables.table_name
              AND t.table_type = 'BASE TABLE'
        ) AS ok
    FROM required_tables
),
all_scoped_tables AS (
    SELECT t.table_schema, t.table_name
    FROM information_schema.tables t
    WHERE t.table_schema IN ('raw', 'ops', 'core', 'audit', 'config', 'security')
      AND t.table_type = 'BASE TABLE'
),
tables_missing_pk AS (
    SELECT ast.table_schema, ast.table_name
    FROM all_scoped_tables ast
    LEFT JOIN information_schema.table_constraints tc
      ON tc.table_schema = ast.table_schema
     AND tc.table_name = ast.table_name
     AND tc.constraint_type = 'PRIMARY KEY'
    WHERE tc.constraint_name IS NULL
),
pk_check AS (
    SELECT
        'all_tables_have_primary_keys' AS check_name,
        COUNT(*) = 0 AS ok
    FROM tables_missing_pk
),
required_fks(check_name, source_schema, source_table, target_schema, target_table) AS (
    VALUES
        ('fk:ops.deal_draft_party->ops.deal_draft', 'ops', 'deal_draft_party', 'ops', 'deal_draft'),
        ('fk:ops.deal_draft_broker->ops.deal_draft', 'ops', 'deal_draft_broker', 'ops', 'deal_draft'),
        ('fk:ops.deal_draft_economics->ops.deal_draft', 'ops', 'deal_draft_economics', 'ops', 'deal_draft'),
        ('fk:ops.deal_draft_doc_status->ops.deal_draft', 'ops', 'deal_draft_doc_status', 'ops', 'deal_draft'),
        ('fk:ops.validation_result->ops.deal_draft', 'ops', 'validation_result', 'ops', 'deal_draft'),
        ('fk:ops.exception_queue->ops.deal_draft', 'ops', 'exception_queue', 'ops', 'deal_draft'),
        ('fk:ops.correction_task->ops.deal_draft', 'ops', 'correction_task', 'ops', 'deal_draft'),
        ('fk:core.deal_version_party->core.deal_version', 'core', 'deal_version_party', 'core', 'deal_version'),
        ('fk:core.deal_version_broker->core.deal_version', 'core', 'deal_version_broker', 'core', 'deal_version'),
        ('fk:core.deal_version_economics->core.deal_version', 'core', 'deal_version_economics', 'core', 'deal_version'),
        ('fk:core.deal_version_doc_checklist_status->core.deal_version', 'core', 'deal_version_doc_checklist_status', 'core', 'deal_version'),
        ('fk:core.approval_requirement->core.deal_version', 'core', 'approval_requirement', 'core', 'deal_version'),
        ('fk:core.approval_response->core.deal_version', 'core', 'approval_response', 'core', 'deal_version'),
        ('fk:core.signwell_envelope->core.deal_version', 'core', 'signwell_envelope', 'core', 'deal_version'),
        ('fk:core.signwell_envelope_recipient->core.deal_version', 'core', 'signwell_envelope_recipient', 'core', 'deal_version'),
        ('fk:core.signwell_document_artifact->core.deal_version', 'core', 'signwell_document_artifact', 'core', 'deal_version'),
        ('fk:core.signwell_envelope_recipient->core.signwell_envelope', 'core', 'signwell_envelope_recipient', 'core', 'signwell_envelope'),
        ('fk:core.signwell_document_artifact->core.signwell_envelope', 'core', 'signwell_document_artifact', 'core', 'signwell_envelope')
),
fk_checks AS (
    SELECT
        rfk.check_name,
        EXISTS (
            SELECT 1
            FROM information_schema.table_constraints tc
            JOIN information_schema.referential_constraints rc
              ON rc.constraint_name = tc.constraint_name
             AND rc.constraint_schema = tc.table_schema
            JOIN information_schema.constraint_column_usage ccu
              ON ccu.constraint_name = rc.unique_constraint_name
             AND ccu.constraint_schema = rc.unique_constraint_schema
            WHERE tc.constraint_type = 'FOREIGN KEY'
              AND tc.table_schema = rfk.source_schema
              AND tc.table_name = rfk.source_table
              AND ccu.table_schema = rfk.target_schema
              AND ccu.table_name = rfk.target_table
        ) AS ok
    FROM required_fks rfk
),
required_append_only_triggers(table_schema, table_name) AS (
    VALUES
        ('audit', 'event_log'),
        ('audit', 'workflow_run'),
        ('audit', 'webhook_event'),
        ('audit', 'deal_version_diff')
),
append_only_checks AS (
    SELECT
        'append_only_trigger:' || rat.table_schema || '.' || rat.table_name AS check_name,
        EXISTS (
            SELECT 1
            FROM pg_trigger trg
            JOIN pg_class cls ON cls.oid = trg.tgrelid
            JOIN pg_namespace ns ON ns.oid = cls.relnamespace
            JOIN pg_proc pr ON pr.oid = trg.tgfoid
            WHERE ns.nspname = rat.table_schema
              AND cls.relname = rat.table_name
              AND trg.tgisinternal = FALSE
              AND pr.proname = 'prevent_update_delete'
        ) AS ok
    FROM required_append_only_triggers rat
),
all_checks AS (
    SELECT * FROM schema_checks
    UNION ALL
    SELECT * FROM table_checks
    UNION ALL
    SELECT * FROM pk_check
    UNION ALL
    SELECT * FROM fk_checks
    UNION ALL
    SELECT * FROM append_only_checks
)
SELECT * FROM all_checks;

SELECT check_name, ok
FROM tmp_milestone1_checks
ORDER BY check_name;

DO $$
DECLARE
    failing_check_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO failing_check_count
    FROM tmp_milestone1_checks
    WHERE ok = FALSE;

    IF failing_check_count > 0 THEN
        RAISE EXCEPTION 'Milestone 1 verification failed: % check(s) failed', failing_check_count;
    END IF;
END;
$$;
