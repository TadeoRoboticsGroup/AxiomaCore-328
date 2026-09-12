// AxiomaCore-328 - Timer1 contra un modelo de la hoja de datos
// SPDX-License-Identifier: Apache-2.0
//
// LO QUE SÓLO PUEDE COMPROBAR ESTE BANCO. simavr no modela EL REGISTRO TEMP:
// escribe los dos bytes por su cuenta (`avr->data[r_tcnth] = tcnt >> 8`). Y el
// TEMP es la trampa nº 4 entera — el acceso de 16 bits por un bus de 8 —, de la
// que dependen `micros()`, `Servo` y cualquier medida de tiempo fina.
//
// Que sea UNO SOLO y COMPARTIDO entre TCNT1, ICR1, OCR1A y OCR1B es lo que
// hace que una interrupción a mitad de un acceso corrompa el otro registro.
// Modelarlo con dos mitades independientes da un chip que pasa la simulación y
// falla con código real, que es exactamente lo que este banco impide.
//
// El modelo de abajo está escrito desde la hoja de datos: los dieciséis modos,
// cuándo se refresca el doble búfer en cada familia, la captura con su
// cancelador de ruido de cuatro muestras, y el TEMP con su orden de acceso.

#include "Vtb_timer1_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>

static Vtb_timer1_top *dut;
static int  fails = 0;
static long checks = 0;
static const char *fase = "";

static void chk(const char *que, uint32_t got, uint32_t exp, long t) {
    checks++;
    if (got != exp && ++fails <= 15)
        printf("    FALLA [%s] %-28s t=%ld obtenido=0x%04X esperado=0x%04X\n",
               fase, que, t, got, exp);
}

enum { A_TIFR1 = 0x16, A_TIMSK1 = 0x4F, A_TCCR1A = 0x60, A_TCCR1B = 0x61,
       A_TCCR1C = 0x62, A_TCNT1L = 0x64, A_TCNT1H = 0x65, A_ICR1L = 0x66,
       A_ICR1H = 0x67, A_OCR1AL = 0x68, A_OCR1AH = 0x69, A_OCR1BL = 0x6A,
       A_OCR1BH = 0x6B };

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

// Ventana del banco: no levanta io_re, así que NO dispara la captura de TEMP.
static uint8_t peek(uint8_t a) {
    dut->io_addr = a; dut->io_re = 0; dut->io_we = 0; dut->eval();
    return dut->io_rdata;
}

// Lectura como la de un programa: io_re alto un ciclo. Sobre el byte BAJO de
// cualquiera de los cuatro de 16 bits, esto CAPTURA el alto en TEMP.
static uint8_t rd(uint8_t a) {
    dut->io_addr = a; dut->io_re = 1; dut->io_we = 0; dut->eval();
    uint8_t v = dut->io_rdata;
    tick();
    dut->io_re = 0; dut->eval();
    return v;
}

static void wr(uint8_t a, uint8_t d) {
    dut->io_addr = a; dut->io_wdata = d; dut->io_we = 1; dut->io_re = 0;
    dut->eval();
    tick();
    dut->io_we = 0; dut->eval();
}

static void run(int n) { for (int i = 0; i < n; i++) tick(); }

// Los dos accesos de 16 bits, en el orden que manda la hoja de datos.
static void wr16(uint8_t lo, uint8_t hi, uint16_t v) { wr(hi, v >> 8); wr(lo, v & 0xFF); }
static uint16_t rd16(uint8_t lo, uint8_t hi) {
    uint8_t l = rd(lo);            // captura el alto en TEMP
    uint8_t h = rd(hi);            // devuelve TEMP
    return (uint16_t)(l | (h << 8));
}

// --------------------------------------------------------------- modelo
struct Model {
    uint16_t presc = 0;
    bool tsm = false, psrasy = false, psrsync = false;

    uint8_t  com = 0, wgm = 0, cs = 0;
    bool     icnc = false, ices = false;
    uint16_t tcnt = 0, ocra_act = 0, ocra_buf = 0, ocrb_act = 0, ocrb_buf = 0;
    uint16_t icr = 0;
    uint8_t  timsk = 0; bool icie = false;
    uint8_t  tifr = 0;  bool icf = false;
    bool     dir_down = false, tcnt_block = false;
    bool     oc1a = false, oc1b = false;
    uint8_t  temp = 0;
    uint8_t  t1s = 0;
    uint8_t  icps = 0;  bool icp_limpio = false, icp_prev = false;

    bool pc()   const { return wgm==1||wgm==2||wgm==3||wgm==10||wgm==11; }
    bool pfc()  const { return wgm==8||wgm==9; }
    bool fast() const { return wgm==5||wgm==6||wgm==7||wgm==14||wgm==15; }
    bool pwm()  const { return pc()||pfc()||fast(); }
    bool ad()   const { return pc()||pfc(); }
    uint16_t top() const {
        switch (wgm) {
        case 1: case 5:  return 0x00FF;
        case 2: case 6:  return 0x01FF;
        case 3: case 7:  return 0x03FF;
        case 4: case 9: case 11: case 15: return ocra_act;
        case 8: case 10: case 12: case 14: return icr;
        default: return 0xFFFF;
        }
    }
    uint8_t com_a() const { return (com >> 2) & 3; }
    uint8_t com_b() const { return com & 3; }
    bool oc1a_en() const { return com_a() != 0; }
    bool oc1b_en() const { return com_b() != 0 && !(pwm() && com_b() == 1); }

    uint8_t read(uint8_t a) const {
        switch (a) {
        case A_TIFR1:  return (uint8_t)((icf << 5) | (tifr & 7));
        case A_TIMSK1: return (uint8_t)((icie << 5) | (timsk & 7));
        case A_TCCR1A: return (uint8_t)((com << 4) | (wgm & 3));
        case A_TCCR1B: return (uint8_t)((icnc << 7) | (ices << 6) |
                                        ((wgm & 8) ? 0x10 : 0) | ((wgm & 4) ? 0x08 : 0) | cs);
        case A_TCCR1C: return 0x00;
        case A_TCNT1L: return (uint8_t)(tcnt & 0xFF);
        case A_ICR1L:  return (uint8_t)(icr & 0xFF);
        case A_OCR1AL: return (uint8_t)(ocra_buf & 0xFF);
        case A_OCR1BL: return (uint8_t)(ocrb_buf & 0xFF);
        case A_TCNT1H: case A_ICR1H: case A_OCR1AH: case A_OCR1BH: return temp;
        default: return 0;
        }
    }

    void cycle(bool we, bool re, uint8_t a, uint8_t d, bool t1, bool icp,
               bool ack_capt, bool ack_a, bool ack_b, bool ack_ovf) {
        bool psr_now = psrsync;
        bool tk[6] = { false, true,
                       ((presc & 0x007) == 0x007) && !psr_now,
                       ((presc & 0x03F) == 0x03F) && !psr_now,
                       ((presc & 0x0FF) == 0x0FF) && !psr_now,
                       ((presc & 0x3FF) == 0x3FF) && !psr_now };
        bool rise = ((t1s >> 1) & 3) == 1;
        bool fall = ((t1s >> 1) & 3) == 2;
        bool ck = (cs == 0) ? false : (cs <= 5) ? tk[cs] : (cs == 6 ? fall : rise);

        bool at_top = (tcnt == top());
        bool at_max = (tcnt == 0xFFFF);
        bool at_bot = (tcnt == 0x0000);

        bool ev_tov   = ck && (ad() ? (dir_down && at_bot) : fast() ? at_top : at_max);
        bool ev_compa = ck && !tcnt_block && (tcnt == ocra_act);
        bool ev_compb = ck && !tcnt_block && (tcnt == ocrb_act);
        bool ev_upd   = ck && (pc() ? at_top : pfc() ? (dir_down && at_bot)
                                     : fast() ? at_top : false);
        bool dir_prev = dir_down;
        // La captura se lleva el valor que el contador tiene DURANTE este
        // ciclo, no el que deja al salir: en el RTL las dos cosas pasan en el
        // mismo flanco con asignación no bloqueante. Aquí, con asignación
        // bloqueante, hay que guardarlo antes. Es el mismo error que cometí en
        // el modelo del Timer0 con el sentido de la cuenta.
        uint16_t tcnt_prev = tcnt;
        uint16_t icr_prev = icr, ocra_buf_prev = ocra_buf, ocrb_buf_prev = ocrb_buf;

        if (ck) {
            if (ad()) {
                if (dir_down) {
                    if (at_bot) { dir_down = false; tcnt = (top() == 0) ? 0 : 1; }
                    else          tcnt--;
                } else {
                    if (at_top) { dir_down = true; tcnt = (top() == 0) ? 0 : (uint16_t)(tcnt - 1); }
                    else          tcnt++;
                }
            } else {
                tcnt = at_top ? 0 : (uint16_t)(tcnt + 1);
            }
            tcnt_block = false;
        }
        if (ev_upd) { ocra_act = ocra_buf; ocrb_act = ocrb_buf; }

        // --- captura, con su cancelador de cuatro muestras ---
        // El cancelador mira las CUATRO muestras que ya están registradas, no
        // la que entra en este flanco: en el RTL `cuatro_altas` sale de
        // `icp_sync` antes de desplazarlo. Calcularlo con el valor nuevo
        // adelanta la captura un ciclo entero.
        uint8_t icps_n = (uint8_t)(((icps << 1) | (icp ? 1 : 0)) & 0xF);
        bool limpio_n = icp_limpio;
        if ((icps & 0xF) == 0xF) limpio_n = true;
        if ((icps & 0xF) == 0x0) limpio_n = false;
        bool filtrado = icnc ? icp_limpio : ((icps >> 1) & 1);
        if (filtrado != icp_prev && filtrado == ices) { icr = tcnt_prev; icf = true; }
        else if (ack_capt || (we && a == A_TIFR1 && (d & 0x20))) icf = false;
        icp_prev = filtrado;
        icps = icps_n; icp_limpio = limpio_n;

        // --- pines ---
        bool foc_a = we && a == A_TCCR1C && (d & 0x80) && !pwm();
        bool foc_b = we && a == A_TCCR1C && (d & 0x40) && !pwm();
        if (!pwm()) {
            if (ev_compa || foc_a) {
                if      (com_a() == 1) oc1a = !oc1a;
                else if (com_a() == 2) oc1a = false;
                else if (com_a() == 3) oc1a = true;
            }
            if (ev_compb || foc_b) {
                if      (com_b() == 1) oc1b = !oc1b;
                else if (com_b() == 2) oc1b = false;
                else if (com_b() == 3) oc1b = true;
            }
        } else if (fast()) {
            if (ck && at_top) {
                if (com_a() == 2) oc1a = true;
                if (com_a() == 3) oc1a = false;
                if (com_b() == 2) oc1b = true;
                if (com_b() == 3) oc1b = false;
            } else {
                if (ev_compa) {
                    if      (com_a() == 1) oc1a = !oc1a;
                    else if (com_a() == 2) oc1a = false;
                    else if (com_a() == 3) oc1a = true;
                }
                if (ev_compb) {
                    if      (com_b() == 2) oc1b = false;
                    else if (com_b() == 3) oc1b = true;
                }
            }
        } else {
            if (ev_compa) {
                if      (com_a() == 1) oc1a = !oc1a;
                else if (com_a() == 2) oc1a = dir_prev;
                else if (com_a() == 3) oc1a = !dir_prev;
            }
            if (ev_compb) {
                if      (com_b() == 2) oc1b = dir_prev;
                else if (com_b() == 3) oc1b = !dir_prev;
            }
        }

        // --- banderas ---
        bool w_tifr = we && a == A_TIFR1;
        if (ev_tov)                               tifr |= 1;
        else if (ack_ovf || (w_tifr && (d & 1)))  tifr &= ~1;
        if (ev_compa)                             tifr |= 2;
        else if (ack_a   || (w_tifr && (d & 2)))  tifr &= ~2;
        if (ev_compb)                             tifr |= 4;
        else if (ack_b   || (w_tifr && (d & 4)))  tifr &= ~4;

        // --- escrituras ---
        if (we) {
            switch (a) {
            case A_TCCR1A: com = (d >> 4) & 0xF; wgm = (uint8_t)((wgm & 0xC) | (d & 3)); break;
            case A_TCCR1B: icnc = (d >> 7) & 1; ices = (d >> 6) & 1;
                           wgm = (uint8_t)((wgm & 3) | ((d & 0x10) ? 8 : 0) | ((d & 0x08) ? 4 : 0));
                           cs = d & 7; break;
            case A_TIMSK1: icie = (d >> 5) & 1; timsk = d & 7; break;
            case A_TCNT1H: case A_ICR1H: case A_OCR1AH: case A_OCR1BH: temp = d; break;
            default: break;
            }
            if (a == A_TCNT1L)  { tcnt = (uint16_t)((temp << 8) | d); tcnt_block = true; }
            if (a == A_ICR1L)   icr = (uint16_t)((temp << 8) | d);
            if (a == A_OCR1AL)  { ocra_buf = (uint16_t)((temp << 8) | d); if (!pwm()) ocra_act = ocra_buf; }
            if (a == A_OCR1BL)  { ocrb_buf = (uint16_t)((temp << 8) | d); if (!pwm()) ocrb_act = ocrb_buf; }
        }

        // --- lecturas con efecto lateral: el byte bajo captura el alto ---
        // Y otra vez lo mismo: lo que se captura en TEMP es el byte alto que el
        // registro tenía AL ENTRAR en el ciclo. En el RTL la carga de TEMP y la
        // cuenta ocurren en el mismo flanco con asignación no bloqueante.
        if (re) {
            if (a == A_TCNT1L)  temp = (uint8_t)(tcnt_prev >> 8);
            if (a == A_ICR1L)   temp = (uint8_t)(icr_prev >> 8);
            if (a == A_OCR1AL)  temp = (uint8_t)(ocra_buf_prev >> 8);
            if (a == A_OCR1BL)  temp = (uint8_t)(ocrb_buf_prev >> 8);
        }

        presc = (uint16_t)((presc + 1) & 0x3FF);
        t1s = (uint8_t)(((t1s << 1) | (t1 ? 1 : 0)) & 7);
    }
};

static Model m;
static long tcyc = 0;

static void compare() {
    static const uint8_t regs[] = { A_TIFR1, A_TIMSK1, A_TCCR1A, A_TCCR1B,
                                    A_TCCR1C, A_TCNT1L, A_TCNT1H, A_ICR1L,
                                    A_ICR1H, A_OCR1AL, A_OCR1AH, A_OCR1BL, A_OCR1BH };
    static const char *nom[] = { "TIFR1","TIMSK1","TCCR1A","TCCR1B","TCCR1C",
                                 "TCNT1L","TCNT1H","ICR1L","ICR1H","OCR1AL",
                                 "OCR1AH","OCR1BL","OCR1BH" };
    for (int i = 0; i < 13; i++) chk(nom[i], peek(regs[i]), m.read(regs[i]), tcyc);
    chk("TCNT1 interno", dut->dbg_tcnt, m.tcnt, tcyc);
    chk("OCR1A activo",  dut->dbg_ocra_act, m.ocra_act, tcyc);
    chk("OCR1B activo",  dut->dbg_ocrb_act, m.ocrb_act, tcyc);
    chk("ICR1 interno",  dut->dbg_icr, m.icr, tcyc);
    chk("TEMP",          dut->dbg_temp, m.temp, tcyc);
    chk("sentido",       dut->dbg_dir_down, m.dir_down, tcyc);
    chk("OC1A",    dut->oc1a, m.oc1a, tcyc);
    chk("OC1A_EN", dut->oc1a_en, m.oc1a_en(), tcyc);
    chk("OC1B",    dut->oc1b, m.oc1b, tcyc);
    chk("OC1B_EN", dut->oc1b_en, m.oc1b_en(), tcyc);
    chk("IRQ CAPT",  dut->irq_capt,  m.icf && m.icie, tcyc);
    chk("IRQ COMPA", dut->irq_compa, (m.tifr & m.timsk & 2) != 0, tcyc);
    chk("IRQ COMPB", dut->irq_compb, (m.tifr & m.timsk & 4) != 0, tcyc);
    chk("IRQ OVF",   dut->irq_ovf,   (m.tifr & m.timsk & 1) != 0, tcyc);
}

static void step(bool we=false, bool re=false, uint8_t a=0, uint8_t d=0,
                 bool t1=false, bool icp=false,
                 bool ac=false, bool aa=false, bool ab=false, bool ao=false) {
    dut->io_we = we; dut->io_re = re; dut->io_addr = a; dut->io_wdata = d;
    dut->t1_pin = t1; dut->icp1_pin = icp;
    dut->ack_capt = ac; dut->ack_compa = aa; dut->ack_compb = ab; dut->ack_ovf = ao;
    dut->eval();
    tick();
    m.cycle(we, re, a, d, t1, icp, ac, aa, ab, ao);
    dut->io_we = 0; dut->io_re = 0; dut->eval();
    tcyc++;
    compare();
}

// Versiones que mantienen el modelo en paso con el DUT.
static void W(uint8_t a, uint8_t d) { step(true, false, a, d); }
static uint8_t R(uint8_t a) {
    dut->io_addr = a; dut->io_re = 1; dut->io_we = 0; dut->eval();
    uint8_t v = dut->io_rdata;
    step(false, true, a, 0);
    return v;
}
static void RUN(int n, bool t1=false, bool icp=false) {
    for (int i = 0; i < n; i++) step(false, false, 0, 0, t1, icp);
}
static void W16(uint8_t lo, uint8_t hi, uint16_t v) { W(hi, (uint8_t)(v >> 8)); W(lo, (uint8_t)v); }
static uint16_t R16(uint8_t lo, uint8_t hi) {
    uint8_t l = R(lo); uint8_t h = R(hi);
    return (uint16_t)(l | (h << 8));
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_timer1_top;
    dut->rst_n = 0; dut->clk = 0;
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->t1_pin = 0; dut->icp1_pin = 0;
    dut->ack_capt = 0; dut->ack_compa = 0; dut->ack_compb = 0; dut->ack_ovf = 0;
    dut->eval(); tick();
    dut->rst_n = 1; dut->eval();

    // ------------------------------------------------ 1. reset
    fase = "reset";
    for (uint8_t a : { (uint8_t)A_TIFR1, (uint8_t)A_TIMSK1, (uint8_t)A_TCCR1A,
                       (uint8_t)A_TCCR1B, (uint8_t)A_TCNT1L, (uint8_t)A_TCNT1H })
        chk("a cero", peek(a), 0, 0);

    // -------------------------- 2. LA TRAMPA Nº 4: el acceso de 16 bits
    fase = "registro TEMP";
    {
        // Escribir ALTO y luego BAJO escribe los dos de golpe.
        W16(A_TCNT1L, A_TCNT1H, 0xBEEF);
        chk("TCNT1 completo", dut->dbg_tcnt, 0xBEEF, tcyc);

        // Leer BAJO y luego ALTO devuelve el valor COHERENTE, aunque el
        // contador siga corriendo entre las dos lecturas.
        W(A_TCCR1B, 0x01);                    // clk/1: el contador avanza
        RUN(5);
        uint16_t v1 = R16(A_TCNT1L, A_TCNT1H);
        RUN(3);
        uint16_t v2 = R16(A_TCNT1L, A_TCNT1H);
        chk("la segunda lectura es mayor", v2 > v1, 1, tcyc);

        // Y AQUÍ ESTÁ LA TRAMPA: leer el ALTO SIN leer antes el bajo devuelve
        // el TEMP que quedó de la vez anterior, no el valor actual. Es lo que
        // hace el chip, y es la razón de que el orden esté documentado.
        W(A_TCCR1B, 0x00);                    // parar para que no cambie
        W16(A_TCNT1L, A_TCNT1H, 0x1234);
        R(A_TCNT1L);                          // captura 0x12 en TEMP
        W16(A_TCNT1L, A_TCNT1H, 0xABCD);      // TEMP pasa a 0xAB al escribir
        chk("TEMP tras escribir el alto", dut->dbg_temp, 0xAB, tcyc);
    }

    // ------------------- 3. TEMP es COMPARTIDO entre los cuatro registros
    fase = "TEMP compartido";
    {
        W(A_TCCR1B, 0x00);
        W16(A_TCNT1L, A_TCNT1H, 0x1111);
        W16(A_ICR1L,  A_ICR1H,  0x2222);
        W16(A_OCR1AL, A_OCR1AH, 0x3333);
        W16(A_OCR1BL, A_OCR1BH, 0x4444);
        chk("TCNT1", R16(A_TCNT1L, A_TCNT1H), 0x1111, tcyc);
        chk("ICR1",  R16(A_ICR1L,  A_ICR1H),  0x2222, tcyc);
        chk("OCR1A", R16(A_OCR1AL, A_OCR1AH), 0x3333, tcyc);
        chk("OCR1B", R16(A_OCR1BL, A_OCR1BH), 0x4444, tcyc);

        // Leer el bajo de UNO y el alto de OTRO mezcla los dos: es el mismo
        // TEMP. Ningún programa debe hacerlo, y el chip tampoco lo impide.
        R(A_OCR1AL);                          // TEMP = 0x33
        chk("TEMP es uno solo", R(A_ICR1H), 0x33, tcyc);
    }

    // ------------------------------------------- 4. los dieciséis modos
    fase = "barrido de modos";
    for (int w = 0; w < 16; w++) {
        for (int c = 0; c < 4; c++) {
            W(A_TCCR1B, 0x00);                             // parar
            W16(A_ICR1L,  A_ICR1H,  (uint16_t)(0x0080 + 0x40 * w));
            W16(A_OCR1AL, A_OCR1AH, (uint16_t)(0x0060 + 0x30 * w));
            W16(A_OCR1BL, A_OCR1BH, (uint16_t)(0x0030 + 0x20 * c));
            W(A_TCCR1A, (uint8_t)((c << 6) | (c << 4) | (w & 3)));
            W16(A_TCNT1L, A_TCNT1H, 0x0000);
            W(A_TIFR1, 0x27);
            W(A_TCCR1B, (uint8_t)(((w & 8) ? 0x10 : 0) | ((w & 4) ? 0x08 : 0) | 0x01));
            RUN(700);
        }
    }

    // ------------------------------------------------- 5. captura de entrada
    fase = "captura";
    {
        W(A_TCCR1B, 0x00);
        W(A_TCCR1A, 0x00);
        W16(A_TCNT1L, A_TCNT1H, 0x0000);
        W(A_TCCR1B, 0x41);                    // ICES=1 (flanco de subida), clk/1
        RUN(40, false, false);
        RUN(40, false, true);                 // flanco de subida en ICP1
        chk("ICF1 puesto", (peek(A_TIFR1) >> 5) & 1, 1, tcyc);
        W(A_TIFR1, 0x20);
        chk("ICF1 limpio", (peek(A_TIFR1) >> 5) & 1, 0, tcyc);

        // Con el cancelador de ruido, un pico de un ciclo NO captura.
        W(A_TCCR1B, 0xC1);                    // ICNC=1, ICES=1
        RUN(30, false, false);
        step(false, false, 0, 0, false, true);   // un solo ciclo alto
        RUN(20, false, false);
        chk("el cancelador ignora un pico", (peek(A_TIFR1) >> 5) & 1, 0, tcyc);
        RUN(30, false, true);                 // ahora sí, sostenido
        chk("y acepta un flanco de verdad", (peek(A_TIFR1) >> 5) & 1, 1, tcyc);
    }

    // ------------------------------------------------- 6. remojo aleatorio
    fase = "aleatorio";
    {
        std::mt19937 rng(20260911);
        static const uint8_t regs[] = { A_TIFR1, A_TIMSK1, A_TCCR1A, A_TCCR1B,
                                        A_TCCR1C, A_TCNT1L, A_TCNT1H, A_ICR1L,
                                        A_ICR1H, A_OCR1AL, A_OCR1AH, A_OCR1BL,
                                        A_OCR1BH };
        for (long i = 0; i < 120000; i++) {
            uint32_t r = rng();
            bool we = (r % 24) == 0;
            bool re = !we && ((r >> 5) % 24) == 0;
            uint8_t a = regs[(r >> 10) % 13];
            uint8_t d = (uint8_t)(r >> 16);
            if (we && a == A_TCCR1B && (d & 7) == 0) d |= 1 + (rng() % 5);
            step(we, re, a, d, (rng() % 7) == 0, (rng() % 11) == 0,
                 (rng() % 4096) == 0, (rng() % 4096) == 0,
                 (rng() % 4096) == 0, (rng() % 4096) == 0);
        }
    }

#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif

    delete dut;
    printf("  %ld comprobaciones en %ld ciclos, %d fallos\n", checks, tcyc, fails);
    if (fails) {
        printf("  el modelo sale de la hoja de datos: simavr no modela TEMP\n");
        return 1;
    }
    printf("  los 16 modos, el TEMP compartido y la captura, correctos\n");
    return 0;
}
