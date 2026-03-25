BEGIN;

-- =========================================================================
-- S004 — Workbook Bootstrap: Dealflow System Setup Workbook v0.1
--
-- Loads all operational data from the workbook into existing tables.
-- All inserts use ON CONFLICT / WHERE NOT EXISTS for idempotency.
-- Tables were created by V001-V009; this file only populates data.
--
-- LOAD ORDER (respects FK dependencies):
--   1. Role Catalog        (config.role_catalog)
--   2. Role Instances       (config.role_instance)
--   3. Identities           (security.identity)
--   4. Role Assignments     (security.role_assignment)
--   5. Deal Type Variants   (config.deal_type_variant)  — UPDATE existing
--   6. Commission Rules     (config.commission_rule)
--   7. Document Checklist   (config.doc_checklist_template_item)
--   8. Signwell Templates   (config.signwell_template)
-- =========================================================================

-- =========================================================================
-- SECTION 1 — Role Catalog (Sheet 02)
-- =========================================================================

INSERT INTO config.role_catalog (role_key, role_name, role_type, role_scope)
VALUES
    ('DEAL_MAKER',     'Broker',           'PARTICIPANT', 'Deal initiation'),
    ('OPS_MANAGER',    'Operations',       'APPLICATION', 'Draft creation, validation and submission'),
    ('FIN_APPROVER',   'Finance',          'APPROVAL',    'Finance approval'),
    ('DIV_APPROVER',   'Divisional Head',  'APPROVAL',    'Divisional approval'),
    ('EXEC_APPROVER',  'Executive Approver', 'APPROVAL',  'Executive approval'),
    ('SYS_ADMIN',      'System Admin',     'SYSTEM',      'System Administration'),
    ('SYS_AUTOMATION', 'System Automation', 'SYSTEM',     'system and workflows'),
    ('READ_ONLY',      'Read Only',        'SYSTEM',      'Audit / reporting')
ON CONFLICT (role_key) DO UPDATE
SET role_name  = EXCLUDED.role_name,
    role_type  = EXCLUDED.role_type,
    role_scope = EXCLUDED.role_scope;

-- =========================================================================
-- SECTION 2 — Role Instances (Sheet 03)
-- =========================================================================

-- Finance must be inserted first (referenced by escalates_to)
INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_active, effective_from)
VALUES
    ('60000_Finance_Manager', 'FIN_APPROVER', 'Finance_Manager', 'Finance', 'Finance', 'SA', 'EC', 'National', NULL, TRUE, '2026-03-01')
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- Executive instances (CFO escalates to Finance_Manager, others to CFO)
INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_active, effective_from)
VALUES
    ('50003_CFO', 'EXEC_APPROVER', 'CFO', 'Executive', 'Executive', 'SA', 'EC', 'National', '60000_Finance_Manager', TRUE, '2026-03-01'),
    ('50001_CEO', 'EXEC_APPROVER', 'CEO', 'Executive', 'Executive', 'SA', 'EC', 'National', '50003_CFO',             TRUE, '2026-03-01'),
    ('50002_COO', 'EXEC_APPROVER', 'COO', 'Executive', 'Executive', 'SA', 'EC', 'National', '50003_CFO',             TRUE, '2026-03-01')
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- Update Finance_Manager escalation now that CFO exists
UPDATE config.role_instance
SET escalates_to_role_instance_id = '50003_CFO'
WHERE role_instance_id = '60000_Finance_Manager';

-- ---- Broking Division ----

INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_active, effective_from)
VALUES
    -- Divisional Approvers
    ('10001_Managing_Director_JHB_Broking', 'DIV_APPROVER', 'Managing_Director_JHB_Broking', 'Broking', 'JHB Broking', 'SA', 'JHB', 'National', '60000_Finance_Manager', TRUE, '2026-03-01'),
    ('10002_Managing_Director_WC_Broking',  'DIV_APPROVER', 'Managing_Director_WC_Broking',  'Broking', 'WC Broking',  'SA', 'WC',  'National', '60000_Finance_Manager', TRUE, '2026-03-01'),
    ('10003_Division_Head_WC_Broking',      'DIV_APPROVER', 'Division_Head_WC_Broking',      'Broking', 'WC Broking',  'SA', 'WC',  'National', '60000_Finance_Manager', TRUE, '2026-03-01'),

    -- Ops Managers
    ('10101_Operations_JHB_Broking', 'OPS_MANAGER', 'Operations_JHB_Broking', 'Broking', 'JHB Broking', 'SA', 'JHB', 'National', '10001_Managing_Director_JHB_Broking', TRUE, '2026-03-01'),
    ('10102_Operations_WC_Broking',  'OPS_MANAGER', 'Operations_WC_Broking',  'Broking', 'WC Broking',  'SA', 'WC',  'National', '10003_Division_Head_WC_Broking',      TRUE, '2026-03-01'),
    ('10103_Operations_WC_Broking',  'OPS_MANAGER', 'Operations_WC_Broking',  'Broking', 'WC Broking',  'SA', 'WC',  'National', '10003_Division_Head_WC_Broking',      TRUE, '2026-03-01'),
    ('10104_Operations_WC_Broking',  'OPS_MANAGER', 'Operations_WC_Broking',  'Broking', 'WC Broking',  'SA', 'WC',  'National', '10003_Division_Head_WC_Broking',      TRUE, '2026-03-01')
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- JHB Broking Deal Makers (25 slots: 11001-11025)
INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_broker_role, is_active, effective_from)
SELECT
    lpad(n::TEXT, 5, '0') || '_Deal_Maker_JHB_Broking',
    'DEAL_MAKER',
    'Deal_Maker_JHB_Broking',
    'Broking',
    'JHB Broking',
    'SA',
    'JHB',
    'National',
    '10101_Operations_JHB_Broking',
    TRUE,
    TRUE,
    DATE '2026-03-01'
FROM generate_series(11001, 11025) AS n
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_broker_role                = EXCLUDED.is_broker_role,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- WC Broking Deal Makers (11 slots: 11026-11036)
INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_broker_role, is_active, effective_from)
SELECT
    lpad(n::TEXT, 5, '0') || '_Deal_Maker_WC_Broking',
    'DEAL_MAKER',
    'Deal_Maker_WC_Broking',
    'Broking',
    'WC Broking',
    'SA',
    'WC',
    'National',
    '10102_Operations_WC_Broking',
    TRUE,
    TRUE,
    DATE '2026-03-01'
FROM generate_series(11026, 11036) AS n
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_broker_role                = EXCLUDED.is_broker_role,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- ---- Auction Division ----

INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_active, effective_from)
VALUES
    -- Divisional Approvers
    ('20001_Managing_Director_JHB_Auction',     'DIV_APPROVER', 'Managing_Director_JHB_Auction',     'Auction', 'JHB Auction',         'SA', 'JHB', 'National', '60000_Finance_Manager', TRUE, '2026-03-01'),
    ('20002_Managing_Director_Coastal_Auction',  'DIV_APPROVER', 'Managing_Director_Coastal_Auction', 'Auction', 'EC KZN WC Auction',   'SA', 'EC',  'National', '60000_Finance_Manager', TRUE, '2026-03-01'),

    -- Ops Managers
    ('20101_Operations_JHB_Auction', 'OPS_MANAGER', 'Operations_JHB_Auction', 'Auction', 'JHB Auction', 'SA', 'JHB', 'National', '20001_Managing_Director_JHB_Auction', TRUE, '2026-03-01'),
    ('20102_Operations_JHB_Auction', 'OPS_MANAGER', 'Operations_JHB_Auction', 'Auction', 'JHB Auction', 'SA', 'JHB', 'National', '20001_Managing_Director_JHB_Auction', TRUE, '2026-03-01'),
    ('20103_Operations_JHB_Auction', 'OPS_MANAGER', 'Operations_JHB_Auction', 'Auction', 'JHB Auction', 'SA', 'JHB', 'National', '20001_Managing_Director_JHB_Auction', TRUE, '2026-03-01')
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- JHB Auction Deal Makers (16 slots: 21001-21016)
INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_broker_role, is_active, effective_from)
SELECT
    lpad(n::TEXT, 5, '0') || '_Deal_Maker_JHB_Auction',
    'DEAL_MAKER',
    'Deal_Maker_JHB_Auction',
    'Auction',
    'JHB Auction',
    'SA',
    'JHB',
    'National',
    '20101_Operations_JHB_Auction',
    TRUE,
    TRUE,
    DATE '2026-03-01'
FROM generate_series(21001, 21016) AS n
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_broker_role                = EXCLUDED.is_broker_role,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- WC Auction Deal Makers (17 slots: 21017-21033)
-- No WC Auction OPS_MANAGER defined; escalates_to set to NULL
INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_broker_role, is_active, effective_from)
SELECT
    lpad(n::TEXT, 5, '0') || '_Deal_Maker_WC_Auction',
    'DEAL_MAKER',
    'Deal_Maker_WC_Auction',
    'Auction',
    'WC Auction',
    'SA',
    'WC',
    'National',
    NULL,
    TRUE,
    TRUE,
    DATE '2026-03-01'
FROM generate_series(21017, 21033) AS n
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_broker_role                = EXCLUDED.is_broker_role,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- KZN Auction Deal Makers (7 slots: 21034-21040)
-- No KZN Auction OPS_MANAGER defined; escalates_to set to NULL
INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_broker_role, is_active, effective_from)
SELECT
    lpad(n::TEXT, 5, '0') || '_Deal_Maker_KZN_Auction',
    'DEAL_MAKER',
    'Deal_Maker_KZN_Auction',
    'Auction',
    'KZN Auction',
    'SA',
    'KZN',
    'National',
    NULL,
    TRUE,
    TRUE,
    DATE '2026-03-01'
FROM generate_series(21034, 21040) AS n
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_broker_role                = EXCLUDED.is_broker_role,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- EC Auction Deal Makers (2 slots: 21041-21042)
-- No EC Auction OPS_MANAGER defined; escalates_to set to NULL
INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_broker_role, is_active, effective_from)
SELECT
    lpad(n::TEXT, 5, '0') || '_Deal_Maker_EC_Auction',
    'DEAL_MAKER',
    'Deal_Maker_EC_Auction',
    'Auction',
    'EC Auction',
    'SA',
    'EC',
    'National',
    NULL,
    TRUE,
    TRUE,
    DATE '2026-03-01'
FROM generate_series(21041, 21042) AS n
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_broker_role                = EXCLUDED.is_broker_role,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- ---- GCS Division ----

INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_active, effective_from)
VALUES
    ('30001_Managing_Director_GCS', 'DIV_APPROVER', 'Managing_Director_GCS', 'GCS', 'GCS', 'SA', 'EC', 'National', '60000_Finance_Manager', TRUE, '2026-03-01'),

    ('30101_Operations_GCS', 'OPS_MANAGER', 'Operations_GCS', 'GCS', 'GCS', 'SA', 'EC', 'National', '30001_Managing_Director_GCS', TRUE, '2026-03-01'),
    ('30102_Operations_GCS', 'OPS_MANAGER', 'Operations_GCS', 'GCS', 'GCS', 'SA', 'EC', 'National', '30001_Managing_Director_GCS', TRUE, '2026-03-01'),
    ('30103_Operations_GCS', 'OPS_MANAGER', 'Operations_GCS', 'GCS', 'GCS', 'SA', 'EC', 'National', '30001_Managing_Director_GCS', TRUE, '2026-03-01')
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- GCS Deal Makers (8 slots: 31001-31008)
INSERT INTO config.role_instance (role_instance_id, role_key, instance_name, division_key, org_unit_key, country, region, area, escalates_to_role_instance_id, is_broker_role, is_active, effective_from)
SELECT
    lpad(n::TEXT, 5, '0') || '_Deal_Maker_GCS',
    'DEAL_MAKER',
    'Deal_Maker_GCS',
    'GCS',
    'GCS',
    'SA',
    'EC',
    'National',
    '30101_Operations_GCS',
    TRUE,
    TRUE,
    DATE '2026-03-01'
FROM generate_series(31001, 31008) AS n
ON CONFLICT (role_instance_id) DO UPDATE
SET role_key                      = EXCLUDED.role_key,
    instance_name                 = EXCLUDED.instance_name,
    division_key                  = EXCLUDED.division_key,
    org_unit_key                  = EXCLUDED.org_unit_key,
    country                       = EXCLUDED.country,
    region                        = EXCLUDED.region,
    area                          = EXCLUDED.area,
    escalates_to_role_instance_id = EXCLUDED.escalates_to_role_instance_id,
    is_broker_role                = EXCLUDED.is_broker_role,
    is_active                     = EXCLUDED.is_active,
    effective_from                = EXCLUDED.effective_from;

-- =========================================================================
-- SECTION 3 — Identities (Sheet 04)
-- =========================================================================

INSERT INTO security.identity (email, display_name, is_active, default_org_unit_key, default_division_key, identity_type, effective_from)
VALUES
    ('reyaan.abarder@galetti.co.za',         'Abarder, Reyaan',                          TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('donovan.akom@galetti.co.za',           'Akom, Donovan Vincent',                    TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('jake.archibald@galetti.co.za',         'Archibald, Jake Sheldon',                  TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('david.arton-powell@galetti.co.za',     'Arton-Powell, David John',                 TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('lester.atkinson@galetti.co.za',        'Atkinson, Lester Brian',                   TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('bhavesh.bansda@galetti.co.za',         'Bansda, Bhavesh',                          TRUE, 'EC Auction',          'Auction',     'USER', '2026-03-01'),
    ('georgia.barbaglia@galetti.co.za',      'Barbaglia, Georgia Vincenza',              TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('kenrick.begemann@galetti.co.za',       'Begemann, Kenrick',                        TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('divan.binneman@galetti.co.za',         'Binneman, Divan Johannes',                 TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('sylvester.black@galetti.co.za',        'Black, Sylvester Apollo',                  TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('francois.botha@galetti.co.za',         'Botha, Francois Gerrit',                   TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('leandri.botha@galetti.co.za',          'Botha, Leandri',                           TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('storme.burger@galetti.co.za',          'Burger, Storme Alexander Ashley',          TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('ryan.burgess@galetti.co.za',           'Burgess, Ryan David',                      TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('jose.cabeleira@galetti.co.za',         'Cabaleira, Jose Miguel',                   TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('tracy.campbell@galetti.co.za',         'Campbell, Tracy Lea',                      TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('siraaj.cassim@galetti.co.za',          'Cassim, Siraaj Ahmad',                     TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('kyle.castelyn@galetti.co.za',          'Castelyn, Kyle',                           TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('muhammed.gamo@galetti.co.za',          'Castineira Gamo, Muhammed Amin',           TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('antoinette.chait@galetti.co.za',       'Chait, Antoinette',                        TRUE, 'Executive',           'Executive',   'USER', '2026-03-01'),
    ('muhammad.chothia@galetti.co.za',       'Chothia, Muhammad',                        TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('scotty.corlett@galetti.co.za',         'Corlett, Scott Kirk',                      TRUE, 'KZN Auction',         'Auction',     'USER', '2026-03-01'),
    ('wesley.cowan@galetti.co.za',           'Cowan, Wesley Anthony',                    TRUE, 'EC KZN WC Auction',   'Auction',     'USER', '2026-03-01'),
    ('david.dawson@galetti.co.za',           'Dawson, David Christopher Morton',         TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('patrick.dewet@galetti.co.za',          'de Wet, Patrick Anthony',                  TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('guy.dowding@galetti.co.za',            'Dowding, Guy John',                        TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('kgomotso.dube@galetti.co.za',          'Dube, Kgomotso',                           TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('igenda.ejekwu@galetti.co.za',          'Ejekwu, Igenda',                           TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('regardt.engelbrecht@galetti.co.za',    'Engelbrecht, Regardt Johann',              TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('tyra.ford@galetti.co.za',              'Ford- Hoon, Tyra',                         TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('gabriella.frankel@galetti.co.za',      'Frankel, Gabriella',                       TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('alison.gerber@galetti.co.za',          'Gerber, Alison',                           TRUE, 'Executive',           'Executive',   'USER', '2026-03-01'),
    ('ricardo.dasilva@galetti.co.za',        'Gomes Da Silva, Ricardo Caseiro',          TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('clinton.govender@galetti.co.za',       'Govender, Clinton',                        TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('pav.govender@galetti.co.za',           'Govender, Paveshan',                       TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('sakhi.gqeba@galetti.co.za',            'Gqeba, Sakekile Nicholas',                 TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('Jessica.green@galetti.co.za',          'Green, Jessica Imogen',                    TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('jordan.grobbelaar@galetti.co.za',      'Grobbelaar, Jordan Daniel',                TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('anton.groeneveldt@galetti.co.za',      'Groeneveldt, Anton Louis Wulf',            TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('nadine.guedes@galetti.co.za',          'Guedes, Nadine Evelyn Haupt',              TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('asanda.gwamanda@galetti.co.za',        'Gwamanda, Asanda',                         TRUE, 'KZN Auction',         'Auction',     'USER', '2026-03-01'),
    ('claydon.hamilton@galetti.co.za',       'Hamilton, Claydon Arthur James',            TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('rochelle.holland@galetti.co.za',       'Holland, Rochelle',                        TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('cameron.hudson@galetti.co.za',         'Hudson, Cameron',                          TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('chris.humphries@galetti.co.za',        'Humphries, Christopher George',            TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('kyle.hyam@galetti.co.za',              'Hyam, Kyle Terry Robert',                  TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('itai.ilouze@galetti.co.za',            'Ilouze, Itai',                             TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('john.jack@galetti.co.za',              'Jack, Jonathan Craig',                     TRUE, 'Executive',           'Executive',   'USER', '2026-03-01'),
    ('bernice.jordaan@galetti.co.za',        'Jordaan, Bernice Mari',                    TRUE, 'Finance',             'Finance',     'USER', '2026-03-01'),
    ('dylan.kelly@galetti.co.za',            'Kelly, Dylan Trent',                       TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('Uwais.khan@galetti.co.za',             'Khan, Mohamed Uwais',                      TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('keke.khojane@galetti.co.za',           'Khojane, Kekeletso Eunice',                TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('tom.king@galetti.co.za',               'King, Thomas Peter',                       TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('paul.knoop@galetti.co.za',             'Knoop, Paul Robert',                       TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('tshepo.kubeka@galetti.co.za',          'Kubeka, Tshepo Kathide',                   TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('qaasim.lamara@galetti.co.za',          'Lamara, Mogammad Qaasim',                  TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('andrew.light@galetti.co.za',           'Light, Andrew George',                     TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('riaan.loggenberg@galetti.co.za',       'Loggenberg, Riaan Francois',               TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('lerato.makgetla@galetti.co.za',        'Makgetla, Lerato Tshepiso',                TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('clint.marais@galetti.co.za',           'Marais, Clinton Andrew',                   TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('kingsley.martell@galetti.co.za',       'Martell, Kingsley',                        TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('danyl.mathieson@galetti.co.za',        'Mathieson, Danyl Luke',                    TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('kopano.matlala@galetti.co.za',         'Matlala, Kopano',                          TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('vibeke.mccleland@galetti.co.za',       'McCleland, Vibeke Tyler',                  TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('james.mccormack@galetti.co.za',        'McCormack, James Michael',                 TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('greg.mcglashan@galetti.co.za',         'McGlashan, Greg Alexander',                TRUE, 'KZN Auction',         'Auction',     'USER', '2026-03-01'),
    ('camilla.messias@galetti.co.za',        'Messias Boltman, Camilla Sage',            TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('jenna.meyer@galetti.co.za',            'Meyer, Jenna',                             TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('ila.milambo@galetti.co.za',            'Milambo, Ila David',                       TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('joshua.mimbulu@galetti.co.za',         'Mimbulu, Joshua Yanse',                    TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('ross.minnaar@galetti.co.za',           'Minnaar, William Ross',                    TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('ian.moses@galetti.co.za',              'Moses, Ian Russel',                        TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('warren.moyle@galetti.co.za',           'Moyle, Warren Gordon',                     TRUE, 'KZN Auction',         'Auction',     'USER', '2026-03-01'),
    ('ramaano.mphigalale@galetti.co.za',     'Mphigalale, Matamela Ramaano',             TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('michelle.mringi@galetti.co.za',        'Mringi, Michelle Chitombo',                TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('chenai.mugunyani@galetti.co.za',       'Mugunyani, Chenai',                        TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('gareth.murray@galetti.co.za',          'Murray, Gareth Athol',                     TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('shaka.mvula@galetti.co.za',            'Mvula, Xolani',                            TRUE, 'EC Auction',          'Auction',     'USER', '2026-03-01'),
    ('kerryann.oelofse@galetti.co.za',       'Oelofse, Kerry-Ann',                       TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('sam.pearson@galetti.co.za',            'Pearson, Samuel',                          TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('derrick.pienaar@galetti.co.za',        'Pienaar, Derrick Robert',                  TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('dylan.pietersen@galetti.co.za',        'Pietersen, Dylan James',                   TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('karusha.pillay@galetti.co.za',         'Pillay, Karusha',                          TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('adriaan.rabie@galetti.co.za',          'Rabie, Adriaan Albertus',                  TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('kgomotso.radebe@galetti.co.za',        'Radebe, Kgomotso Ismael',                  TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('darrin.richardson@galetti.co.za',      'Richardson, Darrin Wade',                  TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('tiisetso.serudu@galetti.co.za',        'Serudu, Tiisetso',                         TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('kiran.singh@galetti.co.za',            'Singh, Kiran Yathin',                      TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('kyle.small@galetti.co.za',             'Small, Kyle Gary',                         TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('cameron.smith@galetti.co.za',          'Smith, Cameron McNamara',                  TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('dean.solomon@galetti.co.za',           'Solomon, Dean',                            TRUE, 'KZN Auction',         'Auction',     'USER', '2026-03-01'),
    ('francois@galetti.co.za',               'Staples, Francois David',                  TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('joshua.swanepoel@galetti.co.za',       'Swanepoel, Joshua Zane',                   TRUE, 'KZN Auction',         'Auction',     'USER', '2026-03-01'),
    ('zaahid.sydow@galetti.co.za',           'Sydow, Zaahid',                            TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('dian.theron@galetti.co.za',            'Theron, David Francois',                   TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('justin.thom@galetti.co.za',            'Thom, James Justin',                       TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('james.trenchard@galetti.co.za',        'Trenchard, James John',                    TRUE, 'JHB Broking',         'Broking',     'USER', '2026-03-01'),
    ('ivan.vandermerwe@galetti.co.za',       'van der Merwe, Ivan Friedrich',             TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('francois.vandermerwe@galetti.co.za',   'van der Merwe, Nicolaas Francois',          TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('shawn.vanjaarsveld@galetti.co.za',     'van Jaarsveld, Shawn Norman',              TRUE, 'WC Auction',          'Auction',     'USER', '2026-03-01'),
    ('darius.vanniekerk@galetti.co.za',      'van Niekerk, Darius Lodewicus',             TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('simon.wilkins@galetti.co.za',          'Wilkins, Simon William',                   TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01'),
    ('mark.wingerin@galetti.co.za',          'Wingerin, Mark',                           TRUE, 'WC Broking',          'Broking',     'USER', '2026-03-01'),
    ('christopher.young@galetti.co.za',      'Young, Christopher Murray',                TRUE, 'KZN Auction',         'Auction',     'USER', '2026-03-01'),
    ('kristylee.zeeman@galetti.co.za',       'Zeeman, Kristy-Lee Carol',                 TRUE, 'JHB Auction',         'Auction',     'USER', '2026-03-01'),
    ('elena.zwick@galetti.co.za',            'Zwick-Sedick, Elena',                      TRUE, 'GCS',                 'GCS',         'USER', '2026-03-01')
ON CONFLICT (email) DO UPDATE
SET display_name          = EXCLUDED.display_name,
    is_active             = EXCLUDED.is_active,
    default_org_unit_key  = EXCLUDED.default_org_unit_key,
    default_division_key  = EXCLUDED.default_division_key,
    identity_type         = EXCLUDED.identity_type,
    effective_from        = EXCLUDED.effective_from;

-- =========================================================================
-- SECTION 4 — Role Assignments (Sheet 05)
-- =========================================================================
-- Uses WHERE NOT EXISTS because the unique index is partial
-- (is_active = TRUE) and includes COALESCE, making ON CONFLICT awkward.

INSERT INTO security.role_assignment (
    identity_id, role_key, role_instance_id, employee_code,
    is_primary_assignment, effective_from, assignment_status,
    visibility_scope_key, is_active
)
SELECT
    i.identity_id,
    ri.role_key,
    ri.role_instance_id,
    v.employee_code,
    TRUE,
    DATE '2026-03-01',
    'ACTIVE',
    v.visibility_scope_key,
    TRUE
FROM (
    VALUES
        -- Broking Division: Managing Directors
        ('cameron.smith@galetti.co.za',          '10001_Managing_Director_JHB_Broking', 'CAMS', 'JHB Broking'),
        ('francois@galetti.co.za',               '10002_Managing_Director_WC_Broking',  'FRAS', 'WC Broking'),
        ('david.arton-powell@galetti.co.za',     '10003_Division_Head_WC_Broking',      'DAVA', 'WC Broking'),

        -- Broking Division: Ops Managers
        ('lerato.makgetla@galetti.co.za',        '10101_Operations_JHB_Broking', 'LERM', 'JHB Broking'),
        ('nadine.guedes@galetti.co.za',          '10102_Operations_WC_Broking',  'NADG', 'WC Broking'),
        ('jenna.meyer@galetti.co.za',            '10103_Operations_WC_Broking',  'JENM', 'WC Broking'),
        ('ivan.vandermerwe@galetti.co.za',       '10104_Operations_WC_Broking',  'IVAV', 'WC Broking'),

        -- Broking Division: JHB Deal Makers (11001-11025)
        ('donovan.akom@galetti.co.za',           '11001_Deal_Maker_JHB_Broking', 'DONA', 'JHB Broking'),
        ('jake.archibald@galetti.co.za',         '11002_Deal_Maker_JHB_Broking', 'JAKA', 'JHB Broking'),
        ('kenrick.begemann@galetti.co.za',       '11003_Deal_Maker_JHB_Broking', 'KENB', 'JHB Broking'),
        ('divan.binneman@galetti.co.za',         '11004_Deal_Maker_JHB_Broking', 'DIVB', 'JHB Broking'),
        ('francois.botha@galetti.co.za',         '11005_Deal_Maker_JHB_Broking', 'FRAB', 'JHB Broking'),
        ('storme.burger@galetti.co.za',          '11006_Deal_Maker_JHB_Broking', 'STOB', 'JHB Broking'),
        ('tracy.campbell@galetti.co.za',         '11007_Deal_Maker_JHB_Broking', 'TRAC', 'JHB Broking'),
        ('muhammad.chothia@galetti.co.za',       '11008_Deal_Maker_JHB_Broking', 'MUHC', 'JHB Broking'),
        ('pav.govender@galetti.co.za',           '11009_Deal_Maker_JHB_Broking', 'PAVG', 'JHB Broking'),
        ('rochelle.holland@galetti.co.za',       '11010_Deal_Maker_JHB_Broking', 'ROCH', 'JHB Broking'),
        ('chris.humphries@galetti.co.za',        '11011_Deal_Maker_JHB_Broking', 'CHRH', 'JHB Broking'),
        ('dylan.kelly@galetti.co.za',            '11012_Deal_Maker_JHB_Broking', 'DYLK', 'JHB Broking'),
        ('tshepo.kubeka@galetti.co.za',          '11013_Deal_Maker_JHB_Broking', 'TSHK', 'JHB Broking'),
        ('riaan.loggenberg@galetti.co.za',       '11014_Deal_Maker_JHB_Broking', 'RIAL', 'JHB Broking'),
        ('kingsley.martell@galetti.co.za',       '11015_Deal_Maker_JHB_Broking', 'KINM', 'JHB Broking'),
        ('danyl.mathieson@galetti.co.za',        '11016_Deal_Maker_JHB_Broking', 'DANM', 'JHB Broking'),
        ('james.mccormack@galetti.co.za',        '11017_Deal_Maker_JHB_Broking', 'JAMM', 'JHB Broking'),
        ('ross.minnaar@galetti.co.za',           '11018_Deal_Maker_JHB_Broking', 'ROSSM', 'JHB Broking'),
        ('sam.pearson@galetti.co.za',            '11019_Deal_Maker_JHB_Broking', 'SAMP', 'JHB Broking'),
        ('derrick.pienaar@galetti.co.za',        '11020_Deal_Maker_JHB_Broking', 'DERP', 'JHB Broking'),
        ('dylan.pietersen@galetti.co.za',        '11021_Deal_Maker_JHB_Broking', 'DYLP', 'JHB Broking'),
        ('kgomotso.radebe@galetti.co.za',        '11022_Deal_Maker_JHB_Broking', 'KGOR', 'JHB Broking'),
        ('tiisetso.serudu@galetti.co.za',        '11023_Deal_Maker_JHB_Broking', 'TIIS', 'JHB Broking'),
        ('dian.theron@galetti.co.za',            '11024_Deal_Maker_JHB_Broking', 'DIAT', 'JHB Broking'),
        ('james.trenchard@galetti.co.za',        '11025_Deal_Maker_JHB_Broking', 'JAMT', 'JHB Broking'),

        -- Broking Division: WC Deal Makers (11026-11036)
        ('reyaan.abarder@galetti.co.za',         '11026_Deal_Maker_WC_Broking', 'REYA', 'WC Broking'),
        ('jose.cabeleira@galetti.co.za',         '11027_Deal_Maker_WC_Broking', 'JOSC', 'WC Broking'),
        ('siraaj.cassim@galetti.co.za',          '11028_Deal_Maker_WC_Broking', 'SIRC', 'WC Broking'),
        ('kyle.castelyn@galetti.co.za',          '11029_Deal_Maker_WC_Broking', 'KYLC', 'WC Broking'),
        ('muhammed.gamo@galetti.co.za',          '11030_Deal_Maker_WC_Broking', 'MUHG', 'WC Broking'),
        ('andrew.light@galetti.co.za',           '11031_Deal_Maker_WC_Broking', 'ANDL', 'WC Broking'),
        ('clint.marais@galetti.co.za',           '11032_Deal_Maker_WC_Broking', 'CLIM', 'WC Broking'),
        ('ian.moses@galetti.co.za',              '11033_Deal_Maker_WC_Broking', 'IANM', 'WC Broking'),
        ('darrin.richardson@galetti.co.za',      '11034_Deal_Maker_WC_Broking', 'DARR', 'WC Broking'),
        ('kyle.small@galetti.co.za',             '11035_Deal_Maker_WC_Broking', 'KYLS', 'WC Broking'),
        ('mark.wingerin@galetti.co.za',          '11036_Deal_Maker_WC_Broking', 'MARW', 'WC Broking'),

        -- Auction Division: Managing Directors
        ('ricardo.dasilva@galetti.co.za',        '20001_Managing_Director_JHB_Auction',     'RICD', 'JHB Auction'),
        ('wesley.cowan@galetti.co.za',           '20002_Managing_Director_Coastal_Auction',  'WESC', 'EC KZN WC Auction'),

        -- Auction Division: Ops Managers
        ('kgomotso.dube@galetti.co.za',          '20101_Operations_JHB_Auction', 'KGOD', 'JHB Auction'),
        ('igenda.ejekwu@galetti.co.za',          '20102_Operations_JHB_Auction', 'IGEE', 'JHB Auction'),
        ('Jessica.green@galetti.co.za',          '20103_Operations_JHB_Auction', 'JESG', 'JHB Auction'),

        -- Auction Division: JHB Deal Makers (21001-21016)
        ('georgia.barbaglia@galetti.co.za',      '21001_Deal_Maker_JHB_Auction', 'GEOB', 'JHB Auction'),
        ('david.dawson@galetti.co.za',           '21002_Deal_Maker_JHB_Auction', 'DAVD', 'JHB Auction'),
        ('guy.dowding@galetti.co.za',            '21003_Deal_Maker_JHB_Auction', 'GUYD', 'JHB Auction'),
        ('regardt.engelbrecht@galetti.co.za',    '21004_Deal_Maker_JHB_Auction', 'REGE', 'JHB Auction'),
        ('tyra.ford@galetti.co.za',              '21005_Deal_Maker_JHB_Auction', 'TYRF', 'JHB Auction'),
        ('clinton.govender@galetti.co.za',       '21006_Deal_Maker_JHB_Auction', 'CLIG', 'JHB Auction'),
        ('sakhi.gqeba@galetti.co.za',            '21007_Deal_Maker_JHB_Auction', 'SAKG', 'JHB Auction'),
        ('claydon.hamilton@galetti.co.za',       '21008_Deal_Maker_JHB_Auction', 'CLAH', 'JHB Auction'),
        ('kopano.matlala@galetti.co.za',         '21009_Deal_Maker_JHB_Auction', 'KOPM', 'JHB Auction'),
        ('joshua.mimbulu@galetti.co.za',         '21010_Deal_Maker_JHB_Auction', 'JOSM', 'JHB Auction'),
        ('gareth.murray@galetti.co.za',          '21011_Deal_Maker_JHB_Auction', 'GARM', 'JHB Auction'),
        ('karusha.pillay@galetti.co.za',         '21012_Deal_Maker_JHB_Auction', 'KARP', 'JHB Auction'),
        ('kiran.singh@galetti.co.za',            '21013_Deal_Maker_JHB_Auction', 'KIRS', 'JHB Auction'),
        ('francois.vandermerwe@galetti.co.za',   '21014_Deal_Maker_JHB_Auction', 'FRAV', 'JHB Auction'),
        ('darius.vanniekerk@galetti.co.za',      '21015_Deal_Maker_JHB_Auction', 'DARV', 'JHB Auction'),
        ('kristylee.zeeman@galetti.co.za',       '21016_Deal_Maker_JHB_Auction', 'KRIZ', 'JHB Auction'),

        -- Auction Division: WC Deal Makers (21017-21033)
        ('lester.atkinson@galetti.co.za',        '21017_Deal_Maker_WC_Auction', 'LESA', 'WC Auction'),
        ('sylvester.black@galetti.co.za',        '21018_Deal_Maker_WC_Auction', 'SYLB', 'WC Auction'),
        ('ryan.burgess@galetti.co.za',           '21019_Deal_Maker_WC_Auction', 'RYB',  'WC Auction'),
        ('patrick.dewet@galetti.co.za',          '21020_Deal_Maker_WC_Auction', 'PATD', 'WC Auction'),
        ('gabriella.frankel@galetti.co.za',      '21021_Deal_Maker_WC_Auction', 'GABF', 'WC Auction'),
        ('jordan.grobbelaar@galetti.co.za',      '21022_Deal_Maker_WC_Auction', 'JORG', 'WC Auction'),
        ('anton.groeneveldt@galetti.co.za',      '21023_Deal_Maker_WC_Auction', 'ANTLG', 'WC Auction'),
        ('cameron.hudson@galetti.co.za',         '21024_Deal_Maker_WC_Auction', 'CAMH', 'WC Auction'),
        ('itai.ilouze@galetti.co.za',            '21025_Deal_Maker_WC_Auction', 'ITAI', 'WC Auction'),
        ('Uwais.khan@galetti.co.za',             '21026_Deal_Maker_WC_Auction', 'UWAK', 'WC Auction'),
        ('tom.king@galetti.co.za',               '21027_Deal_Maker_WC_Auction', 'THOK', 'WC Auction'),
        ('paul.knoop@galetti.co.za',             '21028_Deal_Maker_WC_Auction', 'PAUK', 'WC Auction'),
        ('qaasim.lamara@galetti.co.za',          '21029_Deal_Maker_WC_Auction', 'QAAL', 'WC Auction'),
        ('vibeke.mccleland@galetti.co.za',       '21030_Deal_Maker_WC_Auction', 'VIBM', 'WC Auction'),
        ('adriaan.rabie@galetti.co.za',          '21031_Deal_Maker_WC_Auction', 'ADRR', 'WC Auction'),
        ('zaahid.sydow@galetti.co.za',           '21032_Deal_Maker_WC_Auction', 'ZAAS', 'WC Auction'),
        ('shawn.vanjaarsveld@galetti.co.za',     '21033_Deal_Maker_WC_Auction', 'SHAJ', 'WC Auction'),

        -- Auction Division: KZN Deal Makers (21034-21040)
        ('scotty.corlett@galetti.co.za',         '21034_Deal_Maker_KZN_Auction', 'SCOC', 'KZN Auction'),
        ('asanda.gwamanda@galetti.co.za',        '21035_Deal_Maker_KZN_Auction', 'ASAG', 'KZN Auction'),
        ('greg.mcglashan@galetti.co.za',         '21036_Deal_Maker_KZN_Auction', 'GREM', 'KZN Auction'),
        ('warren.moyle@galetti.co.za',           '21037_Deal_Maker_KZN_Auction', 'WARM', 'KZN Auction'),
        ('dean.solomon@galetti.co.za',           '21038_Deal_Maker_KZN_Auction', 'DEAS', 'KZN Auction'),
        ('joshua.swanepoel@galetti.co.za',       '21039_Deal_Maker_KZN_Auction', 'JOSW', 'KZN Auction'),
        ('christopher.young@galetti.co.za',      '21040_Deal_Maker_KZN_Auction', 'CHRY', 'KZN Auction'),

        -- Auction Division: EC Deal Makers (21041-21042)
        ('bhavesh.bansda@galetti.co.za',         '21041_Deal_Maker_EC_Auction', 'BHAB', 'EC Auction'),
        ('shaka.mvula@galetti.co.za',            '21042_Deal_Maker_EC_Auction', 'XOLM', 'EC Auction'),

        -- GCS Division: Managing Director
        ('simon.wilkins@galetti.co.za',          '30001_Managing_Director_GCS', 'SIMW', 'GCS'),

        -- GCS Division: Ops Managers
        ('camilla.messias@galetti.co.za',        '30101_Operations_GCS', 'CAMM', 'GCS'),
        ('chenai.mugunyani@galetti.co.za',       '30102_Operations_GCS', 'CHEM', 'GCS'),
        ('kerryann.oelofse@galetti.co.za',       '30103_Operations_GCS', 'KERO', 'GCS'),

        -- GCS Division: Deal Makers (31001-31008)
        ('leandri.botha@galetti.co.za',          '31001_Deal_Maker_GCS', 'LEAB', 'GCS'),
        ('kyle.hyam@galetti.co.za',              '31002_Deal_Maker_GCS', 'KYLH', 'GCS'),
        ('keke.khojane@galetti.co.za',           '31003_Deal_Maker_GCS', 'KEKK', 'GCS'),
        ('ila.milambo@galetti.co.za',            '31004_Deal_Maker_GCS', 'ILAM', 'GCS'),
        ('ramaano.mphigalale@galetti.co.za',     '31005_Deal_Maker_GCS', 'RAMP', 'GCS'),
        ('michelle.mringi@galetti.co.za',        '31006_Deal_Maker_GCS', 'MICM', 'GCS'),
        ('justin.thom@galetti.co.za',            '31007_Deal_Maker_GCS', 'JUST', 'GCS'),
        ('elena.zwick@galetti.co.za',            '31008_Deal_Maker_GCS', 'ELEZ', 'GCS'),

        -- Executive
        ('john.jack@galetti.co.za',              '50001_CEO', 'JONJ', 'Executive'),
        ('antoinette.chait@galetti.co.za',       '50002_COO', 'ANTC', 'Executive'),
        ('alison.gerber@galetti.co.za',          '50003_CFO', 'ALIG', 'Executive'),

        -- Finance
        ('bernice.jordaan@galetti.co.za',        '60000_Finance_Manager', 'BERJ', 'Finance')
) AS v(email, role_instance_id, employee_code, visibility_scope_key)
JOIN security.identity i ON i.email = v.email
JOIN config.role_instance ri ON ri.role_instance_id = v.role_instance_id
WHERE NOT EXISTS (
    SELECT 1
    FROM security.role_assignment ra
    WHERE ra.identity_id      = i.identity_id
      AND ra.role_key         = ri.role_key
      AND COALESCE(ra.role_instance_id, '') = COALESCE(v.role_instance_id, '')
      AND ra.is_active        = TRUE
);

-- =========================================================================
-- SECTION 5 — Deal Type Variant extensions (Sheet 07)
-- =========================================================================
-- Update existing rows seeded by S003 with workbook-enriched columns.

UPDATE config.deal_type_variant
SET deal_family             = 'LEASE',
    subtype_key             = 'LEASE_ACQUISITION',
    deal_sheet_template_key = 'LEASE_ACQUISITION',
    xero_payload_type       = 'LEASE_INVOICE',
    checklist_template_key  = 'LEASE_STD',
    signwell_template_group = 'LEASE_ACQUISITION',
    allows_external_referral      = FALSE,
    requires_property_section     = TRUE,
    requires_conveyancer_section  = FALSE,
    allows_invoicing_instructions = TRUE,
    requires_landlord       = TRUE,
    requires_tenant         = TRUE,
    requires_buyer          = FALSE,
    requires_seller         = FALSE,
    requires_client         = FALSE,
    broker_slots_max        = 8
WHERE variant_key = 'LEASE_ACQUISITION';

UPDATE config.deal_type_variant
SET deal_family             = 'LEASE',
    subtype_key             = 'LEASE_RENEWAL',
    deal_sheet_template_key = 'LEASE_RENEWAL',
    xero_payload_type       = 'LEASE_INVOICE',
    checklist_template_key  = 'LEASE_STD',
    signwell_template_group = 'LEASE_RENEWAL',
    allows_external_referral      = FALSE,
    requires_property_section     = TRUE,
    requires_conveyancer_section  = FALSE,
    allows_invoicing_instructions = TRUE,
    requires_landlord       = TRUE,
    requires_tenant         = TRUE,
    requires_buyer          = FALSE,
    requires_seller         = FALSE,
    requires_client         = FALSE,
    broker_slots_max        = 8
WHERE variant_key = 'LEASE_RENEWAL';

UPDATE config.deal_type_variant
SET deal_family             = 'SALE',
    subtype_key             = 'SALE_PVT_TREATY',
    deal_sheet_template_key = 'SALE_PVT_TREATY',
    xero_payload_type       = 'SALE_INVOICE',
    checklist_template_key  = 'SALE_PVT_TREATY',
    signwell_template_group = 'SALE_PVT_TREATY',
    allows_external_referral      = FALSE,
    requires_property_section     = TRUE,
    requires_conveyancer_section  = FALSE,
    allows_invoicing_instructions = TRUE,
    requires_landlord       = FALSE,
    requires_tenant         = FALSE,
    requires_buyer          = TRUE,
    requires_seller         = TRUE,
    requires_client         = FALSE,
    broker_slots_max        = 8
WHERE variant_key = 'SALE_PRIVATE_TREATY';

UPDATE config.deal_type_variant
SET deal_family             = 'SALE',
    subtype_key             = 'SALE_SEALED_BID',
    deal_sheet_template_key = 'SALE_SEALED_BID',
    xero_payload_type       = 'SALE_INVOICE',
    checklist_template_key  = 'SALE_SEALED_BID',
    signwell_template_group = 'SALE_SEALED_BID',
    allows_external_referral      = FALSE,
    requires_property_section     = TRUE,
    requires_conveyancer_section  = FALSE,
    allows_invoicing_instructions = TRUE,
    requires_landlord       = FALSE,
    requires_tenant         = FALSE,
    requires_buyer          = TRUE,
    requires_seller         = TRUE,
    requires_client         = FALSE,
    broker_slots_max        = 8
WHERE variant_key = 'SALE_SEALED_BID';

UPDATE config.deal_type_variant
SET deal_family             = 'REGEAR_OR_CLIENT_INVOICE',
    subtype_key             = 'REGEAR',
    deal_sheet_template_key = 'REGEAR',
    xero_payload_type       = 'REGEAR_INVOICE',
    checklist_template_key  = 'REGEAR',
    signwell_template_group = 'REGEAR',
    allows_external_referral      = FALSE,
    requires_property_section     = TRUE,
    requires_conveyancer_section  = FALSE,
    allows_invoicing_instructions = TRUE,
    requires_landlord       = TRUE,
    requires_tenant         = FALSE,
    requires_buyer          = FALSE,
    requires_seller         = FALSE,
    requires_client         = TRUE,
    broker_slots_max        = 8
WHERE variant_key = 'LEASE_REGEAR';

UPDATE config.deal_type_variant
SET deal_family             = 'REGEAR_OR_CLIENT_INVOICE',
    subtype_key             = 'CLIENT_INVOICE',
    deal_sheet_template_key = 'CLIENT_INVOICE',
    xero_payload_type       = 'CLIENT_TENANT_INVOICE',
    checklist_template_key  = 'CLIENT_TENANT',
    signwell_template_group = 'CLIENT_TENANT',
    allows_external_referral      = FALSE,
    requires_property_section     = TRUE,
    requires_conveyancer_section  = FALSE,
    allows_invoicing_instructions = TRUE,
    requires_landlord       = TRUE,
    requires_tenant         = FALSE,
    requires_buyer          = FALSE,
    requires_seller         = FALSE,
    requires_client         = TRUE,
    broker_slots_max        = 8
WHERE variant_key = 'LEASE_CLIENT_INVOICE';

UPDATE config.deal_type_variant
SET deal_family             = 'AUCTION',
    subtype_key             = 'AUCTION',
    deal_sheet_template_key = 'SALE_AUCTION',
    xero_payload_type       = 'AUCTION_INVOICE',
    checklist_template_key  = 'AUCTION',
    signwell_template_group = 'AUCTION',
    allows_external_referral      = FALSE,
    requires_property_section     = TRUE,
    requires_conveyancer_section  = FALSE,
    allows_invoicing_instructions = TRUE,
    requires_landlord       = FALSE,
    requires_tenant         = FALSE,
    requires_buyer          = TRUE,
    requires_seller         = TRUE,
    requires_client         = FALSE,
    broker_slots_max        = 8
WHERE variant_key = 'AUCTION';

-- =========================================================================
-- SECTION 6 — Commission Rules (Sheet 09)
-- =========================================================================
-- Broking division tiered commission schedule applied across all deal types.
-- Uses the existing unique constraint (deal_type_key, rule_key, effective_from).

INSERT INTO config.commission_rule (
    deal_type_key, rule_key, effective_from, parameters, is_active,
    deal_family, division_key, threshold_period, threshold_metric,
    applies_from_threshold_inclusive, applies_to_threshold_exclusive,
    commission_pct, company_split_pct, tier_sequence,
    broker_net_formula_note
)
VALUES
    -- Tier 1: 0 to R1,450,000 at 50/50
    ('LEASE_ACQ_RENEW', 'BROKING_TIER_01', DATE '2026-03-01',
     '{"tier":"1","description":"Broking Tier 1 - standard split"}'::jsonb, TRUE,
     'LEASE', 'Broking', 'ANNUAL', 'GROSS_BILLINGS',
     0, 1450000,
     0.5000, 0.5000, 1,
     'Net = Gross x Split x (1 - CompanySplit)'),

    ('SALE_PRIVATE_SEALED', 'BROKING_TIER_01', DATE '2026-03-01',
     '{"tier":"1","description":"Broking Tier 1 - standard split"}'::jsonb, TRUE,
     'SALE', 'Broking', 'ANNUAL', 'GROSS_BILLINGS',
     0, 1450000,
     0.5000, 0.5000, 1,
     'Net = Gross x Split x (1 - CompanySplit)'),

    ('LEASE_REGEAR_CLIENT_INV', 'BROKING_TIER_01', DATE '2026-03-01',
     '{"tier":"1","description":"Broking Tier 1 - standard split"}'::jsonb, TRUE,
     'REGEAR_OR_CLIENT_INVOICE', 'Broking', 'ANNUAL', 'GROSS_BILLINGS',
     0, 1450000,
     0.5000, 0.5000, 1,
     'Net = Gross x Split x (1 - CompanySplit)'),

    ('SALE_AUCTION', 'BROKING_TIER_01', DATE '2026-03-01',
     '{"tier":"1","description":"Broking Tier 1 - standard split"}'::jsonb, TRUE,
     'AUCTION', 'Broking', 'ANNUAL', 'GROSS_BILLINGS',
     0, 1450000,
     0.5000, 0.5000, 1,
     'Net = Gross x Split x (1 - CompanySplit)'),

    -- Tier 2: R1,450,000+, 60/40
    ('LEASE_ACQ_RENEW', 'BROKING_TIER_02', DATE '2026-03-01',
     '{"tier":"2","description":"Broking Tier 2 - enhanced split"}'::jsonb, TRUE,
     'LEASE', 'Broking', 'ANNUAL', 'GROSS_BILLINGS',
     1450000, NULL,
     0.6000, 0.4000, 2,
     'Net = Gross x Split x (1 - CompanySplit)'),

    ('SALE_PRIVATE_SEALED', 'BROKING_TIER_02', DATE '2026-03-01',
     '{"tier":"2","description":"Broking Tier 2 - enhanced split"}'::jsonb, TRUE,
     'SALE', 'Broking', 'ANNUAL', 'GROSS_BILLINGS',
     1450000, NULL,
     0.6000, 0.4000, 2,
     'Net = Gross x Split x (1 - CompanySplit)'),

    ('LEASE_REGEAR_CLIENT_INV', 'BROKING_TIER_02', DATE '2026-03-01',
     '{"tier":"2","description":"Broking Tier 2 - enhanced split"}'::jsonb, TRUE,
     'REGEAR_OR_CLIENT_INVOICE', 'Broking', 'ANNUAL', 'GROSS_BILLINGS',
     1450000, NULL,
     0.6000, 0.4000, 2,
     'Net = Gross x Split x (1 - CompanySplit)'),

    ('SALE_AUCTION', 'BROKING_TIER_02', DATE '2026-03-01',
     '{"tier":"2","description":"Broking Tier 2 - enhanced split"}'::jsonb, TRUE,
     'AUCTION', 'Broking', 'ANNUAL', 'GROSS_BILLINGS',
     1450000, NULL,
     0.6000, 0.4000, 2,
     'Net = Gross x Split x (1 - CompanySplit)')

ON CONFLICT (deal_type_key, rule_key, effective_from) DO UPDATE
SET parameters                       = EXCLUDED.parameters,
    is_active                        = EXCLUDED.is_active,
    deal_family                      = EXCLUDED.deal_family,
    division_key                     = EXCLUDED.division_key,
    threshold_period                 = EXCLUDED.threshold_period,
    threshold_metric                 = EXCLUDED.threshold_metric,
    applies_from_threshold_inclusive = EXCLUDED.applies_from_threshold_inclusive,
    applies_to_threshold_exclusive   = EXCLUDED.applies_to_threshold_exclusive,
    commission_pct                   = EXCLUDED.commission_pct,
    company_split_pct                = EXCLUDED.company_split_pct,
    tier_sequence                    = EXCLUDED.tier_sequence,
    broker_net_formula_note          = EXCLUDED.broker_net_formula_note;

-- =========================================================================
-- SECTION 7 — Document Checklist Rules (Sheet 08)
-- =========================================================================
-- Enrich existing doc_checklist_template_item rows with workbook metadata.
-- The items were created by S001/S002; here we tag them with deal_family,
-- subtype, party_scope, and conditional flags from the workbook.

-- Lease Acquisition checklist items
UPDATE config.doc_checklist_template_item
SET deal_family  = 'LEASE',
    subtype_key  = 'LEASE_ACQUISITION',
    variant_key  = 'STANDARD'
WHERE doc_checklist_template_id IN (
    SELECT doc_checklist_template_id
    FROM config.doc_checklist_template
    WHERE template_key = 'TPL_LEASE_ACQUISITION'
);

-- Lease Renewal checklist items
UPDATE config.doc_checklist_template_item
SET deal_family  = 'LEASE',
    subtype_key  = 'LEASE_RENEWAL',
    variant_key  = 'STANDARD'
WHERE doc_checklist_template_id IN (
    SELECT doc_checklist_template_id
    FROM config.doc_checklist_template
    WHERE template_key = 'TPL_LEASE_RENEWAL_V2'
);

-- Sale Private Treaty checklist items
UPDATE config.doc_checklist_template_item
SET deal_family  = 'SALE',
    subtype_key  = 'SALE_PRIVATE_TREATY',
    variant_key  = 'STANDARD'
WHERE doc_checklist_template_id IN (
    SELECT doc_checklist_template_id
    FROM config.doc_checklist_template
    WHERE template_key = 'TPL_SALE_PRIVATE_TREATY'
);

-- Sale Sealed Bid checklist items
UPDATE config.doc_checklist_template_item
SET deal_family  = 'SALE',
    subtype_key  = 'SALE_SEALED_BID',
    variant_key  = 'STANDARD'
WHERE doc_checklist_template_id IN (
    SELECT doc_checklist_template_id
    FROM config.doc_checklist_template
    WHERE template_key = 'TPL_SALE_SEALED_BID'
);

-- Regear checklist items
UPDATE config.doc_checklist_template_item
SET deal_family  = 'REGEAR_OR_CLIENT_INVOICE',
    subtype_key  = 'LEASE_REGEAR',
    variant_key  = 'STANDARD'
WHERE doc_checklist_template_id IN (
    SELECT doc_checklist_template_id
    FROM config.doc_checklist_template
    WHERE template_key = 'TPL_LEASE_REGEAR_V2'
);

-- Client Invoice checklist items
UPDATE config.doc_checklist_template_item
SET deal_family  = 'REGEAR_OR_CLIENT_INVOICE',
    subtype_key  = 'LEASE_CLIENT_INVOICE',
    variant_key  = 'STANDARD'
WHERE doc_checklist_template_id IN (
    SELECT doc_checklist_template_id
    FROM config.doc_checklist_template
    WHERE template_key = 'TPL_LEASE_CLIENT_INVOICE'
);

-- Auction checklist items
UPDATE config.doc_checklist_template_item
SET deal_family  = 'AUCTION',
    subtype_key  = 'AUCTION',
    variant_key  = 'STANDARD'
WHERE doc_checklist_template_id IN (
    SELECT doc_checklist_template_id
    FROM config.doc_checklist_template
    WHERE template_key = 'TPL_AUCTION'
);

-- =========================================================================
-- SECTION 8 — Signwell Template Config (Sheet 10)
-- =========================================================================
-- Enrich existing signwell_template rows with workbook metadata.

UPDATE config.signwell_template
SET deal_family              = 'LEASE',
    subtype_key              = 'LEASE_ACQUISITION',
    signwell_template_name   = 'Lease Acquisition Standard',
    signing_mode             = 'SEQUENTIAL',
    deal_sheet_template_key  = 'LEASE_ACQUISITION',
    field_map_version        = 'v1'
WHERE deal_subtype_key = 'LEASE_ACQUISITION';

UPDATE config.signwell_template
SET deal_family              = 'LEASE',
    subtype_key              = 'LEASE_RENEWAL',
    signwell_template_name   = 'Lease Renewal Standard',
    signing_mode             = 'SEQUENTIAL',
    deal_sheet_template_key  = 'LEASE_RENEWAL',
    field_map_version        = 'v1'
WHERE deal_subtype_key = 'LEASE_RENEWAL';

UPDATE config.signwell_template
SET deal_family              = 'SALE',
    subtype_key              = 'SALE_PRIVATE_TREATY',
    signwell_template_name   = 'Sale Private Treaty Standard',
    signing_mode             = 'SEQUENTIAL',
    deal_sheet_template_key  = 'SALE_PVT_TREATY',
    field_map_version        = 'v1'
WHERE deal_subtype_key = 'SALE_PRIVATE_TREATY';

UPDATE config.signwell_template
SET deal_family              = 'SALE',
    subtype_key              = 'SALE_SEALED_BID',
    signwell_template_name   = 'Sale Sealed Bid Standard',
    signing_mode             = 'SEQUENTIAL',
    deal_sheet_template_key  = 'SALE_SEALED_BID',
    field_map_version        = 'v1'
WHERE deal_subtype_key = 'SALE_SEALED_BID';

UPDATE config.signwell_template
SET deal_family              = 'REGEAR_OR_CLIENT_INVOICE',
    subtype_key              = 'LEASE_REGEAR',
    signwell_template_name   = 'Regear Standard',
    signing_mode             = 'SEQUENTIAL',
    deal_sheet_template_key  = 'REGEAR',
    field_map_version        = 'v1'
WHERE deal_subtype_key = 'LEASE_REGEAR';

UPDATE config.signwell_template
SET deal_family              = 'REGEAR_OR_CLIENT_INVOICE',
    subtype_key              = 'LEASE_CLIENT_INVOICE',
    signwell_template_name   = 'Client Invoice Standard',
    signing_mode             = 'SEQUENTIAL',
    deal_sheet_template_key  = 'CLIENT_INVOICE',
    field_map_version        = 'v1'
WHERE deal_subtype_key = 'LEASE_CLIENT_INVOICE';

UPDATE config.signwell_template
SET deal_family              = 'AUCTION',
    subtype_key              = 'AUCTION',
    signwell_template_name   = 'Auction Standard',
    signing_mode             = 'SEQUENTIAL',
    deal_sheet_template_key  = 'SALE_AUCTION',
    field_map_version        = 'v1'
WHERE deal_subtype_key = 'AUCTION';

-- Upsert signwell_recipient_role_map for G2 gate.
-- Table has UNIQUE(gate_key, role_key), so one row per role per gate.
-- DIV_APPROVER = slot 1 (division head); DEAL_MAKER = slot 2+ (lead + additional).
-- The full 9-slot expansion (LEAD_DEALMAKER..DEALMAKER_08) is modeled
-- via the recipient_slots JSONB on signwell_template config.
INSERT INTO config.signwell_recipient_role_map (gate_key, role_key, recipient_order, recipient_selector)
VALUES
    ('G2', 'DIV_APPROVER', 1, 'LEAD_BROKER_DIVISION_HEAD'),
    ('G2', 'DEAL_MAKER',   2, 'LEAD_DEALMAKER')
ON CONFLICT (gate_key, role_key) DO UPDATE
SET recipient_order    = EXCLUDED.recipient_order,
    recipient_selector = EXCLUDED.recipient_selector;

-- =========================================================================
-- SECTION 9 — Role Permissions for new role keys (Sheet 02 cross-ref)
-- =========================================================================

INSERT INTO config.role_permission (role_key, permission_key)
SELECT v.role_key, v.permission_key
FROM (
    VALUES
        -- DEAL_MAKER: can read tasks
        ('DEAL_MAKER', 'TASK_READ'),

        -- OPS_MANAGER: draft lifecycle + read
        ('OPS_MANAGER', 'DRAFT_EDIT'),
        ('OPS_MANAGER', 'DRAFT_SUBMIT'),
        ('OPS_MANAGER', 'TRACKER_READ'),
        ('OPS_MANAGER', 'TASK_READ'),

        -- DIV_APPROVER: gate decisions + read
        ('DIV_APPROVER', 'GATE_DECIDE'),
        ('DIV_APPROVER', 'TASK_READ'),

        -- EXEC_APPROVER: gate decisions + read
        ('EXEC_APPROVER', 'GATE_DECIDE'),
        ('EXEC_APPROVER', 'TASK_READ'),
        ('EXEC_APPROVER', 'TRACKER_READ'),

        -- SYS_ADMIN: full permissions
        ('SYS_ADMIN', 'DRAFT_EDIT'),
        ('SYS_ADMIN', 'DRAFT_SUBMIT'),
        ('SYS_ADMIN', 'TRACKER_READ'),
        ('SYS_ADMIN', 'TASK_READ'),
        ('SYS_ADMIN', 'GATE_DECIDE'),
        ('SYS_ADMIN', 'FINANCE_SUMMARY_READ'),
        ('SYS_ADMIN', 'PAYLOAD_READ')
) AS v(role_key, permission_key)
WHERE EXISTS (
    SELECT 1 FROM config.role_catalog rc WHERE rc.role_key = v.role_key
)
ON CONFLICT (role_key, permission_key) DO NOTHING;

COMMIT;
