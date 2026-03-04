BEGIN;

-- =========================================================================
-- V008 — API Schema Contract Surface Stabilisation
-- =========================================================================
-- Creates the `api` schema with 34 stable, versioned surfaces (views +
-- functions) that wrap existing internals, decoupling Retool / portal
-- consumers from implementation details.
-- =========================================================================

-- -------------------------------------------------------------------------
-- Section 0 — Preamble: idempotent role guards (V006/V007 pattern)
-- -------------------------------------------------------------------------
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

-- -------------------------------------------------------------------------
-- Section 1 — Schema creation
-- -------------------------------------------------------------------------
CREATE SCHEMA IF NOT EXISTS api;

-- -------------------------------------------------------------------------
-- Section 2 — Schema extensions (internal only)
-- -------------------------------------------------------------------------

-- Validation run tracking table
CREATE TABLE IF NOT EXISTS ops.validation_run (
    run_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    triggered_by BIGINT REFERENCES security.identity (identity_id),
    draft_inputs_hash TEXT,
    overall_status TEXT NOT NULL DEFAULT 'PENDING',
    error_count INTEGER NOT NULL DEFAULT 0,
    warning_count INTEGER NOT NULL DEFAULT 0,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

-- Backward-compatible FK on existing validation_result table
ALTER TABLE ops.validation_result
    ADD COLUMN IF NOT EXISTS validation_run_id BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        WHERE c.conname = 'fk_validation_result_run'
          AND c.conrelid = 'ops.validation_result'::regclass
    ) THEN
        ALTER TABLE ops.validation_result
            ADD CONSTRAINT fk_validation_result_run
            FOREIGN KEY (validation_run_id) REFERENCES ops.validation_run (run_id);
    END IF;
END;
$$;

-- Private helper: compute a deterministic hash of a draft's inputs
CREATE OR REPLACE FUNCTION api._compute_draft_hash(p_draft_id BIGINT)
RETURNS TEXT
LANGUAGE sql
STABLE
AS $$
    SELECT md5(
        COALESCE((SELECT row_to_json(d.*)::text FROM ops.deal_draft d WHERE d.draft_id = p_draft_id), '') ||
        COALESCE((SELECT string_agg(row_to_json(p.*)::text, '|' ORDER BY p.draft_party_id)
                  FROM ops.deal_draft_party p WHERE p.draft_id = p_draft_id), '') ||
        COALESCE((SELECT row_to_json(e.*)::text FROM ops.deal_draft_economics e WHERE e.draft_id = p_draft_id), '') ||
        COALESCE((SELECT string_agg(row_to_json(b.*)::text, '|' ORDER BY b.draft_broker_id)
                  FROM ops.deal_draft_broker b WHERE b.draft_id = p_draft_id), '') ||
        COALESCE((SELECT string_agg(row_to_json(ds.*)::text, '|' ORDER BY ds.draft_doc_status_id)
                  FROM ops.deal_draft_doc_status ds WHERE ds.draft_id = p_draft_id), '')
    );
$$;

-- -------------------------------------------------------------------------
-- Section 3 — Gate 0: Draft (15 surfaces)
-- -------------------------------------------------------------------------

-- #1 api.v_ops_draft_header
CREATE OR REPLACE VIEW api.v_ops_draft_header AS
SELECT
    d.draft_id,
    d.deal_business_key,
    d.deal_subtype_key,
    d.draft_status,
    d.current_gate_key,
    d.is_jse_listed,
    d.source_deal_version_id,
    d.submitted_at,
    d.created_by_identity_id,
    d.updated_by_identity_id,
    d.created_at,
    d.updated_at
FROM ops.deal_draft d;

-- #2 api.v_ops_draft_parties
CREATE OR REPLACE VIEW api.v_ops_draft_parties AS
SELECT
    p.draft_party_id,
    p.draft_id,
    p.party_role_key,
    p.party_name,
    p.party_email,
    p.party_phone,
    p.is_primary,
    p.requires_fica,
    p.created_at
FROM ops.deal_draft_party p;

-- #3 api.v_ops_draft_transaction
CREATE OR REPLACE VIEW api.v_ops_draft_transaction AS
SELECT
    e.draft_economics_id,
    e.draft_id,
    e.gross_billings,
    e.commission_total,
    e.company_split_pct,
    e.broker_split_pct,
    e.economics_payload,
    e.created_at,
    e.updated_at
FROM ops.deal_draft_economics e;

-- #4 api.v_ops_draft_docs
CREATE OR REPLACE VIEW api.v_ops_draft_docs AS
SELECT
    ds.draft_doc_status_id,
    ds.draft_id,
    ds.doc_checklist_template_item_id,
    ds.doc_code,
    ds.is_confirmed,
    ds.note,
    ds.confirmed_by_identity_id,
    ds.confirmed_at,
    ds.created_at
FROM ops.deal_draft_doc_status ds;

-- #5 api.v_ops_draft_required_docs_status
CREATE OR REPLACE VIEW api.v_ops_draft_required_docs_status AS
SELECT
    d.draft_id,
    dcti.checklist_item_key AS doc_code,
    dcti.checklist_item_name AS doc_name,
    dcti.is_required,
    COALESCE(ds.is_confirmed, FALSE) AS is_confirmed,
    ds.note,
    ds.confirmed_at
FROM ops.deal_draft d
JOIN config.doc_checklist_template dct
  ON dct.deal_subtype_key = d.deal_subtype_key
 AND dct.is_active = TRUE
JOIN config.doc_checklist_template_item dcti
  ON dcti.doc_checklist_template_id = dct.doc_checklist_template_id
LEFT JOIN ops.deal_draft_doc_status ds
  ON ds.draft_id = d.draft_id
 AND ds.doc_code = dcti.checklist_item_key;

-- #6 api.v_ops_draft_brokers
CREATE OR REPLACE VIEW api.v_ops_draft_brokers AS
SELECT
    b.draft_broker_id,
    b.draft_id,
    b.broker_identity_id,
    b.broker_external_ref,
    b.is_lead_broker,
    b.split_percent,
    b.created_at
FROM ops.deal_draft_broker b;

-- #7 api.v_ops_draft_commercial_outputs
CREATE OR REPLACE VIEW api.v_ops_draft_commercial_outputs AS
SELECT
    d.draft_id,
    d.deal_business_key,
    d.deal_subtype_key,
    e.gross_billings,
    e.commission_total,
    e.company_split_pct,
    e.broker_split_pct,
    CASE
        WHEN e.gross_billings IS NULL OR e.gross_billings = 0 THEN NULL
        ELSE ROUND((e.commission_total / e.gross_billings) * 100.0, 4)
    END AS commission_rate_pct,
    CASE
        WHEN e.commission_total IS NULL OR e.broker_split_pct IS NULL THEN NULL
        ELSE ROUND(e.commission_total * (e.broker_split_pct / 100.0), 2)
    END AS broker_commission_amount,
    CASE
        WHEN e.commission_total IS NULL OR e.company_split_pct IS NULL THEN NULL
        ELSE ROUND(e.commission_total * (e.company_split_pct / 100.0), 2)
    END AS company_commission_amount
FROM ops.deal_draft d
LEFT JOIN ops.deal_draft_economics e
  ON e.draft_id = d.draft_id;

-- #8 api.v_ops_draft_summary(draft_id)
CREATE OR REPLACE FUNCTION api.v_ops_draft_summary(p_draft_id BIGINT)
RETURNS TABLE (
    draft_id BIGINT,
    deal_subtype_key TEXT,
    error_count INTEGER,
    warning_count INTEGER,
    gross_billings NUMERIC(18,2),
    commission_total NUMERIC(18,2),
    company_split_pct NUMERIC(7,4),
    broker_split_pct NUMERIC(7,4),
    commission_rate_pct NUMERIC(18,4),
    validation_errors JSONB,
    warnings JSONB,
    economics_preview JSONB
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_preview JSONB;
BEGIN
    v_preview := ops.preview_draft(p_draft_id);

    RETURN QUERY
    SELECT
        p_draft_id,
        (v_preview ->> 'deal_subtype_key')::TEXT,
        COALESCE(jsonb_array_length(v_preview -> 'validation_errors'), 0)::INTEGER,
        COALESCE(jsonb_array_length(v_preview -> 'warnings'), 0)::INTEGER,
        (v_preview -> 'economics_preview' ->> 'gross_billings')::NUMERIC(18,2),
        (v_preview -> 'economics_preview' ->> 'commission_total')::NUMERIC(18,2),
        (v_preview -> 'economics_preview' ->> 'company_split_pct')::NUMERIC(7,4),
        (v_preview -> 'economics_preview' ->> 'broker_split_pct')::NUMERIC(7,4),
        (v_preview -> 'economics_preview' ->> 'commission_rate_pct')::NUMERIC(18,4),
        v_preview -> 'validation_errors',
        v_preview -> 'warnings',
        v_preview -> 'economics_preview';
END;
$$;

-- #9 api.v_validation_latest
CREATE OR REPLACE VIEW api.v_validation_latest AS
SELECT DISTINCT ON (vr.draft_id)
    vr.run_id,
    vr.draft_id,
    vr.triggered_by,
    vr.draft_inputs_hash,
    vr.overall_status,
    vr.error_count,
    vr.warning_count,
    vr.created_at
FROM ops.validation_run vr
ORDER BY vr.draft_id, vr.created_at DESC;

-- #10 api.v_validation_issues(draft_id, run_id?)
CREATE OR REPLACE FUNCTION api.v_validation_issues(
    p_draft_id BIGINT,
    p_run_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    validation_result_id BIGINT,
    draft_id BIGINT,
    rule_code TEXT,
    severity TEXT,
    field_path TEXT,
    validation_message TEXT,
    validation_run_id BIGINT,
    created_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        vr.validation_result_id,
        vr.draft_id,
        vr.rule_code,
        vr.severity,
        vr.field_path,
        vr.validation_message,
        vr.validation_run_id,
        vr.created_at
    FROM ops.validation_result vr
    WHERE vr.draft_id = p_draft_id
      AND (
          p_run_id IS NULL
          OR vr.validation_run_id = p_run_id
      )
    ORDER BY vr.created_at DESC, vr.validation_result_id;
$$;

-- #11 api.ops_create_draft(business_key, subtype_key, created_by)
CREATE OR REPLACE FUNCTION api.ops_create_draft(
    p_business_key TEXT,
    p_subtype_key TEXT,
    p_created_by BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_draft_id BIGINT;
BEGIN
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        draft_status,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        NULLIF(btrim(p_business_key), ''),
        p_subtype_key,
        'DRAFT',
        'G0',
        p_created_by,
        p_created_by
    )
    RETURNING draft_id INTO v_draft_id;

    INSERT INTO audit.event_log (
        event_type,
        gate_key,
        actor_identity_id,
        event_payload
    )
    VALUES (
        'DRAFT_CREATED',
        'G0',
        p_created_by,
        jsonb_build_object('draft_id', v_draft_id, 'deal_subtype_key', p_subtype_key)
    );

    RETURN v_draft_id;
END;
$$;

-- #12 api.ops_set_type_variant(draft_id, subtype_key, updated_by)
CREATE OR REPLACE FUNCTION api.ops_set_type_variant(
    p_draft_id BIGINT,
    p_subtype_key TEXT,
    p_updated_by BIGINT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    UPDATE ops.deal_draft
    SET deal_subtype_key = p_subtype_key,
        updated_by_identity_id = p_updated_by,
        updated_at = NOW()
    WHERE draft_id = p_draft_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'draft_id % not found', p_draft_id;
    END IF;
END;
$$;

-- #13a api.ops_upsert_draft_party
CREATE OR REPLACE FUNCTION api.ops_upsert_draft_party(
    p_draft_id BIGINT,
    p_party_role_key TEXT,
    p_party_name TEXT,
    p_party_email TEXT DEFAULT NULL,
    p_party_phone TEXT DEFAULT NULL,
    p_is_primary BOOLEAN DEFAULT FALSE,
    p_requires_fica BOOLEAN DEFAULT FALSE
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO ops.deal_draft_party (
        draft_id, party_role_key, party_name, party_email, party_phone, is_primary, requires_fica
    )
    VALUES (
        p_draft_id, p_party_role_key, p_party_name, p_party_email, p_party_phone, p_is_primary, p_requires_fica
    )
    RETURNING draft_party_id INTO v_id;

    RETURN v_id;
END;
$$;

-- #13b api.ops_upsert_draft_broker
CREATE OR REPLACE FUNCTION api.ops_upsert_draft_broker(
    p_draft_id BIGINT,
    p_broker_identity_id BIGINT DEFAULT NULL,
    p_broker_external_ref TEXT DEFAULT NULL,
    p_is_lead_broker BOOLEAN DEFAULT FALSE,
    p_split_percent NUMERIC(7,4) DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO ops.deal_draft_broker (
        draft_id, broker_identity_id, broker_external_ref, is_lead_broker, split_percent
    )
    VALUES (
        p_draft_id, p_broker_identity_id, p_broker_external_ref, p_is_lead_broker, p_split_percent
    )
    RETURNING draft_broker_id INTO v_id;

    RETURN v_id;
END;
$$;

-- #13c api.ops_upsert_draft_economics
CREATE OR REPLACE FUNCTION api.ops_upsert_draft_economics(
    p_draft_id BIGINT,
    p_gross_billings NUMERIC(18,2) DEFAULT NULL,
    p_commission_total NUMERIC(18,2) DEFAULT NULL,
    p_company_split_pct NUMERIC(7,4) DEFAULT NULL,
    p_broker_split_pct NUMERIC(7,4) DEFAULT NULL,
    p_economics_payload JSONB DEFAULT '{}'::JSONB
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO ops.deal_draft_economics (
        draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct, economics_payload
    )
    VALUES (
        p_draft_id, p_gross_billings, p_commission_total, p_company_split_pct, p_broker_split_pct, p_economics_payload
    )
    ON CONFLICT (draft_id) DO UPDATE
    SET gross_billings = EXCLUDED.gross_billings,
        commission_total = EXCLUDED.commission_total,
        company_split_pct = EXCLUDED.company_split_pct,
        broker_split_pct = EXCLUDED.broker_split_pct,
        economics_payload = EXCLUDED.economics_payload,
        updated_at = NOW()
    RETURNING draft_economics_id INTO v_id;

    RETURN v_id;
END;
$$;

-- #13d api.ops_upsert_draft_doc
CREATE OR REPLACE FUNCTION api.ops_upsert_draft_doc(
    p_draft_id BIGINT,
    p_doc_code TEXT,
    p_is_confirmed BOOLEAN DEFAULT FALSE,
    p_note TEXT DEFAULT NULL,
    p_confirmed_by BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO ops.deal_draft_doc_status (
        draft_id, doc_code, is_confirmed, note, confirmed_by_identity_id, confirmed_at
    )
    VALUES (
        p_draft_id, p_doc_code, p_is_confirmed, p_note, p_confirmed_by,
        CASE WHEN p_is_confirmed THEN NOW() ELSE NULL END
    )
    ON CONFLICT (draft_id, doc_code) DO UPDATE
    SET is_confirmed = EXCLUDED.is_confirmed,
        note = EXCLUDED.note,
        confirmed_by_identity_id = EXCLUDED.confirmed_by_identity_id,
        confirmed_at = EXCLUDED.confirmed_at
    RETURNING draft_doc_status_id INTO v_id;

    RETURN v_id;
END;
$$;

-- #14 api.ops_validate_draft(draft_id, triggered_by)
CREATE OR REPLACE FUNCTION api.ops_validate_draft(
    p_draft_id BIGINT,
    p_triggered_by BIGINT
)
RETURNS TABLE (
    run_id BIGINT,
    overall_status TEXT,
    error_count INTEGER,
    warning_count INTEGER,
    draft_inputs_hash TEXT
)
LANGUAGE plpgsql
AS $$
DECLARE
    v_preview JSONB;
    v_hash TEXT;
    v_run_id BIGINT;
    v_errors JSONB;
    v_warnings JSONB;
    v_error_count INTEGER;
    v_warning_count INTEGER;
    v_overall_status TEXT;
    r RECORD;
BEGIN
    -- Compute hash of current draft inputs
    v_hash := api._compute_draft_hash(p_draft_id);

    -- Call ops.preview_draft to get validation results
    v_preview := ops.preview_draft(p_draft_id);

    v_errors := COALESCE(v_preview -> 'validation_errors', '[]'::jsonb);
    v_warnings := COALESCE(v_preview -> 'warnings', '[]'::jsonb);
    v_error_count := jsonb_array_length(v_errors);
    v_warning_count := jsonb_array_length(v_warnings);

    IF v_error_count > 0 THEN
        v_overall_status := 'FAIL';
    ELSIF v_warning_count > 0 THEN
        v_overall_status := 'WARN';
    ELSE
        v_overall_status := 'PASS';
    END IF;

    -- Create a validation run record
    INSERT INTO ops.validation_run (
        draft_id, triggered_by, draft_inputs_hash, overall_status, error_count, warning_count
    )
    VALUES (
        p_draft_id, p_triggered_by, v_hash, v_overall_status, v_error_count, v_warning_count
    )
    RETURNING ops.validation_run.run_id INTO v_run_id;

    -- Persist individual issues linked to this run
    FOR r IN SELECT * FROM jsonb_array_elements(v_errors) AS e(val)
    LOOP
        INSERT INTO ops.validation_result (
            draft_id, rule_code, severity, field_path, validation_message, validation_run_id
        )
        VALUES (
            p_draft_id,
            r.val ->> 'rule_code',
            COALESCE(r.val ->> 'severity', 'ERROR'),
            r.val ->> 'field_path',
            COALESCE(r.val ->> 'message', r.val ->> 'validation_message', ''),
            v_run_id
        );
    END LOOP;

    FOR r IN SELECT * FROM jsonb_array_elements(v_warnings) AS e(val)
    LOOP
        INSERT INTO ops.validation_result (
            draft_id, rule_code, severity, field_path, validation_message, validation_run_id
        )
        VALUES (
            p_draft_id,
            r.val ->> 'rule_code',
            COALESCE(r.val ->> 'severity', 'WARNING'),
            r.val ->> 'field_path',
            COALESCE(r.val ->> 'message', r.val ->> 'validation_message', ''),
            v_run_id
        );
    END LOOP;

    RETURN QUERY
    SELECT v_run_id, v_overall_status, v_error_count, v_warning_count, v_hash;
END;
$$;

-- #15 api.ops_promote_to_core(draft_id, promoted_by)
CREATE OR REPLACE FUNCTION api.ops_promote_to_core(
    p_draft_id BIGINT,
    p_promoted_by BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_current_hash TEXT;
    v_latest_run ops.validation_run%ROWTYPE;
    v_deal_version_id BIGINT;
BEGIN
    -- Compute current hash
    v_current_hash := api._compute_draft_hash(p_draft_id);

    -- Get latest validation run
    SELECT vr.*
    INTO v_latest_run
    FROM ops.validation_run vr
    WHERE vr.draft_id = p_draft_id
    ORDER BY vr.created_at DESC
    LIMIT 1;

    -- Guard: must have a validation run
    IF v_latest_run.run_id IS NULL THEN
        RAISE EXCEPTION 'No validation run found for draft_id %. Run api.ops_validate_draft first.', p_draft_id;
    END IF;

    -- Guard: validation must have passed
    IF v_latest_run.overall_status = 'FAIL' THEN
        RAISE EXCEPTION 'Cannot promote draft_id %: latest validation run (%) has status FAIL with % errors.',
            p_draft_id, v_latest_run.run_id, v_latest_run.error_count;
    END IF;

    -- Guard: hash must match (draft not modified since validation)
    IF v_latest_run.draft_inputs_hash IS DISTINCT FROM v_current_hash THEN
        RAISE EXCEPTION 'Hash mismatch for draft_id %: draft was modified after validation run %. Re-validate before promoting.',
            p_draft_id, v_latest_run.run_id;
    END IF;

    -- Delegate to internal promotion function
    v_deal_version_id := ops.promote_draft_to_core(p_draft_id, p_promoted_by);

    RETURN v_deal_version_id;
END;
$$;

-- -------------------------------------------------------------------------
-- Section 4 — Resubmission (1 surface)
-- -------------------------------------------------------------------------

-- #16 api.ops_create_revision_from_version(dv_id, created_by)
CREATE OR REPLACE FUNCTION api.ops_create_revision_from_version(
    p_deal_version_id BIGINT,
    p_created_by BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN ops.create_draft_from_deal_version(p_deal_version_id, p_created_by, NULL);
END;
$$;

-- -------------------------------------------------------------------------
-- Section 5 — Pipeline + Tasks (2 surfaces)
-- -------------------------------------------------------------------------

-- #17 api.v_my_deals
CREATE OR REPLACE VIEW api.v_my_deals AS
SELECT
    t.deal_version_id,
    t.deal_id,
    t.deal_business_key,
    t.version_major,
    t.version_minor,
    t.version_label,
    t.is_current,
    t.deal_subtype_key,
    t.current_gate_key,
    t.lifecycle_status,
    t.promoted_at,
    t.previous_deal_version_id,
    t.required_doc_count,
    t.confirmed_doc_count,
    t.open_approval_count,
    t.pending_roles,
    t.has_open_envelope,
    t.last_event_type,
    t.last_event_at
FROM core.v_deal_tracker t
WHERE EXISTS (
    -- broker association: broker can see deals they are on
    SELECT 1
    FROM core.deal_version_broker b
    WHERE b.deal_version_id = t.deal_version_id
      AND b.broker_identity_id = security.current_identity_id()
)
OR EXISTS (
    -- internal role: ops/finance/system can see all
    SELECT 1
    FROM security.role_assignment ra
    WHERE ra.identity_id = security.current_identity_id()
      AND ra.role_key IN ('OPS', 'FIN_APPROVER', 'DIVISION_HEAD')
);

-- #18 api.v_my_tasks
CREATE OR REPLACE VIEW api.v_my_tasks AS
SELECT
    tl.task_type,
    tl.task_id,
    tl.deal_version_id,
    tl.draft_id,
    tl.deal_business_key,
    tl.gate_key,
    tl.assigned_role_key,
    tl.task_status,
    tl.due_at,
    tl.created_at,
    tl.task_payload
FROM core.get_task_list(NULL) tl;

-- -------------------------------------------------------------------------
-- Section 6 — Gate 1 Finance (2 surfaces)
-- -------------------------------------------------------------------------

-- #19 api.v_finance_queue
CREATE OR REPLACE VIEW api.v_finance_queue AS
SELECT
    frs.deal_version_id,
    frs.deal_business_key,
    frs.current_gate_key,
    frs.lifecycle_status,
    frs.deal_subtype_key,
    frs.gross_billings,
    frs.commission_total,
    frs.company_split_pct,
    frs.broker_split_pct,
    frs.required_doc_count,
    frs.confirmed_doc_count,
    frs.outstanding_doc_count,
    frs.open_approval_count,
    frs.approved_count,
    frs.rejected_count,
    frs.xero_payload_hash,
    frs.xero_payload_locked_at,
    frs.promoted_at
FROM core.v_finance_review_summary frs
WHERE frs.current_gate_key = 'G1'
  AND frs.lifecycle_status IN ('SUBMITTED', 'IN_REVIEW');

-- #20 api.finance_decide(dv_id, decision, reason_code?, reason_text?, decided_by?)
CREATE OR REPLACE FUNCTION api.finance_decide(
    p_deal_version_id BIGINT,
    p_decision TEXT,
    p_reason_code TEXT DEFAULT NULL,
    p_reason_text TEXT DEFAULT NULL,
    p_decided_by BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_actor BIGINT;
BEGIN
    v_actor := COALESCE(p_decided_by, security.current_identity_id());

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'No actor identity: provide decided_by or set xero.current_identity_id';
    END IF;

    PERFORM core.record_gate_decision(
        p_deal_version_id,
        'G1',
        'FIN_APPROVER',
        v_actor,
        p_decision,
        p_reason_code,
        p_reason_text
    );
END;
$$;

-- -------------------------------------------------------------------------
-- Section 7 — Gate 2 Approvals (4 surfaces)
-- -------------------------------------------------------------------------

-- #21 api.v_approval_requirements
CREATE OR REPLACE VIEW api.v_approval_requirements AS
SELECT
    ar.approval_requirement_id,
    ar.deal_version_id,
    ar.gate_key,
    ar.required_role_key,
    ar.approval_rule_id,
    ar.requirement_status,
    ar.created_at,
    ar.resolved_at
FROM core.approval_requirement ar;

-- #22 api.v_approval_responses
CREATE OR REPLACE VIEW api.v_approval_responses AS
SELECT
    resp.approval_response_id,
    resp.approval_requirement_id,
    resp.deal_version_id,
    resp.actor_identity_id,
    i.display_name AS actor_display_name,
    resp.response_key,
    resp.reason_code,
    resp.response_comment,
    resp.responded_at
FROM core.approval_response resp
LEFT JOIN security.identity i
  ON i.identity_id = resp.actor_identity_id;

-- #23 api.approvals_generate_requirements(dv_id, generated_by?)
CREATE OR REPLACE FUNCTION api.approvals_generate_requirements(
    p_deal_version_id BIGINT,
    p_generated_by BIGINT DEFAULT NULL
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_gate_key TEXT;
    v_count INTEGER;
BEGIN
    SELECT dv.current_gate_key
    INTO v_gate_key
    FROM core.deal_version dv
    WHERE dv.deal_version_id = p_deal_version_id;

    IF v_gate_key IS NULL THEN
        RAISE EXCEPTION 'deal_version_id % not found', p_deal_version_id;
    END IF;

    v_count := core.materialize_approval_requirements(p_deal_version_id, v_gate_key, 'DEFAULT_GATES_0_3');

    RETURN v_count;
END;
$$;

-- #24 api.approvals_record_response(...)
CREATE OR REPLACE FUNCTION api.approvals_record_response(
    p_deal_version_id BIGINT,
    p_decision TEXT,
    p_role_key TEXT DEFAULT 'FIN_APPROVER',
    p_actor_identity_id BIGINT DEFAULT NULL,
    p_reason_code TEXT DEFAULT NULL,
    p_reason_text TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_actor BIGINT;
    v_gate_key TEXT;
BEGIN
    v_actor := COALESCE(p_actor_identity_id, security.current_identity_id());

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'No actor identity: provide actor_identity_id or set xero.current_identity_id';
    END IF;

    SELECT dv.current_gate_key
    INTO v_gate_key
    FROM core.deal_version dv
    WHERE dv.deal_version_id = p_deal_version_id;

    IF v_gate_key IS NULL THEN
        RAISE EXCEPTION 'deal_version_id % not found', p_deal_version_id;
    END IF;

    PERFORM core.record_gate_decision(
        p_deal_version_id,
        v_gate_key,
        p_role_key,
        v_actor,
        p_decision,
        p_reason_code,
        p_reason_text
    );
END;
$$;

-- -------------------------------------------------------------------------
-- Section 8 — Gate 3 Payload (5 surfaces)
-- -------------------------------------------------------------------------

-- #25 api.v_payload_preview(dv_id)
CREATE OR REPLACE FUNCTION api.v_payload_preview(p_deal_version_id BIGINT)
RETURNS TABLE (
    deal_version_id BIGINT,
    deal_business_key TEXT,
    deal_subtype_key TEXT,
    invoice_reference TEXT,
    gross_billings NUMERIC(18,2),
    commission_total NUMERIC(18,2),
    company_split_pct NUMERIC(7,4),
    broker_split_pct NUMERIC(7,4),
    brokers JSONB,
    previous_deal_version_id BIGINT
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_payload JSONB;
BEGIN
    v_payload := core.get_xero_payload(p_deal_version_id);

    RETURN QUERY
    SELECT
        (v_payload ->> 'deal_version_id')::BIGINT,
        (v_payload ->> 'deal_business_key')::TEXT,
        (v_payload ->> 'deal_subtype_key')::TEXT,
        (v_payload ->> 'invoice_reference')::TEXT,
        (v_payload -> 'economics' ->> 'gross_billings')::NUMERIC(18,2),
        (v_payload -> 'economics' ->> 'commission_total')::NUMERIC(18,2),
        (v_payload -> 'economics' ->> 'company_split_pct')::NUMERIC(7,4),
        (v_payload -> 'economics' ->> 'broker_split_pct')::NUMERIC(7,4),
        v_payload -> 'brokers',
        (v_payload -> 'lineage' ->> 'previous_deal_version_id')::BIGINT;
END;
$$;

-- #26 api.payload_lock(dv_id, locked_by?)
CREATE OR REPLACE FUNCTION api.payload_lock(
    p_deal_version_id BIGINT,
    p_locked_by BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_actor BIGINT;
BEGIN
    v_actor := COALESCE(p_locked_by, security.current_identity_id());
    RETURN core.lock_xero_payload(p_deal_version_id, v_actor);
END;
$$;

-- #27 api.payload_finance_decide(payload_id, ...)
CREATE OR REPLACE FUNCTION api.payload_finance_decide(
    p_deal_version_id BIGINT,
    p_decision TEXT,
    p_reason_code TEXT DEFAULT NULL,
    p_reason_text TEXT DEFAULT NULL,
    p_decided_by BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_actor BIGINT;
BEGIN
    v_actor := COALESCE(p_decided_by, security.current_identity_id());

    IF v_actor IS NULL THEN
        RAISE EXCEPTION 'No actor identity: provide decided_by or set xero.current_identity_id';
    END IF;

    PERFORM core.record_gate_decision(
        p_deal_version_id,
        'G3',
        'FIN_APPROVER',
        v_actor,
        p_decision,
        p_reason_code,
        p_reason_text
    );
END;
$$;

-- #28 api.v_payload_queue
CREATE OR REPLACE VIEW api.v_payload_queue AS
SELECT
    dv.deal_version_id,
    d.deal_business_key,
    dv.deal_subtype_key,
    dv.current_gate_key,
    dv.lifecycle_status,
    dv.xero_payload_hash,
    dv.xero_payload_locked_at,
    dv.promoted_at
FROM core.deal_version dv
JOIN core.deal d
  ON d.deal_id = dv.deal_id
WHERE dv.current_gate_key IN ('G3', 'G4')
  AND dv.lifecycle_status NOT IN ('REJECTED', 'SUPERSEDED')
  AND dv.xero_payload_locked_at IS NULL;

-- #29 api.v_payload_locked
CREATE OR REPLACE VIEW api.v_payload_locked AS
SELECT
    dv.deal_version_id,
    d.deal_business_key,
    dv.deal_subtype_key,
    dv.current_gate_key,
    dv.lifecycle_status,
    dv.xero_payload_hash,
    dv.xero_payload_locked_at,
    dv.xero_payload_locked_by_identity_id,
    i.display_name AS locked_by_display_name,
    dv.promoted_at
FROM core.deal_version dv
JOIN core.deal d
  ON d.deal_id = dv.deal_id
LEFT JOIN security.identity i
  ON i.identity_id = dv.xero_payload_locked_by_identity_id
WHERE dv.xero_payload_locked_at IS NOT NULL;

-- -------------------------------------------------------------------------
-- Section 9 — Observability (2 surfaces)
-- -------------------------------------------------------------------------

-- #30 api.v_audit_timeline(deal_id?, dv_id?)
CREATE OR REPLACE FUNCTION api.v_audit_timeline(
    p_deal_id BIGINT DEFAULT NULL,
    p_deal_version_id BIGINT DEFAULT NULL
)
RETURNS TABLE (
    event_log_id BIGINT,
    deal_id BIGINT,
    deal_version_id BIGINT,
    event_type TEXT,
    gate_key TEXT,
    actor_identity_id BIGINT,
    actor_display_name TEXT,
    reason_code TEXT,
    correlation_id TEXT,
    event_payload JSONB,
    occurred_at TIMESTAMPTZ
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        el.event_log_id,
        el.deal_id,
        el.deal_version_id,
        el.event_type,
        el.gate_key,
        el.actor_identity_id,
        i.display_name AS actor_display_name,
        el.reason_code,
        el.correlation_id,
        el.event_payload,
        el.occurred_at
    FROM audit.event_log el
    LEFT JOIN security.identity i
      ON i.identity_id = el.actor_identity_id
    WHERE (p_deal_id IS NULL OR el.deal_id = p_deal_id)
      AND (p_deal_version_id IS NULL OR el.deal_version_id = p_deal_version_id)
    ORDER BY el.occurred_at DESC, el.event_log_id DESC;
$$;

-- #31 api.v_webhook_inbox
CREATE OR REPLACE VIEW api.v_webhook_inbox AS
SELECT
    we.webhook_event_id,
    we.provider_key,
    we.event_id,
    we.event_type,
    we.deal_version_id,
    we.dedupe_key,
    we.webhook_payload,
    we.process_status,
    we.process_error,
    we.correlation_id,
    we.received_at,
    we.processed_at
FROM audit.webhook_event we
ORDER BY we.received_at DESC;

-- -------------------------------------------------------------------------
-- Section 10 — Reference Catalogues (3 surfaces)
-- -------------------------------------------------------------------------

-- #32 api.v_deal_type_variant_options
CREATE OR REPLACE VIEW api.v_deal_type_variant_options AS
SELECT
    dtc.deal_type_key,
    dtc.display_name AS deal_type_name,
    dsc.deal_subtype_key,
    dsc.display_name AS deal_subtype_name,
    dt.deal_type_id,
    dtv.deal_type_variant_id,
    dtv.variant_key,
    dtv.display_name AS variant_name
FROM config.deal_type_catalog dtc
JOIN config.deal_subtype_catalog dsc
  ON dsc.deal_type_key = dtc.deal_type_key
LEFT JOIN config.deal_type dt
  ON dt.deal_type_key = dtc.deal_type_key
LEFT JOIN config.deal_type_variant dtv
  ON dtv.deal_type_id = dt.deal_type_id
WHERE dtc.is_active = TRUE
  AND dsc.is_active = TRUE;

-- #33 api.v_rejection_reason_codes(scope?)
CREATE OR REPLACE FUNCTION api.v_rejection_reason_codes(p_scope TEXT DEFAULT NULL)
RETURNS TABLE (
    reason_code TEXT,
    reason_category TEXT,
    reason_description TEXT
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        rc.reason_code,
        rc.reason_category,
        rc.reason_description
    FROM config.reason_code rc
    WHERE (p_scope IS NULL OR rc.reason_category = p_scope)
    ORDER BY rc.reason_category, rc.reason_code;
$$;

-- #34 api.v_broker_directory
CREATE OR REPLACE VIEW api.v_broker_directory AS
SELECT
    bd.broker_id,
    bd.person_id,
    bd.display_name,
    bd.division_id
FROM config.v_broker_directory bd;

-- -------------------------------------------------------------------------
-- Section 11 — Security hardening (SECURITY DEFINER + search_path)
-- -------------------------------------------------------------------------

ALTER FUNCTION api._compute_draft_hash(BIGINT) SECURITY DEFINER;
ALTER FUNCTION api._compute_draft_hash(BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.v_ops_draft_summary(BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.v_ops_draft_summary(BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.v_validation_issues(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.v_validation_issues(BIGINT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.ops_create_draft(TEXT, TEXT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.ops_create_draft(TEXT, TEXT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.ops_set_type_variant(BIGINT, TEXT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.ops_set_type_variant(BIGINT, TEXT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.ops_upsert_draft_party(BIGINT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN) SECURITY DEFINER;
ALTER FUNCTION api.ops_upsert_draft_party(BIGINT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.ops_upsert_draft_broker(BIGINT, BIGINT, TEXT, BOOLEAN, NUMERIC) SECURITY DEFINER;
ALTER FUNCTION api.ops_upsert_draft_broker(BIGINT, BIGINT, TEXT, BOOLEAN, NUMERIC)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.ops_upsert_draft_economics(BIGINT, NUMERIC, NUMERIC, NUMERIC, NUMERIC, JSONB) SECURITY DEFINER;
ALTER FUNCTION api.ops_upsert_draft_economics(BIGINT, NUMERIC, NUMERIC, NUMERIC, NUMERIC, JSONB)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.ops_upsert_draft_doc(BIGINT, TEXT, BOOLEAN, TEXT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.ops_upsert_draft_doc(BIGINT, TEXT, BOOLEAN, TEXT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.ops_validate_draft(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.ops_validate_draft(BIGINT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.ops_promote_to_core(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.ops_promote_to_core(BIGINT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.ops_create_revision_from_version(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.ops_create_revision_from_version(BIGINT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.finance_decide(BIGINT, TEXT, TEXT, TEXT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.finance_decide(BIGINT, TEXT, TEXT, TEXT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.approvals_generate_requirements(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.approvals_generate_requirements(BIGINT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.approvals_record_response(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT) SECURITY DEFINER;
ALTER FUNCTION api.approvals_record_response(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.v_payload_preview(BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.v_payload_preview(BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.payload_lock(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.payload_lock(BIGINT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.payload_finance_decide(BIGINT, TEXT, TEXT, TEXT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.payload_finance_decide(BIGINT, TEXT, TEXT, TEXT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.v_audit_timeline(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.v_audit_timeline(BIGINT, BIGINT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

ALTER FUNCTION api.v_rejection_reason_codes(TEXT) SECURITY DEFINER;
ALTER FUNCTION api.v_rejection_reason_codes(TEXT)
    SET search_path = pg_catalog, api, raw, ops, core, audit, config, security, public;

-- -------------------------------------------------------------------------
-- Section 12 — Grants matrix
-- -------------------------------------------------------------------------

-- Revoke broad defaults
REVOKE ALL ON SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA api FROM PUBLIC;

-- Grant usage to all app roles
GRANT USAGE ON SCHEMA api TO app_ops, app_finance, app_broker, app_ui, app_system;

-- Sequence grants for write functions
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ops TO app_ops, app_system;
GRANT USAGE, SELECT ON SEQUENCE ops.validation_run_run_id_seq TO app_ops, app_system;

-- === app_ops ===
-- Draft views (SELECT)
GRANT SELECT ON api.v_ops_draft_header TO app_ops;
GRANT SELECT ON api.v_ops_draft_parties TO app_ops;
GRANT SELECT ON api.v_ops_draft_transaction TO app_ops;
GRANT SELECT ON api.v_ops_draft_docs TO app_ops;
GRANT SELECT ON api.v_ops_draft_required_docs_status TO app_ops;
GRANT SELECT ON api.v_ops_draft_brokers TO app_ops;
GRANT SELECT ON api.v_ops_draft_commercial_outputs TO app_ops;
GRANT SELECT ON api.v_validation_latest TO app_ops;
-- Draft write functions (EXECUTE)
GRANT EXECUTE ON FUNCTION api.ops_create_draft(TEXT, TEXT, BIGINT) TO app_ops;
GRANT EXECUTE ON FUNCTION api.ops_set_type_variant(BIGINT, TEXT, BIGINT) TO app_ops;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_party(BIGINT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN) TO app_ops;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_broker(BIGINT, BIGINT, TEXT, BOOLEAN, NUMERIC) TO app_ops;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_economics(BIGINT, NUMERIC, NUMERIC, NUMERIC, NUMERIC, JSONB) TO app_ops;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_doc(BIGINT, TEXT, BOOLEAN, TEXT, BIGINT) TO app_ops;
GRANT EXECUTE ON FUNCTION api.ops_validate_draft(BIGINT, BIGINT) TO app_ops;
GRANT EXECUTE ON FUNCTION api.ops_promote_to_core(BIGINT, BIGINT) TO app_ops;
GRANT EXECUTE ON FUNCTION api.v_ops_draft_summary(BIGINT) TO app_ops;
GRANT EXECUTE ON FUNCTION api.v_validation_issues(BIGINT, BIGINT) TO app_ops;
GRANT EXECUTE ON FUNCTION api.ops_create_revision_from_version(BIGINT, BIGINT) TO app_ops;
-- Pipeline/tasks
GRANT SELECT ON api.v_my_deals TO app_ops;
GRANT SELECT ON api.v_my_tasks TO app_ops;
-- Approval views
GRANT SELECT ON api.v_approval_requirements TO app_ops;
GRANT SELECT ON api.v_approval_responses TO app_ops;

-- === app_finance ===
-- Finance queue + decide
GRANT SELECT ON api.v_finance_queue TO app_finance;
GRANT EXECUTE ON FUNCTION api.finance_decide(BIGINT, TEXT, TEXT, TEXT, BIGINT) TO app_finance;
-- Approval surfaces
GRANT SELECT ON api.v_approval_requirements TO app_finance;
GRANT SELECT ON api.v_approval_responses TO app_finance;
GRANT EXECUTE ON FUNCTION api.approvals_generate_requirements(BIGINT, BIGINT) TO app_finance;
GRANT EXECUTE ON FUNCTION api.approvals_record_response(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT) TO app_finance;
-- Payload surfaces
GRANT SELECT ON api.v_payload_queue TO app_finance;
GRANT SELECT ON api.v_payload_locked TO app_finance;
GRANT EXECUTE ON FUNCTION api.v_payload_preview(BIGINT) TO app_finance;
GRANT EXECUTE ON FUNCTION api.payload_lock(BIGINT, BIGINT) TO app_finance;
GRANT EXECUTE ON FUNCTION api.payload_finance_decide(BIGINT, TEXT, TEXT, TEXT, BIGINT) TO app_finance;
-- Audit
GRANT EXECUTE ON FUNCTION api.v_audit_timeline(BIGINT, BIGINT) TO app_finance;
-- Pipeline
GRANT SELECT ON api.v_my_deals TO app_finance;
GRANT SELECT ON api.v_my_tasks TO app_finance;
-- Reference
GRANT EXECUTE ON FUNCTION api.v_rejection_reason_codes(TEXT) TO app_finance;

-- === app_broker ===
GRANT SELECT ON api.v_my_deals TO app_broker;
GRANT SELECT ON api.v_approval_requirements TO app_broker;
-- Reference catalogues
GRANT SELECT ON api.v_deal_type_variant_options TO app_broker;
GRANT SELECT ON api.v_broker_directory TO app_broker;
GRANT EXECUTE ON FUNCTION api.v_rejection_reason_codes(TEXT) TO app_broker;

-- === app_ui ===
-- Draft views (read-only)
GRANT SELECT ON api.v_ops_draft_header TO app_ui;
GRANT SELECT ON api.v_ops_draft_parties TO app_ui;
GRANT SELECT ON api.v_ops_draft_transaction TO app_ui;
GRANT SELECT ON api.v_ops_draft_docs TO app_ui;
GRANT SELECT ON api.v_ops_draft_required_docs_status TO app_ui;
GRANT SELECT ON api.v_ops_draft_brokers TO app_ui;
GRANT SELECT ON api.v_ops_draft_commercial_outputs TO app_ui;
-- Validation views
GRANT SELECT ON api.v_validation_latest TO app_ui;
GRANT EXECUTE ON FUNCTION api.v_ops_draft_summary(BIGINT) TO app_ui;
GRANT EXECUTE ON FUNCTION api.v_validation_issues(BIGINT, BIGINT) TO app_ui;
-- Reference catalogues
GRANT SELECT ON api.v_deal_type_variant_options TO app_ui;
GRANT SELECT ON api.v_broker_directory TO app_ui;
GRANT EXECUTE ON FUNCTION api.v_rejection_reason_codes(TEXT) TO app_ui;

-- === app_system ===
-- Broad read + execute
GRANT SELECT ON api.v_ops_draft_header TO app_system;
GRANT SELECT ON api.v_ops_draft_parties TO app_system;
GRANT SELECT ON api.v_ops_draft_transaction TO app_system;
GRANT SELECT ON api.v_ops_draft_docs TO app_system;
GRANT SELECT ON api.v_ops_draft_required_docs_status TO app_system;
GRANT SELECT ON api.v_ops_draft_brokers TO app_system;
GRANT SELECT ON api.v_ops_draft_commercial_outputs TO app_system;
GRANT SELECT ON api.v_validation_latest TO app_system;
GRANT SELECT ON api.v_my_deals TO app_system;
GRANT SELECT ON api.v_my_tasks TO app_system;
GRANT SELECT ON api.v_finance_queue TO app_system;
GRANT SELECT ON api.v_approval_requirements TO app_system;
GRANT SELECT ON api.v_approval_responses TO app_system;
GRANT SELECT ON api.v_payload_queue TO app_system;
GRANT SELECT ON api.v_payload_locked TO app_system;
GRANT SELECT ON api.v_webhook_inbox TO app_system;
GRANT SELECT ON api.v_deal_type_variant_options TO app_system;
GRANT SELECT ON api.v_broker_directory TO app_system;
GRANT EXECUTE ON FUNCTION api.ops_create_draft(TEXT, TEXT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.ops_set_type_variant(BIGINT, TEXT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_party(BIGINT, TEXT, TEXT, TEXT, TEXT, BOOLEAN, BOOLEAN) TO app_system;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_broker(BIGINT, BIGINT, TEXT, BOOLEAN, NUMERIC) TO app_system;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_economics(BIGINT, NUMERIC, NUMERIC, NUMERIC, NUMERIC, JSONB) TO app_system;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_doc(BIGINT, TEXT, BOOLEAN, TEXT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.ops_validate_draft(BIGINT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.ops_promote_to_core(BIGINT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.ops_create_revision_from_version(BIGINT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.v_ops_draft_summary(BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.v_validation_issues(BIGINT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.finance_decide(BIGINT, TEXT, TEXT, TEXT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.approvals_generate_requirements(BIGINT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.approvals_record_response(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT) TO app_system;
GRANT EXECUTE ON FUNCTION api.v_payload_preview(BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.payload_lock(BIGINT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.payload_finance_decide(BIGINT, TEXT, TEXT, TEXT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.v_audit_timeline(BIGINT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION api.v_rejection_reason_codes(TEXT) TO app_system;

COMMIT;
