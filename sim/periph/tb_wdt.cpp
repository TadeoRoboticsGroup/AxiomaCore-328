// AxiomaCore-328 - banco del perro guardian
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// simavr NO MODELA EL PERRO GUARDIAN: no tiene WDTCSR ni cuenta nada. El oraculo
// es la hoja de datos, capitulo 11, y sobre todo sus dos tablas: la 11-1 con los
// periodos del prescaler y la 11-2 con los tres modos.
//
// LO QUE MAS IMPORTA AQUI NO ES LA CUENTA SINO LA SECUENCIA TEMPORIZADA. Un
// perro guardian que se pueda apagar con una escritura suelta no sirve para
// nada: lo que vigila es justamente un programa desbocado, y un programa
// desbocado escribe en cualquier registro.

#include "Vaxioma_wdt.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>

static Vaxioma_wdt *dut;
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

// Un pulso del oscilador de 128 kHz. No vive en el modulo (ADR 0002): en la
// FPGA se divide del reloj de sistema y en silicio es una celda del PDK.
static long osc_cuenta = 0;
// EL REINICIO ES UN PULSO DE UN CICLO, asi que hay que mirarlo DENTRO del
// avance y no despues: el banco que lo mire al volver ya se lo ha perdido. Es
// la misma leccion que el arnes diferencial aprendio con `dbg_irq_entry`.
static int vio_reset = 0;
static void osc(int n) {
    for (int i = 0; i < n; i++) {
        dut->osc_tick = 1; tick();
        if (dut->wdt_reset) vio_reset = 1;
        dut->osc_tick = 0; tick();
        if (dut->wdt_reset) vio_reset = 1;
        osc_cuenta++;
    }
}

enum { WDTCSR = 0x40 };
enum { WDIF = 0x80, WDIE = 0x40, WDP3 = 0x20, WDCE = 0x10, WDE = 0x08 };

static void wr(uint8_t d) {
    dut->io_addr = WDTCSR; dut->io_wdata = d; dut->io_we = 1;
    tick();
    dut->io_we = 0; dut->io_addr = 0; dut->eval();
}

static uint8_t peek() {
    dut->io_addr = WDTCSR; dut->eval();
    uint8_t v = dut->io_rdata;
    dut->io_addr = 0; dut->eval();
    return v;
}

// La secuencia de la hoja de datos: WDCE y WDE a uno a la vez, y dentro de los
// cuatro ciclos siguientes el valor que se quiere.
static void secuencia(uint8_t valor) {
    wr(WDCE | WDE);
    wr(valor);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_wdt;

    dut->rst_n = 0; dut->clk = 0;

    dut->ce = 1;   // a reloj entero: la habilitacion es cosa de CLKPR (ADR 0003)
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->osc_tick = 0; dut->wdr = 0; dut->ack_wdt = 0;
    dut->eval();
    tick();
    dut->rst_n = 1; dut->eval();

    // ------------------------------------------------ 1. valores de reset
    fase = "reset";
    chk("WDTCSR", peek(), 0x00);
    // Una lectura DE VERDAD, con `io_re` levantada. Este periferico no tiene
    // efectos laterales de lectura, pero la puerta de cobertura no sabe eso: si
    // nadie levanta la senial, la linea sale sin cubrir y el informe miente un
    // poco sobre lo que se ha ejercitado.
    dut->io_addr = WDTCSR; dut->io_re = 1; dut->eval();
    chk("y leyendolo de verdad, igual", dut->io_rdata, 0x00);
    tick(); dut->io_re = 0; dut->io_addr = 0; dut->eval();
    chk("no reinicia nada", dut->wdt_reset, 0);
    chk("ni pide interrupcion", dut->irq_wdt, 0);

    // ------------------------------- 2. LA SECUENCIA TEMPORIZADA
    // Es lo que de verdad hay que implementar bien: sin ella, un programa
    // desbocado apaga a su propio vigilante.
    fase = "la secuencia temporizada";
    {
        // Una escritura suelta NO cambia WDE ni el prescaler.
        wr(WDE | 0x07);
        chk("una escritura suelta no enciende WDE", (peek() & WDE) != 0, 0);
        chk("ni toca el prescaler", peek() & 0x27, 0x00);

        // La secuencia SI.
        secuencia(WDE | 0x05);
        chk("con la secuencia, WDE se enciende", (peek() & WDE) != 0, 1);
        chk("y el prescaler entra", peek() & 0x27, 0x05);

        // Y la ventana se cierra sola. Cuatro ciclos despues de abrirla, una
        // escritura ya no vale.
        wr(WDCE | WDE);
        run(6);                       // dejar que la ventana expire
        wr(0x00);                     // intento de apagar, fuera de plazo
        chk("fuera de la ventana, la escritura se ignora",
            (peek() & WDE) != 0, 1);

        // Dentro de plazo si.
        secuencia(0x00);
        chk("dentro de plazo, WDE se apaga", (peek() & WDE) != 0, 0);
    }

    // --------------------------- 3. el orden de los bits de WDTCSR
    // WDP3 esta en el bit 5 y WDP2..0 en los 2..0, con WDCE y WDE EN MEDIO. Es
    // lo que pasa cuando un registro crece de tres bits a cuatro.
    fase = "el orden raro de los bits";
    {
        secuencia(WDP3 | 0x02);       // WDP = 1010 = 10
        chk("WDP3 se lee en el bit 5", (peek() & WDP3) != 0, 1);
        chk("y los tres bajos donde toca", peek() & 0x07, 0x02);
        secuencia(0x00);
    }

    // ------------------------------- 4. los periodos del prescaler
    // Tabla 11-1: WDP=0 son 2K ciclos del oscilador, y cada paso duplica.
    fase = "los periodos de la tabla 11-1";
    for (int wdp = 0; wdp <= 3; wdp++) {
        uint8_t reg = (uint8_t)(((wdp & 8) ? WDP3 : 0) | (wdp & 7));
        secuencia((uint8_t)(WDIE | reg));   // solo interrupcion, para medirlo
        wr((uint8_t)(WDIF | WDIE | reg));   // limpiar la bandera
        dut->wdr = 1; tick(); dut->wdr = 0; tick();   // rearmar

        long esperado = 2048L << wdp;
        long t = 0;
        while (t < esperado * 2 && !(peek() & WDIF)) { osc(1); t++; }
        chk("el periodo son 2K ciclos por su potencia de dos",
            (uint32_t)t, (uint32_t)esperado);
    }
    secuencia(0x00);

    // ------------------------------------------ 5. WDR rearma la cuenta
    fase = "WDR rearma";
    {
        secuencia(WDIE | 0x00);                    // 2K ciclos
        wr(WDIF | WDIE);
        for (int i = 0; i < 10; i++) {
            osc(1024);                             // medio periodo
            dut->wdr = 1; tick(); dut->wdr = 0; tick();
            chk("con WDR a tiempo no vence nunca", (peek() & WDIF) != 0, 0);
        }
        // Y sin WDR, vence.
        osc(2100);
        chk("sin WDR, vence", (peek() & WDIF) != 0, 1);
        wr(WDIF | WDIE);
        secuencia(0x00);
    }

    // --------------------------------- 6. los tres modos, tabla 11-2
    fase = "los tres modos";
    {
        // Solo interrupcion: salta el vector y NO reinicia.
        secuencia(WDIE | 0x00);
        wr(WDIF | WDIE);
        osc(2100);
        chk("solo interrupcion: la bandera sube", (peek() & WDIF) != 0, 1);
        chk("y con WDIE hay peticion", dut->irq_wdt, 1);
        chk("pero no reinicia", dut->wdt_reset, 0);
        // Atender el vector limpia la bandera en su origen.
        dut->ack_wdt = 1; tick(); dut->ack_wdt = 0; tick();
        chk("el reconocimiento la limpia", (peek() & WDIF) != 0, 0);
        secuencia(0x00);

        // Solo reinicio: ni bandera ni vector, reinicio y punto.
        secuencia(WDE | 0x00);
        vio_reset = 0;
        osc(2100);
        chk("solo reinicio: reinicia", vio_reset, 1);
        chk("y no deja bandera", (peek() & WDIF) != 0, 0);
        secuencia(0x00);

        // LOS DOS: primero la interrupcion, y el hardware LIMPIA WDIE, de modo
        // que el siguiente vencimiento ya reinicia. Es el patron de «guardar el
        // estado y morir».
        secuencia(WDIE | WDE | 0x00);
        wr(WDIF | WDIE | WDE);
        vio_reset = 0;
        osc(2100);
        chk("los dos: primero interrumpe", (peek() & WDIF) != 0, 1);
        // Y NO REINICIA EN ESE MISMO VENCIMIENTO: ese es todo el sentido del
        // modo, darle a la ISR un periodo entero para guardar el estado. Se
        // mira con `vio_reset` y no con el pin al volver, porque el pulso dura
        // UN ciclo: el mutante que reinicia ademas de interrumpir sobrevivia a
        // la comprobacion que lo miraba tarde.
        chk("sin reiniciar todavia", vio_reset, 0);
        chk("y el hardware limpia WDIE", (peek() & WDIE) != 0, 0);
        // El siguiente vencimiento ya reinicia.
        vio_reset = 0;
        osc(2100);
        chk("y el siguiente vencimiento reinicia", vio_reset, 1);
        secuencia(0x00);
    }

    // ------------------------------- 7. apagado, el perro no cuenta
    fase = "apagado";
    {
        secuencia(0x00);
        wr(WDIF);
        vio_reset = 0;
        osc(5000);
        chk("con los dos bits apagados no pasa nada", (peek() & WDIF) != 0, 0);
        chk("ni reinicia", vio_reset, 0);

        // Y EL CONTADOR TIENE QUE ESTAR QUIETO, no solo callado. Si sigue
        // corriendo mientras el perro esta apagado, al encenderlo la cuenta
        // arranca por donde se quedo y el primer vencimiento llega ANTES de
        // tiempo — un reinicio que el programa no espera. Se enciende sin WDR
        // a proposito: con un WDR de por medio, la cuenta se pone a cero y el
        // fallo no se ve.
        secuencia(WDIE | 0x00);
        wr(WDIF | WDIE);
        osc(2000);
        chk("al encender, la cuenta empieza de cero", (peek() & WDIF) != 0, 0);
        osc(100);
        chk("y vence en su periodo entero", (peek() & WDIF) != 0, 1);
        wr(WDIF | WDIE);
        secuencia(0x00);
    }

    // --------------------- 8. WDIE no esta protegido por la secuencia
    // Lo protegido es lo que puede DESACTIVAR la vigilancia. Cambiar que hace al
    // vencer se puede hacer con una escritura suelta.
    fase = "WDIE se escribe sin secuencia";
    {
        wr(WDIE);
        chk("WDIE entra con una escritura suelta", (peek() & WDIE) != 0, 1);
        wr(0x00);
        chk("y se quita igual", (peek() & WDIE) != 0, 0);
    }

#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;
    printf("  %ld comprobaciones, %d fallos (%ld ciclos del oscilador)\n",
           checks, fails, osc_cuenta);
    if (fails) {
        printf("  simavr no modela este periferico: el oraculo es la hoja de\n"
               "  datos, capitulo 11, con sus tablas 11-1 y 11-2.\n");
        return 1;
    }
    printf("  secuencia temporizada, periodos y los tres modos correctos\n");
    return 0;
}
