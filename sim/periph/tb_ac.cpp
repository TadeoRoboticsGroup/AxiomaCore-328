// AxiomaCore-328 - banco del comparador analogico
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El comparador es analogico y se queda fuera del RTL (ADR 0002), asi que aqui
// se le mueve la salida a mano y se comprueba lo que el RTL SI hace: elegir las
// entradas, sincronizar la salida, decidir que flanco interrumpe, y llevarla a
// la captura del Timer1.
//
// simavr NO MODELA ESTE PERIFERICO EN ABSOLUTO: no tiene ACSR ni comparador. Lo
// que hay en el diferencial es el registro como almacenamiento, y nada mas.

#include "Vaxioma_ac.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>

static Vaxioma_ac *dut;
static int  fails = 0;
static long checks = 0;
static const char *fase = "";

static void chk(const char *que, uint32_t got, uint32_t exp) {
    checks++;
    if (got != exp) {
        if (++fails <= 20)
            printf("    FALLA [%s] %-46s obtenido=0x%02X esperado=0x%02X\n",
                   fase, que, got, exp);
    }
}

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }
static void run(int n) { for (int i = 0; i < n; i++) tick(); }

enum { ACSR = 0x30, DIDR1 = 0x5F };
enum { ACD = 0x80, ACBG = 0x40, ACO = 0x20, ACI = 0x10, ACIE = 0x08,
       ACIC = 0x04 };

static void wr(uint8_t a, uint8_t d) {
    dut->io_addr = a; dut->io_wdata = d; dut->io_we = 1;
    tick();
    dut->io_we = 0; dut->io_addr = 0; dut->eval();
}

static uint8_t peek(uint8_t a) {
    uint8_t ant = dut->io_addr;
    dut->io_addr = a; dut->eval();
    uint8_t v = dut->io_rdata;
    dut->io_addr = ant; dut->eval();
    return v;
}

// Mover la salida del comparador y dejar que los dos biestables de
// sincronizacion la vean. La hoja de datos promete «1 - 2 clock cycles»: se
// espera ese margen y despues se mira.
static void salida(int v) { dut->ac_salida = v; dut->eval(); run(3); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_ac;

    dut->rst_n = 0; dut->clk = 0;
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->ac_salida = 0; dut->adc_acme = 0; dut->adc_encendido = 0;
    dut->ack_ac = 0;
    dut->eval();
    tick();
    dut->rst_n = 1; dut->eval();

    // ------------------------------------------------ 1. valores de reset
    fase = "reset";
    chk("ACSR", peek(ACSR), 0x00);
    chk("DIDR1", peek(DIDR1), 0x00);
    chk("no se apaga solo", dut->ac_apagado, 0);
    chk("ni pide la referencia interna", dut->ac_bandgap, 0);
    chk("ni el bufer digital", dut->didr_dis, 0x00);
    chk("ni la captura", dut->ac_a_captura, 0);

    // ------------------------------- 2. los registros se leen de vuelta
    fase = "lectura de vuelta";
    wr(ACSR, ACD | ACBG | ACIE | ACIC | 0x03);
    chk("ACSR devuelve lo que se le escribio", peek(ACSR) & 0xCF,
        (uint8_t)(ACD | ACBG | ACIE | ACIC | 0x03));
    chk("ACD sale al frente analogico", dut->ac_apagado, 1);
    chk("ACBG tambien", dut->ac_bandgap, 1);
    chk("y ACIC va a la captura", dut->ac_a_captura, 1);
    wr(DIDR1, 0xFF);
    chk("DIDR1 tiene dos bits", peek(DIDR1), 0x03);
    chk("y apaga PD6 y PD7", dut->didr_dis, 0xC0);
    wr(DIDR1, 0x00);
    wr(ACSR, 0x00);

    // --------------------------------------------- 3. ACO, sincronizada
    // «1 - 2 clock cycles», dice la hoja de datos. Lo importante aqui no es el
    // numero exacto sino que NO sea combinacional: un comparador sin histeresis
    // oscila cerca del umbral, y sin sincronizar eso entra en el registro que
    // lee el programa.
    fase = "ACO llega sincronizada";
    {
        dut->ac_salida = 1; dut->eval();
        chk("no aparece en el mismo ciclo", (peek(ACSR) & ACO) != 0, 0);
        tick();
        chk("ni en el siguiente", (peek(ACSR) & ACO) != 0, 0);
        tick();
        chk("si dos ciclos despues", (peek(ACSR) & ACO) != 0, 1);
        salida(0);
        chk("y vuelve a bajar", (peek(ACSR) & ACO) != 0, 0);
    }

    // ------------------------------------- 4. los tres modos de ACIS
    // 00 los dos flancos, 10 el de bajada, 11 el de subida. El 01 esta
    // RESERVADO y el chip no lo decodifica aparte: se comporta como el 00.
    fase = "ACIS elige el flanco";
    for (int acis = 0; acis < 4; acis++) {
        bool con_subida = (acis != 2);
        bool con_bajada = (acis != 3);

        salida(0);
        wr(ACSR, (uint8_t)(ACI | acis));            // limpiar la bandera
        chk("la bandera arranca limpia", (peek(ACSR) & ACI) != 0, 0);

        salida(1);                                   // flanco de subida
        chk("subida", (peek(ACSR) & ACI) != 0, con_subida ? 1 : 0);

        wr(ACSR, (uint8_t)(ACI | acis));
        salida(0);                                   // flanco de bajada
        chk("bajada", (peek(ACSR) & ACI) != 0, con_bajada ? 1 : 0);
        wr(ACSR, (uint8_t)(ACI | acis));
    }

    // --------------------------------------- 5. la bandera y el vector
    fase = "la bandera y el vector";
    {
        salida(0);
        wr(ACSR, ACI);                               // ACIS=00, sin ACIE
        salida(1);
        chk("ACI se levanta", (peek(ACSR) & ACI) != 0, 1);
        chk("pero sin ACIE no hay peticion", dut->irq_ac, 0);
        wr(ACSR, ACIE);                              // habilitar sin limpiar
        chk("con ACIE la peticion sale", dut->irq_ac, 1);

        // Atender el vector limpia la bandera en su origen.
        dut->ack_ac = 1; tick(); dut->ack_ac = 0; tick();
        chk("el reconocimiento la limpia", (peek(ACSR) & ACI) != 0, 0);
        chk("y con ella la peticion", dut->irq_ac, 0);

        // Y se limpia escribiendo un UNO, no un cero.
        salida(0);
        chk("otro flanco la vuelve a levantar", (peek(ACSR) & ACI) != 0, 1);
        wr(ACSR, ACIE);                              // escribir CERO en ACI
        chk("escribir un cero no la limpia", (peek(ACSR) & ACI) != 0, 1);
        wr(ACSR, (uint8_t)(ACIE | ACI));
        chk("escribir un uno si", (peek(ACSR) & ACI) != 0, 0);
    }

    // ------------------------------------- 6. ACD apaga de verdad
    // Con el comparador apagado, ACO se lee como cero y no hay flancos que
    // interrumpan: es lo que hace util apagarlo para ahorrar corriente.
    fase = "ACD apaga el comparador";
    {
        salida(0);
        wr(ACSR, (uint8_t)(ACD | ACI));
        salida(1);
        chk("ACO se lee cero con ACD puesto", (peek(ACSR) & ACO) != 0, 0);
        chk("y no interrumpe", (peek(ACSR) & ACI) != 0, 0);
        wr(ACSR, ACI);                               // encender otra vez
        run(3);
        chk("al encenderlo aparece la salida", (peek(ACSR) & ACO) != 0, 1);

        // PERO APAGARLO CON LA SALIDA ALTA SI DEJA LA BANDERA, y no es un
        // descuido: la hoja de datos avisa de que hay que quitar ACIE antes de
        // tocar ACD «otherwise an interrupt can occur when the bit is changed».
        // Apagar el comparador hace caer ACO, y esa caida es un flanco. El chip
        // se comporta asi, y un programa escrito para el chip lo espera.
        salida(1);
        wr(ACSR, ACI);                               // limpiar, ACIS=00
        chk("la bandera esta limpia y la salida alta",
            (peek(ACSR) & (ACI | ACO)), ACO);
        wr(ACSR, ACD);                               // apagar
        run(2);
        chk("apagarlo deja la bandera puesta", (peek(ACSR) & ACI) != 0, 1);
        wr(ACSR, ACI);                               // encender y limpiar
        run(3);
    }

    // ------------------- 7. la entrada negativa, que es la tabla 22-1
    // El multiplexor del ADC alimenta la entrada negativa SOLO si ACME esta
    // puesto Y el ADC esta apagado. Con el ADC en marcha manda el ADC.
    fase = "la tabla 22-1 de la entrada negativa";
    for (int acme = 0; acme < 2; acme++)
        for (int aden = 0; aden < 2; aden++) {
            dut->adc_acme = acme; dut->adc_encendido = aden; dut->eval();
            chk("de donde sale la entrada negativa", dut->ac_neg_mux,
                (acme && !aden) ? 1 : 0);
        }
    dut->adc_acme = 0; dut->adc_encendido = 0; dut->eval();

    // --------------------------------------- 8. barrido aleatorio
    fase = "aleatorio";
    {
        std::mt19937 rng(20260917);
        int esperado_aci = 0, anterior = 0;
        salida(0); anterior = 0;
        wr(ACSR, ACI);
        uint8_t acis = 0;
        for (int i = 0; i < 2000; i++) {
            if ((rng() % 16) == 0) {                 // cambiar de modo
                acis = (uint8_t)(rng() % 4);
                wr(ACSR, (uint8_t)(ACI | acis));
                esperado_aci = 0;
            }
            int v = (int)(rng() % 2);
            salida(v);
            if (v != anterior) {
                bool sube = (v == 1);
                bool cuenta = (acis == 2) ? !sube : (acis == 3) ? sube : true;
                if (cuenta) esperado_aci = 1;
                anterior = v;
            }
            chk("la bandera sigue a los flancos que toca",
                (peek(ACSR) & ACI) != 0, (uint32_t)esperado_aci);
            if ((rng() % 8) == 0) {                  // limpiarla de vez en cuando
                wr(ACSR, (uint8_t)(ACI | acis));
                esperado_aci = 0;
            }
        }
    }

#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;
    printf("  %ld comprobaciones, %d fallos\n", checks, fails);
    if (fails) {
        printf("  simavr no modela este periferico en absoluto: el oraculo es\n"
               "  la hoja de datos, capitulo 22.\n");
        return 1;
    }
    printf("  entradas, sincronizacion, flancos y captura correctos\n");
    return 0;
}
