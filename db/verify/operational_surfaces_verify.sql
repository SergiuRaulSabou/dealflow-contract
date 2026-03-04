-- Gap-closure verification.
-- Verifies: UI operational read models, payload retrieval surface,
-- and compatibility schema scaffolds populated by seed.
-- Expected result: no uncaught exceptions.

BEGIN;

DO $$
DECLARE
    v_missing_tables TEXT;
    v_ops_identity_id BIGINT;
    v_fin_identity_id BIGINT;
    v_broker_identity_id BIGINT;
    v_draft_id BIGINT;
    v_deal_version_id BIGINT;
    v_payload_bundle JSONB;
    v_count INTEGER;
BEGIN
    -- Required compatibility tables from schema sheets must exist.
    WITH required(schema_name, table_name) AS (
        VALUES
            ('config', 'deal_type'),
            ('config', 'deal_type_variant'),
            ('config', 'field_dictionary'),
            ('config', 'deal_type_field_rule'),
            ('config', 'party_role'),
            ('config', 'party_role_rule'),
            ('config', 'broker_role'),
            ('config', 'commission_band'),
            ('config', 'economics_rule_set'),
            ('config', 'economics_rule'),
            ('config', 'invoice_plan_template'),
            ('config', 'invoice_plan_rule'),
            ('config', 'deal_type_gate_rule'),
            ('config', 'doc_category'),
            ('config', 'doc_checklist_item'),
            ('config', 'deal_type_doc_checklist_rule'),
            ('config', 'approval_role'),
            ('config', 'deal_type_approval_matrix'),
            ('config', 'org_unit'),
            ('config', 'org_position'),
            ('config', 'role_permission'),
            ('config', 'signwell_field_map'),
            ('config', 'webhook_source'),
            ('config', 'validation_rule'),
            ('config', 'environment_setting'),
            ('config', 'audit_event_type'),
            ('core', 'deal_version_property'),
            ('core', 'deal_version_invoice_plan'),
            ('core', 'deal_version_document'),
            ('core', 'deal_version_gate'),
            ('raw', 'invoice'),
            ('raw', 'deal_attributes'),
            ('raw', 'document_flags'),
            ('raw', 'invoice_commission_allocation'),
            ('raw', 'invoice_commission_provision'),
            ('raw', 'ref_person'),
            ('raw', 'ref_cost_center')
    ), missing AS (
        SELECT r.schema_name || '.' || r.table_name AS object_name
        FROM required r
        LEFT JOIN information_schema.tables t
          ON t.table_schema = r.schema_name
         AND t.table_name = r.table_name
        WHERE t.table_name IS NULL
    )
    SELECT string_agg(object_name, ', ' ORDER BY object_name)
    INTO v_missing_tables
    FROM missing;

    IF v_missing_tables IS NOT NULL THEN
        RAISE EXCEPTION 'Missing required compatibility tables: %', v_missing_tables;
    END IF;

    -- Required new contract surfaces must exist.
    IF NOT EXISTS (
        SELECT 1
        FROM pg_views v
        WHERE v.schemaname = 'core'
          AND v.viewname = 'v_deal_tracker'
    ) THEN
        RAISE EXCEPTION 'Missing required view core.v_deal_tracker';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_views v
        WHERE v.schemaname = 'core'
          AND v.viewname = 'v_finance_review_summary'
    ) THEN
        RAISE EXCEPTION 'Missing required view core.v_finance_review_summary';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core'
          AND p.proname = 'get_task_list'
          AND pg_get_function_identity_arguments(p.oid) = 'p_identity_id bigint'
    ) THEN
        RAISE EXCEPTION 'Missing required function core.get_task_list(BIGINT)';
    END IF;

    IF NOT EXISTS (
        SELECT 1
        FROM pg_proc p
        JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'core'
          AND p.proname = 'get_payload_bundle'
          AND pg_get_function_identity_arguments(p.oid) = 'p_deal_version_id bigint, p_gate_key text'
    ) THEN
        RAISE EXCEPTION 'Missing required function core.get_payload_bundle(BIGINT, TEXT)';
    END IF;

    -- Seeded compatibility catalogue checks.
    SELECT COUNT(*) INTO v_count FROM config.deal_type;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'Expected seeded rows in config.deal_type';
    END IF;

    SELECT COUNT(*) INTO v_count FROM config.deal_type_variant;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'Expected seeded rows in config.deal_type_variant';
    END IF;

    SELECT COUNT(*) INTO v_count FROM config.signwell_field_map;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'Expected seeded rows in config.signwell_field_map';
    END IF;

    SELECT COUNT(*) INTO v_count FROM config.audit_event_type;
    IF v_count = 0 THEN
        RAISE EXCEPTION 'Expected seeded rows in config.audit_event_type';
    END IF;

    -- Functional smoke: create a draft, promote, and read through new surfaces.
    INSERT INTO security.identity (email, display_name)
    VALUES (
        'gap-ops+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Gap Verify Ops'
    )
    RETURNING identity_id INTO v_ops_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'gap-fin+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Gap Verify Finance'
    )
    RETURNING identity_id INTO v_fin_identity_id;

    INSERT INTO security.identity (email, display_name)
    VALUES (
        'gap-broker+' || to_char(clock_timestamp(), 'YYYYMMDDHH24MISSMS') || '@example.com',
        'Gap Verify Broker'
    )
    RETURNING identity_id INTO v_broker_identity_id;

    INSERT INTO security.role_assignment (identity_id, role_key)
    VALUES
        (v_fin_identity_id, 'FIN_APPROVER'),
        (v_broker_identity_id, 'BROKER')
    ON CONFLICT DO NOTHING;

    INSERT INTO ops.deal_draft (
        deal_business_key,
        deal_subtype_key,
        current_gate_key,
        created_by_identity_id,
        updated_by_identity_id,
        is_jse_listed
    )
    VALUES (
        'GAP-CLOSURE-' || v_ops_identity_id::TEXT,
        'LEASE_ACQUISITION_OR_RENEWAL',
        'G0',
        v_ops_identity_id,
        v_ops_identity_id,
        FALSE
    )
    RETURNING draft_id INTO v_draft_id;

    INSERT INTO ops.deal_draft_broker (draft_id, broker_identity_id, is_lead_broker, split_percent)
    VALUES (v_draft_id, v_broker_identity_id, TRUE, 100.0);

    INSERT INTO ops.deal_draft_doc_status (draft_id, doc_code, is_confirmed)
    VALUES
        (v_draft_id, 'DEALSHEET_SIGNED', TRUE),
        (v_draft_id, 'OTP_OR_LEASE', TRUE);

    INSERT INTO ops.deal_draft_economics (
        draft_id,
        gross_billings,
        commission_total,
        company_split_pct,
        broker_split_pct
    )
    VALUES (v_draft_id, 1000.00, 100.00, 50.0, 50.0);

    v_deal_version_id := ops.promote_draft_to_core(v_draft_id, v_ops_identity_id);
    IF v_deal_version_id IS NULL THEN
        RAISE EXCEPTION 'Gap verification setup failed to promote draft';
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM core.v_deal_tracker v
    WHERE v.deal_version_id = v_deal_version_id;

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected core.v_deal_tracker row for promoted deal_version';
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM core.v_finance_review_summary v
    WHERE v.deal_version_id = v_deal_version_id;

    IF v_count <> 1 THEN
        RAISE EXCEPTION 'Expected core.v_finance_review_summary row for promoted deal_version';
    END IF;

    SELECT COUNT(*)
    INTO v_count
    FROM core.get_task_list(v_fin_identity_id) t
    WHERE t.deal_version_id = v_deal_version_id
      AND t.task_type = 'APPROVAL';

    IF v_count = 0 THEN
        RAISE EXCEPTION 'Expected finance approval tasks in core.get_task_list(...)';
    END IF;

    v_payload_bundle := core.get_payload_bundle(v_deal_version_id, 'G1');

    IF v_payload_bundle IS NULL
       OR NOT (v_payload_bundle ? 'signwell')
       OR NOT (v_payload_bundle ? 'xero') THEN
        RAISE EXCEPTION 'Expected core.get_payload_bundle(...) to return signwell and xero sections';
    END IF;

    IF COALESCE(v_payload_bundle #>> '{signwell,reason}', '') = '' THEN
        RAISE EXCEPTION 'Expected core.get_payload_bundle(...) to include signwell reason';
    END IF;
END;
$$;

ROLLBACK;
