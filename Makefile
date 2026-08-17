SHELL := /usr/bin/env bash
.DEFAULT_GOAL := verify

.PHONY: test-static test-unit test-security test-local test-contract test-observability test-public eval verify

test-static:
	@bash tests/static/test_repository_contract.sh
	@bash tests/static/test_compose_contract.sh
	@bash tests/static/test_login_contract.sh
	@bash tests/static/bootstrap_contract.sh
	@bash tests/static/restore_contract.sh
	@bash tests/static/systemd_contract.sh
	@bash tests/static/switch_current_machine_contract.sh

test-unit:
	@bash tests/unit/public_edge_config.sh

test-security:
	@bash tests/security/secret_hygiene.sh
	@bash tests/security/error_redaction.sh

test-local:
	@bash tests/integration/cpa_auth_models.sh
	@bash tests/integration/backup_restore.sh
	@bash tests/integration/restart_persistence.sh

test-contract:
	@bash tests/contract/responses_contract.sh

test-observability:
	@bash tests/integration/cpamp_collection.sh

test-public:
	@bash tests/e2e/public_contract.sh
	@bash tests/e2e/public_dashboard.sh
	@node tests/e2e/utility_llm_shaman.js

eval:
	@bash tests/eval/harness_reproducibility.sh
	@bash tests/eval/compose_reproducibility.sh
	@bash tests/eval/responses_reliability.sh
	@bash tests/eval/cpamp_collection_lag.sh
	@bash tests/eval/recovery_rehearsal.sh

verify: test-static test-unit test-security test-local test-contract test-observability
