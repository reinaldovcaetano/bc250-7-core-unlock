#!/bin/bash
# =====================================================================================
#  bc250-nucleos-arch.sh - versao do bc250-nucleos.sh para Arch/CachyOS com o bootloader LIMINE
#
#  Para placa cujo nucleo extra JA FOI TESTADO (aqui: nucleo 7; o 3 tem defeito e fica parado).
#  Nao tem fila de testes: so instala, mostra o status e desfaz.
#
#    sudo ./bc250-nucleos-arch.sh testar       liga os nucleos em UM boot so (o proximo boot frio volta ao normal)
#    sudo ./bc250-nucleos-arch.sh instalar     confere tudo e instala como padrao (pede confirmacao)
#    sudo ./bc250-nucleos-arch.sh status
#    sudo ./bc250-nucleos-arch.sh desfazer
#    sudo ./bc250-nucleos-arch.sh acpi          correcao ACPI do e-tho (P-states/C-states) em TODO boot, com ou sem nucleo extra
#    sudo ./bc250-nucleos-arch.sh acpi-desfazer
#    NUCLEOS="7" muda quais nucleos ocultos sao ligados (padrao: 7)
#
#  Correcao ACPI: as 3 SSDT do e-tho (as mesmas da "correcao ACPI" do BC250 Control Center) entram na
#  initramfs normal pelo hook acpi_override do mkinitcpio. Com ela instalada, o cpio da entrada
#  bc250-nucleos leva so a MADT; sem ela, leva MADT + SSDT. Nunca carrega as tabelas em dobro.
#
#  Como funciona (igual ao original, trocando GRUB por Limine):
#    boot frio (entrada normal, 12 threads): o servico grava 0xFF na mascara da SMU, marca a entrada
#    "bc250-nucleos" do Limine para o PROXIMO boot (bootctl set-oneshot) e reinicia a QUENTE.
#    boot 2 (entrada bc250-nucleos): o initrd extra traz uma MADT que lista so os nucleos bons -> 14 threads.
#  A entrada do Limine e recriada a cada boot a partir da entrada do kernel (sobrevive a atualizacao
#  do kernel e ao limine-entry-tool). A entrada normal nunca e alterada.
# =====================================================================================
set -u
AQUI=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
[ "$(id -u)" -eq 0 ] || exec sudo NUCLEOS="${NUCLEOS:-7}" "$0" "$@"
NUCLEOS=${NUCLEOS:-7}
LIB=/usr/local/lib/bc250-nucleos
EST=/var/lib/bc250-nucleos
CONF=/etc/bc250-nucleos.conf
ESP=/boot
LCONF=$ESP/limine.conf
CPIO=bc250-nucleos.cpio                 # fica em $ESP, referenciado como boot():/$CPIO
ENT_ID=bc250-nucleos                    # id da entrada no Limine (bootctl)
UNIT=bc250-nucleos-boot.service
UNIT_T=bc250-nucleos-teste.service
SERV_OC="bc250-smu-oc bc250-cpu-escada cyan-skillfish-governor-smu oberon-governor bc250-cu-live-manager"
SERV_GPU_GOV="cyan-skillfish-governor-smu oberon-governor"
SERV_OC_CPU="bc250-smu-oc bc250-cpu-escada"
ACPI_DIR=/etc/initcpio/acpi_override                 # lido pelo hook acpi_override do mkinitcpio
ACPI_DROPIN=/etc/mkinitcpio.conf.d/20-bc250-acpi.conf
# e-tho/bc250-acpi-fix v1.1.0 (identicas ao payload do BC250 Control Center)
ACPI_SHA="dcc596e8b566a74268f75d8c66bd90a23bc8ac02768283b265edfec13f9d7fca SSDT-CPU.aml
cb3c96c622d2d653777020283c434f92c26bf2c83502a27d9a398f98424a771f SSDT-PST.aml
c219ce775476725d49739024e149556228436a1c3faf0768a7c3eff9d85f66c2 SSDT-STUBS.aml"
mkdir -p "$EST"

B=$'\e[1m'; VM=$'\e[31m'; VD=$'\e[32m'; AM=$'\e[33m'; N0=$'\e[0m'
[ -t 1 ] || { B=; VM=; VD=; AM=; N0=; }
ok()   { echo "  ${VD}OK${N0}  $*"; }
ruim() { echo "  ${VM}ERRO${N0} $*"; }
aviso() { echo "  ${AM}!!${N0}  $*"; }
pergunta() { local r; read -rp "$1 [s/N] " r; [[ "$r" =~ ^[sS]$ ]]; }
log()  { echo "$(date '+%F %T') $*" >> "$EST/historico.log"; }   # so acoes manuais (testar/instalar/acpi...): cresce pouco
# threads ONLINE (nao "nproc --all": a MADT nova declara 14 mesmo quando o hardware so tem 12)
threads() { grep -c '^processor' /proc/cpuinfo; }
# o Limine (remember_last_entry: yes) lembra a entrada do ultimo boot; se for a bc250-nucleos, o proximo
# boot frio cairia direto nela com a mascara de fabrica (12 threads + ~20 s esperando o nucleo ausente).
# Apaga a lembranca: o boot frio volta para a default_entry. O one-shot nao usa esta variavel.
LIMINE_LAST=/sys/firmware/efi/efivars/LimineLastBootedEntry-513ee0d0-6e43-cb05-b272-f146a2fcb88a
esquece_entrada() {
    [ -f "$LIMINE_LAST" ] && tail -c +5 "$LIMINE_LAST" | tr -d '\0' | grep -qx "$ENT_ID" || return 0
    chattr -i "$LIMINE_LAST" 2>/dev/null; rm -f "$LIMINE_LAST"
}
mascara() { python3 "$LIB/smu.py" ler; }
reboot_frio()   { echo acpi > /sys/kernel/reboot/type; echo cold > /sys/kernel/reboot/mode; }
reboot_quente() { echo efi  > /sys/kernel/reboot/type; echo warm > /sys/kernel/reboot/mode; }
# desliga as threads pelo ID APIC (OFF16 guarda IDs APIC, nao numeros de CPU: o kernel numera as CPUs
# na ordem da MADT, entao "cpu6" pode ser outro nucleo). Retorna 1 se algum APIC pedido continuar online.
desliga_apics() {
    local a c r=0
    for a in "$@"; do
        for c in $(awk -v a="$a" '/^processor/{p=$3} /^apicid/{if ($3 == a) print p}' /proc/cpuinfo); do
            echo 0 > "/sys/devices/system/cpu/cpu$c/online" 2>/dev/null
        done
    done
    for a in "$@"; do awk -v a="$a" '/^apicid/{if ($3 == a) f=1} END{exit !f}' /proc/cpuinfo && r=1; done
    return $r
}
apics_de() { python3 -c "import sys;m=int(sys.argv[1],16);x=[int(c) for c in sys.argv[2].split()];print(' '.join(str(a) for c in range(8) if (m>>c&1 or c in x) for a in (2*c,2*c+1)))" "$1" "${2:-}"; }
kconfig_ok() { zcat /proc/config.gz 2>/dev/null | grep -q '^CONFIG_ACPI_TABLE_UPGRADE=y'; }
# SSDT carregadas neste boot: "OEM-table-id:revisao" (ex.: "AMD CPU:1")
ssdt_vivas() { local t; for t in /sys/firmware/acpi/tables/SSDT*; do
    echo "$(dd if="$t" bs=1 skip=16 count=8 status=none | tr -d '\0'):$(od -An -tu4 -j24 -N4 "$t" | tr -d ' ')"; done; }
# a initramfs da entrada do kernel ja traz as SSDT do e-tho no cpio early? (cpio -t le so o 1o arquivo, o early)
acpi_na_initramfs() {
    local p
    for p in $(python3 "$LIB/limine.py" modulos "$LCONF" 2>/dev/null); do
        cpio -it --quiet < "$ESP/$p" 2>/dev/null | grep -qx 'kernel/firmware/acpi/SSDT-PST.aml' && return 0
    done
    return 1
}
# cpio da entrada bc250-nucleos: so a MADT quando a initramfs ja traz as SSDT, senao MADT + SSDT
cpio_certo() { if [ -f "$LIB/madt.cpio" ] && acpi_na_initramfs; then echo "$LIB/madt.cpio"; else echo "$LIB/final.cpio"; fi; }
gera_cpios() {
    python3 "$LIB/madt.py" gerar "$EST/madt-original.aml" "$ap" "$LIB/final.cpio" $ssdt &&
    python3 "$LIB/madt.py" gerar "$EST/madt-original.aml" "$ap" "$LIB/madt.cpio"
}

# ---------- auxiliares Python ----------
grava_aux() {
mkdir -p "$LIB"
# smu.py e madt.py: identicos aos do bc250-nucleos.sh original
sed -n "/^cat > \"\$LIB\/smu.py\" <<'PY'$/,/^PY$/p" "$AQUI/bc250-nucleos.sh" | sed '1d;$d' > "$LIB/smu.py"
sed -n "/^cat > \"\$LIB\/madt.py\" <<'PY'$/,/^PY$/p" "$AQUI/bc250-nucleos.sh" | sed '1d;$d' > "$LIB/madt.py"
grep -q 'MASK = 0x5A870' "$LIB/smu.py" && grep -q 'def ler' "$LIB/madt.py" || { ruim "nao consegui extrair smu.py/madt.py do bc250-nucleos.sh"; return 1; }
# a BIOS desta placa numera os UID em sequencia so nos nucleos ativos (APIC 8 = UID 7). Aceita esse
# layout tambem: a MADT gerada usa UID = APIC+1, que bate com as P000..P00F das SSDT (P00x = APIC x).
python3 - "$LIB/madt.py" <<'PY' || { ruim "nao consegui ajustar o madt.py"; return 1; }
import sys
p = sys.argv[1]; s = open(p).read()
velho = '    if ruins: sys.exit("UID != APIC+1 em %r - layout desconhecido" % ruins)\n'
novo = ('    seq = [e[2] for e in sorted(ativos, key=lambda e: e[3])] == list(range(1, len(ativos) + 1))\n'
        '    if ruins and not seq: sys.exit("UID != APIC+1 em %r - layout desconhecido" % ruins)\n'
        '    if ruins: print("UIDs em sequencia (layout da BIOS); a MADT nova usa UID = APIC+1, como as SSDT P00x")\n')
if "seq = " in s: sys.exit(0)        # o bc250-nucleos.sh ja traz a checagem nova
if velho not in s: sys.exit(1)
open(p, "w").write(s.replace(velho, novo))
PY
cat > "$LIB/limine.py" <<'PY'
# Recria a entrada "/bc250-nucleos" no fim do limine.conf, copiando a entrada do kernel
# (primeira entrada linux fora dos Snapshots) e acrescentando o cpio da MADT como 1o module_path.
#   limine.py atualizar <limine.conf> <cpio> [opcoes extras do kernel]   -> imprime a versao do kernel da entrada base
#   limine.py remover   <limine.conf>
#   limine.py modulos   <limine.conf>   -> caminhos (relativos ao ESP) dos module_path da entrada do kernel
import os, re, sys
acao, conf = sys.argv[1], sys.argv[2]
INI, FIM = "# >>> bc250-nucleos (gerado pelo bc250-nucleos-arch.sh; nao editar)", "# <<< bc250-nucleos"
txt = open(conf).read()
linhas, fora, pula = txt.split("\n"), [], False
for l in linhas:
    if l.startswith("# >>> bc250-nucleos"): pula = True; continue
    if l.startswith(FIM): pula = False; continue
    if not pula: fora.append(l)
while fora and fora[-1] == "": fora.pop()
novo = "\n".join(fora) + "\n"
def entrada_base():
    i = 0
    while i < len(fora):
        if re.match(r"^\s*//[^/]", fora[i]):
            j = i + 1; bloco = []
            while j < len(fora) and not re.match(r"^\s*/", fora[j]): bloco.append(fora[j].strip()); j += 1
            if "protocol: linux" in bloco and not any(".snapshots" in b for b in bloco):
                return bloco
            i = j
        else: i += 1
    sys.exit("entrada do kernel nao encontrada no limine.conf")
if acao == "modulos":
    for b in entrada_base():
        if b.startswith("module_path:"): print(b.split(":", 1)[1].strip().split("#")[0].replace("boot():/", "", 1))
    sys.exit(0)
if acao == "atualizar":
    cpio = sys.argv[3]
    base = entrada_base()
    mods = [b for b in base if b.startswith("module_path:")]
    path = [b for b in base if b.startswith("path:")]
    cmd = [b for b in base if b.startswith("cmdline:")]
    kv = [b.split(":", 2)[2].strip() for b in base if b.startswith("comment: Kernel version:")]
    if not (mods and path and cmd): sys.exit("entrada do kernel incompleta (module_path/path/cmdline)")
    novo += "\n".join(["", INI, "/" + "bc250-nucleos", "  comment: BC-250 com nucleos extras (so funciona depois do reset quente)",
                       "  protocol: linux", "  module_path: boot():/" + cpio] + ["  " + m for m in mods] +
                      ["  " + path[0], "  " + cmd[0] + (" " + sys.argv[4] if len(sys.argv) > 4 and sys.argv[4] else ""), FIM, ""])
    print(kv[0] if kv else "?")
if novo != txt:
    tmp = conf + ".bc250tmp"
    with open(tmp, "w") as f: f.write(novo); f.flush(); os.fsync(f.fileno())
    os.replace(tmp, conf)
PY
}

# ---------- instalar ----------
# trava: o OC da CPU (calibrado para 6 nucleos) nao pode estar habilitado nem aplicado neste boot,
# porque o OC gravado na SMU sobrevive ao reset quente e iria junto para o boot com mais nucleos
oc_livre() {
    local s r=0
    for s in $SERV_OC_CPU; do
        systemctl cat "$s.service" >/dev/null 2>&1 || continue
        if systemctl is-enabled -q "$s" 2>/dev/null; then
            ruim "$s (OC da CPU) esta habilitado: calibrado para 6 nucleos, pode travar com mais."
            echo "        Desligue:  sudo systemctl disable $s   e reinicie NORMALMENTE antes de rodar de novo."
            r=1
        elif [ "$(systemctl show -P ExecMainStartTimestampMonotonic "$s" 2>/dev/null)" != 0 ]; then
            ruim "$s rodou NESTE boot: o OC continua na SMU. Reinicie normalmente antes."; r=1
        else ok "$s desligado e nao aplicado neste boot"; fi
    done
    return $r
}

# confere tudo; deixa m/base/ap/alvo/off16/ssdt nas variaveis locais de quem chamou
prepara() {
    local falha=0 nb c ocultos
    echo "${B}BC-250: liberar nucleo(s) $NUCLEOS (Arch/CachyOS + Limine)${N0}"
    . /etc/os-release
    [[ "$ID" == arch || " ${ID_LIKE:-} " == *" arch "* ]] && ok "distro: $NAME" || { ruim "distro $NAME: esta versao e para Arch/CachyOS"; falha=1; }
    bootctl status 2>/dev/null | grep -q 'Product: Limine' && [ -f "$LCONF" ] && ok "boot: Limine ($LCONF)" || { ruim "bootloader nao e Limine com $LCONF"; falha=1; }
    bootctl status 2>/dev/null | grep -q '✓ One-shot entry control' && ok "Limine aceita entrada de uma vez (one-shot)" || { ruim "Limine sem one-shot entry control"; falha=1; }
    [ -d /sys/firmware/efi ] || { ruim "nao bootou em EFI"; falha=1; }
    kconfig_ok && ok "kernel $(uname -r) com CONFIG_ACPI_TABLE_UPGRADE" || { ruim "kernel sem CONFIG_ACPI_TABLE_UPGRADE"; falha=1; }
    grep -q 'AMD BC-250' /proc/cpuinfo && ok "placa: BC-250 | BIOS $(cat /sys/class/dmi/id/bios_version)" || { ruim "isto nao e uma BC-250"; falha=1; }
    for p in python3 cpio bootctl; do command -v $p >/dev/null || { ruim "falta $p (pacman -S python cpio)"; falha=1; }; done
    [ -e "/etc/systemd/system/$UNIT" ] && { ruim "ja instalado - use 'desfazer' antes"; falha=1; }
    [ -e /etc/systemd/system/bc250-7cores.service ] && { ruim "existe outro desbloqueio (bc250-7cores) - remova antes"; falha=1; }
    oc_livre || falha=1
    [ "$falha" = 0 ] || { ruim "${B}Nada foi alterado.${N0}"; return 1; }
    grava_aux || return 1
    m=$(mascara) || { ruim "nao consegui ler a mascara da SMU"; return 1; }
    # 'instalar' logo depois de um 'testar' OK, ainda no boot de teste: usa a mascara de fabrica,
    # as threads de base e a MADT original que o 'testar' guardou no boot normal
    local do_teste=0
    if [ "$m" = 0xFF ] && [ "${DO_TESTE_OK:-0}" = 1 ] && grep -qw bc250.nucleos=teste /proc/cmdline &&
       grep -q ' teste: OK: ' "$EST/teste-resultado.txt" 2>/dev/null && [ -f "$EST/teste.conf" ] && [ -f "$EST/madt-original.aml" ]; then
        local MASCARA= BASE= ALVO= OFF16=; . "$EST/teste.conf"
        if [ -n "$MASCARA" ] && [ "$MASCARA" != 0xFF ] && [ "$(threads)" = "$ALVO" ]; then
            m=$MASCARA; do_teste=1
            ok "boot de teste OK ($(threads) threads): usa a mascara de fabrica $m e a MADT guardadas pelo 'testar'"
        fi
    fi
    [ "$m" = 0xFF ] && { ruim "mascara ja esta 0xFF: desligue a placa totalmente e rode de novo"; return 1; }
    nb=$(python3 -c "print(bin(int('$m',16)).count('1'))"); base=$(threads)
    [ "$do_teste" = 1 ] && base=$BASE
    [ "$base" = $((nb * 2)) ] || { ruim "mascara $m indica $((nb*2)) threads mas ha $base: faca um boot frio"; return 1; }
    ocultos=$(python3 -c "m=int('$m',16);print(' '.join(str(c) for c in range(8) if not m>>c&1))")
    for c in $NUCLEOS; do [[ " $ocultos " == *" $c "* ]] || { ruim "nucleo $c nao esta oculto (ocultos: $ocultos)"; return 1; }; done
    ok "mascara $m: ocultos = $ocultos; vai ligar: $NUCLEOS"
    [ "$do_teste" = 1 ] || cp /sys/firmware/acpi/tables/APIC "$EST/madt-original.aml"
    local vm; vm=$(python3 "$LIB/madt.py" verificar "$EST/madt-original.aml" "$m" 2>&1) || { ruim "$vm"; ruim "layout da MADT desconhecido. Nada foi alterado."; return 1; }
    ok "$vm"
    ssdt=""
    if [ "$(cat /sys/class/dmi/id/bios_version)" = P3.00 ] && grep -l 'AMD CPU' /sys/firmware/acpi/tables/SSDT* >/dev/null 2>&1; then
        mkdir -p "$LIB/acpi"; cp "$AQUI"/acpi/*.aml "$LIB/acpi/"; ssdt=$LIB/acpi
        if acpi_na_initramfs; then ok "BIOS P3.00: a correcao ACPI ja esta na initramfs; o cpio leva so a MADT"
        else ok "BIOS P3.00: tabelas de P-states/C-states (e-tho) vao junto no cpio"; fi
    else aviso "BIOS diferente da P3.00: so a tabela de nucleos"; fi
    ap=$(apics_de "$m" "$NUCLEOS"); alvo=$(echo $ap | wc -w)
    off16=""; for c in $ocultos; do [[ " $NUCLEOS " == *" $c "* ]] || off16="$off16 $((2*c)) $((2*c+1))"; done
    off16=${off16# }
}

# ---------- testar: um boot so ----------
testar() {
    local m base ap alvo off16 ssdt
    prepara || return 1
    [ -e "/etc/systemd/system/$UNIT_T" ] && { ruim "ja ha um teste agendado (rode 'desfazer' se ficou preso)"; return 1; }
    echo
    echo "  ${B}Teste de um boot:${N0}"
    echo "    - grava 0xFF na mascara pela SMU (liga os nucleos ocultos no hardware)"
    echo "    - cria a entrada '$ENT_ID' no fim do limine.conf (backup em $LCONF.bc250-bak), marcada so para o proximo boot"
    echo "    - reinicia a QUENTE e sobe com $alvo threads (APIC $ap)${off16:+; o nucleo ruim (APIC $off16) fica parado}"
    echo "    - nesse boot um servico tira a entrada do limine.conf e volta o reboot para frio:"
    echo "      o proximo boot normal volta ao padrao de fabrica ($base threads)"
    echo "  Se travar: desligue e ligue a placa (boot frio = padrao de fabrica)."
    pergunta "Gravar a mascara e REINICIAR agora para testar?" || return 0
    gera_cpios || { ruim "falha ao gerar a tabela"; return 1; }
    install -m 0755 "$(readlink -f "$0")" "$LIB/bc250-nucleos-arch.sh"
    printf 'MASCARA=%s\nBASE=%s\nALVO=%s\nOFF16="%s"\n' "$m" "$base" "$alvo" "$off16" > "$EST/teste.conf"
    [ -e "$LCONF.bc250-bak" ] || cp -p "$LCONF" "$LCONF.bc250-bak"
    install -m 0644 "$(cpio_certo)" "$ESP/$CPIO"
    # no boot de teste o OC (CPU e GPU) fica mascarado, como no script original
    local s masc=""; for s in $SERV_OC; do systemctl cat "$s.service" >/dev/null 2>&1 && masc="$masc systemd.mask=$s.service"; done
    local kv; kv=$(python3 "$LIB/limine.py" atualizar "$LCONF" "$CPIO" "bc250.nucleos=teste$masc" 2>&1) || { ruim "limine.conf: $kv"; _limpa_teste; return 1; }
    [ "$kv" = "$(uname -r)" ] || { ruim "a entrada do Limine usa o kernel $kv, mas esta rodando $(uname -r): reinicie no kernel padrao antes"; _limpa_teste; return 1; }
    ok "entrada '$ENT_ID' criada (kernel $kv)"
    cat > "/etc/systemd/system/$UNIT_T" <<UNIDADE
[Unit]
Description=BC-250 teste de nucleos: confere e limpa depois do boot de teste
After=local-fs.target
RequiresMountsFor=/boot /var/lib

[Service]
Type=oneshot
ExecStart=$LIB/bc250-nucleos-arch.sh _teste

[Install]
WantedBy=multi-user.target
UNIDADE
    systemctl daemon-reload; systemctl enable "$UNIT_T"
    local out; for s in $SERV_GPU_GOV; do systemctl stop "$s" 2>/dev/null; done
    out=$(python3 "$LIB/smu.py" gravar "$m" 2>&1) || { ruim "SMU: $out"; _limpa_teste; for s in $SERV_GPU_GOV; do systemctl is-enabled -q "$s" 2>/dev/null && systemctl start "$s"; done; return 1; }
    ok "$out"
    bootctl set-oneshot "$ENT_ID" || { ruim "bootctl set-oneshot falhou"; _limpa_teste; reboot_frio; return 1; }
    log "arch: teste iniciado (APIC $ap)"
    reboot_quente; sync
    echo "  Reiniciando a quente... Depois do boot: sudo $0 status"
    systemctl reboot
}
_limpa_teste() {
    systemctl disable "$UNIT_T" 2>/dev/null; rm -f "/etc/systemd/system/$UNIT_T"; systemctl daemon-reload
    [ -f "$CONF" ] || { python3 "$LIB/limine.py" remover "$LCONF"; rm -f "$ESP/$CPIO"; }
    bootctl set-oneshot "" 2>/dev/null
}
# roda no 1o boot depois do 'testar' (em qualquer entrada), confere, limpa e se desliga
_teste() {
    MASCARA=; BASE=; ALVO=; OFF16=
    . "$EST/teste.conf" || { _limpa_teste; exit 0; }
    local n c r; n=$(threads)
    if [ "$n" = "$ALVO" ]; then r="OK: subiu com $n threads (online $(cat /sys/devices/system/cpu/online))"
    elif [ "$n" -gt "$BASE" ]; then
        desliga_apics $OFF16 && c="desligados" || c="FALHA AO DESLIGAR"
        r="subiu na entrada normal com $n threads: APIC $OFF16 (nucleo ruim) $c, online $(cat /sys/devices/system/cpu/online)"
    else r="FALHOU: subiu com $n threads (a mascara ou a entrada nao valeu)"; fi
    _limpa_teste; reboot_frio
    echo "$(date '+%F %T') teste: $r" | tee -a "$EST/historico.log" > "$EST/teste-resultado.txt"
    wall "BC-250 teste de nucleos: $r. O proximo reboot volta ao padrao de fabrica." 2>/dev/null
    exit 0
}

# ---------- instalar ----------
instalar() {
    local m base ap alvo off16 ssdt
    DO_TESTE_OK=1 prepara || return 1
    echo
    echo "  Vai instalar o servico $UNIT. Em todo boot frio:"
    echo "    boot 1 (entrada normal, $base threads): grava 0xFF na SMU e reinicia a quente na entrada '$ENT_ID'"
    echo "    boot 2 (entrada '$ENT_ID', $alvo threads, APIC $ap): segue normal"
    echo "  O limine.conf ganha uma entrada no fim (backup em $LCONF.bc250-bak). A entrada normal nao muda."
    echo "  Protecoes: se o boot 2 nao chegar a $alvo threads, para de tentar (rm $EST/falhou para tentar de novo);"
    echo "  desligar 1 boot: tecla e no Limine e acrescentar bc250.nucleos.nao; de vez: touch /etc/bc250-nucleos.desligado"
    [ -n "$off16" ] && echo "  Se a entrada normal subir com todos os nucleos, os APIC $off16 (nucleo ruim) sao desligados na hora."
    pergunta "Instalar agora?" || return 0
    gera_cpios || { ruim "falha ao gerar a tabela"; return 1; }
    install -m 0755 "$(readlink -f "$0")" "$LIB/bc250-nucleos-arch.sh"
    [ -e "$LCONF.bc250-bak" ] || cp -p "$LCONF" "$LCONF.bc250-bak"
    printf 'MASCARA=%s\nBASE=%s\nALVO=%s\nOFF16="%s"\n' "$m" "$base" "$alvo" "$off16" > "$CONF"
    cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=BC-250 nucleos extras por padrao (bc250-nucleos-arch.sh)
After=local-fs.target
Before=bc250-smu-oc.service bc250-cpu-escada.service cyan-skillfish-governor-smu.service oberon-governor.service bc250-cu-live-manager.service display-manager.service
RequiresMountsFor=/boot /var/lib

[Service]
Type=oneshot
ExecStart=$LIB/bc250-nucleos-arch.sh _boot
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
    systemctl daemon-reload; systemctl enable "$UNIT"
    rm -f "$EST/tentativa" "$EST/falhou"
    log "arch: instalado (nucleos $NUCLEOS, $alvo threads, APIC $ap)"
    ok "Instalado. Reinicie normalmente: a placa reinicia sozinha uma vez e volta com $alvo threads."
    pergunta "Reiniciar agora?" && { reboot_frio; systemctl reboot; }
}

# ---------- roda em todo boot ----------
_boot() {
    local BL=$EST/boot.log; MASCARA=; BASE=; ALVO=; OFF16=
    . "$CONF" || exit 0
    blog() { echo "$*"; echo "$(date '+%F %T') $*" >> "$BL"; }
    # boot.log ganha ~3 linhas por boot frio: guarda so as 500 mais recentes
    [ "$(wc -l < "$BL" 2>/dev/null || echo 0)" -gt 500 ] && { tail -n 300 "$BL" > "$BL.tmp" && mv "$BL.tmp" "$BL"; }
    local n; n=$(threads)
    esquece_entrada
    # boot com o nucleo extra: o proximo reboot tem de ser FRIO (volta a mascara de fabrica); um reset
    # quente com 0xFF numa entrada sem a MADT nova subiria o nucleo ruim
    if [ "$n" = "$ALVO" ]; then rm -f "$EST/tentativa"; reboot_frio; blog "OK: $n threads"; exit 0; fi
    if [ "$n" -gt "$BASE" ] && [ -n "$OFF16" ]; then
        local d; desliga_apics $OFF16 && d="desligados" || d="FALHA AO DESLIGAR"
        blog "$n threads na entrada normal (reset quente): APIC $OFF16 (nucleo ruim) $d, online=$(cat /sys/devices/system/cpu/online)"
    elif [ "$n" != "$BASE" ]; then blog "threads=$n inesperado - nada a fazer"; exit 0; fi
    parar() { blog "$1"; [ "$n" -gt "$BASE" ] && reboot_frio; exit 0; }
    grep -qw bc250.nucleos.nao /proc/cmdline && parar "desligado pela linha do kernel"
    [ -e /etc/bc250-nucleos.desligado ] && parar "desligado por /etc/bc250-nucleos.desligado"
    [ -e "$EST/falhou" ] && parar "tentativa anterior falhou - parado (rm $EST/falhou para tentar de novo)"
    [ -e "$EST/tentativa" ] && { mv "$EST/tentativa" "$EST/falhou"; parar "FALHOU: a ultima tentativa nao chegou a $ALVO threads. Parado."; }
    kconfig_ok || parar "kernel $(uname -r) sem CONFIG_ACPI_TABLE_UPGRADE - nao libero"
    install -m 0644 "$(cpio_certo)" "$ESP/$CPIO"
    local kv; kv=$(python3 "$LIB/limine.py" atualizar "$LCONF" "$CPIO" 2>&1) || parar "limine.conf: $kv"
    # so da para conferir o CONFIG_ACPI_TABLE_UPGRADE do kernel que esta rodando: outro kernel na entrada = nao libera
    [ "$kv" = "$(uname -r)" ] || { python3 "$LIB/limine.py" remover "$LCONF"; parar "entrada do Limine usa o kernel $kv mas esta rodando $(uname -r) - nao libero neste boot"; }
    if [ "$n" = "$BASE" ]; then
        local s out; for s in $SERV_GPU_GOV; do systemctl stop "$s" 2>/dev/null; done
        out=$(python3 "$LIB/smu.py" gravar "$MASCARA" 2>&1) || { blog "SMU: $out - segue com $BASE threads"; exit 0; }
        blog "mascara: $out"
    fi
    bootctl set-oneshot "$ENT_ID" || parar "bootctl set-oneshot falhou"
    echo "$(date '+%F %T') kernel $kv" > "$EST/tentativa"; sync
    reboot_quente; blog "reset quente para a entrada $ENT_ID (kernel $kv)"
    systemctl reboot; sleep 60
}

# ---------- correcao ACPI (SSDT do e-tho) em todo boot ----------
# reaplica o cpio da entrada bc250-nucleos (se existir) depois que a initramfs mudou
_acpi_refaz_cpio() { [ -f "$ESP/$CPIO" ] && [ -f "$LIB/final.cpio" ] && install -m 0644 "$(cpio_certo)" "$ESP/$CPIO"; return 0; }
_acpi_tira() { rm -f "$ACPI_DROPIN"; local f; for f in $(echo "$ACPI_SHA" | awk '{print $2}'); do rm -f "$ACPI_DIR/$f"; done; rmdir "$ACPI_DIR" 2>/dev/null; }
acpi_instalar() {
    local falha=0 d f outros
    echo "${B}BC-250: correcao ACPI (P-states/C-states do e-tho) na initramfs (Arch/CachyOS + Limine)${N0}"
    . /etc/os-release
    [[ "$ID" == arch || " ${ID_LIKE:-} " == *" arch "* ]] && ok "distro: $NAME" || { ruim "distro $NAME: esta versao e para Arch/CachyOS"; falha=1; }
    bootctl status 2>/dev/null | grep -q 'Product: Limine' && [ -f "$LCONF" ] && ok "boot: Limine ($LCONF)" || { ruim "bootloader nao e Limine com $LCONF"; falha=1; }
    command -v limine-mkinitcpio >/dev/null && [ -f /usr/lib/initcpio/install/acpi_override ] && ok "limine-mkinitcpio e hook acpi_override presentes" || { ruim "falta limine-mkinitcpio ou o hook acpi_override do mkinitcpio"; falha=1; }
    kconfig_ok && ok "kernel $(uname -r) com CONFIG_ACPI_TABLE_UPGRADE" || { ruim "kernel sem CONFIG_ACPI_TABLE_UPGRADE"; falha=1; }
    grep -q '\[none\]' /sys/kernel/security/lockdown 2>/dev/null || [ ! -e /sys/kernel/security/lockdown ] && ok "lockdown: none" || { ruim "kernel em lockdown: ignora tabelas da initramfs"; falha=1; }
    grep -q 'AMD BC-250' /proc/cpuinfo && [ "$(cat /sys/class/dmi/id/bios_version)" = P3.00 ] && ok "placa: BC-250 | BIOS P3.00" || { ruim "so para BC-250 com BIOS P3.00 (as SSDT foram feitas para ela)"; falha=1; }
    (cd "$AQUI/acpi" && echo "$ACPI_SHA" | sed 's/ /  /' | sha256sum -c --quiet) && ok "SSDT do e-tho v1.1.0 conferidas (sha256)" || { ruim "arquivos em $AQUI/acpi diferentes dos esperados"; falha=1; }
    if [ -f "$ACPI_DROPIN" ]; then ok "ja instalada ($ACPI_DROPIN): vai so regerar a initramfs"
    else
        # tabelas de outra correcao ja ativas (ex.: a do BC250 Control Center)
        ssdt_vivas | grep -qE '^(PSTATES|STUBS|P_CST3):|^AMD CPU:([2-9]|[0-9]{2,})$' && { ruim "ja ha outra correcao ACPI ativa neste boot ($(ssdt_vivas | tr '\n' ' ')) - remova-a antes (no Control Center: desinstalar a correcao ACPI)"; falha=1; }
        grep -q 'bc250-acpi' "$LCONF" 2>/dev/null && { ruim "o limine.conf ja carrega um bc250-acpi.cpio (outra instalacao) - remova antes"; falha=1; }
        for d in /usr/lib/initcpio/acpi_override "$ACPI_DIR"; do
            outros=$(compgen -G "$d/*.aml"); [ -n "$outros" ] && { ruim "ja ha tabelas em $d: $(echo $outros)"; falha=1; }
        done
    fi
    [ -f "$ESP/$CPIO" ] && [ ! -f "$LIB/madt.cpio" ] && { ruim "nucleo extra instalado por versao antiga do script (sem madt.cpio): rode 'desfazer' e 'instalar' de novo antes"; falha=1; }
    [ "$falha" = 0 ] || { ruim "${B}Nada foi alterado.${N0}"; return 1; }
    echo
    echo "  Vai: copiar as 3 SSDT para $ACPI_DIR, criar $ACPI_DROPIN (HOOKS+=(acpi_override))"
    echo "  e rodar limine-mkinitcpio. Snapshots antigos do Limine continuam sem a correcao."
    [ -f "$CONF" ] && echo "  O nucleo extra continua: a entrada '$ENT_ID' passa a levar so a MADT."
    pergunta "Instalar a correcao ACPI?" || return 0
    grava_aux || return 1
    mkdir -p "$ACPI_DIR"
    for f in $(echo "$ACPI_SHA" | awk '{print $2}'); do install -m 0644 "$AQUI/acpi/$f" "$ACPI_DIR/$f"; done
    printf '# gerado pelo bc250-nucleos-arch.sh: SSDT do e-tho (em %s) no cpio early da initramfs\nHOOKS+=(acpi_override)\n' "$ACPI_DIR" > "$ACPI_DROPIN"
    if ! limine-mkinitcpio; then ruim "limine-mkinitcpio falhou: desfazendo"; _acpi_tira; limine-mkinitcpio; return 1; fi
    acpi_na_initramfs || { ruim "as SSDT nao apareceram na initramfs da entrada do kernel: desfazendo"; _acpi_tira; limine-mkinitcpio; return 1; }
    ok "SSDT na initramfs da entrada do kernel"
    _acpi_refaz_cpio
    log "arch: correcao ACPI instalada"
    ok "Instalada. Reinicie; depois: sudo $0 status (deve mostrar PSTATES e STUBS carregadas)"
}
acpi_desfazer() {
    echo "${B}Desfazer a correcao ACPI${N0}: remove $ACPI_DROPIN e as SSDT de $ACPI_DIR e regera a initramfs."
    [ -f "$ACPI_DROPIN" ] || { aviso "nao esta instalada por este script"; return 0; }
    pergunta "Desfazer?" || return 0
    _acpi_tira
    limine-mkinitcpio || { ruim "limine-mkinitcpio falhou - rode-o de novo a mao"; return 1; }
    _acpi_refaz_cpio
    log "arch: correcao ACPI desfeita"
    ok "Desfeita. Reinicie."
}

status() {
    echo "${B}Status${N0}"
    echo "  Agora: $(threads) threads (online $(cat /sys/devices/system/cpu/online)) | mascara $([ -f "$LIB/smu.py" ] && mascara || echo '?')"
    [ -f "$CONF" ] && { . "$CONF"; echo "  Instalado: alvo $ALVO threads (base $BASE)"; } || echo "  Nao instalado como padrao."
    [ -f "$EST/teste-resultado.txt" ] && echo "  Ultimo teste: $(cat "$EST/teste-resultado.txt")"
    [ -e "/etc/systemd/system/$UNIT_T" ] && echo "  Teste agendado (aguardando o boot de teste)."
    [ -e "$EST/falhou" ] && aviso "parado por falha: $(cat "$EST/falhou")"
    local v; v=$(ssdt_vivas | tr '\n' ' ')
    if [ -f "$ACPI_DROPIN" ]; then echo "  Correcao ACPI: instalada | initramfs: $(acpi_na_initramfs && echo com SSDT || echo SEM SSDT - rode limine-mkinitcpio)"
    else echo "  Correcao ACPI: nao instalada por este script"; fi
    echo "  SSDT neste boot: $v$([[ " $v" == *" PSTATES:"* ]] && echo '-> correcao ATIVA' || echo '-> de fabrica')"
    echo "  Boots:"; tail -n 6 "$EST/boot.log" 2>/dev/null | sed 's/^/    /'
}

desfazer() {
    echo "${B}Desfazer${N0}: remove o servico, a entrada do Limine e o cpio."
    pergunta "Desfazer?" || return 0
    for u in "$UNIT" "$UNIT_T"; do systemctl disable "$u" 2>/dev/null; rm -f "/etc/systemd/system/$u"; done; systemctl daemon-reload
    [ -f "$LIB/limine.py" ] && python3 "$LIB/limine.py" remover "$LCONF"
    rm -f "$ESP/$CPIO" "$CONF" "$EST/tentativa" "$EST/falhou"
    bootctl set-oneshot "" 2>/dev/null
    reboot_frio; log "arch: desfeito"
    ok "Desfeito. Reinicie normalmente (frio) para voltar ao padrao de fabrica."
}

case "${1:-}" in
    testar) testar;;
    _teste) _teste;;
    instalar) instalar;;
    _boot) _boot;;
    status) status;;
    desfazer) desfazer;;
    acpi) acpi_instalar;;
    acpi-desfazer) acpi_desfazer;;
    *) echo "uso: sudo $0 testar | instalar | status | desfazer | acpi | acpi-desfazer";;
esac
