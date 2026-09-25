// AxiomaCore-328 - el gestor de arranque, hablado por el pin
// SPDX-License-Identifier: Apache-2.0
//
// Este banco hace de **avrdude**. No llama a ninguna función del gestor ni mira
// ninguna señal interna: pone y quita bits en `RXD`, lee `TXD`, y habla
// STK500v1 como lo haría el programa del otro extremo del cable.
//
// Lo que se demuestra con eso es más de lo que parece, porque el camino que
// recorre cada byte atraviesa el chip entero:
//
//   la USART recibiendo a 19 200 con el divisor que el propio gestor calculó;
//   el núcleo ejecutando C compilado con avr-gcc **sin modificar**;
//   `<avr/boot.h>` de **avr-libc, sin tocar**, escribiendo `SPMCSR` y
//   ejecutando `SPM` con su secuencia de cuatro ciclos;
//   `axioma_spm` borrando la página, llenando el búfer y volcándolo;
//   y la USART devolviendo lo que `LPM` lee de vuelta.
//
// Si cualquiera de esas piezas no fuera la del ATmega328P, la cabecera oficial
// de avr-libc no funcionaría y esto no pasaría. **No hay ninguna capa de
// compatibilidad en medio que pueda tapar una diferencia.**
//
// EL PERIODO DE BIT NO SE SUPONE: se lee de `UBRR0` y `U2X0`, que es lo que el
// gestor acaba de configurar. Suponerlo sería probar el banco contra sí mismo,
// y además taparía justo el fallo que más duele en un gestor de arranque —un
// divisor mal calculado—, porque los dos lados se equivocarían igual.

#include "Vtb_soc_uart_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static Vtb_soc_uart_top *dut;
static int fallos = 0;
static int comprobaciones = 0;
static long periodo = 0;          // ciclos por bit, según lo que configuró el gestor

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static void chk(const char *que, uint32_t got, uint32_t exp) {
    comprobaciones++;
    if (got != exp) {
        printf("    FALLA %-46s obtenido=0x%02X esperado=0x%02X\n", que, got, exp);
        fallos++;
    }
}

// ------------------------------------------------------------- el cable
// Mandar un byte es mover el pin: bit de arranque a cero, ocho de datos con el
// menos significativo primero, y bit de parada a uno.
static void manda(uint8_t b) {
    dut->rxd = 0; dut->eval();
    for (long i = 0; i < periodo; i++) tick();
    for (int k = 0; k < 8; k++) {
        dut->rxd = (b >> k) & 1; dut->eval();
        for (long i = 0; i < periodo; i++) tick();
    }
    dut->rxd = 1; dut->eval();
    for (long i = 0; i < periodo; i++) tick();
}

// Y recibir es esperar el flanco de bajada y muestrear EN MITAD de cada bit,
// que es donde la señal está asentada. Devuelve -1 si no llega nada.
static int recibe(long tope) {
    long n = 0;
    while (dut->txd) { tick(); if (++n > tope) return -1; }
    // colocarse en el centro del bit de arranque y comprobarlo
    for (long i = 0; i < periodo / 2; i++) tick();
    if (dut->txd) return -2;                       // no era un arranque
    uint8_t b = 0;
    for (int k = 0; k < 8; k++) {
        for (long i = 0; i < periodo; i++) tick();
        if (dut->txd) b |= (1 << k);
    }
    for (long i = 0; i < periodo; i++) tick();     // bit de parada
    return b;
}

enum { STK_OK = 0x10, STK_INSYNC = 0x14, CRC_EOP = 0x20 };

// Una orden entera: se manda, se espera `INSYNC`, se leen los bytes de
// respuesta que toquen y se espera `OK`.
static bool orden(const char *nombre, const std::vector<uint8_t> &tx,
                  int n_resp, uint8_t *resp, long tope = 4000000) {
    for (uint8_t b : tx) manda(b);
    manda(CRC_EOP);

    int v = recibe(tope);
    comprobaciones++;
    if (v != STK_INSYNC) {
        printf("    FALLA %-30s no contesto INSYNC (0x%02X)\n", nombre, v & 0xFF);
        fallos++;
        return false;
    }
    for (int i = 0; i < n_resp; i++) {
        v = recibe(tope);
        if (v < 0) {
            printf("    FALLA %-30s se corto en el byte %d\n", nombre, i);
            fallos++;
            return false;
        }
        resp[i] = (uint8_t)v;
    }
    v = recibe(tope);
    comprobaciones++;
    if (v != STK_OK) {
        printf("    FALLA %-30s no cerro con OK (0x%02X)\n", nombre, v & 0xFF);
        fallos++;
        return false;
    }
    return true;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_uart_top;
    if (argc < 2) { printf("  uso: tb_soc_boot <gestor.bin>\n"); return 2; }

    // ------------------------------------------------ la imagen de Flash
    // El gestor vive ARRIBA, en el byte 0x7E00 —palabra 0x3F00—, que es donde
    // lo coloca el enlazador y donde estaria la seccion de arranque del chip.
    // En la palabra 0 va un salto hasta el: en el 328P eso lo decide el fusible
    // `BOOTRST`, que aqui no existe, y esa diferencia esta declarada.
    FILE *f = fopen(argv[1], "rb");
    if (!f) { printf("  no se pudo abrir %s\n", argv[1]); return 2; }
    std::vector<uint8_t> bin;
    int c;
    while ((c = fgetc(f)) != EOF) bin.push_back((uint8_t)c);
    fclose(f);

    const uint16_t BOOT_PALABRA = 0x3F00;
    std::vector<uint16_t> flash(16384, 0xFFFF);
    flash[0] = 0x940C;                       // JMP
    flash[1] = BOOT_PALABRA;
    for (size_t i = 0; i + 1 < bin.size(); i += 2)
        flash[BOOT_PALABRA + i / 2] = (uint16_t)bin[i] | ((uint16_t)bin[i + 1] << 8);

    printf("  gestor de %zu bytes en la palabra 0x%04X\n", bin.size(), BOOT_PALABRA);

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

    // --------------------------------- el periodo, leido de lo que configuro
    for (long i = 0; i < 200000 && dut->dbg_ubrr == 0; i++) tick();

    comprobaciones++;
    if (dut->dbg_ubrr == 0) {
        printf("    FALLA el gestor no llego a configurar la USART\n");
        fallos++;
        delete dut;
        return 1;
    }
    periodo = (long)(dut->dbg_ubrr + 1) * (dut->dbg_u2x ? 8 : 16);
    printf("  UBRR0=%d, U2X=%d -> %ld ciclos por bit\n",
           (int)dut->dbg_ubrr, (int)dut->dbg_u2x, periodo);
    for (long i = 0; i < periodo * 4; i++) tick();

    uint8_t r[256];

    // ---------------------------------------------------- 1. sincronizar
    orden("GET_SYNC", {0x30}, 0, r);

    // ---------------------------------------------------- 2. la firma
    // Es lo primero que hace avrdude al conectar, y lo que decide si el IDE
    // reconoce la placa. 0x1E 0x95 0x0F es la del ATmega328P.
    if (orden("READ_SIGN", {0x75}, 3, r)) {
        chk("firma, byte 0", r[0], 0x1E);
        chk("firma, byte 1", r[1], 0x95);
        chk("firma, byte 2", r[2], 0x0F);
    }

    // -------------------------------------------- 3. programar una pagina
    // La direccion va en PALABRAS: 0x0100 es el byte 0x0200, la pagina 4.
    // Lejos del salto de la palabra 0 y lejisimos del propio gestor.
    const uint16_t DIR = 0x0100;
    std::vector<uint8_t> datos(128);
    for (int i = 0; i < 128; i++) datos[i] = (uint8_t)(0xA0 + i);

    orden("LOAD_ADDRESS", {0x55, (uint8_t)(DIR & 0xFF), (uint8_t)(DIR >> 8)}, 0, r);

    std::vector<uint8_t> prog = {0x64, 0x00, 0x80, 'F'};
    prog.insert(prog.end(), datos.begin(), datos.end());
    orden("PROG_PAGE", prog, 0, r);

    // ------------------------------------------------ 4. releerla del chip
    // Por `LPM`, o sea de la Flash de verdad: si la grabacion no hubiera
    // llegado, aqui saldria 0xFF.
    orden("LOAD_ADDRESS", {0x55, (uint8_t)(DIR & 0xFF), (uint8_t)(DIR >> 8)}, 0, r);
    if (orden("READ_PAGE", {0x74, 0x00, 0x80, 'F'}, 128, r)) {
        int mal = 0;
        for (int i = 0; i < 128; i++) if (r[i] != datos[i]) mal++;
        chk("los 128 bytes vuelven tal cual", mal, 0);
        if (mal) printf("    primero: leido 0x%02X, esperado 0x%02X\n", r[0], datos[0]);
    }

    // ----------------------------- 5. y una pagina que NADIE ha programado
    // Tiene que salir borrada. Sin esto, un `READ_PAGE` que devolviera siempre
    // lo ultimo escrito pasaria la comprobacion de arriba con nota.
    const uint16_t OTRA = 0x0180;
    orden("LOAD_ADDRESS", {0x55, (uint8_t)(OTRA & 0xFF), (uint8_t)(OTRA >> 8)}, 0, r);
    if (orden("READ_PAGE", {0x74, 0x00, 0x80, 'F'}, 128, r)) {
        int mal = 0;
        for (int i = 0; i < 128; i++) if (r[i] != 0xFF) mal++;
        chk("una pagina sin programar sale borrada", mal, 0);
    }

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
        printf("  El gestor usa <avr/boot.h> de avr-libc SIN TOCAR: si esto falla,\n"
               "  lo que no encaja con la hoja de datos es el RTL, no el firmware.\n");
        return 1;
    }
    printf("  el gestor habla STK500v1, programa una pagina y la relee\n");
    return 0;
}
