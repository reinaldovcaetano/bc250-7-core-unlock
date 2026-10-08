# bc250-nucleos-arch: BC-250 core 7 on Arch / CachyOS (Limine)

**Languages:** [Português](arch-cachyos.md) · **English** · [Русский](arch-cachyos.ru.md)

Version of `bc250-nucleos.sh` for **Arch/CachyOS with the Limine bootloader**. The original script only works on Fedora/Nobara (GRUB with BLS).

It also installs **e-tho's ACPI fix** (P-states/C-states, the same tables as the BC250 Control Center "ACPI fix") on every boot, **with or without the extra core**, without replacing Limine with GRUB/systemd-boot.

> The script's questions and messages are in Portuguese.

> **Status on 2026-10-05:** script written and tested **offline** (syntax, helpers, editing a copy of the real `limine.conf`, table generated from the board's real MADT, initramfs generated with the `acpi_override` hook, initrd scan simulated the way the kernel does it). **Tested on the board on 2026-10-05:** step 1 (`acpi`) and step 2 (`testar`, 14 threads + 5 min of stress) OK. See the [board test log](#board-test-log).

## The board

| | |
|---|---|
| System | CachyOS (`linux-cachyos-deckify` 7.2.9), Limine 12.9.0, EFI, Secure Boot off, lockdown `none` |
| BIOS | P3.00 (12/09/2021), with the factory "AMD CPU" SSDT |
| SMU mask | `0x77`: cores **3 and 7 hidden**; 12 threads (APIC 0–5 and 8–13) |
| Earlier tests (on Nobara) | **core 7 good**, core 3 defective |
| Goal | enable only core 7: **14 threads** (APIC 0–5 and 8–15; APIC 6/7 = core 3 parked) |

## Before you start (mandatory)

1. **Turn off the CPU OC** and reboot normally:
   ```
   sudo systemctl disable bc250-smu-oc
   sudo reboot
   ```
   The OC (3850 MHz, scale −31) was calibrated with 6 cores. On the original board, the old OC froze the display with 7 cores. An applied OC stays in the SMU and **survives the warm reset**. The script refuses to run if `bc250-smu-oc` is enabled or has run in the current boot.
   If the OC was applied from the BC250 Control Center app (rather than the service), the script cannot detect it. So **do not apply the OC from the app** before testing.
2. Be on the default kernel of the Limine entry (not a snapshot, and not a freshly installed kernel without a reboot).
3. SMT on (the thread math assumes 2 per core).

## Usage

```
cd ~/Downloads/bc250-7-core-unlock
sudo ./bc250-nucleos-arch.sh testar     # enables core 7 for ONE boot only
sudo ./bc250-nucleos-arch.sh status     # result; nproc should show 14
sudo ./bc250-nucleos-arch.sh instalar   # keeps it enabled by default (every cold boot becomes 2 boots)
sudo ./bc250-nucleos-arch.sh desfazer   # removes the extra core (does not touch the ACPI fix)
sudo ./bc250-nucleos-arch.sh acpi           # e-tho ACPI fix on every boot
sudo ./bc250-nucleos-arch.sh acpi-desfazer  # removes the ACPI fix
```
Run it in a separate terminal, because the script asks questions. `NUCLEOS="7"` is the default; another list can be passed through the variable.

Optional stress test during the test boot: `sudo pacman -S stress-ng`, then `stress-ng --cpu 14 --verify -t 10m`.

### `testar` (one boot only)
1. Checks distro, Limine with one-shot, EFI, `CONFIG_ACPI_TABLE_UPGRADE`, board, OC off, mask and MADT.
2. Generates the cpio with the new MADT (+ the e-tho SSDTs, if the ACPI fix is not in the initramfs yet) and copies it to `/boot/bc250-nucleos.cpio`.
3. Appends the `/bc250-nucleos` entry to the end of `/boot/limine.conf`. Makes a backup at `/boot/limine.conf.bc250-bak` (first time only). The kernel line gets `bc250.nucleos=teste` and `systemd.mask=` for the OC and governor services.
4. Stops the GPU governor, writes `0xFF` to the mask through the SMU, runs `bootctl set-oneshot bc250-nucleos` and restarts **warm**.
5. On the test boot, the `bc250-nucleos-teste.service` service checks the threads, **removes the entry and the cpio**, sets reboot back to cold and disables itself. The next normal reboot returns to factory state.

### `instalar` (default)
Can be run on a normal boot (12 threads) or **right after a successful `testar`, still on the test boot**. In the latter case it uses the factory mask, the base thread count and the original MADT that `testar` saved in `/var/lib/bc250-nucleos/` (only if the kernel line has `bc250.nucleos=teste` and the result is `OK`).

Installs `bc250-nucleos-boot.service`. On every cold boot, the 1st boot (normal entry, 12 threads) writes `0xFF` and warm-restarts into the `bc250-nucleos` entry. The 2nd boot comes up with 14 threads. The Limine entry is recreated on every boot from the kernel entry, so it survives `limine-entry-tool` and updates.

Disable for one boot: in Limine, press `e` and add `bc250.nucleos.nao`. Disable for good: `sudo touch /etc/bc250-nucleos.desligado`. If an attempt does not reach 14 threads, it stops trying (`sudo rm /var/lib/bc250-nucleos/falhou` to try again).

### `acpi` (ACPI fix on every boot)
Why not use the Control Center installer: it only accepts GRUB or systemd-boot Type #1 and flags Limine as "UKI" (wrong: here `ENABLE_UKI=no` and Limine loads `vmlinuz` and `initramfs` separately). This command does the same thing the native Arch way:

1. Checks distro, Limine, `limine-mkinitcpio`, the `acpi_override` hook, `CONFIG_ACPI_TABLE_UPGRADE`, lockdown, BC-250 with BIOS P3.00 and the **sha256** of the 3 SSDTs (identical to e-tho v1.1.0 and to the Control Center payload).
2. Refuses if another fix is already present: SSDT `PSTATES`/`STUBS`/`P_CST3` or `AMD CPU` rev ≥ 2 loaded, `bc250-acpi` in `limine.conf`, or `.aml` files in `/etc/initcpio/acpi_override` or `/usr/lib/initcpio/acpi_override`.
3. Copies the SSDTs to `/etc/initcpio/acpi_override/` and creates `/etc/mkinitcpio.conf.d/20-bc250-acpi.conf` with `HOOKS+=(acpi_override)`. The main `mkinitcpio.conf` is not edited.
4. Runs `limine-mkinitcpio` and checks that the SSDTs made it into the early cpio of the kernel entry's initramfs. If they did not, it undoes everything by itself.

Since it is a mkinitcpio drop-in, it survives kernel updates. Old Limine snapshots stay without the fix (they use old initramfs images).

After `acpi`, the Control Center checker shows "tables modified by another fix" and blocks its own installer. **That is expected**, because it prevents installing twice.

### Extra core + ACPI fix together
The Limine `bc250-nucleos` entry loads `bc250-nucleos.cpio` **before** the normal initramfs. So the SSDTs are never loaded twice, the script generates two cpios and picks one on every boot:

| ACPI fix installed? | `bc250-nucleos.cpio` carries | Result on the extra-core boot |
|---|---|---|
| yes (SSDTs in the initramfs) | `madt.cpio`: MADT only | new MADT + SSDTs once |
| no | `final.cpio`: MADT + SSDTs | new MADT + SSDTs once |

The choice (`cpio_certo`) looks at the early cpio of the initramfs referenced by the kernel entry. That is why installing or removing the ACPI fix after the extra core does not require reinstalling anything.

## If something goes wrong
- **Froze:** power the board off and on. A cold boot restores the factory mask (`0x77`, 12 threads).
- **Came up with 16 threads** (core 3 enabled): the service turns off CPUs 6 and 7 right away and logs it in `status`. Reboot normally.
- **The test boot landed on the normal entry:** the `bc250-nucleos` ID in Limine is probably different (see below). Note the output of `status` and `bootctl list`.
- **Limine does not boot:** pick another entry from the menu, or restore `/boot/limine.conf.bc250-bak`.

## What changed compared to the original script

| Original (Fedora/Nobara) | Arch/CachyOS |
|---|---|
| Fedora/Nobara only | Arch/CachyOS (`ID`/`ID_LIKE` = arch) |
| BLS entry in GRUB (`/boot/loader/entries`) | Block at the end of `limine.conf` between `# >>> bc250-nucleos` and `# <<< bc250-nucleos`, with the cpio as the 1st `module_path` |
| `grub2-reboot` | `bootctl set-oneshot bc250-nucleos` (Limine has "One-shot entry control") |
| Kernel checked in `/boot/config-*` | `/proc/config.gz` of the running kernel; if the entry uses another kernel, it does not proceed |
| `dnf install` | Only needs `python` and `cpio` (already installed) |
| Test queue 3 → 7 → all | No queue: core 7 was already tested |
| OC only warned about | **Blocks** if the CPU OC is enabled or applied on this boot |

`smu.py` and `madt.py` are extracted from the original `bc250-nucleos.sh` (which must be in the same folder), without changing anything else.

### Fix in the MADT check
The original check required **UID = APIC+1** and would have rejected this BIOS. BIOS P3.00 numbers UIDs sequentially over the active cores only (APIC 8 → UID 7). The e-tho SSDTs use `P000`…`P00F`, with `_CSD` grouping two threads per physical core (P00E/P00F = core 7 = APIC 14/15), meaning P00x = APIC x. The generated MADT (UID = APIC+1) is the consistent one. The check now also accepts the sequential layout. Any other layout is still rejected.

Generated table (checked, checksum OK):
```
APIC 0-5   enabled    (cores 0-2)
APIC 6-7   DISABLED   (core 3, defective)
APIC 8-15  enabled    (cores 4-7)
```

## Compatibility with BC250 Control Center

| Item | Effect |
|---|---|
| CPU OC (`bc250-smu-oc`) | **Turn off first.** Recalibrate with 7 cores (Control Center detection) before turning it back on |
| Cyan Skillfish Governor | OK: the script stops it before talking to the SMU (restarts it if the write fails) and masks it on the test boot |
| "CPU power management · ACPI" | **Do not install from the Control Center** (it does not accept Limine). Use this script's `acpi`, which installs the same tables and combines with the extra core without loading them twice |
| MastaG kernel / other kernel | Check `zcat /proc/config.gz \| grep ACPI_TABLE_UPGRADE` on it; do not switch kernels in the middle of testing |
| Mesa / GFX1013 / FSR4 | No effect |
| Mitigations | No effect |
| Disabling SMT | **Breaks it** (the thread math no longer holds) |
| Fan control | No effect (good to keep on) |

## Protections against core 3 (audit from 2026-10-05)

The SMU only accepts "release all" (`0xFF`): after the write, core 3 is on in hardware until a cold reset. What prevents the kernel from using it:

| Layer | How | Checked |
|---|---|---|
| New MADT | APIC 6 and 7 with `flags=0` (neither enabled nor *online capable*) | `madt.cpio` in `/boot` identical to the generated one; checksum OK; `possible=present=online=0-13`, no `cpu14/15` in sysfs: they cannot be brought up even by hotplug |
| `bc250-nucleos` entry | only marked (one-shot) after the entry has been written and the kernel checked (`uname -r`) | ID confirmed during the test |
| Reboot after the 14-thread boot | **fixed:** `_boot` now sets the reboot to **cold** (`acpi`/`cold`) on the OK boot too. Before, the kernel default stayed; a warm reset with `0xFF` landing on the normal entry would come up with 16 threads | |
| Normal entry with 16 threads (a warm reset that slipped through) | the service turns off core 3's threads right away and carries on | **fixed:** it used to turn off `cpu6`/`cpu7` by **logical number**. The kernel numbers CPUs in MADT order: on that boot `cpu6`/`cpu7` = APIC 8/9 (core 4, good). It now turns them off by **APIC ID** read from `/proc/cpuinfo` and logs it if that fails |
| Attempt that does not reach 14 | `falhou` file: stops trying and sets reboot back to cold | |

Remaining limitation: if a warm reset lands on the normal entry, the kernel wakes core 3 during boot, before the service turns it off. The two fixes above make that path much less likely.

## Bug fixed: Limine's `remember_last_entry` (2026-10-05)

On a cold boot at 22:03 the board came up with **12 threads** and the service logged `OK: 14 threads`. Two causes:
1. Limine (`remember_last_entry: yes`) stores the last entry in `LimineLastBootedEntry` (EFI). It was `bc250-nucleos`, so the cold boot went straight to the entry with the new MADT, but with the factory mask: the kernel waited ~20 s for the missing APIC 14/15 (`Total of 12 processors activated` at 20.2 s).
2. `threads()` used `nproc --all`, which counts **declared** CPUs (14 in the new MADT), not **online** ones (12).

Fix: `threads()` counts online CPUs (`/proc/cpuinfo`), and `_boot` clears `LimineLastBootedEntry` when it points to `bc250-nucleos`. The next cold boot goes back to `default_entry`; the one-shot does not use that variable. This was the "unconfirmed point" about `remember_last_entry` below: the assumption that the service would follow the normal flow was wrong because of the count.

## CPU OC with the ACPI fix (Control Center detector)

With the ACPI fix, Linux controls frequency (`acpi-cpufreq` + `schedutil`). Under the detector's stress, `schedutil` leaves some cores in lower P-states (1577–2184 MHz). `bc250-detect` thinks it is throttling and **aborts at the first step** (stays at `3500 + target % 100`, e.g. 3550 / scale −2), whatever the VID.

Measured on 2026-10-05 (clock of the 8 cores from the SMU, load on 14 threads): with `performance`, all at 3550 except core 3 (defective, no load, 1577 MHz: the detector marks it as inactive, correctly); with `schedutil`, cores varying between 1577 and 2184.

**To detect the OC:** `performance` governor during detection, then switch back:
```
echo performance | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
# detection in the Control Center
echo schedutil | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
```
(the governor goes back to `schedutil` on its own at the next boot).

## `scx_lavd` scheduler (CachyOS) and frequency

CachyOS uses the sched_ext scheduler `scx_lavd`. In **Auto** mode (`--autopilot`) it does core compaction and sets the frequency target that `schedutil` follows: in a 14-thread `stress-ng` with **99% usage on all CPUs**, 6 of them stayed at **1707 MHz** (measured on 2026-10-05 with OC 3850/−31). It is also the likely reason the OC detection aborts (section above).

Solution: **Gaming** mode (`--performance`) as the default in `/etc/scx_loader.toml` (`default_mode = "Gaming"`, backup in `.bak`; takes effect after `systemctl restart scx_loader` or on the next boot). Result: all 14 CPUs at 3842 MHz under load, and the same idle draw as Auto (PPT ~31.7 W, cores at 800 MHz, C3 ~97% of the time).

Stress with OC 3850/−31 + 7 cores + Gaming: 14/14 passed, 0 failed (stopped at ~6.5 min, ~4.5 min with all at 3850), Tctl steady at 68 °C, PPT ~62–66 W, 1175–1181 mV.

## Kernel
To work, the kernel needs `CONFIG_ACPI_TABLE_UPGRADE=y` and must not be in lockdown (Secure Boot). Without that, it ignores the new MADT. After the warm reset the BIOS shows all 8 cores, and the **defective core 3 would come up**. The script checks both and, if 16 threads come up anyway, turns off CPUs 6 and 7.

## Unconfirmed points
- ~~Entry ID in Limine~~: **confirmed** on 2026-10-05: `bootctl set-oneshot bc250-nucleos` booted the `/bc250-nucleos` entry.
- `remember_last_entry: yes` in `limine.conf`: in `testar` mode it does not matter, because the entry is removed. In `instalar` mode, if Limine remembers the `bc250-nucleos` entry, a cold boot lands on it with the factory mask. The kernel tries to wake the missing APIC 14/15 (a few seconds of delay), comes up with 12 threads and the service follows the normal flow.
- Limine joins several `module_path` entries into a single initrd; the ACPI cpio goes first and uncompressed, as the kernel requires. The kernel (`lib/earlycpio.c`) walks through the uncompressed cpios in sequence until it reaches the compressed part. Simulation with the generated initramfs: `apic.aml SSDT-CPU SSDT-PST SSDT-STUBS AuthenticAMD.bin`, each once.
- e-tho tables with the **factory MADT** (sequential UIDs) on the normal entry: the same scenario in which the Control Center and e-tho install them on factory boards, but not yet seen on this board.

## Files
| Path | What |
|---|---|
| `bc250-nucleos-arch.sh` | the script |
| `bc250-nucleos.sh`, `acpi/*.aml` | Fedora/Nobara version and e-tho tables (the Arch script extracts `smu.py`/`madt.py` from `bc250-nucleos.sh`: both must be in the same folder) |
| `/usr/local/lib/bc250-nucleos/` | copy of the script, `smu.py`, `madt.py`, `limine.py`, `final.cpio` (MADT+SSDT), `madt.cpio` (MADT only), `acpi/` |
| `/etc/initcpio/acpi_override/SSDT-*.aml`, `/etc/mkinitcpio.conf.d/20-bc250-acpi.conf` | ACPI fix (`acpi` command) |
| `/var/lib/bc250-nucleos/` | `madt-original.aml`, `teste.conf`, `teste-resultado.txt`, `historico.log`, `boot.log` |
| `/etc/bc250-nucleos.conf` | `instalar` mode configuration |
| `/boot/bc250-nucleos.cpio`, block in `/boot/limine.conf` | boot entry |
| `/boot/limine.conf.bc250-bak` | backup of the original `limine.conf` |
| `/etc/systemd/system/bc250-nucleos-teste.service` / `bc250-nucleos-boot.service` | services |

## Check done on 2026-10-05 (before the test)

| Item | Result |
|---|---|
| Kernel | `7.2.9-1-cachyos-deckify`: `CONFIG_ACPI_TABLE_UPGRADE=y`, `CONFIG_HOTPLUG_CPU=y`, `CONFIG_X86_AMD_PSTATE=y`, `LOCK_DOWN_KERNEL_FORCE_NONE=y` |
| Lockdown / Secure Boot | `[none]` / not supported by the firmware |
| BIOS | P3.00 |
| SMU mask | `0x77` (cores 3 and 7 hidden), 12 threads, online 0-11 |
| MADT | 16 LAPIC, active 0-5 and 8-13, sequential UIDs: accepted |
| Loaded SSDTs | `AMD CPU` rev 1 and `AmdTable` rev 1 (factory: no fix active) |
| Limine | 12.9.0, one-shot OK, `ENABLE_UKI=no`, kernel entry with separate `module_path` (initramfs) + `path` (vmlinuz), with BLAKE2 hash |
| Entry initramfs | early cpio with AMD microcode only; hooks `base systemd autodetect microcode kms modconf block keyboard sd-vconsole plymouth filesystems` + `sd-btrfs-overlayfs` (snapper drop-in) |
| Script SSDTs vs Control Center | byte-for-byte identical (sha256) to the e-tho v1.1.0 payload of `bc250-control-center-git` |
| CPU OC (`bc250-smu-oc`) | disabled and did not run on this boot |
| GPU governor / CU manager | enabled (the script stops/masks them for the test) |

Offline tests: `bash -n`; `limine.py modulos/atualizar/remover` on a copy of the real `limine.conf`; `madt.py gerar` with and without SSDTs; real initramfs generated by `mkinitcpio` with the `acpi_override` hook; `acpi_na_initramfs`/`cpio_certo` with and without the hook; simulation of the kernel scan over `madt.cpio + initramfs` and `final.cpio + initramfs`.

## Test plan

Each step in a separate terminal (the script asks questions). Note the `status` output at each stage.

**Step 1: ACPI fix only (12 threads)**
```
sudo ./bc250-nucleos-arch.sh acpi
sudo reboot
sudo ./bc250-nucleos-arch.sh status      # "SSDT neste boot: AMD CPU:2 ... PSTATES:1 STUBS:1 -> correcao ATIVA"
sudo dmesg | grep -iE 'ACPI.*(override|upgrade|Error|BIOS bug)|SSDT'
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver      # compare with before (acpi-cpufreq / amd-pstate)
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
```
If it freezes or shows an ACPI error: pick a snapshot in Limine (without the fix) and run `sudo ./bc250-nucleos-arch.sh acpi-desfazer`.

**Step 2: core 7 for one boot (14 threads)**
```
sudo ./bc250-nucleos-arch.sh testar      # should say "a correcao ACPI ja esta na initramfs; o cpio leva so a MADT"
# warm-restarts by itself
sudo ./bc250-nucleos-arch.sh status      # "Ultimo teste: OK: subiu com 14 threads", SSDT with PSTATES
nproc; sudo dmesg | grep -iE 'ACPI.*(Error|override|upgrade)'
stress-ng --cpu 14 --verify -t 10m       # optional
```
If it freezes: power the board off and on (cold boot = factory state).

**Step 3: make it the default**
```
sudo ./bc250-nucleos-arch.sh instalar
```
Then recalibrate the CPU OC with 7 cores before turning `bc250-smu-oc` back on.

## Board test log

| Date | Step | Result |
|---|---|---|
| 2026-10-05 | 1. `acpi` | **OK.** After the reboot: `AMD CPU:2 AmdTable:1 PSTATES:1 STUBS:1` (fix active). dmesg: `Table Upgrade: override [SSDT- AMD- AMD CPU]`, `install [HACK PSTATES]`, `install [HACK STUBS]`, no ACPI errors. `acpi-cpufreq` with 8 P-states (800–3200 MHz: 3200/2550/2325/1960/1820/1600/1271/800), cpuidle POLL/C1/C2/C3. 12 threads. (The `dev-zram0.swap` failure existed before: zram had been disabled by the Control Center.) |
| 2026-10-05 | 2. `testar` | **OK.** Mask written `0x77`→`0xFF`; Limine's one-shot landed on the `bc250-nucleos` entry (**ID confirmed**). dmesg: `Table Upgrade: override [APIC-ALASKA- A M I]` + SSDT `AMD CPU`/`PSTATES`/`STUBS` (once each, cpio with the MADT only), `Total of 14 processors activated`, online 0-13. The test service cleaned up the entry, the cpio and the one-shot and left reboot at `cold`. `stress-ng --cpu 14 --cpu-method all --verify -t 5m`: 14/14 passed, 0 failed, Tctl ~61 °C, no MCE. (The `amdgpu dal_irq_service_ack` warnings in dmesg also show up on factory boots: unrelated.) |
| 2026-10-05 | 3. `instalar` | Installed while still on the test boot (new: `instalar` reuses the `0x77` mask, the 12 base threads and the original MADT saved by the successful `testar`, without having to power the board off). `bc250-nucleos-boot.service` enabled, `/etc/bc250-nucleos.conf` = base 12 / target 14 / CPUs 6 7 off. ACPI fix in the initramfs + cpio with the MADT only. **1st cold boot confirmed (21:43):** wrote `0xFF`, warm reset into `bc250-nucleos`, `OK: 14 threads`; reboot set to `acpi`/`cold`. At idle: `acpi-cpufreq` + `schedutil` at 800 MHz on most CPUs; C3 47–100% of the time (core 7 = 99.6%); Tctl ~40 °C (before ~47 °C) |

## Usage log (`registro/bc250-registro.py`)

The `bc250-registro.service` service (installed in `/usr/local/lib/bc250-registro/`) starts on every boot and writes one line **every 60 s** to `~/Desktop/bc250-registro/YYYY-MM-DD.csv` (one file per day, owned by your user, ~150 bytes per line ≈ 200 KB/day):

`data_hora, tctl_c, gpu_c, ppt_w, cpu_mv, n0..n7 (MHz of each physical core from the SMU; n3 = defective core, always low), threads_online, carga_1min, scx_modo, mce_boot`

(`data_hora` = timestamp, `carga_1min` = 1-minute load, `scx_modo` = scheduler mode.)

It reads the SMU through the Control Center's `bc250_smu` with `flock` (does not collide with the GPU governor). To stop: `sudo systemctl disable --now bc250-registro`.
