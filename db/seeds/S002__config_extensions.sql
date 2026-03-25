BEGIN;

DO $$
BEGIN
    IF to_regclass('config.deal_type_catalog') IS NULL
       OR to_regclass('config.deal_subtype_catalog') IS NULL
       OR to_regclass('config.commission_rule') IS NULL THEN
        RAISE NOTICE 'Skipping S002__config_extensions.sql because Milestone 4 schema objects are not present yet.';
        RETURN;
    END IF;

    -- -----------------------------------------------------------------------
    -- Milestone 4/5 config extensions: deal type catalogues, expanded template
    -- set, and stable UI lookup/commission metadata.
    -- -----------------------------------------------------------------------

    INSERT INTO config.deal_type_catalog (deal_type_key, display_name, is_active)
    VALUES
        ('LEASE_ACQ_RENEW', 'Lease (Acquisition or Renewal)', TRUE),
        ('LEASE_REGEAR_CLIENT_INV', 'Lease (Regear or Client Invoice)', TRUE),
        ('SALE_PRIVATE_SEALED', 'Sale (Private Treaty or Sealed Bid)', TRUE),
        ('SALE_AUCTION', 'Auction', TRUE)
    ON CONFLICT (deal_type_key) DO UPDATE
    SET display_name = EXCLUDED.display_name,
        is_active = EXCLUDED.is_active;

    WITH subtype_seed(deal_subtype_key, deal_type_key, display_name) AS (
        VALUES
            ('LEASE_ACQUISITION_OR_RENEWAL', 'LEASE_ACQ_RENEW', 'Lease (Acquisition or Renewal) [Legacy Bucket]'),
            ('LEASE_ACQUISITION', 'LEASE_ACQ_RENEW', 'Lease Acquisition'),
            ('LEASE_RENEWAL', 'LEASE_ACQ_RENEW', 'Lease Renewal'),

            ('REGEAR_OR_CLIENT_INVOICE', 'LEASE_REGEAR_CLIENT_INV', 'Lease (Regear or Client Invoice) [Legacy Bucket]'),
            ('LEASE_REGEAR', 'LEASE_REGEAR_CLIENT_INV', 'Lease Regear'),
            ('LEASE_CLIENT_INVOICE', 'LEASE_REGEAR_CLIENT_INV', 'Lease Client Invoice'),

            ('SALE_PVT_TREATY_SEALED_BID', 'SALE_PRIVATE_SEALED', 'Sale (Private Treaty or Sealed Bid) [Legacy Bucket]'),
            ('SALE_PRIVATE_TREATY', 'SALE_PRIVATE_SEALED', 'Sale Private Treaty'),
            ('SALE_SEALED_BID', 'SALE_PRIVATE_SEALED', 'Sale Sealed Bid'),

            ('SALE_AUCTION', 'SALE_AUCTION', 'Sale Auction [Legacy Bucket]'),
            ('AUCTION', 'SALE_AUCTION', 'Auction')
    )
    INSERT INTO config.deal_subtype_catalog (deal_subtype_key, deal_type_key, display_name, is_active)
    SELECT
        ss.deal_subtype_key,
        ss.deal_type_key,
        ss.display_name,
        TRUE
    FROM subtype_seed ss
    ON CONFLICT (deal_subtype_key) DO UPDATE
    SET deal_type_key = EXCLUDED.deal_type_key,
        display_name = EXCLUDED.display_name,
        is_active = EXCLUDED.is_active;

    WITH rule_seed(deal_type_key, rule_key, effective_from, parameters) AS (
        VALUES
            ('LEASE_ACQ_RENEW', 'DEFAULT_SPLIT', DATE '2026-01-01', '{"company_split_pct":50,"broker_split_pct":50}'::jsonb),
            ('LEASE_REGEAR_CLIENT_INV', 'DEFAULT_SPLIT', DATE '2026-01-01', '{"company_split_pct":50,"broker_split_pct":50}'::jsonb),
            ('SALE_PRIVATE_SEALED', 'DEFAULT_SPLIT', DATE '2026-01-01', '{"company_split_pct":45,"broker_split_pct":55}'::jsonb),
            ('SALE_AUCTION', 'DEFAULT_SPLIT', DATE '2026-01-01', '{"company_split_pct":40,"broker_split_pct":60}'::jsonb)
    )
    INSERT INTO config.commission_rule (deal_type_key, rule_key, effective_from, parameters, is_active)
    SELECT
        rs.deal_type_key,
        rs.rule_key,
        rs.effective_from,
        rs.parameters,
        TRUE
    FROM rule_seed rs
    ON CONFLICT (deal_type_key, rule_key, effective_from) DO UPDATE
    SET parameters = EXCLUDED.parameters,
        is_active = EXCLUDED.is_active;

    WITH template_seed(template_key, deal_subtype_key, template_name) AS (
        VALUES
            ('TPL_LEASE_ACQUISITION', 'LEASE_ACQUISITION', 'Lease Acquisition Checklist'),
            ('TPL_LEASE_RENEWAL_V2', 'LEASE_RENEWAL', 'Lease Renewal Checklist'),
            ('TPL_LEASE_REGEAR_V2', 'LEASE_REGEAR', 'Lease Regear Checklist'),
            ('TPL_LEASE_CLIENT_INVOICE', 'LEASE_CLIENT_INVOICE', 'Lease Client Invoice Checklist'),
            ('TPL_SALE_PRIVATE_TREATY', 'SALE_PRIVATE_TREATY', 'Sale Private Treaty Checklist'),
            ('TPL_SALE_SEALED_BID', 'SALE_SEALED_BID', 'Sale Sealed Bid Checklist'),
            ('TPL_AUCTION', 'AUCTION', 'Auction Checklist')
    )
    INSERT INTO config.doc_checklist_template (template_key, deal_subtype_key, template_name, is_active)
    SELECT
        ts.template_key,
        ts.deal_subtype_key,
        ts.template_name,
        TRUE
    FROM template_seed ts
    ON CONFLICT (template_key) DO UPDATE
    SET deal_subtype_key = EXCLUDED.deal_subtype_key,
        template_name = EXCLUDED.template_name,
        is_active = EXCLUDED.is_active;

    WITH template_items(template_key, checklist_item_key, checklist_item_name, gate_key, is_required) AS (
        VALUES
            ('TPL_LEASE_ACQUISITION', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
            ('TPL_LEASE_ACQUISITION', 'OTP_OR_LEASE', 'OTP or Lease Document', 'G1', TRUE),
            ('TPL_LEASE_ACQUISITION', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE),

            ('TPL_LEASE_RENEWAL_V2', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
            ('TPL_LEASE_RENEWAL_V2', 'OTP_OR_LEASE', 'OTP or Lease Document', 'G1', TRUE),
            ('TPL_LEASE_RENEWAL_V2', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE),

            ('TPL_LEASE_REGEAR_V2', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
            ('TPL_LEASE_REGEAR_V2', 'INVOICE_PACK', 'Invoice Supporting Pack', 'G1', TRUE),
            ('TPL_LEASE_REGEAR_V2', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE),

            ('TPL_LEASE_CLIENT_INVOICE', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
            ('TPL_LEASE_CLIENT_INVOICE', 'INVOICE_PACK', 'Invoice Supporting Pack', 'G1', TRUE),
            ('TPL_LEASE_CLIENT_INVOICE', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE),

            ('TPL_SALE_PRIVATE_TREATY', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
            ('TPL_SALE_PRIVATE_TREATY', 'MANDATE', 'Signed Mandate', 'G1', TRUE),
            ('TPL_SALE_PRIVATE_TREATY', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE),

            ('TPL_SALE_SEALED_BID', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
            ('TPL_SALE_SEALED_BID', 'MANDATE', 'Signed Mandate', 'G1', TRUE),
            ('TPL_SALE_SEALED_BID', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE),

            ('TPL_AUCTION', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
            ('TPL_AUCTION', 'MANDATE', 'Signed Mandate', 'G1', TRUE),
            ('TPL_AUCTION', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE)
    ),
    resolved AS (
        SELECT
            dct.doc_checklist_template_id,
            ti.checklist_item_key,
            ti.checklist_item_name,
            ti.gate_key,
            ti.is_required
        FROM template_items ti
        JOIN config.doc_checklist_template dct
          ON dct.template_key = ti.template_key
    )
    INSERT INTO config.doc_checklist_template_item (
        doc_checklist_template_id,
        checklist_item_key,
        checklist_item_name,
        gate_key,
        is_required
    )
    SELECT
        r.doc_checklist_template_id,
        r.checklist_item_key,
        r.checklist_item_name,
        r.gate_key,
        r.is_required
    FROM resolved r
    ON CONFLICT (doc_checklist_template_id, checklist_item_key) DO UPDATE
    SET checklist_item_name = EXCLUDED.checklist_item_name,
        gate_key = EXCLUDED.gate_key,
        is_required = EXCLUDED.is_required;

    WITH fica_items AS (
        SELECT dcti.doc_checklist_template_item_id
        FROM config.doc_checklist_template_item dcti
        WHERE dcti.checklist_item_key = 'FICA_COMPLETE'
    )
    INSERT INTO config.doc_checklist_conditional_rule (
        doc_checklist_template_item_id,
        condition_key,
        condition_expression
    )
    SELECT
        fi.doc_checklist_template_item_id,
        'REQUIRES_FICA_OR_JSE',
        '{"requires_when_any":["IS_JSE_LISTED=true","PARTY_REQUIRES_FICA=true"]}'::jsonb
    FROM fica_items fi
    WHERE NOT EXISTS (
        SELECT 1
        FROM config.doc_checklist_conditional_rule c
        WHERE c.doc_checklist_template_item_id = fi.doc_checklist_template_item_id
          AND c.condition_key = 'REQUIRES_FICA_OR_JSE'
    );

    WITH signwell_seed(gate_key, deal_subtype_key, template_external_id) AS (
        VALUES
            ('G2', 'LEASE_ACQUISITION', 'signwell_tpl_g2_lease_acquisition'),
            ('G2', 'LEASE_RENEWAL', 'signwell_tpl_g2_lease_renewal'),
            ('G2', 'LEASE_REGEAR', 'signwell_tpl_g2_lease_regear'),
            ('G2', 'LEASE_CLIENT_INVOICE', 'signwell_tpl_g2_lease_client_invoice'),
            ('G2', 'SALE_PRIVATE_TREATY', 'signwell_tpl_g2_sale_private_treaty'),
            ('G2', 'SALE_SEALED_BID', 'signwell_tpl_g2_sale_sealed_bid'),
            ('G2', 'AUCTION', 'signwell_tpl_g2_auction')
    )
    INSERT INTO config.signwell_template (
        gate_key,
        deal_subtype_key,
        template_external_id,
        template_version,
        is_active
    )
    SELECT
        ss.gate_key,
        ss.deal_subtype_key,
        ss.template_external_id,
        'v1',
        TRUE
    FROM signwell_seed ss
    ON CONFLICT (gate_key, deal_subtype_key, template_version) DO UPDATE
    SET template_external_id = EXCLUDED.template_external_id,
        is_active = EXCLUDED.is_active;
END;
$$;

COMMIT;
