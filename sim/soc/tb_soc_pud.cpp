// AxiomaCore-328 - PUD: que el apagado global llegue a LOS TRES puertos
// SPDX-License-Identifier: Apache-2.0
//
// `PUD` vive en `MCUCR`, que es un registro del control de reloj, y lo que
// apaga son los pull-up de los tres puertos de E/S. O sea que es **un cable
// entre periféricos**, y ésos no los verifica ningún banco de módulo: en
// `axioma_gpio` el `pud` es un puerto de entrada y da igual quién lo mueva.
//
// Es exactamente la misma clase de agujero que el disparo automático del ADC, y
// se cierra igual: un programa de verdad escribe `MCUCR` y desde fuera se mira
// si los pull-up se caen. **En los tres puertos**, porque tres cables son tres
// oportunidades de olvidarse de uno — y el banco del módulo pasaría igual.
//
// La prueba negativa importa tanto como la positiva: con `PUD` a cero los
// pull-up tienen que estar PUESTOS. Un SoC que atara `pud` a uno por
// equivocación apagaría los tres, y sin comprobar el caso contrario eso parece
// «apaga bien».

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

static void chk(const char *que, uint32_t got, uint32_t exp) {
    comprobaciones++;
    if (got != exp) {
        printf("    FALLA %-44s obtenido=0x%02X esperado=0x%02X\n", que, got, exp);
        fallos++;
    }
}

static uint16_t LDI(int d, int k) {
    return 0xE000 | ((k & 0xF0) << 4) | (((d - 16) & 0xF) << 4) | (k & 0xF);
}
static void STS(std::vector<uint16_t> &p, int dir, int reg) {
    p.push_back(0x9200 | (reg << 4));
    p.push_back((uint16_t)dir);
}

enum { D_DDRB = 0x24, D_PORTB = 0x25, D_DDRC = 0x27, D_PORTC = 0x28,
       D_DDRD = 0x2A, D_PORTD = 0x2B, D_MCUCR = 0x55 };

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

// Deja los tres puertos como ENTRADA con el pull-up pedido, escribe `mcucr` y
// se para. Lo unico que cambia entre las dos pasadas es ese byte.
static std::vector<uint16_t> programa(uint8_t mcucr) {
    std::vector<uint16_t> p;
    p.push_back(LDI(16, 0x00));
    STS(p, D_DDRB, 16);  STS(p, D_DDRC, 16);  STS(p, D_DDRD, 16);
    p.push_back(LDI(16, 0xFF));
    STS(p, D_PORTB, 16); STS(p, D_PORTC, 16); STS(p, D_PORTD, 16);
    p.push_back(LDI(16, mcucr));
    STS(p, D_MCUCR, 16);
    p.push_back(0xCFFF);
    return p;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_clk_top;

    // ---- PUD a cero: los pull-up puestos ----
    // El puerto C solo tiene SIETE pines: PC7 no existe en el encapsulado y el
    // SoC lo enmascara. Que aqui salga 0x7F y no 0xFF es parte de lo que se
    // comprueba.
    cargar(programa(0x00));
    for (int i = 0; i < 200; i++) tick();
    chk("sin PUD, el puerto B lleva pull-up", dut->pb_pu_v, 0xFF);
    chk("sin PUD, el puerto C lleva pull-up", dut->pc_pu_v, 0x7F);
    chk("sin PUD, el puerto D lleva pull-up", dut->pd_pu_v, 0xFF);

    // ---- PUD a uno: los tres se caen ----
    cargar(programa(0x10));
    for (int i = 0; i < 200; i++) tick();
    chk("PUD apaga los del puerto B", dut->pb_pu_v, 0x00);
    chk("PUD apaga los del puerto C", dut->pc_pu_v, 0x00);
    chk("PUD apaga los del puerto D", dut->pd_pu_v, 0x00);

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
    printf("  MCUCR.PUD llega a los tres puertos\n");
    return 0;
}
