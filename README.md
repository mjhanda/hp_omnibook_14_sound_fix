# HP OmniBook X Flip 14 — Linux speaker & microphone fix

Gets the **internal speakers and internal microphone** working (headset jack: see [Known issues](#known-issues)) on the
**HP OmniBook X Flip Laptop 14-kc0xxx** (board ID `8EA1`, AMD Ryzen AI) under **Linux 7.2.x**.

Without the fix, the only audio outputs are HDMI/DisplayPort. The built-in speakers and mic don't
show up at all (or the mic shows up but the speakers don't).

> Tested on Ubuntu 26.04 with mainline kernel 7.2.6, BIOS F.07. Most of this is fixed upstream in
> Linux 7.3 (see [Upstream status](#upstream-status)). You won't need this once your distro ships
> that kernel and a recent `linux-firmware`.

## Is this my laptop?

```sh
cat /sys/class/dmi/id/board_name     # must print 8EA1
uname -r                             # 7.2.x
```

If the board isn't `8EA1`, the installer refuses to run. Other Strix/Krackan laptops with TAS2783
amps may have the same problem, but they need their own IDs in the patches.

## Quick start

```sh
# 1. Kernel headers and a compiler (the installer pulls in anything else it needs)
sudo apt install linux-headers-$(uname -r) build-essential curl patch
#    Mainline kernel? Install the matching linux-headers .debs from kernel.ubuntu.com instead.

# 2. Get the fix and run it
git clone https://github.com/mjhanda/hp_omnibook_14_sound_fix.git
cd hp_omnibook_14_sound_fix
sudo ./install.sh

# 3. Reboot, then check
sudo reboot
./scripts/status.sh
```

`status.sh` should show all green ticks:

```
  ✔ ACP driver: snd_pci_ps (SoundWire)
  ✔ SoundWire codecs: 3 (2x TAS2783 + RT712)
  ✔ snd_acp_config: patched
  ✔ snd_soc_acpi_amd_match: patched
  ✔ snd_soc_tas2783_sdw: patched
  ✔ sound card: amd-soundwire
  ✔ speaker PCM (SmartAmp) present
```

Then test both speakers:

```sh
speaker-test -c2 -t wav -l1          # says "Front Left" / "Front Right"
./scripts/speaker-lr-test.sh         # plays tones and measures them with the built-in mic
```

In the L/R test, the `L`, `R` and `S` levels should all be well above `silence`.

> **After every kernel update, run `sudo ./install.sh` again.** The modules are built for one
> kernel version. A new kernel boots with the stock drivers, so the sound goes away until you
> re-run the installer.

## What's wrong, and what the fix does

The laptop's audio goes through AMD's ACP 7.x audio coprocessor (PCI `1022:15e2`, rev `0x72`).
The ACP drives the codecs over **SoundWire**:

| SoundWire link | Device | Job |
|---|---|---|
| link 0, uid `0xC` | TI **TAS2783** smart amp | left speaker |
| link 0, uid `0x9` | TI **TAS2783** smart amp | right speaker |
| link 1, uid `0x0` | Realtek **RT712-VB** (SDCA) | headset jack + digital mic |

Kernel 7.2 has four problems on this machine. The installer fixes each one:

1. **The wrong driver binds** (`patches/0001`). On ACP 7.x, `snd-acp-config` chooses the
   driver from a BIOS flag (`acp-audio-config-flag`). On this laptop the flag selects the legacy,
   DMIC-only driver (`snd_acp_pci`), so nothing ever starts the SoundWire bus. The patch adds a
   DMI override for board `8EA1`, so the SoundWire driver (`snd_pci_ps`) binds instead.
2. **No machine entry for this codec layout** (`patches/0002`). Kernel 7.2 doesn't know the
   "2× TAS2783 on link 0 + RT712-VB on link 1" layout. It falls back to an RT712-only entry, which
   gives you a jack and a mic but no speakers. The patch backports the upstream entry
   (`acp70_tas2783x2_l0u9c_rt712_vb_l1u0`).
3. **Only one speaker plays** (`patches/0003`). The TAS2783 driver gives both amps the full stereo
   channel mask. The two mono amps then mirror each other, and only one actually plays. The patch
   gives each amp a single channel: `tas2783-1` gets left, `tas2783-2` gets right.
4. **Missing amp firmware.** The TAS2783 amps need per-laptop tuning files (`8EA1-*.bin`). The
   installer downloads them from
   [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware/-/tree/main/ti/audio/tas2783),
   checks their SHA-256, and links them to the file names the 7.2 driver looks for.

### How it's installed

- `install.sh` downloads the matching unmodified source files for your exact kernel version
  (the matching release tag from [gregkh/linux](https://github.com/gregkh/linux), e.g. `v7.2.6`) and applies the patches.
  It builds only the three affected modules, out of tree, against your kernel headers.
- The modules go in `/lib/modules/$(uname -r)/updates/omnibook-audio/`. `depmod` loads anything
  in `updates/` ahead of the stock module. Nothing in the original kernel tree is overwritten.
- Firmware goes in `/lib/firmware/ti/audio/tas2783/`, plus symlinks in `/lib/firmware/`. The
  installer keeps a list of what it added in `/var/lib/omnibook-audio/firmware.list`.
- If your kernel is new enough that a fix is already in it, that patch is skipped.

To check the build without installing anything: `./install.sh --build-only` (no root needed).

## Uninstall

```sh
sudo ./uninstall.sh
sudo reboot
```

This removes the module overrides and any firmware files and links the installer added.

## Known issues

- At boot, `dmesg` shows `SDW0-PIN4-CAPTURE-SmartAmp: ASoC error (-22)`. That's the amps'
  feedback-capture stream, which the amps use to monitor themselves. Playback works fine without it.
- Not tested yet: the headset jack (plug detection, headphones, headset mic), and whether audio
  comes back after suspend/resume. Reports either way are welcome as issues.

## Upstream status

| Piece | Status |
|---|---|
| DMI override for `8EA1` in `snd-acp-config` | upstream, Linux 7.3 |
| `acp70_tas2783x2_l0u9c_rt712_vb_l1u0` machine entry | upstream master |
| TAS2783 per-amp channel mask (stereo) | proposed on linux-sound (2026-07), not merged yet |
| TAS2783 `8EA1` tuning firmware | in linux-firmware |

## Disclaimer

This loads patched kernel modules. It's been tested on one laptop. It doesn't touch the BIOS or
change amp limits, but you use it at your own risk. Start with the volume low the first time.

## License

GPL-2.0, same as the Linux kernel code these patches change. The TAS2783 firmware is downloaded
from linux-firmware under its own license and isn't included in this repository.
