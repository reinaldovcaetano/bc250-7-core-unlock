#!/usr/bin/env python3
# Registro leve da BC-250: a cada INTERVALO s grava uma linha num CSV por dia.
#   colunas: hora, temperatura CPU (Tctl) e GPU (edge), potencia (PPT), tensao e clock dos 8 nucleos
#   fisicos (SMU), threads online, carga media, modo do scx_lavd, erros de hardware (MCE) no boot.
# Uso: bc250-registro.py <pasta de saida> <usuario dono dos arquivos> [intervalo_s]
import os, sys, time, glob, pwd, subprocess, datetime
saida, dono = sys.argv[1], sys.argv[2]
# biblioteca da SMU que vem com o BC250 Control Center (sem ela, as colunas de tensao/clock ficam vazias)
SMU_LIB = os.environ.get("BC250_SMU_LIB") or os.path.expanduser("~%s/.local/share/bc250-control-center/ResourceTools/bc250_smu_oc" % dono)
intervalo = int(sys.argv[3]) if len(sys.argv) > 3 else 60
uid, gid = pwd.getpwnam(dono).pw_uid, pwd.getpwnam(dono).pw_gid
CAB = "data_hora,tctl_c,gpu_c,ppt_w,cpu_mv,n0,n1,n2,n3,n4,n5,n6,n7,threads_online,carga_1min,scx_modo,mce_boot\n"

def hwmon(nome, arq):
    for d in glob.glob("/sys/class/hwmon/hwmon*"):
        try:
            if open(d + "/name").read().strip() == nome: return float(open(d + "/" + arq).read()) 
        except OSError: pass
    return None

def smu_le():
    try:
        sys.path.insert(0, SMU_LIB)
        from bc250_smu import Bc250Smu
        s = Bc250Smu(use_flock=True)        # flock: nao atropela o governor da GPU nem o Control Center
        try: return s.q3_0x36_get_current_cpu_voltage(), [s.q3_0x43_get_core_freq(i) for i in range(8)]
        finally: s.close()
    except Exception:
        return None, [None] * 8

def scx_modo():
    try:
        a = open("/proc/%s/cmdline" % subprocess.run(["pgrep", "-x", "scx_lavd"], capture_output=True, text=True).stdout.split()[0]).read()
        return "gaming" if "--performance" in a else "auto" if "--autopilot" in a else "powersave" if "--powersave" in a else "outro"
    except Exception:
        return "nenhum"

def mce():
    try: return sum(1 for l in subprocess.run(["dmesg"], capture_output=True, text=True).stdout.splitlines() if "Hardware Error" in l or "mce: [" in l)
    except Exception: return ""

f = lambda v, fmt="%.1f": "" if v is None else fmt % v
os.makedirs(saida, exist_ok=True); os.chown(saida, uid, gid)
while True:
    agora = datetime.datetime.now()
    arq = os.path.join(saida, agora.strftime("%Y-%m-%d") + ".csv")
    novo = not os.path.exists(arq)
    mv, clk = smu_le()
    tctl = hwmon("k10temp", "temp1_input"); gpu = hwmon("amdgpu", "temp1_input"); ppt = hwmon("amdgpu", "power1_average")
    linha = [agora.strftime("%Y-%m-%d %H:%M:%S"), f(tctl and tctl / 1000), f(gpu and gpu / 1000), f(ppt and ppt / 1e6),
             f(mv, "%d")] + [f(c, "%d") for c in clk] + [
             str(open("/proc/cpuinfo").read().count("\nprocessor") + 1), open("/proc/loadavg").read().split()[0], scx_modo(), str(mce())]
    with open(arq, "a") as o:
        if novo: o.write(CAB)
        o.write(",".join(linha) + "\n")
    if novo: os.chown(arq, uid, gid)
    time.sleep(intervalo)
