BEGIN;

-- Milestone 1 baseline schemas.
CREATE SCHEMA IF NOT EXISTS raw;
CREATE SCHEMA IF NOT EXISTS ops;
CREATE SCHEMA IF NOT EXISTS core;
CREATE SCHEMA IF NOT EXISTS audit;
CREATE SCHEMA IF NOT EXISTS config;
CREATE SCHEMA IF NOT EXISTS security;

-- ---------------------------------------------------------------------------
-- config schema
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS config.gate_catalog (
    gate_key TEXT PRIMARY KEY,
    gate_order INTEGER NOT NULL,
    gate_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.reason_code (
    reason_code TEXT PRIMARY KEY,
    reason_category TEXT NOT NULL,
    reason_description TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.role_catalog (
    role_key TEXT PRIMARY KEY,
    role_name TEXT NOT NULL,
    role_type TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.approval_rule_set (
    approval_rule_set_id BIGSERIAL PRIMARY KEY,
    rule_set_key TEXT NOT NULL UNIQUE,
    rule_set_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.approval_rule (
    approval_rule_id BIGSERIAL PRIMARY KEY,
    approval_rule_set_id BIGINT NOT NULL REFERENCES config.approval_rule_set (approval_rule_set_id),
    gate_key TEXT NOT NULL REFERENCES config.gate_catalog (gate_key),
    required_role_key TEXT NOT NULL REFERENCES config.role_catalog (role_key),
    rule_expression TEXT NOT NULL,
    rule_priority INTEGER NOT NULL DEFAULT 100,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.doc_checklist_template (
    doc_checklist_template_id BIGSERIAL PRIMARY KEY,
    template_key TEXT NOT NULL UNIQUE,
    deal_subtype_key TEXT NOT NULL,
    template_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.doc_checklist_template_item (
    doc_checklist_template_item_id BIGSERIAL PRIMARY KEY,
    doc_checklist_template_id BIGINT NOT NULL REFERENCES config.doc_checklist_template (doc_checklist_template_id),
    checklist_item_key TEXT NOT NULL,
    checklist_item_name TEXT NOT NULL,
    gate_key TEXT REFERENCES config.gate_catalog (gate_key),
    is_required BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (doc_checklist_template_id, checklist_item_key)
);

CREATE TABLE IF NOT EXISTS config.doc_checklist_conditional_rule (
    doc_checklist_conditional_rule_id BIGSERIAL PRIMARY KEY,
    doc_checklist_template_item_id BIGINT NOT NULL REFERENCES config.doc_checklist_template_item (doc_checklist_template_item_id),
    condition_key TEXT NOT NULL,
    condition_expression TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.versioning_rule_set (
    versioning_rule_set_id BIGSERIAL PRIMARY KEY,
    rule_set_key TEXT NOT NULL UNIQUE,
    rule_set_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.versioning_rule (
    versioning_rule_id BIGSERIAL PRIMARY KEY,
    versioning_rule_set_id BIGINT NOT NULL REFERENCES config.versioning_rule_set (versioning_rule_set_id),
    rule_key TEXT NOT NULL,
    rule_expression TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (versioning_rule_set_id, rule_key)
);

CREATE TABLE IF NOT EXISTS config.signwell_template (
    signwell_template_id BIGSERIAL PRIMARY KEY,
    gate_key TEXT NOT NULL REFERENCES config.gate_catalog (gate_key),
    deal_subtype_key TEXT NOT NULL,
    template_external_id TEXT NOT NULL,
    template_version TEXT NOT NULL DEFAULT 'v1',
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (gate_key, deal_subtype_key, template_version)
);

CREATE TABLE IF NOT EXISTS config.signwell_field_dictionary (
    signwell_field_key TEXT PRIMARY KEY,
    field_type TEXT NOT NULL,
    is_required BOOLEAN NOT NULL DEFAULT TRUE,
    field_description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.signwell_recipient_role_map (
    signwell_recipient_role_map_id BIGSERIAL PRIMARY KEY,
    gate_key TEXT NOT NULL REFERENCES config.gate_catalog (gate_key),
    role_key TEXT NOT NULL REFERENCES config.role_catalog (role_key),
    recipient_order INTEGER NOT NULL,
    recipient_selector TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (gate_key, role_key)
);

-- ---------------------------------------------------------------------------
-- security schema
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS security.identity (
    identity_id BIGSERIAL PRIMARY KEY,
    email TEXT NOT NULL UNIQUE,
    display_name TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS security.role_assignment (
    role_assignment_id BIGSERIAL PRIMARY KEY,
    identity_id BIGINT NOT NULL REFERENCES security.identity (identity_id),
    role_key TEXT NOT NULL REFERENCES config.role_catalog (role_key),
    assigned_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    assigned_by_identity_id BIGINT REFERENCES security.identity (identity_id),
    UNIQUE (identity_id, role_key)
);

CREATE TABLE IF NOT EXISTS security.broker_division_map (
    broker_division_map_id BIGSERIAL PRIMARY KEY,
    broker_external_ref TEXT NOT NULL,
    division_key TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    valid_from TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    valid_to TIMESTAMPTZ,
    UNIQUE (broker_external_ref, division_key, valid_from)
);

-- ---------------------------------------------------------------------------
-- raw schema
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS raw.source_file (
    source_file_id BIGSERIAL PRIMARY KEY,
    source_name TEXT NOT NULL,
    file_name TEXT NOT NULL,
    file_checksum_sha256 TEXT,
    ingested_by_identity_id BIGINT REFERENCES security.identity (identity_id),
    ingested_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_name, file_name, file_checksum_sha256)
);

CREATE TABLE IF NOT EXISTS raw.source_file_sheet (
    source_file_sheet_id BIGSERIAL PRIMARY KEY,
    source_file_id BIGINT NOT NULL REFERENCES raw.source_file (source_file_id) ON DELETE CASCADE,
    sheet_name TEXT NOT NULL,
    header_row_number INTEGER,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_file_id, sheet_name)
);

CREATE TABLE IF NOT EXISTS raw.source_row (
    source_row_id BIGSERIAL PRIMARY KEY,
    source_file_id BIGINT NOT NULL REFERENCES raw.source_file (source_file_id) ON DELETE CASCADE,
    source_file_sheet_id BIGINT REFERENCES raw.source_file_sheet (source_file_sheet_id) ON DELETE CASCADE,
    source_row_number INTEGER NOT NULL,
    row_payload JSONB NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (source_file_id, source_file_sheet_id, source_row_number)
);

-- ---------------------------------------------------------------------------
-- ops schema
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS ops.deal_draft (
    draft_id BIGSERIAL PRIMARY KEY,
    deal_business_key TEXT,
    deal_subtype_key TEXT NOT NULL,
    draft_status TEXT NOT NULL DEFAULT 'DRAFT',
    current_gate_key TEXT NOT NULL DEFAULT 'G0' REFERENCES config.gate_catalog (gate_key),
    created_by_identity_id BIGINT REFERENCES security.identity (identity_id),
    updated_by_identity_id BIGINT REFERENCES security.identity (identity_id),
    source_deal_version_id BIGINT,
    submitted_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ops.deal_draft_party (
    draft_party_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    party_role_key TEXT NOT NULL,
    party_name TEXT NOT NULL,
    party_email TEXT,
    party_phone TEXT,
    is_primary BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ops.deal_draft_broker (
    draft_broker_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    broker_identity_id BIGINT REFERENCES security.identity (identity_id),
    broker_external_ref TEXT,
    is_lead_broker BOOLEAN NOT NULL DEFAULT FALSE,
    split_percent NUMERIC(7, 4),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ops.deal_draft_economics (
    draft_economics_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL UNIQUE REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    gross_billings NUMERIC(18, 2),
    commission_total NUMERIC(18, 2),
    company_split_pct NUMERIC(7, 4),
    broker_split_pct NUMERIC(7, 4),
    economics_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ops.deal_draft_doc_status (
    draft_doc_status_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    doc_checklist_template_item_id BIGINT REFERENCES config.doc_checklist_template_item (doc_checklist_template_item_id),
    doc_code TEXT NOT NULL,
    is_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    note TEXT,
    confirmed_by_identity_id BIGINT REFERENCES security.identity (identity_id),
    confirmed_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (draft_id, doc_code)
);

CREATE TABLE IF NOT EXISTS ops.validation_result (
    validation_result_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    rule_code TEXT NOT NULL,
    severity TEXT NOT NULL,
    field_path TEXT,
    validation_message TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS ops.exception_queue (
    exception_queue_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    deal_business_key TEXT,
    exception_code TEXT NOT NULL,
    exception_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
    exception_status TEXT NOT NULL DEFAULT 'OPEN',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS ops.correction_task (
    correction_task_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    assigned_to_identity_id BIGINT REFERENCES security.identity (identity_id),
    reason_code TEXT REFERENCES config.reason_code (reason_code),
    task_status TEXT NOT NULL DEFAULT 'OPEN',
    due_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    completed_at TIMESTAMPTZ
);

-- ---------------------------------------------------------------------------
-- core schema
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS core.deal (
    deal_id BIGSERIAL PRIMARY KEY,
    deal_business_key TEXT NOT NULL UNIQUE,
    created_by_identity_id BIGINT REFERENCES security.identity (identity_id),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS core.deal_version (
    deal_version_id BIGSERIAL PRIMARY KEY,
    deal_id BIGINT NOT NULL REFERENCES core.deal (deal_id) ON DELETE CASCADE,
    version_major INTEGER NOT NULL DEFAULT 1 CHECK (version_major > 0),
    version_minor INTEGER NOT NULL DEFAULT 0 CHECK (version_minor >= 0),
    is_current BOOLEAN NOT NULL DEFAULT TRUE,
    lifecycle_status TEXT NOT NULL DEFAULT 'SUBMITTED',
    current_gate_key TEXT NOT NULL DEFAULT 'G1' REFERENCES config.gate_catalog (gate_key),
    submitted_from_draft_id BIGINT REFERENCES ops.deal_draft (draft_id),
    previous_deal_version_id BIGINT REFERENCES core.deal_version (deal_version_id),
    promoted_by_identity_id BIGINT REFERENCES security.identity (identity_id),
    promoted_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_id, version_major, version_minor)
);

CREATE UNIQUE INDEX IF NOT EXISTS ux_core_deal_version_current
    ON core.deal_version (deal_id)
    WHERE is_current = TRUE;

CREATE TABLE IF NOT EXISTS core.deal_version_party (
    deal_version_party_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    party_role_key TEXT NOT NULL,
    party_name TEXT NOT NULL,
    party_email TEXT,
    party_phone TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS core.deal_version_broker (
    deal_version_broker_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    broker_identity_id BIGINT REFERENCES security.identity (identity_id),
    broker_external_ref TEXT,
    is_lead_broker BOOLEAN NOT NULL DEFAULT FALSE,
    split_percent NUMERIC(7, 4),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS core.deal_version_economics (
    deal_version_economics_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL UNIQUE REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    gross_billings NUMERIC(18, 2),
    commission_total NUMERIC(18, 2),
    company_split_pct NUMERIC(7, 4),
    broker_split_pct NUMERIC(7, 4),
    economics_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS core.deal_version_doc_checklist_status (
    deal_version_doc_checklist_status_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    doc_checklist_template_item_id BIGINT REFERENCES config.doc_checklist_template_item (doc_checklist_template_item_id),
    doc_code TEXT NOT NULL,
    is_required BOOLEAN NOT NULL DEFAULT TRUE,
    is_confirmed BOOLEAN NOT NULL DEFAULT FALSE,
    note TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_version_id, doc_code)
);

CREATE TABLE IF NOT EXISTS core.approval_requirement (
    approval_requirement_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    gate_key TEXT NOT NULL REFERENCES config.gate_catalog (gate_key),
    required_role_key TEXT NOT NULL REFERENCES config.role_catalog (role_key),
    approval_rule_id BIGINT REFERENCES config.approval_rule (approval_rule_id),
    requirement_status TEXT NOT NULL DEFAULT 'OPEN',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    resolved_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS core.approval_response (
    approval_response_id BIGSERIAL PRIMARY KEY,
    approval_requirement_id BIGINT NOT NULL REFERENCES core.approval_requirement (approval_requirement_id) ON DELETE CASCADE,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    actor_identity_id BIGINT REFERENCES security.identity (identity_id),
    response_key TEXT NOT NULL CHECK (response_key IN ('APPROVED', 'REJECTED', 'CHANGE_REQUESTED')),
    reason_code TEXT REFERENCES config.reason_code (reason_code),
    response_comment TEXT,
    responded_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS core.signwell_envelope (
    signwell_envelope_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    gate_key TEXT NOT NULL REFERENCES config.gate_catalog (gate_key),
    external_envelope_id TEXT NOT NULL UNIQUE,
    dedupe_key TEXT UNIQUE,
    envelope_status TEXT NOT NULL DEFAULT 'CREATED',
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    sent_at TIMESTAMPTZ,
    closed_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS core.signwell_envelope_recipient (
    signwell_envelope_recipient_id BIGSERIAL PRIMARY KEY,
    signwell_envelope_id BIGINT NOT NULL REFERENCES core.signwell_envelope (signwell_envelope_id) ON DELETE CASCADE,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    recipient_email TEXT NOT NULL,
    recipient_role_key TEXT NOT NULL,
    recipient_status TEXT NOT NULL DEFAULT 'PENDING',
    signed_at TIMESTAMPTZ,
    declined_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS core.signwell_document_artifact (
    signwell_document_artifact_id BIGSERIAL PRIMARY KEY,
    signwell_envelope_id BIGINT NOT NULL REFERENCES core.signwell_envelope (signwell_envelope_id) ON DELETE CASCADE,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    artifact_type TEXT NOT NULL,
    artifact_reference TEXT NOT NULL,
    checksum_sha256 TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        WHERE c.conname = 'fk_ops_deal_draft_source_deal_version'
          AND c.conrelid = 'ops.deal_draft'::regclass
    ) THEN
        ALTER TABLE ops.deal_draft
            ADD CONSTRAINT fk_ops_deal_draft_source_deal_version
            FOREIGN KEY (source_deal_version_id) REFERENCES core.deal_version (deal_version_id);
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- audit schema
-- ---------------------------------------------------------------------------
CREATE TABLE IF NOT EXISTS audit.event_log (
    event_log_id BIGSERIAL PRIMARY KEY,
    deal_id BIGINT REFERENCES core.deal (deal_id),
    deal_version_id BIGINT REFERENCES core.deal_version (deal_version_id),
    event_type TEXT NOT NULL,
    gate_key TEXT REFERENCES config.gate_catalog (gate_key),
    actor_identity_id BIGINT REFERENCES security.identity (identity_id),
    reason_code TEXT REFERENCES config.reason_code (reason_code),
    correlation_id TEXT,
    event_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
    occurred_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS audit.workflow_run (
    workflow_run_id BIGSERIAL PRIMARY KEY,
    workflow_key TEXT NOT NULL,
    correlation_id TEXT,
    deal_version_id BIGINT REFERENCES core.deal_version (deal_version_id),
    run_status TEXT NOT NULL,
    attempt_no INTEGER NOT NULL DEFAULT 1,
    error_message TEXT,
    started_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    finished_at TIMESTAMPTZ
);

CREATE TABLE IF NOT EXISTS audit.webhook_event (
    webhook_event_id BIGSERIAL PRIMARY KEY,
    provider_key TEXT NOT NULL,
    event_id TEXT NOT NULL,
    event_type TEXT,
    deal_version_id BIGINT REFERENCES core.deal_version (deal_version_id),
    dedupe_key TEXT UNIQUE,
    webhook_payload JSONB NOT NULL,
    process_status TEXT NOT NULL DEFAULT 'RECEIVED',
    process_error TEXT,
    correlation_id TEXT,
    received_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    processed_at TIMESTAMPTZ,
    UNIQUE (provider_key, event_id)
);

CREATE TABLE IF NOT EXISTS audit.deal_version_diff (
    deal_version_diff_id BIGSERIAL PRIMARY KEY,
    deal_id BIGINT NOT NULL REFERENCES core.deal (deal_id),
    from_deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id),
    to_deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id),
    diff_payload JSONB NOT NULL,
    computed_by_identity_id BIGINT REFERENCES security.identity (identity_id),
    computed_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE OR REPLACE FUNCTION audit.prevent_update_delete()
RETURNS TRIGGER
LANGUAGE plpgsql
AS $$
BEGIN
    RAISE EXCEPTION 'audit.% is append-only; % is not allowed', TG_TABLE_NAME, TG_OP;
END;
$$;

CREATE OR REPLACE TRIGGER tr_event_log_append_only
    BEFORE UPDATE OR DELETE ON audit.event_log
    FOR EACH ROW EXECUTE FUNCTION audit.prevent_update_delete();

CREATE OR REPLACE TRIGGER tr_workflow_run_append_only
    BEFORE UPDATE OR DELETE ON audit.workflow_run
    FOR EACH ROW EXECUTE FUNCTION audit.prevent_update_delete();

CREATE OR REPLACE TRIGGER tr_webhook_event_append_only
    BEFORE UPDATE OR DELETE ON audit.webhook_event
    FOR EACH ROW EXECUTE FUNCTION audit.prevent_update_delete();

CREATE OR REPLACE TRIGGER tr_deal_version_diff_append_only
    BEFORE UPDATE OR DELETE ON audit.deal_version_diff
    FOR EACH ROW EXECUTE FUNCTION audit.prevent_update_delete();

COMMIT;
