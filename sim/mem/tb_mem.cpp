// AxiomaCore-328 - memorias contra un modelo de referencia
// SPDX-License-Identifier: Apache-2.0
//
// Hasta ahora solo se sabía que lintaban y que la síntesis las mapeaba a BRAM.
// Esto comprueba lo que de verdad importa:
//
//   - que las escrituras persistan y las lecturas devuelvan lo escrito
//   - que la búsqueda de instrucción tenga la latencia declarada
//   - que los dos puertos de la memoria de programa no se estorben
//   - que la memoria de datos, en FLANCO DE BAJADA, entregue el dato dentro
//     del mismo ciclo del núcleo, que es de lo que depende que LD y LDS
//     conserven sus cuentas de ciclos

#include "Vtb_mem_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstring>
#include <random>

static int  fails  = 0;
static long checks = 0;

static void chk(const char *what, uint32_t got, uint32_t exp, long i) {
    checks++;
    if (got != exp && ++fails <= 8)
        printf("    FALLA %-28s i=%ld obtenido=%04X esperado=%04X\n",
               what, i, got, exp);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    std::mt19937 rng(20260908);
    auto R = [&](int n) { return (uint32_t)(rng() % n); };

    Vtb_mem_top *m = new Vtb_mem_top;
    static uint16_t pmodel[16384];
    static uint8_t  dmodel[2048];
    memset(pmodel, 0, sizeof(pmodel));
    memset(dmodel, 0, sizeof(dmodel));

    m->clk = 0;
    m->pm_if_en = 0; m->pm_d_en = 0; m->pm_d_we = 0;
    m->dm_en = 0;    m->dm_we = 0;
    m->eval();

    // ---------------- memoria de programa: escrituras por el puerto de datos
    for (int i = 0; i < 4000; i++) {
        uint32_t a = R(16384), v = R(65536);
        m->pm_d_addr = a; m->pm_d_en = 1; m->pm_d_we = 1; m->pm_d_wdata = v;
        m->clk = 1; m->eval(); m->clk = 0; m->eval();
        pmodel[a] = v;
    }
    // ---------------- memoria de programa: PUERTO DE DATOS (lo que usa LPM)
    // Se comprueba aparte del de búsqueda: son puertos distintos y romper uno
    // no rompe el otro. Sin esto, LPM quedaba sin verificar.
    for (int i = 0; i < 4000; i++) {
        uint32_t a = R(16384);
        m->pm_d_addr = a; m->pm_d_en = 1; m->pm_d_we = 0;
        m->clk = 1; m->eval(); m->clk = 0; m->eval();
        chk("progmem d_rdata (LPM)", m->pm_d_rdata, pmodel[a], i);
    }

    // ---------------- puerto de datos: lectura coherente tras escritura
    for (int i = 0; i < 2000; i++) {
        uint32_t a = R(16384), v = R(65536);
        m->pm_d_addr = a; m->pm_d_en = 1; m->pm_d_we = 1; m->pm_d_wdata = v;
        m->clk = 1; m->eval(); m->clk = 0; m->eval();
        pmodel[a] = v;
        chk("progmem d_rdata tras escritura", m->pm_d_rdata, v, i);
    }

    m->pm_d_we = 0; m->pm_d_en = 0;

    // ---------------- memoria de programa: búsqueda, latencia de un ciclo
    for (int i = 0; i < 4000; i++) {
        uint32_t a = R(16384);
        m->pm_if_addr = a; m->pm_if_en = 1;
        m->clk = 1; m->eval(); m->clk = 0; m->eval();
        chk("progmem if_data", m->pm_if_data, pmodel[a], i);
    }

    // ---------------- memoria de programa: los dos puertos a la vez
    for (int i = 0; i < 2000; i++) {
        uint32_t a = R(8192), b = 8192 + R(8192), v = R(65536);
        m->pm_if_addr = a; m->pm_if_en = 1;
        m->pm_d_addr = b;  m->pm_d_en = 1; m->pm_d_we = 1; m->pm_d_wdata = v;
        m->clk = 1; m->eval(); m->clk = 0; m->eval();
        pmodel[b] = v;
        chk("progmem dos puertos", m->pm_if_data, pmodel[a], i);
    }
    m->pm_d_we = 0; m->pm_d_en = 0; m->pm_if_en = 0;

    // ---------------- memoria de datos: el FLANCO importa
    //
    // Este bucle modela cómo la maneja el núcleo de verdad, y por eso
    // distingue flanco de bajada de flanco de subida:
    //
    //   posedge T     el núcleo actualiza su estado
    //   ciclo T       el núcleo PRESENTA la dirección (después del flanco)
    //   negedge T     la memoria en bajada captura aquí
    //   antes de T+1  el dato tiene que estar listo
    //
    // Si se presentara la dirección ANTES del flanco de subida, una memoria en
    // subida también pasaría el test y no estaríamos comprobando nada: fue
    // exactamente el fallo de la primera versión de este arnés, que dejó
    // sobrevivir al mutante "vuelve a flanco de subida".
    for (int i = 0; i < 20000; i++) {
        uint32_t a = R(2048), v = R(256), wr = R(2);

        m->clk = 1; m->eval();                    // flanco de subida
        m->dm_addr = a; m->dm_en = 1;             // el núcleo presenta AHORA
        m->dm_we = wr; m->dm_wdata = v;
        m->eval();
        m->clk = 0; m->eval();                    // flanco de bajada: captura

        if (wr) { dmodel[a] = v; chk("dmem lectura-tras-escritura", m->dm_rdata, v, i); }
        else    {                chk("dmem lectura",                m->dm_rdata, dmodel[a], i); }
    }

    // ---------------- con en=0 la salida se mantiene
    {
        m->clk = 1; m->eval();
        m->dm_addr = 7; m->dm_en = 1; m->dm_we = 1; m->dm_wdata = 0xA5; m->eval();
        m->clk = 0; m->eval();
        dmodel[7] = 0xA5;
        uint32_t held = m->dm_rdata;
        m->clk = 1; m->eval();
        m->dm_addr = 999; m->dm_en = 0; m->dm_we = 0; m->eval();
        m->clk = 0; m->eval();
        chk("dmem en=0 mantiene la salida", m->dm_rdata, held, 0);
    }

    // ---------------- barrido completo del rango de direcciones
    for (uint32_t a = 0; a < 2048; a++) {
        m->clk = 1; m->eval();
        m->dm_addr = a; m->dm_en = 1; m->dm_we = 1; m->dm_wdata = (a * 7 + 13) & 0xFF; m->eval();
        m->clk = 0; m->eval();
        dmodel[a] = (a * 7 + 13) & 0xFF;
    }
    for (uint32_t a = 0; a < 2048; a++) {
        m->clk = 1; m->eval();
        m->dm_addr = a; m->dm_en = 1; m->dm_we = 0; m->eval();
        m->clk = 0; m->eval();
        chk("dmem barrido completo", m->dm_rdata, dmodel[a], a);
    }

    delete m;
    printf("  Memorias contra modelo de referencia\n");
    printf("  %ld comprobaciones, %d fallos\n", checks, fails);
    if (fails) return 1;
    printf("  0 fallos\n");
    return 0;
}
