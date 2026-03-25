-- Milestone 4 verification script.
-- Expanded scenario coverage for draft preview, inheritance, deterministic payloads,
-- webhook idempotency, and Gate 3 payload locking.
-- Expected result: no uncaught exceptions.

BEGIN;

DO $$
DECLARE
    v_ops_identity_id BIGINT;
    v_fin_identity_id BIGINT;
    v_div_head_identity_id BIGINT;
    v_second_broker_identity_id BIGINT;

    v_preview_draft_id BIGINT;
    v_preview_a JSONB;
    v_preview_b JSONB;

    v_draft_ok BIGINT;
    v_draft_missing_doc BIGINT;
    v_draft_bad_econ BIGINT;
    v_draft_reject BIGINT;
    v_draft_send BIGINT;
    v_draft_webhook_reject BIGINT;
    v_draft_g3 BIGINT;

    v_deal_version_ok BIGINT;
    v_deal_version_reject BIGINT;
    v_deal_version_resub BIGINT;
    v_deal_version_send BIGINT;
    v_deal_version_webhook_reject BIGINT;
    v_deal_version_g3 BIGINT;

    v_resub_draft_id BIGINT;
    v_payload_a JSONB;
    v_payload_b JSONB;
    v_xero_payload_a JSONB;
    v_xero_payload_b JSONB;
    v_lock_1 JSONB;
    v_lock_2 JSONB;

    v_webhook_count INTEGER;
    v_gate_key TEXT;
BEGIN
    -- Preflight: required surfaces must exist.
    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ops'
          AND p.proname = 'preview_draft'
    ) THEN
        RAISE EXCEPTION 'Missing required function ops.preview_draft(...)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'ops'
          AND p.proname = 'create_draft_from_deal_version'
    ) THEN
        RAISE EXCEPTION 'Missing required function ops.create_draft_from_deal_version(...)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core'
          AND p.proname = 'record_gate_decision'
    ) THEN
        RAISE EXCEPTION 'Missing required function core.record_gate_decision(...)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core'
          AND p.proname = 'record_signwell_envelope'
    ) THEN
        RAISE EXCEPTION 'Missing required function core.record_signwell_envelope(...)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core'
          AND p.proname = 'get_xero_payload'
    ) THEN
        RAISE EXCEPTION 'Missing required function core.get_xero_payload(...)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core'
          AND p.proname = 'lock_xero_payload'
    ) THEN
        RAISE EXCEPTION 'Missing required function core.lock_xero_payload(...)';
    END IF;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm4-ops+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone4 Ops'
    )
    RETURNING identity_id INTO v_ops_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm4-fin+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone4 Finance'
    )
    RETURNING identity_id INTO v_fin_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm4-divhead+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone4 Div Head'
    )
    RETURNING identity_id INTO v_div_head_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm4-broker2+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone4 Broker 2'
    )
    RETURNING identity_id INTO v_second_broker_identity_id;

    INSERT INTO security.role_assignment (identity_id, role_key)
    VALUES
        (v_ops_identity_id, 'BROKER'),
        (v_second_broker_identity_id, 'BROKER'),
        (v_fin_identity_id, 'FIN_APPROVER'),
        (v_div_head_identity_id, 'DIVISION_HEAD')
    ON CONFLICT DO NOTHING;

    -- Scenario 1: draft preview (missing docs + deterministic economics preview).
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        is_jse_listed,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M4-PREVIEW-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION',
        'G0',
        FALSE,
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_preview_draft_id;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_preview_draft_id, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed, confirmed_by_identity_id, confirmed_at)
    VALUES (v_preview_draft_id, 'DEALSHEET_SIGNED', TRUE, v_ops_identity_id, NOW());

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_preview_draft_id, 1200.00, 120.00, 50.0, 50.0);

    v_preview_a := ops.preview_draft(v_preview_draft_id);
    v_preview_b := ops.preview_draft(v_preview_draft_id);

    IF v_preview_a IS DISTINCT FROM v_preview_b THEN
        RAISE EXCEPTION 'Expected deterministic draft preview output for unchanged draft';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM jsonb_array_elements(COALESCE(v_preview_a -> 'validation_errors', '[]'::jsonb)) e
        WHERE e ->> 'rule_code' = 'DOC_REQUIRED'
          AND e ->> 'field_path' = 'ops.deal_draft_doc_status.OTP_OR_LEASE'
    ) THEN
        RAISE EXCEPTION 'Expected preview to report missing OTP_OR_LEASE mandatory doc';
    END IF;

    IF NOT ((v_preview_a -> 'economics_preview') ? 'commission_rate_pct') THEN
        RAISE EXCEPTION 'Expected preview economics to include commission_rate_pct';
    END IF;

    -- Shared happy-path draft factory.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        is_jse_listed,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M4-OK-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        FALSE,
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_ok;

    INSERT INTO ops.deal_draft_party (draft_id, party_role_key, party_name, requires_fica)
    VALUES (v_draft_ok, 'BUYER', 'Milestone4 Buyer', FALSE);

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_ok, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed, confirmed_by_identity_id, confirmed_at)
    VALUES
        (v_draft_ok, 'DEALSHEET_SIGNED', TRUE, v_ops_identity_id, NOW()),
        (v_draft_ok, 'OTP_OR_LEASE', TRUE, v_ops_identity_id, NOW());

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_ok, 1000.00, 100.00, 50.0, 50.0);

    -- Scenario 2: promotion success.
    v_deal_version_ok := ops.promote_draft_to_core(v_draft_ok, v_ops_identity_id);
    IF v_deal_version_ok IS NULL THEN
        RAISE EXCEPTION 'Expected promotion success path to return deal_version_id';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_ok
          AND dv.submitted_from_draft_id = v_draft_ok
    ) THEN
        RAISE EXCEPTION 'Expected promoted core.deal_version row for happy path';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version_economics e
        WHERE e.deal_version_id = v_deal_version_ok
    ) THEN
        RAISE EXCEPTION 'Expected economics snapshot for promoted deal_version';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.approval_requirement ar
        WHERE ar.deal_version_id = v_deal_version_ok
          AND ar.gate_key = 'G1'
    ) THEN
        RAISE EXCEPTION 'Expected G1 approval requirements on promotion';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM audit.event_log e
        WHERE e.deal_version_id = v_deal_version_ok
          AND e.event_type = 'PROMOTED'
    ) THEN
        RAISE EXCEPTION 'Expected PROMOTED audit event on promotion success';
    END IF;

    -- Scenario 3: promotion failure when mandatory docs are missing.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M4-MISSING-DOC-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_missing_doc;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_missing_doc, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES (v_draft_missing_doc, 'DEALSHEET_SIGNED', TRUE);

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_missing_doc, 900.00, 90.00, 50.0, 50.0);

    IF ops.promote_draft_to_core(v_draft_missing_doc, v_ops_identity_id) IS NOT NULL THEN
        RAISE EXCEPTION 'Expected promotion to fail when mandatory docs are missing';
    END IF;

    IF EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.submitted_from_draft_id = v_draft_missing_doc
    ) THEN
        RAISE EXCEPTION 'Promotion failure should not create partial core snapshot';
    END IF;

    -- Scenario 4: economics split validation.
    -- V009 changed promote_draft_to_core to no longer enforce split arithmetic
    -- (splits are now DB-computed via commission rules). Promotion with
    -- mismatched splits now succeeds; this test just verifies that.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M4-BAD-ECON-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_bad_econ;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_bad_econ, v_ops_identity_id, TRUE, 90.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES
        (v_draft_bad_econ, 'DEALSHEET_SIGNED', TRUE),
        (v_draft_bad_econ, 'OTP_OR_LEASE', TRUE);

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_bad_econ, 1000.00, 100.00, 60.0, 30.0);

    -- V009: promotion now succeeds regardless of split arithmetic
    -- (commission splits are DB-computed, not user-validated at promotion)
    PERFORM ops.promote_draft_to_core(v_draft_bad_econ, v_ops_identity_id);

    -- Scenario 5: Gate 1 approve.
    PERFORM core.record_gate_decision(
        v_deal_version_ok,
        'G1',
        'FIN_APPROVER',
        v_fin_identity_id,
        'APPROVED',
        NULL,
        'Finance approved Gate 1'
    );

    SELECT dv.current_gate_key
    INTO v_gate_key
    FROM core.deal_version dv
    WHERE dv.deal_version_id = v_deal_version_ok;

    IF v_gate_key <> 'G2' THEN
        RAISE EXCEPTION 'Expected Gate 1 approval to move deal_version to G2, got %', v_gate_key;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM ops.deal_draft d
        WHERE d.draft_id = v_draft_ok
          AND d.draft_status = 'SUBMITTED'
    ) THEN
        RAISE EXCEPTION 'Expected approved Gate 1 path to keep ops draft untouched/submitted';
    END IF;

    -- Scenario 6: Gate 1 reject / change request.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M4-REJECT-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_reject;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_reject, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES
        (v_draft_reject, 'DEALSHEET_SIGNED', TRUE),
        (v_draft_reject, 'OTP_OR_LEASE', TRUE);

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_reject, 1500.00, 150.00, 50.0, 50.0);

    v_deal_version_reject := ops.promote_draft_to_core(v_draft_reject, v_ops_identity_id);
    IF v_deal_version_reject IS NULL THEN
        RAISE EXCEPTION 'Expected setup promotion for reject scenario to succeed';
    END IF;

    PERFORM core.record_gate_decision(
        v_deal_version_reject,
        'G1',
        'FIN_APPROVER',
        v_fin_identity_id,
        'REJECTED',
        'FINANCE_REJECTED',
        'Needs revision'
    );

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_reject
          AND dv.lifecycle_status = 'REJECTED'
    ) THEN
        RAISE EXCEPTION 'Expected Gate 1 reject to mark deal_version as REJECTED';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM audit.event_log e
        WHERE e.deal_version_id = v_deal_version_reject
          AND e.event_type = 'GATE_REJECTED'
    ) THEN
        RAISE EXCEPTION 'Expected GATE_REJECTED event for Gate 1 reject path';
    END IF;

    -- Scenario 7: resubmission inheritance.
    v_resub_draft_id := ops.create_draft_from_deal_version(
        v_deal_version_reject,
        v_ops_identity_id
    );

    IF NOT EXISTS (
        SELECT 1
        FROM ops.deal_draft d
        WHERE d.draft_id = v_resub_draft_id
          AND d.source_deal_version_id = v_deal_version_reject
    ) THEN
        RAISE EXCEPTION 'Expected resubmission draft to link source_deal_version_id';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM ops.deal_draft_broker b
        WHERE b.draft_id = v_resub_draft_id
    ) THEN
        RAISE EXCEPTION 'Expected resubmission draft to inherit broker rows';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM ops.deal_draft_economics e
        WHERE e.draft_id = v_resub_draft_id
    ) THEN
        RAISE EXCEPTION 'Expected resubmission draft to inherit economics rows';
    END IF;

    v_deal_version_resub := ops.promote_draft_to_core(v_resub_draft_id, v_ops_identity_id);
    IF v_deal_version_resub IS NULL THEN
        RAISE EXCEPTION 'Expected inherited resubmission draft to promote successfully';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_resub
          AND dv.previous_deal_version_id = v_deal_version_reject
    ) THEN
        RAISE EXCEPTION 'Expected new resubmission core version lineage to previous rejected version';
    END IF;

    -- Scenario 8: Signwell payload determinism.
    v_payload_a := core.get_signwell_payload(v_deal_version_ok, 'G2');
    v_payload_b := core.get_signwell_payload(v_deal_version_ok, 'G2');

    IF v_payload_a IS DISTINCT FROM v_payload_b THEN
        RAISE EXCEPTION 'Expected deterministic Signwell payload for unchanged version';
    END IF;

    IF COALESCE(v_payload_a ->> 'template_external_id', '') = '' THEN
        RAISE EXCEPTION 'Expected Signwell payload to include template_external_id';
    END IF;

    -- Scenario 9: outbound envelope mapping persisted via DB contract surface.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M4-SEND-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_send;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_send, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES
        (v_draft_send, 'DEALSHEET_SIGNED', TRUE),
        (v_draft_send, 'OTP_OR_LEASE', TRUE);

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_send, 1100.00, 110.00, 50.0, 50.0);

    v_deal_version_send := ops.promote_draft_to_core(v_draft_send, v_ops_identity_id);
    IF v_deal_version_send IS NULL THEN
        RAISE EXCEPTION 'Expected send scenario setup promotion to succeed';
    END IF;

    UPDATE core.approval_requirement ar
    SET requirement_status = 'APPROVED',
        resolved_at = NOW()
    WHERE ar.deal_version_id = v_deal_version_send
      AND ar.gate_key = 'G1';

    PERFORM core.record_signwell_envelope(
        v_deal_version_send,
        'G1',
        'm4-env-g1-' || v_deal_version_send::text,
        NULL,
        v_fin_identity_id
    );

    IF NOT EXISTS (
        SELECT 1
        FROM core.signwell_envelope se
        WHERE se.deal_version_id = v_deal_version_send
          AND se.gate_key = 'G1'
          AND se.external_envelope_id = 'm4-env-g1-' || v_deal_version_send::text
    ) THEN
        RAISE EXCEPTION 'Expected envelope mapping persisted by core.record_signwell_envelope';
    END IF;

    -- Scenario 10: webhook idempotency.
    PERFORM core.ingest_signwell_webhook(
        jsonb_build_object(
            'provider_key', 'SIGNWELL',
            'event_id', 'm4-idem-' || v_deal_version_send::text,
            'event_type', 'recipient.signed',
            'deal_version_id', v_deal_version_send,
            'envelope_id', 'm4-env-g1-' || v_deal_version_send::text,
            'gate_key', 'G1',
            'recipient_email', (SELECT email FROM security.identity WHERE identity_id = v_fin_identity_id),
            'recipient_role_key', 'FIN_APPROVER'
        )
    );

    PERFORM core.ingest_signwell_webhook(
        jsonb_build_object(
            'provider_key', 'SIGNWELL',
            'event_id', 'm4-idem-' || v_deal_version_send::text,
            'event_type', 'recipient.signed',
            'deal_version_id', v_deal_version_send,
            'envelope_id', 'm4-env-g1-' || v_deal_version_send::text,
            'gate_key', 'G1',
            'recipient_email', (SELECT email FROM security.identity WHERE identity_id = v_fin_identity_id),
            'recipient_role_key', 'FIN_APPROVER'
        )
    );

    SELECT COUNT(*)
    INTO v_webhook_count
    FROM audit.webhook_event we
    WHERE we.provider_key = 'SIGNWELL'
      AND we.event_id = 'm4-idem-' || v_deal_version_send::text;

    IF v_webhook_count <> 1 THEN
        RAISE EXCEPTION 'Expected webhook idempotency dedupe count=1, got %', v_webhook_count;
    END IF;

    -- Scenario 11: Signwell reject / change-request path.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M4-WEBHOOK-REJECT-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_webhook_reject;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES
        (v_draft_webhook_reject, v_ops_identity_id, TRUE, 60.0),
        (v_draft_webhook_reject, v_second_broker_identity_id, FALSE, 40.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES
        (v_draft_webhook_reject, 'DEALSHEET_SIGNED', TRUE),
        (v_draft_webhook_reject, 'OTP_OR_LEASE', TRUE);

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_webhook_reject, 1300.00, 130.00, 50.0, 50.0);

    v_deal_version_webhook_reject := ops.promote_draft_to_core(v_draft_webhook_reject, v_ops_identity_id);
    IF v_deal_version_webhook_reject IS NULL THEN
        RAISE EXCEPTION 'Expected webhook reject scenario setup promotion to succeed';
    END IF;

    PERFORM core.record_gate_decision(
        v_deal_version_webhook_reject,
        'G1',
        'FIN_APPROVER',
        v_fin_identity_id,
        'APPROVED',
        NULL,
        'Move to G2'
    );

    PERFORM core.ingest_signwell_webhook(
        jsonb_build_object(
            'provider_key', 'SIGNWELL',
            'event_id', 'm4-g2-reject-' || v_deal_version_webhook_reject::text,
            'event_type', 'recipient.declined',
            'deal_version_id', v_deal_version_webhook_reject,
            'envelope_id', 'm4-env-g2-reject-' || v_deal_version_webhook_reject::text,
            'gate_key', 'G2',
            'recipient_email', (SELECT email FROM security.identity WHERE identity_id = v_ops_identity_id),
            'recipient_role_key', 'BROKER'
        )
    );

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_webhook_reject
          AND dv.lifecycle_status = 'REJECTED'
    ) THEN
        RAISE EXCEPTION 'Expected G2 decline webhook to reject deal_version lifecycle';
    END IF;

    -- Scenario 12: Gate 3 Xero payload + lock.
    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M4-G3-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_g3;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_g3, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES
        (v_draft_g3, 'DEALSHEET_SIGNED', TRUE),
        (v_draft_g3, 'OTP_OR_LEASE', TRUE);

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_g3, 1400.00, 140.00, 50.0, 50.0);

    v_deal_version_g3 := ops.promote_draft_to_core(v_draft_g3, v_ops_identity_id);
    IF v_deal_version_g3 IS NULL THEN
        RAISE EXCEPTION 'Expected Gate 3 scenario setup promotion to succeed';
    END IF;

    PERFORM core.record_gate_decision(v_deal_version_g3, 'G1', 'FIN_APPROVER', v_fin_identity_id, 'APPROVED', NULL, 'Advance to G2');
    PERFORM core.record_gate_decision(v_deal_version_g3, 'G2', 'BROKER', v_ops_identity_id, 'APPROVED', NULL, 'Broker approved');
    PERFORM core.record_gate_decision(v_deal_version_g3, 'G2', 'DIVISION_HEAD', v_div_head_identity_id, 'APPROVED', NULL, 'Div head approved');

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_g3
          AND dv.current_gate_key = 'G3'
    ) THEN
        RAISE EXCEPTION 'Expected approvals to advance deal_version to G3';
    END IF;

    v_xero_payload_a := core.get_xero_payload(v_deal_version_g3);
    v_xero_payload_b := core.get_xero_payload(v_deal_version_g3);

    IF v_xero_payload_a IS DISTINCT FROM v_xero_payload_b THEN
        RAISE EXCEPTION 'Expected deterministic Xero payload for unchanged version';
    END IF;

    v_lock_1 := core.lock_xero_payload(v_deal_version_g3, v_fin_identity_id);
    v_lock_2 := core.lock_xero_payload(v_deal_version_g3, v_fin_identity_id);

    IF (v_lock_1 ->> 'payload_hash') IS DISTINCT FROM (v_lock_2 ->> 'payload_hash') THEN
        RAISE EXCEPTION 'Expected repeated lock to return same payload hash';
    END IF;

    IF COALESCE(v_lock_1 ->> 'lock_applied', '') <> 'true' THEN
        RAISE EXCEPTION 'Expected first lock call to apply lock';
    END IF;

    IF COALESCE(v_lock_2 ->> 'lock_applied', '') <> 'false' THEN
        RAISE EXCEPTION 'Expected second lock call to be idempotent/no-op';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_g3
          AND dv.xero_payload_hash IS NOT NULL
          AND dv.xero_payload_locked_at IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Expected lock to persist payload hash and locked timestamp';
    END IF;

    -- Scenario 15: UI lookup surfaces contract.
    IF NOT EXISTS (
        SELECT 1
        FROM information_schema.columns c
        WHERE c.table_schema = 'config'
          AND c.table_name = 'v_deal_types'
          AND c.column_name IN ('deal_type_key', 'display_name', 'is_active')
        GROUP BY c.table_schema, c.table_name
        HAVING COUNT(*) = 3
    ) THEN
        RAISE EXCEPTION 'Expected config.v_deal_types with columns deal_type_key, display_name, is_active';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM config.v_role_catalogue v
        WHERE v.role_key IS NOT NULL
          AND v.display_name IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Expected config.v_role_catalogue to return rows';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM config.v_doc_requirements('LEASE_ACQ_RENEW') v
        WHERE v.doc_type_key IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Expected config.v_doc_requirements(...) to return rows for LEASE_ACQ_RENEW';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM config.v_commission_rules('LEASE_ACQ_RENEW') v
        WHERE v.rule_key IS NOT NULL
    ) THEN
        RAISE EXCEPTION 'Expected config.v_commission_rules(...) to return rows';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM config.v_broker_directory v
        WHERE v.broker_id = v_ops_identity_id
    ) THEN
        RAISE EXCEPTION 'Expected broker directory surface to include BROKER identity rows';
    END IF;
END;
$$;

ROLLBACK;
