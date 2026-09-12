// AxiomaCore-328 - Timer2 contra un modelo de la hoja de datos
// SPDX-License-Identifier: Apache-2.0
//
// La máquina de forma de onda la modela `timer8_ref.h`, el mismo fichero que
// usa el banco del Timer0, porque la hoja de datos las describe con las mismas
// palabras y en el RTL también son el mismo módulo. Lo que este banco verifica
// es lo que el Timer2 tiene DISTINTO, que es justamente lo que se puede
// implementar mal sin que nadie se entere:
//
//   PRESCALER PROPIO, con dos tomas que el Timer0 no tiene —/32 y /128— y con
//   el orden de CS corrido: en el Timer2, CS=4 es clk/64, no clk/256. Un
//   copiar y pegar del Timer0 da un temporizador que cuenta cuatro veces más
//   rápido y nada más falla.
//
//   NO ES EL CONTADOR DE LOS OTROS DOS. Poner a cero el prescaler síncrono con
//   GTCCR.PSRSYNC no debe mover la fase de éste, y al revés: PSRASY no debe
//   mover la del Timer0.
//
//   MODO ASÍNCRONO: con ASSR.AS2 el temporizador cuenta los flancos de TOSC1 y
//   no el reloj del sistema. Sin cristal conectado, no cuenta — que es lo que
//   hace el chip en una placa que no lo lleva.
//
// simavr sirve de poco aquí: su modelo de temporizador no cuenta ciclo a ciclo
// —interpola desde su contador de ciclos— y su prescaler se reinicia al
// escribir los bits CS. Manda la hoja de datos. Ver docs/01-arquitectura.md
// §8bis.

#include "Vtb_timer2_top.h"
#include "verilated.h"
#include "timer8_ref.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <random>

static Vtb_timer2_top *dut;
static int  fails  = 0;
static long checks = 0;
static const char *fase = "";

static void chk(const char *what, uint32_t got, uint32_t exp, long t) {
    checks++;
    if (got != exp && ++fails <= 12)
        printf("    FALLA [%s] %-28s t=%ld  obtenido=0x%02X esperado=0x%02X\n",
               fase, what, t, got, exp);
}

// Direcciones de I/O (dirección de dato menos 0x20).
enum {
    A_TIFR2 = 0x17, A_GTCCR = 0x23, A_TIMSK2 = 0x50, A_TCCR2A = 0x90,
    A_TCCR2B = 0x91, A_TCNT2 = 0x92, A_OCR2A = 0x93, A_OCR2B = 0x94,
    A_ASSR  = 0x96
};

// ------------------------------------------------------------------ modelo
struct Model : Timer8Ref {
    // Prescaler PROPIO, de 10 bits. Lo pone a cero PSRASY, no PSRSYNC.
    uint16_t presc = 0;
    bool tsm = false, psrasy = false, psrsync = false;
    uint8_t cs = 0;
    bool as2 = false, exclk = false;
    uint8_t toscs = 0;          // sincronizador de tres etapas de TOSC1

    uint8_t read(uint8_t a) const {
        switch (a) {
        case A_TIFR2:  return rd_tifr();
        case A_GTCCR:  return (uint8_t)((tsm << 7) | (psrasy << 1) | psrsync);
        case A_TIMSK2: return rd_timsk();
        case A_TCCR2A: return rd_tccra();
        case A_TCCR2B: return (uint8_t)(((wgm & 4) ? 0x08 : 0) | cs);
        case A_TCNT2:  return rd_tcnt();
        case A_OCR2A:  return rd_ocra();
        case A_OCR2B:  return rd_ocrb();
        // Los cinco bits de ocupado se leen a cero: las escrituras son
        // inmediatas. Es la diferencia declarada en la cabecera del RTL.
        case A_ASSR:   return (uint8_t)((exclk << 6) | (as2 << 5));
        default:       return 0;
        }
    }

    void cycle(bool we, uint8_t a, uint8_t d, bool tosc,
               bool ack_ovf, bool ack_a, bool ack_b) {
        // ---- prescaler propio: la puesta a cero vale en este mismo ciclo ----
        bool psa_now = (we && a == A_GTCCR) ? ((d >> 1) & 1) : psrasy;

        // La fuente: el reloj del sistema, o un flanco de subida de TOSC1.
        bool rise = ((toscs >> 1) & 3) == 1;
        bool src  = as2 ? rise : true;

        bool tk[8] = { false,
                       src,
                       src && ((presc & 0x007) == 0x007) && !psa_now,   // /8
                       src && ((presc & 0x01F) == 0x01F) && !psa_now,   // /32
                       src && ((presc & 0x03F) == 0x03F) && !psa_now,   // /64
                       src && ((presc & 0x07F) == 0x07F) && !psa_now,   // /128
                       src && ((presc & 0x0FF) == 0x0FF) && !psa_now,   // /256
                       src && ((presc & 0x3FF) == 0x3FF) && !psa_now }; // /1024
        bool ck = tk[cs];

        // ---- el motor ----
        Escritura w;
        w.d     = d;
        w.tccra = we && a == A_TCCR2A;
        w.tccrb = we && a == A_TCCR2B;
        w.tcnt  = we && a == A_TCNT2;
        w.ocra  = we && a == A_OCR2A;
        w.ocrb  = we && a == A_OCR2B;
        w.timsk = we && a == A_TIMSK2;
        w.tifr  = we && a == A_TIFR2;
        Timer8Ref::cycle(ck, w, ack_ovf, ack_a, ack_b);

        // ---- lo que es del Timer2 y no del motor ----
        if (we && a == A_TCCR2B) cs = d & 7;
        if (we && a == A_ASSR) { exclk = (d >> 6) & 1; as2 = (d >> 5) & 1; }

        // ---- GTCCR y el prescaler ----
        if (we && a == A_GTCCR) {
            tsm = (d >> 7) & 1;
            psrasy = tsm && ((d >> 1) & 1);
            psrsync = tsm && (d & 1);
        } else if (!tsm) {
            psrasy = false; psrsync = false;
        }
        if (psa_now)   presc = 0;
        else if (src)  presc = (uint16_t)((presc + 1) & 0x3FF);

        // ---- sincronizador de TOSC1 ----
        toscs = (uint8_t)(((toscs << 1) | (tosc ? 1 : 0)) & 7);
    }
};

static Model m;
static long  tcyc = 0;

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static uint8_t rd(uint8_t a) {
    dut->io_addr = a; dut->io_we = 0; dut->eval();
    return dut->io_rdata;
}

// Compara TODO el estado observable tras cada ciclo.
static void compare() {
    static const uint8_t regs[] = { A_TIFR2, A_GTCCR, A_TIMSK2, A_TCCR2A,
                                    A_TCCR2B, A_TCNT2, A_OCR2A, A_OCR2B, A_ASSR };
    static const char *nom[] = { "TIFR2", "GTCCR", "TIMSK2", "TCCR2A",
                                 "TCCR2B", "TCNT2", "OCR2A", "OCR2B", "ASSR" };
    for (int i = 0; i < 9; i++) chk(nom[i], rd(regs[i]), m.read(regs[i]), tcyc);
    chk("cuenta del prescaler", dut->presc2_count, m.presc, tcyc);
    chk("OCR2A activo", dut->dbg_ocra_act,   m.ocra_act, tcyc);
    chk("OCR2B activo", dut->dbg_ocrb_act,   m.ocrb_act, tcyc);
    chk("sentido de la cuenta", dut->dbg_dir_down, m.dir_down, tcyc);
    chk("comparacion tapada",   dut->dbg_tcnt_block, m.tcnt_block, tcyc);
    chk("OC2A",    dut->oc2a,    m.oca,    tcyc);
    chk("OC2A_EN", dut->oc2a_en, m.oca_en(), tcyc);
    chk("OC2B",    dut->oc2b,    m.ocb,    tcyc);
    chk("OC2B_EN", dut->oc2b_en, m.ocb_en(), tcyc);
    chk("IRQ TOV2",  dut->irq_ovf,   m.irq_ovf(),   tcyc);
    chk("IRQ OCF2A", dut->irq_compa, m.irq_compa(), tcyc);
    chk("IRQ OCF2B", dut->irq_compb, m.irq_compb(), tcyc);
}

static bool tosc_pin = false;

static void step(bool we = false, uint8_t a = 0, uint8_t d = 0,
                 bool ack_ovf = false, bool ack_a = false, bool ack_b = false) {
    dut->io_we = we; dut->io_addr = a; dut->io_wdata = d;
    dut->io_re = 0;  dut->tosc = tosc_pin;
    dut->ack_ovf = ack_ovf; dut->ack_compa = ack_a; dut->ack_compb = ack_b;
    dut->eval();
    tick();
    m.cycle(we, a, d, tosc_pin, ack_ovf, ack_a, ack_b);
    dut->io_we = 0; dut->eval();
    tcyc++;
    compare();
}

static void wr(uint8_t a, uint8_t d) { step(true, a, d); }
static void run(int n) { for (int i = 0; i < n; i++) step(); }

// El cristal de TOSC1: `periodo` ciclos de reloj del sistema por semiperiodo.
static void run_tosc(int flancos, int periodo) {
    for (int i = 0; i < flancos * 2; i++) {
        tosc_pin = !tosc_pin;
        run(periodo);
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_timer2_top;

    dut->rst_n = 0; dut->clk = 0;
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->tosc = 0; dut->ack_ovf = 0; dut->ack_compa = 0; dut->ack_compb = 0;
    dut->eval();
    tick();
    dut->rst_n = 1; dut->eval();

    printf("\033[1mTimer2 contra la hoja de datos\033[0m\n");

    // ------------------------------------------------ 1. valores de reset
    fase = "reset";
    for (uint8_t a : { (uint8_t)A_TIFR2, (uint8_t)A_TIMSK2, (uint8_t)A_TCCR2A,
                       (uint8_t)A_TCCR2B, (uint8_t)A_TCNT2, (uint8_t)A_OCR2A,
                       (uint8_t)A_OCR2B, (uint8_t)A_ASSR })
        chk("todo a cero tras el reset", rd(a), 0x00, tcyc);
    run(4);

    // ------------------------------- 2. LAS OCHO TOMAS, que son SUYAS
    // Ésta es la prueba que separa el Timer2 de una copia del Timer0: sus CS
    // no significan lo mismo. Se mide cuántos ciclos de reloj tarda TCNT2 en
    // avanzar uno con cada CS.
    fase = "las ocho tomas";
    {
        const int div[8] = { 0, 1, 8, 32, 64, 128, 256, 1024 };
        for (int cs = 1; cs < 8; cs++) {
            wr(A_TCCR2A, 0x00);             // modo normal
            wr(A_TCCR2B, (uint8_t)cs);
            wr(A_TCNT2,  0x00);
            // PSRASY VA EL ULTIMO, y no es un detalle de escritura: cada ciclo
            // que pase entre poner el prescaler a cero y empezar a mirar es un
            // ciclo que el prescaler ya ha contado. Con las tres escrituras
            // delante, la primera cuenta llega N-3 ciclos despues y la medida
            // dice que el divisor esta mal cuando lo que esta mal es el reloj
            // de quien mide.
            wr(A_GTCCR,  0x02);             // PSRASY: prescaler a cero
            long antes = tcyc;
            uint8_t v0 = rd(A_TCNT2);
            while (rd(A_TCNT2) == v0 && (tcyc - antes) < 4096) run(1);
            long tardo = tcyc - antes;
            checks++;
            // Se admite un ciclo de margen por el flanco en el que cae la
            // ultima escritura.
            if (tardo < div[cs] - 1 || tardo > div[cs] + 1) {
                printf("    FALLA CS=%d: la cuenta tardo %ld ciclos y la hoja "
                       "de datos dice %d\n", cs, tardo, div[cs]);
                fails++;
            }
        }
    }
    printf("  las ocho tomas del prescaler propio, incluidas /32 y /128\n");

    // --------------------------- 3. el prescaler es SUYO: PSRSYNC no lo toca
    fase = "prescaler propio";
    wr(A_TCCR2B, 0x03);                     // clk/32
    wr(A_GTCCR,  0x02);                     // PSRASY -> a cero
    run(5);
    {
        uint16_t antes = dut->presc2_count;
        wr(A_GTCCR, 0x01);                  // PSRSYNC: el del Timer0, no el suyo
        checks++;
        if (dut->presc2_count == 0 && antes != 0) {
            printf("    FALLA: PSRSYNC puso a cero el prescaler del Timer2\n");
            fails++;
        }
        wr(A_GTCCR, 0x02);                  // PSRASY: éste sí
        checks++;
        if (dut->presc2_count != 0) {
            printf("    FALLA: PSRASY no puso a cero el prescaler del Timer2\n");
            fails++;
        }
    }
    // Y TSM lo retiene parado, igual que al síncrono.
    wr(A_GTCCR, 0x82);                      // TSM + PSRASY
    run(20);
    chk("con TSM el prescaler no avanza", dut->presc2_count, 0, tcyc);
    wr(A_GTCCR, 0x00);
    run(10);
    printf("  el prescaler es suyo: PSRASY lo pone a cero y PSRSYNC no lo toca\n");

    // ------------------------------------ 4. modo normal, TOV2 y su limpieza
    fase = "normal y TOV2";
    wr(A_TCCR2A, 0x00);
    wr(A_TCCR2B, 0x01);                     // clk/1
    wr(A_TCNT2,  0xFD);
    run(6);
    chk("TOV2 puesto tras desbordar", rd(A_TIFR2) & 1, 1, tcyc);
    wr(A_TIFR2, 0x01);
    chk("TOV2 limpio", rd(A_TIFR2) & 1, 0, tcyc);
    wr(A_TIMSK2, 0x01);                     // TOIE2
    wr(A_TCNT2,  0xFF);
    run(3);
    chk("peticion de interrupcion", dut->irq_ovf, 1, tcyc);
    step(false, 0, 0, true);                // reconocimiento del vector
    chk("el vector limpia la bandera", rd(A_TIFR2) & 1, 0, tcyc);
    wr(A_TIMSK2, 0x00);

    // ------------------------------------------------- 5. MODO ASÍNCRONO
    // Con AS2 puesto, el temporizador cuenta TOSC1 y no el reloj del sistema.
    fase = "asincrono";
    wr(A_TCCR2A, 0x00);
    wr(A_TCCR2B, 0x01);                     // clk/1 de la fuente que toque
    wr(A_TCNT2,  0x00);
    wr(A_ASSR,   0x20);                     // AS2
    chk("ASSR se lee de vuelta", rd(A_ASSR), 0x20, tcyc);
    {
        // Sin cristal: TOSC1 quieto, el temporizador parado. Es lo que pasa en
        // una placa que no lleva el cristal de 32 kHz.
        uint8_t antes = rd(A_TCNT2);
        run(300);
        checks++;
        if (rd(A_TCNT2) != antes) {
            printf("    FALLA: en asincrono y sin cristal el Timer2 cuenta\n");
            fails++;
        }
        // Y con cristal, cuenta un flanco de subida por cada periodo.
        antes = rd(A_TCNT2);
        run_tosc(10, 7);
        checks++;
        uint8_t despues = rd(A_TCNT2);
        if ((uint8_t)(despues - antes) != 10) {
            printf("    FALLA: 10 flancos de TOSC1 dieron %d cuentas\n",
                   (uint8_t)(despues - antes));
            fails++;
        }
    }
    // Los cinco bits de ocupado se leen a cero: las escrituras son inmediatas.
    wr(A_TCNT2, 0x55);
    chk("ASSR sin bits de ocupado", rd(A_ASSR), 0x20, tcyc);
    chk("y la escritura ya esta hecha", rd(A_TCNT2), 0x55, tcyc);
    // De vuelta al sincrono.
    wr(A_ASSR, 0x00);
    run(4);
    printf("  el modo asincrono cuenta TOSC1, y sin cristal no cuenta\n");

    // --------------------------- 6. /128 sobre 32 768 Hz da un segundo exacto
    // Es para lo que existe esta toma: 32768/128 = 256, que es justo un
    // desbordamiento de 8 bits. Aquí se comprueba la división, no el segundo.
    fase = "un segundo";
    wr(A_ASSR,   0x20);                     // asincrono
    wr(A_GTCCR,  0x02);
    wr(A_TCCR2B, 0x05);                     // clk/128
    wr(A_TCNT2,  0x00);
    wr(A_TIFR2,  0x07);
    run_tosc(128, 3);
    chk("una cuenta cada 128 flancos", rd(A_TCNT2), 1, tcyc);
    wr(A_ASSR, 0x00);

    // ------------------------------------------------- 7. barrido de modos
    // Los ocho modos con varias combinaciones de COM. El motor es el mismo que
    // el del Timer0 y ya está barrido allí, pero eso es precisamente lo que hay
    // que comprobar: que aquí se comporta igual.
    fase = "barrido de modos";
    for (int wgm = 0; wgm < 8; wgm++) {
        for (int com = 0; com < 4; com++) {
            uint8_t tccra = (uint8_t)((com << 6) | (com << 4) | (wgm & 3));
            uint8_t tccrb = (uint8_t)(((wgm & 4) ? 0x08 : 0) | 0x01);
            wr(A_TCCR2A, tccra);
            wr(A_TCCR2B, tccrb);
            wr(A_OCR2A,  (uint8_t)(0x10 + 0x23 * wgm));
            wr(A_OCR2B,  (uint8_t)(0x80 + 0x11 * com));
            wr(A_TCNT2,  0x00);
            wr(A_TIFR2,  0x07);
            run(600);
        }
    }

    // ------------------------------------------------- 8. remojo aleatorio
    fase = "aleatorio";
    std::mt19937 rng(20260911);
    static const uint8_t regs[] = { A_TIFR2, A_GTCCR, A_TIMSK2, A_TCCR2A,
                                    A_TCCR2B, A_TCNT2, A_OCR2A, A_OCR2B, A_ASSR };
    for (long i = 0; i < 200000; i++) {
        bool we = (rng() % 24) == 0;
        uint8_t a = regs[rng() % 9];
        uint8_t d = (uint8_t)rng();
        // Un temporizador parado no prueba nada: los CS a cero se resiembran.
        if (we && a == A_TCCR2B && (d & 7) == 0) d |= 1 + (rng() % 7);
        // Y el asíncrono sin cristal tampoco, así que TOSC1 se mueve a un
        // ritmo que no divide al del reloj, para que los flancos caigan en
        // sitios distintos.
        if ((i % 5) == 0) tosc_pin = !tosc_pin;
        step(we, a, d, (rng() % 4096) == 0, (rng() % 4096) == 0, (rng() % 4096) == 0);
    }

#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;

    printf("  %ld comprobaciones en %ld ciclos, %d fallos\n", checks, tcyc, fails);
    if (fails) { printf("  el modelo sale de la hoja de datos, no del RTL\n"); return 1; }
    printf("  las ocho tomas, los ocho modos y el asincrono, correctos\n");
    return 0;
}
