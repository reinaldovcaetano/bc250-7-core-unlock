#!/bin/bash
# =====================================================================================
#  bc250-grub.sh - escolher no MENU DO GRUB quantos nucleos a AMD BC-250 usa (Fedora/Nobara)
#
#  Para placa cujo nucleo extra JA FOI TESTADO (padrao: nucleo 7). Em vez de destravar sozinho
#  em todo boot (como o servico do bc250-nucleos.sh), aqui o destrave SO acontece quando a
#  entrada de destrave e escolhida no GRUB. O menu do GRUB fica visivel (5 s) com:
#
#    BC-250: 6 nucleos (normal)             nunca destrava (tabela de CPUs so com os nucleos de fabrica)
#    BC-250: 7 nucleos (destrave)           destrava: grava 0xFF na SMU e reinicia a quente nela mesma
#    BC-250: 7 nucleos sem OC (seguranca)   igual, com o OC da CPU/GPU mascarado nesse boot
#    Nobara Linux (...)                     entrada original do sistema, intocada (ultimo recurso)
#
#    sudo ./bc250-grub.sh instalar      confere tudo, cria as entradas e o servico (pede confirmacao)
#    sudo ./bc250-grub.sh padrao 6|7    o que o GRUB escolhe sozinho quando ninguem mexe no menu
#    sudo ./bc250-grub.sh status
#    sudo ./bc250-grub.sh desfazer
#    NUCLEOS="7" muda quais nucleos ocultos sao ligados (padrao: 7)
#
#  Protecao contra loop (o motivo deste script):
#    - o "padrao" do GRUB (saved_entry) e SEMPRE a entrada de 6 nucleos;
#    - "padrao 7" e um one-shot do GRUB (next_entry), rearmado so depois que o boot com 7 nucleos
#      ficou de pe por ESTAVEL segundos (padrao 300) ou desligou de forma limpa. O GRUB apaga o
#      one-shot ao usa-lo: se travar, o proximo boot cai sozinho em 6 nucleos;
#    - um boot de 7 nucleos que nao terminou e detectado no boot seguinte: o padrao vira 6 e fica
#      registrado em /var/lib/bc250-grub/boot.log (sudo ./bc250-grub.sh status).
#  Usa o smu.py e o madt.py do bc250-nucleos.sh (mantenha os dois juntos na pasta).
# =====================================================================================
set -u
AQUI=$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)
NUCLEOS=${NUCLEOS:-7}
LIB=/usr/local/lib/bc250-grub
EST=/var/lib/bc250-grub
CONF=/etc/bc250-grub.conf
ENTRIES=/boot/loader/entries
GRUBDEF=/etc/default/grub
GRUBCFG=/boot/grub2/grub.cfg
E6=bc250-6nucleos                        # ids das entradas (arquivos em $ENTRIES e cpio em /boot)
E7=bc250-7nucleos
E7S=bc250-7nucleos-semoc
UNIT=bc250-grub.service
HOOK=/etc/kernel/install.d/96-bc250-grub.install
TIMEOUT=5
SERV_OC="bc250-smu-oc bc250-cpu-escada cyan-skillfish-governor-smu oberon-governor bc250-cu-live-manager"
SERV_GPU_GOV="cyan-skillfish-governor-smu oberon-governor"   # precisam estar parados para falar com a SMU
# e-tho/bc250-acpi-fix v1.1.0 (identicas ao payload do BC250 Control Center)
ACPI_SHA="dcc596e8b566a74268f75d8c66bd90a23bc8ac02768283b265edfec13f9d7fca SSDT-CPU.aml
cb3c96c622d2d653777020283c434f92c26bf2c83502a27d9a398f98424a771f SSDT-PST.aml
c219ce775476725d49739024e149556228436a1c3faf0768a7c3eff9d85f66c2 SSDT-STUBS.aml"

B=$'\e[1m'; VM=$'\e[31m'; VD=$'\e[32m'; AM=$'\e[33m'; N0=$'\e[0m'
[ -t 1 ] || { B=; VM=; VD=; AM=; N0=; }
ok()   { echo "  ${VD}OK${N0}  $*"; }
ruim() { echo "  ${VM}ERRO${N0} $*"; }
aviso() { echo "  ${AM}!!${N0}  $*"; }
pergunta() { local r; read -rp "$1 [s/N] " r; [[ "$r" =~ ^[sS]$ ]]; }
log()  { echo "$(date '+%F %T') $*" >> "$EST/historico.log"; }   # acoes manuais
blog() { echo "$*"; echo "$(date '+%F %T') $*" >> "$EST/boot.log"; }   # servico
# threads ONLINE (nao "nproc --all": a MADT nova declara 14 mesmo quando o hardware so tem 12)
threads() { grep -c '^processor' /proc/cpuinfo; }
apics()   { awk '/^apicid/{print $3}' /proc/cpuinfo | sort -n | tr '\n' ' ' | sed 's/ $//'; }
cmd_param() { tr ' ' '\n' < /proc/cmdline | sed -n "s/^$1=//p" | tail -1; }
mascara() { python3 "$LIB/smu.py" ler; }
reboot_frio()   { echo acpi > /sys/kernel/reboot/type; echo cold > /sys/kernel/reboot/mode; }
reboot_quente() { echo efi  > /sys/kernel/reboot/type; echo warm > /sys/kernel/reboot/mode; }
apics_de() { python3 -c "import sys;m=int(sys.argv[1],16);x=[int(c) for c in sys.argv[2].split()];print(' '.join(str(a) for c in range(8) if (m>>c&1 or c in x) for a in (2*c,2*c+1)))" "$1" "${2:-}"; }
bios_id() { echo "$(cat /sys/class/dmi/id/bios_version 2>/dev/null) $(cat /sys/class/dmi/id/bios_date 2>/dev/null)"; }
cset() { sed -i "/^$1=/d" "$CONF"; echo "$1=\"$2\"" >> "$CONF"; }
# estado do ciclo de 7 nucleos: "" | armado (proximo boot programado em 7) | destravando (reset quente feito,
# esperando o boot de 7 nucleos confirmar que ficou de pe)
estado() { cat "$EST/tentativa" 2>/dev/null; }
# desliga as threads pelo ID APIC (o kernel numera as CPUs na ordem da MADT: "cpu6" pode ser outro nucleo).
# Retorna 1 se algum APIC pedido continuar online.
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

# ---------- entradas do GRUB ----------
# entrada BLS do kernel mais novo (a que o Nobara/kernel-install cria; nunca e alterada)
entrada_base() {
    local mid; mid=$(cat /etc/machine-id)
    ls "$ENTRIES/$mid"-*.conf 2>/dev/null | grep -v rescue | sort -V | tail -1
}
# copia a entrada base: troca o titulo, poe o cpio (MADT/SSDT) como 1o initrd e acrescenta opcoes
cria_entrada() {   # base id titulo cpio "opcoes"
    local base=$1 id=$2 tit=$3 cpio=$4 extra=$5 pre
    pre=$(sed -n 's|^linux[[:space:]]\+\(.*\)/vmlinuz-.*|\1|p' "$base" | head -1)   # "" com /boot separado
    sed -e "s|^title .*|title $tit|" -e "0,/^initrd /s|^initrd |initrd $pre/$cpio\ninitrd |" \
        -e "s|^options .*|& $extra|" "$base" > "$ENTRIES/$id.conf.tmp"
    if grep -q "^initrd $pre/$cpio\$" "$ENTRIES/$id.conf.tmp" && grep -q "^options .*bc250.entrada=$id\b" "$ENTRIES/$id.conf.tmp"; then
        mv "$ENTRIES/$id.conf.tmp" "$ENTRIES/$id.conf"
    else
        rm -f "$ENTRIES/$id.conf.tmp"; echo "falha ao gerar a entrada $id a partir de $base"; return 1
    fi
}
remove_entradas() { rm -f "$ENTRIES/$E6.conf" "$ENTRIES/$E7.conf" "$ENTRIES/$E7S.conf" "/boot/$E6.cpio" "/boot/$E7.cpio"; }
# recria as 3 entradas a partir do kernel mais novo (instalar, todo boot e toda atualizacao de kernel)
atualiza_entradas() {
    local base kver masc="" s
    base=$(entrada_base); [ -n "$base" ] || { echo "entrada do kernel nao encontrada em $ENTRIES"; return 1; }
    kver=$(sed -n 's|^linux[[:space:]]\+.*/vmlinuz-||p' "$base" | head -1)
    if ! grep -q '^CONFIG_ACPI_TABLE_UPGRADE=y' "/boot/config-$kver" 2>/dev/null; then
        remove_entradas; echo "kernel $kver sem CONFIG_ACPI_TABLE_UPGRADE: entradas bc250 removidas"; return 1
    fi
    # a initramfs ja traz SSDT (ex.: correcao ACPI do Control Center instalada depois)? usa os cpio so com a MADT,
    # para as tabelas nunca carregarem em dobro
    local v=""
    [ -f "$LIB/6m.cpio" ] && cpio -it --quiet < "/boot/initramfs-$kver.img" 2>/dev/null | grep -q '^kernel/firmware/acpi/SSDT' && v=m
    install -m 0644 "$LIB/6$v.cpio" "/boot/$E6.cpio" && install -m 0644 "$LIB/7$v.cpio" "/boot/$E7.cpio" || { echo "falha ao copiar os cpio para /boot"; return 1; }
    for s in $SERV_OC; do systemctl cat "$s.service" >/dev/null 2>&1 && masc="$masc systemd.mask=$s.service"; done
    cria_entrada "$base" "$E6"  "BC-250: $((BASE / 2)) nucleos (normal)" "$E6.cpio" "bc250.modo=6 bc250.entrada=$E6" &&
    cria_entrada "$base" "$E7"  "BC-250: $((ALVO / 2)) nucleos (destrave)" "$E7.cpio" "bc250.modo=7 bc250.entrada=$E7" &&
    cria_entrada "$base" "$E7S" "BC-250: $((ALVO / 2)) nucleos sem OC (seguranca)" "$E7.cpio" "bc250.modo=7 bc250.entrada=$E7S$masc" || return 1
    echo "$kver"
}
# o padrao gravado do GRUB e SEMPRE a entrada de 6 nucleos; o "padrao 7" e o one-shot (next_entry)
fixa_padrao_grub() {
    [ -f "$ENTRIES/$E6.conf" ] || return 0
    [ "$(grub2-editenv list | sed -n 's/^saved_entry=//p')" = "$E6" ] || grub2-set-default "$E6"
}
arma() { grub2-reboot "$E7" && echo armado > "$EST/tentativa"; }
desarma() { grub2-editenv - unset next_entry; [ "$(estado)" = armado ] && rm -f "$EST/tentativa"; return 0; }
# um boot de 7 nucleos nao terminou: nunca mais entra em 7 sozinho ate alguem mandar
falha() {
    rm -f "$EST/tentativa"; grub2-editenv - unset next_entry
    [ "$PADRAO" = 7 ] && { cset PADRAO 6; PADRAO=6; }
    echo "$(date '+%F %T') $1" > "$EST/ultima-falha"
    blog "FALHA: $1. Padrao do GRUB = $((BASE / 2)) nucleos (para voltar: sudo bc250-grub.sh padrao 7)"
    wall "BC-250: $1. O GRUB voltou para $((BASE / 2)) nucleos por padrao (veja: sudo bc250-grub.sh status)" 2>/dev/null
}

# ---------- servico: roda em todo boot ----------
_boot() {
    [ -f "$CONF" ] || exit 0
    . "$CONF"
    local n modo ent t kv m out="" s
    n=$(threads); modo=$(cmd_param bc250.modo); ent=$(cmd_param bc250.entrada); t=$(estado)
    reboot_frio     # todo reboot e frio (a mascara volta para a de fabrica), menos o reset quente do destrave
    [ -f "$EST/boot.log" ] && [ "$(wc -l < "$EST/boot.log")" -gt 500 ] && { tail -n 400 "$EST/boot.log" > "$EST/boot.log.tmp"; mv "$EST/boot.log.tmp" "$EST/boot.log"; }
    kv=$(atualiza_entradas 2>&1) || blog "entradas do GRUB: $kv"
    fixa_padrao_grub
    if [ "$n" -gt "$BASE" ]; then
        if [ "$modo" = 7 ] && [ "$n" = "$ALVO" ] && [ "$(apics)" = "$AP7" ]; then
            blog "OK: $ent com $n threads (confirma em ${ESTAVEL}s ou no desligamento limpo)"
            systemd-run --quiet --unit=bc250-grub-confirma --on-active="$ESTAVEL" "$LIB/bc250-grub.sh" _confirma
            exit 0
        fi
        # mascara 0xFF numa entrada que nao devia ter os nucleos extras: deixa so os de fabrica (ou os escolhidos)
        local off d; [ "$modo" = 7 ] && off=$OFF7 || off=$OFF6
        [ -n "$off" ] && { desliga_apics $off && d=desligados || d="FALHA AO DESLIGAR"; }
        blog "$n threads no modo '${modo:-entrada original}' (APIC $(apics)): fora do esperado; APIC ${off:-nenhum} ${d:-}, online=$(cat /sys/devices/system/cpu/online)"
        exit 0
    fi
    [ "$n" = "$BASE" ] || { blog "$n threads: inesperado, nada feito"; exit 0; }
    if [ "$modo" != 7 ]; then
        [ "$modo" = 6 ] && { out=$(python3 "$LIB/confere_madt.py" "$AP6" 2>&1) || blog "aviso: a tabela de CPUs/ACPI da entrada de 6 nucleos nao carregou ($out)"; }
        [ -n "$t" ] && falha "o ultimo boot de $((ALVO / 2)) nucleos nao terminou (estado '$t': travou, desligou no botao ou outra entrada foi escolhida no menu)"
        blog "modo ${modo:-entrada original}: $n threads"
        systemd-run --quiet --unit=bc250-grub-confirma --on-active="$ESTAVEL" "$LIB/bc250-grub.sh" _confirma
        exit 0
    fi
    # ---- modo 7 com a mascara de fabrica: destrave ----
    [ "$t" = destravando ] && falha "o boot destravado anterior nao terminou; tentando de novo porque '$ent' foi escolhida no menu"
    grep -qw bc250.nucleos.nao /proc/cmdline && { blog "destrave desligado pela linha do kernel"; rm -f "$EST/tentativa"; exit 0; }
    [ -e /etc/bc250-grub.desligado ] && { blog "destrave desligado por /etc/bc250-grub.desligado"; rm -f "$EST/tentativa"; exit 0; }
    [ -f "$ENTRIES/$ent.conf" ] || { blog "entrada '$ent' nao existe mais - segue com $n threads"; rm -f "$EST/tentativa"; exit 0; }
    [ "$(bios_id)" = "$BIOS" ] || { blog "BIOS mudou ($BIOS -> $(bios_id)): a tabela de CPUs gerada pode nao servir - destrave cancelado; rode o instalar de novo"; rm -f "$EST/tentativa"; exit 0; }
    grep -q '\[none\]' /sys/kernel/security/lockdown 2>/dev/null || { blog "kernel em lockdown (Secure Boot?): a tabela de CPUs nao carrega - destrave cancelado"; rm -f "$EST/tentativa"; exit 0; }
    # a MADT nova TEM de estar valendo ja neste boot: sem ela o reset quente subiria com a MADT da BIOS e o
    # kernel acordaria o nucleo ruim antes de qualquer servico poder desliga-lo
    out=$(python3 "$LIB/confere_madt.py" "$AP7" 2>&1) || { blog "tabela de CPUs do destrave NAO carregou neste boot ($out) - destrave cancelado"; rm -f "$EST/tentativa"; exit 0; }
    m=$(mascara)
    [ "$m" = "$MASCARA" ] || { blog "mascara $m diferente da de fabrica ($MASCARA) - nada feito; desligue a placa da tomada"; rm -f "$EST/tentativa"; exit 0; }
    for s in $SERV_GPU_GOV; do systemctl stop "$s" 2>/dev/null; done
    out=$(python3 "$LIB/smu.py" gravar "$MASCARA" 2>&1) || { blog "SMU: $out - segue com $n threads"; rm -f "$EST/tentativa"; exit 0; }
    # sem o one-shot o reset quente cairia na entrada padrao (6 nucleos, que nao liga os extras); o reboot fica frio
    grub2-reboot "$ent" || { blog "grub2-reboot falhou - segue com $n threads (proximo reboot frio)"; rm -f "$EST/tentativa"; exit 0; }
    echo destravando > "$EST/tentativa"; sync
    reboot_quente; blog "mascara: $out; reset quente para $ent"
    systemctl reboot; sleep 60
}

# ---------- confirma que o boot ficou de pe (timer de ESTAVEL s ou desligamento limpo) ----------
_confirma() {
    [ -f "$CONF" ] || exit 0
    . "$CONF"
    local n modo t; n=$(threads); modo=$(cmd_param bc250.modo); t=$(estado)
    if [ "$modo" = 7 ]; then [ "$n" = "$ALVO" ] || exit 0     # 1o boot do destrave (12 threads): nao confirma nada
    else [ "$n" = "$BASE" ] || exit 0; fi
    [ "$t" = destravando ] && blog "confirmado: $n threads de pe (modo $modo)"
    if [ "$PADRAO" = 7 ]; then arma; else rm -f "$EST/tentativa"; fi
    exit 0
}

# ---------- hook do kernel-install: kernel novo ou removido ----------
_kernel() {
    [ -f "$CONF" ] || exit 0
    . "$CONF"
    atualiza_entradas >/dev/null 2>&1
    fixa_padrao_grub      # UPDATEDEFAULT=yes poe o kernel novo como padrao: volta para a entrada de 6 nucleos
    [ "$(estado)" = armado ] && grub2-reboot "$E7"
    exit 0
}

# ---------- instalar ----------
grava_aux() {
    mkdir -p "$LIB"
    # smu.py e madt.py: os mesmos do bc250-nucleos.sh
    sed -n "/^cat > \"\$LIB\/smu.py\" <<'PY'$/,/^PY$/p" "$AQUI/bc250-nucleos.sh" | sed '1d;$d' > "$LIB/smu.py"
    sed -n "/^cat > \"\$LIB\/madt.py\" <<'PY'$/,/^PY$/p" "$AQUI/bc250-nucleos.sh" | sed '1d;$d' > "$LIB/madt.py"
    cat > "$LIB/confere_madt.py" <<'PY'
# Confere se a MADT em uso neste boot e a gerada pelo bc250-grub.sh (UID = APIC+1, 16 LAPIC) com os APIC pedidos ligados.
# Uso: confere_madt.py "<apics ligados>"
import struct, sys
d = open("/sys/firmware/acpi/tables/APIC", "rb").read()
lap, o = [], 44
while o < len(d):
    if d[o] == 0: lap.append((d[o + 2], d[o + 3], struct.unpack("<I", d[o + 4:o + 8])[0]))
    o += max(d[o + 1], 2)
lig = sorted(a for u, a, f in lap if f & 1)
esp = sorted(int(x) for x in sys.argv[1].split())
if len(lap) != 16 or any(u != a + 1 for u, a, f in lap) or lig != esp:
    sys.exit("MADT em uso e a da BIOS ou outra: APIC ligados %s, esperado %s" % (lig, esp))
print("MADT nova em uso: APIC %s" % lig)
PY
    grep -q 'MASK = 0x5A870' "$LIB/smu.py" && grep -q 'seq = ' "$LIB/madt.py" || { ruim "nao consegui extrair smu.py/madt.py do $AQUI/bc250-nucleos.sh"; return 1; }
}
menu_grub() {
    [ -f "$EST/grub.default.orig" ] || cp -p "$GRUBDEF" "$EST/grub.default.orig"
    [ -f "$EST/grub.cfg.orig" ] || cp -p "$GRUBCFG" "$EST/grub.cfg.orig"
    sed -i -e '/^GRUB_DEFAULT=/d' -e '/^GRUB_TIMEOUT=/d' -e '/^GRUB_TIMEOUT_STYLE=/d' \
           -e '/^GRUB_HIDDEN_TIMEOUT/d' -e '/^GRUB_SAVEDEFAULT=/d' "$GRUBDEF"
    printf "GRUB_DEFAULT='saved'\nGRUB_TIMEOUT='%s'\nGRUB_TIMEOUT_STYLE='menu'\n" "$TIMEOUT" >> "$GRUBDEF"
    grub2-editenv - unset menu_auto_hide
    grub2-mkconfig -o "$GRUBCFG" >/dev/null 2>&1 || { ruim "grub2-mkconfig falhou (backup em $EST/grub.cfg.orig)"; return 1; }
    # o normal e o grub.cfg do EFI ser um stub (configfile -> /boot/grub2); se for uma configuracao completa, regera tambem
    local f; for f in /boot/efi/EFI/*/grub.cfg; do
        [ -f "$f" ] && grep -q blscfg "$f" && ! grep -q configfile "$f" || continue
        cp -p "$f" "$EST/$(basename "$(dirname "$f")")-grub.cfg.orig" 2>/dev/null
        grub2-mkconfig -o "$f" >/dev/null 2>&1 && aviso "$f era uma configuracao completa: regerada tambem"
    done
    ok "menu do GRUB visivel por $TIMEOUT s (antes: $(sed -n 's/^GRUB_TIMEOUT=//p' "$EST/grub.default.orig"), backup em $EST/grub.default.orig)"
}
instalar() {
    local falha=0 m n nb ocultos c placa bios
    echo "${B}Instalar: escolha de nucleos pelo menu do GRUB (nucleo extra: $NUCLEOS)${N0}"
    . /etc/os-release
    if [[ "$ID" == fedora || "$ID" == nobara || " ${ID_LIKE:-} " == *" fedora "* ]]; then ok "distro: $NAME"
    else ruim "distro $NAME nao suportada (so Fedora/Nobara)"; falha=1; fi
    [ -e /run/ostree-booted ] && { ruim "sistema imutavel (ostree) - nao suportado"; falha=1; }
    if [ -d "$ENTRIES" ] && grep -qE "^GRUB_ENABLE_BLSCFG=['\"]?true" "$GRUBDEF" && [ -f "$GRUBCFG" ] \
       && command -v grub2-reboot >/dev/null && command -v grub2-set-default >/dev/null; then ok "boot: GRUB com BLS"
    else ruim "boot nao e GRUB com BLS ($ENTRIES, $GRUBCFG, grub2-reboot)"; falha=1; fi
    [ -d /sys/firmware/efi ] || { ruim "placa nao bootou em modo EFI"; falha=1; }
    case "$(findmnt -no FSTYPE --target /boot)" in
        ext4|ext3|ext2|xfs) ok "/boot em $(findmnt -no FSTYPE --target /boot): o GRUB consegue apagar o one-shot (next_entry)";;
        *) ruim "/boot em $(findmnt -no FSTYPE --target /boot): o GRUB nao grava o grubenv aqui e o one-shot nunca seria apagado (risco de loop)"; falha=1;;
    esac
    grep -q '^CONFIG_ACPI_TABLE_UPGRADE=y' "/boot/config-$(uname -r)" 2>/dev/null && ok "kernel $(uname -r) com CONFIG_ACPI_TABLE_UPGRADE" \
        || { ruim "kernel sem CONFIG_ACPI_TABLE_UPGRADE"; falha=1; }
    grep -q '\[none\]' /sys/kernel/security/lockdown 2>/dev/null && ok "lockdown: none (Secure Boot desligado)" \
        || { ruim "kernel em lockdown ($(cat /sys/kernel/security/lockdown 2>/dev/null)): desligue o Secure Boot"; falha=1; }
    placa=$(cat /sys/class/dmi/id/board_name 2>/dev/null); bios=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
    if [[ "$placa" == *BC-250* ]] || grep -q 'AMD BC-250' /proc/cpuinfo; then ok "placa BC-250, BIOS $bios"
    else ruim "isto nao e uma AMD BC-250"; falha=1; fi
    for c in python3 cpio; do command -v $c >/dev/null || { ruim "falta o $c (sudo dnf install $c)"; falha=1; }; done
    for c in bc250-nucleos-boot bc250-nucleos-teste bc250-7cores; do
        [ -e "/etc/systemd/system/$c.service" ] && { ruim "o desbloqueio automatico antigo ($c.service) esta instalado - desfaca antes (bc250-nucleos.sh opcao 9)"; falha=1; }
    done
    [ "$falha" = 0 ] || { ruim "${B}Nada foi alterado.${N0}"; return 1; }
    mkdir -p "$EST"; grava_aux || return 1
    m=$(mascara) || { ruim "nao consegui ler a mascara pela SMU"; return 1; }
    [ "$m" = 0xFF ] && { ruim "mascara ja esta 0xFF (destrave ativo neste boot): escolha '6 nucleos' ou desligue a placa da tomada e rode de novo"; return 1; }
    nb=$(python3 -c "print(bin(int('$m',16)).count('1'))"); n=$(threads)
    [ "$n" = $((nb * 2)) ] || { ruim "mascara $m indica $((nb * 2)) threads, mas ha $n online - faca um boot frio"; return 1; }
    ocultos=$(python3 -c "m=int('$m',16);print(' '.join(str(c) for c in range(8) if not m>>c&1))")
    [ -n "$ocultos" ] || { ok "nenhum nucleo oculto (mascara $m). Nada a fazer."; return 0; }
    for c in $NUCLEOS; do [[ " $ocultos " == *" $c "* ]] || { ruim "nucleo $c nao esta oculto (ocultos: $ocultos)"; return 1; }; done
    ok "mascara $m: ocultos = $ocultos; liga = $NUCLEOS"
    cp /sys/firmware/acpi/tables/APIC "$EST/madt-original.aml"
    local vm; vm=$(python3 "$LIB/madt.py" verificar "$EST/madt-original.aml" "$m" 2>&1) || { ruim "$vm"; ruim "layout da MADT desconhecido. Nada foi alterado no boot."; return 1; }
    ok "$vm"
    # SSDT do e-tho (P-states/C-states): nos dois modos, se a BIOS for a P3.00 e a initramfs ainda nao as tiver
    local acpi="" kver; kver=$(uname -r)
    if [ "$bios" = P3.00 ] && grep -l 'AMD CPU' /sys/firmware/acpi/tables/SSDT* >/dev/null 2>&1; then
        if cpio -it --quiet < "/boot/initramfs-$kver.img" 2>/dev/null | grep -q '^kernel/firmware/acpi/SSDT'; then
            aviso "a initramfs ja traz SSDT (correcao ACPI do Control Center?): os cpio levam so a tabela de CPUs"
        elif (cd "$AQUI/acpi" && echo "$ACPI_SHA" | sed 's/ /  /' | sha256sum -c --quiet); then
            mkdir -p "$LIB/acpi"; cp "$AQUI"/acpi/*.aml "$LIB/acpi/"; acpi="$LIB/acpi"
            ok "BIOS P3.00: as SSDT do e-tho v1.1.0 (sha256 conferido) vao junto nos dois modos (clock 800-3200 MHz)"
        else aviso "arquivos em $AQUI/acpi diferentes dos esperados: sem a correcao ACPI"; fi
    else aviso "BIOS $bios: sem a correcao ACPI (feita para a P3.00)"; fi
    local ap6 ap7 off6="" off7=""
    ap6=$(apics_de "$m" ""); ap7=$(apics_de "$m" "$NUCLEOS")
    for c in $ocultos; do off6="$off6 $((2 * c)) $((2 * c + 1))"; [[ " $NUCLEOS " == *" $c "* ]] || off7="$off7 $((2 * c)) $((2 * c + 1))"; done
    echo
    echo "  Vai criar no GRUB (o menu passa a aparecer por $TIMEOUT s em todo boot):"
    echo "    ${B}BC-250: $nb nucleos (normal)${N0}            APIC $ap6  <- padrao, nunca destrava"
    echo "    ${B}BC-250: $((nb + $(echo $NUCLEOS | wc -w))) nucleos (destrave)${N0}          APIC $ap7"
    echo "    ${B}BC-250: $((nb + $(echo $NUCLEOS | wc -w))) nucleos sem OC (seguranca)${N0}  igual, com o OC mascarado"
    echo "    e a entrada original do Nobara continua la, intocada."
    echo "  Escolher o destrave: o boot sobe com $n threads, grava 0xFF na SMU e reinicia a quente sozinho"
    echo "  (~20 s a mais esperando o nucleo que ainda nao existe) e volta com $(echo $ap7 | wc -w) threads."
    pergunta "Instalar agora?" || return 1
    python3 "$LIB/madt.py" gerar "$EST/madt-original.aml" "$ap6" "$LIB/6.cpio" $acpi >/dev/null &&
    python3 "$LIB/madt.py" gerar "$EST/madt-original.aml" "$ap7" "$LIB/7.cpio" $acpi >/dev/null || { ruim "falha ao gerar as tabelas"; return 1; }
    rm -f "$LIB/6m.cpio" "$LIB/7m.cpio"
    if [ -n "$acpi" ]; then      # variantes so com a MADT, para quando a initramfs passar a trazer as SSDT
        python3 "$LIB/madt.py" gerar "$EST/madt-original.aml" "$ap6" "$LIB/6m.cpio" >/dev/null &&
        python3 "$LIB/madt.py" gerar "$EST/madt-original.aml" "$ap7" "$LIB/7m.cpio" >/dev/null || { ruim "falha ao gerar as tabelas"; return 1; }
    fi
    install -m 0755 "$(readlink -f "${BASH_SOURCE[0]}")" "$LIB/bc250-grub.sh"
    ln -sf "$LIB/bc250-grub.sh" /usr/local/sbin/bc250-grub.sh
    local padrao=6; [ -f "$CONF" ] && padrao=$(. "$CONF"; echo "$PADRAO")
    cat > "$CONF" <<EOF
# gerado pelo bc250-grub.sh $(date '+%F %T')
MASCARA="$m"
NUCLEOS="$NUCLEOS"
BASE="$n"
ALVO="$(echo $ap7 | wc -w)"
AP6="$ap6"
AP7="$ap7"
BIOS="$(bios_id)"
OFF6="${off6# }"
OFF7="${off7# }"
ESTAVEL="300"
PADRAO="$padrao"
EOF
    . "$CONF"
    menu_grub || return 1
    local kv; kv=$(atualiza_entradas 2>&1) || { ruim "$kv"; return 1; }
    ok "entradas criadas a partir do kernel $kv"
    fixa_padrao_grub && ok "padrao gravado do GRUB: $E6"
    cat > "/etc/systemd/system/$UNIT" <<EOF
[Unit]
Description=BC-250 nucleos escolhidos no menu do GRUB (bc250-grub.sh)
After=local-fs.target
Before=bc250-smu-oc.service bc250-cpu-escada.service cyan-skillfish-governor-smu.service oberon-governor.service bc250-cu-live-manager.service bc250-memory-setup.service bc250-fan-control.service display-manager.service
RequiresMountsFor=/boot /var/lib

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=$LIB/bc250-grub.sh _boot
ExecStop=$LIB/bc250-grub.sh _confirma
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
    mkdir -p "$(dirname "$HOOK")"
    printf '#!/bin/bash\n# bc250-grub.sh: recria as entradas BC-250 do GRUB quando um kernel e instalado/removido\n[ -x %s ] && %s _kernel "$@" >/dev/null 2>&1\nexit 0\n' "$LIB/bc250-grub.sh" "$LIB/bc250-grub.sh" > "$HOOK"
    chmod 0755 "$HOOK"
    systemctl daemon-reload; systemctl enable "$UNIT" >/dev/null 2>&1
    reboot_frio
    log "instalado: mascara $m, nucleos $NUCLEOS, APIC $ap7, SSDT=${acpi:+sim}"
    echo; ok "${B}Instalado.${N0} Padrao: $PADRAO nucleos."
    echo "  Para usar $((ALVO / 2)) nucleos: reinicie e escolha 'BC-250: $((ALVO / 2)) nucleos (destrave)' no menu do GRUB."
    echo "  Depois de validar, para o GRUB ir sozinho para 7: sudo bc250-grub.sh padrao 7"
}

padrao() {
    [ -f "$CONF" ] || { ruim "nao instalado"; return 1; }
    . "$CONF"
    case "${1:-}" in
        6) cset PADRAO 6; desarma; fixa_padrao_grub; log "padrao 6"; ok "o GRUB vai sozinho para $((BASE / 2)) nucleos";;
        7) cset PADRAO 7; PADRAO=7
           [ "$(estado)" = destravando ] || arma
           rm -f "$EST/ultima-falha"; log "padrao 7"
           ok "o GRUB vai sozinho para $((ALVO / 2)) nucleos (rearmado a cada boot que ficar ${ESTAVEL}s de pe ou desligar limpo)"
           echo "  Se um boot de $((ALVO / 2)) nucleos travar, o proximo cai sozinho em $((BASE / 2)) e o padrao volta para 6.";;
        *) echo "uso: sudo bc250-grub.sh padrao 6|7"; return 1;;
    esac
}

status() {
    echo "${B}BC-250: nucleos pelo GRUB${N0}"
    [ -f "$CONF" ] || { aviso "nao instalado (sudo ./bc250-grub.sh instalar)"; return; }
    . "$CONF"
    local modo; modo=$(cmd_param bc250.modo)
    echo "  Agora: $(threads) threads (APIC $(apics)) | mascara $(mascara) | entrada: $(cmd_param bc250.entrada)${modo:+ (modo $modo)}"
    [ -z "$modo" ] && echo "         (entrada original do Nobara)"
    echo "  Padrao: ${B}$PADRAO nucleos${N0} | estado do ciclo: $(estado || true) | servico: $(systemctl is-enabled $UNIT 2>/dev/null)"
    echo "  GRUB: $(grub2-editenv list | grep -E '^(saved_entry|next_entry)=' | tr '\n' ' ')"
    local e; for e in "$E6" "$E7" "$E7S"; do [ -f "$ENTRIES/$e.conf" ] && echo "    $(sed -n 's/^title //p' "$ENTRIES/$e.conf")  [$(sed -n 's|^linux[[:space:]]\+.*/vmlinuz-||p' "$ENTRIES/$e.conf")]" || aviso "entrada $e ausente"; done
    [ -f "$EST/ultima-falha" ] && aviso "ultima falha: $(cat "$EST/ultima-falha")"
    echo "  Boots:"; tail -n 8 "$EST/boot.log" 2>/dev/null | sed 's/^/    /'
}

desfazer() {
    echo "${B}Desfazer${N0}: remove o servico, o hook do kernel, as entradas BC-250 do GRUB e os cpio de /boot."
    pergunta "Desfazer?" || return 1
    systemctl disable "$UNIT" >/dev/null 2>&1; rm -f "/etc/systemd/system/$UNIT" "$HOOK" /usr/local/sbin/bc250-grub.sh
    systemctl daemon-reload
    grub2-editenv - unset next_entry
    remove_entradas; rm -f "$CONF" "$EST/tentativa"
    local base; base=$(entrada_base); [ -n "$base" ] && grub2-set-default "$(basename "$base" .conf)"
    if [ -f "$EST/grub.default.orig" ] && ! pergunta "Manter o menu do GRUB visivel (recomendado)?"; then
        cp -p "$EST/grub.default.orig" "$GRUBDEF"; grub2-mkconfig -o "$GRUBCFG" >/dev/null 2>&1 && ok "menu do GRUB como era antes"
    fi
    reboot_frio; log "desfeito"
    ok "Desfeito. Se estiver com $(grep -c '^processor' /proc/cpuinfo) threads acima do normal, reinicie (o reboot ja esta ajustado para frio)."
}

[ "${BASH_SOURCE[0]}" = "$0" ] || return 0     # "source" para testes: so as funcoes
[ "$(id -u)" -eq 0 ] || exec sudo NUCLEOS="$NUCLEOS" "$0" "$@"
mkdir -p "$EST"
case "${1:-}" in
    _boot) _boot;;
    _confirma) _confirma;;
    _kernel) shift; _kernel "$@";;
    instalar) instalar;;
    padrao) padrao "${2:-}";;
    status|"") status;;
    desfazer) desfazer;;
    *) echo "uso: sudo $0 instalar | padrao 6|7 | status | desfazer"; exit 1;;
esac
