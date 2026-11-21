#!/usr/bin/env bash
set -euo pipefail
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
bash "$ROOT/build_scripts/build_esp32.sh" S3_PiBridge_LinkIt_Host
if [[ -n "${PI_MODULE_SDKCONFIG:-}" && -n "${PI_MODULE_PACKAGE_DIR:-}" ]]; then
  for mode in BLE LAN; do
    bash "$ROOT/build_scripts/build_module_variant.sh" smart-planter "$mode" \
      "$HOME/esp32_workspace/builds/smart-planter-$mode"
  done
else
  echo "Skipping smart-planter variants: set PI_MODULE_SDKCONFIG and PI_MODULE_PACKAGE_DIR for private provisioning."
fi
