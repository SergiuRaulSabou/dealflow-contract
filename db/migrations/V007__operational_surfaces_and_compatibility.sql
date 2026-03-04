BEGIN;

-- ---------------------------------------------------------------------------
-- Post-milestone gap closure: UI operational read models + schema compatibility
-- ---------------------------------------------------------------------------

-- Ensure app roles exist when running this migration independently.
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ops') THEN
        CREATE ROLE app_ops NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_finance') THEN
        CREATE ROLE app_finance NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_broker') THEN
        CREATE ROLE app_broker NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ui') THEN
        CREATE ROLE app_ui NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_system') THEN
        CREATE ROLE app_system NOLOGIN;
    END IF;
END;
$$;

-- ---------------------------------------------------------------------------
-- Compatibility scaffolds for config schema sheets
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.deal_type (
    deal_type_id BIGSERIAL PRIMARY KEY,
    deal_type_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.deal_type_variant (
    deal_type_variant_id BIGSERIAL PRIMARY KEY,
    deal_type_id BIGINT NOT NULL REFERENCES config.deal_type (deal_type_id) ON DELETE CASCADE,
    variant_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.field_dictionary (
    field_dictionary_id BIGSERIAL PRIMARY KEY,
    field_key TEXT NOT NULL UNIQUE,
    data_type TEXT NOT NULL,
    ui_label TEXT,
    field_description TEXT,
    in_signature_payload BOOLEAN NOT NULL DEFAULT FALSE,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.deal_type_field_rule (
    deal_type_field_rule_id BIGSERIAL PRIMARY KEY,
    deal_type_variant_id BIGINT REFERENCES config.deal_type_variant (deal_type_variant_id) ON DELETE CASCADE,
    field_dictionary_id BIGINT NOT NULL REFERENCES config.field_dictionary (field_dictionary_id) ON DELETE CASCADE,
    rule_code TEXT NOT NULL,
    rule_parameters JSONB NOT NULL DEFAULT '{}'::JSONB,
    is_required BOOLEAN NOT NULL DEFAULT FALSE,
    affects_version_hash BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_type_variant_id, field_dictionary_id, rule_code)
);

CREATE TABLE IF NOT EXISTS config.party_role (
    party_role_id BIGSERIAL PRIMARY KEY,
    party_role_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.party_role_rule (
    party_role_rule_id BIGSERIAL PRIMARY KEY,
    deal_type_variant_id BIGINT REFERENCES config.deal_type_variant (deal_type_variant_id) ON DELETE CASCADE,
    party_role_id BIGINT NOT NULL REFERENCES config.party_role (party_role_id) ON DELETE CASCADE,
    min_count INTEGER NOT NULL DEFAULT 0,
    max_count INTEGER,
    can_be_signwell_primary BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_type_variant_id, party_role_id)
);

CREATE TABLE IF NOT EXISTS config.broker_role (
    broker_role_id BIGSERIAL PRIMARY KEY,
    broker_role_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    participates_in_rls BOOLEAN NOT NULL DEFAULT TRUE,
    participates_in_approvals BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.commission_band (
    commission_band_id BIGSERIAL PRIMARY KEY,
    band_key TEXT NOT NULL UNIQUE,
    min_percent NUMERIC(7, 4),
    max_percent NUMERIC(7, 4),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.economics_rule_set (
    economics_rule_set_id BIGSERIAL PRIMARY KEY,
    deal_type_id BIGINT REFERENCES config.deal_type (deal_type_id) ON DELETE CASCADE,
    rule_set_key TEXT NOT NULL UNIQUE,
    rule_set_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.economics_rule (
    economics_rule_id BIGSERIAL PRIMARY KEY,
    economics_rule_set_id BIGINT NOT NULL REFERENCES config.economics_rule_set (economics_rule_set_id) ON DELETE CASCADE,
    rule_code TEXT NOT NULL,
    precedence INTEGER NOT NULL DEFAULT 100,
    rule_parameters JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (economics_rule_set_id, rule_code)
);

CREATE TABLE IF NOT EXISTS config.invoice_plan_template (
    invoice_plan_template_id BIGSERIAL PRIMARY KEY,
    deal_type_variant_id BIGINT REFERENCES config.deal_type_variant (deal_type_variant_id) ON DELETE CASCADE,
    template_key TEXT NOT NULL UNIQUE,
    template_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.invoice_plan_rule (
    invoice_plan_rule_id BIGSERIAL PRIMARY KEY,
    invoice_plan_template_id BIGINT NOT NULL REFERENCES config.invoice_plan_template (invoice_plan_template_id) ON DELETE CASCADE,
    rule_code TEXT NOT NULL,
    rule_parameters JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (invoice_plan_template_id, rule_code)
);

CREATE TABLE IF NOT EXISTS config.deal_type_gate_rule (
    deal_type_gate_rule_id BIGSERIAL PRIMARY KEY,
    deal_type_variant_id BIGINT REFERENCES config.deal_type_variant (deal_type_variant_id) ON DELETE CASCADE,
    gate_key TEXT NOT NULL REFERENCES config.gate_catalog (gate_key),
    gate_sequence INTEGER NOT NULL,
    can_reenter_after_kickback BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_type_variant_id, gate_key)
);

CREATE TABLE IF NOT EXISTS config.doc_category (
    doc_category_id BIGSERIAL PRIMARY KEY,
    doc_category_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.doc_checklist_item (
    doc_checklist_item_id BIGSERIAL PRIMARY KEY,
    doc_type_key TEXT NOT NULL UNIQUE,
    doc_category_id BIGINT REFERENCES config.doc_category (doc_category_id) ON DELETE SET NULL,
    display_name TEXT NOT NULL,
    must_be_signed BOOLEAN NOT NULL DEFAULT FALSE,
    checksum_required BOOLEAN NOT NULL DEFAULT FALSE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.deal_type_doc_checklist_rule (
    deal_type_doc_checklist_rule_id BIGSERIAL PRIMARY KEY,
    deal_type_variant_id BIGINT REFERENCES config.deal_type_variant (deal_type_variant_id) ON DELETE CASCADE,
    doc_checklist_item_id BIGINT NOT NULL REFERENCES config.doc_checklist_item (doc_checklist_item_id) ON DELETE CASCADE,
    gate_key TEXT REFERENCES config.gate_catalog (gate_key),
    is_required BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_type_variant_id, doc_checklist_item_id, gate_key)
);

CREATE TABLE IF NOT EXISTS config.approval_role (
    approval_role_id BIGSERIAL PRIMARY KEY,
    approval_role_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.deal_type_approval_matrix (
    deal_type_approval_matrix_id BIGSERIAL PRIMARY KEY,
    deal_type_variant_id BIGINT REFERENCES config.deal_type_variant (deal_type_variant_id) ON DELETE CASCADE,
    gate_key TEXT NOT NULL REFERENCES config.gate_catalog (gate_key),
    approval_role_id BIGINT NOT NULL REFERENCES config.approval_role (approval_role_id) ON DELETE CASCADE,
    approval_rule_id BIGINT REFERENCES config.approval_rule (approval_rule_id) ON DELETE SET NULL,
    rule_order INTEGER NOT NULL DEFAULT 1,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_type_variant_id, gate_key, approval_role_id, rule_order)
);

CREATE TABLE IF NOT EXISTS config.org_unit (
    org_unit_id BIGSERIAL PRIMARY KEY,
    org_unit_key TEXT NOT NULL UNIQUE,
    parent_org_unit_id BIGINT REFERENCES config.org_unit (org_unit_id) ON DELETE SET NULL,
    display_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.org_position (
    org_position_id BIGSERIAL PRIMARY KEY,
    position_key TEXT NOT NULL UNIQUE,
    display_name TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.role_permission (
    role_permission_id BIGSERIAL PRIMARY KEY,
    role_key TEXT NOT NULL REFERENCES config.role_catalog (role_key) ON DELETE CASCADE,
    permission_key TEXT NOT NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (role_key, permission_key)
);

CREATE TABLE IF NOT EXISTS config.signwell_field_map (
    signwell_field_map_id BIGSERIAL PRIMARY KEY,
    signwell_template_id BIGINT NOT NULL REFERENCES config.signwell_template (signwell_template_id) ON DELETE CASCADE,
    field_key TEXT NOT NULL,
    signwell_field_key TEXT NOT NULL,
    field_type TEXT NOT NULL DEFAULT 'TEXT',
    is_required BOOLEAN NOT NULL DEFAULT TRUE,
    format_rule TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (signwell_template_id, signwell_field_key)
);

CREATE TABLE IF NOT EXISTS config.webhook_source (
    webhook_source_id BIGSERIAL PRIMARY KEY,
    source_key TEXT NOT NULL UNIQUE,
    dedupe_key_field TEXT NOT NULL DEFAULT 'event_id',
    replay_is_safe BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.validation_rule (
    validation_rule_id BIGSERIAL PRIMARY KEY,
    rule_code TEXT NOT NULL UNIQUE,
    severity TEXT NOT NULL,
    message_template TEXT NOT NULL,
    field_key TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    FOREIGN KEY (field_key) REFERENCES config.field_dictionary (field_key) ON DELETE SET NULL
);

CREATE TABLE IF NOT EXISTS config.environment_setting (
    environment_setting_id BIGSERIAL PRIMARY KEY,
    setting_key TEXT NOT NULL UNIQUE,
    setting_value TEXT,
    updated_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.audit_event_type (
    audit_event_type_id BIGSERIAL PRIMARY KEY,
    event_type TEXT NOT NULL UNIQUE,
    event_description TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- Compatibility scaffolds for core schema sheets
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS core.deal_version_property (
    deal_version_property_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    property_key TEXT NOT NULL,
    property_value JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_version_id, property_key)
);

CREATE TABLE IF NOT EXISTS core.deal_version_invoice_plan (
    deal_version_invoice_plan_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    plan_key TEXT NOT NULL,
    plan_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_version_id, plan_key)
);

CREATE TABLE IF NOT EXISTS core.deal_version_document (
    deal_version_document_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    doc_type_key TEXT NOT NULL,
    doc_category_key TEXT,
    artifact_reference TEXT,
    checksum_sha256 TEXT,
    uploaded_by_identity_id BIGINT REFERENCES security.identity (identity_id) ON DELETE SET NULL,
    uploaded_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS core.deal_version_gate (
    deal_version_gate_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    gate_key TEXT NOT NULL REFERENCES config.gate_catalog (gate_key),
    gate_instance_no INTEGER NOT NULL DEFAULT 1,
    gate_status TEXT NOT NULL DEFAULT 'OPEN',
    opened_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    closed_at TIMESTAMPTZ,
    reason_code TEXT REFERENCES config.reason_code (reason_code),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_version_id, gate_key, gate_instance_no)
);

INSERT INTO core.deal_version_gate (
    deal_version_id,
    gate_key,
    gate_instance_no,
    gate_status,
    opened_at,
    closed_at,
    reason_code
)
SELECT
    dv.deal_version_id,
    dv.current_gate_key,
    1,
    CASE
        WHEN dv.lifecycle_status IN ('REJECTED', 'SUPERSEDED') THEN 'CLOSED'
        ELSE 'OPEN'
    END,
    dv.promoted_at,
    CASE
        WHEN dv.lifecycle_status IN ('REJECTED', 'SUPERSEDED') THEN dv.promoted_at
        ELSE NULL
    END,
    CASE
        WHEN dv.lifecycle_status = 'REJECTED' THEN 'FINANCE_REJECTED'
        ELSE NULL
    END
FROM core.deal_version dv
WHERE NOT EXISTS (
    SELECT 1
    FROM core.deal_version_gate dvg
    WHERE dvg.deal_version_id = dv.deal_version_id
      AND dvg.gate_key = dv.current_gate_key
      AND dvg.gate_instance_no = 1
);

-- ---------------------------------------------------------------------------
-- Compatibility scaffolds for raw schema sheets
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS raw.invoice (
    raw_invoice_id BIGSERIAL PRIMARY KEY,
    source_row_id BIGINT UNIQUE REFERENCES raw.source_row (source_row_id) ON DELETE CASCADE,
    invoice_number TEXT,
    invoice_status TEXT,
    invoice_date DATE,
    due_date DATE,
    invoiced_to TEXT,
    total_excl_vat NUMERIC(18, 2),
    total_incl_vat NUMERIC(18, 2),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw.deal_attributes (
    raw_deal_attributes_id BIGSERIAL PRIMARY KEY,
    source_row_id BIGINT UNIQUE REFERENCES raw.source_row (source_row_id) ON DELETE CASCADE,
    deal_name TEXT,
    deal_subtype_key TEXT,
    property_address TEXT,
    suburb_area TEXT,
    gla_sqm NUMERIC(18, 4),
    lease_length_years NUMERIC(18, 4),
    total_lease_value NUMERIC(18, 2),
    purchase_price NUMERIC(18, 2),
    commission_percent NUMERIC(9, 4),
    sector TEXT,
    attributes_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw.document_flags (
    raw_document_flags_id BIGSERIAL PRIMARY KEY,
    source_row_id BIGINT UNIQUE REFERENCES raw.source_row (source_row_id) ON DELETE CASCADE,
    dealsheet_signed BOOLEAN,
    checklist_complete BOOLEAN,
    otp_or_lease_present BOOLEAN,
    fica_present BOOLEAN,
    document_flags_payload JSONB NOT NULL DEFAULT '{}'::JSONB,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw.invoice_commission_allocation (
    raw_invoice_commission_allocation_id BIGSERIAL PRIMARY KEY,
    source_row_id BIGINT REFERENCES raw.source_row (source_row_id) ON DELETE CASCADE,
    allocation_target_key TEXT NOT NULL,
    allocation_target_name TEXT,
    allocation_percent NUMERIC(9, 4),
    allocation_amount NUMERIC(18, 2),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw.invoice_commission_provision (
    raw_invoice_commission_provision_id BIGSERIAL PRIMARY KEY,
    source_row_id BIGINT REFERENCES raw.source_row (source_row_id) ON DELETE CASCADE,
    cost_center_key TEXT,
    total_commission NUMERIC(18, 2),
    paid_out NUMERIC(18, 2),
    external_paid_out NUMERIC(18, 2),
    provision_balance NUMERIC(18, 2),
    opening_balance NUMERIC(18, 2),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw.ref_person (
    ref_person_id BIGSERIAL PRIMARY KEY,
    raw_name TEXT NOT NULL UNIQUE,
    normalized_name TEXT,
    identity_id BIGINT REFERENCES security.identity (identity_id) ON DELETE SET NULL,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS raw.ref_cost_center (
    ref_cost_center_id BIGSERIAL PRIMARY KEY,
    raw_label TEXT NOT NULL UNIQUE,
    canonical_code TEXT,
    display_name TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- ---------------------------------------------------------------------------
-- UI operational read models / retrieval surfaces
-- ---------------------------------------------------------------------------

CREATE OR REPLACE VIEW core.v_deal_tracker AS
SELECT
    dv.deal_version_id,
    dv.deal_id,
    d.deal_business_key,
    dv.version_major,
    dv.version_minor,
    ('v' || dv.version_major::TEXT || '.' || dv.version_minor::TEXT) AS version_label,
    dv.is_current,
    dv.deal_subtype_key,
    dv.current_gate_key,
    dv.lifecycle_status,
    dv.promoted_at,
    dv.previous_deal_version_id,
    COALESCE(doc.required_doc_count, 0) AS required_doc_count,
    COALESCE(doc.confirmed_doc_count, 0) AS confirmed_doc_count,
    COALESCE(ar.open_approval_count, 0) AS open_approval_count,
    COALESCE(ar.pending_roles, '[]'::JSONB) AS pending_roles,
    COALESCE(sw.has_open_envelope, FALSE) AS has_open_envelope,
    ev.last_event_type,
    ev.last_event_at
FROM core.deal_version dv
JOIN core.deal d
  ON d.deal_id = dv.deal_id
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) FILTER (WHERE s.is_required = TRUE) AS required_doc_count,
        COUNT(*) FILTER (WHERE s.is_required = TRUE AND s.is_confirmed = TRUE) AS confirmed_doc_count
    FROM core.deal_version_doc_checklist_status s
    WHERE s.deal_version_id = dv.deal_version_id
) doc ON TRUE
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) FILTER (WHERE ar.requirement_status = 'OPEN') AS open_approval_count,
        COALESCE(
            jsonb_agg(DISTINCT ar.required_role_key) FILTER (WHERE ar.requirement_status = 'OPEN'),
            '[]'::JSONB
        ) AS pending_roles
    FROM core.approval_requirement ar
    WHERE ar.deal_version_id = dv.deal_version_id
) ar ON TRUE
LEFT JOIN LATERAL (
    SELECT
        COALESCE(
            BOOL_OR(COALESCE(se.envelope_status, 'CREATED') NOT IN ('COMPLETED', 'DECLINED', 'VOIDED', 'CANCELLED')),
            FALSE
        ) AS has_open_envelope
    FROM core.signwell_envelope se
    WHERE se.deal_version_id = dv.deal_version_id
) sw ON TRUE
LEFT JOIN LATERAL (
    SELECT
        el.event_type AS last_event_type,
        el.occurred_at AS last_event_at
    FROM audit.event_log el
    WHERE el.deal_version_id = dv.deal_version_id
    ORDER BY el.occurred_at DESC, el.event_log_id DESC
    LIMIT 1
) ev ON TRUE;

CREATE OR REPLACE VIEW core.v_finance_review_summary AS
SELECT
    dv.deal_version_id,
    d.deal_business_key,
    dv.current_gate_key,
    dv.lifecycle_status,
    dv.deal_subtype_key,
    e.gross_billings,
    e.commission_total,
    e.company_split_pct,
    e.broker_split_pct,
    COALESCE(doc.required_doc_count, 0) AS required_doc_count,
    COALESCE(doc.confirmed_doc_count, 0) AS confirmed_doc_count,
    COALESCE(doc.outstanding_doc_count, 0) AS outstanding_doc_count,
    COALESCE(ar.open_approval_count, 0) AS open_approval_count,
    COALESCE(ar.approved_count, 0) AS approved_count,
    COALESCE(ar.rejected_count, 0) AS rejected_count,
    dv.xero_payload_hash,
    dv.xero_payload_locked_at,
    dv.promoted_at
FROM core.deal_version dv
JOIN core.deal d
  ON d.deal_id = dv.deal_id
LEFT JOIN core.deal_version_economics e
  ON e.deal_version_id = dv.deal_version_id
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) FILTER (WHERE s.is_required = TRUE) AS required_doc_count,
        COUNT(*) FILTER (WHERE s.is_required = TRUE AND s.is_confirmed = TRUE) AS confirmed_doc_count,
        COUNT(*) FILTER (WHERE s.is_required = TRUE AND s.is_confirmed = FALSE) AS outstanding_doc_count
    FROM core.deal_version_doc_checklist_status s
    WHERE s.deal_version_id = dv.deal_version_id
) doc ON TRUE
LEFT JOIN LATERAL (
    SELECT
        COUNT(*) FILTER (WHERE ar.requirement_status = 'OPEN') AS open_approval_count,
        COUNT(*) FILTER (WHERE ar.requirement_status IN ('APPROVED', 'RESOLVED')) AS approved_count,
        COUNT(*) FILTER (WHERE ar.requirement_status IN ('REJECTED', 'INVALIDATED')) AS rejected_count
    FROM core.approval_requirement ar
    WHERE ar.deal_version_id = dv.deal_version_id
) ar ON TRUE;

CREATE OR REPLACE FUNCTION core.get_task_list(p_identity_id BIGINT DEFAULT NULL)
RETURNS TABLE (
    task_type TEXT,
    task_id TEXT,
    deal_version_id BIGINT,
    draft_id BIGINT,
    deal_business_key TEXT,
    gate_key TEXT,
    assigned_role_key TEXT,
    task_status TEXT,
    due_at TIMESTAMPTZ,
    created_at TIMESTAMPTZ,
    task_payload JSONB
)
LANGUAGE sql
STABLE
AS $$
WITH resolved AS (
    SELECT COALESCE(p_identity_id, security.current_identity_id()) AS identity_id
),
approval_tasks AS (
    SELECT
        'APPROVAL'::TEXT AS task_type,
        ar.approval_requirement_id::TEXT AS task_id,
        ar.deal_version_id,
        NULL::BIGINT AS draft_id,
        d.deal_business_key,
        ar.gate_key,
        ar.required_role_key AS assigned_role_key,
        ar.requirement_status AS task_status,
        NULL::TIMESTAMPTZ AS due_at,
        ar.created_at,
        jsonb_build_object(
            'approval_requirement_id', ar.approval_requirement_id,
            'required_role_key', ar.required_role_key,
            'lifecycle_status', dv.lifecycle_status
        ) AS task_payload
    FROM resolved r
    JOIN security.role_assignment ra
      ON ra.identity_id = r.identity_id
    JOIN core.approval_requirement ar
      ON ar.required_role_key = ra.role_key
     AND ar.requirement_status = 'OPEN'
    JOIN core.deal_version dv
      ON dv.deal_version_id = ar.deal_version_id
    JOIN core.deal d
      ON d.deal_id = dv.deal_id
    WHERE r.identity_id IS NOT NULL
),
correction_tasks AS (
    SELECT
        'CORRECTION'::TEXT AS task_type,
        ct.correction_task_id::TEXT AS task_id,
        dv_current.deal_version_id,
        ct.draft_id,
        od.deal_business_key,
        dv_current.current_gate_key AS gate_key,
        NULL::TEXT AS assigned_role_key,
        ct.task_status,
        ct.due_at,
        ct.created_at,
        jsonb_build_object(
            'reason_code', ct.reason_code,
            'assigned_to_identity_id', ct.assigned_to_identity_id
        ) AS task_payload
    FROM resolved r
    JOIN ops.correction_task ct
      ON r.identity_id IS NOT NULL
     AND ct.task_status = 'OPEN'
     AND (ct.assigned_to_identity_id IS NULL OR ct.assigned_to_identity_id = r.identity_id)
    JOIN ops.deal_draft od
      ON od.draft_id = ct.draft_id
    LEFT JOIN core.deal d
      ON d.deal_business_key = od.deal_business_key
    LEFT JOIN LATERAL (
        SELECT dv.deal_version_id, dv.current_gate_key
        FROM core.deal_version dv
        WHERE dv.deal_id = d.deal_id
          AND dv.is_current = TRUE
        ORDER BY dv.promoted_at DESC
        LIMIT 1
    ) dv_current ON TRUE
),
exception_tasks AS (
    SELECT
        'EXCEPTION'::TEXT AS task_type,
        eq.exception_queue_id::TEXT AS task_id,
        dv_current.deal_version_id,
        eq.draft_id,
        COALESCE(od.deal_business_key, eq.deal_business_key) AS deal_business_key,
        dv_current.current_gate_key AS gate_key,
        NULL::TEXT AS assigned_role_key,
        eq.exception_status AS task_status,
        NULL::TIMESTAMPTZ AS due_at,
        eq.created_at,
        eq.exception_payload AS task_payload
    FROM resolved r
    JOIN ops.exception_queue eq
      ON r.identity_id IS NOT NULL
     AND eq.exception_status = 'OPEN'
    LEFT JOIN ops.deal_draft od
      ON od.draft_id = eq.draft_id
    LEFT JOIN core.deal d
      ON d.deal_business_key = COALESCE(od.deal_business_key, eq.deal_business_key)
    LEFT JOIN LATERAL (
        SELECT dv.deal_version_id, dv.current_gate_key
        FROM core.deal_version dv
        WHERE dv.deal_id = d.deal_id
          AND dv.is_current = TRUE
        ORDER BY dv.promoted_at DESC
        LIMIT 1
    ) dv_current ON TRUE
    WHERE EXISTS (
        SELECT 1
        FROM security.role_assignment ra
        WHERE ra.identity_id = r.identity_id
          AND ra.role_key IN ('OPS', 'FIN_APPROVER', 'DIVISION_HEAD')
    )
)
SELECT * FROM approval_tasks
UNION ALL
SELECT * FROM correction_tasks
UNION ALL
SELECT * FROM exception_tasks
ORDER BY created_at DESC, task_type, task_id;
$$;

CREATE OR REPLACE FUNCTION core.get_payload_bundle(
    p_deal_version_id BIGINT,
    p_gate_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_gate_key TEXT;
    v_requested_gate_key TEXT;
    v_lifecycle_status TEXT;
    v_xero_payload_hash TEXT;
    v_xero_payload_locked_at TIMESTAMPTZ;
    v_signwell_payload JSONB := NULL;
    v_xero_payload JSONB := NULL;
    v_is_eligible BOOLEAN := FALSE;
    v_reason TEXT := 'NOT_CHECKED';
BEGIN
    SELECT
        dv.current_gate_key,
        dv.lifecycle_status,
        dv.xero_payload_hash,
        dv.xero_payload_locked_at
    INTO
        v_current_gate_key,
        v_lifecycle_status,
        v_xero_payload_hash,
        v_xero_payload_locked_at
    FROM core.deal_version dv
    WHERE dv.deal_version_id = p_deal_version_id;

    IF v_current_gate_key IS NULL THEN
        RAISE EXCEPTION 'deal_version_id % not found', p_deal_version_id;
    END IF;

    v_requested_gate_key := COALESCE(NULLIF(p_gate_key, ''), v_current_gate_key);

    IF v_requested_gate_key IN ('G1', 'G2', 'G3') THEN
        SELECT e.is_eligible, e.reason
        INTO v_is_eligible, v_reason
        FROM core.is_send_eligible(p_deal_version_id, v_requested_gate_key) e;

        IF v_is_eligible IS TRUE THEN
            v_signwell_payload := core.get_signwell_payload(p_deal_version_id, v_requested_gate_key);
        END IF;
    ELSE
        v_reason := 'GATE_NOT_SIGNWELL_ENABLED';
    END IF;

    IF v_current_gate_key IN ('G3', 'G4')
       AND v_lifecycle_status NOT IN ('REJECTED', 'SUPERSEDED') THEN
        v_xero_payload := core.get_xero_payload(p_deal_version_id);
    END IF;

    RETURN jsonb_build_object(
        'deal_version_id', p_deal_version_id,
        'requested_gate_key', v_requested_gate_key,
        'current_gate_key', v_current_gate_key,
        'lifecycle_status', v_lifecycle_status,
        'signwell', jsonb_build_object(
            'eligible', v_is_eligible,
            'reason', v_reason,
            'payload', v_signwell_payload
        ),
        'xero', jsonb_build_object(
            'payload', v_xero_payload,
            'payload_hash', v_xero_payload_hash,
            'payload_locked_at', v_xero_payload_locked_at
        )
    );
END;
$$;

ALTER FUNCTION core.get_payload_bundle(BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION core.get_payload_bundle(BIGINT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;

ALTER FUNCTION core.get_task_list(BIGINT) SECURITY DEFINER;
ALTER FUNCTION core.get_task_list(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;

-- ---------------------------------------------------------------------------
-- Grants for new read models and compatibility scaffolds
-- ---------------------------------------------------------------------------

GRANT SELECT ON core.v_deal_tracker TO app_ops, app_finance, app_system;
GRANT SELECT ON core.v_finance_review_summary TO app_ops, app_finance, app_system;
GRANT EXECUTE ON FUNCTION core.get_task_list(BIGINT) TO app_ops, app_finance, app_system;
GRANT EXECUTE ON FUNCTION core.get_payload_bundle(BIGINT, TEXT) TO app_ops, app_finance, app_system;

GRANT SELECT ON TABLE
    config.deal_type,
    config.deal_type_variant,
    config.field_dictionary,
    config.deal_type_field_rule,
    config.party_role,
    config.party_role_rule,
    config.broker_role,
    config.commission_band,
    config.economics_rule_set,
    config.economics_rule,
    config.invoice_plan_template,
    config.invoice_plan_rule,
    config.deal_type_gate_rule,
    config.doc_category,
    config.doc_checklist_item,
    config.deal_type_doc_checklist_rule,
    config.approval_role,
    config.deal_type_approval_matrix,
    config.org_unit,
    config.org_position,
    config.role_permission,
    config.signwell_field_map,
    config.webhook_source,
    config.validation_rule,
    config.environment_setting,
    config.audit_event_type
TO app_system, app_finance;

GRANT SELECT ON TABLE
    core.deal_version_property,
    core.deal_version_invoice_plan,
    core.deal_version_document,
    core.deal_version_gate
TO app_system, app_finance;

GRANT SELECT ON TABLE
    raw.invoice,
    raw.deal_attributes,
    raw.document_flags,
    raw.invoice_commission_allocation,
    raw.invoice_commission_provision,
    raw.ref_person,
    raw.ref_cost_center
TO app_system;

COMMIT;
