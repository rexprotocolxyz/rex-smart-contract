#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "usage: $0 <forge-size-report.json>" >&2
  exit 64
fi

size_report="$1"
if [[ ! -s "$size_report" || -L "$size_report" ]]; then
  echo "size report must be a nonempty regular file, not a symlink: ${size_report}" >&2
  exit 66
fi
if ! jq -e 'type == "object"' "$size_report" >/dev/null; then
  echo "invalid Forge size report: ${size_report}" >&2
  exit 65
fi

required_deployables=(
  BPSOrderBookFeeController
  OrderBookDeployer
  OrderBookFactory
  OrderBookWithFeeController
)

printf '%-32s %12s %12s %12s %12s\n' \
  "Contract" "Runtime (B)" "Runtime free" "Initcode (B)" "Initcode free"
for contract_name in "${required_deployables[@]}"; do
  if ! jq -e --arg contract_name "$contract_name" 'has($contract_name)' "$size_report" >/dev/null; then
    echo "missing required deployable from Forge size report: ${contract_name}" >&2
    exit 65
  fi
  if ! jq -e \
    --arg contract_name "$contract_name" \
    '
      .[$contract_name]
      | (.runtime_size | type == "number" and . == floor and . > 0)
        and (.init_size | type == "number" and . == floor and . > 0)
        and (.runtime_margin | type == "number" and . == floor)
        and (.init_margin | type == "number" and . == floor)
        and (.runtime_size + .runtime_margin == 24576)
        and (.init_size + .init_margin == 49152)
    ' "$size_report" >/dev/null; then
    echo "invalid size data for required deployable: ${contract_name}" >&2
    exit 65
  fi
  if ! jq -e \
    --arg contract_name "$contract_name" \
    '.[$contract_name] | .runtime_margin >= 0 and .init_margin >= 0' \
    "$size_report" >/dev/null; then
    echo "required deployable exceeds an EVM deployment-size limit: ${contract_name}" >&2
    exit 65
  fi

  IFS=$'\t' read -r runtime_size runtime_margin init_size init_margin < <(
    jq -r \
      --arg contract_name "$contract_name" \
      '.[$contract_name] | [.runtime_size, .runtime_margin, .init_size, .init_margin] | @tsv' \
      "$size_report"
  )
  printf '%-32s %12s %12s %12s %12s\n' \
    "$contract_name" "$runtime_size" "$runtime_margin" "$init_size" "$init_margin"
done
