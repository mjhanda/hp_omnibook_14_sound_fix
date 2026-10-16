#!/usr/bin/env bash
# Show whether the OmniBook 8EA1 audio fix is active. No root needed.
ok()  { printf '  \033[32m✔\033[0m %s\n' "$*"; }
bad() { printf '  \033[31m✘\033[0m %s\n' "$*"; }

echo "Board:  $(cat /sys/class/dmi/id/product_name) ($(cat /sys/class/dmi/id/board_name))"
echo "Kernel: $(uname -r)"
echo

acp=""
for d in /sys/bus/pci/devices/*; do
  [ "$(cat "$d/vendor")" = 0x1022 ] && [ "$(cat "$d/device")" = 0x15e2 ] && acp=$d
done
drv="$(basename "$(readlink "$acp/driver" 2>/dev/null)" 2>/dev/null)"
[ "$drv" = snd_pci_ps ] && ok "ACP driver: snd_pci_ps (SoundWire)" \
                        || bad "ACP driver: ${drv:-none} (expected snd_pci_ps)"

n="$(ls /sys/bus/soundwire/devices/ 2>/dev/null | grep -c '^sdw:')"
[ "$n" -ge 3 ] && ok "SoundWire codecs: $n (2x TAS2783 + RT712)" || bad "SoundWire codecs: $n (expected 3)"

for m in snd_acp_config snd_soc_acpi_amd_match snd_soc_tas2783_sdw; do
  p="$(modinfo -n $m 2>/dev/null)"
  case "$p" in */updates/*) ok "$m: patched ($p)" ;;
               "") bad "$m: not found" ;;
               *) echo "  - $m: stock ($p)" ;; esac
done

if grep -q amd-soundwire /proc/asound/cards 2>/dev/null; then
  ok "sound card: amd-soundwire"
  aplay -l 2>/dev/null | grep -q SmartAmp && ok "speaker PCM (SmartAmp) present" || bad "no speaker PCM (SmartAmp)"
else
  bad "no amd-soundwire sound card"
fi
