BEGIN;

-- ---------------------------------------------------------------------------
-- Populate compatibility config scaffolds from existing baseline configuration
-- ---------------------------------------------------------------------------

INSERT INTO config.deal_type (deal_type_key, display_name, is_active)
SELECT
    dt.deal_type_key,
    dt.display_name,
    dt.is_active
FROM config.deal_type_catalog dt
ON CONFLICT (deal_type_key) DO UPDATE
SET display_name = EXCLUDED.display_name,
    is_active = EXCLUDED.is_active;

INSERT INTO config.deal_type_variant (deal_type_id, variant_key, display_name, is_active)
SELECT
    dtc.deal_type_id,
    dsc.deal_subtype_key,
    dsc.display_name,
    dsc.is_active
FROM config.deal_subtype_catalog dsc
JOIN config.deal_type dtc
  ON dtc.deal_type_key = dsc.deal_type_key
ON CONFLICT (variant_key) DO UPDATE
SET deal_type_id = EXCLUDED.deal_type_id,
    display_name = EXCLUDED.display_name,
    is_active = EXCLUDED.is_active;

INSERT INTO config.field_dictionary (
    field_key,
    data_type,
    ui_label,
    field_description,
    in_signature_payload,
    is_active
)
SELECT
    sfd.signwell_field_key,
    COALESCE(NULLIF(sfd.field_type, ''), 'TEXT') AS data_type,
    INITCAP(REPLACE(sfd.signwell_field_key, '_', ' ')) AS ui_label,
    'Seeded from config.signwell_field_dictionary' AS field_description,
    TRUE,
    TRUE
FROM config.signwell_field_dictionary sfd
ON CONFLICT (field_key) DO UPDATE
SET data_type = EXCLUDED.data_type,
    ui_label = EXCLUDED.ui_label,
    in_signature_payload = EXCLUDED.in_signature_payload,
    is_active = EXCLUDED.is_active;

INSERT INTO config.field_dictionary (
    field_key,
    data_type,
    ui_label,
    field_description,
    in_signature_payload,
    is_active
)
VALUES
    ('deal_business_key', 'TEXT', 'Deal Business Key', 'Stable deal identifier', FALSE, TRUE),
    ('deal_subtype_key', 'TEXT', 'Deal Subtype Key', 'Canonical deal subtype key', FALSE, TRUE),
    ('gross_billings', 'NUMERIC', 'Gross Billings', 'Draft economics gross billings', FALSE, TRUE),
    ('commission_total', 'NUMERIC', 'Commission Total', 'Draft economics commission total', FALSE, TRUE),
    ('broker_split_pct', 'NUMERIC', 'Broker Split Percent', 'Draft economics broker split percentage', FALSE, TRUE),
    ('company_split_pct', 'NUMERIC', 'Company Split Percent', 'Draft economics company split percentage', FALSE, TRUE)
ON CONFLICT (field_key) DO UPDATE
SET data_type = EXCLUDED.data_type,
    ui_label = EXCLUDED.ui_label,
    field_description = EXCLUDED.field_description,
    in_signature_payload = EXCLUDED.in_signature_payload,
    is_active = EXCLUDED.is_active;

INSERT INTO config.party_role (party_role_key, display_name, is_active)
VALUES
    ('LANDLORD', 'Landlord', TRUE),
    ('TENANT', 'Tenant', TRUE),
    ('SELLER', 'Seller', TRUE),
    ('BUYER', 'Buyer', TRUE),
    ('OTHER_AGENT', 'Other Agent', TRUE)
ON CONFLICT (party_role_key) DO UPDATE
SET display_name = EXCLUDED.display_name,
    is_active = EXCLUDED.is_active;

INSERT INTO config.broker_role (broker_role_key, display_name, participates_in_rls, participates_in_approvals)
VALUES
    ('LEAD', 'Lead Broker', TRUE, TRUE),
    ('SUPPORT', 'Support Broker', TRUE, TRUE),
    ('INTRODUCER', 'Introducer', TRUE, FALSE)
ON CONFLICT (broker_role_key) DO UPDATE
SET display_name = EXCLUDED.display_name,
    participates_in_rls = EXCLUDED.participates_in_rls,
    participates_in_approvals = EXCLUDED.participates_in_approvals;

INSERT INTO config.commission_band (band_key, min_percent, max_percent)
VALUES
    ('COMPANY_50', 50.0000, 50.0000),
    ('COMPANY_60', 60.0000, 60.0000),
    ('CUSTOM', 0.0000, 100.0000)
ON CONFLICT (band_key) DO UPDATE
SET min_percent = EXCLUDED.min_percent,
    max_percent = EXCLUDED.max_percent;

INSERT INTO config.economics_rule_set (deal_type_id, rule_set_key, rule_set_name, is_active)
SELECT
    dt.deal_type_id,
    dt.deal_type_key || '_DEFAULT_ECON',
    dt.display_name || ' Default Economics',
    dt.is_active
FROM config.deal_type dt
ON CONFLICT (rule_set_key) DO UPDATE
SET deal_type_id = EXCLUDED.deal_type_id,
    rule_set_name = EXCLUDED.rule_set_name,
    is_active = EXCLUDED.is_active;

INSERT INTO config.economics_rule (economics_rule_set_id, rule_code, precedence, rule_parameters)
SELECT
    ers.economics_rule_set_id,
    rule.rule_code,
    rule.precedence,
    rule.parameters
FROM config.economics_rule_set ers
CROSS JOIN (
    VALUES
        ('BROKER_SPLIT_SUM_100', 10, jsonb_build_object('expected_total', 100.0)),
        ('COMPANY_BROKER_SPLIT_SUM_100', 20, jsonb_build_object('expected_total', 100.0)),
        ('COMMISSION_LTE_GROSS', 30, '{}'::jsonb)
) AS rule(rule_code, precedence, parameters)
ON CONFLICT (economics_rule_set_id, rule_code) DO UPDATE
SET precedence = EXCLUDED.precedence,
    rule_parameters = EXCLUDED.rule_parameters;

INSERT INTO config.invoice_plan_template (deal_type_variant_id, template_key, template_payload, is_active)
SELECT
    dv.deal_type_variant_id,
    dv.variant_key || '_DEFAULT_INVOICE',
    jsonb_build_object('billing_model', 'SINGLE', 'currency', 'ZAR'),
    dv.is_active
FROM config.deal_type_variant dv
ON CONFLICT (template_key) DO UPDATE
SET deal_type_variant_id = EXCLUDED.deal_type_variant_id,
    template_payload = EXCLUDED.template_payload,
    is_active = EXCLUDED.is_active;

INSERT INTO config.invoice_plan_rule (invoice_plan_template_id, rule_code, rule_parameters)
SELECT
    ipt.invoice_plan_template_id,
    'TOTAL_RECONCILES',
    jsonb_build_object('required', TRUE)
FROM config.invoice_plan_template ipt
ON CONFLICT (invoice_plan_template_id, rule_code) DO UPDATE
SET rule_parameters = EXCLUDED.rule_parameters;

INSERT INTO config.deal_type_gate_rule (deal_type_variant_id, gate_key, gate_sequence, can_reenter_after_kickback)
SELECT
    dv.deal_type_variant_id,
    g.gate_key,
    g.gate_order,
    TRUE
FROM config.deal_type_variant dv
JOIN config.gate_catalog g
  ON g.gate_key IN ('G1', 'G2', 'G3')
ON CONFLICT (deal_type_variant_id, gate_key) DO UPDATE
SET gate_sequence = EXCLUDED.gate_sequence,
    can_reenter_after_kickback = EXCLUDED.can_reenter_after_kickback;

INSERT INTO config.doc_category (doc_category_key, display_name)
VALUES
    ('CONTRACT', 'Contract Document'),
    ('FICA', 'FICA Document'),
    ('CHECKLIST', 'Checklist Support')
ON CONFLICT (doc_category_key) DO UPDATE
SET display_name = EXCLUDED.display_name;

INSERT INTO config.doc_checklist_item (
    doc_type_key,
    doc_category_id,
    display_name,
    must_be_signed,
    checksum_required
)
SELECT DISTINCT
    dcti.checklist_item_key,
    dc.doc_category_id,
    INITCAP(REPLACE(dcti.checklist_item_key, '_', ' ')) AS display_name,
    CASE WHEN dcti.checklist_item_key IN ('DEALSHEET_SIGNED', 'OTP_OR_LEASE') THEN TRUE ELSE FALSE END,
    FALSE
FROM config.doc_checklist_template_item dcti
JOIN config.doc_category dc
  ON dc.doc_category_key = CASE
      WHEN dcti.checklist_item_key ILIKE '%FICA%' THEN 'FICA'
      ELSE 'CONTRACT'
  END
ON CONFLICT (doc_type_key) DO UPDATE
SET doc_category_id = EXCLUDED.doc_category_id,
    display_name = EXCLUDED.display_name,
    must_be_signed = EXCLUDED.must_be_signed,
    checksum_required = EXCLUDED.checksum_required;

INSERT INTO config.deal_type_doc_checklist_rule (
    deal_type_variant_id,
    doc_checklist_item_id,
    gate_key,
    is_required
)
SELECT
    dv.deal_type_variant_id,
    dci.doc_checklist_item_id,
    COALESCE(dcti.gate_key, 'G1') AS gate_key,
    dcti.is_required
FROM config.doc_checklist_template dct
JOIN config.doc_checklist_template_item dcti
  ON dcti.doc_checklist_template_id = dct.doc_checklist_template_id
JOIN config.deal_type_variant dv
  ON dv.variant_key = dct.deal_subtype_key
JOIN config.doc_checklist_item dci
  ON dci.doc_type_key = dcti.checklist_item_key
ON CONFLICT (deal_type_variant_id, doc_checklist_item_id, gate_key) DO UPDATE
SET is_required = EXCLUDED.is_required;

INSERT INTO config.approval_role (approval_role_key, display_name)
SELECT
    rc.role_key,
    rc.role_name
FROM config.role_catalog rc
ON CONFLICT (approval_role_key) DO UPDATE
SET display_name = EXCLUDED.display_name;

INSERT INTO config.deal_type_approval_matrix (
    deal_type_variant_id,
    gate_key,
    approval_role_id,
    approval_rule_id,
    rule_order
)
SELECT
    dv.deal_type_variant_id,
    ar.gate_key,
    apr.approval_role_id,
    ar.approval_rule_id,
    ar.rule_priority
FROM config.deal_type_variant dv
JOIN config.approval_rule ar
  ON ar.gate_key IN ('G1', 'G2', 'G3')
JOIN config.approval_role apr
  ON apr.approval_role_key = ar.required_role_key
ON CONFLICT (deal_type_variant_id, gate_key, approval_role_id, rule_order) DO UPDATE
SET approval_rule_id = EXCLUDED.approval_rule_id;

INSERT INTO config.org_unit (org_unit_key, parent_org_unit_id, display_name)
VALUES ('HQ', NULL, 'Head Office')
ON CONFLICT (org_unit_key) DO UPDATE
SET display_name = EXCLUDED.display_name;

INSERT INTO config.org_unit (org_unit_key, parent_org_unit_id, display_name)
SELECT DISTINCT
    bdm.division_key,
    hq.org_unit_id,
    bdm.division_key
FROM security.broker_division_map bdm
JOIN config.org_unit hq
  ON hq.org_unit_key = 'HQ'
WHERE bdm.division_key IS NOT NULL
ON CONFLICT (org_unit_key) DO UPDATE
SET parent_org_unit_id = EXCLUDED.parent_org_unit_id,
    display_name = EXCLUDED.display_name;

INSERT INTO config.org_position (position_key, display_name)
VALUES
    ('OPS', 'Operations'),
    ('FINANCE', 'Finance'),
    ('BROKER', 'Broker'),
    ('DIVISION_HEAD', 'Division Head'),
    ('SYSTEM', 'System Integration')
ON CONFLICT (position_key) DO UPDATE
SET display_name = EXCLUDED.display_name;

INSERT INTO config.role_permission (role_key, permission_key)
SELECT role_key, permission_key
FROM (
    VALUES
        ('OPS', 'DRAFT_EDIT'),
        ('OPS', 'DRAFT_SUBMIT'),
        ('OPS', 'TRACKER_READ'),
        ('OPS', 'TASK_READ'),
        ('FIN_APPROVER', 'GATE_DECIDE'),
        ('FIN_APPROVER', 'TRACKER_READ'),
        ('FIN_APPROVER', 'FINANCE_SUMMARY_READ'),
        ('FIN_APPROVER', 'PAYLOAD_READ'),
        ('BROKER', 'TASK_READ'),
        ('DIVISION_HEAD', 'GATE_DECIDE'),
        ('DIVISION_HEAD', 'TASK_READ')
) AS p(role_key, permission_key)
WHERE EXISTS (
    SELECT 1
    FROM config.role_catalog rc
    WHERE rc.role_key = p.role_key
)
ON CONFLICT (role_key, permission_key) DO NOTHING;

INSERT INTO config.signwell_field_map (
    signwell_template_id,
    field_key,
    signwell_field_key,
    field_type,
    is_required,
    format_rule
)
SELECT
    st.signwell_template_id,
    sfd.signwell_field_key,
    sfd.signwell_field_key,
    COALESCE(NULLIF(sfd.field_type, ''), 'TEXT'),
    sfd.is_required,
    NULL::TEXT
FROM config.signwell_template st
JOIN config.signwell_field_dictionary sfd
  ON TRUE
WHERE st.is_active = TRUE
ON CONFLICT (signwell_template_id, signwell_field_key) DO UPDATE
SET field_key = EXCLUDED.field_key,
    field_type = EXCLUDED.field_type,
    is_required = EXCLUDED.is_required,
    format_rule = EXCLUDED.format_rule;

INSERT INTO config.webhook_source (source_key, dedupe_key_field, replay_is_safe)
VALUES
    ('SIGNWELL', 'event_id', TRUE),
    ('XERO', 'event_id', TRUE)
ON CONFLICT (source_key) DO UPDATE
SET dedupe_key_field = EXCLUDED.dedupe_key_field,
    replay_is_safe = EXCLUDED.replay_is_safe;

INSERT INTO config.validation_rule (rule_code, severity, message_template, field_key)
VALUES
    ('LEAD_BROKER_REQUIRED', 'ERROR', 'A lead broker is required to submit.', 'deal_business_key'),
    ('REQUIRED_DOCS_MISSING', 'ERROR', 'Required documents are missing or unconfirmed.', 'deal_subtype_key'),
    ('ECONOMICS_REQUIRED', 'ERROR', 'Economics are required to submit.', 'gross_billings'),
    ('ECON_COMMISSION_INVALID', 'ERROR', 'Commission total must be >= 0 and <= gross billings.', 'commission_total'),
    ('ECON_SPLIT_INVALID', 'ERROR', 'Company and broker split percentages must sum to 100.', 'broker_split_pct')
ON CONFLICT (rule_code) DO UPDATE
SET severity = EXCLUDED.severity,
    message_template = EXCLUDED.message_template,
    field_key = EXCLUDED.field_key;

INSERT INTO config.environment_setting (setting_key, setting_value)
VALUES
    ('default_timezone', 'Africa/Johannesburg'),
    ('signwell_provider_key', 'SIGNWELL'),
    ('phase', 'phase_1')
ON CONFLICT (setting_key) DO UPDATE
SET setting_value = EXCLUDED.setting_value,
    updated_at = NOW();

INSERT INTO config.audit_event_type (event_type, event_description)
VALUES
    ('PROMOTED_TO_CORE', 'Draft promoted to immutable core snapshot'),
    ('G1_ENTERED', 'Deal entered Gate 1'),
    ('G2_ENTERED', 'Deal entered Gate 2'),
    ('G3_ENTERED', 'Deal entered Gate 3'),
    ('GATE_REJECTED', 'Gate decision rejected or change requested'),
    ('SIGNWELL_ENVELOPE_RECORDED', 'Signwell envelope linked to deal version'),
    ('WEBHOOK_INGESTED', 'Webhook event ingested and processed'),
    ('XERO_PAYLOAD_LOCKED', 'Xero payload readiness locked')
ON CONFLICT (event_type) DO UPDATE
SET event_description = EXCLUDED.event_description;

-- ---------------------------------------------------------------------------
-- Compatibility backfill for new core compatibility tables
-- ---------------------------------------------------------------------------

INSERT INTO core.deal_version_property (deal_version_id, property_key, property_value)
SELECT
    dv.deal_version_id,
    'deal_subtype_key',
    to_jsonb(dv.deal_subtype_key)
FROM core.deal_version dv
ON CONFLICT (deal_version_id, property_key) DO UPDATE
SET property_value = EXCLUDED.property_value;

INSERT INTO core.deal_version_property (deal_version_id, property_key, property_value)
SELECT
    dv.deal_version_id,
    'lifecycle_status',
    to_jsonb(dv.lifecycle_status)
FROM core.deal_version dv
ON CONFLICT (deal_version_id, property_key) DO UPDATE
SET property_value = EXCLUDED.property_value;

INSERT INTO core.deal_version_document (
    deal_version_id,
    doc_type_key,
    doc_category_key,
    artifact_reference,
    checksum_sha256,
    uploaded_at
)
SELECT
    sda.deal_version_id,
    sda.artifact_type,
    'SIGNWELL',
    sda.artifact_reference,
    sda.checksum_sha256,
    sda.created_at
FROM core.signwell_document_artifact sda
ON CONFLICT DO NOTHING;

COMMIT;
