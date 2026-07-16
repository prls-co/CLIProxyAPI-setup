#!/usr/bin/env bash
# TEST-001
set -euo pipefail
export LC_ALL=C

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$root"

required_paths=(
  Makefile
  README.md
  scripts/README.md
  tests/README.md
  artifacts/.gitkeep
  state/.gitignore
  backups/.gitignore
)

failed=0
for path in "${required_paths[@]}"; do
  if [[ ! -f "$path" ]]; then
    printf 'missing required file: %s\n' "$path" >&2
    failed=1
  fi
done

if [[ -f Makefile ]]; then
  required_targets=(test-static test-unit test-security test-local test-contract test-observability test-public eval verify)
  for target in "${required_targets[@]}"; do
    if ! grep -Eq "^${target}:" Makefile; then
      printf 'missing Make target: %s\n' "$target" >&2
      failed=1
    fi
  done
fi

while IFS= read -r file; do
  case "$file" in
    tests/eval/*)
      grep -Eq '^# EVAL-[0-9]{3}$' "$file" || {
        printf 'missing EVAL traceability tag: %s\n' "$file" >&2
        failed=1
      }
      ;;
    tests/*.sh|tests/*/*.sh)
      grep -Eq '^# TEST-[0-9]{3}$' "$file" || {
        printf 'missing TEST traceability tag: %s\n' "$file" >&2
        failed=1
      }
      ;;
  esac
done < <(find tests -type f -name '*.sh' | sort)

if (( failed != 0 )); then
  exit 1
fi

printf 'repository contract: ok\n'
