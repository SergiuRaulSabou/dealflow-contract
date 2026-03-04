# Contract Surfaces

## Ops Surfaces
- `ops.preview_draft(draft_id)`
- `ops.promote_draft_to_core(draft_id, submitted_by_identity_id)`
- `ops.create_draft_from_deal_version(source_deal_version_id, created_by_identity_id, new_business_key)`

## Core Approval / Gate Surfaces
- `core.record_gate_decision(...)`
- `core.materialize_approval_requirements(...)`

## Signwell Surfaces
- `core.is_send_eligible(deal_version_id, gate_key)`
- `core.assert_send_eligible(deal_version_id, gate_key)`
- `core.get_signwell_payload(deal_version_id, gate_key)`
- `core.record_signwell_envelope(...)`
- `core.ingest_signwell_webhook(payload_jsonb)`

## Xero Preparation Surfaces
- `core.get_xero_payload(deal_version_id)`
- `core.lock_xero_payload(deal_version_id, actor_identity_id)`

## Operational UI Surfaces
- `core.v_deal_tracker`
- `core.get_task_list(identity_id)`
- `core.v_finance_review_summary`
- `core.get_payload_bundle(deal_version_id, gate_key)`

## Stable UI Lookup Surfaces
- `config.v_deal_types`
- `config.v_role_catalogue`
- `config.v_broker_directory`
- `config.v_doc_requirements(deal_type_key)`
- `config.v_commission_rules(deal_type_key)`

## Compatibility Scaffolds
- Compatibility tables from the schema-definition sheets are materialized in:
  - `config.*` (`deal_type`, `deal_type_variant`, `field_dictionary`, `deal_type_field_rule`, `party_role`, `party_role_rule`, `broker_role`, `commission_band`, `economics_rule_set`, `economics_rule`, `invoice_plan_template`, `invoice_plan_rule`, `deal_type_gate_rule`, `doc_category`, `doc_checklist_item`, `deal_type_doc_checklist_rule`, `approval_role`, `deal_type_approval_matrix`, `org_unit`, `org_position`, `role_permission`, `signwell_field_map`, `webhook_source`, `validation_rule`, `environment_setting`, `audit_event_type`)
  - `core.*` (`deal_version_property`, `deal_version_invoice_plan`, `deal_version_document`, `deal_version_gate`)
  - `raw.*` (`invoice`, `deal_attributes`, `document_flags`, `invoice_commission_allocation`, `invoice_commission_provision`, `ref_person`, `ref_cost_center`)
