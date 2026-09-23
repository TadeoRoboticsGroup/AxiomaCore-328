// AxiomaCore-328 - PRR: que cada bit apague SU periférico y sólo el suyo
// SPDX-License-Identifier: Apache-2.0
//
// `PRR` apaga siete periféricos uno a uno para ahorrar corriente, y con la
// habilitación de reloj ya repartida (ADR 0003) implementarlo es **una `and`
// por módulo**. Eso lo hace barato, y también lo hace fácil de cablear mal: un
// bit cambiado de sitio apaga el periférico de al lado, y **eso no lo nota
// ningún banco de módulo** — en cada periférico `ce` es un puerto y da igual
// quién lo mueva.
//
// Así que aquí se ponen **los siete a moverse a la vez** y se apaga uno cada
// vez. La comprobación es doble y las dos mitades hacen falta:
//
//   - **el que se apaga se para** — si no, el bit no llega;
//   - **LOS OTROS SEIS SIGUEN** — si no, el bit llega a más de uno, o alguien
//     ató la habilitación a `~|prr` y apaga todo con cualquier bit puesto.
//
// La segunda mitad es la que de verdad distingue siete cables de uno.
//
// CÓMO SE MIRA CADA UNO, que es lo que ha decidido la forma del programa:
//
//   Timer0   `OC0A` en PD6, conmutando en modo CTC
//   Timer1   `OC1A` en PB1, igual
//   Timer2   `OC2B` en PD3 — PB3 no vale, ahí manda `MOSI`
//   USART    `TXD` en PD1, con el bucle escribiendo `UDR0` sin parar
//   SPI      `SCK` en PB5, con el bucle escribiendo `SPDR` sin parar
//   TWI      `SCL` en PC5, y se mira su HABILITACIÓN DE SALIDA y no su valor:
//            el TWI es colector abierto, no «saca» un uno, tira a cero o suelta
//   ADC      el pulso del S/H, en modo libre, que se rearma solo
//
// Los siete van por pines distintos a propósito: si dos compartieran, apagar
// uno parecería apagar al otro.

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

static uint16_t LDI(int d, int k) {
    return 0xE000 | ((k & 0xF0) << 4) | (((d - 16) & 0xF) << 4) | (k & 0xF);
}
static void STS(std::vector<uint16_t> &p, int dir, int reg) {
    p.push_back(0x9200 | (reg << 4));
    p.push_back((uint16_t)dir);
}
static void PON(std::vector<uint16_t> &p, int dir, int val) {
    p.push_back(LDI(16, val));
    STS(p, dir, 16);
}

enum { D_DDRB = 0x24, D_DDRC = 0x27, D_PORTC = 0x28, D_DDRD = 0x2A,
       D_TCCR0A = 0x44, D_TCCR0B = 0x45, D_OCR0A = 0x47,
       D_TCCR1A = 0x80, D_TCCR1B = 0x81, D_OCR1AL = 0x88, D_OCR1AH = 0x89,
       D_TCCR2A = 0xB0, D_TCCR2B = 0xB1, D_OCR2A = 0xB3, D_OCR2B = 0xB4,
       D_UBRR0L = 0xC4, D_UCSR0B = 0xC1, D_UDR0 = 0xC6,
       D_SPCR = 0x4C, D_SPDR = 0x4E,
       D_TWBR = 0xB8, D_TWCR = 0xBC,
       D_ADMUX = 0x7C, D_ADCSRA = 0x7A, D_ADCSRB = 0x7B,
       D_PRR = 0x64 };

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

// Enciende LOS SIETE y luego escribe `prr`. Lo unico que cambia entre las ocho
// pasadas es ese byte: si el programa es el mismo, la diferencia observada solo
// puede venir de `PRR`.
static std::vector<uint16_t> programa(uint8_t prr) {
    std::vector<uint16_t> p;

    // Direcciones de los pines que llevan salida propia.
    PON(p, D_DDRD, 0x4A);               // PD6 OC0A, PD3 OC2B, PD1 TXD
    // PB2 es `SS`, Y TIENE QUE SER SALIDA. Con el SPI en maestro y `SS` como
    // entrada, un cero en ese pin LIMPIA `MSTR` y el SPI se pasa a esclavo:
    // es la hoja de datos, y con el modelo de pad de lazo cerrado un pin de
    // entrada sin pull-up lee cero. Sin esto el SPI no genera un solo pulso, y
    // el banco lo confundiria con «bien apagado».
    PON(p, D_DDRB, 0x2E);               // PB5 SCK, PB3 MOSI, PB2 SS, PB1 OC1A

    // EL BUS DEL TWI TIENE QUE ESTAR LIBRE, y en este arnes eso quiere decir
    // con pull-up: las dos lineas son de colector abierto y el modelo de pad
    // las lee a cero si nadie las levanta. Con el bus visto como ocupado, el
    // maestro no arranca ningun START y tampoco daria un solo pulso.
    PON(p, D_PORTC, 0x30);              // PC5 SCL, PC4 SDA

    // Timer0: CTC, conmuta OC0A cada OCR0A+1 ciclos.
    PON(p, D_TCCR0A, 0x42);             // COM0A=01, WGM=010
    PON(p, D_OCR0A,  0x03);
    PON(p, D_TCCR0B, 0x01);

    // Timer1: CTC con TOP en OCR1A, conmutando OC1A.
    PON(p, D_TCCR1A, 0x40);             // COM1A=01
    PON(p, D_OCR1AH, 0x00);
    PON(p, D_OCR1AL, 0x05);
    PON(p, D_TCCR1B, 0x09);             // WGM12 (CTC) + CS=001

    // Timer2: CTC con TOP en OCR2A, conmutando OC2B en la comparacion B.
    PON(p, D_TCCR2A, 0x12);             // COM2B=01, WGM=010
    PON(p, D_OCR2A,  0x07);
    PON(p, D_OCR2B,  0x03);
    PON(p, D_TCCR2B, 0x01);

    // USART: el baudio mas corto que deja el prescaler.
    PON(p, D_UBRR0L, 0x00);
    PON(p, D_UCSR0B, 0x08);             // TXEN0

    // SPI maestro, sin dividir mas de lo justo.
    PON(p, D_SPCR, 0x50);               // SPE | MSTR

    // TWI: la velocidad mas alta que deja TWBR.
    PON(p, D_TWBR, 0x02);

    // ADC en modo libre: se rearma solo, sin que el programa vuelva a tocarlo.
    PON(p, D_ADMUX,  0x00);
    PON(p, D_ADCSRB, 0x00);             // ADTS = 000, modo libre
    PON(p, D_ADCSRA, 0xE0);             // ADEN | ADSC | ADATE

    // Y AHORA `PRR`, despues de encenderlo todo: apagar un periferico ya
    // configurado es el caso de verdad, no configurarlo apagado.
    PON(p, D_PRR, prr);

    // El bucle: patea a los tres que no se mueven solos.
    size_t bucle = p.size();
    p.push_back(LDI(17, 0x55));
    STS(p, D_UDR0, 17);                 // una trama tras otra
    STS(p, D_SPDR, 17);                 // una transferencia tras otra
    p.push_back(LDI(17, 0xA4));         // TWINT | TWSTA | TWEN
    STS(p, D_TWCR, 17);                 // un START tras otro
    int salto = (int)bucle - (int)(p.size() + 1);
    p.push_back(0xC000 | (salto & 0x0FFF));
    return p;
}

// Cuenta transiciones de cada observable durante una ventana.
struct Actividad { long t0, t1, t2, usart, spi, twi, adc; };

static Actividad medir(int ciclos) {
    Actividad a = {0,0,0,0,0,0,0};
    uint8_t pb = dut->pb_out_v, pd = dut->pd_out_v, pcoe = dut->pc_oe_v;
    for (int i = 0; i < ciclos; i++) {
        tick();
        uint8_t nb = dut->pb_out_v, nd = dut->pd_out_v, npc = dut->pc_oe_v;
        if ((nd ^ pd) & (1 << 6)) a.t0++;
        if ((nb ^ pb) & (1 << 1)) a.t1++;
        if ((nd ^ pd) & (1 << 3)) a.t2++;
        if ((nd ^ pd) & (1 << 1)) a.usart++;
        if ((nb ^ pb) & (1 << 5)) a.spi++;
        if ((npc ^ pcoe) & (1 << 5)) a.twi++;
        if (dut->adc_muestrea_v)  a.adc++;
        pb = nb; pd = nd; pcoe = npc;
    }
    return a;
}

static const char *NOMBRE[7] = {"Timer0","Timer1","Timer2","USART","SPI","TWI","ADC"};

static long campo(const Actividad &a, int i) {
    switch (i) {
        case 0: return a.t0;  case 1: return a.t1;  case 2: return a.t2;
        case 3: return a.usart; case 4: return a.spi; case 5: return a.twi;
        default: return a.adc;
    }
}

// El bit de `PRR` de cada uno, en el orden de NOMBRE[]. Tabla 10-2.
static const int BIT[7] = { 5, 3, 6, 1, 2, 7, 0 };

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_clk_top;

    // ---- con PRR a cero, LOS SIETE se mueven ----
    // Sin esto lo de abajo no dice nada: un periferico que no arrancara nunca
    // pareceria «bien apagado» en su pasada.
    cargar(programa(0x00));
    for (int i = 0; i < 4000; i++) tick();     // dejar que todo arranque
    Actividad base = medir(20000);
    for (int i = 0; i < 7; i++) {
        comprobaciones++;
        if (campo(base, i) == 0) {
            printf("    FALLA con PRR=0 el %s no se mueve\n", NOMBRE[i]);
            fallos++;
        }
    }

    // ---- un bit cada vez ----
    for (int i = 0; i < 7; i++) {
        cargar(programa((uint8_t)(1 << BIT[i])));
        for (int k = 0; k < 4000; k++) tick();
        Actividad a = medir(20000);

        comprobaciones++;
        if (campo(a, i) != 0) {
            printf("    FALLA PRR bit %d deberia parar el %-7s  actividad=%ld\n",
                   BIT[i], NOMBRE[i], campo(a, i));
            fallos++;
        }
        // Y LOS OTROS SEIS SIGUEN. Es la mitad que distingue siete cables de
        // uno: sin ella, atar todas las habilitaciones a `~|prr` pasaria.
        for (int j = 0; j < 7; j++) {
            if (j == i) continue;
            comprobaciones++;
            if (campo(a, j) == 0) {
                printf("    FALLA PRR bit %d (%s) tambien paro el %s\n",
                       BIT[i], NOMBRE[i], NOMBRE[j]);
                fallos++;
            }
        }
    }

    printf("  actividad con PRR=0: T0 %ld · T1 %ld · T2 %ld · USART %ld · "
           "SPI %ld · TWI %ld · ADC %ld\n",
           base.t0, base.t1, base.t2, base.usart, base.spi, base.twi, base.adc);

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
    printf("  cada bit de PRR apaga su periferico, y solo el suyo\n");
    return 0;
}
