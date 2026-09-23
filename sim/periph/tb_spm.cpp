// AxiomaCore-328 - SPM contra el capítulo 26 de la hoja de datos
// SPDX-License-Identifier: Apache-2.0
//
// simavr NO SIRVE DE ORÁCULO AQUÍ, y esta vez de una forma interesante: su
// `avr_flash.c` sí implementa `SPMCSR` y las páginas, pero el arnés diferencial
// de este proyecto **no puede usarlo**, porque un programa que se reescriba la
// Flash cambia el código que los dos están ejecutando y el contraste deja de
// significar nada. El oráculo es el capítulo 26.
//
// Lo que se comprueba, y el orden importa porque cada bloque usa el anterior:
//
//   1. el registro: valores de reinicio, lectura de vuelta, y que `RWWSB` se
//      lea SIEMPRE a cero —no hay secciones que puedan estar ocupadas—;
//   2. LA QUINTA SECUENCIA TEMPORIZADA DEL CHIP, y la única cuyo segundo paso
//      no es una escritura sino una INSTRUCCIÓN. Un `SPM` suelto no hace nada,
//      y uno que llegue tarde tampoco: es lo que impide que un programa
//      desbocado se borre la Flash;
//   3. el búfer temporal, que NO toca la Flash;
//   4. el borrado de página: 64 palabras a 0xFFFF, y LAS DE ESA PÁGINA;
//   5. la escritura de página, y que el búfer quede limpio detrás;
//   6. `SPMEN` bajándolo el hardware al terminar, que es lo que espera
//      `boot_spm_busy_wait()`, y `SPM_READY` como NIVEL.

#include "Vaxioma_spm.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>

static Vaxioma_spm *dut;
static int  fallos = 0;
static long comprobaciones = 0;
static const char *fase = "";

static void chk(const char *que, uint32_t got, uint32_t exp) {
    comprobaciones++;
    if (got != exp) {
        if (++fallos <= 20)
            printf("    FALLA [%s] %-44s obtenido=0x%04X esperado=0x%04X\n",
                   fase, que, got, exp);
    }
}

// La Flash, modelada aquí: 16 K palabras que arrancan borradas.
static uint16_t flash[16384];
static long     escrituras = 0;

// El oscilador, como en el arnés de verdad: un pulso cada 98 ciclos.
static int osc_div = 0;

static void tick() {
    dut->osc_tick = (osc_div == 0);
    osc_div = (osc_div == 0) ? 97 : osc_div - 1;
    dut->clk = 1; dut->eval();
    if (dut->pm_we) { flash[dut->pm_addr] = dut->pm_wdata; escrituras++; }
    dut->clk = 0; dut->eval();
}
static void run(int n) { for (int i = 0; i < n; i++) tick(); }

enum { SPMCSR = 0x37 };
enum { SPMEN = 0x01, PGERS = 0x02, PGWRT = 0x04, BLBSET = 0x08,
       RWWSRE = 0x10, SIGRD = 0x20, RWWSB = 0x40, SPMIE = 0x80 };

static void wr(uint8_t d) {
    dut->io_addr = SPMCSR; dut->io_wdata = d; dut->io_we = 1;
    tick();
    dut->io_we = 0; dut->io_addr = 0; dut->eval();
}

static uint8_t peek() {
    dut->io_addr = SPMCSR; dut->eval();
    uint8_t v = dut->io_rdata;
    dut->io_addr = 0; dut->eval();
    return v;
}

// Ejecutar un `SPM`: es un pulso de un ciclo, como lo emite el secuenciador al
// retirarse la instruccion.
static void spm(uint16_t z, uint16_t dato) {
    dut->spm_z = z; dut->spm_dato = dato; dut->spm_pulso = 1;
    tick();
    dut->spm_pulso = 0; dut->eval();
}

// Esperar a que `SPMEN` se caiga, que es lo que hace `boot_spm_busy_wait()`.
static long espera_fin(long tope = 400000) {
    long n = 0;
    while ((peek() & SPMEN) && n < tope) { tick(); n++; }
    return n;
}

static void reset() {
    dut->rst_n = 0; dut->clk = 0; dut->ce = 1;
    dut->io_addr = 0; dut->io_we = 0; dut->io_re = 0; dut->io_wdata = 0;
    dut->spm_pulso = 0; dut->spm_z = 0; dut->spm_dato = 0; dut->osc_tick = 0;
    dut->eval();
    run(4);
    dut->rst_n = 1; dut->eval();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_spm;
    for (int i = 0; i < 16384; i++) flash[i] = 0xFFFF;
    reset();

    // ----------------------------------------------------- 1. el registro
    fase = "registro";
    chk("arranca a cero", peek(), 0x00);
    wr(SPMIE | SIGRD | RWWSRE | BLBSET);
    chk("guarda los bits que son suyos", peek(), SPMIE | SIGRD | RWWSRE | BLBSET);
    // RWWSB es de SOLO LECTURA y aqui vale siempre cero: la Flash es una BRAM
    // de doble puerto y nunca hay una mitad inaccesible.
    wr(RWWSB);
    chk("RWWSB no se deja escribir", peek() & RWWSB, 0x00);
    // Y NO SE LEE A CERO POR CASUALIDAD: con los demas bits puestos tiene que
    // seguir a cero. Un `RWWSB` que devolviera el estado de otro bit pasaria la
    // comprobacion de arriba, donde todo lo demas vale cero. Lo dijo un mutante.
    wr(SPMIE | SIGRD | RWWSRE | BLBSET | PGWRT | PGERS);
    chk("ni con los demas bits puestos", peek() & RWWSB, 0x00);
    wr(0x00);

    // --------------------------------------- 2. la secuencia temporizada
    fase = "secuencia";
    {
        // Un `SPM` SUELTO no hace nada. Es lo que impide que un programa
        // desbocado se lleve por delante la Flash.
        escrituras = 0;
        spm(0x0200, 0x1234);
        run(4);
        chk("un SPM sin SPMCSR no escribe nada", escrituras, 0);

        // `SPMEN` SE CAE SOLO SI NO LLEGA NINGUN `SPM`, a los cuatro ciclos.
        // Es lo que dice la hoja de datos, y hasta que un mutante lo pidio no
        // habia ni un caso: todos escribian `SPMCSR` y ejecutaban `SPM` detras,
        // asi que `SPMEN` se caia siempre por el otro camino.
        wr(SPMEN);
        chk("recien escrito, SPMEN esta puesto", peek() & SPMEN, SPMEN);
        run(5);
        chk("y a los cuatro ciclos se cae solo", peek() & SPMEN, 0x00);

        // Y uno que llega TARDE, tampoco: la ventana son cuatro ciclos.
        wr(PGERS | SPMEN);
        run(5);
        escrituras = 0;
        spm(0x0200, 0x0000);
        run(200);
        chk("un SPM fuera de la ventana no borra", escrituras, 0);
    }

    // ----------------------------------------------- 3. el bufer temporal
    fase = "bufer temporal";
    {
        // El `SPM` no tiene por que llegar EN EL CICLO SIGUIENTE a la
        // escritura: la ventana son cuatro, y en un programa de verdad entre
        // las dos cosas hay lo que el compilador decida poner. Se comprueba
        // con hueco, que es como llega en el SoC.
        wr(SPMEN); run(1); spm(0x1000, 0x1234);
        chk("con un ciclo de hueco, el SPM sigue valiendo", peek() & SPMEN, 0x00);
        wr(SPMEN); run(2); spm(0x1000, 0x1234);
        chk("y con dos, tambien", peek() & SPMEN, 0x00);
        escrituras = 0;
        for (int w = 0; w < 64; w++) {
            wr(SPMEN);
            spm((uint16_t)(0x1000 + w * 2), (uint16_t)(0xA000 + w));
        }
        chk("llenar el bufer NO toca la Flash", escrituras, 0);
        chk("y SPMEN se cae solo, sin esperar", peek() & SPMEN, 0x00);
    }

    // ------------------------------------------------ 4. borrado de pagina
    fase = "borrado de pagina";
    {
        // Ensuciar dos paginas para poder distinguir cual se borra.
        for (int i = 0; i < 16384; i++) flash[i] = 0x5A5A;

        escrituras = 0;
        wr(PGERS | SPMEN);
        spm(0x1000, 0x0000);            // pagina Z[14:7] = 0x20
        chk("SPMEN sigue puesto mientras borra", peek() & SPMEN, SPMEN);

        long t = espera_fin();
        chk("el hardware baja SPMEN al terminar", peek() & SPMEN, 0x00);
        chk("escribe 64 palabras, ni una mas", escrituras, 64);

        // La pagina de 0x1000: palabra 0x1000/2 = 0x800, o sea 0x800..0x83F.
        int mal = 0;
        for (int w = 0x800; w < 0x840; w++) if (flash[w] != 0xFFFF) mal++;
        chk("las 64 palabras de LA pagina quedan borradas", mal, 0);
        chk("la palabra de antes no se toca", flash[0x7FF], 0x5A5A);
        chk("ni la de despues",              flash[0x840], 0x5A5A);

        // Y tarda lo que tiene que tardar: 576 tics de oscilador a 98 ciclos
        // cada uno. Se admite el margen de las 64 escrituras del principio.
        chk("tarda del orden de 4,5 ms", (t > 56000 && t < 57500), 1);
    }

    // ---------------------------------------------- 5. escritura de pagina
    fase = "escritura de pagina";
    {
        escrituras = 0;
        wr(PGWRT | SPMEN);
        spm(0x1000, 0x0000);
        espera_fin();
        chk("escribe 64 palabras", escrituras, 64);

        int mal = 0;
        for (int w = 0; w < 64; w++)
            if (flash[0x800 + w] != (uint16_t)(0xA000 + w)) mal++;
        chk("la pagina queda con lo que habia en el bufer", mal, 0);

        // EL BUFER SE LIMPIA DETRAS, que lo dice la hoja de datos. Se comprueba
        // volviendo a escribir la MISMA pagina sin llenar nada: tiene que salir
        // borrada entera, no con los restos de la vez anterior.
        wr(PGWRT | SPMEN);
        spm(0x1000, 0x0000);
        espera_fin();
        mal = 0;
        for (int w = 0; w < 64; w++) if (flash[0x800 + w] != 0xFFFF) mal++;
        chk("y el bufer queda limpio detras", mal, 0);
    }

    // ------------------------------------- 6. la pagina sale de Z, no de otro
    fase = "la pagina sale de Z";
    {
        for (int i = 0; i < 16384; i++) flash[i] = 0x1111;
        wr(SPMEN);  spm(0x0000, 0xBEEF);        // bufer palabra 0
        wr(PGWRT | SPMEN);
        spm(0x3F80, 0x0000);                    // pagina 0x7F -> palabra 0x1FC0
        espera_fin();
        chk("la primera palabra cae en la pagina de Z", flash[0x1FC0], 0xBEEF);
        chk("y no en la pagina cero",                    flash[0x0000], 0x1111);
    }

    // --------------------------------------------------- 7. SPM_READY
    fase = "SPM_READY";
    {
        reset();
        chk("sin SPMIE no hay peticion", dut->irq_spm, 0);
        wr(SPMIE);
        run(2);
        // ES DE NIVEL: vale mientras SPMEN este a cero. No hay bandera.
        chk("con SPMIE y SPMEN a cero, pide", dut->irq_spm, 1);

        wr(SPMIE | PGERS | SPMEN);
        spm(0x0000, 0x0000);
        run(2);
        chk("mientras programa, NO pide", dut->irq_spm, 0);
        espera_fin();
        chk("y al terminar vuelve a pedir", dut->irq_spm, 1);
    }

    dut->final();
#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;
    printf("  %ld comprobaciones, %d fallos\n", comprobaciones, fallos);
    if (fallos) {
        printf("  El oraculo es el capitulo 26 de la hoja de datos: el arnes\n"
               "  diferencial no sirve aqui, porque un programa que se reescribe\n"
               "  la Flash cambia el codigo que los dos estan ejecutando.\n");
        return 1;
    }
    printf("  secuencia, bufer, borrado, escritura por paginas y SPM_READY correctos\n");
    return 0;
}
