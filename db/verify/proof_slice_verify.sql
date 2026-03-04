-- Milestone 0.5 verification script.
-- Includes negative tests (expected failures) and a minimal promote happy-path.
-- Expected result: no uncaught exceptions.

BEGIN;

DO $$
DECLARE
    v_has_promote_fn BOOLEAN;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ops'
          AND p.proname = 'promote_draft_to_core'
    )
    INTO v_has_promote_fn;

    IF NOT v_has_promote_fn THEN
        RAISE EXCEPTION 'Missing required function ops.promote_draft_to_core(...)';
    END IF;
END;
$$;

-- Preflight: proof-slice checks require baseline seed catalogs/rules.
DO $$
BEGIN
    IF NOT EXISTS (
        SELECT 1
        FROM config.gate_catalog gc
        WHERE gc.gate_key = 'G0'
    ) THEN
        RAISE EXCEPTION 'Missing required seed data (config.gate_catalog:G0). Run seed migrations before proof_slice_verify.sql';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM config.doc_checklist_template dct
        JOIN config.doc_checklist_template_item dcti
          ON dcti.doc_checklist_template_id = dct.doc_checklist_template_id
        WHERE dct.deal_subtype_key = 'LEASE_ACQUISITION_OR_RENEWAL'
          AND dcti.gate_key = 'G1'
          AND dcti.checklist_item_key IN ('DEALSHEET_SIGNED', 'OTP_OR_LEASE')
    ) THEN
        RAISE EXCEPTION 'Missing required seed data (G1 checklist items for LEASE_ACQUISITION_OR_RENEWAL). Run seed migrations before proof_slice_verify.sql';
    END IF;
END;
$$;

-- Negative test: FK enforcement (ops child -> ops.deal_draft).
DO $$
BEGIN
    BEGIN
        INSERT INTO ops.deal_draft_party (draft_id, party_role_key, party_name)
        VALUES (-1, 'BUYER', 'Should Fail');
        RAISE EXCEPTION 'Expected FK failure inserting ops.deal_draft_party with invalid draft_id';
    EXCEPTION WHEN foreign_key_violation THEN
        -- expected
    END;
END;
$$;

-- Negative test: audit tables are append-only (UPDATE blocked).
DO $$
DECLARE
    v_event_id BIGINT;
BEGIN
    INSERT INTO audit.event_log (event_type, event_payload)
    VALUES ('TEST_APPEND_ONLY', '{}'::jsonb)
    RETURNING event_log_id INTO v_event_id;

    BEGIN
        UPDATE audit.event_log
        SET event_type = 'TEST_APPEND_ONLY_UPDATED'
        WHERE event_log_id = v_event_id;
        RAISE EXCEPTION 'Expected append-only failure updating audit.event_log';
    EXCEPTION WHEN OTHERS THEN
        -- expected
    END;
END;
$$;

-- Negative test: webhook inbox dedupe (provider_key + event_id unique).
DO $$
BEGIN
    INSERT INTO audit.webhook_event (provider_key, event_id, webhook_payload)
    VALUES ('SIGNWELL', 'verify-event-1', '{}'::jsonb);

    BEGIN
        INSERT INTO audit.webhook_event (provider_key, event_id, webhook_payload)
        VALUES ('SIGNWELL', 'verify-event-1', '{}'::jsonb);
        RAISE EXCEPTION 'Expected unique violation inserting duplicate audit.webhook_event';
    EXCEPTION WHEN unique_violation THEN
        -- expected
    END;
END;
$$;

-- Promote happy-path + one promote negative-path (missing lead broker).
DO $$
DECLARE
    v_identity_id BIGINT;
    v_draft_id BIGINT;
    v_draft_id_no_lead BIGINT;
    v_deal_version_id BIGINT;
BEGIN
    INSERT INTO security.identity (email, display_name)
    VALUES (
        'verify+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Verify User'
    )
    RETURNING identity_id INTO v_identity_id;

    -- Happy-path draft
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'VERIFY-' || v_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_identity_id,
        v_identity_id
    )
    RETURNING draft_id INTO v_draft_id;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_id, v_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed, confirmed_by_identity_id, confirmed_at)
    VALUES
        (v_draft_id, 'DEALSHEET_SIGNED', TRUE, v_identity_id, NOW()),
        (v_draft_id, 'OTP_OR_LEASE', TRUE, v_identity_id, NOW());

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_id, 1000.00, 100.00, 50.0, 50.0);

    v_deal_version_id := ops.promote_draft_to_core(v_draft_id, v_identity_id);
    IF v_deal_version_id IS NULL THEN
        RAISE EXCEPTION 'Expected promotion to succeed for draft %, got NULL', v_draft_id;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_id
          AND dv.submitted_from_draft_id = v_draft_id
    ) THEN
        RAISE EXCEPTION 'Promotion did not create expected core.deal_version row';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM audit.event_log e
        WHERE e.deal_version_id = v_deal_version_id
          AND e.event_type = 'PROMOTED'
    ) THEN
        RAISE EXCEPTION 'Promotion did not write expected PROMOTED audit event';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.approval_requirement ar
        WHERE ar.deal_version_id = v_deal_version_id
          AND ar.gate_key = 'G1'
    ) THEN
        RAISE EXCEPTION 'Promotion did not materialize expected G1 core.approval_requirement rows';
    END IF;

    -- Negative-path: missing lead broker should fail and write validation_result.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'VERIFY-NO-LEAD-' || v_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_identity_id,
        v_identity_id
    )
    RETURNING draft_id INTO v_draft_id_no_lead;

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed, confirmed_by_identity_id, confirmed_at)
    VALUES
        (v_draft_id_no_lead, 'DEALSHEET_SIGNED', TRUE, v_identity_id, NOW()),
        (v_draft_id_no_lead, 'OTP_OR_LEASE', TRUE, v_identity_id, NOW());

    v_deal_version_id := ops.promote_draft_to_core(v_draft_id_no_lead, v_identity_id);
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
        RAISE EXCEPTION 'Expected validation_result for missing lead broker was not written';
    END IF;

    -- Negative-path: docs present but not confirmed should fail and write validation_result(s).
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'VERIFY-DOCS-UNCONFIRMED-' || v_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_identity_id,
        v_identity_id
    )
    RETURNING draft_id INTO v_draft_id;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_id, v_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES
        (v_draft_id, 'DEALSHEET_SIGNED', FALSE),
        (v_draft_id, 'OTP_OR_LEASE', TRUE);

    v_deal_version_id := ops.promote_draft_to_core(v_draft_id, v_identity_id);
    IF v_deal_version_id IS NOT NULL THEN
        RAISE EXCEPTION 'Expected promotion to fail with unconfirmed docs, but it succeeded';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM ops.validation_result vr
        WHERE vr.draft_id = v_draft_id
          AND vr.rule_code = 'DOC_NOT_CONFIRMED'
          AND vr.severity = 'ERROR'
    ) THEN
        RAISE EXCEPTION 'Expected validation_result for unconfirmed docs was not written';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.submitted_from_draft_id = v_draft_id
    ) THEN
        RAISE EXCEPTION 'Promotion failure should not create core.deal_version rows';
    END IF;
END;
$$;

ROLLBACK;
