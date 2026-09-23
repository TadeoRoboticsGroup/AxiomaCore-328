// AxiomaCore-328 - el control de reloj contra la hoja de datos
// SPDX-License-Identifier: Apache-2.0
//
// simavr NO SIRVE DE ORACULO AQUI, y esta vez ni siquiera a medias: su
// `avr_mcu_t` guarda `CLKPR` como almacenamiento y no divide nada, `PRR` es un
// registro mas, y el sueño lo resuelve adelantando su reloj interno hasta la
// siguiente interrupcion en vez de parar nada. El oraculo es el capitulo 9
// -gestion del reloj- y el 10 -gestion del consumo- de la hoja de datos.
//
// Lo que se comprueba aqui, y el orden importa porque cada bloque se apoya en
// el anterior:
//
//   1. los cinco registros: valores de reinicio y lectura de vuelta;
//   2. LA SECUENCIA DE `CLKPCE`, que NO es la del perro guardian: aqui la
//      escritura que abre la ventana lleva `CLKPCE` a uno Y TODO LO DEMAS A
//      CERO, asi que una escritura de 0x83 -que en el perro guardian seria
//      valida- no abre nada;
//   3. LA DIVISION MEDIDA, no leida: se cuentan los ciclos del reloj de
//      entrada entre dos habilitaciones, para los nueve valores de `CLKPS` y
//      para los siete reservados;
//   4. EL SUEÑO, que es donde se ve que los dos relojes son dos: en `Idle` el
//      nucleo se para y los perifericos siguen; en los demas modos se paran los
//      dos. Y que despierta una interrupcion habilitada en su mascara.
//   5. `MCUSR`, que se limpia escribiendo CERO -al reves que el resto del chip-;
//   6. `MCUCR` con la CUARTA secuencia temporizada, la de `IVCE`.

#include "Vaxioma_clkctrl.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>

static Vaxioma_clkctrl *dut;
static int  fails = 0;
static long checks = 0;
static const char *fase = "";

static void chk(const char *que, uint32_t got, uint32_t exp) {
    checks++;
    if (got != exp) {
        if (++fails <= 20)
            printf("    FALLA [%s] %-44s obtenido=0x%02X esperado=0x%02X\n",
                   fase, que, got, exp);
    }
}

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }
static void run(int n) { for (int i = 0; i < n; i++) tick(); }

enum { SMCR = 0x33, MCUSR = 0x34, MCUCR = 0x35, CLKPR = 0x41, PRR = 0x44 };

// El periodo del reloj de sistema en ciclos del reloj de entrada. El banco lo
// lleva a mano porque una escritura tiene que durar lo que dura un ciclo de
// sistema: es lo que hace el nucleo, cuyas salidas se quedan quietas mientras
// no le toca su habilitacion.
static int periodo = 1;

static void wr(uint8_t a, uint8_t d) {
    dut->io_addr = a; dut->io_wdata = d; dut->io_we = 1;
    run(periodo);
    dut->io_we = 0; dut->io_addr = 0; dut->eval();
}

static uint8_t peek(uint8_t a) {
    uint8_t ant = dut->io_addr;
    dut->io_addr = a; dut->eval();
    uint8_t v = dut->io_rdata;
    dut->io_addr = ant; dut->eval();
    return v;
}

static void reset() {
    dut->rst_n = 0; dut->clk = 0;
    dut->io_addr = 0; dut->io_we = 0; dut->io_re = 0; dut->io_wdata = 0;
    dut->sleep_pulso = 0; dut->irq_pendiente = 0; dut->wdt_reset = 0;
    dut->eval();
    run(4);
    dut->rst_n = 1; dut->eval();
    periodo = 1;
}

// Poner el prescaler POR LA SECUENCIA, que es la unica forma que tiene un
// programa. Devuelve si el cambio se llego a aplicar.
static void pon_clkps(int v) {
    wr(CLKPR, 0x80);            // abre: CLKPCE solo
    wr(CLKPR, v & 0x0F);        // dentro de la ventana
    periodo = 1 << ((v > 8) ? 8 : v);
}

// MEDIR la division, no leerla: se cuentan los ciclos del reloj de ENTRADA
// entre dos habilitaciones consecutivas. Es la unica comprobacion que dice algo
// sobre el divisor; leer CLKPS solo dice que el registro guarda bien.
static int mide_periodo() {
    // colocarse justo despues de una habilitacion
    while (!dut->ce_io) tick();
    tick();
    int n = 1;
    while (!dut->ce_io) { tick(); n++; }
    return n;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_clkctrl;
    reset();

    // ---------------------------------------------------- 1. los registros
    fase = "reinicio";
    chk("CLKPR arranca sin division", peek(CLKPR), 0x00);
    chk("PRR arranca con todo encendido", peek(PRR), 0x00);
    chk("SMCR arranca a cero", peek(SMCR), 0x00);
    chk("MCUCR arranca a cero", peek(MCUCR), 0x00);
    // PORF: el chip tiene que poder decir POR QUE arranco.
    chk("MCUSR arranca con PORF", peek(MCUSR), 0x01);

    fase = "almacenamiento";
    wr(PRR, 0xEF);
    chk("PRR guarda los siete bits", peek(PRR), 0xEF);
    chk("y PRR sale al exterior", dut->prr, 0xEF);
    wr(PRR, 0x00);
    chk("y se apaga entero", dut->prr, 0x00);
    wr(SMCR, 0x0F);
    chk("SMCR guarda SM2:0 y SE", peek(SMCR), 0x0F);
    wr(SMCR, 0x00);

    // ------------------------------------------ 2. la secuencia de CLKPCE
    fase = "secuencia CLKPCE";
    wr(CLKPR, 0x03);
    chk("sin ventana, CLKPS no cambia", peek(CLKPR) & 0x0F, 0x00);

    wr(CLKPR, 0x80);
    chk("la escritura que abre pone CLKPCE", peek(CLKPR) & 0x80, 0x80);
    wr(CLKPR, 0x03);
    chk("dentro de la ventana, CLKPS cambia", peek(CLKPR) & 0x0F, 0x03);
    chk("y CLKPCE se cae", peek(CLKPR) & 0x80, 0x00);
    periodo = 8;

    // Volver a 0 para seguir.
    pon_clkps(0);
    chk("se puede volver a cero", peek(CLKPR) & 0x0F, 0x00);

    // LA DIFERENCIA CON EL PERRO GUARDIAN: alli la escritura que abre lleva DOS
    // bits a uno. Aqui la hoja de datos pide CLKPCE a uno Y TODO LO DEMAS A
    // CERO, asi que 0x83 no abre nada.
    wr(CLKPR, 0x83);
    chk("0x83 no abre la ventana", peek(CLKPR) & 0x80, 0x00);
    wr(CLKPR, 0x05);
    chk("y por tanto CLKPS no cambia", peek(CLKPR) & 0x0F, 0x00);

    // Fuera de la ventana: cinco ciclos despues ya no vale.
    wr(CLKPR, 0x80);
    run(5);
    wr(CLKPR, 0x07);
    chk("pasados 4 ciclos, CLKPS no cambia", peek(CLKPR) & 0x0F, 0x00);

    // ------------------------------------------------- 3. la division MEDIDA
    fase = "division";
    for (int v = 0; v <= 8; v++) {
        reset();
        pon_clkps(v);
        char n[64];
        snprintf(n, sizeof n, "CLKPS=%d divide por %d", v, 1 << v);
        chk(n, mide_periodo(), 1 << v);
    }
    // Los reservados 9..15 se tratan como el 8, que es la division mayor: un
    // chip mas lento del que se pidio funciona despacio; uno mas rapido
    // incumple los tiempos.
    for (int v = 9; v <= 15; v++) {
        reset();
        pon_clkps(v);
        char n[64];
        snprintf(n, sizeof n, "CLKPS=%d (reservado) divide por 256", v);
        chk(n, mide_periodo(), 256);
    }

    // LA HABILITACION ES UN PULSO, NO UN NIVEL, y esto hay que mirarlo aparte:
    // un `ce` que estuviera alto media division mediria el mismo PERIODO entre
    // subidas y dejaria correr al chip al doble. Se cuenta cuantas veces esta
    // alto en un tramo largo.
    fase = "division";
    reset();
    pon_clkps(3);
    {
        int altos = 0;
        for (int i = 0; i < 80; i++) { tick(); if (dut->ce_io) altos++; }
        chk("con CLKPS=3 hay 10 habilitaciones en 80 ciclos", altos, 10);
    }

    // LA VENTANA CUENTA CICLOS DE SISTEMA, NO DE ENTRADA. Con el prescaler
    // puesto son dos cosas distintas, y contar en los de entrada da una ventana
    // que se cierra 2^CLKPS veces antes de tiempo: la secuencia correcta de un
    // programa dejaria de funcionar en cuanto bajara el reloj.
    fase = "ventana con prescaler";
    reset();
    pon_clkps(2);                       // division por 4
    wr(CLKPR, 0x80);                    // abre; wr() dura un ciclo de sistema
    run(periodo * 3);                   // tres ciclos de sistema mas
    wr(CLKPR, 0x01);
    chk("a los 3 ciclos de sistema aun vale", peek(CLKPR) & 0x0F, 0x01);

    reset();
    pon_clkps(2);
    wr(CLKPR, 0x80);
    run(periodo * 5);                   // cinco: fuera
    wr(CLKPR, 0x06);
    chk("a los 5 ciclos de sistema ya no", peek(CLKPR) & 0x0F, 0x02);

    // ------------------------------------------------------- 4. el sueño
    reset();
    fase = "sueño";

    // Sin SE, SLEEP es un NOP. avr-libc pone SE, duerme y vuelve a quitarlo
    // justo para esto.
    dut->sleep_pulso = 1; dut->eval(); run(2);
    dut->sleep_pulso = 0; dut->eval();
    chk("sin SE no se duerme", dut->dormido, 0);

    // Idle: el nucleo se para y los perifericos SIGUEN. Es lo que hace util el
    // modo: un temporizador sigue contando mientras la CPU no gasta.
    wr(SMCR, 0x01);                     // SM=000, SE=1
    dut->sleep_pulso = 1; dut->eval(); run(2);
    dut->sleep_pulso = 0; dut->eval();
    chk("con SE se duerme", dut->dormido, 1);
    chk("Idle para el nucleo", dut->ce_cpu, 0);
    chk("Idle NO para los perifericos", dut->ce_io, 1);
    run(20);
    chk("y sigue dormido", dut->dormido, 1);

    // Despierta una interrupcion habilitada EN SU MASCARA. El bit I global no
    // hace falta: con I a cero el chip despierta y sigue por la instruccion de
    // despues del SLEEP, sin entrar en ninguna ISR.
    dut->irq_pendiente = 1; dut->eval(); run(2);
    dut->irq_pendiente = 0; dut->eval();
    chk("una interrupcion despierta", dut->dormido, 0);
    chk("y el nucleo vuelve a correr", dut->ce_cpu, 1);

    // Power-down: se paran LOS DOS relojes. De ahi sale solo que un flanco no
    // pueda despertar -sin reloj de perifericos no hay deteccion de flancos-,
    // que es lo que dice la hoja de datos.
    wr(SMCR, 0x05);                     // SM=010 power-down, SE=1
    dut->sleep_pulso = 1; dut->eval(); run(2);
    dut->sleep_pulso = 0; dut->eval();
    chk("power-down para el nucleo", dut->ce_cpu, 0);
    chk("power-down TAMBIEN para los perifericos", dut->ce_io, 0);
    dut->irq_pendiente = 1; dut->eval(); run(2);
    dut->irq_pendiente = 0; dut->eval();
    chk("y aun asi despierta", dut->dormido, 0);

    // Los reservados 100 y 101 se tratan como Idle, que es el modo mas suave:
    // un modo de mas apaga un reloj que alguien esperaba encendido.
    wr(SMCR, 0x09);                     // SM=100 reservado, SE=1
    dut->sleep_pulso = 1; dut->eval(); run(2);
    dut->sleep_pulso = 0; dut->eval();
    chk("el modo reservado 100 se trata como Idle", dut->ce_io, 1);
    dut->irq_pendiente = 1; dut->eval(); run(2);
    dut->irq_pendiente = 0; dut->eval();

    // Despertar gana sobre dormirse: si llegan a la vez, el chip NO se duerme.
    // Al reves se perderia el despertar y el chip no volveria nunca.
    wr(SMCR, 0x01);
    dut->sleep_pulso = 1; dut->irq_pendiente = 1; dut->eval(); run(2);
    dut->sleep_pulso = 0; dut->irq_pendiente = 0; dut->eval();
    chk("despertar gana a dormirse en el mismo ciclo", dut->dormido, 0);

    // ----------------------------------------------------------- 5. MCUSR
    reset();
    fase = "MCUSR";
    chk("PORF puesto al arrancar", peek(MCUSR) & 0x01, 0x01);

    dut->wdt_reset = 1; dut->eval(); run(2);
    dut->wdt_reset = 0; dut->eval();
    chk("el perro guardian pone WDRF", peek(MCUSR) & 0x08, 0x08);

    // SE LIMPIA ESCRIBIENDO CERO, al reves que el resto del chip.
    wr(MCUSR, 0xFF);
    chk("escribir unos NO limpia", peek(MCUSR) & 0x09, 0x09);
    wr(MCUSR, 0x00);
    chk("escribir ceros limpia", peek(MCUSR), 0x00);

    // ----------------------------------------------------------- 6. MCUCR
    reset();
    fase = "MCUCR";
    wr(MCUCR, 0x10);
    chk("PUD se escribe sin ventana", peek(MCUCR) & 0x10, 0x10);
    chk("y sale al exterior", dut->pud, 1);
    wr(MCUCR, 0x00);
    chk("PUD se quita", dut->pud, 0);

    // IVSEL tiene SU PROPIA ventana, la cuarta secuencia temporizada del chip.
    wr(MCUCR, 0x02);
    chk("sin ventana, IVSEL no cambia", dut->ivsel, 0);

    wr(MCUCR, 0x01);                    // IVCE
    chk("la escritura que abre pone IVCE", peek(MCUCR) & 0x01, 0x01);
    wr(MCUCR, 0x02);                    // IVSEL dentro de la ventana
    chk("dentro de la ventana, IVSEL cambia", dut->ivsel, 1);
    chk("y IVCE se cae", peek(MCUCR) & 0x01, 0x00);

    wr(MCUCR, 0x01);
    run(5);
    wr(MCUCR, 0x00);
    chk("pasados 4 ciclos, IVSEL no cambia", dut->ivsel, 1);

    dut->final();
#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;
    printf("  %ld comprobaciones, %d fallos\n", checks, fails);
    if (fails) {
        printf("  simavr no modela este periferico: CLKPR no divide nada alli.\n"
               "  El oraculo son los capitulos 9 y 10 de la hoja de datos.\n");
        return 1;
    }
    printf("  division, secuencias temporizadas, sueño y MCUSR correctos\n");
    return 0;
}
