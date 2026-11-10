# shellcheck shell=bash
#
# Shared helpers for add-storage-subnet.sh and add-storage-subnet-all.sh.
# Sourced by both scripts; do not run directly.

# Check that a value is a full subnet resource ID (case-insensitive).
is_subnet_id() {
  local lower
  lower=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  [[ $lower =~ ^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.network/virtualnetworks/[^/]+/subnets/[^/]+$ ]]
}
