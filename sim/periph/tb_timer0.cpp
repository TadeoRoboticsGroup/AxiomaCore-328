// AxiomaCore-328 - Timer0 contra un modelo de la hoja de datos
// SPDX-License-Identifier: Apache-2.0
//
// POR QUÉ HACE FALTA ESTE BANCO SI EL DIFERENCIAL YA PASA. Porque el modelo de
// temporizador de simavr se aparta de la hoja de datos en cuatro puntos, y en
// los cuatro manda la hoja de datos (docs/01-arquitectura.md §8bis):
//
//   1. FASE DEL PRESCALER. `avr_timer_write` de simavr llama a
//      `avr_timer_reconfigure(p, 1)` cuando cambian los bits CS, lo que ancla
//      su base de cuenta en el ciclo de la escritura. En el chip el prescaler
//      es un contador LIBRE compartido con el Timer1: arrancar el Timer0 no lo
//      pone a cero, y la primera cuenta llega cuando a ese contador le toca.
//      Es la trampa nº 12 y sólo la ve este banco.
//   2. GTCCR. simavr no lo modela en absoluto: `grep GTCCR avr_timer.c` no
//      devuelve nada. PSRSYNC y TSM no existen para él.
//   3. ESCRIBIR TCNT0 con un valor >= TOP: simavr lo convierte en 0
//      (`if (tcnt >= p->tov_top) tcnt = 0;`). El chip guarda lo que se escribe.
//   4. TEMPORIZADOR PARADO: `_avr_timer_get_current_tcnt` devuelve 0 cuando
//      `tov_cycles` es cero. El chip conserva la cuenta.
//
// Y hay una quinta de fondo: simavr NO cuenta ciclo a ciclo. Programa eventos y
// INTERPOLA el valor de TCNT0 desde `avr->cycle` cuando alguien lo lee. Sirve
// para la semántica de los registros, no para la forma de la cuenta.
//
// El modelo de aquí abajo está escrito desde la hoja de datos: tabla de modos,
// tabla de COM, cuándo se pone cada bandera y cuándo se refresca el doble búfer
// de OCR0x.

#include "Vtb_timer0_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>

static Vtb_timer0_top *dut;
static int  fails  = 0;
static long checks = 0;
static const char *fase = "";

struct Model;
static void dump(const char *what);

static void chk(const char *what, uint32_t got, uint32_t exp, long t) {
    checks++;
    if (got != exp && ++fails <= 12) {
        printf("    FALLA [%s] %-28s t=%ld  obtenido=0x%02X esperado=0x%02X\n",
               fase, what, t, got, exp);
        if (getenv("AXIOMA_DUMP")) dump(what);
    }
}

// Direcciones de I/O (dirección de dato menos 0x20).
enum {
    A_TIFR0 = 0x15, A_GTCCR = 0x23, A_TCCR0A = 0x24, A_TCCR0B = 0x25,
    A_TCNT0 = 0x26, A_OCR0A = 0x27, A_OCR0B  = 0x28, A_TIMSK0 = 0x4E
};

// ------------------------------------------------------------------ modelo
struct Model {
    // Prescaler compartido: 10 bits, libre desde el reset.
    uint16_t presc = 0;
    bool tsm = false, psrasy = false, psrsync = false;

    uint8_t com = 0;        // COM0A1 COM0A0 COM0B1 COM0B0
    uint8_t wgm = 0;        // WGM02 WGM01 WGM00
    uint8_t cs  = 0;
    uint8_t tcnt = 0;
    uint8_t ocra_act = 0, ocra_buf = 0;
    uint8_t ocrb_act = 0, ocrb_buf = 0;
    uint8_t timsk = 0, tifr = 0;
    bool dir_down = false;      // sólo en PWM de fase correcta
    bool tcnt_block = false;    // escribir TCNT0 tapa la comparación siguiente
    bool oc0a = false, oc0b = false;
    uint8_t t0s = 0;            // sincronizador de tres etapas del pin T0

    bool pc()   const { return wgm == 1 || wgm == 5; }
    bool fast() const { return wgm == 3 || wgm == 7; }
    bool pwm()  const { return pc() || fast(); }
    uint8_t top() const { return (wgm == 2 || wgm == 5 || wgm == 7) ? ocra_act : 0xFF; }

    uint8_t com_a() const { return (com >> 2) & 3; }
    uint8_t com_b() const { return com & 3; }

    // Tabla de COM de la hoja de datos: con qué combinaciones se adueña el
    // temporizador del pin. COM=1 en PWM sólo vale para OC0A y sólo con
    // WGM02=1; para OC0B está reservado.
    bool oc0a_en() const { return com_a() != 0 && !(pwm() && com_a() == 1 && !(wgm & 4)); }
    bool oc0b_en() const { return com_b() != 0 && !(pwm() && com_b() == 1); }

    uint8_t read(uint8_t a) const {
        switch (a) {
        case A_TIFR0:  return tifr & 7;
        case A_GTCCR:  return (uint8_t)((tsm << 7) | (psrasy << 1) | psrsync);
        case A_TCCR0A: return (uint8_t)((com << 4) | (wgm & 3));
        case A_TCCR0B: return (uint8_t)(((wgm & 4) ? 0x08 : 0) | cs);
        case A_TCNT0:  return tcnt;
        case A_OCR0A:  return ocra_buf;
        case A_OCR0B:  return ocrb_buf;
        case A_TIMSK0: return timsk & 7;
        default:       return 0;
        }
    }

    void cycle(bool we, uint8_t a, uint8_t d, bool t0,
               bool ack_ovf, bool ack_a, bool ack_b) {
        // ---- prescaler: las tomas salen de la cuenta ACTUAL ----
        bool psr_now = (we && a == A_GTCCR) ? (d & 1) : psrsync;
        bool tk[6] = { false, true,
                       ((presc & 0x007) == 0x007) && !psr_now,
                       ((presc & 0x03F) == 0x03F) && !psr_now,
                       ((presc & 0x0FF) == 0x0FF) && !psr_now,
                       ((presc & 0x3FF) == 0x3FF) && !psr_now };

        bool rise = ((t0s >> 1) & 3) == 1;
        bool fall = ((t0s >> 1) & 3) == 2;
        bool ck = (cs == 0) ? false : (cs <= 5) ? tk[cs] : (cs == 6 ? fall : rise);

        // ---- eventos, sobre el valor que TCNT0 tiene AHORA ----
        bool at_top    = (tcnt == top());
        bool at_max    = (tcnt == 0xFF);
        bool at_bottom = (tcnt == 0x00);

        bool ev_tov   = ck && (pc() ? (dir_down && at_bottom) : fast() ? at_top : at_max);
        bool ev_compa = ck && !tcnt_block && (tcnt == ocra_act);
        bool ev_compb = ck && !tcnt_block && (tcnt == ocrb_act);
        bool ev_upd   = ck && pwm() && at_top;

        // El pin de comparación se decide con el sentido que la cuenta traía
        // AL ENTRAR en este ciclo, no con el que deja al salir. Sólo se nota
        // en el modo 5, donde TOP es OCR0A y la comparación cae exactamente en
        // el ciclo en que la cuenta da la vuelta.
        bool dir_prev = dir_down;

        // ---- cuenta ----
        if (ck) {
            if (pc()) {
                if (dir_down) {
                    if (at_bottom) { dir_down = false; tcnt = (top() == 0) ? 0 : 1; }
                    else             tcnt--;
                } else {
                    if (at_top)    { dir_down = true;  tcnt = (top() == 0) ? 0 : (uint8_t)(tcnt - 1); }
                    else             tcnt++;
                }
            } else {
                tcnt = at_top ? 0 : (uint8_t)(tcnt + 1);
            }
            tcnt_block = false;
        }

        if (ev_upd) { ocra_act = ocra_buf; ocrb_act = ocrb_buf; }

        // ---- pines de comparación ----
        // FOC0A/FOC0B: pulsos de escritura, sólo fuera de los modos PWM.
        bool foc_a = we && a == A_TCCR0B && (d & 0x80) && !pwm();
        bool foc_b = we && a == A_TCCR0B && (d & 0x40) && !pwm();

        if (!pwm()) {
            if (ev_compa || foc_a) {
                if      (com_a() == 1) oc0a = !oc0a;
                else if (com_a() == 2) oc0a = false;
                else if (com_a() == 3) oc0a = true;
            }
            if (ev_compb || foc_b) {
                if      (com_b() == 1) oc0b = !oc0b;
                else if (com_b() == 2) oc0b = false;
                else if (com_b() == 3) oc0b = true;
            }
        } else if (fast()) {
            if (ck && at_top) {          // el flanco de BOTTOM manda
                if (com_a() == 2) oc0a = true;
                if (com_a() == 3) oc0a = false;
                if (com_b() == 2) oc0b = true;
                if (com_b() == 3) oc0b = false;
            } else {
                if (ev_compa) {
                    if      (com_a() == 1) oc0a = !oc0a;
                    else if (com_a() == 2) oc0a = false;
                    else if (com_a() == 3) oc0a = true;
                }
                if (ev_compb) {
                    if      (com_b() == 2) oc0b = false;
                    else if (com_b() == 3) oc0b = true;
                }
            }
        } else {                          // fase correcta
            if (ev_compa) {
                if      (com_a() == 1) oc0a = !oc0a;
                else if (com_a() == 2) oc0a = dir_prev;
                else if (com_a() == 3) oc0a = !dir_prev;
            }
            if (ev_compb) {
                if      (com_b() == 2) oc0b = dir_prev;
                else if (com_b() == 3) oc0b = !dir_prev;
            }
        }

        // ---- banderas: el hardware gana a la limpieza ----
        bool w_tifr = we && a == A_TIFR0;
        if (ev_tov)                                    tifr |= 1;
        else if (ack_ovf || (w_tifr && (d & 1)))       tifr &= ~1;
        if (ev_compa)                                  tifr |= 2;
        else if (ack_a   || (w_tifr && (d & 2)))       tifr &= ~2;
        if (ev_compb)                                  tifr |= 4;
        else if (ack_b   || (w_tifr && (d & 4)))       tifr &= ~4;

        // ---- escrituras: mandan sobre la cuenta del mismo ciclo ----
        if (we) {
            switch (a) {
            case A_TCCR0A: com = (d >> 4) & 0xF; wgm = (wgm & 4) | (d & 3); break;
            case A_TCCR0B: wgm = (uint8_t)((wgm & 3) | ((d & 8) ? 4 : 0)); cs = d & 7; break;
            case A_TCNT0:  tcnt = d; tcnt_block = true; break;
            case A_OCR0A:  ocra_buf = d; if (!pwm()) ocra_act = d; break;
            case A_OCR0B:  ocrb_buf = d; if (!pwm()) ocrb_act = d; break;
            case A_TIMSK0: timsk = d & 7; break;
            default: break;
            }
        }

        // ---- prescaler y GTCCR ----
        if (we && a == A_GTCCR) {
            tsm = (d >> 7) & 1;
            psrasy = tsm && ((d >> 1) & 1);
            psrsync = tsm && (d & 1);
        } else if (!tsm) {
            psrasy = false; psrsync = false;
        }
        presc = psr_now ? 0 : (uint16_t)((presc + 1) & 0x3FF);

        // ---- sincronizador del pin T0 ----
        t0s = (uint8_t)(((t0s << 1) | (t0 ? 1 : 0)) & 7);
    }

    bool irq_ovf()   const { return (tifr & timsk & 1) != 0; }
    bool irq_compa() const { return (tifr & timsk & 2) != 0; }
    bool irq_compb() const { return (tifr & timsk & 4) != 0; }
};

static Model m;
static long tcyc = 0;

static void dump(const char *what) {
    printf("        %s: wgm=%d cs=%d com=%X tcnt=%02X top=%02X ocra_act=%02X "
           "ocra_buf=%02X dir=%d block=%d oc0a=%d presc=%03X\n",
           what, m.wgm, m.cs, m.com, m.tcnt, m.top(), m.ocra_act, m.ocra_buf,
           m.dir_down, m.tcnt_block, m.oc0a, m.presc);
}

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static uint8_t rd(uint8_t a) {
    dut->io_addr = a; dut->io_we = 0; dut->eval();
    return dut->io_rdata;
}

// Compara TODO el estado observable tras cada ciclo. Comparar sólo TCNT0
// dejaría fuera justo lo que rompe código real: las banderas y los pines.
static void compare() {
    static const uint8_t regs[] = { A_TIFR0, A_GTCCR, A_TCCR0A, A_TCCR0B,
                                    A_TCNT0, A_OCR0A, A_OCR0B, A_TIMSK0 };
    static const char *nom[] = { "TIFR0", "GTCCR", "TCCR0A", "TCCR0B",
                                 "TCNT0", "OCR0A", "OCR0B", "TIMSK0" };
    for (int i = 0; i < 8; i++) chk(nom[i], rd(regs[i]), m.read(regs[i]), tcyc);
    chk("cuenta del prescaler", dut->presc_count, m.presc, tcyc);
    chk("OCR0A activo", dut->dbg_ocra_act,   m.ocra_act, tcyc);
    chk("OCR0B activo", dut->dbg_ocrb_act,   m.ocrb_act, tcyc);
    chk("sentido de la cuenta", dut->dbg_dir_down, m.dir_down, tcyc);
    chk("comparacion tapada",   dut->dbg_tcnt_block, m.tcnt_block, tcyc);
    chk("OC0A",    dut->oc0a,    m.oc0a,    tcyc);
    chk("OC0A_EN", dut->oc0a_en, m.oc0a_en(), tcyc);
    chk("OC0B",    dut->oc0b,    m.oc0b,    tcyc);
    chk("OC0B_EN", dut->oc0b_en, m.oc0b_en(), tcyc);
    chk("IRQ TOV0",  dut->irq_ovf,   m.irq_ovf(),   tcyc);
    chk("IRQ OCF0A", dut->irq_compa, m.irq_compa(), tcyc);
    chk("IRQ OCF0B", dut->irq_compb, m.irq_compb(), tcyc);
}

// Un ciclo de reloj con, opcionalmente, una escritura y unos reconocimientos.
static void step(bool we = false, uint8_t a = 0, uint8_t d = 0, bool t0 = false,
                 bool ack_ovf = false, bool ack_a = false, bool ack_b = false) {
    dut->io_we = we; dut->io_addr = a; dut->io_wdata = d;
    dut->io_re = 0;  dut->t0_pin = t0;
    dut->ack_ovf = ack_ovf; dut->ack_compa = ack_a; dut->ack_compb = ack_b;
    dut->eval();
    tick();
    m.cycle(we, a, d, t0, ack_ovf, ack_a, ack_b);
    dut->io_we = 0; dut->eval();
    tcyc++;
    compare();
}

static void wr(uint8_t a, uint8_t d) { step(true, a, d); }
static void run(int n, bool t0 = false) { for (int i = 0; i < n; i++) step(false, 0, 0, t0); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_timer0_top;

    dut->rst_n = 0; dut->clk = 0;
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->t0_pin = 0; dut->ack_ovf = 0; dut->ack_compa = 0; dut->ack_compb = 0;
    dut->eval();
    tick();
    dut->rst_n = 1; dut->eval();

    // ------------------------------------------------ 1. valores de reset
    fase = "reset";
    for (uint8_t a : { (uint8_t)A_TIFR0, (uint8_t)A_GTCCR, (uint8_t)A_TCCR0A,
                       (uint8_t)A_TCCR0B, (uint8_t)A_TCNT0, (uint8_t)A_OCR0A,
                       (uint8_t)A_OCR0B, (uint8_t)A_TIMSK0 })
        chk("reset a cero", rd(a), 0, 0);

    // ---------------------------------- 2. el temporizador arranca parado
    fase = "parado";
    run(40);
    chk("CS=0 no cuenta", rd(A_TCNT0), 0, tcyc);

    // ------------------------------ 3. clk/1: una cuenta por ciclo de reloj
    fase = "clk/1";
    wr(A_TCCR0B, 0x01);
    run(20);

    // ---------------------------- 4. TRAMPA Nº 12: el prescaler es LIBRE
    // Se para el temporizador, se dejan pasar unos ciclos y se arranca con
    // clk/8: la primera cuenta NO llega ocho ciclos después de la escritura,
    // sino cuando al contador compartido le toca. Es justo lo que simavr hace
    // al revés, y por eso este caso sólo lo puede ver este banco.
    fase = "prescaler libre";
    wr(A_TCCR0B, 0x00);
    run(13);
    {
        uint8_t antes = rd(A_TCNT0);
        uint16_t fase_presc = m.presc;
        wr(A_TCCR0B, 0x02);                 // clk/8
        // Tras la escritura el prescaler vale fase_presc+1, y la toma de /8
        // pulsa en el ciclo en que sus tres bits bajos valen 7.
        int faltan = (7 - (fase_presc & 7)) & 7;
        if (faltan == 0) faltan = 8;
        run(faltan - 1);
        chk("todavía no ha contado", rd(A_TCNT0), antes, tcyc);
        run(1);
        chk("cuenta al tocarle al prescaler", rd(A_TCNT0), (uint8_t)(antes + 1), tcyc);
        run(7);
        chk("y no antes de otros ocho", rd(A_TCNT0), (uint8_t)(antes + 1), tcyc);
        run(1);
        chk("segunda cuenta", rd(A_TCNT0), (uint8_t)(antes + 2), tcyc);
    }

    // -------------------------------- 5. GTCCR: PSRSYNC resetea, TSM retiene
    fase = "GTCCR";
    wr(A_GTCCR, 0x01);                      // PSRSYNC
    chk("PSRSYNC se autolimpia", rd(A_GTCCR), 0x00, tcyc);
    chk("prescaler a cero", dut->presc_count, 0, tcyc);
    wr(A_GTCCR, 0x81);                      // TSM + PSRSYNC
    chk("con TSM el bit se retiene", rd(A_GTCCR), 0x81, tcyc);
    run(20);
    chk("con TSM el prescaler no avanza", dut->presc_count, 0, tcyc);
    wr(A_GTCCR, 0x00);                      // suelta
    run(10);

    // ------------------------------------ 6. modo normal: TOV0 y su limpieza
    fase = "normal y TOV0";
    wr(A_GTCCR,  0x01);
    wr(A_TCCR0A, 0x00);
    wr(A_TCCR0B, 0x01);                     // normal, clk/1
    wr(A_TCNT0,  0xFD);
    run(6);
    chk("TOV0 puesto tras desbordar", rd(A_TIFR0) & 1, 1, tcyc);
    wr(A_TIFR0, 0x01);                      // se limpia escribiendo UN UNO
    chk("TOV0 limpio", rd(A_TIFR0) & 1, 0, tcyc);
    wr(A_TIMSK0, 0x01);                     // TOIE0
    wr(A_TCNT0,  0xFF);
    run(3);
    chk("petición de interrupción", dut->irq_ovf, 1, tcyc);
    step(false, 0, 0, false, true);         // reconocimiento del vector
    chk("el vector limpia la bandera", rd(A_TIFR0) & 1, 0, tcyc);
    wr(A_TIMSK0, 0x00);

    // ------------------------------------- 7. CTC: TOP=OCR0A, pero TOV0 en MAX
    fase = "CTC";
    wr(A_TCCR0A, 0x02);                     // WGM01
    wr(A_OCR0A,  0x05);
    wr(A_TCNT0,  0x00);
    wr(A_TIFR0,  0x07);
    run(12);
    chk("vuelve a cero en OCR0A", rd(A_TCNT0) <= 5, 1, tcyc);
    chk("OCF0A puesto", (rd(A_TIFR0) >> 1) & 1, 1, tcyc);
    chk("TOV0 NO puesto en CTC", rd(A_TIFR0) & 1, 0, tcyc);
    // Y ahora el caso que separa CTC de «vuelve a cero en TOP»: se baja OCR0A
    // por debajo de la cuenta, se pierde la comparación y el contador sigue
    // hasta 0xFF. Ahí, y sólo ahí, se pone TOV0.
    wr(A_TIFR0, 0x07);
    wr(A_TCNT0, 0x80);
    wr(A_OCR0A, 0x10);
    run(130);
    chk("TOV0 en MAX al perder la comparación", rd(A_TIFR0) & 1, 1, tcyc);

    // ------------------- 8. escribir TCNT0 tapa la comparación siguiente
    fase = "TCNT0 tapa la comparación";
    wr(A_TCCR0A, 0x00);                     // normal
    wr(A_OCR0A,  0x40);
    wr(A_TIFR0,  0x07);
    wr(A_TCNT0,  0x40);                     // se escribe justo el valor de OCR0A
    run(1);
    chk("comparación tapada", (rd(A_TIFR0) >> 1) & 1, 0, tcyc);
    run(1);

    // ----------------------------- 9. PWM rápido: doble búfer y forma de onda
    fase = "PWM rapido";
    wr(A_TCCR0A, 0xA3);                     // COM0A=2, COM0B=2, WGM=3
    wr(A_OCR0A,  0x40);
    wr(A_OCR0B,  0x80);
    wr(A_TCNT0,  0x00);
    run(600);
    // El doble búfer: se escribe a mitad de periodo y NO puede tener efecto
    // hasta BOTTOM. El modelo lo comprueba ciclo a ciclo; aquí sólo se fuerza
    // el caso.
    wr(A_TCNT0, 0x20);
    wr(A_OCR0A, 0x10);                      // por debajo de la cuenta actual
    run(300);

    // ------------------------------- 10. PWM de fase correcta: cuenta arriba
    //     y abajo, TOV0 en BOTTOM, OCR0x se refresca en TOP
    fase = "PWM fase correcta";
    wr(A_TCCR0A, 0xA1);                     // COM0A=2, COM0B=2, WGM=1
    wr(A_TCNT0,  0x00);
    wr(A_OCR0A,  0x30);
    wr(A_OCR0B,  0xC0);
    wr(A_TIFR0,  0x07);
    run(700);
    wr(A_OCR0A, 0x90);
    run(700);

    // ------------------------------------ 11. TOP = OCR0A (modos 5 y 7)
    fase = "TOP=OCR0A";
    wr(A_TCCR0B, 0x09);                     // WGM02 + clk/1  -> modo 5
    wr(A_OCR0A,  0x20);
    run(400);
    wr(A_TCCR0A, 0xA3);                     // modo 7, PWM rápido con TOP=OCR0A
    run(400);
    // Casos extremos de la hoja de datos: OCR0A = BOTTOM y OCR0A = MAX.
    wr(A_OCR0A, 0x00);
    run(80);
    wr(A_OCR0A, 0xFF);
    run(300);

    // ------------------------------------------- 12. sin PWM: COM conmuta
    fase = "COM sin PWM";
    wr(A_TCCR0A, 0x40);                     // COM0A=1 (conmutar), modo normal
    wr(A_TCCR0B, 0x01);
    wr(A_OCR0A,  0x08);
    wr(A_TCNT0,  0x00);
    run(600);
    // FOC0A fuerza el cambio del pin sin tocar bandera ni contador.
    {
        uint8_t t_antes = rd(A_TCNT0);
        uint8_t f_antes = rd(A_TIFR0);
        wr(A_TCCR0B, 0x81);                 // FOC0A + clk/1
        chk("FOC0A no toca el contador", rd(A_TCNT0), (uint8_t)(t_antes + 1), tcyc);
        chk("FOC0A no toca las banderas", rd(A_TIFR0), f_antes, tcyc);
    }

    // --------------------------------------------- 13. reloj externo por T0
    fase = "reloj externo T0";
    wr(A_TCCR0A, 0x00);
    wr(A_TCCR0B, 0x07);                     // flanco de subida en T0
    wr(A_TCNT0,  0x00);
    for (int i = 0; i < 40; i++) run(3, (i & 1) != 0);
    wr(A_TCCR0B, 0x06);                     // flanco de bajada
    for (int i = 0; i < 40; i++) run(3, (i & 1) != 0);

    // ---------------------------------------------- 14. barrido de modos
    // Cada modo, con varias combinaciones de COM y de OCR0x, durante periodos
    // completos. Es lo que convierte la tabla de modos en algo comprobado y no
    // en un comentario.
    fase = "barrido de modos";
    for (int wgm = 0; wgm < 8; wgm++) {
        for (int com = 0; com < 4; com++) {
            uint8_t tccra = (uint8_t)((com << 6) | (com << 4) | (wgm & 3));
            uint8_t tccrb = (uint8_t)(((wgm & 4) ? 0x08 : 0) | 0x01);
            wr(A_TCCR0A, tccra);
            wr(A_TCCR0B, tccrb);
            wr(A_OCR0A,  (uint8_t)(0x10 + 0x23 * wgm));
            wr(A_OCR0B,  (uint8_t)(0x80 + 0x11 * com));
            wr(A_TCNT0,  0x00);
            wr(A_TIFR0,  0x07);
            run(600);
        }
    }

    // ------------------------------------------------- 15. remojo aleatorio
    // Escrituras al azar sobre registros al azar, acks al azar y el pin T0 al
    // azar. El modelo va en paralelo y se compara TODO el estado cada ciclo.
    fase = "aleatorio";
    std::mt19937 rng(20260911);
    static const uint8_t regs[] = { A_TIFR0, A_GTCCR, A_TCCR0A, A_TCCR0B,
                                    A_TCNT0, A_OCR0A, A_OCR0B, A_TIMSK0 };
    for (long i = 0; i < 200000; i++) {
        bool we = (rng() % 24) == 0;
        uint8_t a = regs[rng() % 8];
        uint8_t d = (uint8_t)rng();
        // Que el temporizador esté parado la mayor parte del tiempo no prueba
        // nada, así que los CS a cero se vuelven a sembrar con una toma real.
        if (we && a == A_TCCR0B && (d & 7) == 0) d |= 1 + (rng() % 5);
        bool t0 = (rng() % 7) == 0;
        step(we, a, d, t0, (rng() % 4096) == 0, (rng() % 4096) == 0, (rng() % 4096) == 0);
    }


#if VM_COVERAGE
    // Sólo existe al compilar con `--coverage`. Sin esta llamada la
    // instrumentación corre y se tira a la basura.
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;

    printf("  %ld comprobaciones en %ld ciclos, %d fallos\n", checks, tcyc, fails);
    if (fails) { printf("  el modelo sale de la hoja de datos, no del RTL\n"); return 1; }
    return 0;
}
