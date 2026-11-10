# Storage Account Subnet Scripts

Bash scripts that add a new subnet to a storage account's virtual network rules, but only when a reference subnet is already allowed.

## Scripts

| Script | Purpose |
| --- | --- |
| `add-storage-subnet.sh` | Processes one storage account (`-g` and `-a`). |
| `add-storage-subnet-all.sh` | Runs `add-storage-subnet.sh` for every storage account in the current subscription, or in one resource group if `-g` is given. |
| `add-storage-subnet-subs.sh` | Runs `add-storage-subnet-all.sh` for every subscription listed in a CSV file. |
| `storage-subnet-lib.sh` | Shared helper (subnet ID check). Sourced by all scripts, not run directly. Keep it in the same folder as the scripts. |

## Prerequisites

- [Azure CLI](https://learn.microsoft.com/cli/azure/install-azure-cli) (`az`)
- Logged in: `az login`
- The correct subscription selected: `az account set --subscription <name-or-id>`
- The new subnet has the `Microsoft.Storage` service endpoint enabled.

## Usage

### Single storage account

```bash
./add-storage-subnet.sh \
  -g <resource-group> \
  -a <storage-account> \
  -r <reference-subnet-id> \
  -n <new-subnet-id> \
  [-d]
```

| Option | Description |
| --- | --- |
| `-g` | Resource group of the storage account (required) |
| `-a` | Storage account name (required) |
| `-r` | Full resource ID of the subnet that must already be allowed (required) |
| `-n` | Full resource ID of the subnet to add (required) |
| `-d` | Dry run: report what would happen without changing anything |
| `-h` | Show help |

### All storage accounts in the subscription

```bash
./add-storage-subnet-all.sh \
  -r <reference-subnet-id> \
  -n <new-subnet-id> \
  [-g <resource-group>] \
  [-d]
```

| Option | Description |
| --- | --- |
| `-r` | Full resource ID of the subnet that must already be allowed (required) |
| `-n` | Full resource ID of the subnet to add (required) |
| `-g` | Optional: only process accounts in this resource group |
| `-d` | Dry run, passed through to `add-storage-subnet.sh` |
| `-h` | Show help |

### Multiple subscriptions from a CSV file

```bash
./add-storage-subnet-subs.sh \
  -f <subscriptions.csv> \
  -r <reference-subnet-id> \
  -n <new-subnet-id> \
  [-g <resource-group>] \
  [-d]
```

| Option | Description |
| --- | --- |
| `-f` | CSV file listing the subscriptions to process (required) |
| `-r` | Full resource ID of the subnet that must already be allowed (required) |
| `-n` | Full resource ID of the subnet to add (required) |
| `-g` | Optional: only process accounts in this resource group, in every subscription |
| `-d` | Dry run, passed through to `add-storage-subnet-all.sh` |
| `-h` | Show help |

The CSV has one subscription per line, as a name or ID. The `subscription` header line is optional. Blank lines and lines starting with `#` are ignored. Lines with more than one field are rejected before any subscription is changed.

```csv
subscription
my-dev-sub
00000000-0000-0000-0000-000000000000
# comments are ignored
```

The reference and new subnet IDs are the same for every subscription. The script switches to each subscription in turn and restores the original subscription when it exits.

### Subnet ID format

```text
/subscriptions/<subscription-id>/resourceGroups/<resource-group>/providers/Microsoft.Network/virtualNetworks/<vnet-name>/subnets/<subnet-name>
```

## Behavior

For each storage account, the script:

1. Reads the subnets currently allowed by the account's virtual network rules.
2. If the reference subnet is not allowed, makes no changes.
3. If the new subnet is already allowed, makes no changes.
4. Otherwise, adds the new subnet (or only reports it, with `-d`).

Subnet IDs are compared case-insensitively. Only full resource IDs are matched; subnet names are not.

## Output and exit codes

The single-account script exits with:

| Code | Meaning |
| --- | --- |
| `0` | Subnet added |
| `1` | Error (explained on stderr) |
| `2` | No change made: reference subnet not allowed, or new subnet already allowed |
| `3` | Dry run: subnet would be added |

The batch script continues past failures. At the end it prints a summary:

```text
Summary: 12 account(s) processed.
  Added:           2
  Would add (dry): 0
  Unchanged:       9
  Failed:          1
```

It exits with `1` if any account failed, and `0` otherwise.

## Errors

- Invalid subnet IDs are rejected before any account is changed.
- Azure CLI errors are printed with the step that failed, followed by the raw Azure CLI output. Read the Azure message for the cause.
- `-h` shows help and exits with `0`. Invalid arguments exit with `1`.

## Examples

Dry run across the whole subscription:

```bash
./add-storage-subnet-all.sh -r "$REF_SUBNET_ID" -n "$NEW_SUBNET_ID" -d
```

Apply to one resource group:

```bash
./add-storage-subnet-all.sh -r "$REF_SUBNET_ID" -n "$NEW_SUBNET_ID" -g my-rg
```

## Notes

- Run a dry run (`-d`) first to confirm the accounts and subnets that will change.
- Keep `storage-subnet-lib.sh` next to the scripts. Copying only the two scripts will fail.
- `add-storage-subnet.sh` and `add-storage-subnet-all.sh` use the currently selected Azure subscription. `add-storage-subnet-subs.sh` switches subscriptions from its CSV file and restores the original one on exit.
# storage-account-subnet-add-script
