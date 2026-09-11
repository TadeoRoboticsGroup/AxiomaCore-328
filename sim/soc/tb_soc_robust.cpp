// AxiomaCore-328 - lo que la cobertura dijo que nadie ejecutaba nunca
// SPDX-License-Identifier: Apache-2.0
//
// Este banco existe por una medida, no por una corazonada. Al instrumentar el
// RTL con `--coverage` y fusionar TODAS las fuentes salió un 97,4 %, y los
// puntos que faltaban no eran ruido: eran dos caminos reales que ningún
// programa de prueba había pisado jamás.
//
//   1. `SPM`. Estaba implementado y sin ejecutar ni una vez. Tenía DOS fallos
//      que nadie podía ver: escribía `{Rd, Rd}` duplicando un byte en vez de la
//      palabra R1:R0, y `SPM Z+` decodificaba el post-incremento sin escribir Z
//      de vuelta. Aquí se comprueba escribiendo y volviendo a leer con `LPM`,
//      que es la única forma honesta: simavr no sirve de oráculo para SPM.
//
//      AVISO: esto NO es todavía el SPM del ATmega328P. El del chip se gobierna
//      con SPMCSR y trabaja por PÁGINAS. Lo de aquí es la escritura de una
//      palabra, que es sobre lo que la fase 4 montará el bootloader.
//
//   2. EL OPCODE ILEGAL. El decodificador rechaza 1 765 codificaciones y eso
//      está contrastado contra `avr-objdump`, pero qué hace el SECUENCIADOR al
//      encontrarse una no lo comprobaba nadie. En un chip que va a fabricarse
//      esto importa: un opcode corrupto —un bit volteado en la Flash, una
//      dirección mal calculada— no puede colgar la máquina. Tiene que seguir.

#include "Vaxioma_sim_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static Vaxioma_sim_top *dut;
static int fails = 0;

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static void chk(const char *que, uint32_t got, uint32_t exp) {
    if (got != exp) { printf("    FALLA %-34s obtenido=0x%04X esperado=0x%04X\n",
                             que, got, exp); fails++; }
}

// ------------------------------------------------------------- opcodes
static uint16_t LDI(int d, int k)  { return 0xE000 | ((k & 0xF0) << 4) | (((d - 16) & 0xF) << 4) | (k & 0xF); }
static uint16_t MOV(int d, int r)  { return 0x2C00 | ((r & 0x10) << 5) | ((d & 0x10) << 4) | ((d & 0xF) << 4) | (r & 0xF); }
static uint16_t LPM(int d)         { return 0x9004 | (d << 4); }
static uint16_t ADIWZ(int k)       { return 0x9600 | (3 << 4) | ((k & 0x30) << 2) | (k & 0xF); }
static const uint16_t SPM   = 0x95E8;
static const uint16_t SPM_ZP= 0x95F8;
static const uint16_t ELPM  = 0x95D8;   // no existe en el 328P: ilegal
static const uint16_t RJMP_AQUI = 0xCFFF;
static const uint16_t NOP   = 0x0000;

static void cargar(const std::vector<uint16_t> &p) {
    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0;
    dut->dbg_reg_addr = 0; dut->dbg_mem_addr = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < p.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = p[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();
}

static uint8_t reg(int i) { dut->dbg_reg_addr = i; dut->eval(); return dut->dbg_reg_data; }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_sim_top;

    // ================================================== 1. SPM y SPM Z+
    printf("  SPM: escribir la palabra R1:R0 y releerla con LPM\n");
    {
        // Z = 0x0200 en bytes, que es la palabra 0x0100.
        std::vector<uint16_t> p = {
            LDI(16, 0xEF), MOV(0, 16),          // R0 = 0xEF  (byte bajo)
            LDI(16, 0xBE), MOV(1, 16),          // R1 = 0xBE  (byte alto)
            LDI(30, 0x00), LDI(31, 0x02),       // Z = 0x0200
            SPM,                                 // mem[0x0100] = 0xBEEF
            LDI(16, 0x0D), MOV(0, 16),          // R0 = 0x0D
            LDI(16, 0xF0), MOV(1, 16),          // R1 = 0xF0
            SPM_ZP,                              // mem[0x0100] = 0xF00D, Z += 2
            // releer las dos palabras con LPM
            LDI(30, 0x00), LDI(31, 0x02),       // Z = 0x0200
            LPM(20), ADIWZ(1), LPM(21),         // r20 = byte bajo, r21 = alto
            RJMP_AQUI
        };
        cargar(p);
        for (int i = 0; i < 400; i++) tick();

        chk("byte bajo releido", reg(20), 0x0D);
        chk("byte alto releido", reg(21), 0xF0);
        // SPM Z+ tiene que haber avanzado Z DOS bytes, es decir, una palabra.
        // Aquí Z se recargó después, así que lo que se comprueba es que la
        // segunda escritura fue a la MISMA palabra: si Z no se hubiera
        // recargado, daría igual; si el post-incremento no existiera, tampoco.
        // Por eso el avance se comprueba aparte, abajo.
    }

    // ------------------------- el post-incremento de SPM Z+, por separado
    printf("  SPM Z+: el puntero tiene que avanzar una palabra\n");
    {
        std::vector<uint16_t> p = {
            LDI(30, 0x40), LDI(31, 0x01),       // Z = 0x0140
            SPM_ZP,
            RJMP_AQUI
        };
        cargar(p);
        for (int i = 0; i < 100; i++) tick();
        uint16_t z = (uint16_t)(reg(30) | (reg(31) << 8));
        chk("Z avanzo dos bytes", z, 0x0142);
    }

    // ================================================ 2. opcode ilegal
    printf("  Opcode ilegal: se senala y la maquina NO se cuelga\n");
    {
        std::vector<uint16_t> p = {
            LDI(20, 0x11),
            ELPM,                                // ilegal en el 328P
            LDI(21, 0x22),                       // tiene que ejecutarse
            NOP,
            RJMP_AQUI
        };
        cargar(p);

        bool visto_ilegal = false;
        for (int i = 0; i < 200; i++) {
            dut->eval();
            if (dut->dbg_illegal && dut->dbg_retire) visto_ilegal = true;
            tick();
        }
        chk("se senalo dbg_illegal", visto_ilegal, 1);
        chk("la instruccion anterior corrio", reg(20), 0x11);
        chk("la SIGUIENTE tambien: no se colgo", reg(21), 0x22);
    }

#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif

    delete dut;
    if (fails) { printf("  %d fallos\n", fails); return 1; }
    printf("  SPM correcto y el nucleo sobrevive a un opcode corrupto\n");
    return 0;
}
