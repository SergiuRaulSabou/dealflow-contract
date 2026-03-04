-- API contract surface verification script (V008).
-- Validates schema existence, object counts, draft lifecycle, hash-mismatch guard,
-- validation FAIL guard, permission boundaries, and reference catalogue smoke tests.
-- Expected result: no uncaught exceptions.

BEGIN;

-- =========================================================================
-- 1. Schema existence
-- =========================================================================
DO $schema_check$
BEGIN
    IF NOT EXISTS (
        SELECT 1 FROM pg_namespace WHERE nspname = 'api'
    ) THEN
        RAISE EXCEPTION 'api schema does not exist';
    END IF;
END;
$schema_check$;

-- =========================================================================
-- 2. Object count — 18 views and 20 functions in api schema
-- =========================================================================
DO $object_count$
DECLARE
    v_view_count INTEGER;
    v_func_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO v_view_count
    FROM pg_views
    WHERE schemaname = 'api';

    IF v_view_count <> 18 THEN
        RAISE EXCEPTION 'Expected 18 views in api schema, found %', v_view_count;
    END IF;

    SELECT COUNT(*)
    INTO v_func_count
    FROM pg_proc p
    JOIN pg_namespace n ON n.oid = p.pronamespace
    WHERE n.nspname = 'api';

    IF v_func_count <> 20 THEN
        RAISE EXCEPTION 'Expected 20 functions in api schema, found %', v_func_count;
    END IF;
END;
$object_count$;

-- =========================================================================
-- 3. Draft lifecycle smoke test
-- =========================================================================
DO $lifecycle$
DECLARE
    v_identity_id BIGINT;
    v_broker_identity_id BIGINT;
    v_draft_id BIGINT;
    v_econ_id BIGINT;
    v_validate_result RECORD;
    v_dv_id BIGINT;
    v_view_count INTEGER;
BEGIN
    -- Create test identities
    INSERT INTO security.identity (email, display_name)
    VALUES (
        'v8-ops+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'V8 Ops User'
    )
    RETURNING identity_id INTO v_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'v8-broker+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'V8 Broker User'
    )
    RETURNING identity_id INTO v_broker_identity_id;

    INSERT INTO security.role_assignment (identity_id, role_key)
    VALUES (v_broker_identity_id, 'BROKER')
    ON CONFLICT DO NOTHING;

    -- #11 Create draft via api.ops_create_draft
    v_draft_id := api.ops_create_draft(
        'V8-SMOKE-' || v_identity_id::TEXT,
        'LEASE_ACQUISITION_OR_RENEWAL',
        v_identity_id
    );

    IF v_draft_id IS NULL THEN
        RAISE EXCEPTION 'api.ops_create_draft returned NULL';
    END IF;

    -- #13a Upsert party
    PERFORM api.ops_upsert_draft_party(
        v_draft_id, 'SELLER', 'Test Seller', 'seller@example.com'
    );

    -- #13b Upsert broker
    PERFORM api.ops_upsert_draft_broker(
        v_draft_id, v_broker_identity_id, NULL, TRUE, 100.0
    );

    -- #13c Upsert economics
    v_econ_id := api.ops_upsert_draft_economics(
        v_draft_id, 10000.00, 1000.00, 50.0000, 50.0000
    );

    IF v_econ_id IS NULL THEN
        RAISE EXCEPTION 'api.ops_upsert_draft_economics returned NULL';
    END IF;

    -- #13d Upsert docs
    PERFORM api.ops_upsert_draft_doc(v_draft_id, 'DEALSHEET_SIGNED', TRUE, NULL, v_identity_id);
    PERFORM api.ops_upsert_draft_doc(v_draft_id, 'OTP_OR_LEASE', TRUE, NULL, v_identity_id);

    -- #14 Validate draft
    SELECT * INTO v_validate_result
    FROM api.ops_validate_draft(v_draft_id, v_identity_id);

    IF v_validate_result.run_id IS NULL THEN
        RAISE EXCEPTION 'api.ops_validate_draft returned NULL run_id';
    END IF;

    IF v_validate_result.overall_status NOT IN ('PASS', 'WARN') THEN
        RAISE EXCEPTION 'api.ops_validate_draft returned unexpected status: %', v_validate_result.overall_status;
    END IF;

    -- #15 Promote to core
    v_dv_id := api.ops_promote_to_core(v_draft_id, v_identity_id);

    IF v_dv_id IS NULL THEN
        RAISE EXCEPTION 'api.ops_promote_to_core returned NULL';
    END IF;

    -- Read back via draft views to verify they return data
    SELECT COUNT(*) INTO v_view_count
    FROM api.v_ops_draft_header WHERE draft_id = v_draft_id;
    IF v_view_count = 0 THEN
        RAISE EXCEPTION 'api.v_ops_draft_header returned no rows for draft_id %', v_draft_id;
    END IF;

    SELECT COUNT(*) INTO v_view_count
    FROM api.v_ops_draft_parties WHERE draft_id = v_draft_id;
    IF v_view_count = 0 THEN
        RAISE EXCEPTION 'api.v_ops_draft_parties returned no rows for draft_id %', v_draft_id;
    END IF;

    SELECT COUNT(*) INTO v_view_count
    FROM api.v_ops_draft_transaction WHERE draft_id = v_draft_id;
    IF v_view_count = 0 THEN
        RAISE EXCEPTION 'api.v_ops_draft_transaction returned no rows for draft_id %', v_draft_id;
    END IF;

    SELECT COUNT(*) INTO v_view_count
    FROM api.v_ops_draft_docs WHERE draft_id = v_draft_id;
    IF v_view_count = 0 THEN
        RAISE EXCEPTION 'api.v_ops_draft_docs returned no rows for draft_id %', v_draft_id;
    END IF;

    SELECT COUNT(*) INTO v_view_count
    FROM api.v_ops_draft_brokers WHERE draft_id = v_draft_id;
    IF v_view_count = 0 THEN
        RAISE EXCEPTION 'api.v_ops_draft_brokers returned no rows for draft_id %', v_draft_id;
    END IF;

    SELECT COUNT(*) INTO v_view_count
    FROM api.v_ops_draft_commercial_outputs WHERE draft_id = v_draft_id;
    IF v_view_count = 0 THEN
        RAISE EXCEPTION 'api.v_ops_draft_commercial_outputs returned no rows for draft_id %', v_draft_id;
    END IF;

    -- Store identities for later permission tests
    PERFORM set_config('xero.v8_ops_identity_id', v_identity_id::TEXT, FALSE);
    PERFORM set_config('xero.v8_broker_identity_id', v_broker_identity_id::TEXT, FALSE);
    PERFORM set_config('xero.v8_draft_id', v_draft_id::TEXT, FALSE);
    PERFORM set_config('xero.v8_dv_id', v_dv_id::TEXT, FALSE);
END;
$lifecycle$;

-- =========================================================================
-- 4. Hash-mismatch guard
-- =========================================================================
DO $hash_mismatch$
DECLARE
    v_identity_id BIGINT;
    v_broker_identity_id BIGINT;
    v_draft_id BIGINT;
    v_validate_result RECORD;
BEGIN
    INSERT INTO security.identity (email, display_name)
    VALUES (
        'v8-hash-ops+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'V8 Hash Ops'
    )
    RETURNING identity_id INTO v_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'v8-hash-broker+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'V8 Hash Broker'
    )
    RETURNING identity_id INTO v_broker_identity_id;

    INSERT INTO security.role_assignment (identity_id, role_key)
    VALUES (v_broker_identity_id, 'BROKER')
    ON CONFLICT DO NOTHING;

    v_draft_id := api.ops_create_draft(
        'V8-HASH-' || v_identity_id::TEXT,
        'LEASE_ACQUISITION_OR_RENEWAL',
        v_identity_id
    );

    PERFORM api.ops_upsert_draft_broker(v_draft_id, v_broker_identity_id, NULL, TRUE, 100.0);
    PERFORM api.ops_upsert_draft_economics(v_draft_id, 10000.00, 1000.00, 50.0000, 50.0000);
    PERFORM api.ops_upsert_draft_doc(v_draft_id, 'DEALSHEET_SIGNED', TRUE, NULL, v_identity_id);
    PERFORM api.ops_upsert_draft_doc(v_draft_id, 'OTP_OR_LEASE', TRUE, NULL, v_identity_id);

    -- Validate
    SELECT * INTO v_validate_result
    FROM api.ops_validate_draft(v_draft_id, v_identity_id);

    -- Modify economics AFTER validation (changes the hash)
    PERFORM api.ops_upsert_draft_economics(v_draft_id, 99999.00, 9999.00, 60.0000, 40.0000);

    -- Attempt promote (should fail with hash mismatch)
    BEGIN
        PERFORM api.ops_promote_to_core(v_draft_id, v_identity_id);
        RAISE EXCEPTION 'Expected hash mismatch exception but promote succeeded';
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM NOT LIKE '%Hash mismatch%' AND SQLERRM NOT LIKE '%hash mismatch%' AND SQLERRM NOT LIKE '%modified after validation%' THEN
                RAISE EXCEPTION 'Expected hash mismatch exception, got: %', SQLERRM;
            END IF;
    END;
END;
$hash_mismatch$;

-- =========================================================================
-- 5. Validation FAIL guard
-- =========================================================================
DO $fail_guard$
DECLARE
    v_identity_id BIGINT;
    v_draft_id BIGINT;
    v_validate_result RECORD;
BEGIN
    INSERT INTO security.identity (email, display_name)
    VALUES (
        'v8-fail-ops+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'V8 Fail Ops'
    )
    RETURNING identity_id INTO v_identity_id;

    -- Create draft WITHOUT broker (invalid)
    v_draft_id := api.ops_create_draft(
        'V8-FAIL-' || v_identity_id::TEXT,
        'LEASE_ACQUISITION_OR_RENEWAL',
        v_identity_id
    );

    -- Add economics but no broker
    PERFORM api.ops_upsert_draft_economics(v_draft_id, 10000.00, 1000.00, 50.0000, 50.0000);

    -- Validate (should get FAIL status)
    SELECT * INTO v_validate_result
    FROM api.ops_validate_draft(v_draft_id, v_identity_id);

    IF v_validate_result.overall_status <> 'FAIL' THEN
        RAISE EXCEPTION 'Expected FAIL validation status for draft without broker, got %', v_validate_result.overall_status;
    END IF;

    -- Attempt promote (should fail because validation status is FAIL)
    BEGIN
        PERFORM api.ops_promote_to_core(v_draft_id, v_identity_id);
        RAISE EXCEPTION 'Expected FAIL guard exception but promote succeeded';
    EXCEPTION
        WHEN raise_exception THEN
            IF SQLERRM NOT LIKE '%FAIL%' AND SQLERRM NOT LIKE '%fail%' AND SQLERRM NOT LIKE '%status FAIL%' THEN
                RAISE EXCEPTION 'Expected validation FAIL exception, got: %', SQLERRM;
            END IF;
    END;
END;
$fail_guard$;

-- =========================================================================
-- 6. Permission boundaries
-- =========================================================================

-- 6a. app_finance cannot call api.ops_create_draft (insufficient_privilege)
SET ROLE app_finance;
DO $fin_no_create$
BEGIN
    BEGIN
        PERFORM api.ops_create_draft('SHOULD-FAIL', 'LEASE_ACQUISITION_OR_RENEWAL', 1);
        RAISE EXCEPTION 'Expected app_finance to be denied api.ops_create_draft';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;
END;
$fin_no_create$;
RESET ROLE;

-- 6b. app_ops cannot call api.finance_decide (insufficient_privilege)
SET ROLE app_ops;
DO $ops_no_finance$
BEGIN
    BEGIN
        PERFORM api.finance_decide(
            current_setting('xero.v8_dv_id')::BIGINT,
            'APPROVED',
            NULL,
            'should fail'
        );
        RAISE EXCEPTION 'Expected app_ops to be denied api.finance_decide';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;
END;
$ops_no_finance$;
RESET ROLE;

-- 6c. app_ui can SELECT api.v_deal_type_variant_options (success)
SET ROLE app_ui;
DO $ui_can_read_types$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_count FROM api.v_deal_type_variant_options;
    -- Success: no exception thrown (count may be 0 or more)
END;
$ui_can_read_types$;
RESET ROLE;

-- 6d. app_ui cannot call api.ops_create_draft (insufficient_privilege)
SET ROLE app_ui;
DO $ui_no_create$
BEGIN
    BEGIN
        PERFORM api.ops_create_draft('SHOULD-FAIL', 'LEASE_ACQUISITION_OR_RENEWAL', 1);
        RAISE EXCEPTION 'Expected app_ui to be denied api.ops_create_draft';
    EXCEPTION
        WHEN insufficient_privilege THEN
            NULL;
    END;
END;
$ui_no_create$;
RESET ROLE;

-- 6e. app_broker can SELECT api.v_my_deals (success)
SET ROLE app_broker;
DO $broker_can_read_deals$
DECLARE
    v_count INTEGER;
BEGIN
    SELECT security.set_current_identity(current_setting('xero.v8_broker_identity_id')::BIGINT);
    SELECT COUNT(*) INTO v_count FROM api.v_my_deals;
    -- Success: no exception thrown
END;
$broker_can_read_deals$;
RESET ROLE;
SELECT security.set_current_identity(NULL);

-- =========================================================================
-- 7. Reference catalogue smoke tests
-- =========================================================================
DO $ref_smoke$
DECLARE
    v_type_count INTEGER;
    v_broker_count INTEGER;
BEGIN
    SELECT COUNT(*) INTO v_type_count FROM api.v_deal_type_variant_options;
    IF v_type_count = 0 THEN
        RAISE EXCEPTION 'api.v_deal_type_variant_options returned no rows (expected seeded data)';
    END IF;

    SELECT COUNT(*) INTO v_broker_count FROM api.v_broker_directory;
    IF v_broker_count = 0 THEN
        RAISE EXCEPTION 'api.v_broker_directory returned no rows (expected seeded data)';
    END IF;
END;
$ref_smoke$;

ROLLBACK;
