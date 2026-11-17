#!/bin/bash
set -euo pipefail

if [[ $# -ne 1 ]]; then
  echo "Usage: $0 /path/to/NVBeacon-servers.json" >&2
  echo "Copies a backup into an already-running simulator. Set SIMULATOR_UDID when multiple simulators are running." >&2
  exit 1
fi

backup_path="$1"
if [[ ! -f "$backup_path" ]]; then
  echo "Backup file not found." >&2
  exit 1
fi
case "$backup_path" in
  *.[jJ][sS][oO][nN]) ;;
  *) echo "Choose the exported .json backup file." >&2; exit 1 ;;
esac
backup_size="$(stat -f%z "$backup_path")"
if (( backup_size > 1048576 )); then
  echo "The backup exceeds NVBeacon's 1 MiB limit." >&2
  exit 1
fi

simulator_id="${SIMULATOR_UDID:-booted}"
bundle_id="${BUNDLE_ID:-com.nvbeacon.ios}"
if ! container_path="$(xcrun simctl get_app_container "$simulator_id" "$bundle_id" data)"; then
  echo "Run NVBeacon in your existing simulator first. This script never creates or boots a simulator." >&2
  exit 1
fi
documents_path="$container_path/Documents"
mkdir -p "$documents_path"
destination="$documents_path/$(basename "$backup_path")"
if [[ -e "$destination" ]]; then
  echo "A file with this name is already staged. Rename the source backup to copy another version." >&2
  exit 1
fi
cp -n "$backup_path" "$destination"
chmod 600 "$destination"
echo "Backup copied. In NVBeacon, choose Import Servers, then Browse > On My iPhone/iPad > NVBeacon."
echo "The file has not been imported or enabled automatically."
