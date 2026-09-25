// AxiomaCore-328 - NeoPixel: el nivel L3 medido con un cronómetro
// SPDX-License-Identifier: Apache-2.0
//
// Una tira WS2812B no tiene reloj: **el bit es la anchura del pulso**. Un cero
// son 350 ns de alto y un uno son 700, con 150 ns de margen cada uno. A
// 12,5 MHz un ciclo son 80 nanosegundos, así que la diferencia entre un color y
// otro se juega en cuatro instrucciones.
//
// Por eso este banco es el que de verdad ejercita el nivel **L3** del contrato
// de compatibilidad. El resto del repositorio comprueba que las instrucciones
// *hagan* lo correcto; aquí se comprueba que *duren* lo que dice el manual. Un
// `SBI` que costara tres ciclos en vez de dos no rompería ningún otro banco —y
// en una tira de verdad se vería como colores equivocados—.
//
// NO SE MIRA NINGUNA SEÑAL INTERNA: se muestrea PB0 y se cronometra, que es
// exactamente lo que haría un analizador lógico enganchado a la placa. Los bits
// se reconstruyen de las anchuras y se comparan con el color que el programa
// dijo que iba a mandar.

#include "Vtb_soc_uart_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static Vtb_soc_uart_top *dut;
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

// Un ciclo del sistema, en nanosegundos: 1 / 12,5 MHz.
static const double NS = 80.0;

// La hoja de datos del WS2812B, con sus márgenes.
struct Rango { const char *nombre; double nominal, margen; };
static const Rango T0H = {"T0H", 350.0, 150.0};
static const Rango T1H = {"T1H", 700.0, 150.0};
static const Rango PER = {"periodo", 1250.0, 600.0};

static void dentro(const Rango &r, double ns) {
    comprobaciones++;
    if (ns < r.nominal - r.margen || ns > r.nominal + r.margen) {
        printf("    FALLA %s mide %.0f ns y la hoja de datos pide %.0f +/- %.0f\n",
               r.nombre, ns, r.nominal, r.margen);
        fallos++;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_uart_top;
    if (argc < 2) { printf("  uso: tb_soc_neopixel <sketch.bin>\n"); return 2; }

    FILE *f = fopen(argv[1], "rb");
    if (!f) { printf("  no se pudo abrir %s\n", argv[1]); return 2; }
    std::vector<uint16_t> flash;
    int lo, hi;
    while ((lo = fgetc(f)) != EOF) {
        hi = fgetc(f);
        flash.push_back((uint16_t)lo | ((uint16_t)(hi == EOF ? 0xFF : hi) << 8));
    }
    fclose(f);

    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0; dut->rxd = 1;
    dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < flash.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = flash[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();

    // ------------------------------------------- el analizador logico
    // Se cronometra cada pulso alto de PB0 y el hueco que lo sigue. Un hueco
    // largo es el REPOSO entre tramas, que es como la tira sabe que la trama
    // ha terminado — y como este banco sabe donde empieza la siguiente.
    struct Pulso { long alto, bajo; };
    std::vector<Pulso> pulsos;
    int ant = dut->portb & 1;
    long alto = 0, bajo = 0;
    const long TOPE = 400000;

    for (long c = 0; c < TOPE; c++) {
        tick();
        int v = dut->portb & 1;
        if (v) {
            if (!ant && alto == 0 && bajo > 0) { /* empieza un pulso */ }
            alto++;
            if (!ant && bajo > 0) { if (!pulsos.empty()) pulsos.back().bajo = bajo; bajo = 0; }
        } else {
            if (ant && alto > 0) { pulsos.push_back({alto, 0}); alto = 0; }
            bajo++;
        }
        ant = v;
    }

    comprobaciones++;
    if (pulsos.size() < 24) {
        printf("    FALLA solo se vieron %zu pulsos en %ld ciclos\n",
               pulsos.size(), TOPE);
        fallos++;
        delete dut;
        printf("  %d comprobaciones, %d fallos\n", comprobaciones, fallos);
        return 1;
    }

    // LA TRAMA SE BUSCA POR SU FINAL, no por su principio, y eso no es un
    // rodeo: en el WS2812B lo que delimita una trama **es el reposo**, no un
    // bit de arranque. Se busca un hueco de mas de 50 us y se toman los 24
    // pulsos que hay DELANTE — que son, por definicion, la trama que acaba de
    // terminar. Buscar el pulso que va detras del hueco parece lo natural y no
    // lo es: el muestreo puede empezar a mitad de una trama, y entonces la
    // cuenta se desplaza sin que nada lo diga.
    size_t fin = 0;
    // Desde el 23 y no desde el 24: el indice 23 es el ultimo bit de la
    // primera trama completa que se ve, y empezar en el 24 se lo salta.
    for (size_t i = 23; i < pulsos.size(); i++) {
        if (pulsos[i].bajo * NS > 50000.0) { fin = i; break; }
    }
    comprobaciones++;
    if (fin == 0) {
        printf("    FALLA no se encontro el reposo de 50 us que cierra la trama\n");
        fallos++;
        delete dut;
        printf("  %d comprobaciones, %d fallos\n", comprobaciones, fallos);
        return 1;
    }
    const size_t ini = fin - 23;
    printf("  reposo de %.0f us tras el bit 24\n", pulsos[fin].bajo * NS / 1000.0);

    // ------------------------------------------------ los anchos medidos
    long ancho0 = 0, ancho1 = 0, n0 = 0, n1 = 0;
    for (size_t i = ini; i < ini + 24 && i < pulsos.size(); i++) {
        // El umbral va justo en medio de los dos anchos posibles. Si el chip
        // se desviara lo bastante como para cruzarlo, el bit saldria cambiado
        // y la comparacion del color de abajo lo diria.
        if (pulsos[i].alto <= 6) { ancho0 += pulsos[i].alto; n0++; }
        else                     { ancho1 += pulsos[i].alto; n1++; }
    }
    comprobaciones++;
    if (!n0 || !n1) {
        printf("    FALLA la trama no tiene ceros y unos: n0=%ld n1=%ld\n", n0, n1);
        fallos++;
    } else {
        dentro(T0H, (double)ancho0 / n0 * NS);
        dentro(T1H, (double)ancho1 / n1 * NS);
        // El periodo: alto mas bajo del mismo bit.
        double per = 0; long np = 0;
        for (size_t i = ini; i + 1 <= fin; i++) {
            per += (pulsos[i].alto + pulsos[i].bajo); np++;
        }
        dentro(PER, per / np * NS);
        printf("  T0H %.0f ns · T1H %.0f ns · periodo %.0f ns\n",
               (double)ancho0 / n0 * NS, (double)ancho1 / n1 * NS, per / np * NS);
    }

    // ------------------------------------------- el color, reconstruido
    // Los bits van de mas significativo a menos, y los bytes en orden G, R, B
    // — que es el del WS2812B y no el RGB que uno esperaria.
    uint8_t leido[3] = {0, 0, 0};
    for (int b = 0; b < 3; b++)
        for (int k = 0; k < 8; k++) {
            size_t i = ini + b * 8 + k;
            if (i < pulsos.size() && pulsos[i].alto > 6)
                leido[b] |= (uint8_t)(0x80 >> k);
        }
    chk("byte G", leido[0], 0xA5);
    chk("byte R", leido[1], 0x00);
    chk("byte B", leido[2], 0xFF);

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
        printf("  Aqui no se mide que las instrucciones hagan lo correcto, sino\n"
               "  que DUREN lo que dice el manual: es el nivel L3 del contrato.\n");
        return 1;
    }
    printf("  la trama WS2812B sale dentro de tolerancia y el color es el que se pidio\n");
    return 0;
}
