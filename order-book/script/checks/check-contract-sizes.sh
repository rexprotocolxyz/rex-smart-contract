#!/usr/bin/env bash
set -euo pipefail

script_directory="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
project_directory="$(cd "${script_directory}/../.." && pwd -P)"
temporary_directory="$(mktemp -d)"
trap 'rm -rf "$temporary_directory"' EXIT

cd "$project_directory"

# Coverage uses different compiler settings and shares Foundry's default cache. Compile into isolated directories and
# force a fresh production-profile build so the size report can never reuse incomplete coverage artifacts.
FOUNDRY_PROFILE=production forge build contracts \
  --sizes \
  --force \
  --out "${temporary_directory}/out" \
  --cache-path "${temporary_directory}/cache" \
  --json >"${temporary_directory}/contract-sizes.json"

bash "${script_directory}/validate-contract-sizes.sh" "${temporary_directory}/contract-sizes.json"
