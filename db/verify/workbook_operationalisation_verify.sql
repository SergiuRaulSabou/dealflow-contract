-- =========================================================================
-- Verify: V009 workbook operationalisation structures
-- =========================================================================

DO $$
DECLARE
    v_count INTEGER;
BEGIN
    -- Section 2: role_instance table exists.
    ASSERT to_regclass('config.role_instance') IS NOT NULL,
        'config.role_instance must exist';

    -- Section 3: identity extensions.
    ASSERT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'security' AND table_name = 'identity'
          AND column_name = 'auth_source'
    ), 'security.identity.auth_source must exist';

    ASSERT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'security' AND table_name = 'identity'
          AND column_name = 'default_division_key'
    ), 'security.identity.default_division_key must exist';

    -- Section 4: role_assignment extensions.
    ASSERT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'security' AND table_name = 'role_assignment'
          AND column_name = 'role_instance_id'
    ), 'security.role_assignment.role_instance_id must exist';

    ASSERT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'security' AND table_name = 'role_assignment'
          AND column_name = 'is_primary_assignment'
    ), 'security.role_assignment.is_primary_assignment must exist';

    -- Section 10: party entity extensions.
    ASSERT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'ops' AND table_name = 'deal_draft_party'
          AND column_name = 'trading_name'
    ), 'ops.deal_draft_party.trading_name must exist';

    ASSERT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'core' AND table_name = 'deal_version_party'
          AND column_name = 'trading_name'
    ), 'core.deal_version_party.trading_name must exist';

    -- Section 11: property tables.
    ASSERT to_regclass('ops.deal_draft_property') IS NOT NULL,
        'ops.deal_draft_property must exist';

    ASSERT to_regclass('core.deal_version_property_detail') IS NOT NULL,
        'core.deal_version_property_detail must exist';

    -- Section 13: external referral tables.
    ASSERT to_regclass('ops.deal_draft_external_referral') IS NOT NULL,
        'ops.deal_draft_external_referral must exist';

    ASSERT to_regclass('core.deal_version_external_referral') IS NOT NULL,
        'core.deal_version_external_referral must exist';

    -- Section 14: deal_draft extensions.
    ASSERT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'ops' AND table_name = 'deal_draft'
          AND column_name = 'deal_name'
    ), 'ops.deal_draft.deal_name must exist';

    ASSERT EXISTS (
        SELECT 1 FROM information_schema.columns
        WHERE table_schema = 'ops' AND table_name = 'deal_draft_economics'
          AND column_name = 'purchase_price'
    ), 'ops.deal_draft_economics.purchase_price must exist';

    -- Section 15: computation functions exist.
    ASSERT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api' AND p.proname = 'compute_broker_economics'
    ), 'api.compute_broker_economics must exist';

    ASSERT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api' AND p.proname = 'compute_division_summary'
    ), 'api.compute_division_summary must exist';

    ASSERT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api' AND p.proname = 'compute_commission_value'
    ), 'api.compute_commission_value must exist';

    -- Section 16: TBC surfaces now confirmed.
    ASSERT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api' AND p.proname = 'signwell_get_payload'
    ), 'api.signwell_get_payload must exist';

    ASSERT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api' AND p.proname = 'signwell_check_eligibility'
    ), 'api.signwell_check_eligibility must exist';

    ASSERT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api' AND p.proname = 'signwell_ingest_webhook'
    ), 'api.signwell_ingest_webhook must exist';

    ASSERT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api' AND p.proname = 'xero_get_payload'
    ), 'api.xero_get_payload must exist';

    ASSERT EXISTS (
        SELECT 1 FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'api' AND p.proname = 'xero_lock_payload'
    ), 'api.xero_lock_payload must exist';

    -- Section 17: new views exist.
    ASSERT to_regclass('api.v_ops_draft_property') IS NOT NULL,
        'api.v_ops_draft_property must exist';

    ASSERT to_regclass('api.v_ops_draft_brokers_enriched') IS NOT NULL,
        'api.v_ops_draft_brokers_enriched must exist';

    ASSERT to_regclass('api.v_role_instance_selector') IS NOT NULL,
        'api.v_role_instance_selector must exist';

    RAISE NOTICE '=== V009 workbook operationalisation verify: ALL PASSED ===';
END;
$$;
