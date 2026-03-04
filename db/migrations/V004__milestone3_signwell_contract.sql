BEGIN;

-- Milestone 3: Signwell payload contract, send-eligibility guard, and webhook ingest.

CREATE OR REPLACE FUNCTION core.is_send_eligible(
    p_deal_version_id BIGINT,
    p_gate_key TEXT
)
RETURNS TABLE (is_eligible BOOLEAN, reason TEXT)
LANGUAGE plpgsql
AS $$
DECLARE
    v_deal_version core.deal_version%ROWTYPE;
    v_missing_required_docs INTEGER;
    v_requirements_total INTEGER;
    v_unresolved_requirements INTEGER;
    v_open_envelopes INTEGER;
BEGIN
    SELECT dv.*
    INTO v_deal_version
    FROM core.deal_version dv
    WHERE dv.deal_version_id = p_deal_version_id;

    IF NOT FOUND THEN
        RETURN QUERY SELECT FALSE, 'DEAL_VERSION_NOT_FOUND';
        RETURN;
    END IF;

    IF v_deal_version.is_current IS DISTINCT FROM TRUE THEN
        RETURN QUERY SELECT FALSE, 'DEAL_VERSION_NOT_CURRENT';
        RETURN;
    END IF;

    IF COALESCE(v_deal_version.lifecycle_status, '') IN ('REJECTED', 'SUPERSEDED') THEN
        RETURN QUERY SELECT FALSE, 'DEAL_VERSION_REJECTED_OR_SUPERSEDED';
        RETURN;
    END IF;

    IF v_deal_version.current_gate_key IS DISTINCT FROM p_gate_key THEN
        RETURN QUERY SELECT FALSE, 'GATE_MISMATCH';
        RETURN;
    END IF;

    SELECT COUNT(*)
    INTO v_missing_required_docs
    FROM core.deal_version_doc_checklist_status s
    WHERE s.deal_version_id = p_deal_version_id
      AND s.is_required = TRUE
      AND s.is_confirmed = FALSE;

    IF v_missing_required_docs > 0 THEN
        RETURN QUERY SELECT FALSE, 'REQUIRED_DOCS_UNCONFIRMED';
        RETURN;
    END IF;

    SELECT COUNT(*)
    INTO v_requirements_total
    FROM core.approval_requirement ar
    WHERE ar.deal_version_id = p_deal_version_id
      AND ar.gate_key = p_gate_key;

    IF v_requirements_total = 0 THEN
        RETURN QUERY SELECT FALSE, 'APPROVAL_REQUIREMENTS_MISSING';
        RETURN;
    END IF;

    SELECT COUNT(*)
    INTO v_unresolved_requirements
    FROM core.approval_requirement ar
    WHERE ar.deal_version_id = p_deal_version_id
      AND ar.gate_key = p_gate_key
      AND COALESCE(ar.requirement_status, 'OPEN') NOT IN ('APPROVED', 'RESOLVED');

    IF v_unresolved_requirements > 0 THEN
        RETURN QUERY SELECT FALSE, 'APPROVAL_REQUIREMENTS_UNRESOLVED';
        RETURN;
    END IF;

    SELECT COUNT(*)
    INTO v_open_envelopes
    FROM core.signwell_envelope se
    WHERE se.deal_version_id = p_deal_version_id
      AND se.gate_key = p_gate_key
      AND COALESCE(se.envelope_status, 'CREATED') NOT IN ('COMPLETED', 'DECLINED', 'VOIDED', 'CANCELLED');

    IF v_open_envelopes > 0 THEN
        RETURN QUERY SELECT FALSE, 'OPEN_ENVELOPE_EXISTS';
        RETURN;
    END IF;

    RETURN QUERY SELECT TRUE, 'ELIGIBLE';
END;
$$;

CREATE OR REPLACE FUNCTION core.assert_send_eligible(
    p_deal_version_id BIGINT,
    p_gate_key TEXT
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_is_eligible BOOLEAN;
    v_reason TEXT;
BEGIN
    SELECT e.is_eligible, e.reason
    INTO v_is_eligible, v_reason
    FROM core.is_send_eligible(p_deal_version_id, p_gate_key) e;

    IF v_is_eligible IS DISTINCT FROM TRUE THEN
        RAISE EXCEPTION 'Send not eligible for deal_version_id % gate %: %', p_deal_version_id, p_gate_key, v_reason;
    END IF;
END;
$$;

CREATE OR REPLACE FUNCTION core.get_signwell_payload(
    p_deal_version_id BIGINT,
    p_gate_key TEXT
)
RETURNS JSONB
LANGUAGE plpgsql
AS $$
DECLARE
    v_deal_business_key TEXT;
    v_deal_subtype_key TEXT;
    v_template_external_id TEXT;
    v_template_version TEXT;
    v_lead_broker_email TEXT;
    v_division_head_email TEXT;
    v_gross_billings NUMERIC(18, 2);
    v_commission_total NUMERIC(18, 2);
    v_field_values JSONB;
    v_strict_fields JSONB;
    v_recipients JSONB := '[]'::JSONB;
    v_map RECORD;
    v_email TEXT;
    v_missing_field_key TEXT;
BEGIN
    SELECT
        d.deal_business_key,
        od.deal_subtype_key,
        e.gross_billings,
        e.commission_total
    INTO
        v_deal_business_key,
        v_deal_subtype_key,
        v_gross_billings,
        v_commission_total
    FROM core.deal_version dv
    JOIN core.deal d
      ON d.deal_id = dv.deal_id
    LEFT JOIN ops.deal_draft od
      ON od.draft_id = dv.submitted_from_draft_id
    LEFT JOIN core.deal_version_economics e
      ON e.deal_version_id = dv.deal_version_id
    WHERE dv.deal_version_id = p_deal_version_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'deal_version_id % not found', p_deal_version_id;
    END IF;

    IF v_deal_subtype_key IS NULL THEN
        RAISE EXCEPTION 'deal_subtype_key cannot be resolved for deal_version_id %', p_deal_version_id;
    END IF;

    SELECT
        st.template_external_id,
        st.template_version
    INTO
        v_template_external_id,
        v_template_version
    FROM config.signwell_template st
    WHERE st.gate_key = p_gate_key
      AND st.deal_subtype_key = v_deal_subtype_key
      AND st.is_active = TRUE
    ORDER BY st.created_at DESC
    LIMIT 1;

    IF v_template_external_id IS NULL THEN
        RAISE EXCEPTION 'No active Signwell template for gate % and subtype %', p_gate_key, v_deal_subtype_key;
    END IF;

    SELECT i.email
    INTO v_lead_broker_email
    FROM core.deal_version_broker b
    JOIN security.identity i
      ON i.identity_id = b.broker_identity_id
    WHERE b.deal_version_id = p_deal_version_id
      AND b.is_lead_broker = TRUE
    ORDER BY b.deal_version_broker_id ASC
    LIMIT 1;

    SELECT i.email
    INTO v_division_head_email
    FROM security.role_assignment ra
    JOIN security.identity i
      ON i.identity_id = ra.identity_id
    WHERE ra.role_key = 'DIVISION_HEAD'
    ORDER BY ra.assigned_at DESC, ra.identity_id DESC
    LIMIT 1;

    v_field_values := jsonb_build_object(
        'deal_business_key', to_jsonb(v_deal_business_key),
        'deal_subtype_key', to_jsonb(v_deal_subtype_key),
        'gross_billings', to_jsonb(v_gross_billings),
        'commission_total', to_jsonb(v_commission_total),
        'lead_broker_email', to_jsonb(v_lead_broker_email),
        'division_head_email', to_jsonb(v_division_head_email)
    );

    SELECT fd.signwell_field_key
    INTO v_missing_field_key
    FROM config.signwell_field_dictionary fd
    WHERE fd.is_required = TRUE
      AND (
            (v_field_values ? fd.signwell_field_key) = FALSE
            OR NULLIF(v_field_values ->> fd.signwell_field_key, '') IS NULL
          )
    ORDER BY fd.signwell_field_key
    LIMIT 1;

    IF v_missing_field_key IS NOT NULL THEN
        RAISE EXCEPTION 'Missing required Signwell payload field: %', v_missing_field_key;
    END IF;

    SELECT jsonb_object_agg(fd.signwell_field_key, v_field_values -> fd.signwell_field_key)
    INTO v_strict_fields
    FROM config.signwell_field_dictionary fd;

    FOR v_map IN
        SELECT
            rm.role_key,
            rm.recipient_order,
            rm.recipient_selector
        FROM config.signwell_recipient_role_map rm
        WHERE rm.gate_key = p_gate_key
        ORDER BY rm.recipient_order ASC, rm.role_key ASC
    LOOP
        IF v_map.recipient_selector = 'ALL_BROKERS' THEN
            FOR v_email IN
                SELECT DISTINCT i.email
                FROM core.deal_version_broker b
                JOIN security.identity i
                  ON i.identity_id = b.broker_identity_id
                WHERE b.deal_version_id = p_deal_version_id
                ORDER BY i.email
            LOOP
                v_recipients := v_recipients || jsonb_build_array(
                    jsonb_build_object(
                        'email', v_email,
                        'role_key', v_map.role_key,
                        'recipient_order', v_map.recipient_order
                    )
                );
            END LOOP;
        ELSIF v_map.recipient_selector = 'LEAD_BROKER_DIVISION_HEAD' THEN
            IF v_division_head_email IS NOT NULL THEN
                v_recipients := v_recipients || jsonb_build_array(
                    jsonb_build_object(
                        'email', v_division_head_email,
                        'role_key', v_map.role_key,
                        'recipient_order', v_map.recipient_order
                    )
                );
            END IF;
        ELSE
            FOR v_email IN
                SELECT DISTINCT i.email
                FROM security.role_assignment ra
                JOIN security.identity i
                  ON i.identity_id = ra.identity_id
                WHERE ra.role_key = v_map.role_key
                ORDER BY i.email
            LOOP
                v_recipients := v_recipients || jsonb_build_array(
                    jsonb_build_object(
                        'email', v_email,
                        'role_key', v_map.role_key,
                        'recipient_order', v_map.recipient_order
                    )
                );
            END LOOP;
        END IF;
    END LOOP;

    IF jsonb_array_length(v_recipients) = 0 THEN
        RAISE EXCEPTION 'No Signwell recipients resolved for gate %', p_gate_key;
    END IF;

    RETURN jsonb_build_object(
        'provider_key', 'SIGNWELL',
        'deal_version_id', p_deal_version_id,
        'gate_key', p_gate_key,
        'template_external_id', v_template_external_id,
        'template_version', v_template_version,
        'fields', v_strict_fields,
        'recipients', v_recipients,
        'generated_at', NOW()
    );
END;
$$;

CREATE OR REPLACE FUNCTION core.ingest_signwell_webhook(
    p_payload JSONB
)
RETURNS VOID
LANGUAGE plpgsql
AS $$
DECLARE
    v_provider_key TEXT := COALESCE(NULLIF(p_payload ->> 'provider_key', ''), 'SIGNWELL');
    v_event_id TEXT := COALESCE(NULLIF(p_payload ->> 'event_id', ''), NULLIF(p_payload #>> '{event,id}', ''));
    v_event_type TEXT := LOWER(COALESCE(NULLIF(p_payload ->> 'event_type', ''), NULLIF(p_payload #>> '{event,type}', ''), 'unknown'));
    v_external_envelope_id TEXT := COALESCE(NULLIF(p_payload ->> 'envelope_id', ''), NULLIF(p_payload #>> '{data,envelope_id}', ''), NULLIF(p_payload #>> '{envelope,id}', ''));
    v_gate_key TEXT := COALESCE(NULLIF(p_payload ->> 'gate_key', ''), NULLIF(p_payload #>> '{data,gate_key}', ''));
    v_actor_email TEXT := LOWER(COALESCE(NULLIF(p_payload ->> 'recipient_email', ''), NULLIF(p_payload #>> '{data,recipient_email}', ''), NULLIF(p_payload #>> '{recipient,email}', '')));
    v_recipient_role_key TEXT := UPPER(COALESCE(NULLIF(p_payload ->> 'recipient_role_key', ''), NULLIF(p_payload #>> '{data,recipient_role_key}', ''), NULLIF(p_payload #>> '{recipient,role_key}', '')));
    v_dedupe_key TEXT := COALESCE(NULLIF(p_payload ->> 'dedupe_key', ''), v_provider_key || ':' || v_event_id);
    v_correlation_id TEXT := COALESCE(NULLIF(p_payload ->> 'correlation_id', ''), NULLIF(p_payload #>> '{meta,correlation_id}', ''));
    v_deal_version_id BIGINT;
    v_envelope_id BIGINT;
    v_existing_gate_key TEXT;
    v_existing_deal_version_id BIGINT;
    v_deal_id BIGINT;
    v_actor_identity_id BIGINT;
    v_envelope_status TEXT;
    v_recipient_status TEXT;
    v_response_key TEXT;
    v_requirement_id BIGINT;
    v_any_declined BOOLEAN := FALSE;
    v_broker_has_rows BOOLEAN := FALSE;
    v_broker_all_signed BOOLEAN := FALSE;
    v_div_head_signed BOOLEAN := FALSE;
BEGIN
    IF v_event_id IS NULL THEN
        RAISE EXCEPTION 'Webhook payload missing event_id';
    END IF;

    v_deal_version_id := CASE
        WHEN COALESCE(NULLIF(p_payload ->> 'deal_version_id', ''), NULLIF(p_payload #>> '{data,deal_version_id}', '')) ~ '^[0-9]+$'
        THEN (COALESCE(NULLIF(p_payload ->> 'deal_version_id', ''), NULLIF(p_payload #>> '{data,deal_version_id}', '')))::BIGINT
        ELSE NULL
    END;

    INSERT INTO audit.webhook_event (
        provider_key,
        event_id,
        event_type,
        deal_version_id,
        dedupe_key,
        webhook_payload,
        process_status,
        correlation_id,
        processed_at
    )
    VALUES (
        v_provider_key,
        v_event_id,
        v_event_type,
        v_deal_version_id,
        v_dedupe_key,
        p_payload,
        'PROCESSED',
        v_correlation_id,
        NOW()
    )
    ON CONFLICT DO NOTHING;

    IF NOT FOUND THEN
        RETURN;
    END IF;

    IF v_external_envelope_id IS NULL THEN
        INSERT INTO audit.event_log (
            event_type,
            correlation_id,
            event_payload
        )
        VALUES (
            'SIGNWELL_WEBHOOK_IGNORED',
            v_correlation_id,
            jsonb_build_object('reason', 'MISSING_ENVELOPE_ID', 'event_id', v_event_id)
        );
        RETURN;
    END IF;

    SELECT
        se.signwell_envelope_id,
        se.deal_version_id,
        se.gate_key
    INTO
        v_envelope_id,
        v_existing_deal_version_id,
        v_existing_gate_key
    FROM core.signwell_envelope se
    WHERE se.external_envelope_id = v_external_envelope_id;

    v_envelope_status := CASE
        WHEN v_event_type LIKE '%declin%' THEN 'DECLINED'
        WHEN v_event_type LIKE '%complete%' THEN 'COMPLETED'
        WHEN v_event_type LIKE '%sent%' THEN 'SENT'
        WHEN v_event_type LIKE '%create%' THEN 'CREATED'
        WHEN v_event_type LIKE '%sign%' THEN 'IN_PROGRESS'
        ELSE UPPER(COALESCE(NULLIF(p_payload ->> 'envelope_status', ''), 'RECEIVED'))
    END;

    IF v_envelope_id IS NULL THEN
        IF v_deal_version_id IS NULL OR v_gate_key IS NULL THEN
            INSERT INTO audit.event_log (
                event_type,
                correlation_id,
                event_payload
            )
            VALUES (
                'SIGNWELL_WEBHOOK_IGNORED',
                v_correlation_id,
                jsonb_build_object('reason', 'MISSING_DEAL_VERSION_OR_GATE', 'event_id', v_event_id, 'envelope_id', v_external_envelope_id)
            );
            RETURN;
        END IF;

        INSERT INTO core.signwell_envelope (
            deal_version_id,
            gate_key,
            external_envelope_id,
            dedupe_key,
            envelope_status,
            sent_at,
            closed_at
        )
        VALUES (
            v_deal_version_id,
            v_gate_key,
            v_external_envelope_id,
            v_dedupe_key,
            v_envelope_status,
            CASE WHEN v_envelope_status IN ('SENT', 'IN_PROGRESS', 'COMPLETED', 'DECLINED') THEN NOW() ELSE NULL END,
            CASE WHEN v_envelope_status IN ('COMPLETED', 'DECLINED') THEN NOW() ELSE NULL END
        )
        RETURNING signwell_envelope_id INTO v_envelope_id;
    ELSE
        v_deal_version_id := v_existing_deal_version_id;
        v_gate_key := v_existing_gate_key;

        UPDATE core.signwell_envelope se
        SET envelope_status = v_envelope_status,
            sent_at = COALESCE(
                se.sent_at,
                CASE WHEN v_envelope_status IN ('SENT', 'IN_PROGRESS', 'COMPLETED', 'DECLINED') THEN NOW() END
            ),
            closed_at = COALESCE(
                se.closed_at,
                CASE WHEN v_envelope_status IN ('COMPLETED', 'DECLINED') THEN NOW() END
            )
        WHERE se.signwell_envelope_id = v_envelope_id;
    END IF;

    SELECT dv.deal_id
    INTO v_deal_id
    FROM core.deal_version dv
    WHERE dv.deal_version_id = v_deal_version_id;

    IF v_deal_id IS NULL THEN
        RETURN;
    END IF;

    IF COALESCE(v_recipient_role_key, '') = '' AND v_gate_key IN ('G1', 'G3') THEN
        v_recipient_role_key := 'FIN_APPROVER';
    END IF;

    v_recipient_status := CASE
        WHEN v_event_type LIKE '%declin%' THEN 'DECLINED'
        WHEN v_event_type LIKE '%sign%' OR v_event_type LIKE '%complete%' THEN 'SIGNED'
        ELSE UPPER(COALESCE(NULLIF(p_payload ->> 'recipient_status', ''), 'PENDING'))
    END;

    IF COALESCE(v_actor_email, '') <> '' THEN
        SELECT i.identity_id
        INTO v_actor_identity_id
        FROM security.identity i
        WHERE LOWER(i.email) = v_actor_email
        LIMIT 1;

        IF v_actor_identity_id IS NULL THEN
            INSERT INTO security.identity (email, display_name)
            VALUES (v_actor_email, 'Signwell Actor')
            RETURNING identity_id INTO v_actor_identity_id;
        END IF;

        IF EXISTS (
            SELECT 1
            FROM core.signwell_envelope_recipient r
            WHERE r.signwell_envelope_id = v_envelope_id
              AND LOWER(r.recipient_email) = v_actor_email
              AND r.recipient_role_key = COALESCE(v_recipient_role_key, r.recipient_role_key)
        ) THEN
            UPDATE core.signwell_envelope_recipient r
            SET recipient_status = v_recipient_status,
                signed_at = CASE WHEN v_recipient_status = 'SIGNED' THEN COALESCE(r.signed_at, NOW()) ELSE r.signed_at END,
                declined_at = CASE WHEN v_recipient_status = 'DECLINED' THEN COALESCE(r.declined_at, NOW()) ELSE r.declined_at END
            WHERE r.signwell_envelope_id = v_envelope_id
              AND LOWER(r.recipient_email) = v_actor_email
              AND r.recipient_role_key = COALESCE(v_recipient_role_key, r.recipient_role_key);
        ELSE
            INSERT INTO core.signwell_envelope_recipient (
                signwell_envelope_id,
                deal_version_id,
                recipient_email,
                recipient_role_key,
                recipient_status,
                signed_at,
                declined_at
            )
            VALUES (
                v_envelope_id,
                v_deal_version_id,
                v_actor_email,
                COALESCE(v_recipient_role_key, 'UNKNOWN'),
                v_recipient_status,
                CASE WHEN v_recipient_status = 'SIGNED' THEN NOW() END,
                CASE WHEN v_recipient_status = 'DECLINED' THEN NOW() END
            );
        END IF;
    END IF;

    IF v_event_type LIKE '%declin%' THEN
        v_response_key := 'REJECTED';
    ELSIF v_event_type LIKE '%sign%' OR v_event_type LIKE '%complete%' THEN
        v_response_key := 'APPROVED';
    ELSE
        v_response_key := NULL;
    END IF;

    IF v_response_key IS NOT NULL AND COALESCE(v_recipient_role_key, '') <> '' THEN
        SELECT ar.approval_requirement_id
        INTO v_requirement_id
        FROM core.approval_requirement ar
        WHERE ar.deal_version_id = v_deal_version_id
          AND ar.gate_key = v_gate_key
          AND ar.required_role_key = v_recipient_role_key
        ORDER BY ar.approval_requirement_id
        LIMIT 1;

        IF v_requirement_id IS NOT NULL THEN
            INSERT INTO core.approval_response (
                approval_requirement_id,
                deal_version_id,
                actor_identity_id,
                response_key,
                response_comment,
                responded_at
            )
            VALUES (
                v_requirement_id,
                v_deal_version_id,
                v_actor_identity_id,
                v_response_key,
                'Ingested from Signwell webhook',
                NOW()
            );

            UPDATE core.approval_requirement ar
            SET requirement_status = CASE
                                        WHEN v_response_key = 'REJECTED' THEN 'REJECTED'
                                        ELSE 'APPROVED'
                                     END,
                resolved_at = NOW()
            WHERE ar.approval_requirement_id = v_requirement_id;
        END IF;
    END IF;

    SELECT EXISTS (
        SELECT 1
        FROM core.signwell_envelope_recipient r
        WHERE r.signwell_envelope_id = v_envelope_id
          AND r.recipient_status = 'DECLINED'
    )
    INTO v_any_declined;

    IF v_any_declined THEN
        UPDATE core.deal_version dv
        SET lifecycle_status = 'REJECTED'
        WHERE dv.deal_version_id = v_deal_version_id;

        UPDATE core.signwell_envelope se
        SET envelope_status = 'DECLINED',
            closed_at = COALESCE(se.closed_at, NOW())
        WHERE se.signwell_envelope_id = v_envelope_id;

        INSERT INTO audit.event_log (
            deal_id,
            deal_version_id,
            event_type,
            gate_key,
            actor_identity_id,
            reason_code,
            correlation_id,
            event_payload
        )
        VALUES (
            v_deal_id,
            v_deal_version_id,
            'GATE_REJECTED',
            v_gate_key,
            v_actor_identity_id,
            CASE WHEN v_gate_key = 'G2' THEN 'G2_DECLINED' ELSE 'FINANCE_REJECTED' END,
            v_correlation_id,
            jsonb_build_object('event_id', v_event_id, 'envelope_id', v_external_envelope_id)
        );

        RETURN;
    END IF;

    IF v_gate_key = 'G1'
       AND v_response_key = 'APPROVED'
       AND COALESCE(v_recipient_role_key, '') = 'FIN_APPROVER' THEN

        UPDATE core.deal_version dv
        SET current_gate_key = 'G2'
        WHERE dv.deal_version_id = v_deal_version_id;

        PERFORM core.materialize_approval_requirements(v_deal_version_id, 'G2', 'DEFAULT_GATES_0_3');

        INSERT INTO audit.event_log (
            deal_id,
            deal_version_id,
            event_type,
            gate_key,
            actor_identity_id,
            correlation_id,
            event_payload
        )
        VALUES (
            v_deal_id,
            v_deal_version_id,
            'G2_ENTERED',
            'G2',
            v_actor_identity_id,
            v_correlation_id,
            jsonb_build_object('event_id', v_event_id, 'envelope_id', v_external_envelope_id)
        );

    ELSIF v_gate_key = 'G2' THEN
        SELECT EXISTS (
            SELECT 1
            FROM core.signwell_envelope_recipient r
            WHERE r.signwell_envelope_id = v_envelope_id
              AND r.recipient_role_key = 'BROKER'
        )
        INTO v_broker_has_rows;

        SELECT COALESCE(BOOL_AND(r.recipient_status = 'SIGNED'), FALSE)
        INTO v_broker_all_signed
        FROM core.signwell_envelope_recipient r
        WHERE r.signwell_envelope_id = v_envelope_id
          AND r.recipient_role_key = 'BROKER';

        SELECT EXISTS (
            SELECT 1
            FROM core.signwell_envelope_recipient r
            WHERE r.signwell_envelope_id = v_envelope_id
              AND r.recipient_role_key = 'DIVISION_HEAD'
              AND r.recipient_status = 'SIGNED'
        )
        INTO v_div_head_signed;

        IF v_broker_has_rows AND v_broker_all_signed THEN
            UPDATE core.approval_requirement ar
            SET requirement_status = 'APPROVED',
                resolved_at = COALESCE(ar.resolved_at, NOW())
            WHERE ar.deal_version_id = v_deal_version_id
              AND ar.gate_key = 'G2'
              AND ar.required_role_key = 'BROKER';
        END IF;

        IF v_div_head_signed THEN
            UPDATE core.approval_requirement ar
            SET requirement_status = 'APPROVED',
                resolved_at = COALESCE(ar.resolved_at, NOW())
            WHERE ar.deal_version_id = v_deal_version_id
              AND ar.gate_key = 'G2'
              AND ar.required_role_key = 'DIVISION_HEAD';
        END IF;

        IF v_broker_has_rows AND v_broker_all_signed AND v_div_head_signed THEN
            UPDATE core.deal_version dv
            SET current_gate_key = 'G3'
            WHERE dv.deal_version_id = v_deal_version_id;

            UPDATE core.signwell_envelope se
            SET envelope_status = 'COMPLETED',
                closed_at = COALESCE(se.closed_at, NOW())
            WHERE se.signwell_envelope_id = v_envelope_id;

            PERFORM core.materialize_approval_requirements(v_deal_version_id, 'G3', 'DEFAULT_GATES_0_3');

            INSERT INTO audit.event_log (
                deal_id,
                deal_version_id,
                event_type,
                gate_key,
                actor_identity_id,
                correlation_id,
                event_payload
            )
            VALUES (
                v_deal_id,
                v_deal_version_id,
                'G3_ENTERED',
                'G3',
                v_actor_identity_id,
                v_correlation_id,
                jsonb_build_object('event_id', v_event_id, 'envelope_id', v_external_envelope_id)
            );
        END IF;

    ELSIF v_gate_key = 'G3'
          AND v_response_key = 'APPROVED'
          AND COALESCE(v_recipient_role_key, '') = 'FIN_APPROVER' THEN

        UPDATE core.deal_version dv
        SET current_gate_key = 'G4',
            lifecycle_status = 'READY_FOR_XERO'
        WHERE dv.deal_version_id = v_deal_version_id;

        UPDATE core.signwell_envelope se
        SET envelope_status = 'COMPLETED',
            closed_at = COALESCE(se.closed_at, NOW())
        WHERE se.signwell_envelope_id = v_envelope_id;

        INSERT INTO audit.event_log (
            deal_id,
            deal_version_id,
            event_type,
            gate_key,
            actor_identity_id,
            correlation_id,
            event_payload
        )
        VALUES (
            v_deal_id,
            v_deal_version_id,
            'G3_COMPLETED',
            'G3',
            v_actor_identity_id,
            v_correlation_id,
            jsonb_build_object('event_id', v_event_id, 'envelope_id', v_external_envelope_id)
        );
    END IF;

    IF p_payload ? 'signed_pdf_url' THEN
        IF NOT EXISTS (
            SELECT 1
            FROM core.signwell_document_artifact a
            WHERE a.signwell_envelope_id = v_envelope_id
              AND a.artifact_type = 'SIGNED_PDF'
              AND a.artifact_reference = p_payload ->> 'signed_pdf_url'
        ) THEN
            INSERT INTO core.signwell_document_artifact (
                signwell_envelope_id,
                deal_version_id,
                artifact_type,
                artifact_reference,
                checksum_sha256
            )
            VALUES (
                v_envelope_id,
                v_deal_version_id,
                'SIGNED_PDF',
                p_payload ->> 'signed_pdf_url',
                NULLIF(p_payload ->> 'checksum_sha256', '')
            );
        END IF;
    END IF;

    INSERT INTO audit.event_log (
        deal_id,
        deal_version_id,
        event_type,
        gate_key,
        actor_identity_id,
        correlation_id,
        event_payload
    )
    VALUES (
        v_deal_id,
        v_deal_version_id,
        'SIGNWELL_WEBHOOK_INGESTED',
        v_gate_key,
        v_actor_identity_id,
        v_correlation_id,
        jsonb_build_object('event_id', v_event_id, 'event_type', v_event_type, 'envelope_id', v_external_envelope_id)
    );
END;
$$;

COMMIT;
