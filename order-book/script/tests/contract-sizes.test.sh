#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

fail() {
  echo "contract-size test failed: $*" >&2
  exit 1
}

expect_failure() {
  local expected_message="$1"
  shift
  local output
  if output="$("$@" 2>&1)"; then
    fail "command unexpectedly succeeded: $*"
  fi
  if [[ "$output" != *"$expected_message"* ]]; then
    fail "expected '${expected_message}', got: ${output}"
  fi
}

valid_report="${temporary_directory}/valid.json"
jq -n '
  {
    BPSOrderBookFeeController: {
      runtime_size: 10471, init_size: 12055, runtime_margin: 14105, init_margin: 37097
    },
    OrderBookDeployer: {
      runtime_size: 20939, init_size: 20967, runtime_margin: 3637, init_margin: 28185
    },
    OrderBookFactory: {
      runtime_size: 6160, init_size: 28953, runtime_margin: 18416, init_margin: 20199
    },
    OrderBookWithFeeController: {
      runtime_size: 18349, init_size: 20500, runtime_margin: 6227, init_margin: 28652
    }
  }
' >"$valid_report"

bash "${script_directory}/checks/validate-contract-sizes.sh" "$valid_report" >/dev/null

missing_report="${temporary_directory}/missing.json"
jq 'del(.OrderBookDeployer)' "$valid_report" >"$missing_report"
expect_failure "missing required deployable" \
  bash "${script_directory}/checks/validate-contract-sizes.sh" "$missing_report"

oversized_report="${temporary_directory}/oversized.json"
jq '.OrderBookDeployer.runtime_size = 24577 | .OrderBookDeployer.runtime_margin = -1' \
  "$valid_report" >"$oversized_report"
expect_failure "exceeds an EVM deployment-size limit" \
  bash "${script_directory}/checks/validate-contract-sizes.sh" "$oversized_report"

invalid_report="${temporary_directory}/invalid.json"
jq '.OrderBookFactory.runtime_size = "6160"' "$valid_report" >"$invalid_report"
expect_failure "invalid size data" \
  bash "${script_directory}/checks/validate-contract-sizes.sh" "$invalid_report"

echo "contract-size tests passed"
