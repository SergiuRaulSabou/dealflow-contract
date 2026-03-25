BEGIN;

-- Milestone 0.5 (Proof Slice): minimal end-to-end "promote" contract surface.
-- This is intentionally small and DB-only, to be used by Retool as the contract boundary.

CREATE OR REPLACE FUNCTION ops.promote_draft_to_core(
    p_draft_id BIGINT,
    p_submitted_by_identity_id BIGINT
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_draft ops.deal_draft%ROWTYPE;
    v_has_identity BOOLEAN;
    v_has_lead_broker BOOLEAN;
    v_doc_count INTEGER;
    v_unconfirmed_docs INTEGER;
    v_business_key TEXT;
    v_deal_id BIGINT;
    v_prev_deal_version_id BIGINT;
    v_prev_major INTEGER;
    v_prev_minor INTEGER;
    v_new_major INTEGER;
    v_new_minor INTEGER;
    v_new_deal_version_id BIGINT;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM security.identity i
        WHERE i.identity_id = p_submitted_by_identity_id
    )
    INTO v_has_identity;

    IF NOT v_has_identity THEN
        RAISE EXCEPTION 'submitted_by_identity_id % does not exist', p_submitted_by_identity_id;
    END IF;

    SELECT *
    INTO v_draft
    FROM ops.deal_draft d
    WHERE d.draft_id = p_draft_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'draft_id % not found', p_draft_id;
    END IF;

    -- Clear prior validation results for a deterministic promotion attempt.
    DELETE FROM ops.validation_result vr
    WHERE vr.draft_id = p_draft_id;

    SELECT EXISTS (
        SELECT 1
        FROM ops.deal_draft_broker b
        WHERE b.draft_id = p_draft_id
          AND b.is_lead_broker = TRUE
    )
    INTO v_has_lead_broker;

    IF NOT v_has_lead_broker THEN
        INSERT INTO ops.validation_result (
            draft_id,
            rule_code,
            severity,
            field_path,
            validation_message
        )
        VALUES (
            p_draft_id,
            'LEAD_BROKER_REQUIRED',
            'ERROR',
            'ops.deal_draft_broker.is_lead_broker',
            'A lead broker is required to submit.'
        );

        UPDATE ops.deal_draft
        SET draft_status = 'VALIDATION_FAILED',
            updated_by_identity_id = p_submitted_by_identity_id,
            updated_at = NOW()
        WHERE draft_id = p_draft_id;

        RETURN NULL;
    END IF;

    SELECT COUNT(*)
    INTO v_doc_count
    FROM ops.deal_draft_doc_status ds
    WHERE ds.draft_id = p_draft_id;

    IF v_doc_count = 0 THEN
        INSERT INTO ops.validation_result (
            draft_id,
            rule_code,
            severity,
            field_path,
            validation_message
        )
        VALUES (
            p_draft_id,
            'DOCS_REQUIRED',
            'ERROR',
            'ops.deal_draft_doc_status',
            'At least one required document must be confirmed before submission.'
        );

        UPDATE ops.deal_draft
        SET draft_status = 'VALIDATION_FAILED',
            updated_by_identity_id = p_submitted_by_identity_id,
            updated_at = NOW()
        WHERE draft_id = p_draft_id;

        RETURN NULL;
    END IF;

    SELECT COUNT(*)
    INTO v_unconfirmed_docs
    FROM ops.deal_draft_doc_status ds
    WHERE ds.draft_id = p_draft_id
      AND ds.is_confirmed = FALSE;

    IF v_unconfirmed_docs > 0 THEN
        INSERT INTO ops.validation_result (
            draft_id,
            rule_code,
            severity,
            field_path,
            validation_message
        )
        SELECT
            p_draft_id,
            'DOC_NOT_CONFIRMED',
            'ERROR',
            'ops.deal_draft_doc_status.' || ds.doc_code,
            'Document ' || ds.doc_code || ' is not confirmed.'
        FROM ops.deal_draft_doc_status ds
        WHERE ds.draft_id = p_draft_id
          AND ds.is_confirmed = FALSE;

        UPDATE ops.deal_draft
        SET draft_status = 'VALIDATION_FAILED',
            updated_by_identity_id = p_submitted_by_identity_id,
            updated_at = NOW()
        WHERE draft_id = p_draft_id;

        RETURN NULL;
    END IF;

    v_business_key := COALESCE(v_draft.deal_business_key, 'DRAFT-' || p_draft_id::text);

    INSERT INTO core.deal (deal_business_key, created_by_identity_id)
    VALUES (v_business_key, p_submitted_by_identity_id)
    ON CONFLICT (deal_business_key) DO NOTHING;

    SELECT d.deal_id
    INTO v_deal_id
    FROM core.deal d
    WHERE d.deal_business_key = v_business_key;

    SELECT dv.deal_version_id, dv.version_major, dv.version_minor
    INTO v_prev_deal_version_id, v_prev_major, v_prev_minor
    FROM core.deal_version dv
    WHERE dv.deal_id = v_deal_id
      AND dv.is_current = TRUE
    ORDER BY dv.version_major DESC, dv.version_minor DESC
    LIMIT 1;

    IF v_prev_deal_version_id IS NULL THEN
        v_new_major := 1;
        v_new_minor := 0;
    ELSE
        v_new_major := v_prev_major;
        v_new_minor := v_prev_minor + 1;

        UPDATE core.deal_version
        SET is_current = FALSE
        WHERE deal_id = v_deal_id
          AND is_current = TRUE;
    END IF;

    INSERT INTO core.deal_version (
        deal_id,
        version_major,
        version_minor,
        is_current,
        lifecycle_status,
        current_gate_key,
        submitted_from_draft_id,
        previous_deal_version_id,
        promoted_by_identity_id,
        promoted_at
    )
    VALUES (
        v_deal_id,
        v_new_major,
        v_new_minor,
        TRUE,
        'SUBMITTED',
        'G1',
        p_draft_id,
        v_prev_deal_version_id,
        p_submitted_by_identity_id,
        NOW()
    )
    RETURNING deal_version_id INTO v_new_deal_version_id;

    -- Materialize baseline Gate 1 approval requirements at promotion time (Proof Slice).
    INSERT INTO core.approval_requirement (
        deal_version_id,
        gate_key,
        required_role_key,
        approval_rule_id
    )
    SELECT
        v_new_deal_version_id,
        ar.gate_key,
        ar.required_role_key,
        ar.approval_rule_id
    FROM config.approval_rule ar
    JOIN config.approval_rule_set ars
      ON ars.approval_rule_set_id = ar.approval_rule_set_id
    WHERE ars.rule_set_key = 'DEFAULT_GATES_0_3'
      AND ar.gate_key = 'G1'
    ORDER BY ar.rule_priority ASC;

    INSERT INTO core.deal_version_party (
        deal_version_id,
        party_role_key,
        party_name,
        party_email,
        party_phone
    )
    SELECT
        v_new_deal_version_id,
        p.party_role_key,
        p.party_name,
        p.party_email,
        p.party_phone
    FROM ops.deal_draft_party p
    WHERE p.draft_id = p_draft_id;

    INSERT INTO core.deal_version_broker (
        deal_version_id,
        broker_identity_id,
        broker_external_ref,
        is_lead_broker,
        split_percent
    )
    SELECT
        v_new_deal_version_id,
        b.broker_identity_id,
        b.broker_external_ref,
        b.is_lead_broker,
        b.split_percent
    FROM ops.deal_draft_broker b
    WHERE b.draft_id = p_draft_id;

    INSERT INTO core.deal_version_economics (
        deal_version_id,
        gross_billings,
        commission_total,
        company_split_pct,
        broker_split_pct,
        economics_payload
    )
    SELECT
        v_new_deal_version_id,
        e.gross_billings,
        e.commission_total,
        e.company_split_pct,
        e.broker_split_pct,
        e.economics_payload
    FROM ops.deal_draft_economics e
    WHERE e.draft_id = p_draft_id;

    IF NOT FOUND THEN
        INSERT INTO core.deal_version_economics (deal_version_id)
        VALUES (v_new_deal_version_id);
    END IF;

    INSERT INTO core.deal_version_doc_checklist_status (
        deal_version_id,
        doc_checklist_template_item_id,
        doc_code,
        is_required,
        is_confirmed,
        note
    )
    SELECT
        v_new_deal_version_id,
        ds.doc_checklist_template_item_id,
        ds.doc_code,
        TRUE,
        ds.is_confirmed,
        ds.note
    FROM ops.deal_draft_doc_status ds
    WHERE ds.draft_id = p_draft_id;

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
        v_new_deal_version_id,
        'PROMOTED',
        'G0',
        p_submitted_by_identity_id,
        jsonb_build_object('draft_id', p_draft_id)
    );

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
        v_new_deal_version_id,
        'G1_ENTERED',
        'G1',
        p_submitted_by_identity_id,
        '{}'::jsonb
    );

    UPDATE ops.deal_draft
    SET draft_status = 'SUBMITTED',
        submitted_at = NOW(),
        updated_by_identity_id = p_submitted_by_identity_id,
        updated_at = NOW()
    WHERE draft_id = p_draft_id;

    RETURN v_new_deal_version_id;
END;
$$;

COMMIT;
