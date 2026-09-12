#!/usr/bin/env python3
"""
Comprobación de síntesis: ni latches, ni área que se dispare sin avisar.

POR QUÉ HACE FALTA SI EL LINT YA PASA. `verilator --lint-only` no es un
sintetizador. No infiere latches, no resuelve la jerarquía como lo hará la
herramienta que fabrica el bitstream, y no dice cuánta área ocupa nada. El
README citaba números de LUT del ECP5 que ningún comando volvía a medir: eran
una foto de un día concreto, no una propiedad comprobada.

Un latch inferido es el fallo clásico del RTL escrito a mano —una rama de un
`always @(*)` que no asigna una señal—, y no lo caza la simulación, porque el
simulador conserva el valor anterior igual que el latch. Aparece en silicio.

Qué hace:
  1. lee TODO el RTL y comprueba la jerarquía;
  2. falla si yosys infiere un solo latch;
  3. sintetiza cada módulo para el ECP5 y publica su área.

El área NO es un criterio de fallo: es un número que se mide y se enseña, para
que un cambio que duplique el tamaño de un módulo se vea en el diff de la CI
en vez de descubrirse al cerrar el timing en la fase 5.
"""
import re
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent

CORE = ["rtl/core/axioma_core.v", "rtl/core/axioma_seq.v", "rtl/core/axioma_decode.v",
        "rtl/core/axioma_alu.v", "rtl/core/axioma_sreg.v", "rtl/core/axioma_regfile.v"]

PERIF = ["rtl/bus/axioma_dbus.v", "rtl/periph/axioma_gpio.v",
         "rtl/periph/axioma_gpior.v", "rtl/periph/axioma_prescaler.v",
         "rtl/periph/axioma_timer0.v", "rtl/periph/axioma_timer1.v",
         "rtl/periph/axioma_usart.v", "rtl/periph/axioma_extint.v",
         "rtl/periph/axioma_irq.v"]

SOC = ["rtl/soc/axioma328_soc.v"] + CORE + PERIF + \
      ["rtl/mem/axioma_progmem.v", "rtl/mem/axioma_dmem.v"]

# (módulo, ficheros). Cada uno se sintetiza por separado: así el área es
# atribuible, y un módulo que crece no se esconde dentro del total.
MODULOS = [
    ("axioma_core",      CORE),
    ("axioma_progmem",   ["rtl/mem/axioma_progmem.v"]),
    ("axioma_dmem",      ["rtl/mem/axioma_dmem.v"]),
    ("axioma_dbus",      ["rtl/bus/axioma_dbus.v"]),
    ("axioma_gpio",      ["rtl/periph/axioma_gpio.v"]),
    ("axioma_prescaler", ["rtl/periph/axioma_prescaler.v"]),
    ("axioma_timer0",    ["rtl/periph/axioma_timer0.v"]),
    ("axioma_irq",       ["rtl/periph/axioma_irq.v"]),
    ("axioma_gpior",     ["rtl/periph/axioma_gpior.v"]),
    ("axioma_timer1",    ["rtl/periph/axioma_timer1.v"]),
    ("axioma_usart",     ["rtl/periph/axioma_usart.v"]),
    ("axioma_extint",    ["rtl/periph/axioma_extint.v"]),
    # El dispositivo entero. Es el unico numero que significa algo de cara a la
    # FPGA: los de arriba son atribucion, este es el area.
    ("axioma328_soc",    SOC),
    # Y el top de la placa, que es lo que acaba en el bitstream: anade el PLL,
    # la secuencia de reset y las celdas de pad con triestado.
    ("axioma_ulx3s_top", ["rtl/fpga/ecp5/axioma_ulx3s_top.v",
                          "rtl/fpga/ecp5/axioma_pll.v"] + SOC),
]

VERDE, ROJO, GRIS, NEGRITA, FIN = "\033[0;32m", "\033[0;31m", "\033[2m", "\033[1m", "\033[0m"


def yosys(script):
    r = subprocess.run(["yosys", "-p", script], cwd=ROOT,
                       capture_output=True, text=True)
    return r.returncode, r.stdout + r.stderr


# El PLL instancia EHXPLLL, una primitiva del fabricante. Para la pasada de
# latches se sustituye por el mismo modelo que usa el lint: lo que se busca ahí
# son ramas de un always @(*) sin asignar, y una instancia de primitiva no
# tiene ninguna. En la síntesis de verdad sí se usa el PLL real, porque
# `synth_ecp5` conoce la primitiva.
VENDOR = "rtl/fpga/ecp5/axioma_pll.v"
STUB   = "sim/models/axioma_pll_stub.v"


def todos_los_fuentes():
    fuentes = [str(p.relative_to(ROOT)) for p in (ROOT / "rtl").rglob("*.v")]
    return sorted(f for f in fuentes if f != VENDOR) + [STUB]


def main():
    print(f"{NEGRITA}Síntesis: latches y área{FIN}")

    # ---------------------------------------------------- 1. latches
    # Se lee el RTL entero de una vez, para que la comprobación vea también las
    # instancias entre módulos. `check -assert` aborta ante una jerarquía rota.
    src = " ".join(todos_los_fuentes())
    rc, out = yosys(f"read_verilog -Irtl/soc {src}; "
                    "hierarchy -check; proc; opt; check -assert")
    if rc != 0:
        print(f"  {ROJO}yosys no puede leer el RTL{FIN}")
        print("\n".join(out.splitlines()[-25:]))
        return 1

    # yosys imprime una línea por señal: «No latch inferred for signal ...»
    # cuando NO lo infiere, y «Latch inferred for signal ...» cuando sí.
    latches = [l for l in out.splitlines()
               if re.search(r"^\s*Latch inferred for signal", l)]
    if latches:
        print(f"  {ROJO}{len(latches)} latch(es) inferido(s){FIN}")
        for l in latches[:10]:
            print(f"    {l.strip()}")
        print("\n  Un latch es una rama de un always @(*) que no asigna una señal.")
        print("  La simulación NO lo distingue de la lógica correcta: conserva el")
        print("  valor anterior igual que el latch. Aparece en silicio.")
        return 1
    print(f"  {VERDE}sin latches{FIN}   ({len(todos_los_fuentes())} ficheros, jerarquía comprobada)")

    # ---------------------------------------------------- 2. área por módulo
    print()
    print(f"  {GRIS}área en el ECP5 — no es criterio de fallo, es una medida{FIN}")
    print(f"  {'módulo':<20} {'LUT4':>7} {'FF':>7}")
    for mod, files in MODULOS:
        rc, out = yosys(f"read_verilog -Irtl/soc {' '.join(files)}; "
                        f"synth_ecp5 -top {mod}; stat")
        if rc != 0:
            print(f"  {ROJO}{mod}: no sintetiza{FIN}")
            print("\n".join(out.splitlines()[-20:]))
            return 1
        # OJO CON `stat`: se imprime DOS VECES. Una dentro de `synth_ecp5`,
        # con la sección «design hierarchy», y otra al final, que es la del
        # módulo ya sintetizado. Sumar las dos daba el triple de área, que es
        # justo la clase de número inventado que este proyecto no publica.
        # Se parsea sólo el ÚLTIMO bloque.
        ultimo = out[out.rindex("Printing statistics."):]
        lut = sum(int(m.group(1)) for m in
                  re.finditer(r"^\s+(\d+)\s+LUT4\s*$", ultimo, re.M))
        ff = sum(int(m.group(1)) for m in
                 re.finditer(r"^\s+(\d+)\s+\S*TRELLIS_FF\S*\s*$", ultimo, re.M))
        print(f"  {mod:<20} {lut:>7,} {ff:>7,}")
    print(f"\n  {GRIS}Los módulos se sintetizan por separado para que el área sea")
    print(f"  atribuible; `axioma328_soc` es el dispositivo entero y NO es la suma")
    print(f"  de los demás, porque la síntesis comparte lógica entre ellos.{FIN}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
