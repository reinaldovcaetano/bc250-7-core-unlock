# bc250-nucleos: liberar só os núcleos bons ocultos da AMD BC-250

Scripts para ligar os núcleos de CPU que vêm **ocultos de fábrica** na AMD BC-250 (o "APU de PS5" das placas de mineração), **escolhendo quais**: liga só os núcleos bons e deixa parado o que tem defeito. Fica permanente, sobrevive a atualização de kernel e convive com a correção ACPI de energia (P-states/C-states) do e-tho.

Na placa em que foi feito: **12 → 14 threads** (núcleo 7 ligado, núcleo 3 com defeito parado), 3850 MHz de OC nos 7 núcleos, estável.

> ⚠ **Risco por sua conta.** Mexe na SMU (o microcontrolador de energia do chip) e na tabela de CPUs do boot. Um núcleo oculto pode estar oculto **porque tem defeito**: ligar um núcleo ruim pode travar a placa ou corromper dados. Teste cada núcleo antes de deixar permanente. Desligar e ligar a placa (boot frio) sempre volta ao padrão de fábrica.

---

## Sumário
- [Como funciona](#como-funciona)
- [A lógica do destrave](#a-lógica-do-destrave-passo-a-passo)
- [Por que ligar só um núcleo](#por-que-ligar-só-um-núcleo-e-não-todos)
- [Como fica permanente](#como-fica-permanente)
- [Correção ACPI de energia (e-tho)](#correção-acpi-de-energia-e-tho)
- [Sistemas suportados](#sistemas-suportados)
- [Replicar em outra placa](#replicar-em-outra-placa)
- [Onde foi testado](#onde-foi-testado)
- [Overclock, modo Gaming e correção ACPI: até onde foi testado](#overclock-modo-gaming-e-correção-acpi-até-onde-foi-testado)
- [Desfazer](#desfazer)
- [Estrutura da pasta](#estrutura-da-pasta)
- [Créditos](#créditos)

---

## Como funciona

A BC-250 tem 8 núcleos físicos (16 threads), mas a fábrica desliga alguns. Quais ficam ligados está numa **máscara** dentro da SMU (registrador SMN `0x5A870`): bit 1 = núcleo ligado, bit 0 = oculto.

| Máscara | Núcleos ligados | Ocultos | Threads |
|---|---|---|---|
| `0x77` (esta placa) | 0, 1, 2, 4, 5, 6 | **3 e 7** | 12 |
| `0xFF` | todos | nenhum | 16 |

São três peças:

1. **Gravar a máscara.** Uma mensagem da SMU (`0x98`) muda a máscara para `0xFF`. A SMU **só sabe** fazer isso: liga todos os ocultos de uma vez, não dá para escolher um. E a mudança só vale **depois de um reset quente** (reinício sem cortar a energia, via EFI); um boot frio volta para a máscara de fábrica.
2. **Reset quente.** Depois do reset quente a BIOS enxerga os 8 núcleos e monta a tabela de CPUs (MADT) com todos.
3. **MADT nova pelo initrd.** Para ligar **só os bons**, o boot carrega uma MADT própria num cpio "early" do initrd (`kernel/firmware/acpi/apic.aml`), que o kernel usa no lugar da da BIOS (`CONFIG_ACPI_TABLE_UPGRADE=y`). Nela, os APIC do núcleo ruim ficam com `flags=0`: o kernel nunca os acorda e eles nem aparecem como CPU possível (não dá para ligá-los nem por hotplug).

Requisitos do kernel: `CONFIG_ACPI_TABLE_UPGRADE=y` e **sem lockdown** (Secure Boot desligado). Os scripts conferem os dois.

Cada núcleo físico tem 2 threads com APIC `2n` e `2n+1`: núcleo 3 = APIC 6 e 7; núcleo 7 = APIC 14 e 15.

## A lógica do destrave, passo a passo

O destrave acontece em duas camadas diferentes, o **hardware** (SMU + BIOS) e o **sistema operacional** (Linux):

| Camada | Quem decide | O que acontece com o núcleo ruim |
|---|---|---|
| Hardware | máscara da SMU | `0xFF` liga **os 8 núcleos**: todos recebem energia e clock, inclusive o ruim |
| Firmware | BIOS, depois do reset quente | acorda os 8 núcleos durante o POST e lista os 8 na MADT |
| Sistema operacional | a **MADT nova** do initrd | o Linux só usa os núcleos que estão nela; o ruim fica fora |

1. **Máscara `0xFF`.** A SMU passa a considerar os 8 núcleos ativos. Não dá para gravar `0xF7` (só o 7): a mensagem `0x98` só sabe "liberar todos".
2. **Reset quente.** A máscara nova só vale depois de reiniciar sem cortar a energia. A BIOS sobe com os 8 núcleos e monta uma MADT com as 16 threads.
3. **MADT nova pelo initrd.** Antes de ler a MADT da BIOS, o kernel procura tabelas ACPI no cpio do initrd e usa a nossa no lugar. Nela, as duas threads do núcleo ruim estão com `flags=0` (nem habilitadas, nem "online capable").
4. **O Linux acorda só o que está na MADT.** Para cada CPU listada, o kernel manda o sinal de partida (INIT/SIPI). O núcleo ruim nunca recebe esse sinal.

**O que isso significa para o núcleo ruim:**
- **Ele recebe energia e clock.** Pela SMU ele aparece com ~1,3–1,7 GHz o tempo todo, com ou sem carga. Não fica desligado eletricamente.
- **Ele não executa nada.** Fica parado esperando o sinal de partida que nunca chega: nenhum processo, interrupção ou código do kernel roda nele. Para o Linux ele não existe (`/sys/devices/system/cpu/possible` = 0-13).
- **Por isso o defeito não aparece:** o núcleo 3 desta placa travava quando *executava* código; parado, não executa.
- **O que não foi medido:** o consumo dele sozinho. O sistema operacional não consegue colocá-lo nos estados de repouso (C-states) porque não roda nada nele. O consumo total da placa em repouso ficou em ~31,7 W, mas não há medição antes do destrave para comparar.
- A cada **boot frio** a máscara volta à de fábrica e o núcleo ruim volta a ficar desligado pela SMU, até o serviço gravar `0xFF` de novo.

## Por que ligar só um núcleo (e não todos)

Nesta placa os ocultos eram o 3 e o 7. No teste, **o 7 funcionou e o 3 travava**. Como a SMU só liga os dois juntos, quem escolhe é a MADT:

```
APIC 0-5    ligados     (núcleos 0, 1, 2)
APIC 6-7    DESLIGADOS  (núcleo 3, com defeito: ligado no hardware, mas o kernel não o usa)
APIC 8-15   ligados     (núcleos 4, 5, 6 e 7)
```

O núcleo 3 fica energizado e parado (a SMU mostra ~1,5–1,7 GHz nele, sem carga). Proteções contra ele subir por acidente:

| Situação | O que acontece |
|---|---|
| Boot com a entrada dos núcleos | MADT com APIC 6/7 desligados: o núcleo 3 não existe para o kernel |
| Reinício depois do boot com 14 threads | O serviço fixa o reboot como **frio**: a máscara volta para `0x77` |
| Reset quente que caísse na entrada normal (MADT da BIOS, 16 threads) | O serviço desliga na hora as threads com **APIC 6 e 7** (pelo ID APIC, não pelo número da CPU) |
| Tentativa que não chega no número esperado de threads | Para de tentar até você mandar (`rm /var/lib/bc250-nucleos/falhou`) |

## Como fica permanente

Um serviço (`bc250-nucleos-boot.service`) roda em todo boot. Cada boot frio vira **dois boots** (alguns segundos a mais):

```
boot frio ─► entrada NORMAL, máscara de fábrica (12 threads)
             serviço: grava 0xFF na SMU, marca a entrada "bc250-nucleos" só para o próximo boot
             (one-shot: grub2-reboot no Fedora, bootctl set-oneshot no Limine) e reinicia a QUENTE
          ─► entrada bc250-nucleos: MADT nova no initrd (14 threads)
             serviço: confere as threads, fixa o próximo reboot como frio, fim
```

- A entrada `bc250-nucleos` é **recriada a cada boot** a partir da entrada do kernel: sobrevive a atualização de kernel e ao gerador do bootloader. A entrada normal nunca é alterada.
- Se o bootloader lembrar a última entrada (`remember_last_entry` do Limine, `GRUB_SAVEDEFAULT` do GRUB), o serviço apaga essa lembrança; senão o boot frio cairia direto na entrada dos núcleos com a máscara de fábrica.
- Desligar por um boot: no menu do boot, tecla `e`, acrescentar `bc250.nucleos.nao` na linha do kernel. Desligar de vez: `sudo touch /etc/bc250-nucleos.desligado`.

## Correção ACPI de energia (e-tho)

A BIOS P3.00 da BC-250 não informa P-states/C-states ao Linux: a CPU fica sempre no clock máximo. As 3 tabelas do [e-tho/bc250-acpi-fix](https://github.com/e-tho/bc250-acpi-fix) (pasta `acpi/`, idênticas às do BC250 Control Center, conferidas por sha256) corrigem isso: com elas, o `acpi-cpufreq` desce para 800 MHz em repouso e os núcleos dormem em C1–C3.

- **Fedora:** as SSDT vão junto no mesmo cpio da MADT (só na entrada dos núcleos).
- **Arch/CachyOS:** comando `acpi`: as SSDT entram na initramfs **normal** pelo hook `acpi_override` do mkinitcpio, então valem em **todo** boot, com ou sem núcleo extra. O cpio da entrada dos núcleos passa a levar só a MADT; o script decide sozinho, para as tabelas **nunca** carregarem em dobro.
- **Não instale também a "correção ACPI" do BC250 Control Center**: são as mesmas tabelas. (O instalador dele, aliás, só aceita GRUB/systemd-boot e acusa o Limine como "UKI", o que é falso.)

## Sistemas suportados

| Script | Sistemas | Bootloader exigido | Situação |
|---|---|---|---|
| `bc250-nucleos.sh` | **Fedora, Nobara** | GRUB com BLS (`/boot/loader/entries` + `grub2-reboot`) | menu com diagnóstico, **fila de testes de cada núcleo oculto**, instalação |
| `bc250-nucleos-arch.sh` | **Arch, CachyOS** (e derivados) | **Limine** com `limine-mkinitcpio-hook` | testar / instalar / correção ACPI; supõe que você já sabe quais núcleos são bons (veja abaixo) |

Não funciona (o script confere e **não muda nada**): Ubuntu, Debian, Mint, Pop!_OS (systemd-boot), Arch com GRUB ou systemd-boot, Bazzite, Silverblue, SteamOS e outros sistemas imutáveis. Portar exige: um jeito de criar uma entrada de boot com um initrd extra **antes** da initramfs e de marcá-la para um único boot.

Comum aos dois: boot EFI, `CONFIG_ACPI_TABLE_UPGRADE=y`, Secure Boot desligado, SMT ligado, `python3` e `cpio`.

## Replicar em outra placa

Cada placa pode ter **outra máscara** e **outros núcleos ruins**. Nunca copie a configuração desta: teste a sua.

### Placas com outros núcleos ocultos
Nada da placa original está fixo no código. Em cada placa os scripts:

| O quê | De onde vem |
|---|---|
| Núcleos ocultos | lidos da **máscara da SMU desta placa** (bits em 0) |
| Quais ligar | **você escolhe**: fila de testes no Fedora, `NUCLEOS="..."` no Arch (aceita mais de um: `NUCLEOS="2 6"`) |
| Núcleos desligados na MADT | os ocultos que **não** foram escolhidos (APIC `2n` e `2n+1`) |
| MADT nova | gerada a partir da **MADT da BIOS desta placa** (só troca as entradas de CPU) |
| Threads esperadas | calculadas: 2 × (núcleos de fábrica + escolhidos) |

Exemplos calculados pelo script:

| Máscara | Ocultos | Ligar | Threads | APIC desligados (núcleo ruim) |
|---|---|---|---|---|
| `0x77` (esta placa) | 3, 7 | 7 | 14 | 6, 7 (núcleo 3) |
| `0xBB` | 2, 6 | 6 | 14 | 4, 5 (núcleo 2) |
| `0xBB` | 2, 6 | 2 e 6 | 16 | nenhum |
| `0xEE` | 0, 4 | 0 | 14 | 8, 9 (núcleo 4) |
| `0x7F` | 7 | 7 | 16 | nenhum |

O que o script **recusa** (e não muda nada):
- Máscara já `0xFF` (desligue a placa da tomada e tente de novo) ou núcleo pedido que não está oculto.
- Threads atuais que não batem com a máscara (faça um boot frio).
- **MADT com layout desconhecido.** Aceita só os dois layouts conferidos: UID = APIC+1, ou UIDs em sequência só nos núcleos ativos (o da BIOS P3.00). Outras versões de BIOS podem usar outro layout e precisam ser analisadas antes.
- Correção ACPI (tabelas do e-tho) só com **BIOS P3.00**, para a qual elas foram feitas. Com outra BIOS, os núcleos funcionam, mas só com a tabela de CPUs.

O mesmo núcleo pode ser bom numa placa e ruim noutra: **teste cada núcleo oculto sozinho** antes de instalar.

### Antes de tudo (os dois sistemas)
1. **Desligue o OC da CPU** e reinicie normalmente. O OC calibrado com menos núcleos pode travar com mais, e o OC aplicado fica na SMU e sobrevive ao reset quente. Os scripts se recusam a rodar com o `bc250-smu-oc` habilitado ou aplicado no boot atual.
   ```
   sudo systemctl disable bc250-smu-oc
   sudo reboot
   ```
   Não aplique OC pelo app do Control Center antes dos testes (o script não detecta).
2. Copie a pasta inteira (com `acpi/`) para a placa.

### Fedora / Nobara
```
cd bc250-nucleos
sudo ./bc250-nucleos.sh
```
Menu em etapas, que só andam em ordem: **1** diagnóstico (descobre a máscara e os núcleos ocultos, instala dependências) → **2** desliga o OC → **3** testa cada núcleo oculto sozinho, um por boot, com estresse (`stress-ng --verify`) → **4** resultado → **5** instala só os bons → **6** religa o OC. Detalhes: [docs/fedora-nobara.md](docs/fedora-nobara.md).

### Arch / CachyOS (Limine)
O script do Arch não tem a fila de testes. Descubra os núcleos bons testando **um de cada vez**:
```
cd bc250-nucleos
sudo ./bc250-nucleos-arch.sh acpi                 # opcional: correção ACPI em todo boot (reinicie depois)
sudo NUCLEOS="7" ./bc250-nucleos-arch.sh testar   # liga só o núcleo 7 por UM boot (reinicia a quente sozinho)
sudo ./bc250-nucleos-arch.sh status               # depois do boot: "OK: subiu com N threads"
stress-ng --cpu $(nproc) --cpu-method all --verify -t 15m   # estresse no boot de teste
```
- Travou ou deu erro? Desligue e ligue a placa: esse núcleo é ruim.
- Repita com cada núcleo oculto (`NUCLEOS="3"`, …). O `testar` mostra a máscara e os núcleos ocultos (`ocultos = 3 7`) e pede confirmação antes de mudar qualquer coisa; recusa núcleo que não está oculto.
- Instale com os bons. Pode rodar no boot normal ou logo depois de um `testar` OK, ainda no boot de teste:
  ```
  sudo NUCLEOS="7" ./bc250-nucleos-arch.sh instalar
  ```

Detalhes, auditoria e o log completo da placa: [docs/arch-cachyos.md](docs/arch-cachyos.md).

### Depois de instalar
1. Reinicie normalmente: a placa reinicia sozinha uma vez e volta com mais threads (`nproc`).
2. Recalibre o OC da CPU com os núcleos novos (detecção do Control Center). Com a correção ACPI, rode a detecção com o governador `performance` (veja abaixo).
3. Estresse longo com o OC: `stress-ng --cpu $(nproc) --verify -t 15m`.

## Onde foi testado

| | |
|---|---|
| Placa | AMD BC-250, BIOS **P3.00** (12/09/2021), máscara de fábrica `0x77` (núcleos 3 e 7 ocultos) |
| Teste dos núcleos | **Nobara** (Fedora): núcleo 7 bom, **núcleo 3 com defeito** |
| Fluxo completo atual | **CachyOS** (deckify), kernel `7.2.9-1-cachyos-deckify`, **Limine 12.9.0**, EFI, Secure Boot sem suporte no firmware, lockdown `none` |
| Data | 2026-10-05 / 06 |

Resultado no CachyOS:

| Etapa | Resultado |
|---|---|
| Correção ACPI (`acpi`) | SSDT `AMD CPU` substituída, `PSTATES` e `STUBS` instaladas, sem erros; `acpi-cpufreq` com 8 P-states (800–3200 MHz); C3 em 47–100% do tempo em repouso |
| `testar` (núcleo 7) | 14 threads; `stress-ng` 5 min, 14/14 passed |
| `instalar` | Ciclo boot frio → reset quente → 14 threads confirmado em vários boots |
| OC 3850 MHz / scale −31 (7 núcleos) | Os 7 núcleos a 3850 MHz, 1175–1181 mV, Tctl ~68 °C, PPT ~62–66 W; `stress-ng --verify` 14/14 passed, 0 failed |
| Repouso | PPT ~31,7 W, Tctl ~40 °C |

**Fedora/Nobara:** o script `bc250-nucleos.sh` recebeu em 2026-10-05 as mesmas correções do Arch (lista em [docs/fedora-nobara.md](docs/fedora-nobara.md#correções-de-2026-10-05-vindas-da-versão-arch-ainda-não-testadas-no-fedora)). A sintaxe e a MADT gerada foram conferidas (idêntica à que roda na placa), mas **essa versão ainda não foi rodada num Fedora**.

## Overclock, modo Gaming e correção ACPI: até onde foi testado

Tudo medido na placa do [Onde foi testado](#onde-foi-testado), com 7 núcleos (14 threads). Clock por núcleo lido direto da SMU; temperatura (Tctl) e potência (PPT) pelo `sensors`.

### Overclock da CPU

| | |
|---|---|
| Ferramenta | detecção do BC250 Control Center (`bc250-detect` do `bc250_smu_oc`): sobe de 100 em 100 MHz, 10 s de estresse por degrau, e ajusta a curva de tensão (scale) para não passar do limite de VID |
| Alvo pedido | 3850 MHz, VID máx. 1185 mV, 90 °C (VID estimado no resultado: 1192 mV) |
| **Resultado** | **3850 MHz @ scale −31** (o mesmo valor que esta placa tinha com 6 núcleos) |
| Tensão medida com carga | 1162–1181 mV (o limite absoluto da BC-250 é 1325 mV) |
| Temperatura / potência com carga em 14 threads | Tctl estável em **~68 °C**, PPT 60–66 W |
| Estresse validado | `stress-ng --cpu 14 --cpu-method all --verify`: **14/14 passed, 0 failed**. Rodou ~6,5 min, dos quais **~4,5 min com os 7 núcleos a 3850 MHz** (nos primeiros ~2 min o escalonador ainda segurava parte deles; ver modo Gaming) |
| **Não testado ainda** | estresse completo de 15 min com os 7 núcleos a 3850 desde o início; frequências **acima de 3850** (3850 foi o alvo pedido, não o limite encontrado); jogos/uso longo (o [registro de uso](#registro-de-uso) está coletando) |

Como foi aplicado: o serviço `bc250-smu-oc` (do Control Center) aplica `/etc/bc250-smu-oc.conf` em todo boot, **depois** do `bc250-nucleos-boot.service` (que tem `Before=bc250-smu-oc.service`). O OC antigo, calibrado com 6 núcleos, foi removido antes de liberar o núcleo 7 (backup em `/etc/bc250-smu-oc.conf.6nucleos-bak`).

**Detecção de OC com a correção ACPI ligada:** a primeira tentativa abortou no 1º degrau (resultado 3550 / scale −2, igual com VID 1180 ou 1275). Com o Linux controlando a frequência, alguns núcleos ficavam em P-states baixos durante o estresse e o detector entendia como throttling. Solução: rodar a detecção com o governador `performance` e voltar depois:
```
echo performance | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
# detecção no Control Center
echo schedutil | sudo tee /sys/devices/system/cpu/cpufreq/policy*/scaling_governor
```
(o governador também volta para `schedutil` sozinho no próximo boot).

### Modo Gaming (escalonador `scx_lavd` do CachyOS)

O CachyOS usa o escalonador sched_ext `scx_lavd`, que também decide quanto clock pedir para cada CPU. Os modos do `scx_loader`:

| Modo | Argumento | Medido com OC 3850 e carga total (99% em todas as CPUs) |
|---|---|---|
| Auto (padrão do CachyOS) | `--autopilot` | **6 de 14 CPUs presas em ~1700 MHz** (compactação de núcleos / economia) |
| **Gaming** | `--performance` | **as 14 CPUs a ~3842 MHz** |
| PowerSave | `--powersave` | não medido |

Em repouso o Gaming gastou **o mesmo** que o Auto (PPT ~31,7 W, núcleos a 800 MHz, C3 ~97% do tempo): o que economiza em repouso é o núcleo dormir, e isso continua igual. Deixado como padrão:
```
# /etc/scx_loader.toml
default_sched = "scx_lavd"
default_mode = "Gaming"
```
e `sudo systemctl restart scx_loader` (ou reiniciar). Só vale para CachyOS/Arch com `scx_loader`; Fedora não usa sched_ext por padrão.

### Correção ACPI de energia

| | Sem a correção | Com a correção (e-tho) |
|---|---|---|
| Controle de frequência | nenhum (sem P-states: núcleos sempre no clock da SMU) | `acpi-cpufreq` + `schedutil`, 8 P-states: 3200 / 2550 / 2325 / 1960 / 1820 / 1600 / 1271 / 800 MHz |
| Repouso dos núcleos | sem C-states da BIOS | POLL, **C1, C2, C3**; em repouso C3 em 47–100% do tempo (núcleo 7: 99,6%) |
| Tctl em repouso | ~47 °C (uma medição, antes de instalar) | **~40 °C** |
| PPT em repouso | não medido | ~31,7 W |
| Erros no dmesg | | nenhum erro de ACPI |
| Carga total | | sobe ao máximo (com o modo Gaming) |

Carregamento conferido no `dmesg`: `Table Upgrade: override [SSDT- AMD- AMD CPU]`, `install [HACK PSTATES]`, `install [HACK STUBS]`, uma vez cada, também no boot com a MADT nova.

### Registro de uso
`registro/bc250-registro.py` grava a cada minuto, num CSV por dia: temperatura da CPU e da GPU, potência, tensão, clock de cada núcleo físico (pela SMU; o núcleo com defeito aparece sempre baixo), threads online, carga, modo do escalonador e erros de hardware (MCE). Instalação no comentário do `registro/bc250-registro.service`. Serve para conferir o OC no uso real (picos de temperatura, quedas de clock, núcleo extra que não subiu).

## Desfazer

| Sistema | Comando |
|---|---|
| Fedora / Nobara | `sudo ./bc250-nucleos.sh` → opção 9 |
| Arch / CachyOS | `sudo ./bc250-nucleos-arch.sh desfazer` (núcleos) e `sudo ./bc250-nucleos-arch.sh acpi-desfazer` (correção ACPI) |

Depois, reinicie **desligando a placa** (boot frio): volta tudo ao padrão de fábrica.

## Estrutura da pasta

```
bc250-nucleos/
├── README.md                  este arquivo
├── bc250-nucleos.sh           Fedora/Nobara (GRUB+BLS): diagnóstico, fila de testes, instalação
├── bc250-nucleos-arch.sh      Arch/CachyOS (Limine): testar, instalar, status, desfazer, acpi
│                              (extrai o smu.py e o madt.py do bc250-nucleos.sh: mantenha os dois juntos)
├── acpi/                      SSDT do e-tho v1.1.0 (MIT) + LEIA-ME com sha256
├── registro/                  registro de uso em CSV (script + modelo de serviço)
└── docs/
    ├── fedora-nobara.md       manual do script Fedora
    └── arch-cachyos.md        manual do script Arch, auditoria e registro dos testes na placa
```

Na placa, depois de instalar: programa em `/usr/local/lib/bc250-nucleos/`, estado e logs em `/var/lib/bc250-nucleos/` (`boot.log` limitado às 500 linhas mais recentes), configuração em `/etc/bc250-nucleos.conf`.

## Créditos

- Projeto de **Reinaldo Vitor Caetano**, testado na própria BC-250. Licença MIT (arquivo `LICENSE`).
- Feito com a ajuda do **Claude** (Anthropic), pelo Claude Code: a versão Arch/CachyOS com Limine, a correção ACPI na initramfs combinada com o núcleo extra, a auditoria das proteções contra o núcleo ruim (desligar pelo ID APIC, reboot frio, `remember_last_entry`/`GRUB_SAVEDEFAULT`, contagem de threads online), o diagnóstico do OC e do `scx_lavd`, o registro de uso e esta documentação.
- Tabelas ACPI: [e-tho/bc250-acpi-fix](https://github.com/e-tho/bc250-acpi-fix) v1.1.0, licença MIT (texto em `acpi/LEIA-ME.md`).
- Leitura da SMU no registro de uso: biblioteca `bc250_smu` do `bc250_smu_oc` (bc250-collective, MIT), distribuída pelo [BC250 Control Center](https://github.com/movacx/bc250-control-center).
- Mensagem `0x98` da SMU e o método de desbloqueio por MADT: trabalho da comunidade BC-250.
