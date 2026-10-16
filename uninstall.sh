#!/usr/bin/env bash
# Remove everything install.sh added and go back to the stock drivers.
#   sudo ./uninstall.sh             for the running kernel
#   sudo KREL=7.2.6-... ./uninstall.sh   for another installed kernel
set -euo pipefail
KREL="${KREL:-$(uname -r)}"
STATE=/var/lib/omnibook-audio
[ "$(id -u)" = 0 ] || { echo "run with sudo" >&2; exit 1; }

rm -rf "/lib/modules/$KREL/updates/omnibook-audio"
depmod -a "$KREL"
echo "removed module overrides for $KREL"

if [ -f "$STATE/firmware.list" ]; then
  while read -r f; do [ -n "$f" ] && rm -f "/lib/firmware/$f" && echo "removed /lib/firmware/$f"; done < "$STATE/firmware.list"
  rm -rf "$STATE"
fi

if command -v lsinitramfs >/dev/null &&
   lsinitramfs "/boot/initrd.img-$KREL" 2>/dev/null | grep -qE 'snd-acp-config|snd-soc-acpi-amd-match|snd-soc-tas2783'; then
  update-initramfs -u -k "$KREL"
fi
echo "Done. Reboot to load the stock drivers."
