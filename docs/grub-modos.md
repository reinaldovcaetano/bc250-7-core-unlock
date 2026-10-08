# bc250-grub.sh: escolher 6 ou 7 núcleos no menu do GRUB (Fedora / Nobara)

> **Em uma frase:** em vez de a placa destravar o núcleo extra sozinha em todo boot, agora **você escolhe no menu do GRUB** se quer 6 ou 7 núcleos, e se algo travar ela **volta sozinha para 6 núcleos**. Não tem mais loop.

## Sumário
- [Por que este script existe (o problema do loop)](#por-que-este-script-existe-o-problema-do-loop)
- [O que mudou em relação à etapa 5 do bc250-nucleos.sh](#o-que-mudou-em-relação-à-etapa-5-do-bc250-nucleossh)
- [O menu do GRUB](#o-menu-do-grub)
- [Instalação passo a passo](#instalação-passo-a-passo)
- [Primeiro teste, passo a passo](#primeiro-teste-passo-a-passo)
- [Comandos](#comandos)
- [O que acontece quando você escolhe "7 núcleos"](#o-que-acontece-quando-você-escolhe-7-núcleos)
- [Como funciona a proteção contra loop](#como-funciona-a-proteção-contra-loop)
- [Travas antes de destravar](#travas-antes-de-destravar)
- [Atualizações (kernel, BIOS, GRUB, Control Center)](#atualizações)
- [Correção ACPI de energia](#correção-acpi-de-energia)
- [OC](#oc)
- [Deu problema? Como voltar](#deu-problema-como-voltar)
- [Arquivos](#arquivos)
- [Onde foi testado](#onde-foi-testado)

---

## Por que este script existe (o problema do loop)

Na versão anterior (etapa 5 do `bc250-nucleos.sh`), um serviço destravava o núcleo extra **automaticamente em todo boot frio**:

```
liga a placa → serviço grava 0xFF → reset quente → 7 núcleos → (trava) → liga de novo → serviço grava 0xFF → ...
```

Se o boot com 7 núcleos travar **depois** que o serviço já marcou o boot como "OK" (por exemplo, por causa do OC ou de um jogo), a placa entra num loop: toda vez que liga, destrava e trava de novo.

O que piorou: o Nobara vem com o **menu do GRUB escondido** (`GRUB_TIMEOUT=0`). Sem o menu, não dava para escolher outra entrada nem acrescentar `bc250.nucleos.nao` na linha do kernel. Na placa original, a única saída foi **formatar a máquina**.

## O que mudou em relação à etapa 5 do bc250-nucleos.sh

| | Etapa 5 (antes) | `bc250-grub.sh` (agora) |
|---|---|---|
| Quando destrava | Em **todo** boot frio, sozinho | **Só** quando a entrada de 7 núcleos é escolhida no GRUB (ou com `padrao 7`) |
| Menu do GRUB | Escondido (padrão do Nobara) | **Visível por 5 s** em todo boot |
| Se o boot de 7 núcleos travar | Destrava de novo no próximo boot (loop) | O próximo boot **cai sozinho em 6 núcleos** |
| Modo de 6 núcleos | Só a entrada original (sem correção ACPI) | Entrada própria, **com** correção ACPI e uma tabela de CPUs que **impede** o núcleo extra de subir |
| Testar sem OC | Desligar o serviço de OC à mão | Entrada pronta **"7 núcleos sem OC"** |
| Secure Boot ligado ou tabela de CPUs que não carregou | Seguia em frente: o núcleo ruim podia rodar código no boot | **Cancela** o destrave antes de gravar a máscara |
| BIOS atualizada | Usava a tabela gerada para a BIOS antiga | **Cancela** o destrave até reinstalar |
| Atualização de kernel | Entrada recriada só no boot seguinte | Recriada na hora (hook do `kernel-install`); o padrão continua em 6 núcleos |
| Correção ACPI do Control Center instalada depois | As tabelas carregariam em dobro | Detecta e passa a usar só a tabela de CPUs |

O `bc250-grub.sh` **substitui** a etapa 5. As etapas 1 a 4 do `bc250-nucleos.sh` (testar cada núcleo oculto) continuam sendo o jeito de descobrir **qual** núcleo é bom. Este script é para quando você já sabe.

## O menu do GRUB

Depois de instalado, o menu aparece por 5 segundos em todo boot:

```
BC-250: 6 nucleos (normal)              <- padrão. Nunca destrava
BC-250: 7 nucleos (destrave)            <- 7 núcleos, com o OC
BC-250: 7 nucleos sem OC (seguranca)    <- 7 núcleos, com o OC desligado só nesse boot
Nobara Linux (7.2.9-...)                <- entrada original do sistema, intocada
```

| Entrada | Núcleos | OC | Correção ACPI | Para quê |
|---|---|---|---|---|
| **6 nucleos (normal)** | 6 | ligado | sim | Uso seguro. É o padrão |
| **7 nucleos (destrave)** | 7 | ligado | sim | Uso normal com o núcleo extra |
| **7 nucleos sem OC** | 7 | **desligado** | sim | Primeiro teste, ou quando o OC estiver instável |
| **Nobara Linux** | 6 | ligado | não | Último recurso: boot do sistema sem nada do projeto |

Use as setas do teclado para escolher e Enter para entrar. Se ninguém mexer, o GRUB vai para o padrão.

## Instalação passo a passo

Pré-requisitos: Fedora ou Nobara, GRUB com BLS (o padrão desses sistemas), boot EFI, Secure Boot **desligado**, `/boot` em ext4 ou xfs. O script confere tudo isso e **não muda nada** se algo faltar.

1. Baixe a pasta inteira. O script usa os arquivos `bc250-nucleos.sh` e `acpi/` que estão junto:
   ```
   git clone https://github.com/reinaldovcaetano/bc250-nucleos
   cd bc250-nucleos
   ```
2. (Opcional) Confira a placa. Só lê, não muda nada:
   ```
   sudo ./verificar-placa.sh
   ```
   Mostra a máscara da SMU, a tabela de CPUs da BIOS, as entradas do GRUB e o `grubenv`.
3. Instale:
   ```
   sudo ./bc250-grub.sh instalar
   ```
   Ele mostra o que vai criar e pergunta `Instalar agora? [s/N]`. Responda `s`.
   - Outro núcleo extra (por exemplo, o 6): `sudo NUCLEOS="6" ./bc250-grub.sh instalar`
   - Rodar de novo é seguro: recria tudo e mantém o padrão escolhido. Rode no modo de 6 núcleos.

Saída esperada (resumida):
```
  OK  mascara 0x77: ocultos = 3 7; liga = 7
  OK  BIOS P3.00: as SSDT do e-tho v1.1.0 (sha256 conferido) vao junto nos dois modos
  OK  menu do GRUB visivel por 5 s
  OK  entradas criadas a partir do kernel 7.2.9-200.nobara.fc44.x86_64
  OK  padrao gravado do GRUB: bc250-6nucleos
  OK  Instalado. Padrao: 6 nucleos.
```

## Primeiro teste, passo a passo

Faça **um passo por vez** e só avance se o anterior der certo.

1. **6 núcleos.** Reinicie e deixe o GRUB ir sozinho para "6 nucleos (normal)". Depois:
   ```
   sudo bc250-grub.sh status
   cat /sys/devices/system/cpu/cpu0/cpufreq/scaling_driver     # esperado: acpi-cpufreq
   nproc                                                       # esperado: 12
   ```
   Isso confirma que a tabela de CPUs e a correção de energia carregam, sem risco nenhum.
2. **7 núcleos sem OC.** Reinicie e escolha "7 nucleos sem OC (seguranca)". A placa sobe, **reinicia sozinha uma vez** (é o reset quente) e volta. Depois:
   ```
   nproc                                                       # esperado: 14
   sudo bc250-grub.sh status                                   # "OK: bc250-7nucleos-semoc com 14 threads"
   ```
   Deixe ligado **pelo menos 5 minutos**. É o tempo para o boot contar como confirmado. Um teste de estresse:
   ```
   sudo dnf install stress-ng
   stress-ng --cpu $(nproc) --cpu-method all --verify -t 15m
   ```
3. **7 núcleos com OC.** Reinicie e escolha "7 nucleos (destrave)". Repita o estresse.
4. **Deixar 7 como padrão** (opcional, só depois de tudo estável):
   ```
   sudo bc250-grub.sh padrao 7
   ```

Se travar em qualquer passo: **desligue e ligue a placa**. Ela volta sozinha para 6 núcleos.

## Comandos

Depois de instalado, o comando fica disponível de qualquer pasta como `sudo bc250-grub.sh`.

| Comando | O que faz |
|---|---|
| `sudo bc250-grub.sh status` | Mostra threads, máscara, entrada atual, padrão, estado do ciclo, `saved_entry`/`next_entry`, últimos boots e a última falha |
| `sudo bc250-grub.sh padrao 6` | O GRUB vai sozinho para 6 núcleos (o padrão inicial) |
| `sudo bc250-grub.sh padrao 7` | O GRUB vai sozinho para 7 núcleos, com a proteção contra loop |
| `sudo bc250-grub.sh desfazer` | Remove tudo e pergunta se o menu do GRUB volta a ficar escondido (o recomendado é deixar visível) |
| `sudo ./bc250-grub.sh instalar` | Instala ou reinstala (rode da pasta do projeto) |

Exemplo **ilustrativo** de `status` num boot de 7 núcleos (horários de exemplo):
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

## O que acontece quando você escolhe "7 núcleos"

O hardware só aceita o núcleo extra depois de um **reset quente** (reinício sem cortar a energia). Por isso todo boot de 7 núcleos vira **dois boots**, o segundo automático:

```
1º boot (entrada 7 núcleos, máscara de fábrica 0x77, 12 threads)
   ~20 s a mais: a tabela nova declara um núcleo que ainda não existe e o kernel espera por ele
   serviço: confere as travas → grava 0xFF na SMU → marca a mesma entrada para o próximo boot → reset QUENTE
2º boot (mesma entrada, máscara 0xFF, 14 threads)
   serviço: confere os núcleos → "OK" → deixa o próximo reboot como FRIO
   depois de 5 min de pé (ou num desligamento normal): "confirmado"
```

- **Quem escolhe os núcleos** é a tabela de CPUs (MADT) que vai no initrd da entrada. Nela, o núcleo 3 (com defeito) fica desligado: o kernel nunca o acorda.
- **Reiniciar ou desligar** depois disso é sempre frio: a máscara volta para 0x77 de fábrica.

## Como funciona a proteção contra loop

Três ideias simples, uma em cima da outra:

**1. O padrão gravado do GRUB é sempre "6 núcleos".**
O `saved_entry` do GRUB aponta sempre para `bc250-6nucleos`. O serviço reaplica isso em todo boot, e o hook do kernel em toda atualização (o Fedora tem `UPDATEDEFAULT=yes`, que troca o padrão para o kernel novo).

**2. "Padrão 7" é um bilhete de ida única.**
Com `padrao 7`, o script usa o `next_entry` do GRUB: vale para **um** boot só, e o **próprio GRUB apaga** antes de iniciar o Linux. O bilhete só é renovado quando o boot de 7 núcleos prova que ficou de pé:
- ficou **5 minutos** ligado (`ESTAVEL="300"` em `/etc/bc250-grub.conf`), **ou**
- foi **desligado normalmente** (travamento não desliga normalmente).

Se travar em qualquer momento antes disso, o bilhete já foi gasto e o próximo boot vai para o padrão gravado: **6 núcleos**.

**3. Falha detectada e registrada.**
O script guarda em `/var/lib/bc250-grub/tentativa` em que ponto do ciclo está (`armado`: próximo boot programado em 7; `destravando`: reset quente feito, esperando confirmar). Se um boot de 6 núcleos encontra esse arquivo, o boot de 7 não terminou. Então o script:
- registra a falha em `boot.log` e `ultima-falha`
- muda o padrão para **6**
- avisa no terminal (`wall`) e no `status`

Para tentar 7 de novo: escolha no menu, ou `sudo bc250-grub.sh padrao 7`.

| Cenário | O que acontece no próximo boot |
|---|---|
| Boot de 7 núcleos trava (padrão 6) | 6 núcleos; falha registrada |
| Boot de 7 núcleos trava (padrão 7) | 6 núcleos (o bilhete já foi gasto); padrão volta para 6 |
| Trava no 1º boot, antes do serviço rodar | 6 núcleos; padrão volta para 6 |
| Reset quente cai numa entrada sem a tabela nova (16 threads) | O serviço desliga na hora as threads dos núcleos ocultos não escolhidos, pelo ID APIC |
| Escolheu "6 núcleos" com o padrão em 7 | Conta como falha e o padrão vira 6 (conservador de propósito) |

> **Por que o `/boot` precisa ser ext4 ou xfs?** O GRUB só consegue apagar o bilhete (`next_entry`) se conseguir gravar o arquivo `grubenv`, e ele não grava em btrfs. Sem isso, o bilhete nunca seria apagado. O `instalar` confere.

**E se o menu do GRUB voltar a ficar escondido** (por exemplo, por uma atualização do Nobara)? A proteção continua funcionando, porque ela não depende de você ver o menu.

## Travas antes de destravar

Antes de gravar 0xFF na SMU, o serviço confere tudo isto. Se qualquer item falhar, **não destrava**, sobe com 6 núcleos e registra o motivo em `status`:

| Trava | Por quê |
|---|---|
| A **tabela de CPUs nova está em uso** neste boot, com os núcleos certos ligados (`confere_madt.py`) | Sem ela, o reset quente subiria com a tabela da BIOS e o kernel **acordaria o núcleo ruim** antes de qualquer serviço poder desligá-lo |
| **Lockdown** = `none` (Secure Boot desligado) | Com lockdown, o kernel ignora tabelas do initrd |
| **BIOS** igual à da instalação (versão e data) | Outra BIOS pode ter outra tabela de CPUs; a gerada pode não servir |
| **Máscara** igual à de fábrica (0x77) | Estado estranho: melhor desligar a placa da tomada |
| `bc250.nucleos.nao` na linha do kernel, ou `/etc/bc250-grub.desligado` existe | Desligado de propósito |

## Atualizações

| O que atualiza | O que acontece |
|---|---|
| **Kernel** | O hook recria as entradas para o kernel novo. Se ele vier **sem** `CONFIG_ACPI_TABLE_UPGRADE`, as entradas BC-250 são removidas e sobra a do Nobara (6 núcleos, sem correção ACPI) |
| **Secure Boot ligado** | Destrave cancelado (trava de lockdown e da tabela de CPUs) |
| **BIOS** | Destrave cancelado até `sudo ./bc250-grub.sh instalar` de novo |
| **Correção ACPI do Control Center** (tabelas na initramfs) | As entradas passam a usar o cpio só com a tabela de CPUs, para as tabelas não carregarem em dobro |
| **GRUB ou `/etc/default/grub`** | Se o menu voltar a ficar escondido, a proteção contra loop continua |
| **Este projeto** (`git pull`) | Rode `sudo ./bc250-grub.sh instalar` de novo para atualizar a cópia em `/usr/local/lib/bc250-grub/` |

Em todos os casos, o pior resultado é **subir com 6 núcleos**, com o motivo registrado em `sudo bc250-grub.sh status`.

## Correção ACPI de energia

A BIOS P3.00 não informa ao Linux os níveis de clock (P-states) nem os estados de repouso (C-states), então a CPU fica sempre no clock máximo. As 3 tabelas do [e-tho/bc250-acpi-fix](https://github.com/e-tho/bc250-acpi-fix) (pasta `acpi/`, conferidas por sha256) corrigem isso:

- **Clock controlado pelo Linux:** 8 níveis, de **800 a 3200 MHz** (`acpi-cpufreq`).
- **Repouso:** os núcleos dormem em C1–C3.
- **O OC (3850 MHz) é separado:** quem aplica é a SMU, pelo `bc250-smu-oc`. As tabelas não mudam o clock máximo.

Elas vão junto nas **duas** entradas BC-250 (6 e 7 núcleos), só se a BIOS for a P3.00 e a initramfs ainda não as tiver. A entrada original do Nobara fica sem elas.

**Não instale também a "correção ACPI" do BC250 Control Center**: são as mesmas tabelas. Se instalar mesmo assim, o script detecta e não carrega em dobro.

## OC

- O serviço roda **antes** do `bc250-smu-oc`, então o OC só é aplicado depois do destrave.
- Na entrada **"7 núcleos sem OC"**, os serviços `bc250-smu-oc`, `cyan-skillfish-governor-smu` e `bc250-cu-live-manager` (os que existirem) ficam mascarados **só naquele boot**. Nada muda na configuração.
- O OC calibrado com 6 núcleos pode ficar instável com 7. Teste primeiro sem OC e depois recalibre pelo Control Center, se precisar.

## Deu problema? Como voltar

| Situação | O que fazer |
|---|---|
| Travou no boot de 7 núcleos | Desligue e ligue a placa. Volta sozinha para 6 núcleos |
| Quero 6 núcleos agora | Escolha "BC-250: 6 nucleos (normal)" no menu |
| A entrada de 6 núcleos do script deu problema | Escolha "Nobara Linux (...)", a entrada original e intocada |
| Não quero que destrave de jeito nenhum | `sudo touch /etc/bc250-grub.desligado` (para religar: `sudo rm /etc/bc250-grub.desligado`) |
| Desligar só num boot | No GRUB: tecla `e` na entrada, acrescente `bc250.nucleos.nao` no fim da linha `linux`, depois Ctrl+X |
| Ver o que aconteceu | `sudo bc250-grub.sh status` e `sudo cat /var/lib/bc250-grub/boot.log` |
| Remover tudo | `sudo bc250-grub.sh desfazer` e depois reiniciar |

## Arquivos

| Onde | O quê |
|---|---|
| `/usr/local/lib/bc250-grub/` | Programa: `bc250-grub.sh`, `smu.py`, `madt.py`, `confere_madt.py`, `6.cpio`/`7.cpio` (tabela de CPUs + ACPI), `6m.cpio`/`7m.cpio` (só a tabela de CPUs), `acpi/` |
| `/usr/local/sbin/bc250-grub.sh` | Atalho para o comando |
| `/etc/bc250-grub.conf` | Configuração: máscara, núcleos, threads, APIC, BIOS, `ESTAVEL`, `PADRAO` |
| `/var/lib/bc250-grub/` | `boot.log` (cada boot), `historico.log` (ações manuais), `tentativa`, `ultima-falha`, `madt-original.aml`, backups do `/etc/default/grub` e do `grub.cfg` |
| `/boot/loader/entries/bc250-*.conf` | As 3 entradas do GRUB |
| `/boot/bc250-6nucleos.cpio`, `/boot/bc250-7nucleos.cpio` | Initrd extra de cada modo |
| `/etc/systemd/system/bc250-grub.service` | Serviço que roda em todo boot (e no desligamento, para confirmar) |
| `/etc/kernel/install.d/96-bc250-grub.install` | Hook que recria as entradas a cada atualização de kernel |

## Onde foi testado

| | |
|---|---|
| Placa | AMD BC-250, BIOS **P3.00** (12/09/2021), máscara de fábrica `0x77` (núcleos 3 e 7 ocultos; 7 bom, 3 com defeito) |
| Sistema | **Nobara** 44, kernel `7.2.9-200.nobara.fc44`, GRUB 2.12 com BLS, EFI, `/boot` em ext4 |
| Data | 2026-10-08 |

| O que | Situação |
|---|---|
| Verificação da placa (`verificar-placa.sh`): máscara, MADT, SSDT, entradas, `grubenv`, `grub.cfg` | Conferido na placa; igual ao CachyOS onde importa |
| `instalar` | Rodado na placa: entradas, cpio, serviço, hook e menu do GRUB conferidos no disco |
| Proteção contra loop (6 cenários: destrave normal, travamento com padrão 6 e 7, travamento antes do serviço, reset quente na entrada errada) | Simulada com comandos falsos; todos caíram em 6 núcleos |
| `confere_madt.py` | Testado contra a tabela da BIOS (recusa) e contra as geradas (aceita) |
| Boot real em **"6 nucleos (normal)"** | **OK.** 12 threads, máscara `0x77`, tabela de CPUs e as 3 SSDT carregadas pelo initrd (`Table Upgrade: override [APIC…]`, `[SSDT… AMD CPU]`, `install STUBS` e `PSTATES`), `acpi-cpufreq` ativo |
| Boot real em **"7 nucleos (destrave)"** (com OC 3850 / −30) | **OK.** Um único reset quente (cerca de 18 s), subiu com **14 threads** (APIC 0–5 e 8–15, máscara `0xFF`), o núcleo 3 com defeito continuou fora, e o boot ficou **confirmado** após 5 min. O padrão do GRUB continuou em 6 núcleos |
| Estresse em 7 núcleos com OC | `stress-ng --cpu 14 --verify` por **9 min 41 s**: **14/14 passed, 0 failed**, sem nenhum erro de hardware (MCE) no kernel |
| Boot real em "7 nucleos sem OC (seguranca)" | Ainda não testado (é só a opção de emergência) |
| Travamento real em 7 núcleos (a volta sozinha para 6) | Não aconteceu, então só foi testado por simulação |

### Medidas do estresse (Nobara, 7 núcleos, OC 3850 MHz / scale −30)

| | Medido |
|---|---|
| Clock com carga | **3822–3842 MHz em todos os 14 threads** durante o teste inteiro |
| Temperatura (Tctl) | estável em **~80 °C**, pico de **82,2 °C** (limite do OC: 90 °C) |
| Potência (PPT) | 60–69 W |
| Repouso logo após o boot | Tctl ~45 °C, PPT ~34 W; com o `schedutil`, os núcleos descem para 800–1700 MHz |
| Escalonador | O padrão do kernel (EEVDF), **sem** `scx_lavd`. Diferente do CachyOS, nenhum núcleo ficou preso em ~1700 MHz com carga, então o modo Gaming não fez falta |

> **Temperatura:** foi cerca de **12 °C acima** do que se mediu no CachyOS (~68 °C) com potência parecida (as diferenças: scale −30 contra −31, ambiente e ventilação do dia). Ainda há margem até os 90 °C, mas vale ficar de olho no cooler e no fluxo de ar, principalmente no calor e com jogo pesado.

A parte que mexe no hardware (SMU, reset quente, tabela de CPUs pelo initrd) é a mesma do `bc250-nucleos.sh`, validada antes no CachyOS com 14 threads e OC de 3850 MHz.
