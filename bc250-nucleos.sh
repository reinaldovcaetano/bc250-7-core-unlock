#!/bin/bash
# =====================================================================================
#  bc250-nucleos.sh - libera, TESTA e (se voce mandar) instala os nucleos ocultos da AMD BC-250
#
#  >>> SO FUNCIONA EM FEDORA E NOBARA (GRUB com BLS, /boot/loader/entries, nao imutavel). <<<
#  Ubuntu/Debian/Mint/Arch (GRUB classico), CachyOS/Pop (systemd-boot), Bazzite/Silverblue/
#  SteamOS (imutaveis): NAO suportados. A etapa 1 confere e para sem mexer em nada.
#
#  Menu interativo com etapas numeradas, sempre NA ORDEM (nao da para pular):
#    1. Diagnostico (so leitura): placa, distro, kernel, quais nucleos estao ocultos
#    2. Desligar o OC da CPU e da GPU (obrigatorio antes de ativar qualquer nucleo)
#    3. Testar os nucleos ocultos, um teste por vez (cada um em um boot proprio)
#    4. Resultado: quais nucleos sao bons
#    5. Instalar como padrao (so com sua confirmacao)
#    6. Religar o OC
#  O estado fica gravado em /var/lib/bc250-nucleos/estado.env (sobrevive a reboot e travamento).
#  Historico: /var/lib/bc250-nucleos/historico.log    Logs de teste: /var/lib/bc250-nucleos/teste-*.log
#
#  Como funciona: a SMU tem uma mascara de nucleos (SMN 0x5A870, ex. 0x77 = nucleos 3 e 7 ocultos).
#  A SMU so sabe gravar 0xFF (liga TODOS os ocultos) e isso so vale depois de um reset QUENTE.
#  Para ligar so alguns, o boot de teste carrega uma tabela de CPUs (MADT) que lista so os nucleos
#  desejados; os outros ficam parados. Um reboot normal (frio) volta tudo ao padrao de fabrica.
#
#  Simulacao (nao mexe em nada, estado em /tmp): BC250N_SIMULAR=1 ./bc250-nucleos.sh
#    variaveis da simulacao: BC250N_N (threads), BC250N_MASK, BC250N_BOOT (boot id), BC250N_CMDLINE
# =====================================================================================
set -u
VERSAO="1.0 (2026-10-04)"
SIM=${BC250N_SIMULAR:-0}
AQUI=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
if [ "$SIM" = 1 ]; then
    R=${BC250N_SIMDIR:-/tmp/bc250-nucleos-sim}
    mkdir -p "$R/boot/loader/entries" "$R/etc" "$R/lib"
else
    R=""
    [ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
fi
LIB=$R/usr/local/lib/bc250-nucleos           # copia instalada do script + acpi (usada pelos servicos)
EST=$R/var/lib/bc250-nucleos                 # estado
EF=$EST/estado.env
CONF=$R/etc/bc250-nucleos.conf               # configuracao do padrao (etapa 5)
ENTRIES=$R/boot/loader/entries
ENT_T=bc250-nucleos-teste                    # entrada do GRUB de teste (vale 1 boot)
ENT_P=bc250-nucleos                          # entrada do GRUB do padrao (etapa 5)
UNIT_T=bc250-nucleos-teste.service
UNIT_P=bc250-nucleos-boot.service
UNITDIR=$R/etc/systemd/system
# servicos de OC/clock de CPU e GPU (BC250 Control Center e governors) - desligados nos testes
SERV_OC="bc250-smu-oc bc250-cpu-escada cyan-skillfish-governor-smu oberon-governor bc250-cu-live-manager"
SERV_GPU_GOV="cyan-skillfish-governor-smu oberon-governor"   # precisam estar parados para falar com a SMU
mkdir -p "$EST"

# ---------- utilidades ----------
B=$'\e[1m'; VM=$'\e[31m'; VD=$'\e[32m'; AM=$'\e[33m'; AZ=$'\e[36m'; N0=$'\e[0m'
[ -t 1 ] || { B=; VM=; VD=; AM=; AZ=; N0=; }
eget() { sed -n "s/^$1=//p" "$EF" 2>/dev/null | tail -1; }
eset() { touch "$EF"; sed -i "/^$1=/d" "$EF"; echo "$1=$2" >> "$EF"; }
log()  { echo "$(date '+%F %T') $*" >> "$EST/historico.log"; }
faz()  { if [ "$SIM" = 1 ]; then echo "    ${AZ}[simulacao]${N0} $*"; else "$@"; fi; }
fazsh() { if [ "$SIM" = 1 ]; then echo "    ${AZ}[simulacao]${N0} $1"; else bash -c "$1"; fi; }
ok()   { echo "  ${VD}OK${N0}  $*"; }
ruim() { echo "  ${VM}ERRO${N0} $*"; }
aviso() { echo "  ${AM}!!${N0}  $*"; }
pergunta() { local r; read -rp "$1 [s/N] " r; [[ "$r" =~ ^[sS]$ ]]; }
pausa() { [ -t 0 ] && read -rp "Enter para voltar ao menu..." _; }
etapa() { local e; e=$(eget ETAPA); echo "${e:-0}"; }

# threads ONLINE (nao "nproc --all": a MADT nova declara mais CPUs do que o hardware tem antes do reset quente)
threads() { [ "$SIM" = 1 ] && echo "${BC250N_N:-12}" || grep -c '^processor' /proc/cpuinfo; }
bootid()  { [ "$SIM" = 1 ] && echo "${BC250N_BOOT:-boot-1}" || cat /proc/sys/kernel/random/boot_id; }
cmdline() { [ "$SIM" = 1 ] && echo "${BC250N_CMDLINE:-quiet splash}" || cat /proc/cmdline; }
mascara() { [ "$SIM" = 1 ] && echo "${BC250N_MASK:-0x77}" || python3 "$LIB/smu.py" ler; }
apics()   {   # APIC IDs ativos agora
    if [ "$SIM" = 1 ] && [ -n "${BC250N_APICS:-}" ]; then echo "$BC250N_APICS"
    elif [ "$SIM" = 1 ]; then python3 -c "import sys;m=int(sys.argv[1],16);print(' '.join(str(a) for c in range(8) if m>>c&1 for a in (2*c,2*c+1)))" "$(mascara)"
    else awk '/^apicid/{print $3}' /proc/cpuinfo | sort -n | tr '\n' ' ' | sed 's/ $//'; fi; }
svc_existe() { [ "$SIM" = 1 ] && { [[ " ${BC250N_SERVICOS-bc250-smu-oc cyan-skillfish-governor-smu bc250-cu-live-manager} " == *" $1 "* ]]; return; }; systemctl cat "$1.service" >/dev/null 2>&1; }
svc_hab()    { [ "$SIM" = 1 ] && { local h; grep -q '^SIM_HAB=' "$EF" 2>/dev/null && h=$(eget SIM_HAB) || h=${BC250N_HAB-bc250-smu-oc cyan-skillfish-governor-smu bc250-cu-live-manager}; [[ " $h " == *" $1 "* ]]; return; }; [ "$(systemctl is-enabled "$1" 2>/dev/null)" = enabled ]; }
svc_ativo()  { [ "$SIM" = 1 ] && { svc_hab "$1"; return; }; systemctl is-active -q "$1"; }
cmd_param() { cmdline | tr ' ' '\n' | sed -n "s/^$1=//p" | tail -1; }
reboot_frio()   { fazsh "echo acpi > /sys/kernel/reboot/type; echo cold > /sys/kernel/reboot/mode"; }
reboot_quente() { fazsh "echo efi > /sys/kernel/reboot/type; echo warm > /sys/kernel/reboot/mode"; }
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

# apics esperados = nucleos da mascara de fabrica + nucleos extras ("3 7")
apics_de() { python3 -c "import sys;m=int(sys.argv[1],16);x=[int(c) for c in sys.argv[2].split()];print(' '.join(str(a) for c in range(8) if (m>>c&1 or c in x) for a in (2*c,2*c+1)))" "$1" "${2:-}"; }
nome_var() { [ "$1" = todos ] && echo "todos os ocultos ($(eget OCULTOS))" || echo "so o nucleo $1"; }
nucleos_var() { [ "$1" = todos ] && eget OCULTOS || echo "$1"; }

# ---------- arquivos auxiliares (Python), gravados na etapa 1 ----------
grava_aux() {
mkdir -p "$LIB"
cat > "$LIB/smu.py" <<'PY'
# SMU da BC-250: le a mascara de nucleos (SMN 0x5A870) ou grava 0xFF (msg 0x98, fila Q3).
# Uso: smu.py ler | smu.py gravar <mascara_de_fabrica_esperada, ex 0x77>
import os, struct, sys, time
MASK = 0x5A870
Q3_CMD, Q3_RSP, Q3_ARG = 0x03B10A20, 0x03B10A80, 0x03B10A88
DONE = {0x01, 0xFF, 0xFE, 0xFD, 0xFC}
fd = os.open("/sys/bus/pci/devices/0000:00:00.0/config", os.O_RDWR)
def rd(r):
    os.pwrite(fd, struct.pack("<I", r), 0xB8)
    return struct.unpack("<I", os.pread(fd, 4, 0xBC))[0]
def wr(r, v):
    os.pwrite(fd, struct.pack("<I", r), 0xB8)
    os.pwrite(fd, struct.pack("<I", v), 0xBC)
def wait(budget=5.0):
    end = time.monotonic() + budget
    while time.monotonic() < end:
        s = rd(Q3_RSP)
        if s in DONE:
            return s
        time.sleep(0.002)
    return None
try:
    m = rd(MASK) & 0xFF
    if sys.argv[1] == "ler":
        print("0x%02X" % m); sys.exit(0)
    esperada = int(sys.argv[2], 16)
    if m == 0xFF:
        print("mascara ja esta 0xFF"); sys.exit(0)
    if m != esperada:
        sys.exit("mascara 0x%02X diferente da gravada no diagnostico (0x%02X) - abortando" % (m, esperada))
    if wait() is None:
        sys.exit("SMU ocupada antes do envio - nada foi gravado")
    wr(Q3_RSP, 0); wr(Q3_ARG, MASK); wr(Q3_ARG + 4, 0); wr(Q3_CMD, 0x98)
    s = wait()
    if s is None:
        sys.exit("SMU nao respondeu - NAO repita; desligue a placa totalmente")
    if s != 0x01:
        sys.exit("SMU respondeu 0x%02X - comando recusado" % s)
    time.sleep(0.2)
    m = rd(MASK) & 0xFF
    print("mascara depois da gravacao: 0x%02X" % m)
    sys.exit(0 if m == 0xFF else "mascara nao mudou")
finally:
    os.close(fd)
PY
cat > "$LIB/madt.py" <<'PY'
# MADT (tabela de CPUs) da BC-250.
#   madt.py verificar <MADT original> <mascara>      confere se o layout e o conhecido (UID = APIC+1, sem x2APIC)
#   madt.py gerar <MADT original> "<apics ligados>" <saida.cpio> [pasta com SSDT .aml]
# A MADT gerada tem as 16 entradas da placa (UID 1..16 = APIC 0..15); so os APIC pedidos ficam
# habilitados. O kernel nunca acorda os outros. Vai num initrd "early" (kernel/firmware/acpi/).
import struct, sys, os, subprocess, tempfile, shutil, glob
def ler(p):
    d = open(p, "rb").read()
    if d[:4] != b"APIC": sys.exit("%s nao e uma MADT" % p)
    ents, o = [], 44
    while o < len(d):
        l = d[o + 1]
        if l < 2: sys.exit("MADT corrompida")
        ents.append(bytes(d[o:o + l])); o += l
    return d, ents
acao, orig = sys.argv[1], sys.argv[2]
d, ents = ler(orig)
if acao == "verificar":
    m = int(sys.argv[3], 16)
    esperado = [a for c in range(8) if m >> c & 1 for a in (2 * c, 2 * c + 1)]
    if any(e[0] == 9 for e in ents): sys.exit("MADT tem entradas x2APIC - layout desconhecido")
    lap = [e for e in ents if e[0] == 0]
    ativos = [e for e in lap if struct.unpack("<I", e[4:8])[0] & 1]
    ap = sorted(e[3] for e in ativos)
    if ap != esperado: sys.exit("APICs ativos %r nao batem com a mascara (esperado %r)" % (ap, esperado))
    ruins = [(e[2], e[3]) for e in ativos if e[2] != e[3] + 1]
    # a BIOS P3.00 numera os UID em sequencia so nos nucleos ativos (APIC 8 = UID 7); a MADT gerada usa
    # UID = APIC+1, que bate com as P000..P00F das SSDT (P00x = APIC x). Qualquer outro layout e recusado.
    seq = [e[2] for e in sorted(ativos, key=lambda e: e[3])] == list(range(1, len(ativos) + 1))
    if ruins and not seq: sys.exit("UID != APIC+1 em %r - layout desconhecido" % ruins)
    if ruins: print("UIDs em sequencia (layout da BIOS); a MADT nova usa UID = APIC+1, como as SSDT P00x")
    print("MADT ok: %d entradas LAPIC, ativos %s" % (len(lap), ap)); sys.exit(0)
lig = {int(x) for x in sys.argv[3].split()}
out = sys.argv[4]
acpi = sys.argv[5] if len(sys.argv) > 5 else ""
hdr = bytearray(d[:44])
outros = [e for e in ents if e[0] != 0]
novos = [struct.pack("<BBBBI", 0, 8, a + 1, a, 1 if a in lig else 0) for a in range(16)]
corpo = b"".join(novos + outros)
struct.pack_into("<I", hdr, 4, 44 + len(corpo))
struct.pack_into("<I", hdr, 24, struct.unpack("<I", hdr[24:28])[0] + 1)   # OEM revision +1 (override)
t = bytearray(hdr + corpo); t[9] = 0; t[9] = (-sum(t)) & 0xFF
tmp = tempfile.mkdtemp()
try:
    os.makedirs(tmp + "/kernel/firmware/acpi")
    open(tmp + "/kernel/firmware/acpi/apic.aml", "wb").write(t)
    if acpi:
        for f in sorted(glob.glob(acpi + "/*.aml")): shutil.copy(f, tmp + "/kernel/firmware/acpi/")
    subprocess.run("find kernel | cpio -H newc --create --quiet > '%s'" % out, shell=True, cwd=tmp, check=True)
finally:
    shutil.rmtree(tmp)
print("cpio %s: APICs ligados %s%s" % (out, sorted(lig), " + SSDT" if acpi else ""))
PY
}

# cria a entrada do GRUB <nome> = copia da entrada padrao + initrd extra (+ opcoes extras)
cria_entrada() {   # nome titulo cpio_em_/boot "opcoes extras"
    local nome=$1 tit=$2 cpio=$3 extra=$4 saved base
    saved=$([ "$SIM" = 1 ] && echo sim-padrao || grub2-editenv list | sed -n 's/^saved_entry=//p')
    base=$ENTRIES/$saved.conf
    [ -n "$saved" ] && [ -f "$base" ] || base=$ENTRIES/$(cat /etc/machine-id)-$(uname -r).conf
    if [ "$SIM" = 1 ] && [ ! -f "$base" ]; then
        printf 'title Fedora (sim)\nversion 1\nlinux /vmlinuz-sim\ninitrd /initramfs-sim.img\noptions root=UUID=x ro quiet splash\n' > "$base"
    fi
    [ -f "$base" ] || { ruim "entrada base do GRUB nao encontrada"; return 1; }
    sed -e "s/^title .*/title $tit/" -e "s|^initrd |initrd /$cpio\ninitrd |" \
        -e "s|^options .*|& $extra|" "$base" > "$ENTRIES/$nome.conf.tmp"
    grep -q "^initrd /$cpio\$" "$ENTRIES/$nome.conf.tmp" || { rm -f "$ENTRIES/$nome.conf.tmp"; ruim "falha ao gerar a entrada"; return 1; }
    mv "$ENTRIES/$nome.conf.tmp" "$ENTRIES/$nome.conf"
}
limpa_teste() {
    rm -f "$ENTRIES/$ENT_T.conf" "$R/boot/$ENT_T.cpio"
    [ "$SIM" = 1 ] || grub2-editenv - unset next_entry
}
param_ssdt() { [ "$(eget SSDT)" = sim ] && echo "$LIB/acpi" || echo ""; }

# ---------- cabecalho e status ----------
cabecalho() {
    echo "${B}================ BC-250: nucleos ocultos  v$VERSAO ================${N0}"
    echo "  ${AM}So Fedora e Nobara (GRUB com BLS). Outras distros nao sao suportadas.${N0}"
    [ "$SIM" = 1 ] && echo "  ${AZ}MODO SIMULACAO: nada e alterado na placa (estado em $EST)${N0}"
}
mostra_estado() {
    local e oc
    e=$(etapa)
    local mm='?' bt; { [ "$SIM" = 1 ] || [ -f "$LIB/smu.py" ]; } && mm=$(mascara)
    bt=$(cmd_param bc250.nucleos); bt=${bt:+de teste ($(nome_var "$bt"))}
    echo "  Agora: $(threads) threads | mascara $mm | boot ${bt:-normal}"
    [ "$e" -ge 1 ] || return 0
    echo "  Mascara de fabrica: $(eget MASCARA)  ->  nucleos ocultos: ${B}$(eget OCULTOS)${N0}   (base $(eget BASE) threads)"
    for v in $(eget OCULTOS) todos; do
        local r; r=$(eget "TESTE_$v")
        [ -z "$r" ] && [ "$v" = todos ] && continue
        echo "    teste $(printf '%-28s' "$(nome_var "$v")"): ${r:-pendente} $(eget "INFO_$v")"
    done
    [ -n "$(eget FINAL)" ] && echo "  Resultado: ${B}$(eget FINAL_TXT)${N0}"
    oc=$(eget OC_HAB); echo "  OC desligado nas etapas: ${oc:-nenhum servico estava habilitado}"
}

# dependencias (pacotes do Fedora/Nobara): programa -> pacote
instala_deps() {
    local falta="" prog pac c
    for c in python3:python3 cpio:cpio stress-ng:stress-ng grub2-reboot:grub2-tools grub2-editenv:grub2-tools-minimal; do
        prog=${c%%:*}; pac=${c#*:}
        if [ "$SIM" != 1 ] && command -v "$prog" >/dev/null; then continue; fi
        [ "$SIM" = 1 ] && [ -z "${BC250N_FALTA:-}" ] && continue
        [ "$SIM" = 1 ] && [[ " $BC250N_FALTA " != *" $prog "* ]] && continue
        [[ " $falta " == *" $pac "* ]] || falta="$falta $pac"
    done
    falta=${falta# }
    [ -z "$falta" ] && { ok "dependencias: python3, cpio, stress-ng, grub2-tools instalados"; return 0; }
    aviso "faltam pacotes: $falta"
    command -v dnf >/dev/null || [ "$SIM" = 1 ] || { ruim "dnf nao encontrado"; return 1; }
    if pergunta "  Instalar agora com dnf (precisa de internet)?"; then
        faz dnf install -y $falta || { ruim "dnf falhou"; return 1; }
        [ "$SIM" = 1 ] || for c in python3 cpio stress-ng grub2-reboot grub2-editenv; do command -v $c >/dev/null || { ruim "$c continua faltando"; return 1; }; done
        ok "pacotes instalados: $falta"; log "dependencias instaladas: $falta"
    else
        ruim "sem as dependencias nao da para continuar"; return 1
    fi
}

# ---------- etapa 1: diagnostico ----------
etapa1() {
    local falha=0 m nb ocultos base
    echo; echo "${B}1. Diagnostico (so leitura)${N0}"
    if [ "$(etapa)" -ge 1 ]; then
        ok "ja feito: mascara $(eget MASCARA), nucleos ocultos $(eget OCULTOS). Para recomecar do zero: opcao 9."; return
    fi
    # distro
    . /etc/os-release
    if [[ "$ID" == fedora || "$ID" == nobara || " ${ID_LIKE:-} " == *" fedora "* ]]; then ok "distro: $NAME"
    else ruim "distro $NAME nao suportada (so Fedora/Nobara)"; falha=1; fi
    [ -e /run/ostree-booted ] && { ruim "sistema imutavel (ostree: Bazzite/Silverblue/Kinoite) - nao suportado"; falha=1; }
    if [ "$SIM" = 1 ] || { [ -d /boot/loader/entries ] && grep -qE "^GRUB_ENABLE_BLSCFG=['\"]?true" /etc/default/grub 2>/dev/null \
         && command -v grub2-reboot >/dev/null && command -v grub2-editenv >/dev/null; }; then ok "boot: GRUB com BLS (grub2-reboot disponivel)"
    else ruim "boot nao e GRUB com BLS (/boot/loader/entries + grub2-reboot) - nao suportado"; falha=1; fi
    [ "$SIM" = 1 ] || [ -d /sys/firmware/efi ] || { ruim "placa nao bootou em modo EFI"; falha=1; }
    if [ "$SIM" = 1 ] || grep -q '^CONFIG_ACPI_TABLE_UPGRADE=y' "/boot/config-$(uname -r)" 2>/dev/null; then ok "kernel $(uname -r) com CONFIG_ACPI_TABLE_UPGRADE"
    else ruim "kernel sem CONFIG_ACPI_TABLE_UPGRADE (nao da para esconder um nucleo ruim)"; falha=1; fi
    # placa
    local placa; placa=$(cat /sys/class/dmi/id/board_name 2>/dev/null)
    if [ "$SIM" = 1 ] || [[ "$placa" == *BC-250* ]] || grep -q 'AMD BC-250' /proc/cpuinfo; then ok "placa: ${placa:-BC-250} | BIOS $(cat /sys/class/dmi/id/bios_version 2>/dev/null) $(cat /sys/class/dmi/id/bios_date 2>/dev/null)"
    else ruim "isto nao e uma AMD BC-250"; falha=1; fi
    [ "$falha" = 0 ] && { instala_deps || falha=1; }
    for u in bc250-7cores "$UNIT_P"; do
        { [ -e "$UNITDIR/${u%.service}.service" ] || [ -e "$UNITDIR/$u" ]; } && { ruim "ja existe um desbloqueio instalado ($u) - desinstale antes"; falha=1; }
    done
    [ "$falha" = 0 ] || { ruim "${B}Diagnostico reprovado. Nada foi alterado.${N0}"; return; }
    grava_aux
    m=$(mascara) || { ruim "nao consegui ler a mascara pela SMU"; return; }
    nb=$(python3 -c "print(bin(int('$m',16)).count('1'))")
    base=$(threads)
    if [ "$m" = 0xFF ]; then ruim "mascara ja esta 0xFF (desbloqueio ativo neste boot). Desligue a placa totalmente (tirar da tomada ~10 s) e rode de novo."; return; fi
    [ "$base" = $((nb * 2)) ] || { ruim "mascara $m indica $((nb*2)) threads, mas ha $base online - estado estranho, faca um boot frio"; return; }
    ocultos=$(python3 -c "m=int('$m',16);print(' '.join(str(c) for c in range(8) if not m>>c&1))")
    [ -n "$ocultos" ] || { ok "nenhum nucleo oculto (mascara $m). Nada a fazer."; return; }
    # MADT original (de fabrica) - copia guardada para gerar as tabelas dos testes
    if [ "$SIM" = 1 ]; then
        python3 - "$EST/madt-original.aml" "$m" <<'PY'
import struct, sys
m = int(sys.argv[2], 16)
ents = b"".join(struct.pack("<BBBBI", 0, 8, a + 1, a, 1 if m >> (a // 2) & 1 else 0) for a in range(16))
ents += bytes([1, 12, 0x21, 0]) + struct.pack("<II", 0xFEC00000, 0)
h = bytearray(b"APIC" + struct.pack("<I", 44 + len(ents)) + bytes([5, 0]) + b"ALASKA" + b"A M I \x00\x00" + struct.pack("<I", 0x1072009) + b"AMI " + struct.pack("<I", 0x10013) + struct.pack("<II", 0xFEE00000, 1))
t = bytearray(h + ents); t[9] = (-sum(t)) & 0xFF; open(sys.argv[1], "wb").write(t)
PY
    else
        cp /sys/firmware/acpi/tables/APIC "$EST/madt-original.aml"
    fi
    local vm; vm=$(python3 "$LIB/madt.py" verificar "$EST/madt-original.aml" "$m" 2>&1) \
        || { ruim "$vm"; ruim "${B}layout da tabela de CPUs (MADT) desconhecido - nao e seguro continuar. Nada foi alterado.${N0}"; return; }
    ok "$vm"
    # SSDT do e-tho (P-states/C-states): so com a BIOS P3.00 e a SSDT "AMD CPU" de fabrica
    local ssdt=nao bios; bios=$(cat /sys/class/dmi/id/bios_version 2>/dev/null)
    if [ "$SIM" = 1 ] || { [ "$bios" = P3.00 ] && grep -l 'AMD CPU' /sys/firmware/acpi/tables/SSDT* >/dev/null 2>&1; }; then
        ssdt=sim; ok "BIOS P3.00: as tabelas de P-states/C-states (e-tho/bc250-acpi-fix) vao junto (clock da CPU de 800 a 3200 MHz no Linux)"
    else aviso "BIOS $bios diferente da P3.00: sem as tabelas de P-states (so a tabela de nucleos)"; fi
    mkdir -p "$LIB/acpi"; [ "$SIM" = 1 ] || { cp "$AQUI"/acpi/*.aml "$LIB/acpi/" 2>/dev/null; install -m 0755 "$(readlink -f "$0")" "$LIB/bc250-nucleos.sh"; }
    [ "$SIM" = 1 ] && cp "$AQUI"/acpi/*.aml "$LIB/acpi/" 2>/dev/null
    eset MASCARA "$m"; eset OCULTOS "$ocultos"; eset BASE "$base"; eset SSDT "$ssdt"; eset BIOS "$bios"
    for v in $ocultos; do [ -n "$(eget "TESTE_$v")" ] || eset "TESTE_$v" pendente; done
    eset ETAPA 1; log "etapa 1: mascara $m, ocultos: $ocultos, base $base threads, SSDT=$ssdt"
    echo
    ok "${B}Mascara $m: nucleos ocultos = $ocultos${N0} (cada nucleo = 2 threads; APIC $(for c in $ocultos; do printf '%s/%s ' $((2*c)) $((2*c+1)); done))"
    echo "  Proximo: etapa 2 (desligar o OC da CPU e da GPU)."
}

# ---------- etapa 2: desligar OC ----------
etapa2() {
    echo; echo "${B}2. Desligar o OC da CPU e da GPU para os testes${N0}"
    [ "$(etapa)" -ge 1 ] || { aviso "Faca a etapa 1 antes."; return; }
    if [ "$(etapa)" -ge 2 ]; then
        ok "ja feito. Servicos desligados: $(eget OC_HAB)"
        [ "$(eget OC_BOOT)" = "$(bootid)" ] && aviso "Ainda falta REINICIAR (normal) para tirar o OC que ja estava aplicado na SMU."
        return
    fi
    local hab="" s
    for s in $SERV_OC; do svc_existe "$s" || continue
        if svc_hab "$s"; then hab="$hab $s"; echo "    $s: habilitado no boot -> sera desligado"
        else echo "    $s: ja desligado"; fi
    done
    hab=${hab# }
    echo "  Os testes precisam rodar sem OC: com mais nucleos o OC calibrado para 6 nucleos fica instavel"
    echo "  (na placa original o OC antigo travou a imagem com 7 nucleos)."
    echo "  Os servicos acima sao DESABILITADOS (o script lembra quais eram e religa na etapa 6)."
    pergunta "Desligar agora?" || return
    for s in $hab; do faz systemctl disable --now "$s"; done
    [ "$SIM" = 1 ] && eset SIM_HAB ""
    eset OC_HAB "$hab"; eset OC_BOOT "$(bootid)"; eset ETAPA 2
    log "etapa 2: desligados: ${hab:-nenhum}"
    if [ -n "$hab" ]; then
        aviso "${B}Reinicie a placa normalmente (frio)${N0} antes da etapa 3: o OC ja aplicado na SMU so sai num reboot."
        pergunta "Reiniciar agora?" && { reboot_frio; faz systemctl reboot; }
    else ok "Nenhum OC estava ativo. Pode seguir para a etapa 3."; eset OC_BOOT nenhum; fi
}

oc_desligado() {   # trava: nao ativa nucleo com OC ligado
    local s ok2=0
    for s in $SERV_OC; do svc_existe "$s" || continue
        if svc_hab "$s" || svc_ativo "$s"; then ruim "$s esta ligado - rode a etapa 2 de novo (opcao 9 desfaz) ou desligue-o"; ok2=1; fi
    done
    if [ "$(eget OC_BOOT)" = "$(bootid)" ]; then ruim "o OC foi desligado NESTE boot e pode continuar aplicado na SMU: reinicie (normal) antes"; ok2=1; fi
    return $ok2
}

# proximo teste da fila (na ordem; nao pula)
proximo_teste() {
    local v n=0
    for v in $(eget OCULTOS); do case "$(eget "TESTE_$v")" in pendente|"") echo "$v"; return;; passou) n=$((n+1));; esac; done
    if [ "$n" -ge 2 ] && [ -z "$(eget TESTE_todos)" ]; then echo todos; return; fi
    echo ""
}

# ---------- etapa 3: testar ----------
etapa3() {
    echo; echo "${B}3. Testar os nucleos ocultos (um teste por boot)${N0}"
    [ "$(etapa)" -ge 2 ] || { aviso "Faca a etapa 2 (desligar o OC) antes."; return; }
    [ "$(etapa)" -ge 3 ] && { ok "todos os testes ja foram feitos (veja a etapa 4)."; return; }
    local emteste; emteste=$(cmd_param bc250.nucleos)
    # a) estamos no boot de teste
    if [ -n "$emteste" ]; then
        local r; r=$(eget "TESTE_$emteste")
        echo "  Este e o boot de teste de: ${B}$(nome_var "$emteste")${N0} - estado: $r"
        if [ "$r" = testando ]; then
            echo "  O teste roda sozinho em segundo plano. Andamento (Ctrl+C sai so da visualizacao):"
            tail -n 5 "$EST/teste-$emteste.log" 2>/dev/null; return
        fi
        echo "  Teste terminado. Para o proximo, reinicie normalmente (frio: volta ao padrao de fabrica)."
        pergunta "Reiniciar agora?" && { reboot_frio; faz systemctl reboot; }
        return
    fi
    local n; n=$(threads)
    # b) subiu com TODOS os nucleos na entrada normal (reset quente inesperado): perigoso
    if [ "$n" -gt "$(eget BASE)" ] && [ -z "$emteste" ]; then
        ruim "Subiu com $n threads na entrada NORMAL (mascara 0xFF depois de um reset quente)."
        local v; v=$(eget TESTANDO)
        [ -n "$v" ] && { eset "TESTE_$v" falhou; eset "INFO_$v" "(a entrada de teste nao carregou)"; eset TESTANDO ""; log "teste $v: falhou (subiu na entrada normal com $n threads)"; }
        for c in $(eget OCULTOS); do faz sh -c "echo 0 > /sys/devices/system/cpu/cpu$((2*c))/online; echo 0 > /sys/devices/system/cpu/cpu$((2*c+1))/online"; done
        reboot_frio; aviso "Nucleos ocultos desligados. Reinicie normalmente (frio) agora."
        pergunta "Reiniciar agora?" && faz systemctl reboot; return
    fi
    [ "$(mascara)" = "$(eget MASCARA)" ] || { ruim "mascara $(mascara) diferente da de fabrica ($(eget MASCARA)): desligue a placa totalmente e ligue de novo"; return; }
    # c) o teste anterior nao voltou com resultado = travou
    local ant; ant=$(eget TESTANDO)
    if [ -n "$ant" ]; then
        if [ "$(eget "TESTE_$ant")" = testando ]; then
            eset "TESTE_$ant" falhou; eset "INFO_$ant" "(travou ou desligou durante o boot/teste)"
            log "teste $ant: FALHOU (a placa voltou sem resultado: travou)"
            ruim "O teste de $(nome_var "$ant") nao terminou (travou/desligou): marcado como ${B}FALHOU${N0}."
        fi
        eset TESTANDO ""
    fi
    oc_desligado || return
    local v; v=$(proximo_teste)
    if [ -z "$v" ]; then eset ETAPA 3; ok "Todos os testes feitos. Siga para a etapa 4 (resultado)."; return; fi
    local extras ap min
    extras=$(nucleos_var "$v"); ap=$(apics_de "$(eget MASCARA)" "$extras")
    echo "  Proximo teste (fila fixa, nao da para pular): ${B}$(nome_var "$v")${N0}"
    echo "    - grava 0xFF na mascara pela SMU (liga todos os ocultos no hardware)"
    echo "    - cria uma entrada do GRUB que vale SO 1 boot, com a tabela de CPUs listando os APIC: $ap"
    echo "      ($(( $(echo $ap | wc -w) )) threads; os outros nucleos ocultos ficam parados)"
    echo "    - nesse boot o OC (CPU e GPU) fica mascarado e o teste roda SOZINHO em segundo plano"
    echo "    - reinicia a quente (precisa ser quente para a mascara valer)"
    echo "  Se travar: desligue e ligue. A placa volta ao normal e este teste fica marcado como FALHOU."
    read -rp "  Minutos de estresse [10]: " min; min=${min:-10}; [[ "$min" =~ ^[0-9]+$ ]] || min=10
    pergunta "Gravar a mascara e REINICIAR agora para testar $(nome_var "$v")?" || return
    local masc=""
    for s in $SERV_OC; do svc_existe "$s" && masc="$masc systemd.mask=$s.service"; done
    python3 "$LIB/madt.py" gerar "$EST/madt-original.aml" "$ap" "$R/boot/$ENT_T.cpio" $(param_ssdt) || { ruim "falha ao gerar a tabela"; return; }
    cria_entrada "$ENT_T" "BC-250 TESTE nucleos: $(nome_var "$v") (uma vez)" "$ENT_T.cpio" "bc250.nucleos=$v bc250.nucleos.min=$min$masc" || return
    instala_unit_teste
    for s in $SERV_GPU_GOV; do faz systemctl stop "$s" 2>/dev/null; done
    if [ "$SIM" != 1 ]; then
        local out; out=$(python3 "$LIB/smu.py" gravar "$(eget MASCARA)" 2>&1) || { ruim "SMU: $out"; limpa_teste; return; }
        ok "$out"
        grub2-reboot "$ENT_T" || { ruim "grub2-reboot falhou"; limpa_teste; reboot_frio; return; }
    else echo "    ${AZ}[simulacao]${N0} smu.py gravar $(eget MASCARA); grub2-reboot $ENT_T"; fi
    eset "TESTE_$v" testando; eset TESTANDO "$v"; eset "INFO_$v" ""
    log "teste $v: iniciado (APIC $ap, $min min)"
    reboot_quente; sync
    echo "  Reiniciando a quente... Depois do boot, abra este menu: a opcao 3 ou 8 mostra o andamento."
    faz systemctl reboot
}

instala_unit_teste() {
    local f=$UNITDIR/$UNIT_T
    [ "$SIM" = 1 ] && mkdir -p "$UNITDIR"
    cat > "$f" <<EOF
[Unit]
Description=BC-250 teste de nucleos (so roda no boot de teste: bc250.nucleos=)
ConditionKernelCommandLine=bc250.nucleos

[Service]
Type=simple
ExecStart=$LIB/bc250-nucleos.sh _teste

[Install]
WantedBy=multi-user.target
EOF
    faz systemctl daemon-reload; faz systemctl enable "$UNIT_T"
}

# ---------- roda no boot de teste (servico) ----------
_teste() {
    local v min logf ap esp n rc=0 motivo="" t tmax=0
    v=$(cmd_param bc250.nucleos); min=$(cmd_param bc250.nucleos.min); min=${min:-10}
    logf=$EST/teste-$v.log
    exec > >(tee "$logf") 2>&1
    echo "=== $(date) teste: $(nome_var "$v"), $min min"
    limpa_teste; reboot_frio
    [ "$(eget TESTANDO)" = "$v" ] || { echo "este teste nao estava agendado (TESTANDO=$(eget TESTANDO)) - nada feito"; exit 0; }
    fim() { eset "TESTE_$v" "$1"; eset "INFO_$v" "$2"; eset TESTANDO ""; log "teste $v: $1 $2"; echo "=== RESULTADO: $1 $2"; sync
            [ "$SIM" = 1 ] || wall "BC-250: teste de $(nome_var "$v"): $1 $2. Abra o bc250-nucleos.sh (etapa 3) para continuar." 2>/dev/null; exit 0; }
    esp=$(apics_de "$(eget MASCARA)" "$(nucleos_var "$v")"); ap=$(apics); n=$(threads)
    echo "APIC esperados: $esp"; echo "APIC ativos   : $ap"
    echo "ACPI: $(dmesg | grep -i 'table upgrade' | sed 's/.*Upgrade: //' | tr '\n' ';')"
    [ "$ap" = "$esp" ] || fim falhou "(os nucleos ativos nao sao os esperados: $ap)"
    echo "OC: $(for s in $SERV_OC; do svc_existe $s && printf '%s=%s ' $s "$(systemctl is-active $s)"; done)"
    local s2; for s2 in $SERV_OC; do
        if [ "$SIM" != 1 ] && svc_existe "$s2" && systemctl is-active -q "$s2"; then
            eset "TESTE_$v" pendente; eset "INFO_$v" "(teste anulado: $s2 estava ligado)"; eset TESTANDO ""
            log "teste $v: ANULADO - $s2 ligado no boot de teste (volta para pendente)"; echo "=== ANULADO: $s2 ligado"; exit 0
        fi
    done
    echo "aguardando 60 s o sistema assentar..."; [ "$SIM" = 1 ] || sleep 60
    local ERR='Oops|BUG:|Machine check|mce:|segfault|general protection|Hardware Error|soft lockup|hard LOCKUP|rcu.*stall'
    local d0; d0=$(dmesg | wc -l)
    local e0; e0=$(dmesg | grep -E "$ERR" | head -3)
    [ -n "$e0" ] && { echo "$e0"; fim falhou "(erros do kernel ja no boot: $(echo "$e0" | head -1 | cut -c1-80))"; }
    local tf; tf=$(grep -l k10temp /sys/class/hwmon/hwmon*/name 2>/dev/null | head -1 | sed 's/name$/temp1_input/')
    ( while :; do sleep 30; t=$(( $(cat "$tf" 2>/dev/null || echo 0) / 1000 )); echo "  ... vivo $(date +%T)  CPU ${t} C  clock max $(awk '/MHz/{print int($4)}' /proc/cpuinfo | sort -n | tail -1) MHz"; sync; done ) &
    local hb=$!
    echo "=== estresse em todas as $n threads por $min min"
    if command -v stress-ng >/dev/null; then
        local dur="${min}m"; [ "$SIM" = 1 ] && dur=5s
        stress-ng --cpu "$n" --cpu-method all --verify --metrics-brief -t "$dur"; rc=$?
    else
        python3 - "$min" <<'PY'
import hashlib, os, sys, time, zlib, random, multiprocessing as mp
def trabalho(cpu, fim, q):
    os.sched_setaffinity(0, {cpu})
    buf = bytes(random.Random(1234).getrandbits(8) for _ in range(1 << 20))
    rh = hashlib.sha256(buf).hexdigest(); rf = sum((i * 1.000001) ** 0.5 for i in range(200000))
    n = e = 0
    while time.time() < fim:
        if hashlib.sha256(buf).hexdigest() != rh: e += 1
        if zlib.decompress(zlib.compress(buf, 6)) != buf: e += 1
        if sum((i * 1.000001) ** 0.5 for i in range(200000)) != rf: e += 1
        n += 1
    q.put((cpu, n, e))
fim = time.time() + float(sys.argv[1]) * 60
ctx = mp.get_context("fork"); q = ctx.Queue()
ps = [ctx.Process(target=trabalho, args=(c, fim, q)) for c in sorted(os.sched_getaffinity(0))]
[p.start() for p in ps]; [p.join() for p in ps]
ruim = 0
while not q.empty():
    c, n, e = q.get(); print("    cpu%d: %d rodadas, %d erros" % (c, n, e)); ruim += e
sys.exit(1 if ruim else 0)
PY
        rc=$?
    fi
    kill $hb 2>/dev/null
    tmax=$(grep -o 'CPU [0-9]* C' "$logf" | awk '{print $2}' | sort -n | tail -1)
    motivo=$(dmesg | tail -n +"$((d0 + 1))" | grep -E "$ERR" | head -3)
    [ -n "$motivo" ] && { echo "$motivo"; fim falhou "(erro do kernel no estresse: $(echo "$motivo" | head -1 | cut -c1-80))"; }
    [ "$rc" -eq 0 ] || fim falhou "(o estresse achou erro de calculo, codigo $rc)"
    fim passou "($min min, $n threads, CPU max ${tmax:-?} C)"
}

# ---------- etapa 4: resultado ----------
etapa4() {
    echo; echo "${B}4. Resultado${N0}"
    [ "$(etapa)" -ge 3 ] || { aviso "Termine a etapa 3 (todos os testes) antes. Proximo teste: $(nome_var "$(proximo_teste)")"; return; }
    local bons="" v final txt
    for v in $(eget OCULTOS); do [ "$(eget "TESTE_$v")" = passou ] && bons="$bons $v"; done
    bons=${bons# }
    if [ "$(eget TESTE_todos)" = passou ]; then final=$(eget OCULTOS)
    elif [ -n "$bons" ]; then final=${bons%% *}
        [ "$(echo $bons | wc -w)" -gt 1 ] && aviso "Os nucleos $bons passaram sozinhos, mas JUNTOS falharam: fica so o $final."
    else final=nenhum; fi
    mostra_estado
    if [ "$final" = nenhum ]; then txt="nenhum nucleo oculto estavel: a placa fica como veio ($(eget BASE) threads)"
    else txt="liberar nucleo(s) $final -> $(( $(eget BASE) + 2 * $(echo $final | wc -w) )) threads"; fi
    eset FINAL "$final"; eset FINAL_TXT "$txt"; eset ETAPA 4; log "etapa 4: $txt"
    { echo "BC-250 nucleos - relatorio $(date '+%F %T')"; echo "mascara $(eget MASCARA), ocultos: $(eget OCULTOS)"
      for v in $(eget OCULTOS) todos; do [ -n "$(eget "TESTE_$v")" ] && echo "  $(nome_var "$v"): $(eget "TESTE_$v") $(eget "INFO_$v")"; done
      echo "resultado: $txt"; } > "$EST/relatorio.txt"
    echo; ok "${B}$txt${N0}  (relatorio em $EST/relatorio.txt)"
    [ "$final" = nenhum ] && echo "  Pule para a etapa 6 (religar o OC)." || echo "  Proximo: etapa 5 (instalar como padrao) - so se voce quiser."
}

# ---------- etapa 5: instalar ----------
etapa5() {
    echo; echo "${B}5. Instalar como padrao${N0}"
    [ "$(etapa)" -ge 4 ] || { aviso "Faca a etapa 4 antes."; return; }
    [ "$(eget FINAL)" = nenhum ] && { aviso "Nenhum nucleo passou: nada a instalar. Va para a etapa 6."; return; }
    [ "$(etapa)" -ge 5 ] && { ok "ja instalado ($(eget FINAL_TXT)). Historico de boots: $EST/boot.log"; return; }
    local final alvo ap off16="" c todos_ocultos
    final=$(eget FINAL); ap=$(apics_de "$(eget MASCARA)" "$final"); alvo=$(echo $ap | wc -w)
    for c in $(eget OCULTOS); do [[ " $final " == *" $c "* ]] || off16="$off16 $((2*c)) $((2*c+1))"; done
    echo "  Vai instalar o servico $UNIT_P. Em todo boot frio (a mascara volta ao padrao de fabrica):"
    echo "    boot 1 (entrada normal, $(eget BASE) threads): grava 0xFF e reinicia a quente sozinho na entrada '$ENT_P'"
    echo "    boot 2 (entrada '$ENT_P', $alvo threads, APIC $ap): segue normal"
    echo "  Ou seja, todo ligar/reiniciar vira dois boots seguidos (o 2o e automatico)."
    echo "  Protecoes: a entrada normal do GRUB nao muda; se o boot 2 nao chegar a $alvo threads, para de tentar"
    echo "  (rm $EST/falhou para tentar de novo); desligar 1 boot: 'bc250.nucleos.nao' na linha do kernel"
    echo "  (tecla e no GRUB); desligar de vez: touch /etc/bc250-nucleos.desligado; desfazer: opcao 9."
    [ -n "$off16" ] && echo "  Se a entrada normal subir com todos os nucleos (reset quente inesperado), os APIC$off16 sao desligados na hora."
    pergunta "Instalar agora?" || return
    python3 "$LIB/madt.py" gerar "$EST/madt-original.aml" "$ap" "$LIB/final.cpio" $(param_ssdt) || { ruim "falha ao gerar a tabela"; return; }
    printf 'MASCARA=%s\nBASE=%s\nALVO=%s\nOFF16="%s"\n' "$(eget MASCARA)" "$(eget BASE)" "$alvo" "${off16# }" > "$CONF"
    cat > "$UNITDIR/$UNIT_P" <<EOF
[Unit]
Description=BC-250 nucleos extras por padrao (bc250-nucleos.sh)
After=local-fs.target
Before=bc250-smu-oc.service bc250-cpu-escada.service cyan-skillfish-governor-smu.service oberon-governor.service bc250-cu-live-manager.service bc250-memory-setup.service bc250-fan-control.service display-manager.service
RequiresMountsFor=/boot /var/lib

[Service]
Type=oneshot
ExecStart=$LIB/bc250-nucleos.sh _boot
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF
    faz systemctl disable "$UNIT_T"; rm -f "$UNITDIR/$UNIT_T"
    faz systemctl daemon-reload; faz systemctl enable "$UNIT_P"
    eset ETAPA 5; log "etapa 5: instalado ($(eget FINAL_TXT))"
    ok "Instalado. Validacao: reinicie normalmente; a placa deve reiniciar sozinha uma vez e voltar com $alvo threads."
    echo "  Depois do boot: opcao 8 (status) mostra o historico. Em seguida, etapa 6 (religar o OC)."
    pergunta "Reiniciar agora para validar?" && { reboot_frio; faz systemctl reboot; }
}

# ---------- roda em todo boot depois da etapa 5 (servico) ----------
_boot() {
    [ "$SIM" = 1 ] && { echo "_boot nao roda em simulacao (mexeria na SMU de verdade)"; exit 0; }
    local BL=$EST/boot.log; MASCARA=; BASE=; ALVO=; OFF16=
    . "$CONF" || exit 0
    blog() { echo "$*"; echo "$(date '+%F %T') $*" >> "$BL"; }
    local n; n=$(threads)
    # boot com os nucleos extras: o proximo reboot tem de ser FRIO (volta a mascara de fabrica); um reset
    # quente com 0xFF numa entrada sem a MADT nova subiria os nucleos ruins
    if [ "$n" = "$ALVO" ]; then rm -f "$EST/tentativa"; reboot_frio; blog "OK: $n threads"; exit 0; fi
    if [ "$n" -gt "$BASE" ] && [ -n "$OFF16" ]; then
        local d; desliga_apics $OFF16 && d="desligados" || d="FALHA AO DESLIGAR"
        blog "$n threads na entrada normal (reset quente): APIC $OFF16 (nucleos ruins) $d, online=$(cat /sys/devices/system/cpu/online)"
    elif [ "$n" != "$BASE" ]; then blog "threads=$n inesperado - nada a fazer"; exit 0; fi
    parar() { blog "$1"; [ "$n" -gt "$BASE" ] && { reboot_frio; blog "nucleos ruins offline neste boot; reboot ajustado para frio"; }; exit 0; }
    grep -qw bc250.nucleos.nao /proc/cmdline && parar "desligado pela linha do kernel"
    [ -e /etc/bc250-nucleos.desligado ] && parar "desligado por /etc/bc250-nucleos.desligado"
    [ -e "$EST/falhou" ] && parar "tentativa anterior falhou - parado (rm $EST/falhou para tentar de novo)"
    [ -e "$EST/tentativa" ] && { mv "$EST/tentativa" "$EST/falhou"; parar "FALHOU: a ultima tentativa nao chegou a $ALVO threads. Parado."; }
    local saved base kver
    saved=$(grub2-editenv list | sed -n 's/^saved_entry=//p')
    # com GRUB_SAVEDEFAULT=true o GRUB lembraria a entrada dos nucleos e o boot frio cairia nela com a mascara
    # de fabrica: esquece (o boot frio volta para a entrada padrao)
    [ "$saved" = "$ENT_P" ] && { grub2-editenv - unset saved_entry; blog "saved_entry apontava para $ENT_P - removido"; saved=""; }
    base=$ENTRIES/$saved.conf; [ -n "$saved" ] && [ -f "$base" ] || base=$ENTRIES/$(cat /etc/machine-id)-$(uname -r).conf
    kver=$(sed -n 's|^linux /vmlinuz-||p' "$base" 2>/dev/null)
    grep -q '^CONFIG_ACPI_TABLE_UPGRADE=y' "/boot/config-$kver" 2>/dev/null || parar "kernel '$kver' sem CONFIG_ACPI_TABLE_UPGRADE - nao libero"
    install -m 0644 "$LIB/final.cpio" "/boot/$ENT_P.cpio"
    cria_entrada "$ENT_P" "BC-250 nucleos extras ($kver)" "$ENT_P.cpio" "" >/dev/null || parar "falha ao gerar a entrada"
    if [ "$n" = "$BASE" ]; then
        local s out; for s in $SERV_GPU_GOV; do systemctl stop "$s" 2>/dev/null; done
        out=$(python3 "$LIB/smu.py" gravar "$MASCARA" 2>&1) || { blog "SMU: $out - segue com $BASE threads"; exit 0; }
        blog "mascara: $out"
    fi
    grub2-reboot "$ENT_P" || parar "grub2-reboot falhou"
    echo "$(date '+%F %T') kernel $kver" > "$EST/tentativa"; sync
    reboot_quente; blog "reset quente para a entrada $ENT_P (kernel $kver)"
    systemctl reboot; sleep 60
}

# ---------- etapa 6: religar OC ----------
etapa6() {
    echo; echo "${B}6. Religar o OC${N0}"
    local e; e=$(etapa)
    if ! { [ "$e" -ge 5 ] || { [ "$e" -ge 4 ] && [ "$(eget FINAL)" = nenhum ]; }; }; then aviso "Faca a etapa 5 (ou a 4, se nenhum nucleo passou) antes."; return; fi
    [ "$e" -ge 6 ] && { ok "ja feito."; return; }
    local hab; hab=$(eget OC_HAB)
    [ -n "$hab" ] || { ok "nenhum servico de OC estava ligado antes. Nada a religar."; eset ETAPA 6; return; }
    echo "  Estavam ligados antes: $hab"
    if [ "$(eget FINAL)" != nenhum ]; then
        aviso "O OC da CPU (bc250-smu-oc) foi calibrado com $(( $(eget BASE) / 2 )) nucleos. Com mais nucleos ele pode travar"
        aviso "(foi o que aconteceu na placa original). Recalibre pelo BC250 Control Center (deteccao) antes."
    fi
    echo "   1) religar tudo como estava"
    echo "   2) religar so a GPU (governor/CUs) e deixar o OC da CPU desligado ate recalibrar  [recomendado]"
    echo "   3) nao religar nada agora"
    local o s; read -rp "  Escolha [2]: " o; o=${o:-2}
    case $o in
        1) for s in $hab; do faz systemctl enable --now "$s"; done; log "etapa 6: religado tudo: $hab";;
        2) for s in $hab; do [[ "$s" == bc250-smu-oc || "$s" == bc250-cpu-escada ]] && continue; faz systemctl enable --now "$s"; done
           log "etapa 6: religado so GPU; OC da CPU fica desligado"; aviso "OC da CPU desligado. Depois de recalibrar: systemctl enable --now bc250-smu-oc";;
        *) log "etapa 6: nada religado"; ok "nada religado (servicos: $hab)";;
    esac
    eset ETAPA 6; ok "Concluido."
}

# ---------- 9: desfazer ----------
desfazer() {
    echo; echo "${B}9. Desfazer tudo${N0}"
    echo "  Remove o servico de teste e o padrao, as entradas do GRUB, os cpio em /boot, religa os servicos"
    echo "  de OC que estavam ligados ($(eget OC_HAB)) e apaga o estado (o historico fica)."
    pergunta "Desfazer?" || return
    local s
    for u in "$UNIT_T" "$UNIT_P"; do faz systemctl disable "$u" 2>/dev/null; rm -f "$UNITDIR/$u"; done
    faz systemctl daemon-reload
    limpa_teste; rm -f "$ENTRIES/$ENT_P.conf" "$R/boot/$ENT_P.cpio" "$CONF" "$EST/tentativa" "$EST/falhou"
    if [ "$(etapa)" -ge 2 ] && [ "$(etapa)" -lt 6 ]; then for s in $(eget OC_HAB); do faz systemctl enable "$s"; done; fi
    mv "$EF" "$EST/estado.env.desfeito-$(date +%H%M%S)" 2>/dev/null
    log "desfeito"; reboot_frio
    ok "Desfeito. Reinicie normalmente (frio) para voltar ao padrao de fabrica."
}

status() {
    echo; echo "${B}8. Status${N0}"; mostra_estado
    local v; v=$(eget TESTANDO); [ -n "$v" ] && { echo "  Teste em andamento: $(nome_var "$v")"; tail -n 6 "$EST/teste-$v.log" 2>/dev/null | sed 's/^/    /'; }
    echo "  Historico:"; tail -n 8 "$EST/historico.log" 2>/dev/null | sed 's/^/    /'
    [ -f "$EST/boot.log" ] && { echo "  Boots (padrao):"; tail -n 4 "$EST/boot.log" | sed 's/^/    /'; }
}

menu() {
    while :; do
        clear 2>/dev/null; cabecalho; mostra_estado
        local e p i txt; e=$(etapa)
        case $e in 0) p=1;; 1) p=2;; 2) p=3;; 3) p=4;; 4) [ "$(eget FINAL)" = nenhum ] && p=6 || p=5;; 5) p=6;; *) p=7;; esac
        echo
        for i in 1 2 3 4 5 6; do
            case $i in 1) txt="Diagnostico (so leitura)";; 2) txt="Desligar o OC da CPU e da GPU";; 3) txt="Testar os nucleos (um por boot)";;
                       4) txt="Resultado";; 5) txt="Instalar como padrao";; 6) txt="Religar o OC";; esac
            if [ "$i" -lt "$p" ]; then
                if [ "$i" = 5 ] && [ "$(eget FINAL)" = nenhum ]; then echo "   [pulada]   $i. $txt"; else echo "   ${VD}[feito]${N0}    $i. $txt"; fi
            elif [ "$i" = "$p" ]; then echo "   ${B}${AM}[proxima]${N0}  ${B}$i. $txt${N0}"
            else echo "   [travada]  $i. $txt"; fi
        done
        echo "              8. Status / historico     9. Desfazer tudo     0. Sair"
        local o; read -rp "Opcao: " o || exit 0
        case $o in 1) etapa1;; 2) etapa2;; 3) etapa3;; 4) etapa4;; 5) etapa5;; 6) etapa6;; 8) status;; 9) desfazer;; 0|q) exit 0;; *) continue;; esac
        pausa
    done
}

case "${1:-}" in
    _teste) _teste;;
    _boot) _boot;;
    status) cabecalho; status;;
    1|2|3|4|5|6) cabecalho; "etapa$1";;
    9) cabecalho; desfazer;;
    *) menu;;
esac
