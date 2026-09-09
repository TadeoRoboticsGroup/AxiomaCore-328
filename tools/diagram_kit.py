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
    bg="#ffffff", plate="#f6f8fa", block="#ffffff", ink="#1f2328",
    muted="#59636e", line="#d1d9e0", strong="#8c959f",
    ok="#1a7f37", partial="#9a6700", todo="#818b98",
    ok_bg="#eaf6ec", partial_bg="#fdf5e3", todo_bg="#f2f4f7",
    accent="#0969da", shadow="#00000010",
)
DARK = dict(
    bg="#0d1117", plate="#161b22", block="#11161d", ink="#e6edf3",
    muted="#9198a1", line="#30363d", strong="#6e7681",
    ok="#3fb950", partial="#d29922", todo="#6e7681",
    ok_bg="#12251a", partial_bg="#241c0d", todo_bg="#1b2129",
    accent="#4493f8", shadow="#00000000",
)


def hex2rgba(h):
    h = h.lstrip("#")
    if len(h) == 8:
        return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255,
                int(h[4:6], 16) / 255, int(h[6:8], 16) / 255)
    return (int(h[0:2], 16) / 255, int(h[2:4], 16) / 255, int(h[4:6], 16) / 255, 1.0)


class Canvas:
    def __init__(self, w, h, theme):
        self.w, self.h, self.t = w, h, theme
        self.surface = cairo.ImageSurface(cairo.FORMAT_ARGB32,
                                          int(w * SCALE), int(h * SCALE))
        self.cr = cairo.Context(self.surface)
        self.cr.scale(SCALE, SCALE)
        self.cr.set_antialias(cairo.ANTIALIAS_BEST)
        self.cr.set_line_join(cairo.LINE_JOIN_ROUND)
        self.cr.set_line_cap(cairo.LINE_CAP_ROUND)
        self.set(theme["bg"])
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
