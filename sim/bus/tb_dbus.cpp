// AxiomaCore-328 - fabric del espacio de datos contra un modelo de referencia
// SPDX-License-Identifier: Apache-2.0
//
// El espacio de direcciones del bus es de 16 bits: 65 536 direcciones. Como en
// la ALU y en el decodificador, es enumerable POR COMPLETO, así que no hay
// motivo para muestrear: se barre entero, en lectura y en escritura.
//
// El modelo de referencia transcribe el mapa de docs/01-arquitectura.md §2 y no
// mira el RTL. Comprueba, para cada dirección:
//
//   1. que la región elegida es la correcta, y que es UNA sola
//   2. que la traducción de dirección de la SRAM resta 0x0100
//   3. que la del espacio de I/O resta 0x0020
//   4. que fuera de las regiones mapeadas no se activa nada
//   5. que el multiplexor de lectura devuelve el dato de la región que se leyó,
//      y 0x00 donde no hay nadie
//
// La quinta es la que justifica el registro de flanco de bajada: se comprueba
// DESPUÉS del flanco, que es cuando el núcleo consume el dato.

#include "Vaxioma_dbus.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

static Vaxioma_dbus *dut;
static int fails = 0;
static long checks = 0;

static void chk(const char *what, uint32_t got, uint32_t exp, uint32_t addr) {
    checks++;
    if (got != exp && ++fails <= 8)
        printf("    FALLA %-26s addr=0x%04X  obtenido=%02X esperado=%02X\n",
               what, addr, got, exp);
}

// Modelo de referencia: el mapa del espacio de datos, escrito desde el
// documento de arquitectura.
static const uint32_t IO_BASE = 0x0020, SRAM_BASE = 0x0100, RAMEND = 0x08FF;
static bool ref_io(uint32_t a)   { return a >= IO_BASE   && a < SRAM_BASE; }
static bool ref_sram(uint32_t a) { return a >= SRAM_BASE && a <= RAMEND; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_dbus;

    dut->rst_n = 0; dut->clk = 0; dut->re = 0; dut->we = 0;

    dut->ce = 1;   // a reloj entero: la habilitacion es cosa de CLKPR (ADR 0003)
    dut->addr = 0; dut->wdata = 0; dut->sram_rdata = 0;
    dut->io_rdata = 0; dut->io_sel = 0;
    dut->eval();
    dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval();
    dut->rst_n = 1; dut->eval();

    for (uint32_t a = 0; a < 65536; a++) {
        const bool eio = ref_io(a), esram = ref_sram(a);

        // Datos distintos en cada camino: si el multiplexor se equivoca de
        // región, el valor lo delata en vez de coincidir por casualidad.
        const uint8_t sram_val = (uint8_t)(a * 7 + 13);
        const uint8_t io_val   = (uint8_t)(a * 11 + 71);

        for (int op = 0; op < 2; op++) {          // 0 = lectura, 1 = escritura
            const bool rd = (op == 0), wr = (op == 1);
            dut->addr = a;
            dut->re = rd; dut->we = wr;
            dut->wdata = (uint8_t)(a ^ 0x5A);
            dut->sram_rdata = sram_val;
            dut->io_rdata = io_val;
            // Un periférico responde en toda la I/O estándar; la extendida se
            // deja sin reclamar a propósito, para comprobar que ahí se lee 0.
            dut->io_sel = eio && (a < 0x0060);
            dut->eval();

            // --- 1 a 4: encaminamiento, antes del flanco ---
            chk("sram_en",   dut->sram_en,   esram && (rd || wr), a);
            chk("sram_we",   dut->sram_we,   esram && wr,         a);
            chk("io_re",     dut->io_re,     eio && rd,           a);
            chk("io_we",     dut->io_we,     eio && wr,           a);
            if (esram) chk("sram_addr", dut->sram_addr, (a - SRAM_BASE) & 0x7FF, a);
            if (eio)   chk("io_addr",   dut->io_addr,   (a - IO_BASE) & 0xFF,    a);
            // Nunca las dos regiones a la vez.
            chk("regiones excluyentes", (dut->sram_en && dut->io_re) ? 1 : 0, 0, a);

            // --- flanco: aquí captura el registro de flanco de bajada ---
            dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval();

            // --- 5: el dato que ve el núcleo ---
            if (rd) {
                uint32_t exp = esram ? sram_val
                             : (eio && (a < 0x0060)) ? io_val : 0x00;
                chk("rdata", dut->rdata, exp, a);

                // Y AHORA LO QUE DE VERDAD IMPORTA. El núcleo consume el dato
                // en el segundo ciclo de LD, cuando YA NO mantiene la
                // dirección. Si la selección de región fuera combinacional en
                // vez de registrarse en flanco de bajada, aquí el multiplexor
                // elegiría la región de la dirección NUEVA y devolvería
                // basura. Se comprueba soltando la dirección hacia otra
                // región distinta.
                dut->addr = esram ? 0x0030 : 0x0200;
                dut->re = 0; dut->we = 0;
                dut->eval();
                chk("rdata tras soltar la dirección", dut->rdata, exp, a);
            }
        }
    }

    delete dut;
    printf("  Bus de datos contra modelo de referencia\n");
    printf("  %ld comprobaciones sobre las 65 536 direcciones, %d fallos\n",
           checks, fails);
    if (fails) return 1;
    printf("  0 fallos\n");
    return 0;
}
