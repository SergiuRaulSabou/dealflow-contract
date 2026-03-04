BEGIN;

-- ---------------------------------------------------------------------------
-- Milestone 5: hardening, RLS boundaries, and permission model
-- ---------------------------------------------------------------------------

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

CREATE OR REPLACE FUNCTION security.current_identity_id()
RETURNS BIGINT
LANGUAGE plpgsql
STABLE
AS $$
DECLARE
    v_identity_text TEXT;
BEGIN
    v_identity_text := current_setting('xero.current_identity_id', TRUE);
    IF v_identity_text IS NULL OR btrim(v_identity_text) = '' THEN
        RETURN NULL;
    END IF;

    IF v_identity_text !~ '^[0-9]+$' THEN
        RAISE EXCEPTION 'xero.current_identity_id must be numeric; got %', v_identity_text;
    END IF;

    RETURN v_identity_text::BIGINT;
END;
$$;

CREATE OR REPLACE FUNCTION security.set_current_identity(p_identity_id BIGINT)
RETURNS VOID
LANGUAGE plpgsql
AS $$
BEGIN
    IF p_identity_id IS NULL THEN
        PERFORM set_config('xero.current_identity_id', '', FALSE);
    ELSE
        PERFORM set_config('xero.current_identity_id', p_identity_id::TEXT, FALSE);
    END IF;
END;
$$;

-- Restrict broad defaults first.
REVOKE ALL ON SCHEMA raw FROM PUBLIC;
REVOKE ALL ON SCHEMA ops FROM PUBLIC;
REVOKE ALL ON SCHEMA core FROM PUBLIC;
REVOKE ALL ON SCHEMA audit FROM PUBLIC;
REVOKE ALL ON SCHEMA config FROM PUBLIC;
REVOKE ALL ON SCHEMA security FROM PUBLIC;

REVOKE ALL ON ALL TABLES IN SCHEMA raw FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA ops FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA audit FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA config FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA security FROM PUBLIC;

REVOKE ALL ON ALL SEQUENCES IN SCHEMA raw FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA ops FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA audit FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA config FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA security FROM PUBLIC;

REVOKE ALL ON ALL FUNCTIONS IN SCHEMA raw FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA ops FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA core FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA audit FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA config FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA security FROM PUBLIC;

GRANT USAGE ON SCHEMA raw, ops, core, audit, config, security TO app_ops, app_finance, app_broker, app_ui, app_system;

-- app_ops: can work in ops workspace only, not direct core writes.
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA ops TO app_ops;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA ops TO app_ops;
GRANT SELECT ON security.identity, security.role_assignment TO app_ops;

-- app_finance: read-only on core/config surfaces + function-executed state changes.
GRANT SELECT ON ALL TABLES IN SCHEMA core TO app_finance;
GRANT SELECT ON audit.event_log, audit.webhook_event, audit.workflow_run, audit.deal_version_diff TO app_finance;

-- app_broker: constrained read on core via RLS.
GRANT SELECT ON core.deal_version TO app_broker;
GRANT SELECT ON core.deal_version_broker TO app_broker;
GRANT SELECT ON core.approval_requirement TO app_broker;
GRANT SELECT ON core.signwell_envelope TO app_broker;
GRANT SELECT ON core.signwell_envelope_recipient TO app_broker;

-- app_ui: read through stable views/functions only.
GRANT SELECT ON config.v_deal_types TO app_ui;
GRANT SELECT ON config.v_role_catalogue TO app_ui;
GRANT SELECT ON config.v_broker_directory TO app_ui;

-- app_system: no direct writes required; executes contract functions.
GRANT SELECT ON ALL TABLES IN SCHEMA core TO app_system;
GRANT SELECT ON ALL TABLES IN SCHEMA audit TO app_system;
GRANT SELECT ON ALL TABLES IN SCHEMA config TO app_system;
GRANT SELECT ON security.identity, security.role_assignment TO app_system;

-- Secure key contract functions as SECURITY DEFINER so app roles can execute
-- without direct write privileges on protected schemas.
ALTER FUNCTION ops.promote_draft_to_core(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION ops.preview_draft(BIGINT) SECURITY DEFINER;
ALTER FUNCTION ops.create_draft_from_deal_version(BIGINT, BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION core.materialize_approval_requirements(BIGINT, TEXT, TEXT) SECURITY DEFINER;
ALTER FUNCTION core.is_send_eligible(BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION core.assert_send_eligible(BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION core.get_signwell_payload(BIGINT, TEXT) SECURITY DEFINER;
ALTER FUNCTION core.record_signwell_envelope(BIGINT, TEXT, TEXT, TEXT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION core.ingest_signwell_webhook(JSONB) SECURITY DEFINER;
ALTER FUNCTION core.record_gate_decision(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT) SECURITY DEFINER;
ALTER FUNCTION core.get_xero_payload(BIGINT) SECURITY DEFINER;
ALTER FUNCTION core.lock_xero_payload(BIGINT, BIGINT) SECURITY DEFINER;
ALTER FUNCTION config.v_doc_requirements(TEXT) SECURITY DEFINER;
ALTER FUNCTION config.v_commission_rules(TEXT) SECURITY DEFINER;
ALTER FUNCTION security.current_identity_id() SECURITY DEFINER;
ALTER FUNCTION security.set_current_identity(BIGINT) SECURITY DEFINER;

ALTER FUNCTION ops.promote_draft_to_core(BIGINT, BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION ops.preview_draft(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION ops.create_draft_from_deal_version(BIGINT, BIGINT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION core.materialize_approval_requirements(BIGINT, TEXT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION core.is_send_eligible(BIGINT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION core.assert_send_eligible(BIGINT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION core.get_signwell_payload(BIGINT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION core.record_signwell_envelope(BIGINT, TEXT, TEXT, TEXT, BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION core.ingest_signwell_webhook(JSONB)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION core.record_gate_decision(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION core.get_xero_payload(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION core.lock_xero_payload(BIGINT, BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION config.v_doc_requirements(TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION config.v_commission_rules(TEXT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION security.current_identity_id()
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;
ALTER FUNCTION security.set_current_identity(BIGINT)
    SET search_path = pg_catalog, raw, ops, core, audit, config, security, public;

-- Function execution grants.
GRANT EXECUTE ON FUNCTION ops.promote_draft_to_core(BIGINT, BIGINT) TO app_ops;
GRANT EXECUTE ON FUNCTION ops.preview_draft(BIGINT) TO app_ops, app_ui;
GRANT EXECUTE ON FUNCTION ops.create_draft_from_deal_version(BIGINT, BIGINT, TEXT) TO app_ops;

GRANT EXECUTE ON FUNCTION core.record_gate_decision(BIGINT, TEXT, TEXT, BIGINT, TEXT, TEXT, TEXT) TO app_finance, app_system;
GRANT EXECUTE ON FUNCTION core.is_send_eligible(BIGINT, TEXT) TO app_finance, app_system;
GRANT EXECUTE ON FUNCTION core.assert_send_eligible(BIGINT, TEXT) TO app_finance, app_system;
GRANT EXECUTE ON FUNCTION core.get_signwell_payload(BIGINT, TEXT) TO app_finance, app_system;
GRANT EXECUTE ON FUNCTION core.record_signwell_envelope(BIGINT, TEXT, TEXT, TEXT, BIGINT) TO app_system;
GRANT EXECUTE ON FUNCTION core.ingest_signwell_webhook(JSONB) TO app_system;
GRANT EXECUTE ON FUNCTION core.get_xero_payload(BIGINT) TO app_finance, app_system;
GRANT EXECUTE ON FUNCTION core.lock_xero_payload(BIGINT, BIGINT) TO app_finance, app_system;

GRANT EXECUTE ON FUNCTION config.v_doc_requirements(TEXT) TO app_ui, app_ops, app_finance;
GRANT EXECUTE ON FUNCTION config.v_commission_rules(TEXT) TO app_ui, app_ops, app_finance;
GRANT EXECUTE ON FUNCTION security.current_identity_id() TO app_broker, app_ops, app_finance, app_system, app_ui;
GRANT EXECUTE ON FUNCTION security.set_current_identity(BIGINT) TO app_broker, app_ops, app_finance, app_system, app_ui;

-- Explicitly block app_ui from direct config table access.
REVOKE ALL ON ALL TABLES IN SCHEMA config FROM app_ui;
GRANT SELECT ON config.v_deal_types TO app_ui;
GRANT SELECT ON config.v_role_catalogue TO app_ui;
GRANT SELECT ON config.v_broker_directory TO app_ui;

-- RLS: broker can only see own deal/task scope.
ALTER TABLE core.deal_version ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.approval_requirement ENABLE ROW LEVEL SECURITY;
ALTER TABLE core.signwell_envelope ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS p_core_deal_version_broker_select ON core.deal_version;
DROP POLICY IF EXISTS p_core_deal_version_internal_select ON core.deal_version;
DROP POLICY IF EXISTS p_core_approval_requirement_broker_select ON core.approval_requirement;
DROP POLICY IF EXISTS p_core_approval_requirement_internal_select ON core.approval_requirement;
DROP POLICY IF EXISTS p_core_signwell_envelope_broker_select ON core.signwell_envelope;
DROP POLICY IF EXISTS p_core_signwell_envelope_internal_select ON core.signwell_envelope;

CREATE POLICY p_core_deal_version_broker_select
ON core.deal_version
FOR SELECT
TO app_broker
USING (
    EXISTS (
        SELECT 1
        FROM core.deal_version_broker b
        WHERE b.deal_version_id = core.deal_version.deal_version_id
          AND b.broker_identity_id = security.current_identity_id()
    )
);

CREATE POLICY p_core_deal_version_internal_select
ON core.deal_version
FOR SELECT
TO app_ops, app_finance, app_system
USING (TRUE);

CREATE POLICY p_core_approval_requirement_broker_select
ON core.approval_requirement
FOR SELECT
TO app_broker
USING (
    EXISTS (
        SELECT 1
        FROM core.deal_version_broker b
        WHERE b.deal_version_id = core.approval_requirement.deal_version_id
          AND b.broker_identity_id = security.current_identity_id()
    )
);

CREATE POLICY p_core_approval_requirement_internal_select
ON core.approval_requirement
FOR SELECT
TO app_ops, app_finance, app_system
USING (TRUE);

CREATE POLICY p_core_signwell_envelope_broker_select
ON core.signwell_envelope
FOR SELECT
TO app_broker
USING (
    EXISTS (
        SELECT 1
        FROM core.deal_version_broker b
        WHERE b.deal_version_id = core.signwell_envelope.deal_version_id
          AND b.broker_identity_id = security.current_identity_id()
    )
);

CREATE POLICY p_core_signwell_envelope_internal_select
ON core.signwell_envelope
FOR SELECT
TO app_ops, app_finance, app_system
USING (TRUE);

COMMIT;
