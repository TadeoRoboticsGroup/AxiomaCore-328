#!/usr/bin/env python3
"""
Genera las figuras del README en tema claro y oscuro.

Uso:  python3 tools/gen_diagrams.py [directorio-de-salida]

Salida (2×, PNG):
    images/arquitectura-{light,dark}.png
    images/verificacion-{light,dark}.png
    images/espacio-datos-{light,dark}.png
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from diagram_kit import Canvas, LIGHT, DARK   # noqa: E402

OK, PARTIAL, TODO = "ok", "partial", "todo"


def status_colours(t, st):
    return t[st], t[st + "_bg"]


def block(c, x, y, w, h, title, lines=(), st=None, title_size=14,
          mono_title=True, r=8):
    """Bloque con barra de estado a la izquierda."""
    t = c.t
    fill = t["block"]
    if st:
        _, fill = status_colours(t, st)
    c.box(x, y, w, h, fill, t["line"], r=r)
    if st:
        col, _ = status_colours(t, st)
        c.cr.save()
        c.rrect(x, y, w, h, r)
        c.cr.clip()
        c.box(x, y, 4, h, col, None, r=0)
        c.cr.restore()

    cx = x + w / 2
    if lines:
        c.text(cx, y + h / 2 - (len(lines) * 7) + 1, title, title_size,
               bold=True, mono=mono_title, align="centerm")
        for i, ln in enumerate(lines):
            c.text(cx, y + h / 2 + 13 + i * 15, ln, 11.5,
                   colour=t["muted"], align="centerm")
    else:
        c.ctext(cx, y + h / 2, title, title_size, bold=True, mono=mono_title)


def legend(c, x, y, items, size=11.5):
    """Leyenda horizontal; devuelve el ancho ocupado."""
    t = c.t
    cur = x
    for st, label in items:
        col, bg = status_colours(t, st)
        c.box(cur, y - 6, 12, 12, bg, col, r=3, lw=1.2)
        c.text(cur + 19, y, label, size, colour=t["muted"], align="leftm")
        cur += 19 + c.measure(label, size) + 22
    return cur - x - 22


# ==========================================================================
#  Figura 1 — arquitectura del SoC
# ==========================================================================
def fig_soc(t):
    W, H = 1240, 706
    c = Canvas(W, H, t)

    c.text(48, 54, "Arquitectura de AxiomaCore-328", 26, bold=True)
    c.text(48, 82, "Núcleo AVR de 8 bits · pipeline de 2 etapas · espacio de "
                   "datos unificado · memorias con backend intercambiable",
           13.5, colour=t["muted"])

    legend(c, 48, 664, [(OK, "verificado contra un oráculo independiente"),
                        (PARTIAL, "verificado en parte"),
                        (TODO, "pendiente — fases 2 y 3")])

    # ---- plancha del SoC ----
    PX, PY, PW, PH = 48, 112, 1144, 524
    c.box(PX, PY, PW, PH, t["plate"], t["line"], r=12)
    c.text(PX + 20, PY + 26, "axioma328_soc", 12.5, colour=t["muted"], mono=True)

    # ---- fila 1 ----
    CX, CY, CW, CH = 72, 156, 580, 188
    c.box(CX, CY, CW, CH, t["bg"], t["line"], r=10)
    c.text(CX + 16, CY + 24, "axioma_core", 12.5, colour=t["muted"], mono=True)

    ix, iw = CX + 16, CW - 32                       # 88 .. 636
    block(c, ix, CY + 34, 268, 62, "axioma_decode",
          ["combinacional · 65 536 opcodes"], OK)
    block(c, ix + 280, CY + 34, 268, 62, "axioma_seq",
          ["secuenciador multiciclo"], PARTIAL)
    for i, (nm, sub) in enumerate([("axioma_regfile", "32 × 8 · par de 16 bits"),
                                   ("axioma_alu", "combinacional pura"),
                                   ("axioma_sreg", "I T H S V N Z C")]):
        block(c, ix + i * 188, CY + 108, 172, 62, nm, [sub], OK, title_size=13)

    block(c, 692, CY, 236, 104, "axioma_progmem",
          ["16K × 16 bits · 32 KB", "puerto IF + puerto LPM/SPM",
           "backend: sim · BRAM · SRAM"], OK)

    block(c, 952, CY, 216, 88, "axioma_clkctrl",
          ["CLKPR · PRR · SMCR"], TODO)
    block(c, 952, CY + 100, 216, 88, "axioma_irq",
          ["26 vectores · prioridad fija"], TODO)

    # núcleo <-> memoria de programa
    c.path([(CX + CW + 6, 208), (686, 208)], head="both", colour=t["strong"])
    # irq -> núcleo
    c.path([(946, 300), (CX + CW + 6, 300)], colour=t["todo"], dash=[5, 4])
    c.text(800, 290, "irq_req / irq_ack", 11, colour=t["muted"], mono=True,
           align="center")

    # ---- bus de datos ----
    BX, BY, BW, BH = 72, 376, 1096, 58
    c.box(BX, BY, BW, BH, t["todo_bg"], t["todo"], r=8, dash=[6, 4])
    c.cr.save(); c.rrect(BX, BY, BW, BH, 8); c.cr.clip()
    c.box(BX, BY, 4, BH, t["todo"], None, r=0)
    c.cr.restore()
    c.text(BX + 26, BY + BH / 2 - 7, "axioma_dbus", 14, bold=True, mono=True,
           align="leftm")
    c.text(BX + 26, BY + BH / 2 + 11, "0x0000–0x001F registros · 0x0020–0x005F I/O · "
           "0x0060–0x00FF I/O extendida · 0x0100–0x08FF SRAM",
           11.5, colour=t["muted"], align="leftm")

    c.path([(362, CY + CH + 4), (362, BY - 5)], colour=t["strong"])
    c.text(374, 360, "LD · ST · IN · OUT · PUSH · POP", 11,
           colour=t["muted"], mono=True, align="leftm")

    # ---- periféricos y memorias ----
    RY, RH = 458, 100
    cells = [("axioma_dmem", ["2 KB de SRAM", "flanco de bajada"], OK),
             ("axioma_eeprom", ["1 KB", "máquina de EECR"], TODO),
             ("axioma_gpio", ["PORTB · PORTC · PORTD", "toggle por PINx"], TODO),
             ("axioma_timer0/1/2", ["registro TEMP de 16 bits", "6 canales PWM"], TODO),
             ("usart · spi · twi", ["generador de baudios", "modelos de bus en el banco"], TODO),
             ("adc · ac · wdt", ["SAR de 10 bits", "8 canales"], TODO)]
    cw, gap = 171, 14
    for i, (nm, sub, st) in enumerate(cells):
        x = BX + i * (cw + gap)
        c.path([(x + cw / 2, BY + BH + 4), (x + cw / 2, RY - 5)],
               colour=t["strong"] if st == OK else t["todo"],
               dash=None if st == OK else [5, 4])
        block(c, x, RY, cw, RH, nm, sub, st, title_size=12.5)

    # ---- pines del encapsulado ----
    # Banda propia en vez de una flecha colgando de gpio: los pines salen de
    # varios periféricos, no de uno.
    PBX, PBY, PBH = 72, 578, 40
    c.box(PBX, PBY, BW, PBH, t["bg"], t["line"], r=8, dash=[6, 4])
    c.text(PBX + 26, PBY + PBH / 2, "pines", 11.5, colour=t["muted"],
           mono=True, align="leftm")
    c.text(PBX + BW / 2 + 30, PBY + PBH / 2,
           "PB[7:0]      PC[6:0]      PD[7:0]      ADC[7:0]      "
           "XTAL      RESET", 12, colour=t["muted"], mono=True, align="centerm")
    return c



def badge(c, cx, cy, txt, colour=None, r=11):
    col = colour or c.t["accent"]
    c.set(col)
    c.cr.arc(cx, cy, r, 0, 6.2832)
    c.cr.fill()
    c.ctext(cx, cy, txt, 12, colour=c.t["bg"], bold=True)


def pill(c, x, y, txt, colour=None, size=9.5):
    col = colour or c.t["accent"]
    w = c.measure(txt, size, bold=True) + 18
    c.box(x, y - 9, w, 18, col, None, r=9)
    c.text(x + w / 2, y, txt, size, colour=c.t["bg"], bold=True, align="centerm")
    return w


# ==========================================================================
#  Figura 2 — verificación
# ==========================================================================
def fig_verif(t):
    W, H = 1240, 690
    c = Canvas(W, H, t)

    c.text(48, 54, "Verificación: nada entra sin oráculo", 26, bold=True)
    c.text(48, 82, "Un bloque que no se compara contra una referencia independiente "
                   "no está verificado, está ejecutado. Y el oráculo también se comprueba.",
           13.5, colour=t["muted"])

    # ---------------------------------------------------------- flujo
    c.box(48, 116, 1144, 270, t["plate"], t["line"], r=12)
    c.text(68, 142, "co-simulación diferencial", 12.5, colour=t["muted"], mono=True)

    block(c, 72, 212, 210, 96, "programa .S",
          ["sim/diff/tests/", "avr-gcc → .bin"], None, title_size=13.5)

    block(c, 354, 156, 250, 88, "simavr", ["núcleo AVR de terceros"], None)
    pill(c, 366, 174, "ORÁCULO", t["ok"])
    block(c, 354, 272, 250, 88, "RTL en Verilator", ["axioma_sim_top"], None,
          title_size=13)

    block(c, 676, 212, 214, 96, "comparador",
          ["tras cada instrucción", "retirada"], None, title_size=13.5)

    # panel de resultados: contenido alineado a la izquierda, no centrado,
    # porque son seis líneas y el centrado las desbordaba.
    px, py, pw, ph = 962, 156, 230, 204
    c.box(px, py, pw, ph, t["block"], t["line"], r=10)
    c.text(px + 20, py + 30, "qué se compara", 14, bold=True)
    c.set(t["line"]); c.cr.set_line_width(1)
    c.cr.move_to(px + 20, py + 44); c.cr.line_to(px + pw - 20, py + 44); c.cr.stroke()
    c.text(px + 20, py + 68, "PC · R0–R31 · SREG · SP", 11.5, colour=t["muted"])
    c.text(px + 20, py + 88, "ciclos contra el manual", 11.5, colour=t["muted"])
    c.cr.move_to(px + 20, py + 106); c.cr.line_to(px + pw - 20, py + 106); c.cr.stroke()
    c.text(px + 20, py + 130, "A la primera divergencia", 11.5, bold=True)
    c.text(px + 20, py + 150, "señala la instrucción", 11.5, colour=t["muted"])
    c.text(px + 20, py + 168, "exacta y el estado de", 11.5, colour=t["muted"])
    c.text(px + 20, py + 186, "los dos lados.", 11.5, colour=t["muted"])

    # ramas
    c.path([(288, 260), (318, 260), (318, 200), (348, 200)], colour=t["strong"])
    c.path([(288, 260), (318, 260), (318, 316), (348, 316)], colour=t["strong"])
    c.path([(610, 200), (640, 200), (640, 236), (670, 236)], colour=t["strong"])
    c.path([(610, 316), (640, 316), (640, 284), (670, 284)], colour=t["strong"])
    c.path([(896, 260), (956, 260)], colour=t["strong"])

    # ---------------------------------------------------------- oráculos
    c.text(48, 440, "Los cuatro oráculos", 17, bold=True)
    c.text(48, 464, "Ninguno comparte una línea de código ni de criterio con el RTL.",
           12.5, colour=t["muted"])

    cards = [
        ("ALU", "simavr", "0", "discrepancias",
         "22 282 240 vectores · 24 operaciones"),
        ("Decodificador", "avr-objdump (binutils)", "0", "discrepancias",
         "65 536 opcodes × 11 comprobaciones"),
        ("Ciclos — nivel L3", "tabla del manual del ISA", "0", "desviaciones",
         "60 000 ciclos · 51 de 97 mnemónicos"),
        ("El propio banco", "prueba de mutación", "63/63", "detectados",
         "fallos inyectados a propósito en el RTL"),
    ]
    cw, gap, cx0, cy0, ch = 274, 16, 48, 488, 150
    for i, (title, oracle, big, unit, scope) in enumerate(cards):
        x = cx0 + i * (cw + gap)
        c.box(x, cy0, cw, ch, t["block"], t["line"], r=10)
        c.text(x + 20, cy0 + 30, title, 15, bold=True)
        c.text(x + 20, cy0 + 52, "ORÁCULO", 9.5, colour=t["muted"], mono=True)
        c.text(x + 20, cy0 + 70, oracle, 12.5, colour=t["accent"], bold=True)
        c.set(t["line"]); c.cr.set_line_width(1)
        c.cr.move_to(x + 20, cy0 + 86); c.cr.line_to(x + cw - 20, cy0 + 86); c.cr.stroke()
        bw = c.measure(big, 26, bold=True)
        c.text(x + 20, cy0 + 120, big, 26, bold=True, colour=t["ok"])
        c.text(x + 28 + bw, cy0 + 120, unit, 13, colour=t["ink"])
        c.text(x + 20, cy0 + 140, scope, 11, colour=t["muted"])
    return c


# ==========================================================================
#  Figura 3 — espacio de datos
# ==========================================================================
def fig_dataspace(t):
    W, H = 1240, 540
    c = Canvas(W, H, t)

    c.text(48, 54, "Espacio de datos unificado", 26, bold=True)
    c.text(48, 82, "El AVR es Harvard —programa y datos en buses separados— pero el espacio "
                   "de datos es UNO SOLO, y los 32 registros forman parte de él.",
           13.5, colour=t["muted"])

    BX, BY, BW = 168, 132, 320
    bands = [("0x0000", "0x001F", "32 registros de propósito general", "R0 – R31", 66),
             ("0x0020", "0x005F", "64 registros de I/O estándar", "IN · OUT · LD · ST", 66),
             ("0x0060", "0x00FF", "160 de I/O extendida", "sólo LD · ST", 66),
             ("0x0100", "0x08FF", "2048 bytes de SRAM interna", "datos y pila", 122)]

    y = BY
    for i, (lo, hi, name, how, h) in enumerate(bands):
        c.box(BX, y, BW, h, t["block"], t["line"], r=6)
        c.text(BX - 16, y + 16, lo, 12, colour=t["muted"], mono=True, align="rightm")
        c.text(BX - 16, y + h - 16, hi, 12, colour=t["muted"], mono=True, align="rightm")
        badge(c, BX + 26, y + h / 2, str(i + 1))
        c.text(BX + 50, y + h / 2 - 9, name, 13.5, bold=True, align="leftm")
        c.text(BX + 50, y + h / 2 + 10, how, 11.5, colour=t["muted"], align="leftm")
        y += h
    c.text(BX + BW / 2, y + 22, "el mapa no está a escala", 11,
           colour=t["muted"], align="centerm")

    NX, NW = 560, 632
    notes = [
        (1, "`LD r16, X` con X = 0x0005 lee R5.",
         "No es una curiosidad: el código compilado real lo hace."),
        (2, "IN y OUT alcanzan sólo 0x00–0x3F del espacio de I/O.",
         "La dirección de dato es la de I/O más 0x20: PORTB es I/O 0x05 y dato 0x25."),
        (2, "CBI, SBI, SBIC y SBIS alcanzan sólo 0x00–0x1F.",
         "Un rango más estrecho todavía que el de IN y OUT."),
        (3, "La I/O extendida no es alcanzable con IN ni OUT.",
         "Sólo con LD y ST. Ahí viven los timers de 16 bits y la USART."),
        (4, "RAMEND = 0x08FF, y la pila crece hacia abajo desde ahí.",
         "El arranque de avr-gcc la monta con `out SPL,r28` / `out SPH,r29`."),
    ]
    ny = 140
    for num, head, sub in notes:
        badge(c, NX + 12, ny + 10, str(num), r=10)
        c.text(NX + 36, ny + 10, head.replace("`", ""), 13.5, bold=True, align="leftm")
        c.text(NX + 36, ny + 32, sub.replace("`", ""), 11.5, colour=t["muted"],
               align="leftm")
        ny += 62

    c.box(NX, ny + 4, NW, 74, t["partial_bg"], t["partial"], r=8)
    c.cr.save(); c.rrect(NX, ny + 4, NW, 74, 8); c.cr.clip()
    c.box(NX, ny + 4, 4, 74, t["partial"], None, r=0)
    c.cr.restore()
    c.text(NX + 24, ny + 30, "Tres direcciones no salen al bus", 13.5, bold=True)
    c.text(NX + 24, ny + 54,
           "0x5D SPL · 0x5E SPH · 0x5F SREG. Su estado vive dentro del núcleo, "
           "así que axioma_core las intercepta.", 11.5, colour=t["muted"])
    return c


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "images")
    out.mkdir(parents=True, exist_ok=True)
    figs = {"arquitectura": fig_soc, "verificacion": fig_verif,
            "espacio-datos": fig_dataspace}
    for name, theme in (("light", LIGHT), ("dark", DARK)):
        for base, fn in figs.items():
            fn(theme).save(str(out / f"{base}-{name}.png"))
    print(f"  escritas las figuras en {out}/")


if __name__ == "__main__":
    main()
