-- Milestone 5 verification script.
-- Security hardening and permission boundary tests.
-- Expected result: no uncaught exceptions.

BEGIN;

DO $setup$
DECLARE
    v_ops_identity_id BIGINT;
    v_fin_identity_id BIGINT;
    v_div_head_identity_id BIGINT;
    v_broker_a_identity_id BIGINT;
    v_broker_b_identity_id BIGINT;
    v_draft_a BIGINT;
    v_draft_b BIGINT;
    v_dv_a BIGINT;
    v_dv_b BIGINT;
BEGIN
    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm5-ops+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone5 Ops'
    )
    RETURNING identity_id INTO v_ops_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm5-fin+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone5 Finance'
    )
    RETURNING identity_id INTO v_fin_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm5-divhead+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone5 Div Head'
    )
    RETURNING identity_id INTO v_div_head_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm5-broker-a+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone5 Broker A'
    )
    RETURNING identity_id INTO v_broker_a_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'm5-broker-b+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Milestone5 Broker B'
    )
    RETURNING identity_id INTO v_broker_b_identity_id;

    INSERT INTO security.role_assignment (identity_id, role_key)
    VALUES
        (v_fin_identity_id, 'FIN_APPROVER'),
        (v_div_head_identity_id, 'DIVISION_HEAD'),
        (v_broker_a_identity_id, 'BROKER'),
        (v_broker_b_identity_id, 'BROKER')
    ON CONFLICT DO NOTHING;

    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M5-BROKER-A-' || v_broker_a_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_a;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_a, v_broker_a_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES
        (v_draft_a, 'DEALSHEET_SIGNED', TRUE),
        (v_draft_a, 'OTP_OR_LEASE', TRUE);

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_a, 1000.00, 100.00, 50.0, 50.0);

    v_dv_a := ops.promote_draft_to_core(v_draft_a, v_ops_identity_id);
    IF v_dv_a IS NULL THEN
        RAISE EXCEPTION 'Milestone5 setup failed to create deal_version A';
    END IF;

    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id
    )
    VALUES (
        'M5-BROKER-B-' || v_broker_b_identity_id::text,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_ops_identity_id,
        v_ops_identity_id
    )
    RETURNING draft_id INTO v_draft_b;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_b, v_broker_b_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES
        (v_draft_b, 'DEALSHEET_SIGNED', TRUE),
        (v_draft_b, 'OTP_OR_LEASE', TRUE);

    INSERT INTO ops.deal_draft_economics (draft_id, gross_billings, commission_total, company_split_pct, broker_split_pct)
    VALUES (v_draft_b, 1000.00, 100.00, 50.0, 50.0);

    v_dv_b := ops.promote_draft_to_core(v_draft_b, v_ops_identity_id);
    IF v_dv_b IS NULL THEN
        RAISE EXCEPTION 'Milestone5 setup failed to create deal_version B';
    END IF;

    PERFORM set_config('xero.m5_ops_identity_id', v_ops_identity_id::TEXT, FALSE);
    PERFORM set_config('xero.m5_fin_identity_id', v_fin_identity_id::TEXT, FALSE);
    PERFORM set_config('xero.m5_broker_a_identity_id', v_broker_a_identity_id::TEXT, FALSE);
    PERFORM set_config('xero.m5_broker_b_identity_id', v_broker_b_identity_id::TEXT, FALSE);
    PERFORM set_config('xero.m5_draft_a', v_draft_a::TEXT, FALSE);
    PERFORM set_config('xero.m5_dv_a', v_dv_a::TEXT, FALSE);
    PERFORM set_config('xero.m5_dv_b', v_dv_b::TEXT, FALSE);
END;
$setup$;

-- Broker RLS: broker A cannot see broker B's deal_version.
SELECT security.set_current_identity(current_setting('xero.m5_broker_a_identity_id')::BIGINT);
SET ROLE app_broker;
DO $broker_rls$
DECLARE
    v_dv_a BIGINT := current_setting('xero.m5_dv_a')::BIGINT;
    v_dv_b BIGINT := current_setting('xero.m5_dv_b')::BIGINT;
    v_visible INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_visible
    FROM core.deal_version dv
    WHERE dv.deal_version_id IN (v_dv_a, v_dv_b);

    IF v_visible <> 1 THEN
        RAISE EXCEPTION 'Expected broker RLS to expose exactly one owned deal_version, got %', v_visible;
    END IF;

    IF EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = v_dv_b
    ) THEN
        RAISE EXCEPTION 'Broker should not be able to read another broker''s deal_version';
    END IF;
END;
$broker_rls$;
RESET ROLE;
SELECT security.set_current_identity(NULL);

-- app_ops cannot approve finance gates.
SET ROLE app_ops;
DO $ops_cannot_approve$
BEGIN
    BEGIN
        PERFORM core.record_gate_decision(
            current_setting('xero.m5_dv_a')::BIGINT,
            'G1',
            'FIN_APPROVER',
            current_setting('xero.m5_fin_identity_id')::BIGINT,
            'APPROVED',
            NULL,
            'should fail'
        );
        RAISE EXCEPTION 'Expected app_ops execution denial on core.record_gate_decision';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;
END;
$ops_cannot_approve$;
RESET ROLE;

-- app_finance cannot mutate ops drafts directly.
SET ROLE app_finance;
DO $finance_cannot_mutate_ops$
BEGIN
    BEGIN
        UPDATE ops.deal_draft
        SET draft_status = 'HACKED'
        WHERE draft_id = current_setting('xero.m5_draft_a')::BIGINT;
        RAISE EXCEPTION 'Expected app_finance update denial on ops.deal_draft';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;
END;
$finance_cannot_mutate_ops$;
RESET ROLE;

-- Direct writes to core snapshots must be blocked for non-system app roles.
SET ROLE app_finance;
DO $core_write_block$
BEGIN
    BEGIN
        UPDATE core.deal_version
        SET current_gate_key = 'G9'
        WHERE deal_version_id = current_setting('xero.m5_dv_a')::BIGINT;
        RAISE EXCEPTION 'Expected app_finance write denial on core.deal_version';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;
END;
$core_write_block$;
RESET ROLE;

-- Unauthorized webhook ingest execution must fail.
SET ROLE app_finance;
DO $unauthorized_webhook$
BEGIN
    BEGIN
        PERFORM core.ingest_signwell_webhook(
            jsonb_build_object(
                'provider_key', 'SIGNWELL',
                'event_id', 'm5-unauthorized',
                'event_type', 'recipient.signed'
            )
        );
        RAISE EXCEPTION 'Expected execute denial on core.ingest_signwell_webhook for app_finance';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;
END;
$unauthorized_webhook$;
RESET ROLE;

-- UI role: lookup views allowed, direct config table access denied.
SET ROLE app_ui;
DO $ui_access$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM config.v_deal_types;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'Expected config.v_deal_types rows for app_ui';
    END IF;

    BEGIN
        PERFORM 1 FROM config.role_catalog LIMIT 1;
        RAISE EXCEPTION 'Expected direct config table access denial for app_ui';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;
END;
$ui_access$;
RESET ROLE;

-- Positive control: app_system can ingest webhooks via contract function.
SET ROLE app_system;
DO $system_can_ingest$
BEGIN
    PERFORM core.ingest_signwell_webhook(
        jsonb_build_object(
            'provider_key', 'SIGNWELL',
            'event_id', 'm5-system-ok',
            'event_type', 'recipient.signed'
        )
    );

    IF NOT EXISTS (
        SELECT 1
        FROM audit.webhook_event we
        WHERE we.event_id = 'm5-system-ok'
          AND we.provider_key = 'SIGNWELL'
    ) THEN
        RAISE EXCEPTION 'Expected app_system webhook ingest to persist audit.webhook_event';
    END IF;
END;
$system_can_ingest$;
RESET ROLE;

ROLLBACK;
