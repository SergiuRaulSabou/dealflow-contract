-- Milestone 3 verification script.
-- Covers send eligibility, Signwell payload contract, and webhook ingest behaviour.
-- Expected result: no uncaught exceptions.

BEGIN;

DO $$
DECLARE
    v_ops_identity_id BIGINT;
    v_fin_identity_id BIGINT;
    v_div_head_identity_id BIGINT;
    v_draft_id BIGINT;
    v_deal_version_id BIGINT;
    v_is_eligible BOOLEAN;
    v_reason TEXT;
    v_payload JSONB;
    v_event_id_g1 TEXT;
    v_webhook_count INTEGER;
BEGIN
    -- Preflight: required functions must exist.
    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core'
          AND p.proname = 'is_send_eligible'
    ) THEN
        RAISE EXCEPTION 'Missing required function core.is_send_eligible(...)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core'
          AND p.proname = 'get_signwell_payload'
    ) THEN
        RAISE EXCEPTION 'Missing required function core.get_signwell_payload(...)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core'
          AND p.proname = 'ingest_signwell_webhook'
    ) THEN
        RAISE EXCEPTION 'Missing required function core.ingest_signwell_webhook(...)';
    END IF;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm3-ops+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone3 Ops'
    )
    RETURNING identity_id INTO v_ops_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm3-fin+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone3 Finance'
    )
    RETURNING identity_id INTO v_fin_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm3-divhead+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone3 Division Head'
    )
    RETURNING identity_id INTO v_div_head_identity_id;

    INSERT INTO security.role_assignment (identity_id, role_key)
    VALUES
        (v_fin_identity_id, 'FIN_APPROVER'),
        (v_div_head_identity_id, 'DIVISION_HEAD');

    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        is_jse_listed,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M3-VERIFY-' || v_ops_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        FALSE,
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_id;

    INSERT INTO ops.deal_draft_party (draft_id, party_role_key, party_name, requires_fica)
    VALUES (v_draft_id, 'BUYER', 'Milestone3 Buyer', FALSE);

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_id, v_ops_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed, confirmed_by_identity_id, confirmed_at)
    VALUES
        (v_draft_id, 'DEALSHEET_SIGNED', TRUE, v_ops_identity_id, NOW()),
        (v_draft_id, 'OTP_OR_LEASE', TRUE, v_ops_identity_id, NOW());

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_id, 1000.00, 100.00, 50.0, 50.0);

    v_deal_version_id := ops.promote_draft_to_core(v_draft_id, v_ops_identity_id);
    IF v_deal_version_id IS NULL THEN
        RAISE EXCEPTION 'Expected promotion to succeed for Milestone 3 setup';
    END IF;

    SELECT e.is_eligible, e.reason
    INTO v_is_eligible, v_reason
    FROM core.is_send_eligible(v_deal_version_id, 'G1') e;

    IF v_is_eligible OR v_reason <> 'APPROVAL_REQUIREMENTS_UNRESOLVED' THEN
        RAISE EXCEPTION 'Expected G1 send eligibility to be blocked by unresolved approvals, got eligible=% reason=%', v_is_eligible, v_reason;
    END IF;

    UPDATE core.approval_requirement
    SET requirement_status = 'APPROVED',
        resolved_at = NOW()
    WHERE deal_version_id = v_deal_version_id
      AND gate_key = 'G1';

    SELECT e.is_eligible, e.reason
    INTO v_is_eligible, v_reason
    FROM core.is_send_eligible(v_deal_version_id, 'G1') e;

    IF v_is_eligible IS DISTINCT FROM TRUE OR v_reason <> 'ELIGIBLE' THEN
        RAISE EXCEPTION 'Expected G1 send eligibility after approvals, got eligible=% reason=%', v_is_eligible, v_reason;
    END IF;

    v_payload := core.get_signwell_payload(v_deal_version_id, 'G2');

    IF COALESCE(v_payload ->> 'template_external_id', '') = '' THEN
        RAISE EXCEPTION 'Expected get_signwell_payload to include template_external_id';
    END IF;

    IF NOT (v_payload ? 'fields') THEN
        RAISE EXCEPTION 'Expected get_signwell_payload to include fields object';
    END IF;

    IF NOT (
        (v_payload -> 'fields') ? 'deal_business_key'
        AND (v_payload -> 'fields') ? 'deal_subtype_key'
        AND (v_payload -> 'fields') ? 'gross_billings'
        AND (v_payload -> 'fields') ? 'commission_total'
        AND (v_payload -> 'fields') ? 'lead_broker_email'
        AND (v_payload -> 'fields') ? 'division_head_email'
    ) THEN
        RAISE EXCEPTION 'Expected strict Signwell field keys to be present in payload';
    END IF;

    IF jsonb_array_length(COALESCE(v_payload -> 'recipients', '[]'::jsonb)) < 2 THEN
        RAISE EXCEPTION 'Expected at least 2 recipients (broker + division head) in Signwell payload';
    END IF;

    v_event_id_g1 := 'm3-g1-approve-' || v_deal_version_id::text;

    PERFORM core.ingest_signwell_webhook(
        jsonb_build_object(
            'provider_key', 'SIGNWELL',
            'event_id', v_event_id_g1,
            'event_type', 'recipient.signed',
            'deal_version_id', v_deal_version_id,
            'envelope_id', 'm3-env-g1-' || v_deal_version_id::text,
            'gate_key', 'G1',
            'recipient_email', (SELECT email FROM security.identity WHERE identity_id = v_fin_identity_id),
            'recipient_role_key', 'FIN_APPROVER'
        )
    );

    PERFORM core.ingest_signwell_webhook(
        jsonb_build_object(
            'provider_key', 'SIGNWELL',
            'event_id', v_event_id_g1,
            'event_type', 'recipient.signed',
            'deal_version_id', v_deal_version_id,
            'envelope_id', 'm3-env-g1-' || v_deal_version_id::text,
            'gate_key', 'G1',
            'recipient_email', (SELECT email FROM security.identity WHERE identity_id = v_fin_identity_id),
            'recipient_role_key', 'FIN_APPROVER'
        )
    );

    SELECT COUNT(*)
    INTO v_webhook_count
    FROM audit.webhook_event
    WHERE provider_key = 'SIGNWELL'
      AND event_id = v_event_id_g1;

    IF v_webhook_count <> 1 THEN
        RAISE EXCEPTION 'Expected webhook dedupe by event_id, got count=%', v_webhook_count;
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_id
          AND dv.current_gate_key = 'G2'
    ) THEN
        RAISE EXCEPTION 'Expected G1 signature ingest to move deal_version to G2';
    END IF;

    SELECT e.is_eligible, e.reason
    INTO v_is_eligible, v_reason
    FROM core.is_send_eligible(v_deal_version_id, 'G2') e;

    IF v_is_eligible OR v_reason <> 'APPROVAL_REQUIREMENTS_UNRESOLVED' THEN
        RAISE EXCEPTION 'Expected G2 send eligibility to be blocked by unresolved approvals, got eligible=% reason=%', v_is_eligible, v_reason;
    END IF;

    PERFORM core.ingest_signwell_webhook(
        jsonb_build_object(
            'provider_key', 'SIGNWELL',
            'event_id', 'm3-g2-broker-signed-' || v_deal_version_id::text,
            'event_type', 'recipient.signed',
            'deal_version_id', v_deal_version_id,
            'envelope_id', 'm3-env-g2-' || v_deal_version_id::text,
            'gate_key', 'G2',
            'recipient_email', (SELECT email FROM security.identity WHERE identity_id = v_ops_identity_id),
            'recipient_role_key', 'BROKER'
        )
    );

    PERFORM core.ingest_signwell_webhook(
        jsonb_build_object(
            'provider_key', 'SIGNWELL',
            'event_id', 'm3-g2-divhead-signed-' || v_deal_version_id::text,
            'event_type', 'recipient.signed',
            'deal_version_id', v_deal_version_id,
            'envelope_id', 'm3-env-g2-' || v_deal_version_id::text,
            'gate_key', 'G2',
            'recipient_email', (SELECT email FROM security.identity WHERE identity_id = v_div_head_identity_id),
            'recipient_role_key', 'DIVISION_HEAD',
            'signed_pdf_url', 'https://example.com/m3/signed.pdf',
            'checksum_sha256', 'abc123'
        )
    );

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_id
          AND dv.current_gate_key = 'G3'
    ) THEN
        RAISE EXCEPTION 'Expected completed G2 signatures to move deal_version to G3';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM core.signwell_document_artifact a
        WHERE a.deal_version_id = v_deal_version_id
          AND a.artifact_type = 'SIGNED_PDF'
          AND a.artifact_reference = 'https://example.com/m3/signed.pdf'
    ) THEN
        RAISE EXCEPTION 'Expected signed PDF artifact to be captured from webhook payload';
    END IF;

    PERFORM core.ingest_signwell_webhook(
        jsonb_build_object(
            'provider_key', 'SIGNWELL',
            'event_id', 'm3-g3-fin-declined-' || v_deal_version_id::text,
            'event_type', 'recipient.declined',
            'deal_version_id', v_deal_version_id,
            'envelope_id', 'm3-env-g3-' || v_deal_version_id::text,
            'gate_key', 'G3',
            'recipient_email', (SELECT email FROM security.identity WHERE identity_id = v_fin_identity_id),
            'recipient_role_key', 'FIN_APPROVER'
        )
    );

    IF NOT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_deal_version_id
          AND dv.lifecycle_status = 'REJECTED'
    ) THEN
        RAISE EXCEPTION 'Expected decline ingest to mark deal_version as REJECTED';
    END IF;

    SELECT e.is_eligible, e.reason
    INTO v_is_eligible, v_reason
    FROM core.is_send_eligible(v_deal_version_id, 'G3') e;

    IF v_is_eligible OR v_reason <> 'DEAL_VERSION_REJECTED_OR_SUPERSEDED' THEN
        RAISE EXCEPTION 'Expected send eligibility to block rejected deal_version, got eligible=% reason=%', v_is_eligible, v_reason;
    END IF;
END;
$$;

ROLLBACK;
