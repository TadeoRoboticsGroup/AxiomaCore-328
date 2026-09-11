#!/usr/bin/env python3
"""
Utilidades de dibujo para los diagramas del proyecto.

Los diagramas se GENERAN, no se dibujan a mano, por la misma razón que el mapa
de registros: una figura hecha a mano se desincroniza del diseño y nadie se
entera. `tools/gen_diagrams.py` los produce; este módulo es la caja de
herramientas.

Todo se traza sobre una rejilla de 4 px lógicos y se renderiza a 2× para que se
vea nítido en pantallas de alta densidad.
"""
import math

import cairo

SCALE = 2.0                      # factor de render (2× = nítido en HiDPI)

SANS = "DejaVu Sans"
MONO = "DejaVu Sans Mono"

# --------------------------------------------------------------------------
# Paletas. La clara sigue la de GitHub en tema claro; la oscura, la de su tema
# oscuro, para que los diagramas no se vean como un parche encendido.
# --------------------------------------------------------------------------
LIGHT = dict(
    # RELLENOS TRANSLÚCIDOS, no colores planos. Cada capa es un LAVADO sobre lo
    # que haya debajo —la página—, no un rectángulo que la tape: la placa
    # oscurece un punto, el panel aclara, y el tinte de estado apenas tiñe. Así
    # la figura conserva su jerarquía visual sobre cualquier color de página, y
    # no sólo sobre el blanco exacto que suponía la paleta.
    #
    # El orden importa y los alfas se multiplican: tinte de estado sobre panel
    # sobre placa sobre página. Los valores están elegidos para que la suma dé
    # aproximadamente los colores planos de GitHub en tema claro, que es donde
    # se ve el README la mayoría de las veces.
    plate="#1f23280a", panel="#ffffffb3", block="#ffffffb3",
    ok_bg="#1a7f371a", partial_bg="#9a67001a", todo_bg="#1f232811",
    # El borde también es translúcido: uno opaco se vería como una línea ajena
    # en cuanto la página no fuera del color previsto.
    line="#1f23282e",
    # Tintas y trazos: OPACOS. Son lo que hay que leer.
    ink="#1f2328", muted="#59636e", strong="#8c959f",
    ok="#1a7f37", partial="#9a6700", todo="#818b98",
    accent="#0969da",
    # Color del texto que va ENCIMA de una etiqueta de color —la píldora
    # «ORÁCULO», los círculos numerados—. No es el fondo del lienzo: es la tinta
    # que contrasta con un relleno saturado, y por eso es opaca.
    chip_ink="#ffffff",
)
DARK = dict(
    plate="#ffffff0d", panel="#00000040", block="#00000040",
    ok_bg="#3fb95024", partial_bg="#d2992224", todo_bg="#ffffff0f",
    line="#ffffff30",
    ink="#e6edf3", muted="#9198a1", strong="#6e7681",
    ok="#3fb950", partial="#d29922", todo="#6e7681",
    accent="#4493f8",
    chip_ink="#0d1117",
)


def hex2rgba(h):
    h = h.lstrip("#")
    if len(h) == 8:
        return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255,
                int(h[4:6], 16) / 255, int(h[6:8], 16) / 255)
    return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, 1.0)


class Canvas:
    # EL FONDO ES TRANSPARENTE, y es una decisión, no un descuido. La superficie
    # es ARGB32 y se deja SIN PINTAR: así el PNG no lleva un rectángulo opaco
    # debajo y la figura se posa sobre el color de la página que la muestre, sea
    # el blanco de GitHub, el de una diapositiva o el de un lector con su propio
    # tema. Pintar el fondo del tema no arreglaba nada y estropeaba el caso en el
    # que el color de la página no es exactamente el que supone la paleta: se
    # veía el borde del rectángulo.
    #
    # Lo que SÍ sigue pintado es la placa y las tarjetas de dentro. Son
    # elementos del diseño —el contraste entre la placa gris y los bloques
    # blancos es lo que agrupa visualmente el diagrama—, no relleno de fondo.
    #
    # NO HAY color de fondo en la paleta, y es a propósito: el fondo es la
    # página. Lo que antes lo hacía —`bg`— se ha partido en dos cosas que no
    # eran la misma: `panel`, un lavado translúcido para los bloques que deben
    # parecer recortados sobre la placa, y `chip_ink`, la tinta opaca del texto
    # que va encima de una etiqueta de color.
    #
    # Quien quiera el rectángulo opaco de vuelta, que pase un color en `fondo`.
    def __init__(self, w, h, theme, fondo=None):
        self.w, self.h, self.t = w, h, theme
        self.surface = cairo.ImageSurface(cairo.FORMAT_ARGB32,
                                          int(w * SCALE), int(h * SCALE))
        self.cr = cairo.Context(self.surface)
        self.cr.scale(SCALE, SCALE)
        self.cr.set_antialias(cairo.ANTIALIAS_BEST)
        self.cr.set_line_join(cairo.LINE_JOIN_ROUND)
        self.cr.set_line_cap(cairo.LINE_CAP_ROUND)
        if fondo:
            self.set(fondo)
            self.cr.paint()

    # ---------------------------------------------------------------- básico
    def set(self, colour):
        self.cr.set_source_rgba(*hex2rgba(colour))

    def rrect(self, x, y, w, h, r=8):
        cr = self.cr
        cr.new_sub_path()
        cr.arc(x + w - r, y + r, r, -math.pi / 2, 0)
        cr.arc(x + w - r, y + h - r, r, 0, math.pi / 2)
        cr.arc(x + r, y + h - r, r, math.pi / 2, math.pi)
        cr.arc(x + r, y + r, r, math.pi, 3 * math.pi / 2)
        cr.close_path()

    def box(self, x, y, w, h, fill=None, stroke=None, r=8, lw=1.25, dash=None):
        self.rrect(x, y, w, h, r)
        if fill:
            self.set(fill)
            self.cr.fill_preserve()
        if stroke:
            self.set(stroke)
            self.cr.set_line_width(lw)
            self.cr.set_dash(dash or [])
            self.cr.stroke()
            self.cr.set_dash([])
        else:
            self.cr.new_path()

    # ----------------------------------------------------------------- texto
    def font(self, size, bold=False, mono=False):
        self.cr.select_font_face(
            MONO if mono else SANS, cairo.FONT_SLANT_NORMAL,
            cairo.FONT_WEIGHT_BOLD if bold else cairo.FONT_WEIGHT_NORMAL)
        self.cr.set_font_size(size)

    def measure(self, s, size, bold=False, mono=False):
        self.font(size, bold, mono)
        e = self.cr.text_extents(s)
        return e.x_advance

    def text(self, x, y, s, size=13, colour=None, bold=False, mono=False,
             align="left"):
        """y es la LÍNEA BASE cuando align no lleva 'm'; con 'm' se centra
        verticalmente sobre y."""
        self.font(size, bold, mono)
        e = self.cr.text_extents(s)
        ax = {"left": 0, "center": -e.x_advance / 2, "right": -e.x_advance}[
            align.replace("m", "") or "left"]
        ay = 0.0
        if "m" in align:
            ay = (self.cr.font_extents()[0] - self.cr.font_extents()[1]) / 2
        self.set(colour or self.t["ink"])
        self.cr.move_to(x + ax, y + ay)
        self.cr.show_text(s)

    def ctext(self, cx, cy, s, size=13, **kw):
        """Centrado en horizontal y en vertical sobre (cx, cy)."""
        self.text(cx, cy, s, size, align="centerm", **kw)

    # ---------------------------------------------------------------- flechas
    def arrow_head(self, x, y, ang, size=6.5, colour=None):
        cr = self.cr
        self.set(colour or self.t["strong"])
        cr.save()
        cr.translate(x, y)
        cr.rotate(ang)
        cr.move_to(0, 0)
        cr.line_to(-size, size * 0.45)
        cr.line_to(-size, -size * 0.45)
        cr.close_path()
        cr.fill()
        cr.restore()

    def path(self, pts, colour=None, lw=1.4, head="end", dash=None):
        """Polilínea con punta. `pts` en coordenadas lógicas."""
        cr = self.cr
        self.set(colour or self.t["strong"])
        cr.set_line_width(lw)
        cr.set_dash(dash or [])
        cr.move_to(*pts[0])
        for p in pts[1:]:
            cr.line_to(*p)
        cr.stroke()
        cr.set_dash([])
        if head in ("end", "both"):
            (x0, y0), (x1, y1) = pts[-2], pts[-1]
            self.arrow_head(x1, y1, math.atan2(y1 - y0, x1 - x0), colour=colour)
        if head in ("start", "both"):
            (x0, y0), (x1, y1) = pts[1], pts[0]
            self.arrow_head(x1, y1, math.atan2(y1 - y0, x1 - x0), colour=colour)

    # ------------------------------------------------------------------ save
    def save(self, path):
        self.surface.write_to_png(path)
