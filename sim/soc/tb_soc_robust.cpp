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
static uint16_t RJMP(int d)        { return 0xC000 | (d & 0x0FFF); }
static uint16_t SBRC(int r, int b) { return 0xFC00 | ((r & 0x1F) << 4) | (b & 7); }
// `STS` y `LDS` ocupan DOS palabras. Dentro de una lista de inicializacion eso
// se resuelve con una macro que se expande a las dos entradas, que es mas
// legible que repartir la direccion suelta por el programa.
#define STS_(dir, r) (uint16_t)(0x9200 | ((r) << 4)), (uint16_t)(dir)
#define LDS_(r, dir) (uint16_t)(0x9000 | ((r) << 4)), (uint16_t)(dir)
static const uint16_t SPMCSR = 0x0057;
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

    // ============================== 1. SPM: la secuencia de un gestor
    // Esto YA NO es «escribir una palabra». Desde la fase 4, `SPM` es una
    // PETICION y lo que hace depende de lo que haya en `SPMCSR`, asi que el
    // programa de aqui es literalmente lo que hace un gestor de arranque:
    //
    //   llenar el bufer temporal palabra a palabra, con `SPM Z+`;
    //   borrar la pagina y ESPERAR a que `SPMEN` se caiga;
    //   volcar el bufer y esperar otra vez;
    //   y releer con `LPM` para ver si quedo lo que se pedia.
    //
    // La espera es `boot_spm_busy_wait()` escrito a mano: `LDS` de `SPMCSR`,
    // `SBRC` del bit 0 y volver. Si `SPMEN` se cayera antes de tiempo, el
    // programa seguiria con la pagina a medio escribir, y la relectura lo diria.
    //
    // La pagina es la de Z = 0x0200 —la numero 4, palabras 0x100 a 0x13F—, bien
    // lejos del propio programa: un gestor que se borre la pagina que esta
    // ejecutando se lleva lo que se merece, aqui y en el chip.
    printf("  SPM: llenar el bufer, borrar la pagina, volcarla y releer\n");
    {
        std::vector<uint16_t> p = {
            LDI(16, 0xEF), MOV(0, 16),
            LDI(16, 0xBE), MOV(1, 16),
            LDI(30, 0x00), LDI(31, 0x02),       // Z = 0x0200
            LDI(16, 0x01), STS_(SPMCSR, 16),    // SPMEN
            SPM_ZP,                              // bufer[0] = 0xBEEF, Z += 2
            LDI(16, 0x0D), MOV(0, 16),
            LDI(16, 0xF0), MOV(1, 16),
            LDI(16, 0x01), STS_(SPMCSR, 16),
            SPM,                                 // bufer[1] = 0xF00D
            LDI(30, 0x00), LDI(31, 0x02),
            LDI(16, 0x03), STS_(SPMCSR, 16),    // PGERS | SPMEN
            SPM,
            LDS_(17, SPMCSR), SBRC(17, 0), RJMP(-4),
            LDI(16, 0x05), STS_(SPMCSR, 16),    // PGWRT | SPMEN
            SPM,
            LDS_(17, SPMCSR), SBRC(17, 0), RJMP(-4),
            LDI(30, 0x00), LDI(31, 0x02),
            LPM(20), ADIWZ(1), LPM(21), ADIWZ(1),
            LPM(22), ADIWZ(1), LPM(23), ADIWZ(1),
            LPM(24),
            RJMP_AQUI
        };
        cargar(p);
        // Dos operaciones de pagina a 576 tics de oscilador, y un tic cada 98
        // ciclos: ~113 000. Se deja margen.
        for (int i = 0; i < 200000; i++) tick();

        chk("palabra 0, byte bajo", reg(20), 0xEF);
        chk("palabra 0, byte alto", reg(21), 0xBE);
        chk("palabra 1, byte bajo", reg(22), 0x0D);
        chk("palabra 1, byte alto", reg(23), 0xF0);
        // Y LA TERCERA TIENE QUE ESTAR BORRADA: es lo que comprueba que el
        // bufer se limpia tras volcarlo, y de paso que el borrado llego a las
        // 64 palabras y no solo a las dos que se escribieron.
        chk("palabra 2, borrada", reg(24), 0xFF);
    }

    // ------------------------- el post-incremento de SPM Z+, por separado
    printf("  SPM Z+: el puntero tiene que avanzar una palabra\n");
    {
        std::vector<uint16_t> p = {
            LDI(30, 0x40), LDI(31, 0x01),       // Z = 0x0140
            LDI(16, 0x01), STS_(SPMCSR, 16),    // sin SPMCSR, SPM no hace nada
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
