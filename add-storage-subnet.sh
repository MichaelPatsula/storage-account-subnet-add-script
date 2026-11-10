#!/usr/bin/env bash
#
# Adds a subnet to a storage account's virtual network rules, but only when a
# reference subnet is already allowed by those rules.
#
# Usage:
#   ./add-storage-subnet.sh -g <resource-group> -a <storage-account> \
#       -r <reference-subnet-id> -n <new-subnet-id> [-d]
#
#   -g  Resource group of the storage account
#   -a  Storage account name
#   -r  Full resource ID of the subnet that must already be allowed
#   -n  Full resource ID of the subnet to add
#   -d  Dry run: report what would happen without changing anything
#
# Requires the Azure CLI (az), logged in with `az login`.
# The new subnet must have the Microsoft.Storage service endpoint enabled.
#
# Exit codes:
#   0  subnet added
#   1  error (explained on stderr)
#   2  no change made (reference subnet not allowed, or new subnet already allowed)
#   3  dry run: subnet would be added

# Exit on error (-e), on unset variables (-u), and on failures inside pipes (-o pipefail).
set -euo pipefail

# Shared helper functions (is_subnet_id).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=storage-subnet-lib.sh
source "$SCRIPT_DIR/storage-subnet-lib.sh"

# Print help text and exit with the status given as $1 (default 1).
usage() {
  cat <<'EOF'
Usage: add-storage-subnet.sh -g <resource-group> -a <storage-account> -r <reference-subnet-id> -n <new-subnet-id> [-d]

  -g  Resource group of the storage account
  -a  Storage account name
  -r  Full resource ID of the subnet that must already be allowed
  -n  Full resource ID of the subnet to add
  -d  Dry run: report what would happen without changing anything
EOF
  exit "${1:-1}"
}

# Default values for the options.
RG=""
ACCOUNT=""
REF_SUBNET=""
NEW_SUBNET=""
DRY_RUN=false

# Parse flags. The leading ":" lets us handle missing values and unknown flags ourselves.
while getopts ":g:a:r:n:dh" opt; do
  case $opt in
    g) RG="$OPTARG" ;;
    a) ACCOUNT="$OPTARG" ;;
    r) REF_SUBNET="$OPTARG" ;;
    n) NEW_SUBNET="$OPTARG" ;;
    d) DRY_RUN=true ;;
    h) usage 0 ;;
    :) echo "Error: option -$OPTARG requires a value." >&2; usage ;;
    *) echo "Error: unknown option -$OPTARG." >&2; usage ;;
  esac
done

# All four values are mandatory.
if [[ -z $RG || -z $ACCOUNT || -z $REF_SUBNET || -z $NEW_SUBNET ]]; then
  echo "Error: -g, -a, -r and -n are required." >&2
  usage
fi

# Make sure the Azure CLI is installed.
if ! command -v az >/dev/null 2>&1; then
  echo "Error: Azure CLI (az) is not installed." >&2
  exit 1
fi

# Make sure there is an active Azure login.
if ! az account show >/dev/null 2>&1; then
  echo "Error: not logged in to Azure. Run 'az login' first." >&2
  exit 1
fi

# Azure resource IDs are case-insensitive, so compare lowercased values.
# tr is used instead of ${var,,} for compatibility with the macOS default bash (3.2).
normalize() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]'
}

# Check the subnet IDs before any account is read or changed, so a typo fails early.
if ! is_subnet_id "$REF_SUBNET"; then
  echo "Error: -r is not a valid subnet resource ID: $REF_SUBNET" >&2
  exit 1
fi

if ! is_subnet_id "$NEW_SUBNET"; then
  echo "Error: -n is not a valid subnet resource ID: $NEW_SUBNET" >&2
  exit 1
fi

echo "Reading network rules for storage account '$ACCOUNT' in '$RG'..."
# Fetch the IDs of all subnets currently allowed by the account's virtual network rules, one per line.
# Azure CLI errors go to a temp file so they can be shown if the call fails.
ERR_FILE="$(mktemp)"
trap 'rm -f "$ERR_FILE"' EXIT

if ! EXISTING=$(az storage account network-rule list \
  --account-name "$ACCOUNT" \
  --resource-group "$RG" \
  --query "virtualNetworkRules[].virtualNetworkResourceId" \
  -o tsv 2>"$ERR_FILE"); then
  echo "Error: could not read network rules for '$ACCOUNT' in '$RG'. Azure CLI output:" >&2
  cat "$ERR_FILE" >&2
  exit 1
fi

# Normalized reference and new subnet IDs, used for comparison.
REF_KEY=$(normalize "$REF_SUBNET")
NEW_KEY=$(normalize "$NEW_SUBNET")

# REF_FOUND: true if the reference subnet (-r) is already in the account's rules.
#            Must be true, otherwise the script makes no changes.
# NEW_FOUND: true if the new subnet (-n) is already in the account's rules.
#            If true, the subnet is already allowed and nothing is added.
REF_FOUND=false
NEW_FOUND=false

# Check each existing rule against the reference and new subnet IDs.
# The <<< here-string feeds the EXISTING list into the loop.
while IFS= read -r id; do
  [[ -z $id ]] && continue   # Skip empty lines (no rules configured).
  key=$(normalize "$id")
  if [[ $key == "$REF_KEY" ]]; then
    REF_FOUND=true
  fi
  if [[ $key == "$NEW_KEY" ]]; then
    NEW_FOUND=true
  fi
done <<< "$EXISTING"

# Only proceed if the reference subnet is already allowed.
if [[ $REF_FOUND != true ]]; then
  echo "Reference subnet is not allowed on '$ACCOUNT'. No changes made."
  exit 2
fi

echo "Reference subnet is allowed."

# Nothing to do if the new subnet is already allowed.
if [[ $NEW_FOUND == true ]]; then
  echo "New subnet is already allowed on '$ACCOUNT'. No changes made."
  exit 2
fi

# In dry-run mode, stop before making any change.
if [[ $DRY_RUN == true ]]; then
  echo "[dry run] Would add subnet: $NEW_SUBNET"
  exit 3
fi

# Add the new subnet to the storage account's network rules.
echo "Adding subnet: $NEW_SUBNET"
# Suppress the CLI's JSON output; errors are captured so they can be reported.
if ! ADD_OUTPUT=$(az storage account network-rule add \
  --account-name "$ACCOUNT" \
  --resource-group "$RG" \
  --subnet "$NEW_SUBNET" \
  -o none 2>&1); then
  echo "Error: could not add subnet to '$ACCOUNT' in '$RG'. Azure CLI output:" >&2
  printf '%s\n' "$ADD_OUTPUT" >&2
  exit 1
fi

echo "Done. Subnet added to '$ACCOUNT'."
