#!/usr/bin/env bash
set -euo pipefail
ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$ROOT_DIR"

fail=0
for path in config.env .bastion.env cluster install-config.yaml.backup pull-secret.txt; do
  if [[ -e "$path" ]]; then
    echo "ERROR: local/generated file must not be committed: $path" >&2
    fail=1
  fi
done

scan_files=()
while IFS= read -r -d '' file; do scan_files+=("$file"); done < <(
  find . -type f \
    ! -path './.git/*' \
    ! -name 'check-upstream-safe.sh' \
    ! -name '*.zip' -print0
)

if (( ${#scan_files[@]} > 0 )); then
  if grep -nHE 'AKIA[0-9A-Z]{16}|ASIA[0-9A-Z]{16}|-----BEGIN (RSA |EC |OPENSSH )?PRIVATE KEY-----' "${scan_files[@]}"; then
    echo "ERROR: credential/private-key pattern detected." >&2
    fail=1
  fi

  # Detect concrete AWS resource/account identifiers. Placeholder/example files should use blanks.
  if grep -nHE '(^|[^0-9])[0-9]{12}([^0-9]|$)|vpc-[0-9a-f]{8,}|subnet-[0-9a-f]{8,}|sg-[0-9a-f]{8,}' "${scan_files[@]}"; then
    echo "ERROR: concrete AWS account/resource identifier detected." >&2
    fail=1
  fi
fi

if (( fail != 0 )); then
  exit 1
fi

echo "PASS: repository contains no obvious local deployment state or credential/account identifiers."
