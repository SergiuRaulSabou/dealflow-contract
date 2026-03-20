BEGIN;

-- =========================================================================
-- V009 — Workbook Operationalisation: close all gaps between
--        Dealflow_System_Setup_Workbook v0.1 and the current DB contract.
-- =========================================================================

-- -------------------------------------------------------------------------
-- 0. Idempotent role guards
-- -------------------------------------------------------------------------
DO $$
BEGIN
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ops') THEN
        CREATE ROLE app_ops NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_finance') THEN
        CREATE ROLE app_finance NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_broker') THEN
        CREATE ROLE app_broker NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_ui') THEN
        CREATE ROLE app_ui NOLOGIN;
    END IF;
    IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_system') THEN
        CREATE ROLE app_system NOLOGIN;
    END IF;
END;
$$;

-- =========================================================================
-- SECTION 1 — Role Catalog extensions (Sheet 02)
-- =========================================================================
-- Add db_role_key and app_role_key mapping columns.
ALTER TABLE config.role_catalog
    ADD COLUMN IF NOT EXISTS db_role_key TEXT,
    ADD COLUMN IF NOT EXISTS app_role_key TEXT,
    ADD COLUMN IF NOT EXISTS role_scope TEXT;

-- =========================================================================
-- SECTION 2 — Role Instances (Sheet 03)
-- =========================================================================
CREATE TABLE IF NOT EXISTS config.role_instance (
    role_instance_id TEXT PRIMARY KEY,
    role_key TEXT NOT NULL REFERENCES config.role_catalog (role_key),
    instance_name TEXT NOT NULL,
    division_key TEXT,
    org_unit_key TEXT,
    commission_classification TEXT,
    country TEXT NOT NULL DEFAULT 'SA',
    region TEXT,
    area TEXT,
    approval_level TEXT,
    escalates_to_role_instance_id TEXT,
    visibility_scope_key TEXT,
    geo_scope_key TEXT,
    is_broker_role BOOLEAN NOT NULL DEFAULT FALSE,
    is_finance_role BOOLEAN NOT NULL DEFAULT FALSE,
    is_signwell_recipient_role BOOLEAN NOT NULL DEFAULT FALSE,
    approved_by_role_instance_id TEXT,
    is_active BOOLEAN NOT NULL DEFAULT TRUE,
    effective_from DATE NOT NULL DEFAULT CURRENT_DATE,
    effective_to DATE,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW()
);

CREATE INDEX IF NOT EXISTS ix_role_instance_role_key ON config.role_instance (role_key);
CREATE INDEX IF NOT EXISTS ix_role_instance_division ON config.role_instance (division_key);

-- =========================================================================
-- SECTION 3 — Identity extensions (Sheet 04)
-- =========================================================================
ALTER TABLE security.identity
    ADD COLUMN IF NOT EXISTS auth_source TEXT,
    ADD COLUMN IF NOT EXISTS default_org_unit_key TEXT,
    ADD COLUMN IF NOT EXISTS default_division_key TEXT,
    ADD COLUMN IF NOT EXISTS identity_type TEXT NOT NULL DEFAULT 'USER',
    ADD COLUMN IF NOT EXISTS employee_code TEXT,
    ADD COLUMN IF NOT EXISTS external_ref TEXT,
    ADD COLUMN IF NOT EXISTS signwell_recipient_email_flag BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS effective_from DATE,
    ADD COLUMN IF NOT EXISTS effective_to DATE;

-- =========================================================================
-- SECTION 4 — Role Assignment extensions (Sheet 05)
-- =========================================================================
ALTER TABLE security.role_assignment
    ADD COLUMN IF NOT EXISTS role_instance_id TEXT REFERENCES config.role_instance (role_instance_id),
    ADD COLUMN IF NOT EXISTS employee_code TEXT,
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS visibility_scope_key TEXT,
    ADD COLUMN IF NOT EXISTS assignment_status TEXT NOT NULL DEFAULT 'ACTIVE',
    ADD COLUMN IF NOT EXISTS visibility_override_key TEXT,
    ADD COLUMN IF NOT EXISTS approval_override_role_instance_id TEXT,
    ADD COLUMN IF NOT EXISTS is_primary_assignment BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS effective_from DATE,
    ADD COLUMN IF NOT EXISTS effective_to DATE;

-- Drop the old unique constraint that prevents multiple role assignments.
-- The workbook model allows multiple active assignments per user.
DO $$
BEGIN
    IF EXISTS (
        SELECT 1 FROM pg_constraint
        WHERE conname = 'role_assignment_identity_id_role_key_key'
          AND conrelid = 'security.role_assignment'::regclass
    ) THEN
        ALTER TABLE security.role_assignment
            DROP CONSTRAINT role_assignment_identity_id_role_key_key;
    END IF;
END;
$$;

-- Replacement: unique on identity + role + role_instance (allows same role_key
-- with different role_instance_id values).
CREATE UNIQUE INDEX IF NOT EXISTS ux_role_assignment_identity_role_instance
    ON security.role_assignment (identity_id, role_key, COALESCE(role_instance_id, ''))
    WHERE is_active = TRUE;

-- =========================================================================
-- SECTION 5 — Approval Hierarchy extensions (Sheet 06)
-- =========================================================================
ALTER TABLE config.approval_rule
    ADD COLUMN IF NOT EXISTS deal_family TEXT,
    ADD COLUMN IF NOT EXISTS subtype_key TEXT,
    ADD COLUMN IF NOT EXISTS variant_key TEXT,
    ADD COLUMN IF NOT EXISTS division_key TEXT,
    ADD COLUMN IF NOT EXISTS sub_division_key TEXT,
    ADD COLUMN IF NOT EXISTS country_key TEXT,
    ADD COLUMN IF NOT EXISTS region_key TEXT,
    ADD COLUMN IF NOT EXISTS area_key TEXT,
    ADD COLUMN IF NOT EXISTS applies_to_role_code TEXT,
    ADD COLUMN IF NOT EXISTS applies_to_role_instance_id TEXT,
    ADD COLUMN IF NOT EXISTS escalation_rule_key TEXT,
    ADD COLUMN IF NOT EXISTS fallback_approver_role_instance_id TEXT,
    ADD COLUMN IF NOT EXISTS approval_required_flag BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS reason_if_bypassed TEXT,
    ADD COLUMN IF NOT EXISTS approval_mode TEXT NOT NULL DEFAULT 'SEQUENTIAL',
    ADD COLUMN IF NOT EXISTS threshold_metric TEXT,
    ADD COLUMN IF NOT EXISTS comparison_operator TEXT,
    ADD COLUMN IF NOT EXISTS threshold_value NUMERIC(18,2),
    ADD COLUMN IF NOT EXISTS effective_from DATE,
    ADD COLUMN IF NOT EXISTS effective_to DATE,
    ADD COLUMN IF NOT EXISTS is_active BOOLEAN NOT NULL DEFAULT TRUE;

-- =========================================================================
-- SECTION 6 — Deal Types & Variants extensions (Sheet 07)
-- =========================================================================
ALTER TABLE config.deal_type_variant
    ADD COLUMN IF NOT EXISTS deal_family TEXT,
    ADD COLUMN IF NOT EXISTS subtype_key TEXT,
    ADD COLUMN IF NOT EXISTS deal_sheet_template_key TEXT,
    ADD COLUMN IF NOT EXISTS xero_payload_type TEXT,
    ADD COLUMN IF NOT EXISTS checklist_template_key TEXT,
    ADD COLUMN IF NOT EXISTS signwell_template_group TEXT,
    ADD COLUMN IF NOT EXISTS ui_group TEXT,
    ADD COLUMN IF NOT EXISTS allows_external_referral BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS requires_property_section BOOLEAN NOT NULL DEFAULT TRUE,
    ADD COLUMN IF NOT EXISTS requires_conveyancer_section BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS requires_landlord BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS requires_tenant BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS requires_buyer BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS requires_seller BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS requires_client BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS allows_invoicing_instructions BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS broker_slots_max INTEGER NOT NULL DEFAULT 8,
    ADD COLUMN IF NOT EXISTS active_from DATE,
    ADD COLUMN IF NOT EXISTS active_to DATE;

-- =========================================================================
-- SECTION 7 — Document Requirements extensions (Sheet 08)
-- =========================================================================
ALTER TABLE config.doc_checklist_template_item
    ADD COLUMN IF NOT EXISTS deal_family TEXT,
    ADD COLUMN IF NOT EXISTS subtype_key TEXT,
    ADD COLUMN IF NOT EXISTS variant_key TEXT,
    ADD COLUMN IF NOT EXISTS party_scope TEXT,
    ADD COLUMN IF NOT EXISTS mandatory_flag_if_jse_listed BOOLEAN,
    ADD COLUMN IF NOT EXISTS mandatory_flag_if_not_jse_listed BOOLEAN,
    ADD COLUMN IF NOT EXISTS signwell_required BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS finance_required BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS exclusion_rule_key TEXT,
    ADD COLUMN IF NOT EXISTS document_stage TEXT,
    ADD COLUMN IF NOT EXISTS document_source_type TEXT,
    ADD COLUMN IF NOT EXISTS display_order INTEGER;

-- =========================================================================
-- SECTION 8 — Commission Rules extensions (Sheet 09)
-- =========================================================================
ALTER TABLE config.commission_rule
    ADD COLUMN IF NOT EXISTS deal_family TEXT,
    ADD COLUMN IF NOT EXISTS subtype_key TEXT,
    ADD COLUMN IF NOT EXISTS variant_key TEXT,
    ADD COLUMN IF NOT EXISTS role_key TEXT,
    ADD COLUMN IF NOT EXISTS division_key TEXT,
    ADD COLUMN IF NOT EXISTS threshold_period TEXT,
    ADD COLUMN IF NOT EXISTS reset_event TEXT,
    ADD COLUMN IF NOT EXISTS tier_sequence INTEGER,
    ADD COLUMN IF NOT EXISTS override_reason_required BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS external_referral_supported_flag BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS net_commission_computation_method TEXT,
    ADD COLUMN IF NOT EXISTS threshold_metric TEXT,
    ADD COLUMN IF NOT EXISTS applies_from_threshold_inclusive NUMERIC(18,2),
    ADD COLUMN IF NOT EXISTS applies_to_threshold_exclusive NUMERIC(18,2),
    ADD COLUMN IF NOT EXISTS commission_pct NUMERIC(9,4),
    ADD COLUMN IF NOT EXISTS company_split_pct NUMERIC(9,4),
    ADD COLUMN IF NOT EXISTS broker_net_formula_note TEXT;

-- =========================================================================
-- SECTION 9 — Signwell Template extensions (Sheet 10)
-- =========================================================================
ALTER TABLE config.signwell_template
    ADD COLUMN IF NOT EXISTS deal_family TEXT,
    ADD COLUMN IF NOT EXISTS subtype_key TEXT,
    ADD COLUMN IF NOT EXISTS variant_key TEXT,
    ADD COLUMN IF NOT EXISTS signwell_template_name TEXT,
    ADD COLUMN IF NOT EXISTS signing_mode TEXT NOT NULL DEFAULT 'SEQUENTIAL',
    ADD COLUMN IF NOT EXISTS deal_sheet_template_key TEXT,
    ADD COLUMN IF NOT EXISTS field_map_version TEXT NOT NULL DEFAULT 'v1';

-- Extend recipient role map to support up to 9 slots per template.
ALTER TABLE config.signwell_recipient_role_map
    ADD COLUMN IF NOT EXISTS deal_family TEXT,
    ADD COLUMN IF NOT EXISTS subtype_key TEXT,
    ADD COLUMN IF NOT EXISTS variant_key TEXT,
    ADD COLUMN IF NOT EXISTS signwell_template_id BIGINT REFERENCES config.signwell_template (signwell_template_id);

-- =========================================================================
-- SECTION 10 — Party / Entity detail tables (Sheet 11 requirement)
-- =========================================================================
-- The deal sheet field map requires rich party entity detail. The current
-- ops.deal_draft_party only stores party_name/email/phone. We need a
-- structured entity model for trading name, registration, VAT, addresses,
-- contacts, JSE listed flag, and lead source.

ALTER TABLE ops.deal_draft_party
    ADD COLUMN IF NOT EXISTS trading_name TEXT,
    ADD COLUMN IF NOT EXISTS registration_number TEXT,
    ADD COLUMN IF NOT EXISTS vat_number TEXT,
    ADD COLUMN IF NOT EXISTS jse_listed BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS address_line1 TEXT,
    ADD COLUMN IF NOT EXISTS address_line2 TEXT,
    ADD COLUMN IF NOT EXISTS address_line3 TEXT,
    ADD COLUMN IF NOT EXISTS address_line4 TEXT,
    ADD COLUMN IF NOT EXISTS contact_name TEXT,
    ADD COLUMN IF NOT EXISTS contact_number TEXT,
    ADD COLUMN IF NOT EXISTS contact_email TEXT,
    ADD COLUMN IF NOT EXISTS invoicing_instructions TEXT,
    ADD COLUMN IF NOT EXISTS lead_source TEXT,
    ADD COLUMN IF NOT EXISTS lead_rebase_link TEXT;

-- Mirror in core snapshot.
ALTER TABLE core.deal_version_party
    ADD COLUMN IF NOT EXISTS trading_name TEXT,
    ADD COLUMN IF NOT EXISTS registration_number TEXT,
    ADD COLUMN IF NOT EXISTS vat_number TEXT,
    ADD COLUMN IF NOT EXISTS jse_listed BOOLEAN NOT NULL DEFAULT FALSE,
    ADD COLUMN IF NOT EXISTS address_line1 TEXT,
    ADD COLUMN IF NOT EXISTS address_line2 TEXT,
    ADD COLUMN IF NOT EXISTS address_line3 TEXT,
    ADD COLUMN IF NOT EXISTS address_line4 TEXT,
    ADD COLUMN IF NOT EXISTS contact_name TEXT,
    ADD COLUMN IF NOT EXISTS contact_number TEXT,
    ADD COLUMN IF NOT EXISTS contact_email TEXT,
    ADD COLUMN IF NOT EXISTS invoicing_instructions TEXT,
    ADD COLUMN IF NOT EXISTS lead_source TEXT,
    ADD COLUMN IF NOT EXISTS lead_rebase_link TEXT;

-- =========================================================================
-- SECTION 11 — Property table (Sheet 11 requirement)
-- =========================================================================
CREATE TABLE IF NOT EXISTS ops.deal_draft_property (
    draft_property_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    premises_name TEXT,
    property_name TEXT,
    property_address_line1 TEXT,
    property_address_line2 TEXT,
    property_address_line3 TEXT,
    property_address_line4 TEXT,
    gla_sqm NUMERIC(18,4),
    property_type TEXT,
    property_grade TEXT,
    property_source TEXT,
    property_listing_broker TEXT,
    property_rebase_link TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (draft_id)
);

CREATE TABLE IF NOT EXISTS core.deal_version_property_detail (
    deal_version_property_detail_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    premises_name TEXT,
    property_name TEXT,
    property_address_line1 TEXT,
    property_address_line2 TEXT,
    property_address_line3 TEXT,
    property_address_line4 TEXT,
    gla_sqm NUMERIC(18,4),
    property_type TEXT,
    property_grade TEXT,
    property_source TEXT,
    property_listing_broker TEXT,
    property_rebase_link TEXT,
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_version_id)
);

-- =========================================================================
-- SECTION 12 — Extended broker model (Sheet 11: per-broker economics)
-- =========================================================================
ALTER TABLE ops.deal_draft_broker
    ADD COLUMN IF NOT EXISTS role_instance_id TEXT,
    ADD COLUMN IF NOT EXISTS broker_slot INTEGER,
    ADD COLUMN IF NOT EXISTS division_key TEXT;

ALTER TABLE core.deal_version_broker
    ADD COLUMN IF NOT EXISTS role_instance_id TEXT,
    ADD COLUMN IF NOT EXISTS broker_slot INTEGER,
    ADD COLUMN IF NOT EXISTS division_key TEXT;

-- =========================================================================
-- SECTION 13 — External Referral (Sheet 11 requirement)
-- =========================================================================
CREATE TABLE IF NOT EXISTS ops.deal_draft_external_referral (
    draft_external_referral_id BIGSERIAL PRIMARY KEY,
    draft_id BIGINT NOT NULL REFERENCES ops.deal_draft (draft_id) ON DELETE CASCADE,
    entity_name TEXT,
    contact_name TEXT,
    contact_email TEXT,
    split_of_gross_deal NUMERIC(7,4),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (draft_id)
);

CREATE TABLE IF NOT EXISTS core.deal_version_external_referral (
    deal_version_external_referral_id BIGSERIAL PRIMARY KEY,
    deal_version_id BIGINT NOT NULL REFERENCES core.deal_version (deal_version_id) ON DELETE CASCADE,
    entity_name TEXT,
    contact_name TEXT,
    contact_email TEXT,
    split_of_gross_deal NUMERIC(7,4),
    created_at TIMESTAMPTZ NOT NULL DEFAULT NOW(),
    UNIQUE (deal_version_id)
);

-- =========================================================================
-- SECTION 14 — Extended deal_draft fields (Sheet 11: deal name, dates)
-- =========================================================================
ALTER TABLE ops.deal_draft
    ADD COLUMN IF NOT EXISTS deal_name TEXT,
    ADD COLUMN IF NOT EXISTS deal_family TEXT,
    ADD COLUMN IF NOT EXISTS variant_key TEXT;

ALTER TABLE ops.deal_draft_economics
    ADD COLUMN IF NOT EXISTS purchase_price NUMERIC(18,2),
    ADD COLUMN IF NOT EXISTS commission_pct NUMERIC(9,4),
    ADD COLUMN IF NOT EXISTS due_diligence_end_date DATE,
    ADD COLUMN IF NOT EXISTS deposit_due_date DATE,
    ADD COLUMN IF NOT EXISTS settlement_terms TEXT,
    ADD COLUMN IF NOT EXISTS payment_due_date_1 DATE,
    ADD COLUMN IF NOT EXISTS payment_due_date_2 DATE,
    ADD COLUMN IF NOT EXISTS payment_due_date_3 DATE,
    ADD COLUMN IF NOT EXISTS payment_due_date_4 DATE,
    ADD COLUMN IF NOT EXISTS invoice_reference TEXT,
    ADD COLUMN IF NOT EXISTS invoice_contact_person TEXT,
    ADD COLUMN IF NOT EXISTS invoice_contact_number TEXT,
    ADD COLUMN IF NOT EXISTS invoice_additional_instructions TEXT;

ALTER TABLE core.deal_version_economics
    ADD COLUMN IF NOT EXISTS purchase_price NUMERIC(18,2),
    ADD COLUMN IF NOT EXISTS commission_pct NUMERIC(9,4),
    ADD COLUMN IF NOT EXISTS due_diligence_end_date DATE,
    ADD COLUMN IF NOT EXISTS deposit_due_date DATE,
    ADD COLUMN IF NOT EXISTS settlement_terms TEXT,
    ADD COLUMN IF NOT EXISTS payment_due_date_1 DATE,
    ADD COLUMN IF NOT EXISTS payment_due_date_2 DATE,
    ADD COLUMN IF NOT EXISTS payment_due_date_3 DATE,
    ADD COLUMN IF NOT EXISTS payment_due_date_4 DATE,
    ADD COLUMN IF NOT EXISTS invoice_reference TEXT,
    ADD COLUMN IF NOT EXISTS invoice_contact_person TEXT,
    ADD COLUMN IF NOT EXISTS invoice_contact_number TEXT,
    ADD COLUMN IF NOT EXISTS invoice_additional_instructions TEXT;

-- =========================================================================
-- SECTION 15 — DB-computed economics functions (Sheets 09 + 11)
-- =========================================================================

-- Compute commission value = purchase_price * commission_pct
-- Compute broker split_with_company from commission rules
-- Compute broker net_commission from gross, split, and company split
-- Compute division summary rows

CREATE OR REPLACE FUNCTION api.compute_broker_economics(
    p_draft_id BIGINT
)
RETURNS TABLE (
    broker_slot INTEGER,
    role_instance_id TEXT,
    division_key TEXT,
    split_of_gross_deal NUMERIC(7,4),
    split_with_company NUMERIC(9,4),
    net_commission_before_tax NUMERIC(18,2)
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_gross NUMERIC(18,2);
    v_purchase_price NUMERIC(18,2);
    v_commission_pct NUMERIC(9,4);
    v_commission_total NUMERIC(18,2);
    v_deal_subtype_key TEXT;
BEGIN
    SELECT
        e.gross_billings,
        e.purchase_price,
        e.commission_pct,
        e.commission_total,
        d.deal_subtype_key
    INTO v_gross, v_purchase_price, v_commission_pct, v_commission_total, v_deal_subtype_key
    FROM ops.deal_draft d
    LEFT JOIN ops.deal_draft_economics e ON e.draft_id = d.draft_id
    WHERE d.draft_id = p_draft_id;

    -- Compute commission_total from purchase_price * commission_pct if not set.
    IF v_commission_total IS NULL AND v_purchase_price IS NOT NULL AND v_commission_pct IS NOT NULL THEN
        v_commission_total := v_purchase_price * v_commission_pct;
    END IF;

    v_gross := COALESCE(v_gross, v_commission_total, 0);

    RETURN QUERY
    SELECT
        b.broker_slot,
        b.role_instance_id,
        COALESCE(b.division_key, ri.division_key) AS division_key,
        b.split_percent AS split_of_gross_deal,
        -- Lookup company split from commission rules, falling back to 50/50.
        COALESCE(
            (SELECT cr.company_split_pct
             FROM config.commission_rule cr
             WHERE cr.is_active = TRUE
               AND (cr.division_key IS NULL OR cr.division_key = COALESCE(b.division_key, ri.division_key))
               AND (cr.applies_from_threshold_inclusive IS NULL OR v_gross >= cr.applies_from_threshold_inclusive)
               AND (cr.applies_to_threshold_exclusive IS NULL OR v_gross < cr.applies_to_threshold_exclusive)
             ORDER BY cr.tier_sequence NULLS LAST, cr.commission_rule_id
             LIMIT 1),
            0.5000
        ) AS split_with_company,
        -- net = gross_share * (1 - company_split)
        ROUND(
            v_gross
            * COALESCE(b.split_percent, 0)
            * (1.0 - COALESCE(
                (SELECT cr.company_split_pct
                 FROM config.commission_rule cr
                 WHERE cr.is_active = TRUE
                   AND (cr.division_key IS NULL OR cr.division_key = COALESCE(b.division_key, ri.division_key))
                   AND (cr.applies_from_threshold_inclusive IS NULL OR v_gross >= cr.applies_from_threshold_inclusive)
                   AND (cr.applies_to_threshold_exclusive IS NULL OR v_gross < cr.applies_to_threshold_exclusive)
                 ORDER BY cr.tier_sequence NULLS LAST, cr.commission_rule_id
                 LIMIT 1),
                0.5000
            )),
            2
        ) AS net_commission_before_tax
    FROM ops.deal_draft_broker b
    LEFT JOIN config.role_instance ri ON ri.role_instance_id = b.role_instance_id
    WHERE b.draft_id = p_draft_id
    ORDER BY b.broker_slot NULLS LAST, b.draft_broker_id;
END;
$$;

-- Division summary computation.
CREATE OR REPLACE FUNCTION api.compute_division_summary(
    p_draft_id BIGINT
)
RETURNS TABLE (
    division_key TEXT,
    division_total NUMERIC(18,2)
)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN QUERY
    SELECT
        be.division_key,
        SUM(be.net_commission_before_tax) AS division_total
    FROM api.compute_broker_economics(p_draft_id) be
    WHERE be.division_key IS NOT NULL
    GROUP BY be.division_key
    ORDER BY be.division_key;
END;
$$;

-- External referral net commission computation.
CREATE OR REPLACE FUNCTION api.compute_external_referral_economics(
    p_draft_id BIGINT
)
RETURNS TABLE (
    entity_name TEXT,
    split_of_gross_deal NUMERIC(7,4),
    net_commission_before_tax NUMERIC(18,2)
)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_gross NUMERIC(18,2);
BEGIN
    SELECT COALESCE(e.gross_billings, e.purchase_price * e.commission_pct, 0)
    INTO v_gross
    FROM ops.deal_draft_economics e
    WHERE e.draft_id = p_draft_id;

    RETURN QUERY
    SELECT
        er.entity_name,
        er.split_of_gross_deal,
        ROUND(v_gross * COALESCE(er.split_of_gross_deal, 0), 2)
    FROM ops.deal_draft_external_referral er
    WHERE er.draft_id = p_draft_id;
END;
$$;

-- Commission value computation (purchase_price * commission_pct).
CREATE OR REPLACE FUNCTION api.compute_commission_value(
    p_draft_id BIGINT
)
RETURNS NUMERIC(18,2)
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_result NUMERIC(18,2);
BEGIN
    SELECT
        COALESCE(
            e.commission_total,
            ROUND(COALESCE(e.purchase_price, 0) * COALESCE(e.commission_pct, 0), 2)
        )
    INTO v_result
    FROM ops.deal_draft_economics e
    WHERE e.draft_id = p_draft_id;

    RETURN COALESCE(v_result, 0);
END;
$$;

-- Invoice value computation (= commission_value for now).
CREATE OR REPLACE FUNCTION api.compute_invoice_value(
    p_draft_id BIGINT
)
RETURNS NUMERIC(18,2)
LANGUAGE plpgsql
STABLE
AS $$
BEGIN
    RETURN api.compute_commission_value(p_draft_id);
END;
$$;

-- =========================================================================
-- SECTION 16 — Confirm TBC Surfaces (Sheet 12)
-- =========================================================================
-- The 5 TBC surfaces from sheet 12 map to existing functions:
--   TBC_signwell_payload_surface    → api.signwell_get_payload
--   TBC_signwell_send_eligibility   → api.signwell_check_eligibility
--   TBC_webhook_ingest_surface      → api.signwell_ingest_webhook
--   TBC_xero_payload_surface        → api.xero_get_payload
--   TBC_payload_lock_surface        → api.xero_lock_payload

CREATE OR REPLACE FUNCTION api.signwell_get_payload(
    p_deal_version_id BIGINT,
    p_gate_key TEXT DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_gate TEXT;
BEGIN
    IF p_gate_key IS NULL THEN
        SELECT dv.current_gate_key INTO v_gate
        FROM core.deal_version dv WHERE dv.deal_version_id = p_deal_version_id;
    ELSE
        v_gate := p_gate_key;
    END IF;
    RETURN core.get_signwell_payload(p_deal_version_id, v_gate);
END;
$$;

CREATE OR REPLACE FUNCTION api.signwell_check_eligibility(
    p_deal_version_id BIGINT,
    p_gate_key TEXT DEFAULT NULL
)
RETURNS TABLE (is_eligible BOOLEAN, reason TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_gate TEXT;
BEGIN
    IF p_gate_key IS NULL THEN
        SELECT dv.current_gate_key INTO v_gate
        FROM core.deal_version dv WHERE dv.deal_version_id = p_deal_version_id;
    ELSE
        v_gate := p_gate_key;
    END IF;
    RETURN QUERY SELECT e.is_eligible, e.reason FROM core.is_send_eligible(p_deal_version_id, v_gate) e;
END;
$$;

CREATE OR REPLACE FUNCTION api.signwell_ingest_webhook(
    p_payload JSONB
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM core.ingest_signwell_webhook(p_payload);
END;
$$;

CREATE OR REPLACE FUNCTION api.xero_get_payload(
    p_deal_version_id BIGINT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
BEGIN
    RETURN core.get_xero_payload(p_deal_version_id);
END;
$$;

CREATE OR REPLACE FUNCTION api.xero_lock_payload(
    p_deal_version_id BIGINT,
    p_locked_by_identity_id BIGINT DEFAULT NULL
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    PERFORM core.lock_xero_payload(p_deal_version_id, p_locked_by_identity_id);
END;
$$;

-- =========================================================================
-- SECTION 17 — Extended API views for deal sheet field map (Sheet 11)
-- =========================================================================

-- Property read model for draft.
CREATE OR REPLACE VIEW api.v_ops_draft_property AS
SELECT
    p.draft_id,
    p.premises_name,
    p.property_name,
    p.property_address_line1,
    p.property_address_line2,
    p.property_address_line3,
    p.property_address_line4,
    p.gla_sqm,
    p.property_type,
    p.property_grade,
    p.property_source,
    p.property_listing_broker,
    p.property_rebase_link
FROM ops.deal_draft_property p;

-- External referral read model for draft.
CREATE OR REPLACE VIEW api.v_ops_draft_external_referral AS
SELECT
    er.draft_id,
    er.entity_name,
    er.contact_name,
    er.contact_email,
    er.split_of_gross_deal,
    cx.net_commission_before_tax
FROM ops.deal_draft_external_referral er
LEFT JOIN LATERAL api.compute_external_referral_economics(er.draft_id) cx
    ON cx.entity_name = er.entity_name;

-- Enriched broker read model with DB-computed economics.
CREATE OR REPLACE VIEW api.v_ops_draft_brokers_enriched AS
SELECT
    b.draft_id,
    b.draft_broker_id,
    b.broker_identity_id,
    b.broker_external_ref,
    b.is_lead_broker,
    b.broker_slot,
    b.role_instance_id,
    COALESCE(b.division_key, ri.division_key) AS division_key,
    i.display_name AS broker_name,
    i.email AS broker_email,
    b.split_percent AS split_of_gross_deal,
    be.split_with_company,
    be.net_commission_before_tax
FROM ops.deal_draft_broker b
LEFT JOIN security.identity i ON i.identity_id = b.broker_identity_id
LEFT JOIN config.role_instance ri ON ri.role_instance_id = b.role_instance_id
LEFT JOIN LATERAL (
    SELECT ce.split_with_company, ce.net_commission_before_tax
    FROM api.compute_broker_economics(b.draft_id) ce
    WHERE ce.broker_slot = b.broker_slot
       OR (ce.broker_slot IS NULL AND b.broker_slot IS NULL)
    LIMIT 1
) be ON TRUE;

-- Role instance selector view.
CREATE OR REPLACE VIEW api.v_role_instance_selector AS
SELECT
    ri.role_instance_id,
    ri.role_key,
    ri.instance_name,
    ri.division_key,
    ri.org_unit_key,
    ri.region,
    ri.is_active,
    rc.role_name,
    rc.role_type
FROM config.role_instance ri
JOIN config.role_catalog rc ON rc.role_key = ri.role_key
WHERE ri.is_active = TRUE;

-- =========================================================================
-- SECTION 18 — Upsert functions for new entities
-- =========================================================================

CREATE OR REPLACE FUNCTION api.ops_upsert_draft_property(
    p_draft_id BIGINT,
    p_premises_name TEXT DEFAULT NULL,
    p_property_name TEXT DEFAULT NULL,
    p_address_line1 TEXT DEFAULT NULL,
    p_address_line2 TEXT DEFAULT NULL,
    p_address_line3 TEXT DEFAULT NULL,
    p_address_line4 TEXT DEFAULT NULL,
    p_gla_sqm NUMERIC DEFAULT NULL,
    p_property_type TEXT DEFAULT NULL,
    p_property_grade TEXT DEFAULT NULL,
    p_property_source TEXT DEFAULT NULL,
    p_property_listing_broker TEXT DEFAULT NULL,
    p_property_rebase_link TEXT DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO ops.deal_draft_property (
        draft_id, premises_name, property_name,
        property_address_line1, property_address_line2,
        property_address_line3, property_address_line4,
        gla_sqm, property_type, property_grade,
        property_source, property_listing_broker, property_rebase_link
    )
    VALUES (
        p_draft_id, p_premises_name, p_property_name,
        p_address_line1, p_address_line2, p_address_line3, p_address_line4,
        p_gla_sqm, p_property_type, p_property_grade,
        p_property_source, p_property_listing_broker, p_property_rebase_link
    )
    ON CONFLICT (draft_id) DO UPDATE SET
        premises_name = COALESCE(EXCLUDED.premises_name, ops.deal_draft_property.premises_name),
        property_name = COALESCE(EXCLUDED.property_name, ops.deal_draft_property.property_name),
        property_address_line1 = COALESCE(EXCLUDED.property_address_line1, ops.deal_draft_property.property_address_line1),
        property_address_line2 = COALESCE(EXCLUDED.property_address_line2, ops.deal_draft_property.property_address_line2),
        property_address_line3 = COALESCE(EXCLUDED.property_address_line3, ops.deal_draft_property.property_address_line3),
        property_address_line4 = COALESCE(EXCLUDED.property_address_line4, ops.deal_draft_property.property_address_line4),
        gla_sqm = COALESCE(EXCLUDED.gla_sqm, ops.deal_draft_property.gla_sqm),
        property_type = COALESCE(EXCLUDED.property_type, ops.deal_draft_property.property_type),
        property_grade = COALESCE(EXCLUDED.property_grade, ops.deal_draft_property.property_grade),
        property_source = COALESCE(EXCLUDED.property_source, ops.deal_draft_property.property_source),
        property_listing_broker = COALESCE(EXCLUDED.property_listing_broker, ops.deal_draft_property.property_listing_broker),
        property_rebase_link = COALESCE(EXCLUDED.property_rebase_link, ops.deal_draft_property.property_rebase_link)
    RETURNING draft_property_id INTO v_id;

    RETURN v_id;
END;
$$;

CREATE OR REPLACE FUNCTION api.ops_upsert_draft_external_referral(
    p_draft_id BIGINT,
    p_entity_name TEXT DEFAULT NULL,
    p_contact_name TEXT DEFAULT NULL,
    p_contact_email TEXT DEFAULT NULL,
    p_split_of_gross_deal NUMERIC DEFAULT NULL
)
RETURNS BIGINT
LANGUAGE plpgsql
AS $$
DECLARE
    v_id BIGINT;
BEGIN
    INSERT INTO ops.deal_draft_external_referral (
        draft_id, entity_name, contact_name, contact_email, split_of_gross_deal
    )
    VALUES (
        p_draft_id, p_entity_name, p_contact_name, p_contact_email, p_split_of_gross_deal
    )
    ON CONFLICT (draft_id) DO UPDATE SET
        entity_name = COALESCE(EXCLUDED.entity_name, ops.deal_draft_external_referral.entity_name),
        contact_name = COALESCE(EXCLUDED.contact_name, ops.deal_draft_external_referral.contact_name),
        contact_email = COALESCE(EXCLUDED.contact_email, ops.deal_draft_external_referral.contact_email),
        split_of_gross_deal = COALESCE(EXCLUDED.split_of_gross_deal, ops.deal_draft_external_referral.split_of_gross_deal)
    RETURNING draft_external_referral_id INTO v_id;

    RETURN v_id;
END;
$$;

-- =========================================================================
-- SECTION 19 — Security: DEFINER + search_path + grants
-- =========================================================================
ALTER FUNCTION api.compute_broker_economics(BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.compute_broker_economics(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.compute_division_summary(BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.compute_division_summary(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.compute_external_referral_economics(BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.compute_external_referral_economics(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.compute_commission_value(BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.compute_commission_value(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.compute_invoice_value(BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.compute_invoice_value(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.signwell_get_payload(BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION api.signwell_get_payload(BIGINT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.signwell_check_eligibility(BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION api.signwell_check_eligibility(BIGINT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.signwell_ingest_webhook(JSONB) SECURITY DEFINER;
ALTER FUNCTION api.signwell_ingest_webhook(JSONB)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.xero_get_payload(BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.xero_get_payload(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.xero_lock_payload(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION api.xero_lock_payload(BIGINT, BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.ops_upsert_draft_property(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, TEXT) SECURITY DEFINER;
ALTER FUNCTION api.ops_upsert_draft_property(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

ALTER FUNCTION api.ops_upsert_draft_external_referral(BIGINT, TEXT, TEXT, TEXT, NUMERIC) SECURITY DEFINER;
ALTER FUNCTION api.ops_upsert_draft_external_referral(BIGINT, TEXT, TEXT, TEXT, NUMERIC)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, api, public;

-- Grants.
GRANT EXECUTE ON FUNCTION api.compute_broker_economics(BIGINT) TO app_ops, app_finance, app_ui;
GRANT EXECUTE ON FUNCTION api.compute_division_summary(BIGINT) TO app_ops, app_finance, app_ui;
GRANT EXECUTE ON FUNCTION api.compute_external_referral_economics(BIGINT) TO app_ops, app_finance, app_ui;
GRANT EXECUTE ON FUNCTION api.compute_commission_value(BIGINT) TO app_ops, app_finance, app_ui;
GRANT EXECUTE ON FUNCTION api.compute_invoice_value(BIGINT) TO app_ops, app_finance, app_ui;
GRANT EXECUTE ON FUNCTION api.signwell_get_payload(BIGINT, TEXT) TO app_finance, app_system;
GRANT EXECUTE ON FUNCTION api.signwell_check_eligibility(BIGINT, TEXT) TO app_finance, app_system, app_ops;
GRANT EXECUTE ON FUNCTION api.signwell_ingest_webhook(JSONB) TO app_system;
GRANT EXECUTE ON FUNCTION api.xero_get_payload(BIGINT) TO app_finance, app_system;
GRANT EXECUTE ON FUNCTION api.xero_lock_payload(BIGINT, BIGINT) TO app_finance, app_system;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_property(BIGINT, TEXT, TEXT, TEXT, TEXT, TEXT, TEXT, NUMERIC, TEXT, TEXT, TEXT, TEXT, TEXT) TO app_ops;
GRANT EXECUTE ON FUNCTION api.ops_upsert_draft_external_referral(BIGINT, TEXT, TEXT, TEXT, NUMERIC) TO app_ops;

GRANT SELECT ON api.v_ops_draft_property TO app_ops, app_finance, app_ui;
GRANT SELECT ON api.v_ops_draft_external_referral TO app_ops, app_finance, app_ui;
GRANT SELECT ON api.v_ops_draft_brokers_enriched TO app_ops, app_finance, app_ui;
GRANT SELECT ON api.v_role_instance_selector TO app_ops, app_finance, app_ui, app_broker;

GRANT SELECT ON config.role_instance TO app_ops, app_finance, app_system;
GRANT SELECT ON ops.deal_draft_property TO app_ops;
GRANT SELECT ON ops.deal_draft_external_referral TO app_ops;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ops TO app_ops;

GRANT SELECT ON core.deal_version_property_detail TO app_finance, app_system;
GRANT SELECT ON core.deal_version_external_referral TO app_finance, app_system;

-- =========================================================================
-- SECTION 20 — Updated promote_draft_to_core with V009 table snapshots
-- =========================================================================

-- Add deal_name and deal_family to core.deal_version so they can be
-- snapshotted during promotion.
ALTER TABLE core.deal_version
    ADD COLUMN IF NOT EXISTS deal_name TEXT,
    ADD COLUMN IF NOT EXISTS deal_family TEXT;

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
    v_business_key TEXT;
    v_deal_id BIGINT;
    v_prev_deal_version_id BIGINT;
    v_prev_major INTEGER;
    v_prev_minor INTEGER;
    v_new_major INTEGER;
    v_new_minor INTEGER;
    v_new_deal_version_id BIGINT;
    v_template_id BIGINT;
    v_requires_fica BOOLEAN;
    v_missing_required_docs INTEGER;
    v_unconfirmed_required_docs INTEGER;
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

    -- Determine applicable checklist template for this draft subtype.
    SELECT dct.doc_checklist_template_id
    INTO v_template_id
    FROM config.doc_checklist_template dct
    WHERE dct.deal_subtype_key = v_draft.deal_subtype_key
      AND dct.is_active = TRUE
    ORDER BY dct.created_at DESC
    LIMIT 1;

    IF v_template_id IS NULL THEN
        INSERT INTO ops.validation_result (
            draft_id,
            rule_code,
            severity,
            field_path,
            validation_message
        )
        VALUES (
            p_draft_id,
            'DOC_TEMPLATE_MISSING',
            'ERROR',
            'config.doc_checklist_template',
            'No active document checklist template exists for this deal subtype.'
        );

        UPDATE ops.deal_draft
        SET draft_status = 'VALIDATION_FAILED',
            updated_by_identity_id = p_submitted_by_identity_id,
            updated_at = NOW()
        WHERE draft_id = p_draft_id;

        RETURN NULL;
    END IF;

    SELECT (
        v_draft.is_jse_listed
        OR EXISTS (
            SELECT 1
            FROM ops.deal_draft_party p
            WHERE p.draft_id = p_draft_id
              AND p.requires_fica = TRUE
        )
    )
    INTO v_requires_fica;

    -- Fail if any required docs are missing or unconfirmed.
    WITH required_items AS (
        SELECT
            dcti.checklist_item_key AS doc_code,
            CASE
                WHEN dcti.checklist_item_key = 'FICA_COMPLETE'
                     AND EXISTS (
                         SELECT 1
                         FROM config.doc_checklist_conditional_rule r
                         WHERE r.doc_checklist_template_item_id = dcti.doc_checklist_template_item_id
                           AND r.condition_key = 'REQUIRES_FICA_OR_JSE'
                     )
                THEN v_requires_fica
                ELSE dcti.is_required
            END AS is_required
        FROM config.doc_checklist_template_item dcti
        WHERE dcti.doc_checklist_template_id = v_template_id
    ),
    required_docs AS (
        SELECT doc_code
        FROM required_items
        WHERE is_required = TRUE
    )
    SELECT
        (SELECT COUNT(*)
         FROM required_docs rd
         LEFT JOIN ops.deal_draft_doc_status ds
           ON ds.draft_id = p_draft_id
          AND ds.doc_code = rd.doc_code
         WHERE ds.draft_doc_status_id IS NULL),
        (SELECT COUNT(*)
         FROM required_docs rd
         JOIN ops.deal_draft_doc_status ds
           ON ds.draft_id = p_draft_id
          AND ds.doc_code = rd.doc_code
         WHERE ds.is_confirmed = FALSE)
    INTO v_missing_required_docs, v_unconfirmed_required_docs;

    IF v_missing_required_docs > 0 THEN
        INSERT INTO ops.validation_result (
            draft_id,
            rule_code,
            severity,
            field_path,
            validation_message
        )
        SELECT
            p_draft_id,
            'DOC_REQUIRED',
            'ERROR',
            'ops.deal_draft_doc_status.' || rd.doc_code,
            'Document ' || rd.doc_code || ' is required.'
        FROM (
            WITH required_items AS (
                SELECT
                    dcti.checklist_item_key AS doc_code,
                    CASE
                        WHEN dcti.checklist_item_key = 'FICA_COMPLETE'
                             AND EXISTS (
                                 SELECT 1
                                 FROM config.doc_checklist_conditional_rule r
                                 WHERE r.doc_checklist_template_item_id = dcti.doc_checklist_template_item_id
                                   AND r.condition_key = 'REQUIRES_FICA_OR_JSE'
                             )
                        THEN v_requires_fica
                        ELSE dcti.is_required
                    END AS is_required
                FROM config.doc_checklist_template_item dcti
                WHERE dcti.doc_checklist_template_id = v_template_id
            )
            SELECT doc_code
            FROM required_items
            WHERE is_required = TRUE
        ) rd
        LEFT JOIN ops.deal_draft_doc_status ds
          ON ds.draft_id = p_draft_id
         AND ds.doc_code = rd.doc_code
        WHERE ds.draft_doc_status_id IS NULL;
    END IF;

    IF v_unconfirmed_required_docs > 0 THEN
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
          AND ds.is_confirmed = FALSE
          AND EXISTS (
              WITH required_items AS (
                  SELECT
                      dcti.checklist_item_key AS doc_code,
                      CASE
                          WHEN dcti.checklist_item_key = 'FICA_COMPLETE'
                               AND EXISTS (
                                   SELECT 1
                                   FROM config.doc_checklist_conditional_rule r
                                   WHERE r.doc_checklist_template_item_id = dcti.doc_checklist_template_item_id
                                     AND r.condition_key = 'REQUIRES_FICA_OR_JSE'
                               )
                          THEN v_requires_fica
                          ELSE dcti.is_required
                      END AS is_required
                  FROM config.doc_checklist_template_item dcti
                  WHERE dcti.doc_checklist_template_id = v_template_id
              )
              SELECT 1
              FROM required_items ri
              WHERE ri.is_required = TRUE
                AND ri.doc_code = ds.doc_code
          );
    END IF;

    IF (v_missing_required_docs + v_unconfirmed_required_docs) > 0 THEN
        UPDATE ops.deal_draft
        SET draft_status = 'VALIDATION_FAILED',
            updated_by_identity_id = p_submitted_by_identity_id,
            updated_at = NOW()
        WHERE draft_id = p_draft_id;

        RETURN NULL;
    END IF;

    -- Economics must exist (minimal invariant for deterministic promotion).
    IF NOT EXISTS (
        SELECT 1
        FROM ops.deal_draft_economics e
        WHERE e.draft_id = p_draft_id
    ) THEN
        INSERT INTO ops.validation_result (
            draft_id,
            rule_code,
            severity,
            field_path,
            validation_message
        )
        VALUES (
            p_draft_id,
            'ECONOMICS_REQUIRED',
            'ERROR',
            'ops.deal_draft_economics',
            'Economics are required to submit.'
        );

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
        promoted_at,
        is_jse_listed,
        deal_subtype_key,
        deal_name,
        deal_family
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
        NOW(),
        v_draft.is_jse_listed,
        v_draft.deal_subtype_key,
        v_draft.deal_name,
        v_draft.deal_family
    )
    RETURNING deal_version_id INTO v_new_deal_version_id;

    -- Materialize baseline Gate 1 approval requirements at promotion time.
    PERFORM core.materialize_approval_requirements(v_new_deal_version_id, 'G1', 'DEFAULT_GATES_0_3');

    INSERT INTO core.deal_version_party (
        deal_version_id,
        party_role_key,
        party_name,
        party_email,
        party_phone,
        requires_fica,
        trading_name,
        registration_number,
        vat_number,
        jse_listed,
        address_line1,
        address_line2,
        address_line3,
        address_line4,
        contact_name,
        contact_number,
        contact_email,
        invoicing_instructions,
        lead_source,
        lead_rebase_link
    )
    SELECT
        v_new_deal_version_id,
        p.party_role_key,
        p.party_name,
        p.party_email,
        p.party_phone,
        p.requires_fica,
        p.trading_name,
        p.registration_number,
        p.vat_number,
        p.jse_listed,
        p.address_line1,
        p.address_line2,
        p.address_line3,
        p.address_line4,
        p.contact_name,
        p.contact_number,
        p.contact_email,
        p.invoicing_instructions,
        p.lead_source,
        p.lead_rebase_link
    FROM ops.deal_draft_party p
    WHERE p.draft_id = p_draft_id;

    INSERT INTO core.deal_version_broker (
        deal_version_id,
        broker_identity_id,
        broker_external_ref,
        is_lead_broker,
        split_percent,
        role_instance_id,
        broker_slot,
        division_key
    )
    SELECT
        v_new_deal_version_id,
        b.broker_identity_id,
        b.broker_external_ref,
        b.is_lead_broker,
        b.split_percent,
        b.role_instance_id,
        b.broker_slot,
        b.division_key
    FROM ops.deal_draft_broker b
    WHERE b.draft_id = p_draft_id;

    INSERT INTO core.deal_version_economics (
        deal_version_id,
        gross_billings,
        commission_total,
        company_split_pct,
        broker_split_pct,
        economics_payload,
        purchase_price,
        commission_pct,
        due_diligence_end_date,
        deposit_due_date,
        settlement_terms,
        payment_due_date_1,
        payment_due_date_2,
        payment_due_date_3,
        payment_due_date_4,
        invoice_reference,
        invoice_contact_person,
        invoice_contact_number,
        invoice_additional_instructions
    )
    SELECT
        v_new_deal_version_id,
        e.gross_billings,
        e.commission_total,
        e.company_split_pct,
        e.broker_split_pct,
        e.economics_payload,
        e.purchase_price,
        e.commission_pct,
        e.due_diligence_end_date,
        e.deposit_due_date,
        e.settlement_terms,
        e.payment_due_date_1,
        e.payment_due_date_2,
        e.payment_due_date_3,
        e.payment_due_date_4,
        e.invoice_reference,
        e.invoice_contact_person,
        e.invoice_contact_number,
        e.invoice_additional_instructions
    FROM ops.deal_draft_economics e
    WHERE e.draft_id = p_draft_id;

    -- Snapshot property detail from draft to core.
    INSERT INTO core.deal_version_property_detail (
        deal_version_id,
        premises_name,
        property_name,
        property_address_line1,
        property_address_line2,
        property_address_line3,
        property_address_line4,
        gla_sqm,
        property_type,
        property_grade,
        property_source,
        property_listing_broker,
        property_rebase_link
    )
    SELECT
        v_new_deal_version_id,
        pp.premises_name,
        pp.property_name,
        pp.property_address_line1,
        pp.property_address_line2,
        pp.property_address_line3,
        pp.property_address_line4,
        pp.gla_sqm,
        pp.property_type,
        pp.property_grade,
        pp.property_source,
        pp.property_listing_broker,
        pp.property_rebase_link
    FROM ops.deal_draft_property pp
    WHERE pp.draft_id = p_draft_id;

    -- Snapshot external referral from draft to core.
    INSERT INTO core.deal_version_external_referral (
        deal_version_id,
        entity_name,
        contact_name,
        contact_email,
        split_of_gross_deal
    )
    SELECT
        v_new_deal_version_id,
        er.entity_name,
        er.contact_name,
        er.contact_email,
        er.split_of_gross_deal
    FROM ops.deal_draft_external_referral er
    WHERE er.draft_id = p_draft_id;

    -- Snapshot checklist status for all items in the template, including missing/unconfirmed (should only be non-required at this point).
    WITH template_items AS (
        SELECT
            dcti.doc_checklist_template_item_id,
            dcti.checklist_item_key AS doc_code,
            CASE
                WHEN dcti.checklist_item_key = 'FICA_COMPLETE'
                     AND EXISTS (
                         SELECT 1
                         FROM config.doc_checklist_conditional_rule r
                         WHERE r.doc_checklist_template_item_id = dcti.doc_checklist_template_item_id
                           AND r.condition_key = 'REQUIRES_FICA_OR_JSE'
                     )
                THEN v_requires_fica
                ELSE dcti.is_required
            END AS is_required
        FROM config.doc_checklist_template_item dcti
        WHERE dcti.doc_checklist_template_id = v_template_id
    )
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
        ti.doc_checklist_template_item_id,
        ti.doc_code,
        ti.is_required,
        COALESCE(ds.is_confirmed, FALSE),
        ds.note
    FROM template_items ti
    LEFT JOIN ops.deal_draft_doc_status ds
      ON ds.draft_id = p_draft_id
     AND ds.doc_code = ti.doc_code;

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
