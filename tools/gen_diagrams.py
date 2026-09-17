#!/usr/bin/env python3
"""
Genera las figuras del README en tema claro y oscuro.

Uso:  python3 tools/gen_diagrams.py [directorio-de-salida]

POR QUÉ EL LIENZO MIDE 900 PX Y NO MÁS. La columna de contenido de un README en
github.com mide unos 896 px. El navegador encaja la imagen en ese ancho, sea
cual sea su tamaño real, así que lo único que decide si un texto se lee es la
proporción entre el cuerpo de la letra y el ANCHO del lienzo, no los píxeles.

Con un lienzo de 1240 px lógicos, un texto de 11,5 px acaba en 8,3 px en
pantalla: ilegible. Con 900 px lógicos, el mismo texto sale a 11,4 px, que sí
se lee. De ahí que estas figuras crezcan hacia abajo y no hacia los lados.

    tamaño en pantalla = cuerpo_lógico × 896 / ancho_lógico

Se renderiza a 2× para que quede nítido en pantallas de alta densidad.

Salida:
    images/arquitectura-{light,dark}.png
    images/verificacion-{light,dark}.png
    images/espacio-datos-{light,dark}.png
"""
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
from diagram_kit import Canvas, LIGHT, DARK   # noqa: E402

W = 900                     # ancho lógico; ver la nota de arriba
M = 28                      # margen exterior
IN_L, IN_R = 48, 852        # margen interior de la plancha
IN_W = IN_R - IN_L          # 804

OK, PARTIAL, TODO = "ok", "partial", "todo"

# Cuerpos de letra, en px lógicos. El mínimo es 11: por debajo de eso no se lee
# una vez que GitHub encaja la figura en su columna.
F_TITLE, F_SUB = 24, 12.5
F_H2, F_BLOCK, F_BODY, F_TINY = 16, 13, 11, 10.5


def sc(t, st):
    return t[st], t[st + "_bg"]


def block(c, x, y, w, h, title, lines=(), st=None,
          title_size=F_BLOCK, mono_title=True, r=7):
    """Bloque con barra de estado a la izquierda y texto centrado."""
    t = c.t
    fill = sc(t, st)[1] if st else t["block"]
    c.box(x, y, w, h, fill, t["line"], r=r)
    if st:
        c.cr.save()
        c.rrect(x, y, w, h, r)
        c.cr.clip()
        c.box(x, y, 3.5, h, sc(t, st)[0], None, r=0)
        c.cr.restore()

    cx = x + w / 2
    if lines:
        c.text(cx, y + h / 2 - len(lines) * 6.5, title, title_size,
               bold=True, mono=mono_title, align="centerm")
        for i, ln in enumerate(lines):
            c.text(cx, y + h / 2 + 11 + i * 13.5, ln, F_BODY,
                   colour=t["muted"], align="centerm")
    else:
        c.ctext(cx, y + h / 2, title, title_size, bold=True, mono=mono_title)


def bar(c, x, y, w, h, colour, r=7):
    """Barra de estado dentro de una caja ya dibujada."""
    c.cr.save()
    c.rrect(x, y, w, h, r)
    c.cr.clip()
    c.box(x, y, 3.5, h, colour, None, r=0)
    c.cr.restore()


def legend(c, x, y, items):
    cur = x
    for st, label in items:
        col, bg = sc(c.t, st)
        c.box(cur, y - 5.5, 11, 11, bg, col, r=3, lw=1.1)
        c.text(cur + 17, y, label, F_BODY, colour=c.t["muted"], align="leftm")
        cur += 17 + c.measure(label, F_BODY) + 20
    return cur


def rule(c, x1, y, x2):
    c.set(c.t["line"])
    c.cr.set_line_width(1)
    c.cr.move_to(x1, y)
    c.cr.line_to(x2, y)
    c.cr.stroke()


# ==========================================================================
#  Figura 1 — arquitectura del SoC
# ==========================================================================
def fig_soc(t):
    # LOS BLOQUES PRIMERO, Y LAS ALTURAS SALEN DE ELLOS. Estaban escritas a
    # mano, y el bloque numero trece -el TWI- empujo la rejilla fuera del panel
    # y encima de la tira de pines. Una figura que se rompe al añadir una fila
    # es una figura que se va a romper otra vez.
    cells = [("axioma_dmem", ["2 KB de SRAM · flanco de bajada"], OK),
             ("axioma_gpio", ["PORTB/C/D · toggle por PINx · anulación"], OK),
             ("axioma_gpior", ["GPIOR0/1/2 · almacenamiento puro"], OK),
             ("axioma_prescaler", ["10 bits · COMPARTIDO por timer0 y timer1"], OK),
             ("axioma_timer0", ["8 modos de onda · OC0A/OC0B · T0"], OK),
             ("axioma_timer1", ["16 bits · captura · TEMP compartido"], OK),
             ("axioma_timer2", ["prescaler propio · modo asíncrono"], OK),
             ("axioma_usart", ["asíncrono · síncrono · MPCM · SPI maestro"], OK),
             ("axioma_spi", ["maestro y esclavo · los cuatro modos"], OK),
             ("axioma_extint", ["INT0/1 · PCINT0/1/2"], OK),
             ("axioma_twi", ["maestro y esclavo · arbitraje · I2C"], OK),
             ("axioma_eeprom", ["1 KB · máquina de estados de EECR"], TODO),
             ("adc · ac · wdt", ["SAR · comparador · perro guardián"], TODO)]
    FILAS = (len(cells) + 2) // 3
    GY = 510
    GH = 32 + FILAS * 74 - 12 + 14
    PIN_Y, PIN_H = GY + GH + 14, 36
    PY, PH = 88, PIN_Y + PIN_H + 16 - 88
    LEG_Y = PY + PH + 24
    H = LEG_Y + 22
    c = Canvas(W, H, t)

    c.text(M, 42, "Arquitectura de AxiomaCore-328", F_TITLE, bold=True)
    c.text(M, 66, "Núcleo AVR de 8 bits · pipeline de 2 etapas · espacio de datos "
                  "unificado · memorias con backend intercambiable",
           F_SUB, colour=t["muted"])

    # ---- plancha del SoC ----
    c.box(M, PY, W - 2 * M, PH, t["plate"], t["line_strong"], r=10, lw=1.6)
    c.text(M + 16, PY + 22, "axioma328_soc", 11.5, colour=t["muted"], mono=True)

    # ---- núcleo ----
    CY, CH = 122, 170
    c.box(IN_L, CY, IN_W, CH, t["panel"], t["line"], r=8)
    c.text(IN_L + 14, CY + 21, "axioma_core", 11.5, colour=t["muted"], mono=True)

    ix, iw = IN_L + 16, IN_W - 32                    # 64 .. 836
    block(c, ix, CY + 32, (iw - 12) / 2, 58, "axioma_decode",
          ["combinacional · 65 536 opcodes"], OK)
    block(c, ix + (iw - 12) / 2 + 12, CY + 32, (iw - 12) / 2, 58, "axioma_seq",
          ["secuenciador multiciclo"], OK)
    bw = (iw - 24) / 3
    for i, (nm, sub) in enumerate([("axioma_regfile", "32 × 8 · par de 16 bits"),
                                   ("axioma_alu", "combinacional pura"),
                                   ("axioma_sreg", "I T H S V N Z C")]):
        block(c, ix + i * (bw + 12), CY + 102, bw, 58, nm, [sub], OK,
              title_size=12.5)

    # ---- memoria de programa, reloj e interrupciones ----
    RY, RH = 316, 100
    block(c, IN_L, RY, 420, RH, "axioma_progmem",
          ["16K × 16 bits · 32 KB · puerto IF y puerto LPM/SPM",
           "memoria inferida: simulación y BRAM · Sky130 en la fase 6"], OK)
    block(c, 492, RY, 174, RH, "axioma_clkctrl",
          ["CLKPR · PRR", "SMCR"], TODO, title_size=12.5)
    block(c, 678, RY, 174, RH, "axioma_irq",
          ["26 vectores", "irq_req / irq_ack"], OK, title_size=12.5)

    c.path([(IN_L + 210, CY + CH + 4), (IN_L + 210, RY - 5)],
           head="both", colour=t["strong"])
    c.path([(765, RY - 5), (765, CY + CH + 4)], colour=t["strong"])

    # ---- bus de datos ----
    BY, BH = 430, 54
    c.box(IN_L, BY, IN_W, BH, t["ok_bg"], t["ok"], r=7)
    bar(c, IN_L, BY, IN_W, BH, t["ok"])
    c.text(IN_L + 20, BY + BH / 2 - 8, "axioma_dbus", F_BLOCK, bold=True, mono=True,
           align="leftm")
    c.text(IN_L + 20, BY + BH / 2 + 10,
           "0x0000–0x001F registros · 0x0020–0x005F I/O · "
           "0x0060–0x00FF I/O extendida · 0x0100–0x08FF SRAM",
           F_BODY, colour=t["muted"], align="leftm")
    # El núcleo baja al bus por el carril libre entre progmem y la columna
    # derecha, para no cruzar por encima de ningún bloque.
    c.path([(480, CY + CH + 4), (480, BY - 5)], colour=t["strong"])

    # ---- lo que cuelga del bus ----
    c.box(IN_L, GY, IN_W, GH, t["panel"], t["line"], r=8)
    c.text(IN_L + 14, GY + 21, "en el espacio de datos", 11.5, colour=t["muted"],
           mono=True)
    nota = "timer0 y timer2 comparten axioma_timer8, el motor de onda de 8 bits"
    c.text(IN_L + IN_W - 14 - c.measure(nota, 10.5, mono=True), GY + 21,
           nota, 10.5, colour=t["muted"], mono=True)
    c.path([(450, BY + BH + 4), (450, GY - 5)], colour=t["strong"])

    gw = (IN_W - 32 - 24) / 3
    for i, (nm, sub, st) in enumerate(cells):
        gx = IN_L + 16 + (i % 3) * (gw + 12)
        gy = GY + 32 + (i // 3) * 74
        block(c, gx, gy, gw, 62, nm, sub, st, title_size=12)

    # ---- pines ----
    py, ph = PIN_Y, PIN_H
    c.box(IN_L, py, IN_W, ph, t["panel"], t["line"], r=7, dash=[5, 3])
    c.text(IN_L + 20, py + ph / 2, "pines", 11, colour=t["muted"], mono=True,
           align="leftm")
    c.text(IN_L + IN_W / 2 + 26, py + ph / 2,
           "PB[7:0]    PC[6:0]    PD[7:0]    ADC[7:0]    XTAL    RESET",
           11, colour=t["muted"], mono=True, align="centerm")

    # La leyenda sólo lista los estados que la figura USA. Ahora mismo no hay
    # ningún bloque a medio verificar; el día que lo haya, PARTIAL vuelve aquí.
    legend(c, M, LEG_Y, [(OK, "verificado contra un oráculo independiente"),
                       (TODO, "pendiente — fase 3 en adelante")])
    return c


# ==========================================================================
#  Figura 2 — verificación
# ==========================================================================
def pill(c, x, y, txt, colour=None, size=9):
    col = colour or c.t["accent"]
    w = c.measure(txt, size, bold=True) + 14
    c.box(x, y - 8, w, 16, col, None, r=8)
    c.text(x + w / 2, y, txt, size, colour=c.t["chip_ink"], bold=True, align="centerm")
    return w


def fig_verif(t):
    H = 740
    c = Canvas(W, H, t)

    c.text(M, 42, "Verificación: nada entra sin oráculo", F_TITLE, bold=True)
    c.text(M, 66, "Un bloque que no se compara contra una referencia independiente "
                  "no está verificado, está ejecutado.", F_SUB, colour=t["muted"])
    c.text(M, 84, "Y el oráculo también se comprueba.", F_SUB, colour=t["muted"])

    # ---------------------------------------------------------- flujo
    PY, PH = 106, 272
    c.box(M, PY, W - 2 * M, PH, t["plate"], t["line_strong"], r=10, lw=1.6)
    c.text(M + 16, PY + 22, "co-simulación diferencial", 11.5, colour=t["muted"],
           mono=True)

    block(c, IN_L, 176, 190, 72, "programa .S",
          ["sim/diff/tests/", "avr-gcc → .bin"], None, title_size=12.5)

    block(c, 306, 142, 236, 66, "simavr", ["núcleo AVR de terceros"], None)
    pill(c, 318, 158, "ORÁCULO", t["ok"])
    block(c, 306, 218, 236, 66, "RTL en Verilator", ["axioma_sim_top"], None,
          title_size=12.5)

    block(c, 616, 176, 236, 72, "comparador",
          ["tras cada instrucción retirada"], None, title_size=12.5)

    c.path([(244, 212), (272, 212), (272, 175), (300, 175)], colour=t["strong"])
    c.path([(244, 212), (272, 212), (272, 251), (300, 251)], colour=t["strong"])
    c.path([(548, 175), (578, 175), (578, 212), (610, 212)], colour=t["strong"])
    c.path([(548, 251), (578, 251), (578, 212)], head=None, colour=t["strong"])

    c.box(IN_L, 296, IN_W, 76, t["block"], t["line"], r=7)
    c.text(IN_L + 20, 318, "Qué se compara", 12.5, bold=True)
    c.text(IN_L + 20, 338, "PC · R0–R31 · SREG · SP y los ciclos, tras cada "
                           "instrucción retirada; la SRAM entera al terminar.",
           F_BODY, colour=t["muted"])
    c.text(IN_L + 20, 356, "A la primera divergencia: la instrucción exacta y el "
                           "estado de los dos lados.",
           F_BODY, colour=t["muted"])

    # ---------------------------------------------------------- oráculos
    c.text(M, 412, "Los cuatro oráculos", F_H2, bold=True)
    c.text(M, 434, "Ninguno comparte una línea de código ni de criterio con el RTL.",
           F_SUB, colour=t["muted"])

    cards = [
        ("ALU", "simavr", "0", "discrepancias",
         "22 282 240 vectores · 24 operaciones"),
        ("Decodificador", "avr-objdump (binutils)", "0", "discrepancias",
         "65 536 opcodes × 11 comprobaciones"),
        ("Ciclos — nivel L3", "tabla del manual del ISA", "0", "desviaciones",
         "300 048 instrucciones · 97 de 97 mnemónicos"),
        ("El propio banco", "prueba de mutación", "221/221", "detectados",
         "fallos inyectados a propósito en el RTL"),
    ]
    cw, ch = (IN_W - 12) / 2, 128
    for i, (title, oracle, big, unit, scope) in enumerate(cards):
        x = IN_L + (i % 2) * (cw + 12)
        y = 452 + (i // 2) * (ch + 12)
        c.box(x, y, cw, ch, t["block"], t["line"], r=8)
        c.text(x + 18, y + 26, title, 14, bold=True)
        c.text(x + 18, y + 46, "ORÁCULO", 8.5, colour=t["muted"], mono=True)
        c.text(x + 18, y + 62, oracle, 12, colour=t["accent"], bold=True)
        rule(c, x + 18, y + 76, x + cw - 18)
        bwid = c.measure(big, 22, bold=True)
        c.text(x + 18, y + 102, big, 22, bold=True, colour=t["ok"])
        c.text(x + 25 + bwid, y + 102, unit, 12, colour=t["ink"])
        c.text(x + 18, y + 120, scope, F_BODY, colour=t["muted"])
    return c


# ==========================================================================
#  Figura 3 — espacio de datos
# ==========================================================================
def badge(c, cx, cy, txt, r=9):
    c.set(c.t["accent"])
    c.cr.arc(cx, cy, r, 0, 6.2832)
    c.cr.fill()
    c.ctext(cx, cy, txt, 10.5, colour=c.t["chip_ink"], bold=True)


def fig_dataspace(t):
    H = 510
    c = Canvas(W, H, t)

    c.text(M, 42, "Espacio de datos unificado", F_TITLE, bold=True)
    c.text(M, 66, "El AVR es Harvard —programa y datos en buses separados— pero el "
                  "espacio de datos es UNO SOLO,", F_SUB, colour=t["muted"])
    c.text(M, 84, "y los 32 registros forman parte de él.", F_SUB, colour=t["muted"])

    BX, BY, BW = 106, 116, 236
    bands = [("0x0000", "0x001F", "32 registros", "R0 – R31", 60),
             ("0x0020", "0x005F", "64 de I/O estándar", "IN · OUT · LD · ST", 60),
             ("0x0060", "0x00FF", "160 de I/O extendida", "sólo LD · ST", 60),
             ("0x0100", "0x08FF", "2048 bytes de SRAM", "datos y pila", 108)]

    y = BY
    for i, (lo, hi, name, how, h) in enumerate(bands):
        c.box(BX, y, BW, h, t["block"], t["line"], r=5)
        c.text(BX - 12, y + 15, lo, 11, colour=t["muted"], mono=True, align="rightm")
        c.text(BX - 12, y + h - 15, hi, 11, colour=t["muted"], mono=True,
               align="rightm")
        badge(c, BX + 22, y + h / 2, str(i + 1))
        c.text(BX + 42, y + h / 2 - 8, name, 12.5, bold=True, align="leftm")
        c.text(BX + 42, y + h / 2 + 9, how, F_BODY, colour=t["muted"], align="leftm")
        y += h
    c.text(BX + BW / 2, y + 20, "el mapa no está a escala", F_TINY,
           colour=t["muted"], align="centerm")

    NX, NW = 380, 472
    notes = [
        (1, "LD r16, X con X = 0x0005 lee R5.",
         "No es una curiosidad: el código compilado real lo hace."),
        (2, "IN y OUT alcanzan sólo 0x00–0x3F de la I/O.",
         "La dirección de dato es la de I/O más 0x20: PORTB es I/O 0x05 y dato 0x25."),
        (2, "CBI, SBI, SBIC y SBIS sólo llegan a 0x00–0x1F.",
         "Un rango más estrecho todavía que el de IN y OUT."),
        (3, "La I/O extendida no se alcanza con IN ni OUT.",
         "Sólo con LD y ST. Ahí viven los timers de 16 bits y la USART."),
        (4, "RAMEND = 0x08FF; la pila crece hacia abajo.",
         "El arranque de avr-gcc la monta con out SPL,r28 / out SPH,r29."),
    ]
    ny = 128
    for num, head, sub in notes:
        badge(c, NX + 10, ny + 8, str(num))
        c.text(NX + 30, ny + 8, head, 12.5, bold=True, align="leftm")
        c.text(NX + 30, ny + 28, sub, F_BODY, colour=t["muted"], align="leftm")
        ny += 56

    cy, chh = ny + 6, 66
    c.box(NX, cy, NW, chh, t["partial_bg"], t["partial"], r=7)
    bar(c, NX, cy, NW, chh, t["partial"])
    c.text(NX + 20, cy + 24, "Tres direcciones no salen al bus", 12.5, bold=True)
    c.text(NX + 20, cy + 44, "0x5D SPL · 0x5E SPH · 0x5F SREG. Su estado vive dentro",
           F_BODY, colour=t["muted"])
    c.text(NX + 20, cy + 58, "del núcleo, así que axioma_core las intercepta.",
           F_BODY, colour=t["muted"])
    return c


def main():
    out = Path(sys.argv[1] if len(sys.argv) > 1 else "images")
    out.mkdir(parents=True, exist_ok=True)
    figs = {"arquitectura": fig_soc, "verificacion": fig_verif,
            "espacio-datos": fig_dataspace}
    for name, theme in (("light", LIGHT), ("dark", DARK)):
        for base, fn in figs.items():
            fn(theme).save(str(out / f"{base}-{name}.png"))
    px = 896 / W
    print(f"  figuras escritas en {out}/")
    print(f"  lienzo de {W} px lógicos: un texto de {F_BODY} px se verá a "
          f"{F_BODY * px:.1f} px en la columna de GitHub")


if __name__ == "__main__":
    main()
