-- Seed verification script.
-- Expected result: zero failing checks. The script raises an exception if any check fails.

DROP TABLE IF EXISTS tmp_seed_checks;

CREATE TEMP TABLE tmp_seed_checks AS
WITH checks AS (
    SELECT 'seed:gates_count>=6' AS check_name, (SELECT COUNT(*) >= 6 FROM config.gate_catalog) AS ok
    UNION ALL
    SELECT 'seed:gates_have_G0_G5', (
        SELECT COUNT(*) = 6
        FROM config.gate_catalog
        WHERE gate_key IN ('G0', 'G1', 'G2', 'G3', 'G4', 'G5')
    )
    UNION ALL
    SELECT 'seed:role_catalog_has_fin_broker_division_head', (
        SELECT COUNT(*) = 3
        FROM config.role_catalog
        WHERE role_key IN ('FIN_APPROVER', 'BROKER', 'DIVISION_HEAD')
    )
    UNION ALL
    SELECT 'seed:approval_rule_set_present', EXISTS (
        SELECT 1
        FROM config.approval_rule_set
        WHERE rule_set_key = 'DEFAULT_GATES_0_3'
    )
    UNION ALL
    SELECT 'seed:approval_rules_G1_G2_G3_present', (
        SELECT COUNT(*) >= 4
        FROM config.approval_rule
        WHERE gate_key IN ('G1', 'G2', 'G3')
    )
    UNION ALL
    SELECT 'seed:doc_templates_present', (
        SELECT COUNT(*) >= 4
        FROM config.doc_checklist_template
    )
    UNION ALL
    SELECT 'seed:doc_template_items_present', (
        SELECT COUNT(*) >= 12
        FROM config.doc_checklist_template_item
    )
    UNION ALL
    SELECT 'seed:fica_or_jse_condition_present', EXISTS (
        SELECT 1
        FROM config.doc_checklist_conditional_rule
        WHERE condition_key = 'REQUIRES_FICA_OR_JSE'
    )
    UNION ALL
    SELECT 'seed:signwell_templates_g2_present', (
        SELECT COUNT(*) >= 4
        FROM config.signwell_template
        WHERE gate_key = 'G2'
    )
    UNION ALL
    SELECT 'seed:signwell_recipient_mapping_present', (
        SELECT COUNT(*) = 2
        FROM config.signwell_recipient_role_map
        WHERE gate_key = 'G2'
          AND role_key IN ('BROKER', 'DIVISION_HEAD')
    )
)
SELECT * FROM checks;

SELECT check_name, ok
FROM tmp_seed_checks
ORDER BY check_name;

DO $$
DECLARE
    failing_check_count INTEGER;
BEGIN
    SELECT COUNT(*)
    INTO failing_check_count
    FROM tmp_seed_checks
    WHERE ok = FALSE;

    IF failing_check_count > 0 THEN
        RAISE EXCEPTION 'Seed verification failed: % check(s) failed', failing_check_count;
    END IF;
END;
$$;
