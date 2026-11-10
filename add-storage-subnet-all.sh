#!/usr/bin/env bash
#
# Runs add-storage-subnet.sh against every storage account in the current
# subscription, or only those in one resource group if -g is given.
#
# Usage:
#   ./add-storage-subnet-all.sh -r <reference-subnet-id> -n <new-subnet-id> [-g <resource-group>] [-d]
#
#   -r  Full resource ID of the subnet that must already be allowed
#   -n  Full resource ID of the subnet to add
#   -g  Optional: only process accounts in this resource group
#   -d  Dry run, passed through to add-storage-subnet.sh
#
# Requires the Azure CLI (az), logged in with `az login`.
# The current subscription is used (change it with `az account set`).

set -euo pipefail

# Path to the single-account script, located next to this script.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SINGLE_SCRIPT="$SCRIPT_DIR/add-storage-subnet.sh"

# Shared helper functions (is_subnet_id).
# shellcheck source=storage-subnet-lib.sh
source "$SCRIPT_DIR/storage-subnet-lib.sh"

# Print help text and exit with the status given as $1 (default 1).
usage() {
  cat <<'EOF'
Usage: add-storage-subnet-all.sh -r <reference-subnet-id> -n <new-subnet-id> [-g <resource-group>] [-d]

  -r  Full resource ID of the subnet that must already be allowed
  -n  Full resource ID of the subnet to add
  -g  Optional: only process accounts in this resource group
  -d  Dry run, passed through to add-storage-subnet.sh
EOF
  exit "${1:-1}"
}

# True if the file contains anything other than whitespace.
has_text() { grep -q '[^[:space:]]' "$1"; }

RG_FILTER=""
REF_SUBNET=""
NEW_SUBNET=""
DRY_RUN=false

# Parse flags. The leading ":" lets us handle missing values and unknown flags ourselves.
while getopts ":g:r:n:dh" opt; do
  case $opt in
    g) RG_FILTER="$OPTARG" ;;
    r) REF_SUBNET="$OPTARG" ;;
    n) NEW_SUBNET="$OPTARG" ;;
    d) DRY_RUN=true ;;
    h) usage 0 ;;
    :) echo "Error: option -$OPTARG requires a value." >&2; usage ;;
    *) echo "Error: unknown option -$OPTARG." >&2; usage ;;
  esac
done

# The reference and new subnet IDs are mandatory.
if [[ -z $REF_SUBNET || -z $NEW_SUBNET ]]; then
  echo "Error: -r and -n are required." >&2
  usage
fi

# Check the subnet IDs first, so a typo fails before any account is changed.
if ! is_subnet_id "$REF_SUBNET"; then
  echo "Error: -r is not a valid subnet resource ID: $REF_SUBNET" >&2
  exit 1
fi

if ! is_subnet_id "$NEW_SUBNET"; then
  echo "Error: -n is not a valid subnet resource ID: $NEW_SUBNET" >&2
  exit 1
fi

# Make sure the single-account script exists.
if [[ ! -f $SINGLE_SCRIPT ]]; then
  echo "Error: $SINGLE_SCRIPT not found." >&2
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

# List every storage account as "name<TAB>resourceGroup".
LIST_ARGS=(storage account list --query "[].[name, resourceGroup]" -o tsv)
if [[ -n $RG_FILTER ]]; then
  LIST_ARGS+=(--resource-group "$RG_FILTER")
fi

# Azure CLI errors go to a temp file so they can be shown if the call fails.
ERR_FILE="$(mktemp)"
CHILD_ERR="$(mktemp)"
trap 'rm -f "$ERR_FILE" "$CHILD_ERR"' EXIT

if ! ACCOUNTS=$(az "${LIST_ARGS[@]}" 2>"$ERR_FILE"); then
  echo "Error: could not list storage accounts. Azure CLI output:" >&2
  cat "$ERR_FILE" >&2
  exit 1
fi

# Show any warnings from a successful call.
if has_text "$ERR_FILE"; then
  cat "$ERR_FILE" >&2
fi

TOTAL=0
ADDED=0
WOULD_ADD=0
SKIPPED=0
FAILED=0

# Run the single-account script for each account. A failure on one account
# does not stop the others; it is counted and reported at the end.
while IFS=$'\t' read -r name rg; do
  [[ -z $name ]] && continue

  TOTAL=$((TOTAL + 1))
  echo "==> $name (resource group: $rg)"

  ARGS=(-g "$rg" -a "$name" -r "$REF_SUBNET" -n "$NEW_SUBNET")
  if [[ $DRY_RUN == true ]]; then
    ARGS+=(-d)
  fi

  # </dev/null stops the child process from reading the account list.
  # The child's stderr is captured so we can tell whether it printed an explanation.
  : > "$CHILD_ERR"
  RC=0
  bash "$SINGLE_SCRIPT" "${ARGS[@]}" </dev/null 2>"$CHILD_ERR" || RC=$?
  cat "$CHILD_ERR" >&2
  case $RC in
    0) ADDED=$((ADDED + 1)) ;;
    2) SKIPPED=$((SKIPPED + 1)) ;;
    3) WOULD_ADD=$((WOULD_ADD + 1)) ;;
    # Exit code 1 means the single-account script failed. If it printed nothing, say so here.
    1)
      if ! has_text "$CHILD_ERR"; then
        echo "Error: add-storage-subnet.sh failed without a message (exit code 1)." >&2
      fi
      echo "    FAILED: $name (see error above)" >&2
      FAILED=$((FAILED + 1)) ;;
    *) echo "    FAILED: $name (process ended unexpectedly, exit code $RC)" >&2; FAILED=$((FAILED + 1)) ;;
  esac
  echo
done <<< "$ACCOUNTS"

echo "Summary: $TOTAL account(s) processed."
echo "  Added:           $ADDED"
echo "  Would add (dry): $WOULD_ADD"
echo "  Unchanged:       $SKIPPED"
echo "  Failed:          $FAILED"

# Exit non-zero if any account failed, so the result can be checked by other tools.
[[ $FAILED -eq 0 ]] || exit 1
