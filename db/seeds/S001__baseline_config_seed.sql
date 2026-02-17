BEGIN;

-- ---------------------------------------------------------------------------
-- Gate catalogue
-- ---------------------------------------------------------------------------
INSERT INTO config.gate_catalog (gate_key, gate_order, gate_name)
VALUES
    ('G0', 0, 'Draft'),
    ('G1', 1, 'Finance Review'),
    ('G2', 2, 'Signwell Approvals'),
    ('G3', 3, 'Xero Payload Ready'),
    ('G4', 4, 'Reserved'),
    ('G5', 5, 'Reserved')
ON CONFLICT (gate_key) DO UPDATE
SET gate_order = EXCLUDED.gate_order,
    gate_name = EXCLUDED.gate_name;

-- ---------------------------------------------------------------------------
-- Role + reason catalogues
-- ---------------------------------------------------------------------------
INSERT INTO config.role_catalog (role_key, role_name, role_type)
VALUES
    ('OPS_USER', 'Ops User', 'APPLICATION'),
    ('FIN_APPROVER', 'Finance Approver', 'APPROVAL'),
    ('BROKER', 'Broker', 'PARTICIPANT'),
    ('DIVISION_HEAD', 'Divisional Head', 'APPROVAL'),
    ('SYSTEM', 'System User', 'SYSTEM')
ON CONFLICT (role_key) DO UPDATE
SET role_name = EXCLUDED.role_name,
    role_type = EXCLUDED.role_type;

INSERT INTO config.reason_code (reason_code, reason_category, reason_description)
VALUES
    ('MISSING_DOC', 'VALIDATION', 'A required document is missing.'),
    ('MISSING_LEAD_BROKER', 'VALIDATION', 'Lead broker assignment is missing.'),
    ('FINANCE_REJECTED', 'APPROVAL', 'Finance rejected the submission.'),
    ('G2_DECLINED', 'APPROVAL', 'Signwell recipient declined at Gate 2.')
ON CONFLICT (reason_code) DO UPDATE
SET reason_category = EXCLUDED.reason_category,
    reason_description = EXCLUDED.reason_description;

-- ---------------------------------------------------------------------------
-- Approval rules (baseline for G1/G2/G3)
-- ---------------------------------------------------------------------------
INSERT INTO config.approval_rule_set (rule_set_key, rule_set_name)
VALUES
    ('DEFAULT_GATES_0_3', 'Default Rules for Gates 0 to 3')
ON CONFLICT (rule_set_key) DO UPDATE
SET rule_set_name = EXCLUDED.rule_set_name;

WITH target_rule_set AS (
    SELECT approval_rule_set_id
    FROM config.approval_rule_set
    WHERE rule_set_key = 'DEFAULT_GATES_0_3'
),
rule_data(gate_key, required_role_key, rule_expression, rule_priority) AS (
    VALUES
        ('G1', 'FIN_APPROVER', '{"mode":"ANY","role":"FIN_APPROVER"}', 10),
        ('G2', 'BROKER', '{"mode":"ALL","role":"BROKER"}', 20),
        ('G2', 'DIVISION_HEAD', '{"mode":"ANY","selector":"LEAD_BROKER_DIVISION_HEAD"}', 30),
        ('G3', 'FIN_APPROVER', '{"mode":"ANY","role":"FIN_APPROVER"}', 10)
)
INSERT INTO config.approval_rule (
    approval_rule_set_id,
    gate_key,
    required_role_key,
    rule_expression,
    rule_priority
)
SELECT
    trs.approval_rule_set_id,
    rd.gate_key,
    rd.required_role_key,
    rd.rule_expression,
    rd.rule_priority
FROM target_rule_set trs
JOIN rule_data rd ON TRUE
WHERE NOT EXISTS (
    SELECT 1
    FROM config.approval_rule ar
    WHERE ar.approval_rule_set_id = trs.approval_rule_set_id
      AND ar.gate_key = rd.gate_key
      AND ar.required_role_key = rd.required_role_key
      AND ar.rule_priority = rd.rule_priority
);

-- ---------------------------------------------------------------------------
-- Versioning placeholders
-- ---------------------------------------------------------------------------
INSERT INTO config.versioning_rule_set (rule_set_key, rule_set_name)
VALUES
    ('DEFAULT_VERSIONING', 'Default Versioning Rules')
ON CONFLICT (rule_set_key) DO UPDATE
SET rule_set_name = EXCLUDED.rule_set_name;

WITH vrs AS (
    SELECT versioning_rule_set_id
    FROM config.versioning_rule_set
    WHERE rule_set_key = 'DEFAULT_VERSIONING'
)
INSERT INTO config.versioning_rule (versioning_rule_set_id, rule_key, rule_expression)
SELECT vrs.versioning_rule_set_id, seed.rule_key, seed.rule_expression
FROM vrs
JOIN (
    VALUES
        ('MAJOR_ON_SUBTYPE_CHANGE', '{"event":"DEAL_SUBTYPE_CHANGED","new_version":"MAJOR"}'),
        ('MINOR_ON_NON_CRITICAL_CHANGE', '{"event":"NON_CRITICAL_FIELD_CHANGED","new_version":"MINOR"}')
) AS seed(rule_key, rule_expression) ON TRUE
WHERE NOT EXISTS (
    SELECT 1
    FROM config.versioning_rule vr
    WHERE vr.versioning_rule_set_id = vrs.versioning_rule_set_id
      AND vr.rule_key = seed.rule_key
);

-- ---------------------------------------------------------------------------
-- Document checklist templates
-- ---------------------------------------------------------------------------
INSERT INTO config.doc_checklist_template (template_key, deal_subtype_key, template_name)
VALUES
    ('TPL_LEASE_RENEWAL', 'LEASE_ACQUISITION_OR_RENEWAL', 'Lease Acquisition or Renewal Checklist'),
    ('TPL_REGEAR_INVOICE', 'REGEAR_OR_CLIENT_INVOICE', 'Regear or Client Invoice Checklist'),
    ('TPL_SALE_AUCTION', 'SALE_AUCTION', 'Sale (Auction) Checklist'),
    ('TPL_SALE_PVT_SEALED', 'SALE_PVT_TREATY_SEALED_BID', 'Sale (Private Treaty / Sealed Bid) Checklist')
ON CONFLICT (template_key) DO UPDATE
SET deal_subtype_key = EXCLUDED.deal_subtype_key,
    template_name = EXCLUDED.template_name;

WITH template_items(template_key, checklist_item_key, checklist_item_name, gate_key, is_required) AS (
    VALUES
        ('TPL_LEASE_RENEWAL', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
        ('TPL_LEASE_RENEWAL', 'OTP_OR_LEASE', 'OTP or Lease Document', 'G1', TRUE),
        ('TPL_LEASE_RENEWAL', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE),
        ('TPL_REGEAR_INVOICE', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
        ('TPL_REGEAR_INVOICE', 'INVOICE_PACK', 'Invoice Supporting Pack', 'G1', TRUE),
        ('TPL_REGEAR_INVOICE', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE),
        ('TPL_SALE_AUCTION', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
        ('TPL_SALE_AUCTION', 'MANDATE', 'Signed Mandate', 'G1', TRUE),
        ('TPL_SALE_AUCTION', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE),
        ('TPL_SALE_PVT_SEALED', 'DEALSHEET_SIGNED', 'Dealsheet Signed', 'G1', TRUE),
        ('TPL_SALE_PVT_SEALED', 'MANDATE', 'Signed Mandate', 'G1', TRUE),
        ('TPL_SALE_PVT_SEALED', 'FICA_COMPLETE', 'FICA Complete', 'G1', FALSE)
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
    '{"requires_when_any":["IS_JSE_LISTED=true","PARTY_REQUIRES_FICA=true"]}'
FROM fica_items fi
WHERE NOT EXISTS (
    SELECT 1
    FROM config.doc_checklist_conditional_rule c
    WHERE c.doc_checklist_template_item_id = fi.doc_checklist_template_item_id
      AND c.condition_key = 'REQUIRES_FICA_OR_JSE'
);

-- ---------------------------------------------------------------------------
-- Signwell config placeholders (minimum G2 coverage)
-- ---------------------------------------------------------------------------
WITH signwell_seed(gate_key, deal_subtype_key, template_external_id) AS (
    VALUES
        ('G2', 'LEASE_ACQUISITION_OR_RENEWAL', 'signwell_tpl_g2_lease'),
        ('G2', 'REGEAR_OR_CLIENT_INVOICE', 'signwell_tpl_g2_regear'),
        ('G2', 'SALE_AUCTION', 'signwell_tpl_g2_sale_auction'),
        ('G2', 'SALE_PVT_TREATY_SEALED_BID', 'signwell_tpl_g2_sale_private')
)
INSERT INTO config.signwell_template (
    gate_key,
    deal_subtype_key,
    template_external_id,
    template_version
)
SELECT
    ss.gate_key,
    ss.deal_subtype_key,
    ss.template_external_id,
    'v1'
FROM signwell_seed ss
ON CONFLICT (gate_key, deal_subtype_key, template_version) DO UPDATE
SET template_external_id = EXCLUDED.template_external_id;

INSERT INTO config.signwell_field_dictionary (
    signwell_field_key,
    field_type,
    is_required,
    field_description
)
VALUES
    ('deal_business_key', 'TEXT', TRUE, 'Stable external deal key'),
    ('deal_subtype_key', 'TEXT', TRUE, 'Deal subtype identifier'),
    ('gross_billings', 'NUMERIC', TRUE, 'Gross billings amount'),
    ('commission_total', 'NUMERIC', TRUE, 'Total commission amount'),
    ('lead_broker_email', 'EMAIL', TRUE, 'Lead broker recipient email'),
    ('division_head_email', 'EMAIL', TRUE, 'Division head recipient email')
ON CONFLICT (signwell_field_key) DO UPDATE
SET field_type = EXCLUDED.field_type,
    is_required = EXCLUDED.is_required,
    field_description = EXCLUDED.field_description;

INSERT INTO config.signwell_recipient_role_map (
    gate_key,
    role_key,
    recipient_order,
    recipient_selector
)
VALUES
    ('G2', 'BROKER', 1, 'ALL_BROKERS'),
    ('G2', 'DIVISION_HEAD', 2, 'LEAD_BROKER_DIVISION_HEAD')
ON CONFLICT (gate_key, role_key) DO UPDATE
SET recipient_order = EXCLUDED.recipient_order,
    recipient_selector = EXCLUDED.recipient_selector;

COMMIT;
