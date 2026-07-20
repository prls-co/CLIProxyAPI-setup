SHELL := /usr/bin/env bash
.DEFAULT_GOAL := verify

.PHONY: test-static test-unit test-security test-local test-contract test-observability test-public eval verify

test-static:
	@bash tests/static/test_repository_contract.sh
	@bash tests/static/test_compose_contract.sh
	@bash tests/static/test_login_contract.sh
	@bash tests/static/systemd_contract.sh

test-unit:
	@bash tests/unit/public_edge_config.sh

test-security:
	@bash tests/security/secret_hygiene.sh
	@CPA_BASE_URL=http://127.0.0.1:8317 CPAMP_BASE_URL=http://127.0.0.1:18317 bash tests/security/error_redaction.sh

test-local:
	@CPA_BASE_URL=http://127.0.0.1:8317 CPA_API_KEY_FILE=state/secrets/cpa-api-key MODEL=gpt-5.4-mini bash tests/integration/cpa_auth_models.sh
	@bash tests/integration/backup_restore.sh
	@bash tests/integration/restart_persistence.sh

test-contract:
	@CPA_BASE_URL=http://127.0.0.1:8317 CPA_API_KEY_FILE=state/secrets/cpa-api-key MODEL=gpt-5.4-mini bash tests/contract/responses_contract.sh

test-observability:
	@CPAMP_BASE_URL=http://127.0.0.1:18317 CPAMP_ADMIN_KEY_FILE=state/secrets/cpamp-admin-key CPA_BASE_URL=http://127.0.0.1:8317 CPA_API_KEY_FILE=state/secrets/cpa-api-key bash tests/integration/cpamp_collection.sh

test-public:
	@PUBLIC_BASE_URL=https://cpa.prls.co/v1 PUBLIC_API_KEY_FILE=state/secrets/cpa-api-key MODEL=gpt-5.4-mini bash tests/e2e/public_contract.sh
	@bash tests/e2e/public_dashboard.sh
	@node tests/e2e/utility_llm_shaman.js

eval:
	@bash tests/eval/harness_reproducibility.sh
	@bash tests/eval/compose_reproducibility.sh
	@CPA_BASE_URL=http://127.0.0.1:8317 CPA_API_KEY_FILE=state/secrets/cpa-api-key MODEL=gpt-5.4-mini bash tests/eval/responses_reliability.sh
	@CPAMP_BASE_URL=http://127.0.0.1:18317 CPAMP_ADMIN_KEY_FILE=state/secrets/cpamp-admin-key CPA_BASE_URL=http://127.0.0.1:8317 CPA_API_KEY_FILE=state/secrets/cpa-api-key bash tests/eval/cpamp_collection_lag.sh
	@bash tests/eval/recovery_rehearsal.sh

verify: test-static test-unit test-security test-local test-contract test-observability
