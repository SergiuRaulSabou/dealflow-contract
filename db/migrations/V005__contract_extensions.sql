BEGIN;

-- ---------------------------------------------------------------------------
-- Milestone 4: regression contract extensions + deterministic payload surfaces
-- ---------------------------------------------------------------------------

CREATE TABLE IF NOT EXISTS config.deal_type_catalog (
    deal_type_key TEXT PRIMARY KEY,
    display_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.deal_subtype_catalog (
    deal_subtype_key TEXT PRIMARY KEY,
    deal_type_key TEXT NOT NULL REFERENCES config.deal_type_catalog (deal_type_key),
    display_name TEXT NOT NULL,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE TABLE IF NOT EXISTS config.commission_rule (
    commission_rule_id BIGSERIAL PRIMARY KEY,
    deal_type_key TEXT NOT NULL REFERENCES config.deal_type_catalog (deal_type_key),
    rule_key TEXT NOT NULL,
    effective_from DATE NOT NULL,
    parameters JSONB NOT NULL DEFAULT '{}'::jsonb,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_type_key, rule_key, effective_from)
);

ALTER TABLE core.deal_version
    ADD COLUMN IF NOT EXISTS deal_subtype_key TEXT;

ALTER TABLE core.deal_version
    ADD COLUMN IF NOT EXISTS xero_payload_hash TEXT;

ALTER TABLE core.deal_version
    ADD COLUMN IF NOT EXISTS xero_payload_locked_at TIMESTAMPTZ;

ALTER TABLE core.deal_version
    ADD COLUMN IF NOT EXISTS xero_payload_locked_by_identity_id BIGINT;

DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM pg_constraint c
        WHERE c.conname = 'fk_core_deal_version_xero_payload_locked_by_identity'
          AND c.conrelid = 'core.deal_version'::regclass
    ) THEN
        ALTER TABLE core.deal_version
            ADD CONSTRAINT fk_core_deal_version_xero_payload_locked_by_identity
            FOREIGN KEY (xero_payload_locked_by_identity_id)
            REFERENCES security.identity (identity_id);
    END IF;
END;
$$;

UPDATE core.deal_version dv
SET deal_subtype_key = od.deal_subtype_key
FROM ops.deal_draft od
WHERE dv.submitted_from_draft_id = od.draft_id
  AND dv.deal_subtype_key IS NULL;

CREATE INDEX IF NOT EXISTS ix_core_deal_version_deal_subtype_key
    ON core.deal_version (deal_subtype_key);

CREATE OR REPLACE VIEW config.v_deal_types AS
SELECT
    dt.deal_type_key,
    dt.display_name,
    dt.is_active
FROM config.deal_type_catalog dt;

CREATE OR REPLACE VIEW config.v_role_catalogue AS
SELECT
    rc.role_key,
    rc.role_name AS display_name,
    gate_map.gate_key
FROM config.role_catalog rc
LEFT JOIN (
    SELECT DISTINCT
        ar.required_role_key,
        ar.gate_key
    FROM config.approval_rule ar
) gate_map
    ON gate_map.required_role_key = rc.role_key
WHERE rc.is_active = TRUE;

CREATE OR REPLACE VIEW config.v_broker_directory AS
SELECT
    i.identity_id AS broker_id,
    i.identity_id AS person_id,
    COALESCE(i.display_name, i.email) AS display_name,
    dm.division_key AS division_id
FROM security.role_assignment ra
JOIN security.identity i
  ON i.identity_id = ra.identity_id
LEFT JOIN LATERAL (
    SELECT bdm.division_key
    FROM security.broker_division_map bdm
    WHERE bdm.broker_external_ref = i.email
      AND bdm.is_active = TRUE
      AND (bdm.valid_to IS NULL OR bdm.valid_to > NOW())
    ORDER BY bdm.valid_from DESC
    LIMIT 1
) dm ON TRUE
WHERE ra.role_key = 'BROKER';

CREATE OR REPLACE FUNCTION config.v_doc_requirements(p_deal_type_key TEXT)
RETURNS TABLE (
    doc_type_key TEXT,
    is_mandatory BOOLEAN,
    gate_key TEXT
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        dcti.checklist_item_key AS doc_type_key,
        BOOL_OR(dcti.is_required) AS is_mandatory,
        MIN(dcti.gate_key) AS gate_key
    FROM config.deal_subtype_catalog dsc
    JOIN config.doc_checklist_template dct
      ON dct.deal_subtype_key = dsc.deal_subtype_key
     AND dct.is_active = TRUE
    JOIN config.doc_checklist_template_item dcti
      ON dcti.doc_checklist_template_id = dct.doc_checklist_template_id
    WHERE dsc.deal_type_key = p_deal_type_key
      AND dsc.is_active = TRUE
    GROUP BY dcti.checklist_item_key
    ORDER BY dcti.checklist_item_key;
$$;

CREATE OR REPLACE FUNCTION config.v_commission_rules(p_deal_type_key TEXT)
RETURNS TABLE (
    rule_key TEXT,
    effective_from DATE,
    parameters JSONB
)
LANGUAGE sql
STABLE
AS $$
    SELECT
        cr.rule_key,
        cr.effective_from,
        cr.parameters
    FROM config.commission_rule cr
    WHERE cr.is_active = TRUE
      AND (p_deal_type_key IS NULL OR cr.deal_type_key = p_deal_type_key)
    ORDER BY cr.rule_key, cr.effective_from DESC;
$$;

CREATE OR REPLACE FUNCTION ops.preview_draft(
    p_draft_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_draft ops.deal_draft%ROWTYPE;
    v_econ ops.deal_draft_economics%ROWTYPE;
    v_template_id BIGINT;
    v_requires_fica BOOLEAN := FALSE;
    v_errors JSONB := '[]'::jsonb;
    v_warnings JSONB := '[]'::jsonb;
    v_econ_preview JSONB := '{}'::jsonb;
    v_broker_split_total NUMERIC(18, 4);
    r RECORD;
BEGIN
    SELECT d.*
    INTO v_draft
    FROM ops.deal_draft d
    WHERE d.draft_id = p_draft_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'draft_id % not found', p_draft_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM config.deal_subtype_catalog dsc
        WHERE dsc.deal_subtype_key = v_draft.deal_subtype_key
          AND dsc.is_active = TRUE
    ) THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'rule_code', 'DEAL_SUBTYPE_INVALID',
                'severity', 'ERROR',
                'field_path', 'ops.deal_draft.deal_subtype_key',
                'message', 'Deal subtype key is not in the active catalog.'
            )
        );
    END IF;

    SELECT dct.doc_checklist_template_id
    INTO v_template_id
    FROM config.doc_checklist_template dct
    WHERE dct.deal_subtype_key = v_draft.deal_subtype_key
      AND dct.is_active = TRUE
    ORDER BY dct.created_at DESC
    LIMIT 1;

    IF v_template_id IS NULL THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'rule_code', 'DOC_TEMPLATE_MISSING',
                'severity', 'ERROR',
                'field_path', 'config.doc_checklist_template',
                'message', 'No active document checklist template exists for this deal subtype.'
            )
        );
    END IF;

    SELECT (
        COALESCE(v_draft.is_jse_listed, FALSE)
        OR EXISTS (
            SELECT 1
            FROM ops.deal_draft_party p
            WHERE p.draft_id = p_draft_id
              AND p.requires_fica = TRUE
        )
    )
    INTO v_requires_fica;

    IF v_template_id IS NOT NULL THEN
        FOR r IN
            WITH required_items AS (
                SELECT
                    dcti.checklist_item_key AS doc_code,
                    CASE
                        WHEN dcti.checklist_item_key = 'FICA_COMPLETE'
                             AND EXISTS (
                                 SELECT 1
                                 FROM config.doc_checklist_conditional_rule c
                                 WHERE c.doc_checklist_template_item_id = dcti.doc_checklist_template_item_id
                                   AND c.condition_key = 'REQUIRES_FICA_OR_JSE'
                             )
                        THEN v_requires_fica
                        ELSE dcti.is_required
                    END AS is_required
                FROM config.doc_checklist_template_item dcti
                WHERE dcti.doc_checklist_template_id = v_template_id
            )
            SELECT ri.doc_code
            FROM required_items ri
            LEFT JOIN ops.deal_draft_doc_status ds
              ON ds.draft_id = p_draft_id
             AND ds.doc_code = ri.doc_code
            WHERE ri.is_required = TRUE
              AND ds.draft_doc_status_id IS NULL
            ORDER BY ri.doc_code
        LOOP
            v_errors := v_errors || jsonb_build_array(
                jsonb_build_object(
                    'rule_code', 'DOC_REQUIRED',
                    'severity', 'ERROR',
                    'field_path', 'ops.deal_draft_doc_status.' || r.doc_code,
                    'message', 'Document ' || r.doc_code || ' is required.'
                )
            );
        END LOOP;

        FOR r IN
            WITH required_items AS (
                SELECT
                    dcti.checklist_item_key AS doc_code,
                    CASE
                        WHEN dcti.checklist_item_key = 'FICA_COMPLETE'
                             AND EXISTS (
                                 SELECT 1
                                 FROM config.doc_checklist_conditional_rule c
                                 WHERE c.doc_checklist_template_item_id = dcti.doc_checklist_template_item_id
                                   AND c.condition_key = 'REQUIRES_FICA_OR_JSE'
                             )
                        THEN v_requires_fica
                        ELSE dcti.is_required
                    END AS is_required
                FROM config.doc_checklist_template_item dcti
                WHERE dcti.doc_checklist_template_id = v_template_id
            )
            SELECT ds.doc_code
            FROM ops.deal_draft_doc_status ds
            JOIN required_items ri
              ON ri.doc_code = ds.doc_code
             AND ri.is_required = TRUE
            WHERE ds.draft_id = p_draft_id
              AND ds.is_confirmed = FALSE
            ORDER BY ds.doc_code
        LOOP
            v_errors := v_errors || jsonb_build_array(
                jsonb_build_object(
                    'rule_code', 'DOC_NOT_CONFIRMED',
                    'severity', 'ERROR',
                    'field_path', 'ops.deal_draft_doc_status.' || r.doc_code,
                    'message', 'Document ' || r.doc_code || ' is not confirmed.'
                )
            );
        END LOOP;
    END IF;

    SELECT e.*
    INTO v_econ
    FROM ops.deal_draft_economics e
    WHERE e.draft_id = p_draft_id;

    IF NOT FOUND THEN
        v_errors := v_errors || jsonb_build_array(
            jsonb_build_object(
                'rule_code', 'ECONOMICS_REQUIRED',
                'severity', 'ERROR',
                'field_path', 'ops.deal_draft_economics',
                'message', 'Economics are required to submit.'
            )
        );
    ELSE
        v_econ_preview := jsonb_build_object(
            'gross_billings', v_econ.gross_billings,
            'commission_total', v_econ.commission_total,
            'company_split_pct', v_econ.company_split_pct,
            'broker_split_pct', v_econ.broker_split_pct,
            'commission_rate_pct',
                CASE
                    WHEN v_econ.gross_billings IS NULL OR v_econ.gross_billings = 0 THEN NULL
                    ELSE ROUND((v_econ.commission_total / v_econ.gross_billings) * 100.0, 4)
                END
        );

        IF v_econ.gross_billings IS NULL OR v_econ.gross_billings <= 0 THEN
            v_errors := v_errors || jsonb_build_array(
                jsonb_build_object(
                    'rule_code', 'ECON_GROSS_INVALID',
                    'severity', 'ERROR',
                    'field_path', 'ops.deal_draft_economics.gross_billings',
                    'message', 'Gross billings must be greater than zero.'
                )
            );
        END IF;

        IF v_econ.commission_total IS NULL
           OR v_econ.commission_total < 0
           OR (v_econ.gross_billings IS NOT NULL AND v_econ.commission_total > v_econ.gross_billings) THEN
            v_errors := v_errors || jsonb_build_array(
                jsonb_build_object(
                    'rule_code', 'ECON_COMMISSION_INVALID',
                    'severity', 'ERROR',
                    'field_path', 'ops.deal_draft_economics.commission_total',
                    'message', 'Commission total must be >= 0 and <= gross billings.'
                )
            );
        END IF;

        IF v_econ.company_split_pct IS NULL
           OR v_econ.broker_split_pct IS NULL
           OR ROUND(v_econ.company_split_pct + v_econ.broker_split_pct, 4) <> 100.0000 THEN
            v_errors := v_errors || jsonb_build_array(
                jsonb_build_object(
                    'rule_code', 'ECON_SPLIT_INVALID',
                    'severity', 'ERROR',
                    'field_path', 'ops.deal_draft_economics.company_split_pct',
                    'message', 'Company and broker split percentages must sum to 100.'
                )
            );
        END IF;

        SELECT ROUND(COALESCE(SUM(COALESCE(b.split_percent, 0.0)), 0.0), 4)
        INTO v_broker_split_total
        FROM ops.deal_draft_broker b
        WHERE b.draft_id = p_draft_id;

        IF EXISTS (SELECT 1 FROM ops.deal_draft_broker b WHERE b.draft_id = p_draft_id)
           AND v_broker_split_total <> 100.0000 THEN
            v_errors := v_errors || jsonb_build_array(
                jsonb_build_object(
                    'rule_code', 'BROKER_SPLIT_INVALID',
                    'severity', 'ERROR',
                    'field_path', 'ops.deal_draft_broker.split_percent',
                    'message', 'Broker split percentages must sum to 100.'
                )
            );
        END IF;
    END IF;

    RETURN jsonb_build_object(
        'draft_id', p_draft_id,
        'deal_subtype_key', v_draft.deal_subtype_key,
        'validation_errors', v_errors,
        'warnings', v_warnings,
        'economics_preview', v_econ_preview
    );
END;
$$;

CREATE OR REPLACE FUNCTION ops.create_draft_from_deal_version(
    p_source_deal_version_id BIGINT,
    p_created_by_identity_id BIGINT,
    p_new_business_key TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_source core.deal_version%ROWTYPE;
    v_source_business_key TEXT;
    v_new_draft_id BIGINT;
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM security.identity i
        WHERE i.identity_id = p_created_by_identity_id
    ) THEN
        RAISE EXCEPTION 'created_by_identity_id % does not exist', p_created_by_identity_id;
    END IF;

    SELECT dv.*
    INTO v_source
    FROM core.deal_version dv
    WHERE dv.deal_version_id = p_source_deal_version_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'deal_version_id % not found', p_source_deal_version_id;
    END IF;

    SELECT d.deal_business_key
    INTO v_source_business_key
    FROM core.deal d
    WHERE d.deal_id = v_source.deal_id;

    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        draft_status,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id,
        source_deal_version_id,
        is_jse_listed
    )
    VALUES (
        COALESCE(NULLIF(p_new_business_key, ''), v_source_business_key),
        COALESCE(v_source.deal_subtype_key, 'LEASE_ACQUISITION_OR_RENEWAL'),
        'DRAFT',
        'G0',
        p_created_by_identity_id,
        p_created_by_identity_id,
        p_source_deal_version_id,
        COALESCE(v_source.is_jse_listed, FALSE)
    )
    RETURNING draft_id INTO v_new_draft_id;

    INSERT INTO ops.deal_draft_party (
        draft_id,
        party_role_key,
        party_name,
        party_email,
        party_phone,
        is_primary,
        requires_fica
    )
    SELECT
        v_new_draft_id,
        p.party_role_key,
        p.party_name,
        p.party_email,
        p.party_phone,
        FALSE,
        COALESCE(p.requires_fica, FALSE)
    FROM core.deal_version_party p
    WHERE p.deal_version_id = p_source_deal_version_id;

    INSERT INTO ops.deal_draft_broker (
        draft_id,
        broker_identity_id,
        broker_external_ref,
        is_lead_broker,
        split_percent
    )
    SELECT
        v_new_draft_id,
        b.broker_identity_id,
        b.broker_external_ref,
        b.is_lead_broker,
        b.split_percent
    FROM core.deal_version_broker b
    WHERE b.deal_version_id = p_source_deal_version_id;

    INSERT INTO ops.deal_draft_economics (
        draft_id,
        gross_billings,
        commission_total,
        company_split_pct,
        broker_split_pct,
        economics_payload
    )
    SELECT
        v_new_draft_id,
        e.gross_billings,
        e.commission_total,
        e.company_split_pct,
        e.broker_split_pct,
        e.economics_payload
    FROM core.deal_version_economics e
    WHERE e.deal_version_id = p_source_deal_version_id;

    INSERT INTO ops.deal_draft_doc_status (
        draft_id,
        doc_checklist_template_item_id,
        doc_code,
        is_confirmed,
        note,
        confirmed_by_identity_id,
        confirmed_at
    )
    SELECT
        v_new_draft_id,
        s.doc_checklist_template_item_id,
        s.doc_code,
        s.is_confirmed,
        s.note,
        p_created_by_identity_id,
        CASE WHEN s.is_confirmed THEN NOW() ELSE NULL END
    FROM core.deal_version_doc_checklist_status s
    WHERE s.deal_version_id = p_source_deal_version_id;

    INSERT INTO audit.event_log (
        deal_id,
        deal_version_id,
        event_type,
        gate_key,
        actor_identity_id,
        event_payload
    )
    VALUES (
        v_source.deal_id,
        p_source_deal_version_id,
        'DRAFT_INHERITED',
        'G0',
        p_created_by_identity_id,
        jsonb_build_object(
            'source_deal_version_id', p_source_deal_version_id,
            'new_draft_id', v_new_draft_id
        )
    );

    RETURN v_new_draft_id;
END;
$$;

CREATE OR REPLACE FUNCTION core.record_gate_decision(
    p_deal_version_id BIGINT,
    p_gate_key TEXT,
    p_required_role_key TEXT,
    p_actor_identity_id BIGINT,
    p_decision_key TEXT,
    p_reason_code TEXT DEFAULT NULL,
    p_response_comment TEXT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_requirement_id BIGINT;
    v_deal_id BIGINT;
    v_current_gate_key TEXT;
    v_all_resolved BOOLEAN;
    v_next_gate_key TEXT;
BEGIN
    IF p_decision_key NOT IN ('APPROVED', 'REJECTED', 'CHANGE_REQUESTED') THEN
        RAISE EXCEPTION 'Unsupported decision_key: %', p_decision_key;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM security.identity i
        WHERE i.identity_id = p_actor_identity_id
    ) THEN
        RAISE EXCEPTION 'actor_identity_id % does not exist', p_actor_identity_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM security.role_assignment ra
        WHERE ra.identity_id = p_actor_identity_id
          AND ra.role_key = p_required_role_key
    ) THEN
        RAISE EXCEPTION 'actor_identity_id % is not assigned required role %', p_actor_identity_id, p_required_role_key;
    END IF;

    SELECT dv.deal_id, dv.current_gate_key
    INTO v_deal_id, v_current_gate_key
    FROM core.deal_version dv
    WHERE dv.deal_version_id = p_deal_version_id;

    IF v_deal_id IS NULL THEN
        RAISE EXCEPTION 'deal_version_id % does not exist', p_deal_version_id;
    END IF;

    IF v_current_gate_key IS DISTINCT FROM p_gate_key THEN
        RAISE EXCEPTION 'deal_version_id % gate mismatch: expected %, actual %', p_deal_version_id, p_gate_key, v_current_gate_key;
    END IF;

    SELECT ar.approval_requirement_id
    INTO v_requirement_id
    FROM core.approval_requirement ar
    WHERE ar.deal_version_id = p_deal_version_id
      AND ar.gate_key = p_gate_key
      AND ar.required_role_key = p_required_role_key
    ORDER BY ar.approval_requirement_id
    LIMIT 1;

    IF v_requirement_id IS NULL THEN
        RAISE EXCEPTION 'No approval requirement for deal_version_id %, gate %, role %', p_deal_version_id, p_gate_key, p_required_role_key;
    END IF;

    INSERT INTO core.approval_response (
        approval_requirement_id,
        deal_version_id,
        actor_identity_id,
        response_key,
        reason_code,
        response_comment,
        responded_at
    )
    VALUES (
        v_requirement_id,
        p_deal_version_id,
        p_actor_identity_id,
        p_decision_key,
        p_reason_code,
        COALESCE(p_response_comment, 'Recorded by core.record_gate_decision'),
        NOW()
    );

    UPDATE core.approval_requirement ar
    SET requirement_status = CASE
                                WHEN p_decision_key = 'APPROVED' THEN 'APPROVED'
                                WHEN p_decision_key = 'CHANGE_REQUESTED' THEN 'REJECTED'
                                ELSE 'REJECTED'
                             END,
        resolved_at = NOW()
    WHERE ar.approval_requirement_id = v_requirement_id;

    IF p_decision_key IN ('REJECTED', 'CHANGE_REQUESTED') THEN
        UPDATE core.approval_requirement ar
        SET requirement_status = CASE
                                    WHEN ar.requirement_status = 'OPEN' THEN 'INVALIDATED'
                                    ELSE ar.requirement_status
                                 END,
            resolved_at = CASE
                             WHEN ar.requirement_status = 'OPEN' THEN NOW()
                             ELSE ar.resolved_at
                          END
        WHERE ar.deal_version_id = p_deal_version_id
          AND ar.approval_requirement_id <> v_requirement_id;

        UPDATE core.deal_version dv
        SET lifecycle_status = 'REJECTED'
        WHERE dv.deal_version_id = p_deal_version_id;

        INSERT INTO audit.event_log (
            deal_id,
            deal_version_id,
            event_type,
            gate_key,
            actor_identity_id,
            reason_code,
            event_payload
        )
        VALUES (
            v_deal_id,
            p_deal_version_id,
            'GATE_REJECTED',
            p_gate_key,
            p_actor_identity_id,
            COALESCE(p_reason_code, 'FINANCE_REJECTED'),
            jsonb_build_object(
                'decision_key', p_decision_key,
                'role_key', p_required_role_key,
                'comment', p_response_comment
            )
        );

        RETURN;
    END IF;

    SELECT COALESCE(BOOL_AND(ar.requirement_status IN ('APPROVED', 'RESOLVED')), FALSE)
    INTO v_all_resolved
    FROM core.approval_requirement ar
    WHERE ar.deal_version_id = p_deal_version_id
      AND ar.gate_key = p_gate_key;

    IF v_all_resolved THEN
        IF p_gate_key = 'G1' THEN
            v_next_gate_key := 'G2';
        ELSIF p_gate_key = 'G2' THEN
            v_next_gate_key := 'G3';
        ELSIF p_gate_key = 'G3' THEN
            v_next_gate_key := 'G4';
        ELSE
            v_next_gate_key := p_gate_key;
        END IF;

        UPDATE core.deal_version dv
        SET current_gate_key = v_next_gate_key,
            lifecycle_status = CASE
                                  WHEN v_next_gate_key = 'G4' THEN 'READY_FOR_XERO'
                                  ELSE dv.lifecycle_status
                               END
        WHERE dv.deal_version_id = p_deal_version_id;

        IF v_next_gate_key IN ('G2', 'G3') THEN
            PERFORM core.materialize_approval_requirements(p_deal_version_id, v_next_gate_key, 'DEFAULT_GATES_0_3');
        END IF;

        INSERT INTO audit.event_log (
            deal_id,
            deal_version_id,
            event_type,
            gate_key,
            actor_identity_id,
            event_payload
        )
        VALUES (
            v_deal_id,
            p_deal_version_id,
            CASE
                WHEN v_next_gate_key = 'G4' THEN 'G3_COMPLETED'
                ELSE v_next_gate_key || '_ENTERED'
            END,
            v_next_gate_key,
            p_actor_identity_id,
            jsonb_build_object(
                'decision_key', p_decision_key,
                'role_key', p_required_role_key,
                'from_gate', p_gate_key,
                'to_gate', v_next_gate_key
            )
        );
    ELSE
        INSERT INTO audit.event_log (
            deal_id,
            deal_version_id,
            event_type,
            gate_key,
            actor_identity_id,
            event_payload
        )
        VALUES (
            v_deal_id,
            p_deal_version_id,
            'GATE_APPROVAL_RECORDED',
            p_gate_key,
            p_actor_identity_id,
            jsonb_build_object(
                'decision_key', p_decision_key,
                'role_key', p_required_role_key
            )
        );
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION core.record_signwell_envelope(
    p_deal_version_id BIGINT,
    p_gate_key TEXT,
    p_external_envelope_id TEXT,
    p_dedupe_key TEXT DEFAULT NULL,
    p_actor_identity_id BIGINT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_envelope_id BIGINT;
    v_deal_id BIGINT;
BEGIN
    IF NULLIF(p_external_envelope_id, '') IS NULL THEN
        RAISE EXCEPTION 'external_envelope_id is required';
    END IF;

    PERFORM core.assert_send_eligible(p_deal_version_id, p_gate_key);

    INSERT INTO core.signwell_envelope (
        deal_version_id,
        gate_key,
        external_envelope_id,
        dedupe_key,
        envelope_status,
        sent_at
    )
    VALUES (
        p_deal_version_id,
        p_gate_key,
        p_external_envelope_id,
        COALESCE(NULLIF(p_dedupe_key, ''), 'SIGNWELL:' || p_external_envelope_id),
        'SENT',
        NOW()
    )
    ON CONFLICT (external_envelope_id) DO UPDATE
    SET dedupe_key = COALESCE(EXCLUDED.dedupe_key, core.signwell_envelope.dedupe_key),
        envelope_status = 'SENT',
        sent_at = COALESCE(core.signwell_envelope.sent_at, EXCLUDED.sent_at)
    RETURNING signwell_envelope_id INTO v_envelope_id;

    SELECT dv.deal_id
    INTO v_deal_id
    FROM core.deal_version dv
    WHERE dv.deal_version_id = p_deal_version_id;

    INSERT INTO audit.event_log (
        deal_id,
        deal_version_id,
        event_type,
        gate_key,
        actor_identity_id,
        event_payload
    )
    VALUES (
        v_deal_id,
        p_deal_version_id,
        'SIGNWELL_ENVELOPE_RECORDED',
        p_gate_key,
        p_actor_identity_id,
        jsonb_build_object(
            'envelope_id', p_external_envelope_id,
            'dedupe_key', COALESCE(NULLIF(p_dedupe_key, ''), 'SIGNWELL:' || p_external_envelope_id)
        )
    );

    RETURN v_envelope_id;
END;
$$;

CREATE OR REPLACE FUNCTION core.get_signwell_payload(
    p_deal_version_id BIGINT,
    p_gate_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_deal_business_key TEXT;
    v_deal_subtype_key TEXT;
    v_template_external_id TEXT;
    v_template_version TEXT;
    v_lead_broker_email TEXT;
    v_division_head_email TEXT;
    v_gross_billings NUMERIC(18, 2);
    v_commission_total NUMERIC(18, 2);
    v_field_values JSONB;
    v_strict_fields JSONB;
    v_recipients JSONB := '[]'::jsonb;
    v_missing_field_key TEXT;
BEGIN
    SELECT
        d.deal_business_key,
        dv.deal_subtype_key,
        e.gross_billings,
        e.commission_total
    INTO
        v_deal_business_key,
        v_deal_subtype_key,
        v_gross_billings,
        v_commission_total
    FROM core.deal_version dv
    JOIN core.deal d
      ON d.deal_id = dv.deal_id
    LEFT JOIN core.deal_version_economics e
      ON e.deal_version_id = dv.deal_version_id
    WHERE dv.deal_version_id = p_deal_version_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'deal_version_id % not found', p_deal_version_id;
    END IF;

    IF COALESCE(v_deal_subtype_key, '') = '' THEN
        RAISE EXCEPTION 'deal_subtype_key cannot be resolved for deal_version_id %', p_deal_version_id;
    END IF;

    SELECT
        st.template_external_id,
        st.template_version
    INTO
        v_template_external_id,
        v_template_version
    FROM config.signwell_template st
    WHERE st.gate_key = p_gate_key
      AND st.deal_subtype_key = v_deal_subtype_key
      AND st.is_active = TRUE
    ORDER BY st.created_at DESC
    LIMIT 1;

    IF v_template_external_id IS NULL THEN
        RAISE EXCEPTION 'No active Signwell template for gate % and subtype %', p_gate_key, v_deal_subtype_key;
    END IF;

    SELECT LOWER(i.email)
    INTO v_lead_broker_email
    FROM core.deal_version_broker b
    JOIN security.identity i
      ON i.identity_id = b.broker_identity_id
    WHERE b.deal_version_id = p_deal_version_id
      AND b.is_lead_broker = TRUE
    ORDER BY b.deal_version_broker_id ASC
    LIMIT 1;

    SELECT LOWER(i.email)
    INTO v_division_head_email
    FROM security.role_assignment ra
    JOIN security.identity i
      ON i.identity_id = ra.identity_id
    WHERE ra.role_key = 'DIVISION_HEAD'
    ORDER BY ra.assigned_at DESC, ra.identity_id DESC
    LIMIT 1;

    v_field_values := jsonb_build_object(
        'deal_business_key', to_jsonb(v_deal_business_key),
        'deal_subtype_key', to_jsonb(v_deal_subtype_key),
        'gross_billings', to_jsonb(v_gross_billings),
        'commission_total', to_jsonb(v_commission_total),
        'lead_broker_email', to_jsonb(v_lead_broker_email),
        'division_head_email', to_jsonb(v_division_head_email)
    );

    SELECT fd.signwell_field_key
    INTO v_missing_field_key
    FROM config.signwell_field_dictionary fd
    WHERE fd.is_required = TRUE
      AND (
            (v_field_values ? fd.signwell_field_key) = FALSE
            OR NULLIF(v_field_values ->> fd.signwell_field_key, '') IS NULL
          )
    ORDER BY fd.signwell_field_key
    LIMIT 1;

    IF v_missing_field_key IS NOT NULL THEN
        RAISE EXCEPTION 'Missing required Signwell payload field: %', v_missing_field_key;
    END IF;

    SELECT jsonb_object_agg(fd.signwell_field_key, v_field_values -> fd.signwell_field_key)
    INTO v_strict_fields
    FROM config.signwell_field_dictionary fd;

    WITH recipient_candidates AS (
        SELECT
            rm.role_key,
            rm.recipient_order,
            LOWER(i.email) AS recipient_email
        FROM config.signwell_recipient_role_map rm
        JOIN core.deal_version_broker b
          ON b.deal_version_id = p_deal_version_id
        JOIN security.identity i
          ON i.identity_id = b.broker_identity_id
        WHERE rm.gate_key = p_gate_key
          AND rm.recipient_selector = 'ALL_BROKERS'

        UNION ALL

        SELECT
            rm.role_key,
            rm.recipient_order,
            v_division_head_email AS recipient_email
        FROM config.signwell_recipient_role_map rm
        WHERE rm.gate_key = p_gate_key
          AND rm.recipient_selector = 'LEAD_BROKER_DIVISION_HEAD'

        UNION ALL

        SELECT
            rm.role_key,
            rm.recipient_order,
            LOWER(i.email) AS recipient_email
        FROM config.signwell_recipient_role_map rm
        JOIN security.role_assignment ra
          ON ra.role_key = rm.role_key
        JOIN security.identity i
          ON i.identity_id = ra.identity_id
        WHERE rm.gate_key = p_gate_key
          AND rm.recipient_selector NOT IN ('ALL_BROKERS', 'LEAD_BROKER_DIVISION_HEAD')
    ),
    recipient_dedup AS (
        SELECT DISTINCT
            rc.role_key,
            rc.recipient_order,
            rc.recipient_email
        FROM recipient_candidates rc
        WHERE NULLIF(rc.recipient_email, '') IS NOT NULL
    )
    SELECT COALESCE(
               jsonb_agg(
                   jsonb_build_object(
                       'email', rd.recipient_email,
                       'role_key', rd.role_key,
                       'recipient_order', rd.recipient_order
                   )
                   ORDER BY rd.recipient_order, rd.role_key, rd.recipient_email
               ),
               '[]'::jsonb
           )
    INTO v_recipients
    FROM recipient_dedup rd;

    IF jsonb_array_length(v_recipients) = 0 THEN
        RAISE EXCEPTION 'No Signwell recipients resolved for gate %', p_gate_key;
    END IF;

    RETURN jsonb_build_object(
        'provider_key', 'SIGNWELL',
        'deal_version_id', p_deal_version_id,
        'gate_key', p_gate_key,
        'template_external_id', v_template_external_id,
        'template_version', v_template_version,
        'payload_version', '2026-02',
        'fields', v_strict_fields,
        'recipients', v_recipients
    );
END;
$$;

CREATE OR REPLACE FUNCTION core.get_xero_payload(
    p_deal_version_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_deal_id BIGINT;
    v_deal_business_key TEXT;
    v_deal_subtype_key TEXT;
    v_version_major INTEGER;
    v_version_minor INTEGER;
    v_current_gate_key TEXT;
    v_lifecycle_status TEXT;
    v_previous_deal_version_id BIGINT;
    v_gross_billings NUMERIC(18, 2);
    v_commission_total NUMERIC(18, 2);
    v_company_split_pct NUMERIC(7, 4);
    v_broker_split_pct NUMERIC(7, 4);
    v_brokers JSONB := '[]'::jsonb;
BEGIN
    SELECT
        dv.deal_id,
        d.deal_business_key,
        dv.deal_subtype_key,
        dv.version_major,
        dv.version_minor,
        dv.current_gate_key,
        dv.lifecycle_status,
        dv.previous_deal_version_id,
        e.gross_billings,
        e.commission_total,
        e.company_split_pct,
        e.broker_split_pct
    INTO
        v_deal_id,
        v_deal_business_key,
        v_deal_subtype_key,
        v_version_major,
        v_version_minor,
        v_current_gate_key,
        v_lifecycle_status,
        v_previous_deal_version_id,
        v_gross_billings,
        v_commission_total,
        v_company_split_pct,
        v_broker_split_pct
    FROM core.deal_version dv
    JOIN core.deal d
      ON d.deal_id = dv.deal_id
    LEFT JOIN core.deal_version_economics e
      ON e.deal_version_id = dv.deal_version_id
    WHERE dv.deal_version_id = p_deal_version_id;

    IF v_deal_id IS NULL THEN
        RAISE EXCEPTION 'deal_version_id % not found', p_deal_version_id;
    END IF;

    IF v_lifecycle_status IN ('REJECTED', 'SUPERSEDED') THEN
        RAISE EXCEPTION 'Cannot generate Xero payload for lifecycle_status %', v_lifecycle_status;
    END IF;

    IF v_current_gate_key NOT IN ('G3', 'G4') THEN
        RAISE EXCEPTION 'Xero payload only available at G3/G4. Current gate: %', v_current_gate_key;
    END IF;

    SELECT COALESCE(
               jsonb_agg(
                   jsonb_build_object(
                       'broker_identity_id', b.broker_identity_id,
                       'broker_email', i.email,
                       'is_lead_broker', b.is_lead_broker,
                       'split_percent', b.split_percent
                   )
                   ORDER BY b.deal_version_broker_id
               ),
               '[]'::jsonb
           )
    INTO v_brokers
    FROM core.deal_version_broker b
    LEFT JOIN security.identity i
      ON i.identity_id = b.broker_identity_id
    WHERE b.deal_version_id = p_deal_version_id;

    RETURN jsonb_build_object(
        'payload_type', 'XERO_READY',
        'deal_version_id', p_deal_version_id,
        'deal_business_key', v_deal_business_key,
        'deal_subtype_key', v_deal_subtype_key,
        'invoice_reference', v_deal_business_key || '-v' || v_version_major || '.' || v_version_minor,
        'economics', jsonb_build_object(
            'gross_billings', v_gross_billings,
            'commission_total', v_commission_total,
            'company_split_pct', v_company_split_pct,
            'broker_split_pct', v_broker_split_pct
        ),
        'brokers', v_brokers,
        'lineage', jsonb_build_object(
            'previous_deal_version_id', v_previous_deal_version_id
        )
    );
END;
$$;

CREATE OR REPLACE FUNCTION core.lock_xero_payload(
    p_deal_version_id BIGINT,
    p_actor_identity_id BIGINT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_payload JSONB;
    v_payload_hash TEXT;
    v_existing_hash TEXT;
    v_existing_locked_at TIMESTAMPTZ;
    v_deal_id BIGINT;
BEGIN
    IF p_actor_identity_id IS NOT NULL THEN
        IF NOT EXISTS (
            SELECT 1
            FROM security.identity i
            WHERE i.identity_id = p_actor_identity_id
        ) THEN
            RAISE EXCEPTION 'actor_identity_id % does not exist', p_actor_identity_id;
        END IF;
    END IF;

    v_payload := core.get_xero_payload(p_deal_version_id);
    v_payload_hash := md5(v_payload::text);

    SELECT
        dv.xero_payload_hash,
        dv.xero_payload_locked_at,
        dv.deal_id
    INTO
        v_existing_hash,
        v_existing_locked_at,
        v_deal_id
    FROM core.deal_version dv
    WHERE dv.deal_version_id = p_deal_version_id
    FOR UPDATE;

    IF v_deal_id IS NULL THEN
        RAISE EXCEPTION 'deal_version_id % not found', p_deal_version_id;
    END IF;

    IF v_existing_hash IS NOT NULL THEN
        IF v_existing_hash <> v_payload_hash THEN
            RAISE EXCEPTION 'Payload hash mismatch for already-locked deal_version_id %', p_deal_version_id;
        END IF;

        RETURN jsonb_build_object(
            'deal_version_id', p_deal_version_id,
            'payload_hash', v_existing_hash,
            'payload_locked_at', v_existing_locked_at,
            'lock_applied', FALSE
        );
    END IF;

    UPDATE core.deal_version dv
    SET xero_payload_hash = v_payload_hash,
        xero_payload_locked_at = NOW(),
        xero_payload_locked_by_identity_id = p_actor_identity_id
    WHERE dv.deal_version_id = p_deal_version_id;

    INSERT INTO audit.event_log (
        deal_id,
        deal_version_id,
        event_type,
        gate_key,
        actor_identity_id,
        event_payload
    )
    VALUES (
        v_deal_id,
        p_deal_version_id,
        'XERO_PAYLOAD_LOCKED',
        'G3',
        p_actor_identity_id,
        jsonb_build_object('payload_hash', v_payload_hash)
    );

    RETURN jsonb_build_object(
        'deal_version_id', p_deal_version_id,
        'payload_hash', v_payload_hash,
        'payload_locked_at', (SELECT dv.xero_payload_locked_at FROM core.deal_version dv WHERE dv.deal_version_id = p_deal_version_id),
        'lock_applied', TRUE
    );
END;
$$;

-- Wrap the Milestone 2 promotion function with additional economics-integrity checks.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ops'
          AND p.proname = 'promote_draft_to_core_v3'
          AND pg_get_function_identity_arguments(p.oid) = 'p_draft_id bigint, p_submitted_by_identity_id bigint'
    ) THEN
        -- already renamed
        NULL;
    ELSIF EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ops'
          AND p.proname = 'promote_draft_to_core'
          AND pg_get_function_identity_arguments(p.oid) = 'p_draft_id bigint, p_submitted_by_identity_id bigint'
    ) THEN
        ALTER FUNCTION ops.promote_draft_to_core(BIGINT, BIGINT) RENAME TO promote_draft_to_core_v3;
    ELSE
        RAISE EXCEPTION 'Required function ops.promote_draft_to_core(BIGINT,BIGINT) not found';
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION ops.promote_draft_to_core(
    p_draft_id BIGINT,
    p_submitted_by_identity_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_econ ops.deal_draft_economics%ROWTYPE;
    v_broker_split_total NUMERIC(18, 4);
    v_has_errors BOOLEAN := FALSE;
    v_deal_subtype_key TEXT;
    v_deal_version_id BIGINT;
BEGIN
    DELETE FROM ops.validation_result vr
    WHERE vr.draft_id = p_draft_id
      AND vr.rule_code IN (
          'ECON_GROSS_INVALID',
          'ECON_COMMISSION_INVALID',
          'ECON_SPLIT_INVALID',
          'BROKER_SPLIT_INVALID'
      );

    SELECT d.deal_subtype_key
    INTO v_deal_subtype_key
    FROM ops.deal_draft d
    WHERE d.draft_id = p_draft_id;

    SELECT e.*
    INTO v_econ
    FROM ops.deal_draft_economics e
    WHERE e.draft_id = p_draft_id;

    IF FOUND THEN
        IF v_econ.gross_billings IS NULL OR v_econ.gross_billings <= 0 THEN
            INSERT INTO ops.validation_result (
                draft_id,
                rule_code,
                severity,
                field_path,
                validation_message
            )
            VALUES (
                p_draft_id,
                'ECON_GROSS_INVALID',
                'ERROR',
                'ops.deal_draft_economics.gross_billings',
                'Gross billings must be greater than zero.'
            );
            v_has_errors := TRUE;
        END IF;

        IF v_econ.commission_total IS NULL
           OR v_econ.commission_total < 0
           OR (v_econ.gross_billings IS NOT NULL AND v_econ.commission_total > v_econ.gross_billings) THEN
            INSERT INTO ops.validation_result (
                draft_id,
                rule_code,
                severity,
                field_path,
                validation_message
            )
            VALUES (
                p_draft_id,
                'ECON_COMMISSION_INVALID',
                'ERROR',
                'ops.deal_draft_economics.commission_total',
                'Commission total must be >= 0 and <= gross billings.'
            );
            v_has_errors := TRUE;
        END IF;

        IF v_econ.company_split_pct IS NULL
           OR v_econ.broker_split_pct IS NULL
           OR ROUND(v_econ.company_split_pct + v_econ.broker_split_pct, 4) <> 100.0000 THEN
            INSERT INTO ops.validation_result (
                draft_id,
                rule_code,
                severity,
                field_path,
                validation_message
            )
            VALUES (
                p_draft_id,
                'ECON_SPLIT_INVALID',
                'ERROR',
                'ops.deal_draft_economics.company_split_pct',
                'Company and broker split percentages must sum to 100.'
            );
            v_has_errors := TRUE;
        END IF;

        SELECT ROUND(COALESCE(SUM(COALESCE(b.split_percent, 0.0)), 0.0), 4)
        INTO v_broker_split_total
        FROM ops.deal_draft_broker b
        WHERE b.draft_id = p_draft_id;

        IF EXISTS (
            SELECT 1
            FROM ops.deal_draft_broker b
            WHERE b.draft_id = p_draft_id
        ) AND v_broker_split_total <> 100.0000 THEN
            INSERT INTO ops.validation_result (
                draft_id,
                rule_code,
                severity,
                field_path,
                validation_message
            )
            VALUES (
                p_draft_id,
                'BROKER_SPLIT_INVALID',
                'ERROR',
                'ops.deal_draft_broker.split_percent',
                'Broker split percentages must sum to 100.'
            );
            v_has_errors := TRUE;
        END IF;
    END IF;

    IF v_has_errors THEN
        UPDATE ops.deal_draft
        SET draft_status = 'VALIDATION_FAILED',
            updated_by_identity_id = p_submitted_by_identity_id,
            updated_at = NOW()
        WHERE draft_id = p_draft_id;

        RETURN NULL;
    END IF;

    v_deal_version_id := ops.promote_draft_to_core_v3(p_draft_id, p_submitted_by_identity_id);

    IF v_deal_version_id IS NOT NULL THEN
        UPDATE core.deal_version dv
        SET deal_subtype_key = COALESCE(v_deal_subtype_key, dv.deal_subtype_key)
        WHERE dv.deal_version_id = v_deal_version_id;
    END IF;

    RETURN v_deal_version_id;
END;
$$;

COMMIT;
