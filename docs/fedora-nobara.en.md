# bc250-nucleos: unlocks and tests the hidden cores of the AMD BC-250

**Languages:** [Português](fedora-nobara.md) · **English** · [Русский](fedora-nobara.ru.md)

> ## ⚠ Only works on **Fedora** and **Nobara**
> The script needs GRUB with BLS (`/boot/loader/entries` + `grub2-reboot`), EFI boot and a **non**-immutable system.
> It **does not work** on Ubuntu, Debian, Mint, Arch with GRUB, Pop!_OS (systemd-boot), Bazzite, Silverblue or SteamOS. For Arch/CachyOS with Limine use `bc250-nucleos-arch.sh` ([arch-cachyos.en.md](arch-cachyos.en.md)).
> On any other system, step 1 checks everything, stops and **changes nothing**.

> The script's menu and messages are in Portuguese.

## How to use
Copy the whole folder, including `acpi/`, to the other board and run:
```
cd bc250-7-core-unlock
sudo ./bc250-nucleos.sh
```
It opens a menu with numbered steps. Steps **only advance in order**: the ones that cannot be done yet show as `[travada]` (locked).

| Step | What it does | Reboots? |
|---|---|---|
| 1. Diagnostics | Checks the distro, boot, kernel and board. **Installs missing dependencies** (python3, cpio, stress-ng, grub2-tools) after you confirm. Reads the SMU mask and finds out **which cores are hidden** (they may differ on each board). | no |
| 2. Turn off OC | Disables the CPU OC (`bc250-smu-oc`, `bc250-cpu-escada`) and the GPU OC (governor, CU manager) and remembers which were on. | yes, normal reboot |
| 3. Test | One test per boot, in a fixed queue: each hidden core on its own; then all of them together, if more than one passes. The test runs on its own in the background (N minutes of stress). | yes, warm reset |
| 4. Result | Shows which cores are good and saves the report. | no |
| 5. Install | Keeps the good cores enabled by default. **Only does this if you confirm.** | validation |
| 6. Turn OC back on | Re-enables what was on. Recommended: only the GPU, until you recalibrate the CPU OC. | no |
| 8 / 9 | Status and history / undo everything. | |

## Safety checks
- **No core is enabled while the OC is on.** Step 3 checks that the OC services are disabled and stopped, and that the board has rebooted since step 2, because an applied OC stays in the SMU until a reboot. On the test boot the OC is also masked via the kernel line. If it is still on anyway, the test is **voided** and goes back to pending; the core is not condemned.
- State is saved in `/var/lib/bc250-nucleos/estado.env`: mask, hidden cores, result of each test and the OC services that were turned off. It survives reboots and freezes. A core that was already tested is not tested again, and you cannot skip the next test in the queue.
- **If it freezes during a test:** power the board off and on. The cold boot returns to factory state, and when you open step 3 the test left without a result is marked as **FALHOU** (failed). The queue then moves on to the next one.
- The GRUB test entry is valid for **one boot only**. The normal entry is never changed.

## How it works (summary)
- The SMU mask (SMN `0x5A870`) shows the factory cores: bit 1 is an enabled core, bit 0 a hidden core. Example: `0x77` = cores 3 and 7 hidden.
- The SMU can only write `0xFF`, which enables **all** hidden cores, and this only takes effect after a **warm** reset.
- To enable only the good ones, the boot loads a CPU table (MADT) via the initrd that lists only the desired cores. The others stay parked. The kernel needs `CONFIG_ACPI_TABLE_UPGRADE=y`.
- On BIOS P3.00, the e-tho/bc250-acpi-fix P-state and C-state tables (`acpi/` folder) go along. With them, Linux controls the CPU clock.
- After step 5, every cold boot becomes **two boots**: the first writes `0xFF` and warm-restarts by itself; the second already comes up with the good cores.

> To choose 6 or 7 cores from the GRUB menu instead of unlocking on every boot (recommended after testing), see [grub-modos.en.md](grub-modos.en.md).

## Files on the board
- State: `/var/lib/bc250-nucleos/`, with `estado.env`, `historico.log`, `teste-<core>.log`, `relatorio.txt` and `boot.log`.
- Program: `/usr/local/lib/bc250-nucleos/`. Services: `bc250-nucleos-teste.service` (only during testing) and `bc250-nucleos-boot.service` (after step 5).
- Disable for one boot: press `e` in GRUB and add `bc250.nucleos.nao`. Disable for good: `sudo touch /etc/bc250-nucleos.desligado`.

## Simulation (does not touch the board)
`BC250N_SIMULAR=1 BC250N_MASK=0xBB ./bc250-nucleos.sh` simulates another mask. State is kept in `/tmp/bc250-nucleos-sim`.


## Fixes from 2026-10-05 (from the Arch version, **not yet tested on Fedora**)
Found and confirmed on the board running CachyOS; applied here because the boot service code is the same:
- **Thread count:** `nproc --all` counted the CPUs declared in the new MADT (14) even when the hardware only had 12. It now counts online CPUs (`/proc/cpuinfo`).
- **Bad core turned off by APIC ID:** it used to turn off `cpu6`/`cpu7` by logical number; the kernel numbers CPUs in MADT order, and `cpu6` may be a different core. It now turns off the right APICs.
- **Cold reboot on the OK boot:** the service also sets the reboot to cold on the boot with the extra cores, so a normal restart never lands on the default entry with mask `0xFF`.
- **`GRUB_SAVEDEFAULT`:** if GRUB remembers the `bc250-nucleos-padrao` entry, the service clears `saved_entry` (the cold boot goes back to the default entry). It is the same problem Limine had with `remember_last_entry`.
- **BIOS P3.00 MADT:** the check accepts the sequential UIDs this BIOS uses (it used to reject the board).
