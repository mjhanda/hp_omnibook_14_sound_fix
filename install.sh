#!/usr/bin/env bash
# Fix the internal speakers and microphone on the HP OmniBook X Flip 14 (board 8EA1, AMD
# Ryzen AI / ACP 7.x) for Linux 7.2.x.
#
#   sudo ./install.sh              build + install for the running kernel, then reboot
#   ./install.sh --build-only      just fetch, patch and build (no root needed)
#   sudo ./install.sh --force      skip the board / kernel version checks
#
# Re-run after every kernel update: the modules are built for one kernel release.
# Undo with: sudo ./uninstall.sh
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KREL="${KREL:-$(uname -r)}"
KDIR="/lib/modules/$KREL/build"
DEST="/lib/modules/$KREL/updates/omnibook-audio"
STATE=/var/lib/omnibook-audio
SSID=8EA1
FW_URL=https://gitlab.com/kernel-firmware/linux-firmware/-/raw/main/ti/audio/tas2783

BUILD_ONLY=0 FORCE=0
for a in "$@"; do
  case "$a" in
    --build-only) BUILD_ONLY=1 ;;
    --force) FORCE=1 ;;
    -h|--help) sed -n '2,11p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $a" >&2; exit 2 ;;
  esac
done

say() { printf '\n\033[1m== %s\033[0m\n' "$*"; }
die() { echo "error: $*" >&2; exit 1; }

# ---------------------------------------------------------------- checks
board="$(cat /sys/class/dmi/id/board_name 2>/dev/null || true)"
if [ "$board" != "$SSID" ] && [ $FORCE = 0 ]; then
  die "this is for board $SSID (HP OmniBook X Flip 14-kc0xxx); this machine is '$board'. Use --force to override."
fi

# 7.2.6-070206-generic -> 7.2.6 ; 7.2.0-12-generic -> 7.2
UPVER="$(echo "$KREL" | sed -E 's/^([0-9]+\.[0-9]+)\.([0-9]+).*/\1.\2/; s/\.0$//')"
MAJMIN="$(echo "$UPVER" | cut -d. -f1-2)"
if [ $FORCE = 0 ] && [ "$(printf '%s\n' 7.2 "$MAJMIN" | sort -V | head -1)" != 7.2 ]; then
  die "kernel $KREL is older than 7.2; these patches target 7.2.x. Use --force to try anyway."
fi

if [ $BUILD_ONLY = 0 ] && [ "$(id -u)" != 0 ]; then
  die "run with sudo (or use --build-only)"
fi

# ---------------------------------------------------------------- toolchain
CC="$(sed -n 's/^CONFIG_CC_VERSION_TEXT="\([^ ]*\) .*/\1/p' "/boot/config-$KREL" 2>/dev/null || true)"
CC="${CC:-gcc}"
missing=()
command -v make  >/dev/null || missing+=(build-essential)
command -v patch >/dev/null || missing+=(patch)
command -v curl  >/dev/null || missing+=(curl)
command -v "$CC" >/dev/null || missing+=("${CC#x86_64-linux-gnu-}")
if [ ${#missing[@]} -gt 0 ]; then
  [ "$(id -u)" = 0 ] || die "missing tools: ${missing[*]} (sudo apt install ${missing[*]})"
  say "Installing build tools: ${missing[*]}"
  DEBIAN_FRONTEND=noninteractive apt-get install -y "${missing[@]}"
fi
[ -d "$KDIR" ] || die "kernel headers for $KREL not found at $KDIR (install the matching linux-headers package)"

# ---------------------------------------------------------------- build
W="$(mktemp -d)"
trap 'rm -rf "$W"' EXIT
RAW="https://raw.githubusercontent.com/gregkh/linux/v$UPVER"
fetch() { mkdir -p "$W/src/$(dirname "$1")"; curl -fsSL "$RAW/$1" -o "$W/src/$1" || die "could not download $1 for v$UPVER"; }

say "Fetching Linux v$UPVER sources"
for f in sound/soc/amd/acp-config.c sound/soc/amd/mach-config.h \
         sound/soc/sof/amd/acp.h sound/soc/sof/sof-priv.h sound/soc/sof/sof-audio.h \
         sound/soc/amd/acp/amd-acp63-acpi-match.c sound/soc/amd/acp/amd-acp70-acpi-match.c \
         sound/soc/amd/acp/soc-acpi-amd-sdca-quirks.c sound/soc/amd/acp/soc-acpi-amd-sdca-quirks.h \
         sound/soc/codecs/tas2783-sdw.c sound/soc/codecs/tas2783.h; do
  fetch "$f"
done

apply() {  # apply <patch> <file> <string that means it's already upstream, or ''>
  local p="$HERE/patches/$1" f="$W/src/$2"
  if [ -n "$3" ] && grep -q "$3" "$f"; then echo "  $1: already in v$UPVER, skipping"; return 1; fi
  patch -s -d "$W/src" -p1 < "$p" || die "$1 does not apply to v$UPVER"
  echo "  $1: applied"
}

# build <dir> <module> <objs...>
build() {
  local d="$W/src/$1" m="$2"; shift 2
  { echo "obj-m += $m.o"; echo "$m-y := $*"; } > "$d/Kbuild"
  make -s -C "$KDIR" M="$d" CC="$CC" modules >"$W/build-$m.log" 2>&1 \
    || { cat "$W/build-$m.log"; die "build of $m failed"; }
  [ "$(modinfo -F vermagic "$d/$m.ko" | cut -d' ' -f1)" = "$KREL" ] || die "$m: vermagic mismatch"
  BUILT+=("$d/$m.ko"); echo "  built $m.ko"
}

BUILT=()
say "Patching and building"
if apply 0001-ASoC-amd-acp-config-add-DMI-override-for-HP-8EA1.patch \
         sound/soc/amd/acp-config.c 'DMI_BOARD_NAME, "8EA1"'; then
  build sound/soc/amd snd-acp-config acp-config.o
fi
if apply 0002-ASoC-amd-acp70-match-add-TAS2783x2-RT712-VB-entry.patch \
         sound/soc/amd/acp/amd-acp70-acpi-match.c 'tas2783x2_l0u9c'; then
  build sound/soc/amd/acp snd-soc-acpi-amd-match \
        amd-acp63-acpi-match.o amd-acp70-acpi-match.o soc-acpi-amd-sdca-quirks.o
fi
if apply 0003-ASoC-tas2783-per-amp-channel-mask.patch \
         sound/soc/codecs/tas2783-sdw.c ''; then
  build sound/soc/codecs snd-soc-tas2783-sdw tas2783-sdw.o
fi

if [ $BUILD_ONLY = 1 ]; then
  mkdir -p "$HERE/build/$KREL"
  for k in "${BUILT[@]}"; do cp "$k" "$HERE/build/$KREL/"; done
  echo; echo "Build OK. Modules copied to $HERE/build/$KREL/"
  exit 0
fi

# ---------------------------------------------------------------- install modules
say "Installing modules to $DEST"
rm -rf "$DEST"; mkdir -p "$DEST"
for k in "${BUILT[@]}"; do install -m 0644 "$k" "$DEST/"; echo "  $(basename "$k")"; done
depmod -a "$KREL"
for m in snd_acp_config snd_soc_acpi_amd_match snd_soc_tas2783_sdw; do
  echo "  $m -> $(modinfo -k "$KREL" -n $m)"
done

# ---------------------------------------------------------------- firmware
say "TAS2783 speaker-amp firmware"
mkdir -p "$STATE" /lib/firmware/ti/audio/tas2783
: > "$STATE/firmware.list"
# name, sha256 (linux-firmware, ti/audio/tas2783)
while read -r name sum; do
  have="$(ls /lib/firmware/ti/audio/tas2783/"$name"{,.zst,.xz} 2>/dev/null | head -1 || true)"
  if [ -z "$have" ]; then
    curl -fsSL "$FW_URL/$name" -o "$W/$name" || die "could not download $name"
    echo "$sum  $W/$name" | sha256sum -c --quiet - || die "$name: checksum mismatch"
    install -m 0644 "$W/$name" /lib/firmware/ti/audio/tas2783/
    echo "ti/audio/tas2783/$name" >> "$STATE/firmware.list"
    have=/lib/firmware/ti/audio/tas2783/$name
    echo "  downloaded $name"
  else
    echo "  present    $(basename "$have")"
  fi
done <<'EOF'
8EA1-0-0-0x9.bin 3757323b677ff383a1cbf80b0f26644ba868007c81f808d671fc08d40f91ba3d
8EA1-0-0-0xC.bin 56edb073297fb39332564964dc4ee00548c9ea9be902866afe00c18b0aaa4613
8EA1-1-0-0x9.bin 727aaac2fbd52cea1220587c37d6449d93e328d6879fb169ed9366b22967a066
8EA1-1-0-0xC.bin 4b1ae1dbf427e4f45318202416947b1b718f55fe52d8c8be6f510be1d6099e33
EOF
# The 7.2 driver asks for <SSID>-<link>-0x<uid>.bin (then <SSID>-<link>-<uid>.bin) at the top
# of /lib/firmware; point those names at the linux-firmware files.
for u in 9 C; do
  t="$(cd /lib/firmware && ls ti/audio/tas2783/$SSID-0-0-0x$u.bin{,.zst,.xz} 2>/dev/null | head -1)"
  ext="${t#*.bin}"
  for n in "$SSID-0-0x$u.bin$ext" "$SSID-0-$u.bin$ext"; do
    if [ ! -e "/lib/firmware/$n" ] || [ -L "/lib/firmware/$n" ]; then
      ln -sfn "$t" "/lib/firmware/$n"; echo "$n" >> "$STATE/firmware.list"
      echo "  linked     $n -> $t"
    fi
  done
done

# ---------------------------------------------------------------- initramfs
if command -v lsinitramfs >/dev/null &&
   lsinitramfs "/boot/initrd.img-$KREL" 2>/dev/null | grep -qE 'snd-acp-config|snd-soc-acpi-amd-match|snd-soc-tas2783'; then
  say "Updating initramfs"
  update-initramfs -u -k "$KREL"
fi

say "Done. Reboot to load the fixed drivers."
echo "After the reboot, check with:  ./scripts/status.sh"
