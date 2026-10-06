# bc250-nucleos: libera e testa os núcleos ocultos da AMD BC-250

> ## ⚠ Só funciona em **Fedora** e **Nobara**
> O script precisa do GRUB com BLS (`/boot/loader/entries` + `grub2-reboot`), boot EFI e um sistema **não** imutável.
> **Não funciona** em Ubuntu, Debian, Mint, Arch com GRUB, Pop!_OS (systemd-boot), Bazzite, Silverblue ou SteamOS. Para Arch/CachyOS com Limine use o `bc250-nucleos-arch.sh` ([arch-cachyos.md](arch-cachyos.md)).
> Em outro sistema a etapa 1 confere tudo, para e **não muda nada**.

## Como usar
Copie a pasta inteira, com o `acpi/` junto, para a outra placa e rode:
```
cd bc250-nucleos
sudo ./bc250-nucleos.sh
```
Ele abre um menu com as etapas numeradas. As etapas **só andam na ordem**: as que ainda não podem ser feitas aparecem como `[travada]`.

| Etapa | O que faz | Reinicia? |
|---|---|---|
| 1. Diagnóstico | Confere a distro, o boot, o kernel e a placa. **Instala as dependências que faltarem** (python3, cpio, stress-ng, grub2-tools) com sua confirmação. Lê a máscara da SMU e descobre **quais núcleos estão ocultos** (em cada placa podem ser outros). | não |
| 2. Desligar o OC | Desabilita o OC da CPU (`bc250-smu-oc`, `bc250-cpu-escada`) e da GPU (governor, CU manager) e guarda quais estavam ligados. | sim, reboot normal |
| 3. Testar | Um teste por boot, numa fila fixa: cada núcleo oculto sozinho; depois todos juntos, se mais de um passar. O teste roda sozinho em segundo plano (estresse de N minutos). | sim, reset quente |
| 4. Resultado | Mostra quais núcleos são bons e grava o relatório. | não |
| 5. Instalar | Deixa os núcleos bons ligados por padrão. **Só faz isso se você confirmar.** | validação |
| 6. Religar o OC | Religa o que estava ligado. Recomendado: só a GPU, até recalibrar o OC da CPU. | não |
| 8 / 9 | Status e histórico / desfazer tudo. | |

## Travas de segurança
- **Nenhum núcleo é ativado com o OC ligado.** A etapa 3 confere se os serviços de OC estão desabilitados e parados, e se a placa já reiniciou depois da etapa 2, porque o OC aplicado continua na SMU até um reboot. No boot de teste, o OC também fica mascarado pela linha do kernel. Se mesmo assim estiver ligado, o teste é **anulado** e volta para pendente; o núcleo não é condenado.
- O estado fica gravado em `/var/lib/bc250-nucleos/estado.env`: máscara, núcleos ocultos, resultado de cada teste e serviços de OC desligados. Ele sobrevive a reboot e a travamento. Um núcleo já testado não é testado de novo, e não dá para pular o próximo teste da fila.
- **Se travar durante um teste:** desligue e ligue a placa. O boot frio volta ao padrão de fábrica, e ao abrir a etapa 3 o teste que ficou sem resultado é marcado como **FALHOU**. A fila então segue para o próximo.
- A entrada de teste do GRUB vale **um boot só**. A entrada normal nunca é alterada.

## Como funciona (resumo)
- A máscara da SMU (SMN `0x5A870`) indica os núcleos de fábrica: bit 1 é núcleo ligado, bit 0 é núcleo oculto. Exemplo: `0x77` = núcleos 3 e 7 ocultos.
- A SMU só sabe gravar `0xFF`, que liga **todos** os ocultos, e isso só vale depois de um reset **quente**.
- Para ligar só os bons, o boot carrega uma tabela de CPUs (MADT) pelo initrd que lista só os núcleos desejados. Os outros ficam parados. O kernel precisa ter `CONFIG_ACPI_TABLE_UPGRADE=y`.
- Na BIOS P3.00 vão juntas as tabelas de P-states e C-states do e-tho/bc250-acpi-fix (pasta `acpi/`). Com elas, o Linux controla o clock da CPU.
- Depois da etapa 5, todo boot frio vira **dois boots**: o primeiro grava `0xFF` e reinicia a quente sozinho; o segundo já sobe com os núcleos bons.

## Arquivos na placa
- Estado: `/var/lib/bc250-nucleos/`, com `estado.env`, `historico.log`, `teste-<núcleo>.log`, `relatorio.txt` e `boot.log`.
- Programa: `/usr/local/lib/bc250-nucleos/`. Serviços: `bc250-nucleos-teste.service` (só durante os testes) e `bc250-nucleos-boot.service` (depois da etapa 5).
- Desligar por um boot: tecla `e` no GRUB e acrescentar `bc250.nucleos.nao`. Desligar de vez: `sudo touch /etc/bc250-nucleos.desligado`.

## Simulação (não mexe na placa)
`BC250N_SIMULAR=1 BC250N_MASK=0xBB ./bc250-nucleos.sh` simula outra máscara. O estado fica em `/tmp/bc250-nucleos-sim`.


## Correções de 2026-10-05 (vindas da versão Arch, **ainda não testadas no Fedora**)
Achadas e confirmadas na placa com CachyOS; aplicadas aqui porque o código do serviço de boot é o mesmo:
- **Contagem de threads:** `nproc --all` contava as CPUs declaradas na MADT nova (14) mesmo quando o hardware só tinha 12. Agora conta as CPUs online (`/proc/cpuinfo`).
- **Núcleo ruim desligado pelo ID APIC:** antes desligava `cpu6`/`cpu7` pelo número lógico; o kernel numera as CPUs na ordem da MADT, e `cpu6` pode ser outro núcleo. Agora desliga pelos APIC certos.
- **Reboot frio no boot OK:** o serviço fixa o reboot como frio também no boot com os núcleos extras, para um reinício normal nunca cair na entrada padrão com a máscara `0xFF`.
- **`GRUB_SAVEDEFAULT`:** se o GRUB lembrar a entrada `bc250-nucleos-padrao`, o serviço apaga o `saved_entry` (o boot frio volta para a entrada padrão). É o mesmo problema que o Limine teve com `remember_last_entry`.
- **MADT da BIOS P3.00:** a checagem aceita os UIDs em sequência que essa BIOS usa (antes recusava a placa).
