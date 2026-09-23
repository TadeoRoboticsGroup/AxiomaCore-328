// AxiomaCore-328 - banco de la EEPROM
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// simavr SI tiene EEPROM, pero su modelo es de almacenamiento: escribe el byte
// cuando se le pide y no cuenta los 3,4 ms ni distingue los modos de `EEPM`.
// El oraculo es la hoja de datos, capitulo 8.
//
// LO QUE MAS IMPORTA AQUI, por orden:
//
//   1. LA SECUENCIA TEMPORIZADA. Una escritura perdida en la EEPROM no se nota
//      hasta el siguiente arranque, y para entonces el dato bueno ya no esta.
//   2. LA FISICA DE LA CELDA. Borrar la pone a 0xFF y escribir sin borrar solo
//      puede APAGAR unos. Un modelo que trate la EEPROM como RAM hace funcionar
//      aqui codigo que en silicio no funciona.
//   3. EL TIEMPO. 3,4 ms borrando y escribiendo, 1,8 ms haciendo solo una de
//      las dos. Es lo que hace que una rutina de guardado tarde lo que tarda.

#include "Vaxioma_eeprom.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>

static Vaxioma_eeprom *dut;
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

// El oscilador que fija el tiempo de grabacion. No vive en el modulo: es el
// mismo criterio del ADR 0002 y el mismo que en el perro guardian.
static long osc_cuenta = 0;
static void osc(int n) {
    for (int i = 0; i < n; i++) {
        dut->osc_tick = 1; tick();
        dut->osc_tick = 0; tick();
        osc_cuenta++;
    }
}

enum { EECR = 0x1F, EEDR = 0x20, EEARL = 0x21, EEARH = 0x22 };
enum { EEPM1 = 0x20, EEPM0 = 0x10, EERIE = 0x08, EEMPE = 0x04, EEPE = 0x02,
       EERE = 0x01 };

static void wr(uint8_t a, uint8_t d) {
    dut->io_addr = a; dut->io_wdata = d; dut->io_we = 1;
    tick();
    dut->io_we = 0; dut->io_addr = 0; dut->eval();
}

static uint8_t peek(uint8_t a) {
    dut->io_addr = a; dut->eval();
    uint8_t v = dut->io_rdata;
    dut->io_addr = 0; dut->eval();
    return v;
}

static void direccion(uint16_t a) {
    wr(EEARH, (uint8_t)(a >> 8));
    wr(EEARL, (uint8_t)(a & 0xFF));
    run(2);                      // que el puerto de lectura presente la celda
}

// La secuencia de la hoja de datos: EEMPE primero, EEPE dentro de cuatro ciclos.
// Devuelve cuantos ciclos del oscilador tardo la grabacion.
static long grabar(uint8_t modo) {
    wr(EECR, (uint8_t)(modo | EEMPE));
    wr(EECR, (uint8_t)(modo | EEPE));
    long t = 0;
    while ((peek(EECR) & EEPE) && t < 2000) { osc(1); t++; }
    return t;
}

// Leer una celda: EERE es una ESCRITURA en EECR, y el byte aparece en EEDR.
static uint8_t leer(uint16_t a) {
    direccion(a);
    wr(EECR, EERE);
    run(1);
    return peek(EEDR);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_eeprom;

    dut->rst_n = 0; dut->clk = 0;

    dut->ce = 1;   // a reloj entero: la habilitacion es cosa de CLKPR (ADR 0003)
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->osc_tick = 0;
    dut->eval();
    tick();
    dut->rst_n = 1; dut->eval();
    run(4);

    // ------------------------------------------------ 1. valores de reset
    fase = "reset";
    chk("EECR", peek(EECR), 0x00);
    chk("EEDR", peek(EEDR), 0x00);
    chk("EEARL", peek(EEARL), 0x00);
    chk("EEARH", peek(EEARH), 0x00);
    chk("no pide interrupcion", dut->irq_ee, 0);
    // Una lectura DE VERDAD, con `io_re` levantada. Este periferico no tiene
    // efectos laterales de lectura -la celda la lee `EERE`, que es una
    // ESCRITURA en EECR-, pero la puerta de cobertura no sabe eso: sin nadie
    // que levante la senial, la linea sale sin cubrir.
    dut->io_addr = EECR; dut->io_re = 1; dut->eval();
    chk("y leyendolo de verdad, igual", dut->io_rdata, 0x00);
    tick(); dut->io_re = 0; dut->io_addr = 0; dut->eval();

    // UNA EEPROM DE FABRICA ESTA BORRADA: todas las celdas a 0xFF. Un programa
    // que lea una posicion virgen tiene que encontrarse 0xFF, no ceros, y de eso
    // dependen las rutinas que usan 0xFF como «aqui no hay nada escrito».
    fase = "de fabrica";
    chk("la celda 0 nace borrada", leer(0x000), 0xFF);
    chk("y la ultima tambien", leer(0x3FF), 0xFF);

    // ------------------------------- 2. los registros se leen de vuelta
    fase = "lectura de vuelta";
    wr(EEDR, 0xA5);
    chk("EEDR devuelve lo escrito sin haber leido ninguna celda",
        peek(EEDR), 0xA5);
    wr(EEARH, 0xFF);
    chk("EEARH solo tiene dos bits: 1 KB son diez", peek(EEARH), 0x03);
    wr(EEARL, 0x5A);
    chk("EEARL entero", peek(EEARL), 0x5A);
    wr(EECR, 0xFF & ~(uint8_t)(EEMPE | EEPE | EERE));
    chk("EECR: los dos bits altos no existen", peek(EECR) & 0xC0, 0x00);
    chk("y EEPM y EERIE si", peek(EECR) & 0x38, 0x38);
    wr(EECR, 0x00);
    wr(EEARH, 0x00);

    // ------------------------------- 3. LA SECUENCIA TEMPORIZADA
    fase = "la secuencia temporizada";
    {
        direccion(0x010);
        wr(EEDR, 0x42);

        // Sin EEMPE, EEPE no arranca nada.
        wr(EECR, EEPE);
        chk("EEPE suelto no arranca", (peek(EECR) & EEPE) != 0, 0);
        osc(600);
        chk("y la celda sigue borrada", leer(0x010), 0xFF);

        // Con EEMPE pero FUERA de plazo, tampoco.
        direccion(0x010);
        wr(EEDR, 0x42);
        wr(EECR, EEMPE);
        run(6);                      // dejar que la ventana expire
        wr(EECR, EEPE);
        chk("fuera de los cuatro ciclos tampoco", (peek(EECR) & EEPE) != 0, 0);
        osc(600);
        chk("y la celda sigue borrada", leer(0x010), 0xFF);

        // Y EEMPE se cae solo, sin que nadie lo baje.
        wr(EECR, EEMPE);
        chk("EEMPE se lee puesto", (peek(EECR) & EEMPE) != 0, 1);
        run(6);
        chk("y se cae solo a los cuatro ciclos", (peek(EECR) & EEMPE) != 0, 0);
    }

    // --------------------------------- 4. escribir y volver a leer
    fase = "escribir y leer";
    {
        direccion(0x010);
        wr(EEDR, 0x42);
        long t = grabar(0x00);
        chk("la grabacion termina", t < 2000, 1);
        chk("y el byte esta ahi", leer(0x010), 0x42);
        // Y no ha tocado a la vecina.
        chk("la celda de al lado sigue borrada", leer(0x011), 0xFF);
    }

    // ------------------------ 5. EL TIEMPO, que es de la tabla 8-1
    // 3,4 ms borrando y escribiendo -435 ciclos de 128 kHz-, 1,8 ms haciendo
    // solo una de las dos -230-.
    fase = "los tiempos de la tabla 8-1";
    {
        direccion(0x020);
        wr(EEDR, 0x11);
        chk("borrar y escribir: 3,4 ms", (uint32_t)grabar(0x00), 435);

        direccion(0x021);
        wr(EEDR, 0x22);
        chk("solo borrar: 1,8 ms", (uint32_t)grabar(EEPM0), 230);

        direccion(0x022);
        wr(EEDR, 0x33);
        chk("solo escribir: 1,8 ms", (uint32_t)grabar(EEPM1), 230);
    }

    // --------------- 6. LA FISICA DE LA CELDA, que es lo que no es RAM
    fase = "la celda baja bits, no los sube";
    {
        // Partimos de una celda escrita con 0x0F.
        direccion(0x030);
        wr(EEDR, 0x0F);
        grabar(0x00);
        chk("queda 0x0F", leer(0x030), 0x0F);

        // SOLO ESCRIBIR sobre una celda que ya tiene bits bajados NO los sube:
        // hace un AND. Es lo que fisicamente puede una EEPROM.
        direccion(0x030);
        wr(EEDR, 0xF3);
        grabar(EEPM1);
        chk("escribir sin borrar solo apaga unos", leer(0x030), 0x03);

        // SOLO BORRAR la deja a 0xFF, sin mirar EEDR.
        direccion(0x030);
        wr(EEDR, 0x00);
        grabar(EEPM0);
        chk("borrar la deja a 0xFF pase lo que pase en EEDR",
            leer(0x030), 0xFF);

        // Y borrar+escribir si pone el byte tal cual, aunque suba bits.
        direccion(0x030);
        wr(EEDR, 0x0F);
        grabar(0x00);
        direccion(0x030);
        wr(EEDR, 0xF0);
        grabar(0x00);
        chk("borrar y escribir pone el byte entero", leer(0x030), 0xF0);
    }

    // ------------------- 7. EEPE bloquea mientras dura la grabacion
    fase = "EEPE bloquea";
    {
        direccion(0x040);
        wr(EEDR, 0x77);
        wr(EECR, EEMPE);
        wr(EECR, EEPE);
        chk("EEPE se lee puesto durante la grabacion",
            (peek(EECR) & EEPE) != 0, 1);

        // Un segundo intento a otra direccion NO debe colarse.
        direccion(0x041);
        wr(EEDR, 0x88);
        wr(EECR, EEMPE);
        wr(EECR, EEPE);
        while (peek(EECR) & EEPE) osc(1);
        chk("el primero llego", leer(0x040), 0x77);
        chk("y el segundo no se colo", leer(0x041), 0xFF);
    }

    // ----------------------- 8. EE_READY ES UN NIVEL, no una bandera
    // «The interrupt is constantly triggered when EEPE is cleared». No hay nada
    // que limpiar: la ISR tiene que quitar EERIE o lanzar otra escritura.
    fase = "EE_READY es de nivel";
    {
        wr(EECR, 0x00);
        chk("sin EERIE no hay peticion", dut->irq_ee, 0);
        wr(EECR, EERIE);
        chk("con EERIE y sin grabar, peticion CONSTANTE", dut->irq_ee, 1);
        run(50);
        chk("y sigue ahi, porque es un nivel", dut->irq_ee, 1);

        // Durante una grabacion se calla, que es justo lo que la hace util.
        direccion(0x050);
        wr(EEDR, 0x99);
        wr(EECR, (uint8_t)(EERIE | EEMPE));
        wr(EECR, (uint8_t)(EERIE | EEPE));
        chk("mientras graba, se calla", dut->irq_ee, 0);
        while (peek(EECR) & EEPE) osc(1);
        chk("y al terminar vuelve", dut->irq_ee, 1);
        wr(EECR, 0x00);
        chk("quitar EERIE la apaga", dut->irq_ee, 0);
    }

    // ------------------------------ 9. el kilobyte entero es accesible
    // Un byte por cada bit de direccion, para que un cable cruzado en EEAR se
    // vea. Con 1 024 grabaciones completas el banco tardaria de mas: se prueban
    // las direcciones que hacen visible cada bit.
    fase = "las diez lineas de direccion";
    {
        static const uint16_t dirs[] = {0x001, 0x002, 0x004, 0x008, 0x010,
                                        0x020, 0x040, 0x080, 0x100, 0x200,
                                        0x3FF};
        for (size_t k = 0; k < sizeof(dirs)/sizeof(dirs[0]); k++) {
            direccion(dirs[k]);
            wr(EEDR, (uint8_t)(0xC0 | k));
            grabar(0x00);
        }
        for (size_t k = 0; k < sizeof(dirs)/sizeof(dirs[0]); k++)
            chk("cada direccion guarda lo suyo", leer(dirs[k]),
                (uint8_t)(0xC0 | k));
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
        printf("  simavr tiene EEPROM, pero la suya es almacenamiento: no cuenta\n"
               "  los 3,4 ms ni distingue los modos. El oraculo es el capitulo 8.\n");
        return 1;
    }
    printf("  secuencia, fisica de la celda, tiempos y EE_READY correctos\n");
    return 0;
}
