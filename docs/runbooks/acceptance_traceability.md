# Acceptance Traceability Matrix

This matrix maps Appendix A scenarios to concrete repository artifacts and repeatable verification commands.

| Scenario | Requirement Summary | Implementation Artifact(s) | Verification Evidence |
|---|---|---|---|
| 1 | Draft preview (validation + deterministic economics preview) | `db/migrations/V005__milestone4_regression_contract_extensions.sql` (`ops.preview_draft`) | `db/verify/milestone4_verify.sql` (Scenario 1) via `make verify_4` |
| 2 | Promotion success path | `ops.promote_draft_to_core` (`V005`) | `db/verify/milestone4_verify.sql` (Scenario 2) |
| 3 | Promotion failure on mandatory docs | `ops.promote_draft_to_core` validation writes `ops.validation_result` | `db/verify/milestone4_verify.sql` (Scenario 3) |
| 4 | Promotion failure on economics integrity | `ops.promote_draft_to_core` economics checks | `db/verify/milestone4_verify.sql` (Scenario 4) |
| 5 | Gate 1 approve path | `core.record_gate_decision` (`V005`) | `db/verify/milestone4_verify.sql` (Scenario 5) |
| 6 | Gate 1 reject/change request path | `core.record_gate_decision` reject/change logic | `db/verify/milestone4_verify.sql` (Scenario 6) |
| 7 | Resubmission inheritance (no re-capture) | `ops.create_draft_from_deal_version` (`V005`) | `db/verify/milestone4_verify.sql` (Scenario 7) |
| 8 | Signwell payload determinism | `core.get_signwell_payload` (`V005`) | `db/verify/milestone4_verify.sql` (Scenario 8) |
| 9 | n8n outbound send (glue only) | `core.is_send_eligible`, `core.get_signwell_payload`, `core.record_signwell_envelope`; `docs/n8n/signwell_outbound_workflow.json` | `db/verify/milestone4_verify.sql` (Scenario 9) + runbook node mapping in `docs/runbooks/runbook.md` |
| 10 | Webhook ingest idempotency (replay safe) | `core.ingest_signwell_webhook` (`V004`/`V005`) | `db/verify/milestone4_verify.sql` (Scenario 10) |
| 11 | Signwell reject/change-request path | `core.ingest_signwell_webhook`, lifecycle transition logic | `db/verify/milestone4_verify.sql` (Scenario 11) |
| 12 | Gate 3 Xero payload + lock | `core.get_xero_payload`, `core.lock_xero_payload` (`V005`) | `db/verify/milestone4_verify.sql` (Scenario 12) |
| 13 | RLS and permission negative tests | `db/migrations/V006__milestone5_hardening_security_permissions.sql` | `db/verify/milestone5_verify.sql` |
| 14 | Orchestration readiness (n8n-compatible) | `docs/n8n/signwell_outbound_workflow.json`, `docs/n8n/signwell_inbound_workflow.json`, `docs/runbooks/runbook.md`, `docs/runbooks/n8n_contract_test_calls.sh` | `bash docs/runbooks/n8n_contract_test_calls.sh` + `make verify_3`/`make verify_4` |
| 15 | UI lookup surfaces contract | `config.v_deal_types`, `config.v_role_catalogue`, `config.v_doc_requirements`, `config.v_commission_rules`, `config.v_broker_directory` | `db/verify/milestone4_verify.sql` (Scenario 15) |

## Additional Gap-Closure Proof
- New UI operational read models and payload retrieval surfaces:
  - `core.v_deal_tracker`
  - `core.get_task_list(identity_id)`
  - `core.v_finance_review_summary`
  - `core.get_payload_bundle(deal_version_id, gate_key)`
- Verification:
  - `db/verify/docs_gap_closure_verify.sql`
  - Command: `make verify_gap`

## Run Order (Clean, Deterministic)
1. `make reset` (full pack)
2. `make verify_gap` (post-milestone gap closure)
3. Optional n8n call proof: `DEAL_VERSION_ID=<id> bash docs/runbooks/n8n_contract_test_calls.sh`
