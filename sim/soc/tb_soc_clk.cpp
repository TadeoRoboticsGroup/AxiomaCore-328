// AxiomaCore-328 - que la habilitación de reloj LLEGUE, medido por fuera
// SPDX-License-Identifier: Apache-2.0
//
// Este banco existe por un agujero concreto, y conviene decirlo entero porque
// es la cara mala de una decisión buena.
//
// Convertir el chip a habilitación de reloj (ADR 0003) es seguro justamente
// porque con `CLKPS`=0 la habilitación vale uno siempre y el dispositivo queda
// **bit a bit** como estaba: los treinta y cinco objetivos de la regresión
// siguen pasando sin tocar una línea, y si un módulo se convierte mal, lo dice
// su propio banco.
//
// Pero eso mismo significa que **NADIE COMPRUEBA LA HABILITACIÓN**. Un módulo
// al que se le olvide —o un `.ce()` que el SoC no cablee— pasa su banco, pasa
// lint, pasa síntesis y pasa el diferencial, porque todos corren a reloj
// entero. El fallo sólo aparece el día que un programa baja el reloj para
// ahorrar corriente, y entonces aparece como un baudio que no cuadra.
//
// Así que se mide por fuera, y con un programa de verdad:
//
//   1. el programa hace la secuencia de `CLKPR` y se pone a mover un pin en un
//      bucle cerrado;
//   2. el banco cuenta CICLOS DEL RELOJ DE ENTRADA entre dos transiciones;
//   3. el periodo tiene que multiplicarse por dos cada vez que sube `CLKPS`.
//
// Eso recorre el camino entero: el núcleo ejecuta más despacio, el bus lleva la
// escritura más despacio y el puerto de E/S la registra más despacio. Si
// cualquiera de los tres se quedó sin habilitación, la proporción no sale.
//
// Y LA OTRA MITAD: el oscilador del perro guardián **no** se divide. Es de otro
// reloj, y de ahí sale que el perro pueda morder con el reloj del sistema
// parado. Se cuenta cuántos tics del oscilador caben en una vuelta del bucle:
// si `CLKPR` lo afectara, la proporción sería constante en vez de doblarse.

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

static uint8_t pb0()  { return dut->pb_out_v & 0x01; }
static uint8_t oc0a() { return (dut->pd_out_v >> 6) & 0x01; }

static void chk(const char *que, long got, long exp) {
    comprobaciones++;
    if (got != exp) {
        printf("    FALLA %-46s obtenido=%ld esperado=%ld\n", que, got, exp);
        fallos++;
    }
}

// ------------------------------------------------------------- opcodes
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
static const uint16_t RJMP_ATRAS4 = 0xCFFB;   // rjmp -5: al principio del bucle

enum { IO_DDRB = 0x04, IO_PORTB = 0x05, D_CLKPR = 0x61,
       D_DDRD = 0x2A, D_TCCR0A = 0x44, D_TCCR0B = 0x45, D_OCR0A = 0x47,
       D_UBRR0L = 0xC4, D_UCSR0B = 0xC1, D_UDR0 = 0xC6, D_WDTCSR = 0x60 };

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

// El programa: pone CLKPS por su secuencia y se queda moviendo PB0. El bucle es
// de tamaño fijo, así que lo único que puede cambiar su duración medida en
// ciclos del reloj de ENTRADA es el prescaler.
static std::vector<uint16_t> programa(int clkps) {
    std::vector<uint16_t> p;
    p.push_back(LDI(16, 0xFF));
    p.push_back(OUT(IO_DDRB, 16));      // todo el puerto B, salida

    // La secuencia de CLKPR: CLKPCE solo, y dentro de cuatro ciclos el valor.
    p.push_back(LDI(16, 0x80));
    STS(p, D_CLKPR, 16);
    p.push_back(LDI(16, clkps));
    STS(p, D_CLKPR, 16);

    // El bucle: cinco palabras, y siempre las mismas.
    p.push_back(LDI(16, 0x01));
    p.push_back(OUT(IO_PORTB, 16));
    p.push_back(LDI(16, 0x00));
    p.push_back(OUT(IO_PORTB, 16));
    p.push_back(RJMP_ATRAS4);
    return p;
}

// El segundo programa: deja al Timer0 conmutando OC0A -PD6- en modo CTC y se
// queda parado. Lo que se mide aqui NO es el nucleo: es LA BASE DE TIEMPO DE UN
// PERIFERICO. El bucle del primer programa solo depende de la habilitacion del
// nucleo -las del bus y el puerto de E/S son redundantes, porque `io_we` ya va
// cualificado con `ce_cpu`-, asi que sin esto la mitad periferica se quedaria
// sin comprobar.
static std::vector<uint16_t> programa_timer(int clkps, int cs) {
    std::vector<uint16_t> p;
    p.push_back(LDI(16, 0x40));
    STS(p, D_DDRD, 16);                 // PD6 (OC0A) como salida

    p.push_back(LDI(16, 0x80));
    STS(p, D_CLKPR, 16);
    p.push_back(LDI(16, clkps));
    STS(p, D_CLKPR, 16);

    p.push_back(LDI(16, 0x42));         // COM0A=01 conmutar, WGM=010 (CTC)
    STS(p, D_TCCR0A, 16);
    p.push_back(LDI(16, 0x13));         // OCR0A = 19: conmuta cada 20 ciclos
    STS(p, D_OCR0A, 16);
    p.push_back(LDI(16, cs));           // la toma del prescaler compartido
    STS(p, D_TCCR0B, 16);
    p.push_back(0xCFFF);                // rjmp aqui
    return p;
}

// El tercer programa: LA USART, que es el ejemplo que motiva el ADR 0003. Un
// generador de baudios que contara con el reloj sin dividir dejaria a un
// programa que baja a f/8 transmitiendo ocho veces mas rapido de lo que pidio,
// y el otro extremo del cable no entenderia nada. Aqui se mide el ANCHO DEL BIT
// DE ARRANQUE en ciclos del reloj de entrada.
//
// No es hipotetico: al convertir el chip, el generador de baudios se quedo sin
// gatear y ningun banco lo noto. Este lo nota.
static std::vector<uint16_t> programa_usart(int clkps) {
    std::vector<uint16_t> p;
    p.push_back(LDI(16, 0x80));
    STS(p, D_CLKPR, 16);
    p.push_back(LDI(16, clkps));
    STS(p, D_CLKPR, 16);

    p.push_back(LDI(16, 0x03));         // UBRR0L = 3: el bit dura 16*4 = 64
    STS(p, D_UBRR0L, 16);
    p.push_back(LDI(16, 0x08));         // TXEN0
    STS(p, D_UCSR0B, 16);
    p.push_back(LDI(16, 0x55));         // 0x55: tras el arranque viene un uno,
    STS(p, D_UDR0, 16);                 // asi que el bit de arranque se ve solo
    p.push_back(0xCFFF);
    return p;
}

// El ancho del pulso bajo de TXD (PD1): el bit de arranque.
static long ancho_arranque() {
    long n = 0;
    // PRIMERO HAY QUE ESPERAR AL REPOSO. Antes de `TXEN0` el pin no lo lleva la
    // USART y vale cero, asi que medir el primer tramo bajo mide la puesta en
    // marcha del programa y no el bit — 13 ciclos en vez de 64. Paso.
    while (!((dut->pd_out_v >> 1) & 1)) { tick(); if (++n > 500000) return -1; }
    n = 0;
    while ((dut->pd_out_v >> 1) & 1)    { tick(); if (++n > 500000) return -1; }
    n = 0;
    while (!((dut->pd_out_v >> 1) & 1)) { tick(); if (++n > 500000) return -1; }
    return n;
}

// El cuarto programa: EL PERRO GUARDIAN, que es la otra mitad de la decision.
// Su cuenta NO se gatea con `ce` porque corre con su propio oscilador, y de ahi
// sale que pueda morder con el reloj del sistema parado — que es justo para lo
// que existe, y lo que permite despertar de un `Power-down`.
//
// Medirlo contando tics del oscilador POR FUERA del chip no prueba nada: los
// tics estan ahi igual, la pregunta es si el perro los usa. Lo dijo un mutante
// superviviente. Asi que se mide EL INTERVALO ENTRE DOS MORDISCOS, que es
// tiempo de oscilador puro y tiene que salir igual con cualquier `CLKPS`.
static std::vector<uint16_t> programa_wdt(int clkps) {
    std::vector<uint16_t> p;
    p.push_back(LDI(16, 0x80));
    STS(p, D_CLKPR, 16);
    p.push_back(LDI(16, clkps));
    STS(p, D_CLKPR, 16);

    // La secuencia del perro: WDCE y WDE a uno A LA VEZ, y dentro de cuatro
    // ciclos el valor que se quiere. WDP=0, el periodo mas corto.
    p.push_back(LDI(16, 0x18));         // WDCE | WDE
    STS(p, D_WDTCSR, 16);
    p.push_back(LDI(16, 0x08));         // WDE, WDP=0
    STS(p, D_WDTCSR, 16);
    p.push_back(0xCFFF);
    return p;
}

// El intervalo, en ciclos del reloj de entrada, entre dos mordiscos.
static long entre_mordiscos() {
    long n = 0;
    while (!dut->wdt_reset_v) { tick(); if (++n > 4000000) return -1; }
    tick();
    n = 0;
    while (!dut->wdt_reset_v) { tick(); if (++n > 4000000) return -1; }
    return n;
}

// Cuenta ciclos del reloj de ENTRADA entre dos subidas de PB0.
static long periodo_pin(uint8_t (*leer)(), long *tics_osc) {
    int  ant = leer() & 1;
    long n = 0, osc = 0;
    // colocarse en una subida
    while (true) {
        tick();
        int v = leer() & 1;
        if (v && !ant) { ant = v; break; }
        ant = v;
        if (++n > 2000000) return -1;
    }
    n = 0;
    while (true) {
        tick();
        if (dut->osc_tick_v) osc++;
        int v = leer() & 1;
        n++;
        if (v && !ant) break;
        ant = v;
        if (n > 2000000) return -1;
    }
    *tics_osc = osc;
    return n;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_clk_top;

    printf("  el periodo del bucle, medido en ciclos del reloj de entrada\n");

    long base = 0, base_osc = 0;
    for (int k = 0; k <= 3; k++) {
        cargar(programa(k));
        long osc = 0;
        long t = periodo_pin(pb0, &osc);
        if (t < 0) { printf("    FALLA el pin no se movio con CLKPS=%d\n", k);
                     fallos++; comprobaciones++; continue; }
        if (k == 0) base = t;

        char n[80];
        snprintf(n, sizeof n, "CLKPS=%d: el bucle dura %d veces mas", k, 1 << k);
        chk(n, t, base << k);

        // LA OTRA MITAD, y hay que medirla sobre una VENTANA FIJA de ciclos de
        // entrada y no sobre el bucle: el bucle dura 2^k veces mas, asi que
        // contar tics dentro de el daria 2^k veces mas aunque el oscilador
        // estuviera dividido igual que todo lo demas. Sobre una ventana fija,
        // el numero de tics tiene que salir EL MISMO mande lo que mande CLKPR,
        // y eso solo pasa si de verdad es otro reloj.
        long osc2 = 0;
        for (int i = 0; i < 10000; i++) { tick(); if (dut->osc_tick_v) osc2++; }
        if (k == 0) base_osc = osc2;
        snprintf(n, sizeof n, "CLKPS=%d: el oscilador NO se divide", k);
        chk(n, osc2, base_osc);
    }

    printf("  un bucle de %ld ciclos a reloj entero; %ld tics del oscilador\n"
           "  en 10 000 ciclos de entrada, los mismos con cualquier CLKPS\n",
           base, base_osc);

    // ------------------------------------------------------------------------
    // LA BASE DE TIEMPO DE UN PERIFERICO. El Timer0 conmuta OC0A cada
    // OCR0A+1 ciclos de SISTEMA, asi que medido en ciclos de entrada tiene que
    // doblarse igual que el bucle. Esto recorre el prescaler compartido y el
    // motor de forma de onda, que es la mitad del chip que el primer programa
    // no toca.
    // Se mide con DOS tomas del prescaler a proposito. Con `CS`=001 el reloj
    // del temporizador sale directo de `clk_I/O` y no pasa por el contador de
    // diez bits compartido -lo dice la figura del prescaler, y este proyecto ya
    // lo tenia escrito-, asi que esa medida comprueba el motor de forma de onda
    // pero NO el contador. Con `CS`=010 pasa por el, y entonces si.
    //
    // No es una precaucion teorica: se quito la habilitacion del prescaler a
    // mano y la medida de `CS`=001 seguia pasando.
    printf("  y el periodo de OC0A, que es la base de tiempo de un periferico\n");
    long base_t = 0;
    for (int k = 0; k <= 2; k++) {
        cargar(programa_timer(k, 0x01));
        long osc = 0;
        long t = periodo_pin(oc0a, &osc);
        if (t < 0) { printf("    FALLA OC0A no conmuto con CLKPS=%d\n", k);
                     fallos++; comprobaciones++; continue; }
        if (k == 0) base_t = t;
        char n[80];
        snprintf(n, sizeof n, "CLKPS=%d: OC0A conmuta %d veces mas despacio", k, 1 << k);
        chk(n, t, base_t << k);
    }
    printf("  OC0A a %ld ciclos de entrada con el reloj entero (CS=001)\n", base_t);

    long base_p = 0;
    for (int k = 0; k <= 2; k++) {
        cargar(programa_timer(k, 0x02));        // CS=010: por el contador de 10 bits
        long osc = 0;
        long t = periodo_pin(oc0a, &osc);
        if (t < 0) { printf("    FALLA OC0A no conmuto con CS=010 y CLKPS=%d\n", k);
                     fallos++; comprobaciones++; continue; }
        if (k == 0) base_p = t;
        char n[80];
        snprintf(n, sizeof n, "CLKPS=%d por el prescaler compartido", k);
        chk(n, t, base_p << k);
    }
    printf("  y a %ld por la toma de clk/8, que pasa por el contador compartido\n",
           base_p);

    // ------------------------------------------------------------------------
    printf("  y el bit de la USART, que es el ejemplo del ADR 0003\n");
    long base_u = 0;
    for (int k = 0; k <= 2; k++) {
        cargar(programa_usart(k));
        long t = ancho_arranque();
        if (t < 0) { printf("    FALLA la USART no transmitio con CLKPS=%d\n", k);
                     fallos++; comprobaciones++; continue; }
        if (k == 0) base_u = t;
        char n[80];
        snprintf(n, sizeof n, "CLKPS=%d: el bit dura %d veces mas", k, 1 << k);
        chk(n, t, base_u << k);
    }
    printf("  un bit de arranque de %ld ciclos de entrada con el reloj entero\n",
           base_u);

    // ------------------------------------------------------------------------
    printf("  y el perro guardian, que NO se divide porque es de otro reloj\n");
    long base_w = 0;
    for (int k = 0; k <= 2; k++) {
        cargar(programa_wdt(k));
        long t = entre_mordiscos();
        if (t < 0) { printf("    FALLA el perro no mordio con CLKPS=%d\n", k);
                     fallos++; comprobaciones++; continue; }
        if (k == 0) base_w = t;
        char n[80];
        snprintf(n, sizeof n, "CLKPS=%d: el perro muerde a la misma hora", k);
        chk(n, t, base_w);
    }
    printf("  %ld ciclos de entrada entre mordiscos, con cualquier CLKPS\n",
           base_w);

    dut->final();
#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;

    printf("  %d comprobaciones, %d fallos\n", comprobaciones, fallos);
    if (fallos) {
        printf("  Si el periodo no se dobla, hay un modulo SIN la habilitacion:\n"
               "  con CLKPS=0 eso no se nota en ningun otro banco.\n");
        return 1;
    }
    printf("  la habilitacion llega al nucleo, al bus y al puerto de E/S\n");
    return 0;
}
