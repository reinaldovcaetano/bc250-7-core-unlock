#!/bin/bash
# So leitura: confere se esta placa/sistema batem com o que o bc250-grub.sh espera. Nao grava nada no boot nem na SMU.
[ "$(id -u)" -eq 0 ] || exec sudo "$0" "$@"
AQUI=$(cd "$(dirname "$(readlink -f "$0")")" && pwd)
T=$(mktemp -d); trap 'rm -rf "$T"' EXIT
sed -n "/^cat > \"\$LIB\/smu.py\" <<'PY'$/,/^PY$/p" "$AQUI/bc250-nucleos.sh" | sed '1d;$d' > "$T/smu.py"
sed -n "/^cat > \"\$LIB\/madt.py\" <<'PY'$/,/^PY$/p" "$AQUI/bc250-nucleos.sh" | sed '1d;$d' > "$T/madt.py"
echo "== mascara da SMU (so leitura)";  M=$(python3 "$T/smu.py" ler); echo "$M"
echo "== MADT da BIOS";                 cp /sys/firmware/acpi/tables/APIC "$T/apic"; python3 "$T/madt.py" verificar "$T/apic" "$M"
python3 - "$T/apic" <<'PY'
import struct,sys
d=open(sys.argv[1],'rb').read(); o=44
print("  OEM %s %s rev 0x%X" % (d[10:16].decode(errors='replace'), d[16:24].decode(errors='replace'), struct.unpack('<I',d[24:28])[0]))
while o<len(d):
    t,l=d[o],d[o+1]
    if t==0: print("  LAPIC uid=%-3d apic=%-2d flags=%d" % (d[o+2],d[o+3],struct.unpack('<I',d[o+4:o+8])[0]))
    else: print("  entrada tipo %d (%d bytes)" % (t,l))
    o+=l
PY
echo "== SSDT da BIOS";  for f in /sys/firmware/acpi/tables/SSDT*; do echo "  $(basename $f): $(dd if=$f bs=1 skip=16 count=8 status=none | tr -d '\0') rev $(od -An -tu4 -j24 -N4 $f | tr -d ' ')"; done
echo "== initramfs ja tem SSDT?"; cpio -it --quiet < /boot/initramfs-$(uname -r).img 2>/dev/null | grep acpi || echo "  nao"
echo "== entradas BLS"; ls -la /boot/loader/entries; for f in /boot/loader/entries/*.conf; do echo "-- $f"; cat "$f"; done
echo "== grubenv"; grub2-editenv list
echo "== grub.cfg do EFI"; for f in /boot/efi/EFI/*/grub.cfg; do echo "-- $f"; head -c 600 "$f"; echo; done
echo "== grub.cfg principal"; ls -la /boot/grub2/grub.cfg; grep -n 'timeout\|blscfg\|next_entry\|menu_auto_hide' /boot/grub2/grub.cfg | head -20
echo "== servicos antigos"; ls /etc/systemd/system | grep -i bc250 || echo "  nenhum"
