# bc250-nucleos-arch: núcleo 7 da BC-250 no Arch / CachyOS (Limine)

Versão do `bc250-nucleos.sh` para **Arch/CachyOS com o bootloader Limine**. O script original só funciona em Fedora/Nobara (GRUB com BLS).

Também instala a **correção ACPI do e-tho** (P-states/C-states, as mesmas tabelas da "correção ACPI" do BC250 Control Center) em todo boot, **com ou sem o núcleo extra**, sem trocar o Limine por GRUB/systemd-boot.

> **Situação em 2026-10-05:** script escrito e testado **offline** (sintaxe, auxiliares, edição de uma cópia do `limine.conf` real, tabela gerada a partir da MADT real da placa, initramfs gerada com o hook `acpi_override`, varredura do initrd simulada como o kernel faz). **Testado na placa em 2026-10-05:** passo 1 (`acpi`) e passo 2 (`testar`, 14 threads + 5 min de estresse) OK. Veja o [registro dos testes](#registro-dos-testes-na-placa).

## A placa

| | |
|---|---|
| Sistema | CachyOS (`linux-cachyos-deckify` 7.2.9), Limine 12.9.0, EFI, Secure Boot desligado, lockdown `none` |
| BIOS | P3.00 (12/09/2021), com a SSDT "AMD CPU" de fábrica |
| Máscara SMU | `0x77`: núcleos **3 e 7 ocultos**; 12 threads (APIC 0–5 e 8–13) |
| Testes anteriores (no Nobara) | **núcleo 7 bom**, núcleo 3 com defeito |
| Objetivo | ligar só o núcleo 7: **14 threads** (APIC 0–5 e 8–15; APIC 6/7 = núcleo 3 parado) |

## Antes de começar (obrigatório)

1. **Desligar o OC da CPU** e reiniciar normalmente:
   ```
   sudo systemctl disable bc250-smu-oc
   sudo reboot
   ```
   O OC (3850 MHz, scale −31) foi calibrado com 6 núcleos. Na placa original, o OC antigo travou a imagem com 7 núcleos. O OC aplicado fica na SMU e **sobrevive ao reset quente**. O script se recusa a rodar se o `bc250-smu-oc` estiver habilitado ou tiver rodado no boot atual.
   Se o OC tiver sido aplicado pelo app do BC250 Control Center (e não pelo serviço), o script não detecta. Então **não aplique o OC pelo app** antes do teste.
2. Estar no kernel padrão da entrada do Limine (não num snapshot nem num kernel recém-instalado sem reboot).
3. SMT ligado (as contas de threads supõem 2 por núcleo).

## Uso

```
cd ~/Downloads/bc250-nucleos
sudo ./bc250-nucleos-arch.sh testar     # liga o núcleo 7 em UM boot só
sudo ./bc250-nucleos-arch.sh status     # resultado; nproc deve dar 14
sudo ./bc250-nucleos-arch.sh instalar   # deixa ligado como padrão (todo boot frio vira 2 boots)
sudo ./bc250-nucleos-arch.sh desfazer   # remove o núcleo extra (não mexe na correção ACPI)
sudo ./bc250-nucleos-arch.sh acpi           # correção ACPI do e-tho em todo boot
sudo ./bc250-nucleos-arch.sh acpi-desfazer  # remove a correção ACPI
```
Rode num terminal à parte, porque o script faz perguntas. `NUCLEOS="7"` é o padrão; outra lista pode ser passada pela variável.

Teste de estresse opcional durante o boot de teste: `sudo pacman -S stress-ng` e depois `stress-ng --cpu 14 --verify -t 10m`.

### `testar` (um boot só)
1. Confere distro, Limine com one-shot, EFI, `CONFIG_ACPI_TABLE_UPGRADE`, placa, OC desligado, máscara e MADT.
2. Gera o cpio com a MADT nova (+ as SSDT do e-tho, se a correção ACPI ainda não estiver na initramfs) e copia para `/boot/bc250-nucleos.cpio`.
3. Acrescenta a entrada `/bc250-nucleos` no fim do `/boot/limine.conf`. Faz backup em `/boot/limine.conf.bc250-bak` (só na 1ª vez). A linha do kernel ganha `bc250.nucleos=teste` e `systemd.mask=` dos serviços de OC e governor.
4. Para o governor da GPU, grava `0xFF` na máscara pela SMU, faz `bootctl set-oneshot bc250-nucleos` e reinicia **a quente**.
5. No boot de teste, o serviço `bc250-nucleos-teste.service` confere as threads, **remove a entrada e o cpio**, volta o reboot para frio e se desabilita. O próximo reboot normal volta ao padrão de fábrica.

### `instalar` (padrão)
Pode ser corrido num boot normal (12 threads) ou **logo depois de um `testar` OK, ainda no boot de teste**. Neste caso usa a máscara de fábrica, as threads de base e a MADT original que o `testar` guardou em `/var/lib/bc250-nucleos/` (só se a linha do kernel tiver `bc250.nucleos=teste` e o resultado for `OK`).

Instala `bc250-nucleos-boot.service`. Em todo boot frio, o 1º boot (entrada normal, 12 threads) grava `0xFF` e reinicia a quente na entrada `bc250-nucleos`. O 2º boot sobe com 14 threads. A entrada do Limine é recriada a cada boot a partir da entrada do kernel, então sobrevive ao `limine-entry-tool` e a atualizações.

Desligar por um boot: no Limine, tecla `e` e acrescentar `bc250.nucleos.nao`. Desligar de vez: `sudo touch /etc/bc250-nucleos.desligado`. Se uma tentativa não chegar a 14 threads, para de tentar (`sudo rm /var/lib/bc250-nucleos/falhou` para tentar de novo).

### `acpi` (correção ACPI em todo boot)
Por que não usar o instalador do Control Center: ele só aceita GRUB ou systemd-boot Type #1 e acusa o Limine como "UKI" (falso: aqui `ENABLE_UKI=no` e o Limine carrega `vmlinuz` e `initramfs` separados). Este comando faz o mesmo pelo caminho nativo do Arch:

1. Confere distro, Limine, `limine-mkinitcpio`, hook `acpi_override`, `CONFIG_ACPI_TABLE_UPGRADE`, lockdown, BC-250 com BIOS P3.00 e o **sha256** das 3 SSDT (iguais às do e-tho v1.1.0 e ao payload do Control Center).
2. Recusa se já houver outra correção: SSDT `PSTATES`/`STUBS`/`P_CST3` ou `AMD CPU` rev ≥ 2 carregadas, `bc250-acpi` no `limine.conf`, ou `.aml` em `/etc/initcpio/acpi_override` ou `/usr/lib/initcpio/acpi_override`.
3. Copia as SSDT para `/etc/initcpio/acpi_override/` e cria `/etc/mkinitcpio.conf.d/20-bc250-acpi.conf` com `HOOKS+=(acpi_override)`. O `mkinitcpio.conf` principal não é editado.
4. Roda `limine-mkinitcpio` e confere se as SSDT entraram no cpio early da initramfs da entrada do kernel. Se não entrarem, desfaz sozinho.

Como é um drop-in do mkinitcpio, sobrevive a atualizações do kernel. Os snapshots antigos do Limine continuam sem a correção (usam initramfs antigas).

Depois do `acpi`, o checker do Control Center passa a mostrar "tabelas modificadas por outra correção" e bloqueia o instalador dele. **É o esperado**, porque impede a instalação em dobro.

### Núcleo extra + correção ACPI juntos
A entrada `bc250-nucleos` do Limine carrega `bc250-nucleos.cpio` **antes** da initramfs normal. Para nunca carregar as SSDT em dobro, o script gera dois cpios e escolhe um em todo boot:

| Correção ACPI instalada? | `bc250-nucleos.cpio` leva | Resultado no boot com o núcleo extra |
|---|---|---|
| sim (SSDT na initramfs) | `madt.cpio`: só a MADT | MADT nova + SSDT 1 vez |
| não | `final.cpio`: MADT + SSDT | MADT nova + SSDT 1 vez |

A escolha (`cpio_certo`) olha o cpio early da initramfs referenciada pela entrada do kernel. Por isso, instalar ou desfazer a correção ACPI depois do núcleo extra não exige reinstalar nada.

## Se der problema
- **Travou:** desligue e ligue a placa. O boot frio volta a máscara de fábrica (`0x77`, 12 threads).
- **Subiu com 16 threads** (núcleo 3 ligado): o serviço desliga as CPUs 6 e 7 na hora e registra no `status`. Reinicie normalmente.
- **O boot de teste caiu na entrada normal:** provavelmente o ID `bc250-nucleos` no Limine é outro (veja abaixo). Anote a saída de `status` e de `bootctl list`.
- **Limine não sobe:** escolha outra entrada no menu, ou restaure `/boot/limine.conf.bc250-bak`.

## O que mudou em relação ao script original

| Original (Fedora/Nobara) | Arch/CachyOS |
|---|---|
| Só Fedora/Nobara | Arch/CachyOS (`ID`/`ID_LIKE` = arch) |
| Entrada BLS no GRUB (`/boot/loader/entries`) | Bloco no fim do `limine.conf` entre `# >>> bc250-nucleos` e `# <<< bc250-nucleos`, com o cpio como 1º `module_path` |
| `grub2-reboot` | `bootctl set-oneshot bc250-nucleos` (Limine tem "One-shot entry control") |
| Kernel conferido em `/boot/config-*` | `/proc/config.gz` do kernel rodando; se a entrada usar outro kernel, não libera |
| `dnf install` | Só precisa de `python` e `cpio` (já instalados) |
| Fila de testes 3 → 7 → todos | Sem fila: o núcleo 7 já foi testado |
| OC só avisado | **Trava** se o OC da CPU estiver habilitado ou aplicado no boot |

`smu.py` e `madt.py` são extraídos do `bc250-nucleos.sh` original (precisa ficar na mesma pasta), sem mudar o resto.

### Correção na checagem da MADT
A checagem original exigia **UID = APIC+1** e teria recusado esta BIOS. A BIOS P3.00 numera os UID em sequência só nos núcleos ativos (APIC 8 → UID 7). As SSDT do e-tho usam `P000`…`P00F`, com o `_CSD` agrupando duas threads por núcleo físico (P00E/P00F = núcleo 7 = APIC 14/15), ou seja, P00x = APIC x. A MADT gerada (UID = APIC+1) é a coerente. A checagem agora aceita também o layout em sequência. Qualquer outro layout continua recusado.

Tabela gerada (conferida, checksum OK):
```
APIC 0-5   ligados   (núcleos 0-2)
APIC 6-7   DESLIGADOS (núcleo 3, defeito)
APIC 8-15  ligados   (núcleos 4-7)
```

## Compatibilidade com o BC250 Control Center

| Item | Efeito |
|---|---|
| OC da CPU (`bc250-smu-oc`) | **Desligar antes.** Recalibrar com 7 núcleos (detecção do Control Center) antes de religar |
| Cyan Skillfish Governor | OK: o script para antes de falar com a SMU (religa se a gravação falhar) e mascara no boot de teste |
| "Gestão de energia da CPU · ACPI" | **Não instalar pelo Control Center** (ele não aceita Limine). Use `acpi` deste script, que instala as mesmas tabelas e combina com o núcleo extra sem carregar em dobro |
| Kernel MastaG / outro kernel | Conferir `zcat /proc/config.gz \| grep ACPI_TABLE_UPGRADE` nele; não trocar de kernel no meio do teste |
| Mesa / GFX1013 / FSR4 | Sem efeito |
| Mitigações | Sem efeito |
| Desativar SMT | **Atrapalha** (as contas de threads deixam de valer) |
| Controle da ventoinha | Sem efeito (bom deixar ligado) |

## Proteções contra o núcleo 3 (auditoria de 2026-10-05)

A SMU só aceita "liberar todos" (`0xFF`): depois da gravação, o núcleo 3 fica ligado no hardware até um reset frio. O que impede o kernel de usá-lo:

| Camada | Como | Conferido |
|---|---|---|
| MADT nova | APIC 6 e 7 com `flags=0` (nem habilitados, nem *online capable*) | `madt.cpio` em `/boot` idêntico ao gerado; checksum OK; `possible=present=online=0-13`, sem `cpu14/15` no sysfs: não dá para ligá-los nem por hotplug |
| Entrada `bc250-nucleos` | só é marcada (one-shot) depois de a entrada ser escrita e o kernel conferido (`uname -r`) | ID confirmado no teste |
| Reboot depois do boot com 14 threads | **corrigido:** o `_boot` passa a fixar reboot **frio** (`acpi`/`cold`) também no boot OK. Antes ficava o padrão do kernel; um reset quente com `0xFF` que caísse na entrada normal subiria 16 threads | |
| Entrada normal com 16 threads (reset quente que escapou) | o serviço desliga as threads do núcleo 3 na hora e segue | **corrigido:** antes desligava `cpu6`/`cpu7` pelo **número lógico**. O kernel numera as CPUs na ordem da MADT: neste boot `cpu6`/`cpu7` = APIC 8/9 (núcleo 4, bom). Agora desliga pelo **ID APIC** lido do `/proc/cpuinfo` e registra se falhar |
| Tentativa que não chega a 14 | arquivo `falhou`: para de tentar e volta o reboot para frio | |

Limitação que sobra: se um reset quente cair na entrada normal, o kernel acorda o núcleo 3 durante o boot, antes de o serviço desligá-lo. As duas correções acima tornam esse caminho bem mais improvável.

## Bug corrigido: `remember_last_entry` do Limine (2026-10-05)

Num boot frio às 22:03 a placa subiu com **12 threads** e o serviço registrou `OK: 14 threads`. Duas causas:
1. O Limine (`remember_last_entry: yes`) guarda a última entrada em `LimineLastBootedEntry` (EFI). Ela era `bc250-nucleos`, então o boot frio foi direto para a entrada com a MADT nova, mas com a máscara de fábrica: o kernel esperou ~20 s pelos APIC 14/15 ausentes (`Total of 12 processors activated` aos 20,2 s).
2. `threads()` usava `nproc --all`, que conta as CPUs **declaradas** (14 na MADT nova), não as **online** (12).

Correção: `threads()` conta as CPUs online (`/proc/cpuinfo`), e o `_boot` apaga `LimineLastBootedEntry` quando ela aponta para `bc250-nucleos`. O próximo boot frio volta para a `default_entry`; o one-shot não usa essa variável. Era o "ponto não confirmado" do `remember_last_entry` acima: a suposição de que o serviço seguiria o fluxo normal estava errada por causa da contagem.

## OC da CPU com a correção ACPI (detector do Control Center)

Com a correção ACPI, o Linux passa a controlar a frequência (`acpi-cpufreq` + `schedutil`). Sob o estresse do detector, o `schedutil` deixa alguns núcleos em P-states mais baixos (1577–2184 MHz). O `bc250-detect` acha que é throttling e **aborta no primeiro degrau** (fica em `3500 + alvo % 100`, ex.: 3550 / scale −2), qualquer que seja o VID.

Medido em 2026-10-05 (clock dos 8 núcleos pela SMU, carga em 14 threads): com `performance`, todos a 3550 menos o núcleo 3 (com defeito, sem carga, 1577 MHz: o detector o marca como inativo, correto); com `schedutil`, núcleos variando para 1577–2184.

**Para detectar o OC:** governador `performance` durante a detecção, e depois voltar:
```
echo performance | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
# detecção no Control Center
echo schedutil | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
```
(o governador volta para `schedutil` sozinho no próximo boot).

## Escalonador `scx_lavd` (CachyOS) e frequência

O CachyOS usa o escalonador sched_ext `scx_lavd`. No modo **Auto** (`--autopilot`) ele faz compactação de núcleos e define o alvo de frequência que o `schedutil` segue: num `stress-ng` de 14 threads com **99% de uso em todas as CPUs**, 6 delas ficaram em **1707 MHz** (medido em 2026-10-05 com OC 3850/−31). Também é a causa provável de a detecção de OC abortar (seção acima).

Solução: modo **Gaming** (`--performance`) como padrão em `/etc/scx_loader.toml` (`default_mode = "Gaming"`, backup em `.bak`; vale depois de `systemctl restart scx_loader` ou no próximo boot). Resultado: as 14 CPUs a 3842 MHz sob carga, e em repouso o mesmo consumo do Auto (PPT ~31,7 W, núcleos a 800 MHz, C3 ~97% do tempo).

Stress com OC 3850/−31 + 7 núcleos + Gaming: 14/14 passed, 0 failed (interrompido aos ~6,5 min, ~4,5 min com todos a 3850), Tctl estável em 68 °C, PPT ~62–66 W, 1175–1181 mV.

## Kernel
Para funcionar, o kernel precisa de `CONFIG_ACPI_TABLE_UPGRADE=y` e não pode estar em lockdown (Secure Boot). Sem isso, ele ignora a MADT nova. Depois do reset quente a BIOS mostra os 8 núcleos, e o **núcleo 3 defeituoso subiria**. O script confere as duas coisas e, se mesmo assim subirem 16 threads, desliga as CPUs 6 e 7.

## Pontos não confirmados
- ~~ID da entrada no Limine~~: **confirmado** em 2026-10-05: `bootctl set-oneshot bc250-nucleos` bootou a entrada `/bc250-nucleos`.
- `remember_last_entry: yes` no `limine.conf`: no modo `testar` não importa, porque a entrada é removida. No modo `instalar`, se o Limine lembrar a entrada `bc250-nucleos`, um boot frio cai nela com a máscara de fábrica. O kernel tenta acordar o APIC 14/15 ausente (alguns segundos de atraso), sobe com 12 threads e o serviço segue o fluxo normal.
- O Limine junta vários `module_path` num initrd só; o cpio da ACPI vai primeiro e sem compressão, como o kernel exige. O kernel (`lib/earlycpio.c`) percorre os cpios sem compressão em sequência até chegar na parte comprimida. Simulação com a initramfs gerada: `apic.aml SSDT-CPU SSDT-PST SSDT-STUBS AuthenticAMD.bin`, cada um uma vez.
- Tabelas do e-tho com a **MADT de fábrica** (UIDs em sequência) na entrada normal: é o mesmo cenário em que o Control Center e o e-tho as instalam em placas de fábrica, mas ainda não foi visto nesta placa.

## Arquivos
| Caminho | O quê |
|---|---|
| `bc250-nucleos-arch.sh` | o script |
| `bc250-nucleos.sh`, `acpi/*.aml` | versão Fedora/Nobara e tabelas do e-tho (o script do Arch extrai o `smu.py`/`madt.py` do `bc250-nucleos.sh`: os dois têm de ficar na mesma pasta) |
| `/usr/local/lib/bc250-nucleos/` | cópia do script, `smu.py`, `madt.py`, `limine.py`, `final.cpio` (MADT+SSDT), `madt.cpio` (só MADT), `acpi/` |
| `/etc/initcpio/acpi_override/SSDT-*.aml`, `/etc/mkinitcpio.conf.d/20-bc250-acpi.conf` | correção ACPI (comando `acpi`) |
| `/var/lib/bc250-nucleos/` | `madt-original.aml`, `teste.conf`, `teste-resultado.txt`, `historico.log`, `boot.log` |
| `/etc/bc250-nucleos.conf` | configuração do modo `instalar` |
| `/boot/bc250-nucleos.cpio`, bloco no `/boot/limine.conf` | entrada de boot |
| `/boot/limine.conf.bc250-bak` | backup do `limine.conf` original |
| `/etc/systemd/system/bc250-nucleos-teste.service` / `bc250-nucleos-boot.service` | serviços |

## Verificação feita em 2026-10-05 (antes do teste)

| Item | Resultado |
|---|---|
| Kernel | `7.2.9-1-cachyos-deckify`: `CONFIG_ACPI_TABLE_UPGRADE=y`, `CONFIG_HOTPLUG_CPU=y`, `CONFIG_X86_AMD_PSTATE=y`, `LOCK_DOWN_KERNEL_FORCE_NONE=y` |
| Lockdown / Secure Boot | `[none]` / sem suporte no firmware |
| BIOS | P3.00 |
| Máscara SMU | `0x77` (núcleos 3 e 7 ocultos), 12 threads, online 0-11 |
| MADT | 16 LAPIC, ativos 0-5 e 8-13, UIDs em sequência: aceita |
| SSDT carregadas | `AMD CPU` rev 1 e `AmdTable` rev 1 (de fábrica: nenhuma correção ativa) |
| Limine | 12.9.0, one-shot OK, `ENABLE_UKI=no`, entrada do kernel com `module_path` (initramfs) + `path` (vmlinuz) separados, com hash BLAKE2 |
| initramfs da entrada | cpio early só com microcode AMD; hooks `base systemd autodetect microcode kms modconf block keyboard sd-vconsole plymouth filesystems` + `sd-btrfs-overlayfs` (drop-in do snapper) |
| SSDT do script × Control Center | idênticas byte a byte (sha256) ao payload e-tho v1.1.0 do `bc250-control-center-git` |
| OC da CPU (`bc250-smu-oc`) | desabilitado e não rodou neste boot |
| Governor GPU / CU manager | habilitados (o script os para/mascara no teste) |

Testes offline: `bash -n`; `limine.py modulos/atualizar/remover` na cópia do `limine.conf` real; `madt.py gerar` com e sem SSDT; initramfs real gerada por `mkinitcpio` com o hook `acpi_override`; `acpi_na_initramfs`/`cpio_certo` com e sem o hook; simulação da varredura do kernel em `madt.cpio + initramfs` e `final.cpio + initramfs`.

## Roteiro de teste

Cada passo num terminal à parte (o script pergunta). Anote a saída de `status` em cada etapa.

**Passo 1: só a correção ACPI (12 threads)**
```
sudo ./bc250-nucleos-arch.sh acpi
sudo reboot
sudo ./bc250-nucleos-arch.sh status      # "SSDT neste boot: AMD CPU:2 ... PSTATES:1 STUBS:1 -> correcao ATIVA"
sudo dmesg | grep -iE 'ACPI.*(override|upgrade|Error|BIOS bug)|SSDT'
cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver      # comparar com antes (acpi-cpufreq / amd-pstate)
cat /sys/devices/system/cpu/cpu0/cpuidle/state*/name
```
Se travar ou der erro de ACPI: escolha um snapshot no Limine (sem a correção) e rode `sudo ./bc250-nucleos-arch.sh acpi-desfazer`.

**Passo 2: núcleo 7 num boot só (14 threads)**
```
sudo ./bc250-nucleos-arch.sh testar      # deve dizer "a correcao ACPI ja esta na initramfs; o cpio leva so a MADT"
# reinicia a quente sozinho
sudo ./bc250-nucleos-arch.sh status      # "Ultimo teste: OK: subiu com 14 threads", SSDT com PSTATES
nproc; sudo dmesg | grep -iE 'ACPI.*(Error|override|upgrade)'
stress-ng --cpu 14 --verify -t 10m       # opcional
```
Se travar: desligue e ligue a placa (boot frio = padrão de fábrica).

**Passo 3: deixar como padrão**
```
sudo ./bc250-nucleos-arch.sh instalar
```
Depois, recalibrar o OC da CPU com 7 núcleos antes de religar o `bc250-smu-oc`.

## Registro dos testes na placa

| Data | Passo | Resultado |
|---|---|---|
| 2026-10-05 | 1. `acpi` | **OK.** Após o reboot: `AMD CPU:2 AmdTable:1 PSTATES:1 STUBS:1` (correção ativa). dmesg: `Table Upgrade: override [SSDT- AMD- AMD CPU]`, `install [HACK PSTATES]`, `install [HACK STUBS]`, nenhum erro de ACPI. `acpi-cpufreq` com 8 P-states (800–3200 MHz: 3200/2550/2325/1960/1820/1600/1271/800), cpuidle POLL/C1/C2/C3. 12 threads. (A falha do `dev-zram0.swap` já existia antes: o zram foi desativado pelo Control Center.) |
| 2026-10-05 | 2. `testar` | **OK.** Máscara gravada `0x77`→`0xFF`; o one-shot do Limine caiu na entrada `bc250-nucleos` (**ID confirmado**). dmesg: `Table Upgrade: override [APIC-ALASKA- A M I]` + SSDT `AMD CPU`/`PSTATES`/`STUBS` (uma vez cada, cpio só com a MADT), `Total of 14 processors activated`, online 0-13. O serviço de teste limpou a entrada, o cpio e o one-shot e deixou o reboot em `cold`. `stress-ng --cpu 14 --cpu-method all --verify -t 5m`: 14/14 passed, 0 failed, Tctl ~61 °C, sem MCE. (Os avisos `amdgpu dal_irq_service_ack` no dmesg também aparecem nos boots de fábrica: não têm relação.) |
| 2026-10-05 | 3. `instalar` | Instalado ainda no boot de teste (novo: o `instalar` reaproveita a máscara `0x77`, as 12 threads de base e a MADT original guardadas pelo `testar` OK, sem precisar de desligar a placa). `bc250-nucleos-boot.service` habilitado, `/etc/bc250-nucleos.conf` = base 12 / alvo 14 / CPUs 6 7 fora. Correção ACPI na initramfs + cpio só com a MADT. **1º boot frio confirmado (21:43):** gravou `0xFF`, reset quente para `bc250-nucleos`, `OK: 14 threads`; reboot fixado em `acpi`/`cold`. Em repouso: `acpi-cpufreq` + `schedutil` a 800 MHz na maioria das CPUs; C3 em 47–100% do tempo (núcleo 7 = 99,6%); Tctl ~40 °C (antes ~47 °C) |

## Registro de uso (`registro/bc250-registro.py`)

Serviço `bc250-registro.service` (instalado em `/usr/local/lib/bc250-registro/`), sobe em todo boot e grava **a cada 60 s** uma linha em `~/Desktop/bc250-registro/AAAA-MM-DD.csv` (um arquivo por dia, dono = seu usuário, ~150 bytes por linha ≈ 200 KB/dia):

`data_hora, tctl_c, gpu_c, ppt_w, cpu_mv, n0..n7 (MHz de cada núcleo físico pela SMU; n3 = núcleo com defeito, sempre baixo), threads_online, carga_1min, scx_modo, mce_boot`

Lê a SMU pelo `bc250_smu` do Control Center com `flock` (não atropela o governor da GPU). Parar: `sudo systemctl disable --now bc250-registro`.
