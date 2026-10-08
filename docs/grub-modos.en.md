# bc250-grub.sh: choose 6 or 7 cores from the GRUB menu (Fedora / Nobara)

**Languages:** [Português](grub-modos.md) · **English** · [Русский](grub-modos.ru.md)

> **In one sentence:** instead of the board unlocking the extra core by itself on every boot, **you now choose in the GRUB menu** whether you want 6 or 7 cores, and if something freezes it **falls back to 6 cores on its own**. No more loop.

> The script's messages and the GRUB entry names are in Portuguese ("nucleos" = cores, "destrave" = unlock, "sem OC" = without OC, "seguranca" = safety). They are shown here exactly as they appear on screen.

## Contents
- [Why this script exists (the loop problem)](#why-this-script-exists-the-loop-problem)
- [What changed compared to step 5 of bc250-nucleos.sh](#what-changed-compared-to-step-5-of-bc250-nucleossh)
- [The GRUB menu](#the-grub-menu)
- [Installation, step by step](#installation-step-by-step)
- [First test, step by step](#first-test-step-by-step)
- [Commands](#commands)
- [What happens when you choose "7 cores"](#what-happens-when-you-choose-7-cores)
- [How the loop protection works](#how-the-loop-protection-works)
- [Checks before unlocking](#checks-before-unlocking)
- [Updates (kernel, BIOS, GRUB, Control Center)](#updates)
- [ACPI power fix](#acpi-power-fix)
- [OC](#oc)
- [Something went wrong? How to go back](#something-went-wrong-how-to-go-back)
- [Files](#files)
- [Where it was tested](#where-it-was-tested)

---

## Why this script exists (the loop problem)

In the previous version (step 5 of `bc250-nucleos.sh`), a service unlocked the extra core **automatically on every cold boot**:

```
power on → service writes 0xFF → warm reset → 7 cores → (freeze) → power on again → service writes 0xFF → ...
```

If the 7-core boot freezes **after** the service has already marked the boot as "OK" (for example because of the OC or a game), the board enters a loop: every time it powers on, it unlocks and freezes again.

What made it worse: Nobara ships with the **GRUB menu hidden** (`GRUB_TIMEOUT=0`). Without the menu there was no way to pick another entry or add `bc250.nucleos.nao` to the kernel line. On the original board the only way out was to **reinstall the system**.

## What changed compared to step 5 of bc250-nucleos.sh

| | Step 5 (before) | `bc250-grub.sh` (now) |
|---|---|---|
| When it unlocks | On **every** cold boot, by itself | **Only** when the 7-core entry is chosen in GRUB (or with `padrao 7`) |
| GRUB menu | Hidden (Nobara default) | **Visible for 5 s** on every boot |
| If the 7-core boot freezes | Unlocks again on the next boot (loop) | The next boot **falls back to 6 cores on its own** |
| 6-core mode | Only the original entry (no ACPI fix) | Its own entry, **with** the ACPI fix and a CPU table that **prevents** the extra core from coming up |
| Testing without OC | Turn off the OC service by hand | Ready-made **"7 cores without OC"** entry |
| Secure Boot on, or CPU table not loaded | Carried on: the bad core could run code during boot | **Cancels** the unlock before writing the mask |
| BIOS updated | Used the table generated for the old BIOS | **Cancels** the unlock until you reinstall |
| Kernel update | Entry recreated only on the next boot | Recreated right away (`kernel-install` hook); the default stays at 6 cores |
| Control Center ACPI fix installed later | Tables would load twice | Detects it and uses only the CPU table |

`bc250-grub.sh` **replaces** step 5. Steps 1 to 4 of `bc250-nucleos.sh` (testing each hidden core) are still the way to find out **which** core is good. This script is for when you already know.

## The GRUB menu

Once installed, the menu shows for 5 seconds on every boot:

```
BC-250: 6 nucleos (normal)              <- default. Never unlocks
BC-250: 7 nucleos (destrave)            <- 7 cores, with OC
BC-250: 7 nucleos sem OC (seguranca)    <- 7 cores, OC off for this boot only
Nobara Linux (7.2.9-...)                <- original system entry, untouched
```

| Entry | Cores | OC | ACPI fix | What for |
|---|---|---|---|---|
| **6 nucleos (normal)** | 6 | on | yes | Safe use. This is the default |
| **7 nucleos (destrave)** | 7 | on | yes | Normal use with the extra core |
| **7 nucleos sem OC** | 7 | **off** | yes | First test, or when the OC is unstable |
| **Nobara Linux** | 6 | on | no | Last resort: system boot with nothing from this project |

Use the arrow keys to choose and Enter to boot. If nobody touches anything, GRUB goes to the default.

## Installation, step by step

Requirements: Fedora or Nobara, GRUB with BLS (the default on these systems), EFI boot, Secure Boot **off**, `/boot` on ext4 or xfs. The script checks all of this and **changes nothing** if something is missing.

1. Download the whole folder. The script uses the `bc250-nucleos.sh` and `acpi/` files next to it:
   ```
   git clone https://github.com/reinaldovcaetano/bc250-7-core-unlock
   cd bc250-7-core-unlock
   ```
2. (Optional) Check the board. Read-only, changes nothing:
   ```
   sudo ./verificar-placa.sh
   ```
   Shows the SMU mask, the BIOS CPU table, the GRUB entries and `grubenv`.
3. Install:
   ```
   sudo ./bc250-grub.sh instalar
   ```
   It shows what it will create and asks `Instalar agora? [s/N]` ("Install now? [y/N]"). Answer `s` (yes).
   - A different extra core (for example core 6): `sudo NUCLEOS="6" ./bc250-grub.sh instalar`
   - Running it again is safe: it recreates everything and keeps the chosen default. Run it in 6-core mode.

Expected output (summarised):
```
  OK  mascara 0x77: ocultos = 3 7; liga = 7
  OK  BIOS P3.00: as SSDT do e-tho v1.1.0 (sha256 conferido) vao junto nos dois modos
  OK  menu do GRUB visivel por 5 s
  OK  entradas criadas a partir do kernel 7.2.9-200.nobara.fc44.x86_64
  OK  padrao gravado do GRUB: bc250-6nucleos
  OK  Instalado. Padrao: 6 nucleos.
```

## First test, step by step

Do **one step at a time** and only move on if the previous one worked.

1. **6 cores.** Reboot and let GRUB go to "6 nucleos (normal)" by itself. Then:
   ```
   sudo bc250-grub.sh status
   cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver     # expected: acpi-cpufreq
   nproc                                                       # expected: 12
   ```
   This confirms that the CPU table and the power fix load, with no risk at all.
2. **7 cores without OC.** Reboot and choose "7 nucleos sem OC (seguranca)". The board comes up, **restarts by itself once** (that is the warm reset) and comes back. Then:
   ```
   nproc                                                       # expected: 14
   sudo bc250-grub.sh status                                   # "OK: bc250-7nucleos-semoc com 14 threads"
   ```
   Leave it running **at least 5 minutes**. That is how long it takes for the boot to count as confirmed. A stress test:
   ```
   sudo dnf install stress-ng
   stress-ng --cpu $(nproc) --cpu-method all --verify -t 15m
   ```
3. **7 cores with OC.** Reboot and choose "7 nucleos (destrave)". Repeat the stress test.
4. **Make 7 the default** (optional, only once everything is stable):
   ```
   sudo bc250-grub.sh padrao 7
   ```

If it freezes at any step: **power the board off and on**. It falls back to 6 cores by itself.

## Commands

Once installed, the command is available from any folder as `sudo bc250-grub.sh`.

| Command | What it does |
|---|---|
| `sudo bc250-grub.sh status` | Shows threads, mask, current entry, default, cycle state, `saved_entry`/`next_entry`, recent boots and the last failure |
| `sudo bc250-grub.sh padrao 6` | GRUB goes to 6 cores by itself (the initial default) |
| `sudo bc250-grub.sh padrao 7` | GRUB goes to 7 cores by itself, with loop protection |
| `sudo bc250-grub.sh desfazer` | Removes everything and asks whether the GRUB menu should be hidden again (recommended: keep it visible) |
| `sudo ./bc250-grub.sh instalar` | Installs or reinstalls (run from the project folder) |

**Illustrative** example of `status` on a 7-core boot (example times):
```
BC-250: nucleos pelo GRUB
  Agora: 14 threads (APIC 0 1 2 3 4 5 8 9 10 11 12 13 14 15) | mascara 0xFF | entrada: bc250-7nucleos (modo 7)
  Padrao: 6 nucleos | estado do ciclo:  | servico: enabled
  GRUB: saved_entry=bc250-6nucleos
    BC-250: 6 nucleos (normal)  [7.2.9-200.nobara.fc44.x86_64]
    BC-250: 7 nucleos (destrave)  [7.2.9-200.nobara.fc44.x86_64]
    BC-250: 7 nucleos sem OC (seguranca)  [7.2.9-200.nobara.fc44.x86_64]
  Boots:
    2026-10-08 20:01:12 mascara: mascara depois da gravacao: 0xFF; reset quente para bc250-7nucleos
    2026-10-08 20:01:58 OK: bc250-7nucleos com 14 threads (confirma em 300s ou no desligamento limpo)
    2026-10-08 20:06:58 confirmado: 14 threads de pe (modo 7)
```
(`Agora` = now, `Padrao` = default, `estado do ciclo` = cycle state, `reset quente` = warm reset, `confirmado` = confirmed.)

## What happens when you choose "7 cores"

The hardware only accepts the extra core after a **warm reset** (a restart without cutting power). That is why every 7-core boot becomes **two boots**, the second one automatic:

```
1st boot (7-core entry, factory mask 0x77, 12 threads)
   ~20 s longer: the new table declares a core that does not exist yet and the kernel waits for it
   service: checks the safeguards → writes 0xFF to the SMU → marks the same entry for the next boot → WARM reset
2nd boot (same entry, mask 0xFF, 14 threads)
   service: checks the cores → "OK" → makes the next reboot COLD
   after 5 min of uptime (or on a normal shutdown): "confirmed"
```

- **The CPU table (MADT)** in the entry's initrd is what **chooses the cores**. In it, core 3 (defective) is disabled: the kernel never wakes it.
- **Rebooting or shutting down** after that is always cold: the mask goes back to the factory 0x77.

## How the loop protection works

Three simple ideas, stacked on top of each other:

**1. GRUB's saved default is always "6 cores".**
GRUB's `saved_entry` always points to `bc250-6nucleos`. The service re-applies this on every boot, and the kernel hook on every update (Fedora has `UPDATEDEFAULT=yes`, which switches the default to the new kernel).

**2. "Default 7" is a one-way ticket.**
With `padrao 7`, the script uses GRUB's `next_entry`: it is valid for **one** boot only, and **GRUB itself erases it** before starting Linux. The ticket is only renewed when the 7-core boot proves it stayed up:
- it ran for **5 minutes** (`ESTAVEL="300"` in `/etc/bc250-grub.conf`), **or**
- it was **shut down normally** (a freeze is not a normal shutdown).

If it freezes at any point before that, the ticket is already spent and the next boot goes to the saved default: **6 cores**.

**3. Failure detected and logged.**
The script keeps in `/var/lib/bc250-grub/tentativa` where in the cycle it is (`armado`: next boot scheduled for 7; `destravando`: warm reset done, waiting for confirmation). If a 6-core boot finds this file, the 7-core boot did not finish. The script then:
- logs the failure in `boot.log` and `ultima-falha`
- switches the default to **6**
- warns in the terminal (`wall`) and in `status`

To try 7 again: choose it in the menu, or `sudo bc250-grub.sh padrao 7`.

| Scenario | What happens on the next boot |
|---|---|
| 7-core boot freezes (default 6) | 6 cores; failure logged |
| 7-core boot freezes (default 7) | 6 cores (the ticket was already spent); default goes back to 6 |
| Freezes on the 1st boot, before the service runs | 6 cores; default goes back to 6 |
| Warm reset lands on an entry without the new table (16 threads) | The service immediately turns off the threads of the hidden cores that were not chosen, by APIC ID |
| You chose "6 cores" while the default was 7 | Counts as a failure and the default becomes 6 (conservative on purpose) |

> **Why does `/boot` need to be ext4 or xfs?** GRUB can only erase the ticket (`next_entry`) if it can write the `grubenv` file, and it cannot write on btrfs. Without that, the ticket would never be erased. `instalar` checks this.

**What if the GRUB menu gets hidden again** (for example by a Nobara update)? The protection keeps working, because it does not depend on you seeing the menu.

## Checks before unlocking

Before writing 0xFF to the SMU, the service checks all of this. If any item fails, it **does not unlock**, boots with 6 cores and logs the reason in `status`:

| Check | Why |
|---|---|
| The **new CPU table is in use** on this boot, with the right cores enabled (`confere_madt.py`) | Without it, the warm reset would come up with the BIOS table and the kernel would **wake the bad core** before any service could turn it off |
| **Lockdown** = `none` (Secure Boot off) | With lockdown, the kernel ignores tables from the initrd |
| **BIOS** same as at install time (version and date) | Another BIOS may have a different CPU table; the generated one may not fit |
| **Mask** equal to the factory one (0x77) | Odd state: better to unplug the board |
| `bc250.nucleos.nao` on the kernel line, or `/etc/bc250-grub.desligado` exists | Disabled on purpose |

## Updates

| What gets updated | What happens |
|---|---|
| **Kernel** | The hook recreates the entries for the new kernel. If it comes **without** `CONFIG_ACPI_TABLE_UPGRADE`, the BC-250 entries are removed and only the Nobara one remains (6 cores, no ACPI fix) |
| **Secure Boot turned on** | Unlock cancelled (lockdown and CPU table checks) |
| **BIOS** | Unlock cancelled until you run `sudo ./bc250-grub.sh instalar` again |
| **Control Center ACPI fix** (tables in the initramfs) | The entries switch to the cpio with only the CPU table, so the tables are not loaded twice |
| **GRUB or `/etc/default/grub`** | If the menu gets hidden again, the loop protection keeps working |
| **This project** (`git pull`) | Run `sudo ./bc250-grub.sh instalar` again to update the copy in `/usr/local/lib/bc250-grub/` |

In every case, the worst outcome is **booting with 6 cores**, with the reason logged in `sudo bc250-grub.sh status`.

## ACPI power fix

The P3.00 BIOS does not tell Linux the clock levels (P-states) or idle states (C-states), so the CPU always stays at maximum clock. The 3 tables from [e-tho/bc250-acpi-fix](https://github.com/e-tho/bc250-acpi-fix) (`acpi/` folder, verified by sha256) fix that:

- **Clock controlled by Linux:** 8 levels, from **800 to 3200 MHz** (`acpi-cpufreq`).
- **Idle:** the cores sleep in C1–C3.
- **The OC (3850 MHz) is separate:** it is applied by the SMU, through `bc250-smu-oc`. The tables do not change the maximum clock.

They are included in **both** BC-250 entries (6 and 7 cores), only if the BIOS is P3.00 and the initramfs does not have them yet. The original Nobara entry does not get them.

**Do not also install the BC250 Control Center "ACPI fix"**: they are the same tables. If you install it anyway, the script detects it and does not load them twice.

## OC

- The service runs **before** `bc250-smu-oc`, so the OC is only applied after the unlock.
- On the **"7 cores without OC"** entry, the `bc250-smu-oc`, `cyan-skillfish-governor-smu` and `bc250-cu-live-manager` services (whichever exist) are masked **for that boot only**. Nothing changes in the configuration.
- An OC calibrated with 6 cores may be unstable with 7. Test without OC first and recalibrate in the Control Center afterwards if needed.

## Something went wrong? How to go back

| Situation | What to do |
|---|---|
| Froze on the 7-core boot | Power the board off and on. It falls back to 6 cores by itself |
| I want 6 cores now | Choose "BC-250: 6 nucleos (normal)" in the menu |
| The script's 6-core entry has a problem | Choose "Nobara Linux (...)", the original, untouched entry |
| I never want it to unlock | `sudo touch /etc/bc250-grub.desligado` (to re-enable: `sudo rm /etc/bc250-grub.desligado`) |
| Disable for one boot only | In GRUB: press `e` on the entry, add `bc250.nucleos.nao` at the end of the `linux` line, then Ctrl+X |
| See what happened | `sudo bc250-grub.sh status` and `sudo cat /var/lib/bc250-grub/boot.log` |
| Remove everything | `sudo bc250-grub.sh desfazer`, then reboot |

## Files

| Where | What |
|---|---|
| `/usr/local/lib/bc250-grub/` | Program: `bc250-grub.sh`, `smu.py`, `madt.py`, `confere_madt.py`, `6.cpio`/`7.cpio` (CPU table + ACPI), `6m.cpio`/`7m.cpio` (CPU table only), `acpi/` |
| `/usr/local/sbin/bc250-grub.sh` | Shortcut to the command |
| `/etc/bc250-grub.conf` | Configuration: mask, cores, threads, APIC, BIOS, `ESTAVEL`, `PADRAO` |
| `/var/lib/bc250-grub/` | `boot.log` (every boot), `historico.log` (manual actions), `tentativa`, `ultima-falha`, `madt-original.aml`, backups of `/etc/default/grub` and `grub.cfg` |
| `/boot/loader/entries/bc250-*.conf` | The 3 GRUB entries |
| `/boot/bc250-6nucleos.cpio`, `/boot/bc250-7nucleos.cpio` | Extra initrd for each mode |
| `/etc/systemd/system/bc250-grub.service` | Service that runs on every boot (and at shutdown, to confirm) |
| `/etc/kernel/install.d/96-bc250-grub.install` | Hook that recreates the entries on every kernel update |

## Where it was tested

| | |
|---|---|
| Board | AMD BC-250, BIOS **P3.00** (12/09/2021), factory mask `0x77` (cores 3 and 7 hidden; 7 good, 3 defective) |
| System | **Nobara** 44, kernel `7.2.9-200.nobara.fc44`, GRUB 2.12 with BLS, EFI, `/boot` on ext4 |
| Date | 2026-10-08 |

| What | Status |
|---|---|
| Board check (`verificar-placa.sh`): mask, MADT, SSDT, entries, `grubenv`, `grub.cfg` | Checked on the board; same as CachyOS where it matters |
| `instalar` | Run on the board: entries, cpio, service, hook and GRUB menu checked on disk |
| Loop protection (6 scenarios: normal unlock, freeze with default 6 and 7, freeze before the service, warm reset on the wrong entry) | Simulated with fake commands; all fell back to 6 cores |
| `confere_madt.py` | Tested against the BIOS table (rejects) and against the generated ones (accepts) |
| Real boot of **"6 nucleos (normal)"** | **OK.** 12 threads, mask `0x77`, CPU table and the 3 SSDTs loaded from the initrd (`Table Upgrade: override [APIC…]`, `[SSDT… AMD CPU]`, `install STUBS` and `PSTATES`), `acpi-cpufreq` active |
| Real boot of **"7 nucleos (destrave)"** (with OC 3850 / −30) | **OK.** A single warm reset (about 18 s), came up with **14 threads** (APIC 0–5 and 8–15, mask `0xFF`), defective core 3 stayed out, and the boot was **confirmed** after 5 min. GRUB's default stayed at 6 cores |
| 7-core stress with OC | `stress-ng --cpu 14 --verify` for **9 min 41 s**: **14/14 passed, 0 failed**, no hardware errors (MCE) in the kernel |
| Real boot of "7 nucleos sem OC (seguranca)" | Not tested yet (it is only the emergency option) |
| Real freeze on 7 cores (automatic fallback to 6) | Has not happened, so only tested by simulation |

### Stress measurements (Nobara, 7 cores, OC 3850 MHz / scale −30)

| | Measured |
|---|---|
| Clock under load | **3822–3842 MHz on all 14 threads** for the whole test |
| Temperature (Tctl) | steady at **~80 °C**, peak **82.2 °C** (OC limit: 90 °C) |
| Power (PPT) | 60–69 W |
| Idle right after boot | Tctl ~45 °C, PPT ~34 W; with `schedutil`, the cores drop to 800–1700 MHz |
| Scheduler | The kernel default (EEVDF), **without** `scx_lavd`. Unlike on CachyOS, no core got stuck at ~1700 MHz under load, so Gaming mode was not needed |

> **Temperature:** about **12 °C higher** than measured on CachyOS (~68 °C) at similar power (differences: scale −30 vs −31, room temperature and airflow that day). There is still headroom up to 90 °C, but keep an eye on the cooler and airflow, especially in hot weather and with heavy games.

The part that touches the hardware (SMU, warm reset, CPU table via initrd) is the same as in `bc250-nucleos.sh`, validated earlier on CachyOS with 14 threads and a 3850 MHz OC.
