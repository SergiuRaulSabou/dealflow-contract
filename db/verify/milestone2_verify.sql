-- Milestone 2 verification script.
-- Promotion must enforce doc template rules (including JSE/FICA conditional rule)
-- and materialize approval requirements for Gates 1-3 via a deterministic rule set.
--
-- Expected result: no uncaught exceptions.

BEGIN;

DO $$
DECLARE
    v_ops_identity_id BIGINT;
    v_fin_identity_id BIGINT;
    v_draft_id BIGINT;
    v_draft_id_non_jse BIGINT;
    v_draft_id_missing_doc BIGINT;
    v_draft_id_no_lead BIGINT;
    v_deal_version_id BIGINT;
    v_deal_version_id_non_jse BIGINT;
    v_inserted_g2 INTEGER;
    v_inserted_g3 INTEGER;
    v_reinserted_g2 INTEGER;
BEGIN
    INSERT INTO security.identity (email, display_name)
    VALUES (
        'ops+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Ops User'
    )
    RETURNING identity_id INTO v_ops_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'fin+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Finance Approver'
    )
    RETURNING identity_id INTO v_fin_identity_id;

    -- Happy-path: JSE listed => FICA required.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        is_jse_listed,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M2-VERIFY-JSE-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        TRUE,
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_id;

    INSERT INTO ops.deal_draft_party (draft_id, party_role_key, party_name, requires_fica)
    VALUES (v_draft_id, 'BUYER', 'Buyer Party', FALSE);

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_id, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed, confirmed_by_identity_id, confirmed_at)
    VALUES
        (v_draft_id, 'DEALSHEET_SIGNED', TRUE, v_ops_identity_id, NOW()),
        (v_draft_id, 'OTP_OR_LEASE', TRUE, v_ops_identity_id, NOW()),
        (v_draft_id, 'FICA_COMPLETE', TRUE, v_ops_identity_id, NOW());

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_id, 1000.00, 100.00, 50.0, 50.0);

    v_deal_version_id := ops.promote_draft_to_core(v_draft_id, v_ops_identity_id);
    IF v_deal_version_id IS NULL THEN
        RAISE EXCEPTION 'Expected Milestone 2 promotion (JSE) to succeed, got NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_id
          AND dv.is_jse_listed = TRUE
    ) THEN
        RAISE EXCEPTION 'Expected core.deal_version.is_jse_listed to be TRUE';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM audit.event_log e
        WHERE e.deal_version_id = v_deal_version_id
          AND e.event_type IN ('PROMOTED', 'G1_ENTERED')
        GROUP BY e.deal_version_id
        HAVING COUNT(*) >= 2
    ) THEN
        RAISE EXCEPTION 'Expected PROMOTED and G1_ENTERED events for promoted deal_version';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.approval_requirement ar
        WHERE ar.deal_version_id = v_deal_version_id
          AND ar.gate_key = 'G1'
    ) THEN
        RAISE EXCEPTION 'Expected G1 approval requirements to be materialized at promotion';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version_doc_checklist_status s
        WHERE s.deal_version_id = v_deal_version_id
          AND s.doc_code = 'FICA_COMPLETE'
          AND s.is_required = TRUE
          AND s.is_confirmed = TRUE
    ) THEN
        RAISE EXCEPTION 'Expected FICA_COMPLETE to be required+confirmed for JSE-listed deal';
    END IF;

    -- Happy-path: not JSE listed, no party requires FICA => FICA not required.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        is_jse_listed,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M2-VERIFY-NONJSE-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        FALSE,
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_id_non_jse;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_id_non_jse, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed, confirmed_by_identity_id, confirmed_at)
    VALUES
        (v_draft_id_non_jse, 'DEALSHEET_SIGNED', TRUE, v_ops_identity_id, NOW()),
        (v_draft_id_non_jse, 'OTP_OR_LEASE', TRUE, v_ops_identity_id, NOW());

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_id_non_jse, 1000.00, 100.00, 50.0, 50.0);

    v_deal_version_id_non_jse := ops.promote_draft_to_core(v_draft_id_non_jse, v_ops_identity_id);
    IF v_deal_version_id_non_jse IS NULL THEN
        RAISE EXCEPTION 'Expected Milestone 2 promotion (non-JSE) to succeed, got NULL';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version_doc_checklist_status s
        WHERE s.deal_version_id = v_deal_version_id_non_jse
          AND s.doc_code = 'FICA_COMPLETE'
          AND s.is_required = FALSE
          AND s.is_confirmed = FALSE
    ) THEN
        RAISE EXCEPTION 'Expected FICA_COMPLETE to be not required and not confirmed for non-JSE deal';
    END IF;

    -- Negative-path: missing required doc (OTP_OR_LEASE) must fail and write validation_result.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        is_jse_listed,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M2-VERIFY-MISSING-DOC-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        FALSE,
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_id_missing_doc;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_id_missing_doc, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed, confirmed_by_identity_id, confirmed_at)
    VALUES (v_draft_id_missing_doc, 'DEALSHEET_SIGNED', TRUE, v_ops_identity_id, NOW());

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_id_missing_doc, 1000.00, 100.00, 50.0, 50.0);

    v_deal_version_id := ops.promote_draft_to_core(v_draft_id_missing_doc, v_ops_identity_id);
    IF v_deal_version_id IS NOT NULL THEN
        RAISE EXCEPTION 'Expected promotion to fail when required doc is missing, but it succeeded';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM ops.validation_result vr
        WHERE vr.draft_id = v_draft_id_missing_doc
          AND vr.rule_code = 'DOC_REQUIRED'
          AND vr.severity = 'ERROR'
          AND vr.field_path = 'ops.deal_draft_doc_status.OTP_OR_LEASE'
    ) THEN
        RAISE EXCEPTION 'Expected DOC_REQUIRED validation for missing OTP_OR_LEASE doc';
    END IF;

    -- Negative-path: missing lead broker must fail.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        is_jse_listed,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M2-VERIFY-NO-LEAD-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        FALSE,
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_id_no_lead;

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed, confirmed_by_identity_id, confirmed_at)
    VALUES
        (v_draft_id_no_lead, 'DEALSHEET_SIGNED', TRUE, v_ops_identity_id, NOW()),
        (v_draft_id_no_lead, 'OTP_OR_LEASE', TRUE, v_ops_identity_id, NOW());

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_id_no_lead, 1000.00, 100.00, 50.0, 50.0);

    v_deal_version_id := ops.promote_draft_to_core(v_draft_id_no_lead, v_ops_identity_id);
    IF v_deal_version_id IS NOT NULL THEN
        RAISE EXCEPTION 'Expected promotion to fail without lead broker, but it succeeded';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM ops.validation_result vr
        WHERE vr.draft_id = v_draft_id_no_lead
          AND vr.rule_code = 'LEAD_BROKER_REQUIRED'
          AND vr.severity = 'ERROR'
    ) THEN
        RAISE EXCEPTION 'Expected LEAD_BROKER_REQUIRED validation for missing lead broker';
    END IF;

    -- Prove approval requirement materialization works for G2 and G3 (rule-set driven + idempotent).
    SELECT core.materialize_approval_requirements(v_deal_version_id_non_jse, 'G2', 'DEFAULT_GATES_0_3')
    INTO v_inserted_g2;
    IF v_inserted_g2 < 2 THEN
        RAISE EXCEPTION 'Expected at least 2 approval requirements inserted for G2, got %', v_inserted_g2;
    END IF;

    SELECT core.materialize_approval_requirements(v_deal_version_id_non_jse, 'G3', 'DEFAULT_GATES_0_3')
    INTO v_inserted_g3;
    IF v_inserted_g3 < 1 THEN
        RAISE EXCEPTION 'Expected at least 1 approval requirement inserted for G3, got %', v_inserted_g3;
    END IF;

    SELECT core.materialize_approval_requirements(v_deal_version_id_non_jse, 'G2', 'DEFAULT_GATES_0_3')
    INTO v_reinserted_g2;
    IF v_reinserted_g2 <> 0 THEN
        RAISE EXCEPTION 'Expected idempotent G2 materialization to insert 0 rows on repeat, got %', v_reinserted_g2;
    END IF;
END;
$$;

ROLLBACK;

