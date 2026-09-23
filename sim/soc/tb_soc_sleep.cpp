// AxiomaCore-328 - el sueño, y la prueba de que los dos relojes son dos
// SPDX-License-Identifier: Apache-2.0
//
// `SLEEP` no es una instrucción que haga algo: es una que deja de hacerlo. Y lo
// único que se puede comprobar de ella es **desde fuera y con el tiempo en la
// mano**: que el núcleo deje de ejecutar, que siga parado, y que lo que tenía
// que despertarlo lo despierte a la hora que toca.
//
// Los cuatro casos de aquí están elegidos para que, entre los dos primeros y
// los dos últimos, quede demostrado lo que el ADR 0003 decidió: que `clk_CPU` y
// `clk_I/O` son **dos relojes y no uno**.
//
//   1. `Idle` + desbordamiento del Timer0 — el núcleo se para y EL
//      TEMPORIZADOR SIGUE, así que puede despertarlo. El pin sale una vez por
//      periodo del temporizador, clavado.
//   2. Sin `SE`, `SLEEP` ES UN `NOP` — el bucle corre a toda velocidad. No es
//      un detalle: avr-libc pone `SE`, duerme y **vuelve a quitarlo**, justo
//      para que un `SLEEP` perdido en el código no pare el chip.
//   3. `Power-down` + el mismo temporizador — AQUÍ NO DESPIERTA NUNCA, porque
//      el temporizador se paró con `clk_I/O`. Es el mismo programa que el caso
//      1 cambiando tres bits, y hace lo contrario.
//   4. `Power-down` + perro guardián — Y AQUÍ SÍ, a la hora del oscilador. Su
//      cuenta no se gatea, y por eso puede morder con el reloj del sistema
//      parado. Es lo que hace del `Power-down` un modo utilizable.
//
// NINGUNO DE LOS CUATRO NECESITA UNA ISR, y eso es a propósito: el bit `I`
// global se deja a cero. La hoja de datos dice que despierta cualquier
// interrupción **habilitada en su máscara**, y con `I` a cero el chip despierta
// y sigue por la instrucción de después del `SLEEP` sin entrar en ninguna
// rutina. Es el idioma de «esperar a que pase algo» sin gastar un vector, y
// comprobarlo así deja el banco sin tabla de vectores de por medio.

#include "Vtb_soc_clk_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static Vtb_soc_clk_top *dut;
static int fallos = 0;
static int comprobaciones = 0;

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static void chk(const char *que, long got, long exp) {
    comprobaciones++;
    if (got != exp) {
        printf("    FALLA %-46s obtenido=%ld esperado=%ld\n", que, got, exp);
        fallos++;
    }
}

static uint16_t LDI(int d, int k) {
    return 0xE000 | ((k & 0xF0) << 4) | (((d - 16) & 0xF) << 4) | (k & 0xF);
}
static uint16_t OUT(int a, int r) {
    return 0xB800 | ((a & 0x30) << 5) | ((r & 0x1F) << 4) | (a & 0x0F);
}
static void STS(std::vector<uint16_t> &p, int dir, int reg) {
    p.push_back(0x9200 | (reg << 4));
    p.push_back((uint16_t)dir);
}
static const uint16_t SLEEP = 0x9588;

enum { IO_DDRB = 0x04, IO_PORTB = 0x05, IO_TIFR0 = 0x15,
       D_TIFR0 = 0x35, D_SMCR = 0x53, D_WDTCSR = 0x60,
       D_TCCR0B = 0x45, D_TIMSK0 = 0x6E };

static void cargar(const std::vector<uint16_t> &p) {
    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0;
    dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < p.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = p[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 1; dut->eval();
}

// `smcr` es el valor de SMCR y `fuente` decide quién tiene permiso para
// despertar. El bucle es SIEMPRE el mismo: mover el pin, limpiar la bandera y
// dormirse. Lo único que cambia entre los cuatro casos son esos dos valores, y
// eso es lo que hace que la comparación signifique algo.
enum Fuente { TIMER0, PERRO };

static std::vector<uint16_t> programa(uint8_t smcr, Fuente fuente) {
    std::vector<uint16_t> p;
    p.push_back(LDI(16, 0xFF));
    p.push_back(OUT(IO_DDRB, 16));

    if (fuente == TIMER0) {
        p.push_back(LDI(16, 0x01));         // TOIE0: la máscara, no el vector
        STS(p, D_TIMSK0, 16);
        p.push_back(LDI(16, 0x01));         // CS=001: desborda cada 256 ciclos
        STS(p, D_TCCR0B, 16);
    } else {
        p.push_back(LDI(16, 0x40));         // WDIE, WDE=0, WDP=0
        STS(p, D_WDTCSR, 16);
    }

    p.push_back(LDI(16, smcr));
    STS(p, D_SMCR, 16);

    // -------- el bucle --------
    size_t bucle = p.size();
    p.push_back(LDI(16, 0x01));
    p.push_back(OUT(IO_PORTB, 16));
    p.push_back(LDI(16, 0x00));
    p.push_back(OUT(IO_PORTB, 16));

    // Limpiar la bandera ANTES de dormirse. Sin esto el chip no llegaria a
    // dormirse nunca: la peticion sigue en pie y despertar gana a dormirse.
    if (fuente == TIMER0) {
        p.push_back(LDI(17, 0x01));         // TOV0 se limpia escribiendo UNO
        p.push_back(OUT(IO_TIFR0, 17));
    } else {
        p.push_back(LDI(16, 0xC0));         // WDIF a uno lo limpia; WDIE sigue
        STS(p, D_WDTCSR, 16);
    }

    p.push_back(SLEEP);

    // Y OTRA VEZ JUSTO DESPUES DEL `SLEEP`, con un `OUT` de un ciclo. Es la
    // forma normal de un programa que despierta y limpia su bandera, y se deja
    // aqui a proposito porque es tambien LA FORMA QUE HARIA VISIBLE UNA
    // ESCRITURA CONGELADA: si el nucleo se quedara dormido presentando la
    // escritura de este `OUT`, el periferico —que en `Idle` sigue corriendo— la
    // aplicaria una vez por cada ciclo suyo, limpiaria `TOV0` para siempre y el
    // chip no despertaria nunca.
    //
    // No pasa, y comprobarlo costo dos mutantes supervivientes: el secuenciador
    // presenta la peticion de escritura REGISTRADA (ADR 0001), asi que al
    // dormirse ya vale cero. El SoC llego a cualificarla con `ce_cpu` por si
    // acaso, y se quito al ver que no hacia falta. Este `OUT` se queda como la
    // prueba de que no hace falta.
    if (fuente == TIMER0) p.push_back(OUT(IO_TIFR0, 17));
    // rjmp hacia atrás hasta el principio del bucle
    int salto = (int)bucle - (int)(p.size() + 1);
    p.push_back(0xC000 | (salto & 0x0FFF));
    return p;
}

// Ciclos del reloj de entrada entre dos subidas de PB0, o -1 si no se mueve.
static long periodo(long limite) {
    int ant = dut->pb_out_v & 1;
    long n = 0;
    while (true) {
        tick();
        int v = dut->pb_out_v & 1;
        if (v && !ant) { ant = v; break; }
        ant = v;
        if (++n > limite) return -1;
    }
    n = 0;
    while (true) {
        tick();
        int v = dut->pb_out_v & 1;
        n++;
        if (v && !ant) return n;
        ant = v;
        if (n > limite) return -1;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_clk_top;

    // ---- 1. Idle: el nucleo se para y el temporizador sigue ----
    cargar(programa(0x01, TIMER0));             // SM=000, SE=1
    // El PRIMER periodo sale 257 y no 256: es el transitorio de arranque —el
    // temporizador lleva ya un rato contando cuando el programa termina de
    // configurarse—. A partir del segundo se asienta. Se mide el de regimen,
    // que es el que dice algo.
    periodo(400000);
    long t_idle = periodo(400000);
    chk("Idle: despierta cada desbordamiento del Timer0", t_idle, 256);

    // ---- 2. sin SE, SLEEP es un NOP ----
    cargar(programa(0x00, TIMER0));             // SE=0
    long t_nop = periodo(400000);
    comprobaciones++;
    if (t_nop < 0 || t_nop >= 256) {
        printf("    FALLA sin SE el bucle deberia correr suelto        obtenido=%ld\n",
               t_nop);
        fallos++;
    }

    // ---- 3. Power-down: el temporizador se para, y ya no despierta nadie ----
    // Mismo programa que el caso 1 con tres bits distintos, y hace lo
    // contrario. Esto es lo que demuestra que los dos relojes son DOS.
    cargar(programa(0x05, TIMER0));             // SM=010, SE=1
    long t_pd = periodo(400000);
    comprobaciones++;
    if (t_pd != -1) {
        printf("    FALLA en Power-down el Timer0 NO deberia despertar  obtenido=%ld\n",
               t_pd);
        fallos++;
    }

    // ---- 4. Power-down: el perro guardian SI, porque es de otro reloj ----
    cargar(programa(0x05, PERRO));
    long t_wdt = periodo(1200000);
    comprobaciones++;
    // 2048 tics del oscilador, y el oscilador va a un tic cada 98 ciclos de
    // entrada en este arnes. Se admite el ciclo de mas o de menos que mete el
    // tiempo que tarda el programa en volver a dormirse.
    if (t_wdt < 200000 || t_wdt > 201500) {
        printf("    FALLA el perro deberia despertar a los ~200 704     obtenido=%ld\n",
               t_wdt);
        fallos++;
    }

    printf("  Idle %ld · sin SE %ld · Power-down con Timer0 %s · con el perro %ld\n",
           t_idle, t_nop, t_pd == -1 ? "no despierta" : "DESPIERTA", t_wdt);

    dut->final();
#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;

    printf("  %d comprobaciones, %d fallos\n", comprobaciones, fallos);
    if (fallos) return 1;
    printf("  el nucleo se para, sigue parado y despierta a su hora\n");
    return 0;
}
