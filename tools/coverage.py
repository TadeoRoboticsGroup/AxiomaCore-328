#!/usr/bin/env python3
"""
Cobertura de código del RTL, fusionando TODAS las fuentes.

POR QUÉ ES UNA PUERTA Y NO UN INFORME. Un «0 divergencias» no dice nada sobre
lo que NO se ejecutó. La prueba de mutación cubre parte de ese hueco, pero su
catálogo lo escribe una persona: sólo prueba lo que a alguien se le ocurrió
romper. La cobertura dice, sin opinión, qué líneas y qué señales no ha tocado
nadie.

Y funciona: la primera medida de este proyecto encontró cuatro caminos que
ningún banco pisaba jamás — `SPM` (con TRES fallos dentro), la ejecución de un
opcode ilegal, las tres interrupciones de la USART y un par de puertos de
escritura de SREG que eran lógica muerta.

LA FUSIÓN ES LO IMPORTANTE. Medir sólo el arnés diferencial da un 80 % y una
conclusión falsa: el Timer0 y la USART salen bajos porque su funcionalidad la
cubren SUS bancos. Lo que vale es la unión de todo lo que se ejecuta.

Uso:  python3 tools/coverage.py [umbral]
"""
import glob
import os
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
COV = ROOT / "build" / "cov"
# 99 %, y no 100. Quedan cinco puntos que NO son alcanzables y están
# adjudicados uno a uno:
#   - el `default:` de un `case` completo en la ALU (3): inalcanzable por
#     construcción, el decodificador sólo emite operaciones válidas. Es la rama
#     defensiva que la síntesis elimina.
#   - `next_warmup` en el secuenciador (1): sólo lo pone el reset.
#   - `$readmemh` en la memoria de programa (1): sólo corre cuando el programa
#     va DENTRO del bitstream; en simulación se carga por la puerta de atrás.
# Si alguna vez baja de 99, hay un camino nuevo que nadie ejecuta.
UMBRAL_POR_DEFECTO = 99.0

VERDE, ROJO, AMAR, GRIS, NEGRITA, FIN = (
    "\033[0;32m", "\033[0;31m", "\033[0;33m", "\033[2m", "\033[1m", "\033[0m")

RTL = ("rtl/soc/axioma328_soc.v rtl/core/axioma_core.v rtl/core/axioma_seq.v "
       "rtl/core/axioma_decode.v rtl/core/axioma_alu.v rtl/core/axioma_sreg.v "
       "rtl/core/axioma_regfile.v rtl/mem/axioma_progmem.v rtl/mem/axioma_dmem.v "
       "rtl/bus/axioma_dbus.v rtl/periph/axioma_gpio.v rtl/periph/axioma_gpior.v "
       "rtl/periph/axioma_prescaler.v rtl/periph/axioma_timer0.v "
       "rtl/periph/axioma_timer1.v rtl/periph/axioma_timer2.v "
       "rtl/periph/axioma_timer8.v "
       "rtl/periph/axioma_usart.v rtl/periph/axioma_extint.v "
       "rtl/periph/axioma_spi.v rtl/periph/axioma_twi.v "
       "rtl/periph/axioma_adc.v rtl/periph/axioma_ac.v "
       "rtl/periph/axioma_wdt.v rtl/periph/axioma_eeprom.v "
       "rtl/periph/axioma_clkctrl.v "
       "rtl/periph/axioma_irq.v")

# El modelo del frente analogico del ADC no es del dispositivo (ADR 0002) y
# no se mide su cobertura, pero hace falta para ELABORAR los tops de
# simulacion: sin el, el SoC tiene cinco puertos colgando.
FRENTE = " rtl/fpga/axioma_adc_frente.v"

# UNOPTFLAT se silencia SÓLO aquí. La instrumentación de cobertura cambia la
# planificación interna de verilator y le hace ver un ciclo combinacional que no
# existe: `yosys ... check -assert` sobre el mismo RTL no encuentra ninguno, y
# eso lo comprueba `make synth-check` en cada ejecución.
COMUN = "--cc --exe --build --coverage -Wall -Wno-DECLFILENAME -Wno-UNOPTFLAT -Irtl/soc -Irtl/core"


def sh(cmd, **kw):
    return subprocess.run(cmd, shell=True, cwd=ROOT, capture_output=True,
                          text=True, **kw)


def construir(mdir, salida, top, fuentes, extra=""):
    r = sh(f"verilator {COMUN} -Mdir {mdir} -o {salida} --top-module {top} "
           f"{extra} {fuentes}")
    if r.returncode:
        print(f"{ROJO}no compila {salida}{FIN}")
        print("\n".join((r.stdout + r.stderr).splitlines()[-15:]))
        sys.exit(1)


def main():
    umbral = float(sys.argv[1]) if len(sys.argv) > 1 else UMBRAL_POR_DEFECTO
    print(f"{NEGRITA}Cobertura de código{FIN}")

    # De dónde salen las rutas de simavr. Se toman del entorno, y el Makefile
    # las pasa SIEMPRE desde sus propias variables: asi este script funciona
    # igual lanzado a mano tras `source env.sh` que desde la CI, que no lo
    # hace. Sin esto fallaba solo en el servidor, que es el peor sitio donde
    # descubrir una dependencia implicita.
    casa = os.path.expanduser("~")
    simavr_inc = os.environ.get("SIMAVR_INCLUDE") or f"{casa}/eda/simavr-src/simavr/sim"
    simavr_lib = os.environ.get("SIMAVR_LIB") or f"{casa}/eda/simavr-src/simavr/obj-x86_64-linux-gnu"
    if not Path(simavr_inc).is_dir():
        print(f"  {ROJO}no encuentro simavr en {simavr_inc}{FIN}")
        print(f"  {GRIS}instalacion desde cero: INSTALL.md{FIN}")
        return 1

    COV.mkdir(parents=True, exist_ok=True)
    for f in COV.glob("*.dat"):
        f.unlink()

    # ---- los tres arneses que ejercitan el RTL ----
    construir("build/vcov", "diffcov", "axioma_sim_top",
              f"sim/diff/axioma_sim_top.v {RTL}{FRENTE} sim/diff/diff.cpp",
              f'-CFLAGS "-I{simavr_inc} -I{simavr_inc}/avr" '
              f'-LDFLAGS "-L{simavr_lib} -lsimavr -lelf"')
    construir("build/vcovr", "robustc", "axioma_sim_top",
              f"sim/diff/axioma_sim_top.v {RTL}{FRENTE} sim/soc/tb_soc_robust.cpp")
    construir("build/vcovt", "tb_timer0c", "tb_timer0_top",
              "sim/periph/tb_timer0_top.v rtl/periph/axioma_timer0.v "
              "rtl/periph/axioma_timer8.v rtl/periph/axioma_prescaler.v "
              "sim/periph/tb_timer0.cpp")
    construir("build/vcov1", "tb_timer1c", "tb_timer1_top",
              "sim/periph/tb_timer1_top.v rtl/periph/axioma_timer1.v "
              "rtl/periph/axioma_prescaler.v sim/periph/tb_timer1.cpp")
    construir("build/vcov2", "tb_timer2c", "tb_timer2_top",
              "sim/periph/tb_timer2_top.v rtl/periph/axioma_timer2.v "
              "rtl/periph/axioma_timer8.v rtl/periph/axioma_prescaler.v "
              "sim/periph/tb_timer2.cpp")
    construir("build/vcovu", "tb_usartc", "axioma_usart",
              "rtl/periph/axioma_usart.v sim/periph/tb_usart.cpp")
    construir("build/vcove", "tb_extintc", "axioma_extint",
              "rtl/periph/axioma_extint.v sim/periph/tb_extint.cpp")
    construir("build/vcovs", "tb_spic", "axioma_spi",
              "rtl/periph/axioma_spi.v sim/periph/tb_spi.cpp")
    construir("build/vcovt", "tb_twic", "axioma_twi",
              "rtl/periph/axioma_twi.v sim/periph/tb_twi.cpp")
    construir("build/vcova", "tb_adcc", "axioma_adc",
              "rtl/periph/axioma_adc.v sim/periph/tb_adc.cpp")
    construir("build/vcovac", "tb_acc", "axioma_ac",
              "rtl/periph/axioma_ac.v sim/periph/tb_ac.cpp")
    construir("build/vcovw", "tb_wdtc", "axioma_wdt",
              "rtl/periph/axioma_wdt.v sim/periph/tb_wdt.cpp")
    construir("build/vcovee", "tb_eepc", "axioma_eeprom",
              "rtl/periph/axioma_eeprom.v sim/periph/tb_eeprom.cpp")
    construir("build/vcovck", "tb_clkc", "axioma_clkctrl",
              "rtl/periph/axioma_clkctrl.v sim/periph/tb_clkctrl.cpp")
    construir("build/vcovck2", "clkc2", "tb_soc_clk_top",
              f"sim/soc/tb_soc_clk_top.v {RTL}{FRENTE} sim/soc/tb_soc_clk.cpp")
    construir("build/vcovsl", "slpc", "tb_soc_clk_top",
              f"sim/soc/tb_soc_clk_top.v {RTL}{FRENTE} sim/soc/tb_soc_sleep.cpp")
    construir("build/vcovpu", "pudc", "tb_soc_clk_top",
              f"sim/soc/tb_soc_clk_top.v {RTL}{FRENTE} sim/soc/tb_soc_pud.cpp")
    construir("build/vcovpr", "prrc", "tb_soc_clk_top",
              f"sim/soc/tb_soc_clk_top.v {RTL}{FRENTE} sim/soc/tb_soc_prr.cpp")
    construir("build/vcovbt", "bitsc", "tb_soc_top",
              f"sim/soc/tb_soc_top.v {RTL}{FRENTE} sim/soc/tb_soc_bits.cpp",
              "-Isim/soc")
    construir("build/vcovmi", "micc", "tb_soc_clk_top",
              f"sim/soc/tb_soc_clk_top.v {RTL}{FRENTE} sim/soc/tb_soc_micros.cpp")
    construir("build/vcovtr", "trigc", "tb_soc_trig_top",
              f"sim/soc/tb_soc_trig_top.v {RTL}{FRENTE} sim/soc/tb_soc_trig.cpp")
    construir("build/vcovh", "helloc", "tb_soc_uart_top",
              f"sim/soc/tb_soc_uart_top.v {RTL}{FRENTE} sim/soc/tb_soc_uart.cpp")

    # ---- ejecutarlos ----
    env = f"LD_LIBRARY_PATH={simavr_lib}:$LD_LIBRARY_PATH"
    n = 0
    for t in sorted(glob.glob(str(ROOT / "build/diff/*.bin"))) + \
             sorted(glob.glob(str(ROOT / "build/random/rnd0*.bin"))):
        nom = Path(t).stem
        sh(f"AXIOMA_COV=build/cov/{nom}.dat {env} ./build/vcov/diffcov "
           f"{t} 50000 build/perf/cycles.bin")
        n += 1
    sh("AXIOMA_COV=build/cov/robust.dat ./build/vcovr/robustc"); n += 1
    sh("AXIOMA_COV=build/cov/timer0.dat ./build/vcovt/tb_timer0c"); n += 1
    sh("AXIOMA_COV=build/cov/timer1.dat ./build/vcov1/tb_timer1c"); n += 1
    sh("AXIOMA_COV=build/cov/timer2.dat ./build/vcov2/tb_timer2c"); n += 1
    sh("AXIOMA_COV=build/cov/usart.dat ./build/vcovu/tb_usartc"); n += 1
    sh("AXIOMA_COV=build/cov/extint.dat ./build/vcove/tb_extintc"); n += 1
    sh("AXIOMA_COV=build/cov/spi.dat ./build/vcovs/tb_spic"); n += 1
    sh("AXIOMA_COV=build/cov/twi.dat ./build/vcovt/tb_twic"); n += 1
    sh("AXIOMA_COV=build/cov/adc.dat ./build/vcova/tb_adcc"); n += 1
    sh("AXIOMA_COV=build/cov/ac.dat ./build/vcovac/tb_acc"); n += 1
    sh("AXIOMA_COV=build/cov/wdt.dat ./build/vcovw/tb_wdtc"); n += 1
    sh("AXIOMA_COV=build/cov/eeprom.dat ./build/vcovee/tb_eepc"); n += 1
    sh("AXIOMA_COV=build/cov/clkctrl.dat ./build/vcovck/tb_clkc"); n += 1
    sh("AXIOMA_COV=build/cov/clk.dat ./build/vcovck2/clkc2"); n += 1
    sh("AXIOMA_COV=build/cov/sleep.dat ./build/vcovsl/slpc"); n += 1
    sh("AXIOMA_COV=build/cov/pud.dat ./build/vcovpu/pudc"); n += 1
    sh("AXIOMA_COV=build/cov/prr.dat ./build/vcovpr/prrc"); n += 1
    sh("AXIOMA_COV=build/cov/bits.dat ./build/vcovbt/bitsc"); n += 1
    sh("AXIOMA_COV=build/cov/micros.dat ./build/vcovmi/micc"); n += 1
    sh("AXIOMA_COV=build/cov/trig.dat ./build/vcovtr/trigc"); n += 1
    sh("AXIOMA_COV=build/cov/hello.dat ./build/vcovh/helloc build/fw/hello.bin"); n += 1
    print(f"  {n} ejecuciones instrumentadas")

    # ---- fusionar ----
    # Se cuenta sobre el formato LCOV y no sobre el fichero anotado: la
    # anotación alinea el contador en un ancho fijo y, en cuanto una línea se
    # ejecuta millones de veces, el formato cambia y un parser ingenuo deja de
    # verla. Pasó: el total «bajó» de 1 298 a 880 puntos al AÑADIR un banco.
    sh(f"rm -rf {COV}/annot")
    sh(f"verilator_coverage --write {COV}/total.dat {COV}/*.dat")
    sh(f"verilator_coverage --write-info {COV}/cov.info {COV}/total.dat")
    sh(f"verilator_coverage --annotate {COV}/annot --annotate-min 1 {COV}/total.dat")

    tot = {}
    fichero = None
    for linea in open(COV / "cov.info", errors="ignore"):
        if linea.startswith("SF:"):
            fichero = os.path.basename(linea[3:].strip())
            if (fichero.startswith("tb_") or fichero.startswith("axioma_sim_top")
                    or fichero == "axioma_adc_frente.v"):
                # Bancos de prueba, no son el chip. Y el modelo del frente
                # analogico tampoco: el ADR 0002 lo deja FUERA del dispositivo,
                # asi que medir su cobertura seria medir el banco. Hace falta
                # para elaborar los tops -el SoC tiene cinco puertos que
                # conectar- y nada mas.
                fichero = None
            elif fichero not in tot:
                tot[fichero] = [0, 0]
        elif linea.startswith("DA:") and fichero:
            cuenta = int(linea[3:].strip().split(",")[1])
            tot[fichero][1 if cuenta == 0 else 0] += 1

    C = S = 0
    print()
    for nom, (c, s_) in sorted(tot.items(), key=lambda x: x[1][1], reverse=True):
        t = c + s_
        if not t:
            continue
        C += c
        S += s_
        col = VERDE if s_ == 0 else AMAR
        print(f"  {col}{nom:<26}{FIN} {100*c/t:5.1f} %   {s_:>3} sin cubrir de {t}")

    pct = 100.0 * C / (C + S) if C + S else 0.0
    print(f"\n  {NEGRITA}{pct:.1f} %{FIN}   ({C} de {C+S} puntos)   umbral {umbral:.1f} %")
    if S:
        print(f"  {GRIS}los puntos sin cubrir salen anotados en build/cov/annot,")
        print(f"  marcados con %000000 al principio de la línea{FIN}")

    if pct < umbral:
        print(f"\n  {ROJO}por debajo del umbral{FIN}")
        return 1
    print(f"  {VERDE}sobre el umbral{FIN}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
