#!/usr/bin/env bash
# Spec-as-code for remote version_ge / already-on-target policy.
# Run: bash tests/test-nginx-version-verify.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="${ROOT}/remote-update-nginx.sh"

# Load version_ge from the product script (single source of truth).
# shellcheck disable=SC1090
eval "$(sed -n '/^version_ge()/,/^}/p' "$SRC")"

fail=0
assert_ge() {
  local a="$1" b="$2" expect="$3" label="$4"
  local got=no
  if version_ge "$a" "$b"; then got=yes; fi
  if [[ "$got" == "$expect" ]]; then
    echo "OK  $label ($a >= $b -> $got)"
  else
    echo "FAIL $label ($a >= $b -> $got, want $expect)" >&2
    fail=1
  fi
}

# installed >= target -> keep (no downgrade)
assert_ge 1.30.6 1.30.6 yes "equal"
assert_ge 1.30.7 1.30.6 yes "greater patch"
assert_ge 1.31.0 1.30.6 yes "greater minor"
# installed < target -> needs upgrade
assert_ge 1.28.0 1.30.6 no "lower minor"
assert_ge 1.9.0 1.30.6 no "numeric order (not string)"
assert_ge 1.1.0 1.30.6 no "numeric order (not string)"

if [[ "$fail" -ne 0 ]]; then
  echo "Some version_ge cases failed." >&2
  exit 1
fi
echo "All version_ge cases passed."
exit 0
