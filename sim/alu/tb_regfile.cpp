// AxiomaCore-328 - banco de registros contra un modelo de referencia
// SPDX-License-Identifier: Apache-2.0
//
// No es una prueba dirigida: mantiene un modelo sombra de los 32 registros y
// lanza operaciones aleatorias, comparando las cuatro salidas en cada ciclo.
// Al final barre los 32 registros por el puerto de depuración.
//
// El modelo aplica las mismas reglas que documenta el RTL:
//   - las lecturas devuelven el valor ANTES del flanco
//   - la escritura de 16 bits gana a la de 8 sobre el mismo par
//   - el par que se LEE y el que se ESCRIBE son independientes: es lo que
//     permite que MOVW copie de un par a otro en un solo ciclo. El estímulo
//     los hace coincidir sólo una parte de las veces, para ejercitar tanto el
//     camino de MOVW como la prioridad de escritura sobre el mismo par.

#include "Vaxioma_regfile.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <random>

static Vaxioma_regfile *dut;
static uint8_t model[32];
static int fails = 0;
static long checks = 0;

static void fail(const char *what, uint32_t got, uint32_t exp, long cyc) {
    if (++fails <= 6)
        printf("    FALLA ciclo %ld  %-12s obtenido=%04X esperado=%04X\n",
               cyc, what, got, exp);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_regfile;
    std::mt19937 rng(20260908);
    auto R = [&](int n) { return (uint32_t)(rng() % n); };

    // ---- reset ----
    // El reset debe DEJAR clk EN BAJO. Si lo deja en alto, el primer ciclo del
    // bucle no produce flanco de subida y su escritura se pierde en el DUT
    // pero no en el modelo. Fallo latente que solo aparece cuando la secuencia
    // aleatoria activa una escritura en el ciclo 0.
    dut->rst_n = 0; dut->we = 0; dut->we16 = 0; dut->ds_addr = 0;
    dut->a16_pair = 0; dut->w16_pair = 0;
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval(); dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    dut->rst_n = 1;
    memset(model, 0, sizeof(model));

    for (int i = 0; i < 32; i++) {
        dut->dbg_addr = i; dut->eval();
        checks++;
        if (dut->dbg_data != 0) fail("reset", dut->dbg_data, 0, -1);
    }

    // ---- estímulo aleatorio ----
    const long N = 200000;
    for (long cyc = 0; cyc < N; cyc++) {
        uint32_t rd_a = R(32), rr_a = R(32), w_a = R(32), pair = R(16), dbg = R(32);
        uint32_t wd = R(256), w16 = R(65536);
        // El par de escritura coincide con el de lectura un 40 % de las veces
        // (ADIW, SBIW, punteros con post-inc y pre-dec) y difiere el resto
        // (MOVW). Con un solo par nunca se probaría el caso de MOVW; usando
        // siempre pares distintos, no se probaría la prioridad.
        uint32_t wpair = (R(100) < 40) ? pair : R(16);
        // Las escrituras coinciden a menudo, para ejercitar la prioridad.
        uint32_t we = (R(100) < 55), we16 = (R(100) < 35);

        dut->rd_addr = rd_a; dut->rr_addr = rr_a; dut->dbg_addr = dbg;
        dut->ds_addr = R(32);
        dut->a16_pair = pair;
        dut->we = we; dut->w_addr = w_a; dut->w_data = wd;
        dut->we16 = we16; dut->w16_pair = wpair; dut->w16_data = w16;
        dut->eval();

        // Las lecturas son del estado ANTERIOR al flanco.
        uint32_t exp_rd  = model[rd_a];
        uint32_t exp_rr  = model[rr_a];
        uint32_t exp_dbg = model[dbg];
        uint32_t exp_16  = (model[pair * 2 + 1] << 8) | model[pair * 2];
        checks += 4;
        if (dut->rd_data   != exp_rd)  fail("rd_data",   dut->rd_data,   exp_rd,  cyc);
        if (dut->rr_data   != exp_rr)  fail("rr_data",   dut->rr_data,   exp_rr,  cyc);
        if (dut->dbg_data  != exp_dbg) fail("dbg_data",  dut->dbg_data,  exp_dbg, cyc);
        if (dut->a16_rdata != exp_16)  fail("a16_rdata", dut->a16_rdata, exp_16,  cyc);

        // Flanco.
        dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval();

        // Mismo orden de prioridad que el RTL.
        if (we16) {
            model[wpair * 2]     = w16 & 0xFF;
            model[wpair * 2 + 1] = (w16 >> 8) & 0xFF;
        }
        if (we && !(we16 && ((w_a >> 1) == wpair)))
            model[w_a] = wd;
    }

    // ---- barrido final de los 32 ----
    dut->we = 0; dut->we16 = 0;
    for (int i = 0; i < 32; i++) {
        dut->dbg_addr = i; dut->eval();
        checks++;
        if (dut->dbg_data != model[i]) fail("barrido final", dut->dbg_data, model[i], N);
    }

    delete dut;
    printf("  Banco de registros contra modelo de referencia\n");
    printf("  %ld comprobaciones en %ld ciclos aleatorios, %d fallos\n", checks, N, fails);
    if (fails) return 1;
    printf("  0 fallos\n");
    return 0;
}
