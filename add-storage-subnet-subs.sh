#!/usr/bin/env bash
#
# Runs add-storage-subnet-all.sh for every subscription listed in a CSV file.
#
# Usage:
#   ./add-storage-subnet-subs.sh -f <subscriptions.csv> -r <reference-subnet-id> -n <new-subnet-id> [-g <resource-group>] [-d]
#
#   -f  CSV file listing the subscriptions to process (see format below)
#   -r  Full resource ID of the subnet that must already be allowed
#   -n  Full resource ID of the subnet to add
#   -g  Optional: only process accounts in this resource group, in every subscription
#   -d  Dry run, passed through to add-storage-subnet-all.sh
#
# CSV format: one subscription per line, name or ID. A header line
# "subscription" is optional. Blank lines and lines starting with # are ignored.
#
#   subscription
#   my-dev-sub
#   00000000-0000-0000-0000-000000000000
#
# Requires the Azure CLI (az), logged in with `az login`.
# The original subscription is restored when the script exits.

set -euo pipefail

# Path to the all-accounts script and the shared helpers, located next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ALL_SCRIPT="$SCRIPT_DIR/add-storage-subnet-all.sh"

# Shared helper functions (is_subnet_id).
# shellcheck source=storage-subnet-lib.sh
source "$SCRIPT_DIR/storage-subnet-lib.sh"

# Print help text and exit with the status given as $1 (default 1).
usage() {
  cat <<'EOF'
Usage: add-storage-subnet-subs.sh -f <subscriptions.csv> -r <reference-subnet-id> -n <new-subnet-id> [-g <resource-group>] [-d]

  -f  CSV file listing the subscriptions to process (one per line, optional "subscription" header)
  -r  Full resource ID of the subnet that must already be allowed
  -n  Full resource ID of the subnet to add
  -g  Optional: only process accounts in this resource group, in every subscription
  -d  Dry run, passed through to add-storage-subnet-all.sh
EOF
  exit "${1:-1}"
}

# Remove leading and trailing whitespace.
trim() {
  local s="$1"
  s="${s#"${s%%[![:space:]]*}"}"
  printf '%s' "${s%"${s##*[![:space:]]}"}"
}

CSV_FILE=""
REF_SUBNET=""
NEW_SUBNET=""
RG_FILTER=""
DRY_RUN=false

# Parse flags. The leading ":" lets us handle missing values and unknown flags ourselves.
while getopts ":f:r:n:g:dh" opt; do
  case $opt in
    f) CSV_FILE="$OPTARG" ;;
    r) REF_SUBNET="$OPTARG" ;;
    n) NEW_SUBNET="$OPTARG" ;;
    g) RG_FILTER="$OPTARG" ;;
    d) DRY_RUN=true ;;
    h) usage 0 ;;
    :) echo "Error: option -$OPTARG requires a value." >&2; usage ;;
    *) echo "Error: unknown option -$OPTARG." >&2; usage ;;
  esac
done

# The CSV file, reference subnet and new subnet are mandatory.
if [[ -z $CSV_FILE || -z $REF_SUBNET || -z $NEW_SUBNET ]]; then
  echo "Error: -f, -r and -n are required." >&2
  usage
fi

if [[ ! -f $CSV_FILE ]]; then
  echo "Error: subscriptions file not found: $CSV_FILE" >&2
  exit 1
fi

# Check the subnet IDs first, so a typo fails before any subscription is changed.
if ! is_subnet_id "$REF_SUBNET"; then
  echo "Error: -r is not a valid subnet resource ID: $REF_SUBNET" >&2
  exit 1
fi

if ! is_subnet_id "$NEW_SUBNET"; then
  echo "Error: -n is not a valid subnet resource ID: $NEW_SUBNET" >&2
  exit 1
fi

# Make sure the all-accounts script exists.
if [[ ! -f $ALL_SCRIPT ]]; then
  echo "Error: $ALL_SCRIPT not found." >&2
  exit 1
fi

# Make sure the Azure CLI is installed and logged in.
if ! command -v az >/dev/null 2>&1; then
  echo "Error: Azure CLI (az) is not installed." >&2
  exit 1
fi

if ! az account show >/dev/null 2>&1; then
  echo "Error: not logged in to Azure. Run 'az login' first." >&2
  exit 1
fi

# Read the whole CSV before changing anything, so a bad row fails early.
SUBS=()
BAD_ROWS=0
LINE_NO=0
HEADER_CHECKED=false

while IFS= read -r line || [[ -n $line ]]; do
  LINE_NO=$((LINE_NO + 1))

  # Strip comments and surrounding whitespace.
  line="${line%%#*}"
  line="$(trim "$line")"
  [[ -z $line ]] && continue

  # Skip the optional header on the first non-blank line.
  if [[ $HEADER_CHECKED == false ]]; then
    HEADER_CHECKED=true
    if [[ $line == subscription ]]; then
      continue
    fi
  fi

  # One subscription per row, so a comma means the row has the wrong shape.
  if [[ $line == *,* ]]; then
    echo "Error: line $LINE_NO has more than one field: $line" >&2
    BAD_ROWS=$((BAD_ROWS + 1))
  else
    SUBS+=("$line")
  fi
done < "$CSV_FILE"

if [[ $BAD_ROWS -gt 0 ]]; then
  echo "Error: $BAD_ROWS invalid line(s) in $CSV_FILE. No changes made." >&2
  exit 1
fi

if [[ ${#SUBS[@]} -eq 0 ]]; then
  echo "Error: no subscriptions found in $CSV_FILE." >&2
  exit 1
fi

# Remember the current subscription and restore it when the script exits.
ORIG_SUB="$(az account show --query id -o tsv)"
trap 'az account set --subscription "$ORIG_SUB" >/dev/null 2>&1 || true' EXIT

TOTAL=0
FAILED=0

# Run the all-accounts script for each subscription. A failure in one subscription
# does not stop the others; it is counted and reported at the end.
for sub in "${SUBS[@]}"; do
  TOTAL=$((TOTAL + 1))
  echo "##### Subscription $TOTAL of ${#SUBS[@]}: $sub"

  if ! az account set --subscription "$sub"; then
    echo "Error: cannot select subscription '$sub'." >&2
    FAILED=$((FAILED + 1))
    echo
    continue
  fi

  ARGS=(-r "$REF_SUBNET" -n "$NEW_SUBNET")
  if [[ -n $RG_FILTER ]]; then
    ARGS+=(-g "$RG_FILTER")
  fi
  if [[ $DRY_RUN == true ]]; then
    ARGS+=(-d)
  fi

  # </dev/null stops the child process from reading the CSV or the terminal.
  if ! bash "$ALL_SCRIPT" "${ARGS[@]}" </dev/null; then
    echo "    Subscription '$sub' had failures." >&2
    FAILED=$((FAILED + 1))
  fi
  echo
done

echo "Summary: $TOTAL subscription(s) processed."
echo "  With failures: $FAILED"

# Exit non-zero if any subscription had failures, so the result can be checked by other tools.
[[ $FAILED -eq 0 ]] || exit 1
