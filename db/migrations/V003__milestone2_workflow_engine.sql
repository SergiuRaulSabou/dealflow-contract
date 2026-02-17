BEGIN;

-- Milestone 2: deterministic promotion + doc template rules + approval requirement materialization.

ALTER TABLE ops.deal_draft
    ADD COLUMN IF NOT EXISTS is_jse_listed BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE ops.deal_draft_party
    ADD COLUMN IF NOT EXISTS requires_fica BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE core.deal_version
    ADD COLUMN IF NOT EXISTS is_jse_listed BOOLEAN NOT NULL DEFAULT FALSE;

ALTER TABLE core.deal_version_party
    ADD COLUMN IF NOT EXISTS requires_fica BOOLEAN NOT NULL DEFAULT FALSE;

CREATE UNIQUE INDEX IF NOT EXISTS ux_core_approval_requirement_version_rule
    ON core.approval_requirement (deal_version_id, approval_rule_id)
    WHERE approval_rule_id IS NOT NULL;

CREATE OR REPLACE FUNCTION core.materialize_approval_requirements(
    p_deal_version_id BIGINT,
    p_gate_key TEXT,
    p_rule_set_key TEXT DEFAULT 'DEFAULT_GATES_0_3'
)
RETURNS INTEGER
LANGUAGE plpgsql
AS $$
DECLARE
    v_exists BOOLEAN;
    v_inserted INTEGER := 0;
BEGIN
    SELECT EXISTS (
        SELECT 1
        FROM core.deal_version dv
        WHERE dv.deal_version_id = p_deal_version_id
    )
    INTO v_exists;

    IF NOT v_exists THEN
        RAISE EXCEPTION 'deal_version_id % does not exist', p_deal_version_id;
    END IF;

    WITH rules AS (
        SELECT ar.approval_rule_id, ar.required_role_key
        FROM config.approval_rule ar
        JOIN config.approval_rule_set ars
          ON ars.approval_rule_set_id = ar.approval_rule_set_id
        WHERE ars.rule_set_key = p_rule_set_key
          AND ar.gate_key = p_gate_key
        ORDER BY ar.rule_priority ASC
    ),
    ins AS (
        INSERT INTO core.approval_requirement (
            deal_version_id,
            gate_key,
            required_role_key,
            approval_rule_id
        )
        SELECT
            p_deal_version_id,
            p_gate_key,
            r.required_role_key,
            r.approval_rule_id
        FROM rules r
        ON CONFLICT (deal_version_id, approval_rule_id) WHERE approval_rule_id IS NOT NULL DO NOTHING
        RETURNING 1
    )
    SELECT COUNT(*) INTO v_inserted FROM ins;

    RETURN v_inserted;
END;
$$;

-- Promotion function: enforce doc checklist templates + conditional rule, snapshot to core, and materialize G1 requirements.
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
        is_jse_listed
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
        v_draft.is_jse_listed
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
        requires_fica
    )
    SELECT
        v_new_deal_version_id,
        p.party_role_key,
        p.party_name,
        p.party_email,
        p.party_phone,
        p.requires_fica
    FROM ops.deal_draft_party p
    WHERE p.draft_id = p_draft_id;

    INSERT INTO core.deal_version_broker (
        deal_version_id,
        broker_identity_id,
        broker_external_ref,
        is_lead_broker,
        split_percent
    )
    SELECT
        v_new_deal_version_id,
        b.broker_identity_id,
        b.broker_external_ref,
        b.is_lead_broker,
        b.split_percent
    FROM ops.deal_draft_broker b
    WHERE b.draft_id = p_draft_id;

    INSERT INTO core.deal_version_economics (
        deal_version_id,
        gross_billings,
        commission_total,
        company_split_pct,
        broker_split_pct,
        economics_payload
    )
    SELECT
        v_new_deal_version_id,
        e.gross_billings,
        e.commission_total,
        e.company_split_pct,
        e.broker_split_pct,
        e.economics_payload
    FROM ops.deal_draft_economics e
    WHERE e.draft_id = p_draft_id;

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
