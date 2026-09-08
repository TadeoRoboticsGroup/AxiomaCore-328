#!/usr/bin/env python3
"""
Genera las constraints de la ULX3S para AxiomaCore-328 a partir del fichero
oficial de la placa, en lugar de transcribir los sitios de pines a mano.

Mismo principio que el generador del mapa de registros: la fuente autoritativa
manda, y una transcripción manual es una fuente de errores silenciosos.

Uso:  python3 tools/gen_ulx3s_lpf.py
Lee:  rtl/fpga/ecp5/ulx3s_v20_reference.lpf
Crea: rtl/fpga/ecp5/axioma_ulx3s.lpf
"""
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
REF = ROOT / "rtl/fpga/ecp5/ulx3s_v20_reference.lpf"
OUT = ROOT / "rtl/fpga/ecp5/axioma_ulx3s.lpf"

# Mapa del SoC sobre las señales de la placa.
#   nombre en nuestro top  ->  (señal de la placa, comentario)
MAP = [
    ("clk_25mhz",   "clk_25mhz",  "oscilador de la placa; el PLL deriva F_CPU"),
    ("btn_reset",   "btn[1]",     "FIRE1. Activo alto en la placa: el top invierte"),
    ("wifi_gpio0",  "wifi_gpio0", "debe conducirse a 1 o el ESP32 reinicia la placa"),
    ("uart_tx",     "ftdi_rxd",   "PD1. La FPGA transmite hacia el FTDI"),
    ("uart_rx",     "ftdi_txd",   "PD0. La FPGA recibe del FTDI"),
]
# Buses: (nuestro bus, señal de la placa, indices de la placa, comentario)
BUSES = [
    ("led",      "led", list(range(8)),        "espejo de PORTB. PB5 = pin 13 de Arduino = led[5]"),
    ("portb_io", "gp",  list(range(0, 8)),     "PB0-PB7  (Arduino D8-D13 + XTAL)"),
    ("portc_io", "gp",  list(range(8, 15)),    "PC0-PC6  (Arduino A0-A5 + RESET)"),
    ("portd_io", "gn",  list(range(0, 8)),     "PD0-PD7  (Arduino D0-D7)"),
]

def load_sites(path):
    txt = path.read_text(encoding="utf-8", errors="replace")
    sites = {}
    for m in re.finditer(r'LOCATE\s+COMP\s+"([^"]+)"\s+SITE\s+"([A-Z0-9]+)"', txt):
        sites[m.group(1)] = m.group(2)
    return sites

def main():
    if not REF.exists():
        sys.exit(f"falta la referencia: {REF}")
    sites = load_sites(REF)

    def site(name):
        if name not in sites:
            sys.exit(f"señal no encontrada en el fichero oficial: {name}")
        return sites[name]

    L = []
    add = L.append
    add("# AxiomaCore-328 - constraints para ULX3S (ECP5 LFE5U-25F, v2.x / v3.0)")
    add("#")
    add("# FICHERO GENERADO. No editar a mano.")
    add("#   Generador: tools/gen_ulx3s_lpf.py")
    add("#   Fuente:    rtl/fpga/ecp5/ulx3s_v20_reference.lpf (proyecto ULX3S de emard)")
    add("#")
    add("# Define el contrato de pines del top rtl/fpga/ecp5/axioma_ulx3s_top.v (fase 2).")
    add("")
    add("BLOCK RESETPATHS;")
    add("BLOCK ASYNCPATHS;")
    add("")
    add("SYSCONFIG CONFIG_IOVOLTAGE=3.3 COMPRESS_CONFIG=ON MCCLK_FREQ=62 "
        "SLAVE_SPI_PORT=DISABLE MASTER_SPI_PORT=ENABLE SLAVE_PARALLEL_PORT=DISABLE;")
    add("")

    add("## ------------------------------------------------------- señales simples")
    for ours, board, note in MAP:
        s = site(board)
        add(f'LOCATE COMP "{ours}" SITE "{s}";  # {board} - {note}')
    add("")
    add(f'IOBUF  PORT "clk_25mhz" PULLMODE=NONE IO_TYPE=LVCMOS33;')
    add(f'FREQUENCY PORT "clk_25mhz" 25 MHZ;')
    add(f'IOBUF  PORT "btn_reset"  PULLMODE=DOWN IO_TYPE=LVCMOS33;')
    add(f'IOBUF  PORT "wifi_gpio0" PULLMODE=UP   IO_TYPE=LVCMOS33 DRIVE=4;')
    add(f'IOBUF  PORT "uart_tx"    PULLMODE=UP   IO_TYPE=LVCMOS33 DRIVE=4;')
    add(f'IOBUF  PORT "uart_rx"    PULLMODE=UP   IO_TYPE=LVCMOS33;')
    add("")

    for ours, board, idxs, note in BUSES:
        add(f"## {ours}[{len(idxs)-1}:0]  <-  {board}[{idxs[0]}..{idxs[-1]}]   # {note}")
        for i, bi in enumerate(idxs):
            s = site(f"{board}[{bi}]")
            add(f'LOCATE COMP "{ours}[{i}]" SITE "{s}";  # {board}[{bi}]')
        drive = 4 if ours == "led" else 8
        pull = "NONE"
        for i in range(len(idxs)):
            add(f'IOBUF PORT "{ours}[{i}]" PULLMODE={pull} IO_TYPE=LVCMOS33 DRIVE={drive};')
        add("")

    OUT.write_text("\n".join(L) + "\n", encoding="utf-8")
    n = sum(1 for l in L if l.startswith("LOCATE"))
    print(f"escrito {OUT.relative_to(ROOT)} — {n} pines localizados")

if __name__ == "__main__":
    main()
