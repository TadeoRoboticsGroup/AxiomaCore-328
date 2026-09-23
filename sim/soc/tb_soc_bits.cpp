// AxiomaCore-328 - el barrido semántico: bit a bit, y todos rendidos
// SPDX-License-Identifier: Apache-2.0
//
// `make sim-soc` comprueba el mapa de **direcciones**: que cada registro esté
// donde dice la hoja de datos y que los huecos lean cero. Eso deja una pregunta
// entera sin contestar, y es la que de verdad decide si un programa de Arduino
// funciona: **dentro de un registro que sí existe, ¿qué hace cada bit?**
//
// Un registro puede estar en su dirección, leerse y escribirse, y tener un bit
// reservado que devuelve basura, o un bit de sólo lectura que se deja escribir,
// o una bandera de las que se limpian escribiendo un uno que se comporta como
// almacenamiento. Nada de eso lo ve el barrido de direcciones.
//
// ESTE BANCO CONTESTA LA MITAD QUE NO SE ESCRIBE A MANO, y por eso vale:
//
//   **qué bits existen** en cada registro sale de `sim/soc/regbits.h`, que lo
//   GENERA `tools/gen_regmap.py` preguntándole al preprocesador de avr-gcc con
//   avr-libc. O sea que la lista de bits reservados no es una lectura mía de un
//   PDF: es un tercero independiente, el mismo que ya decide las direcciones.
//
// Y la hoja de datos dice de los reservados una cosa comprobable: **se leen
// como cero**. Así que para cada registro implementado se escribe 0xFF, se lee,
// se escribe 0x00, se lee, y los bits que avr-libc no nombra tienen que salir a
// cero en las dos lecturas. Escribir unos importa: un bit reservado que fuera
// almacenamiento sólo se delata cuando alguien le mete un uno.
//
// CADA REGISTRO SE PRUEBA DESDE UN REINICIO LIMPIO, con su propio programa, y
// eso no es una precaución cosmética: escribir 0xFF en `WDTCSR` arma el perro
// guardián, en `EECR` lanza una grabación y en `TCCR0B` pone en marcha un
// temporizador. Con un solo programa corrido entero, la mitad de las lecturas
// serían de un chip en un estado que nadie ha pensado.

#include "Vtb_soc_top.h"
#include "verilated.h"
#include "regbits.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <vector>

static Vtb_soc_top *dut;
static int fallos = 0;
static long comprobaciones = 0;

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

// LOS REGISTROS QUE EL SoC IMPLEMENTA, tal y como los lista `tb_soc_map.cpp`.
// Se nombran y no se deducen del RTL a proposito: si alguien añade un registro
// y no lo pone aqui, el recuento del final no cuadra y el banco lo dice.
static const char *IMPLEMENTADOS[] = {
    "PINB","DDRB","PORTB","PINC","DDRC","PORTC","PIND","DDRD","PORTD",
    "TIFR0","GPIOR0","GTCCR","TCCR0A","TCCR0B","TCNT0","OCR0A","OCR0B",
    "GPIOR1","GPIOR2","TIFR1","TIMSK0","TIMSK1","TCCR1A","TCCR1B","TCCR1C",
    "TCNT1L","TCNT1H","ICR1L","ICR1H","OCR1AL","OCR1AH","OCR1BL","OCR1BH",
    "TIFR2","TIMSK2","TCCR2A","TCCR2B","TCNT2","OCR2A","OCR2B","ASSR",
    "SPCR","SPSR","SPDR","TWBR","TWSR","TWAR","TWDR","TWCR","TWAMR",
    "PCIFR","EIFR","EIMSK","PCICR","EICRA","PCMSK0","PCMSK1","PCMSK2",
    "UCSR0A","UCSR0B","UCSR0C","UBRR0L","UBRR0H","UDR0",
    "EECR","EEDR","EEARL","EEARH","WDTCSR","ACSR","DIDR1",
    "SMCR","MCUSR","MCUCR","SPMCSR","CLKPR","PRR",
    "ADCL","ADCH","ADCSRA","ADCSRB","ADMUX","DIDR0",
};
static const int N_IMPL = sizeof(IMPLEMENTADOS) / sizeof(IMPLEMENTADOS[0]);

// ---------------------------------------------------------------------------
// LA CLASE DE CADA BIT, que es la otra mitad del barrido y ésta SÍ se escribe a
// mano — no hay ningún tercero que sepa si un bit de este chip almacena o no.
//
// `rw` son los bits que son ALMACENAMIENTO LLANO: se escribe un uno y se lee un
// uno, se escribe un cero y se lee un cero. Todo lo demás que exista tiene que
// llevar un MOTIVO escrito, y el banco falla si falta. Esa es la regla que hace
// que esta tabla signifique algo: un bit sin clasificar no puede esconderse.
//
//   existen (de avr-libc)  =  rw  +  otros (con motivo)
//   reservados             =  ~existen, y se leen a cero
//
// Y de ahí sale la propiedad que se persigue: **de los 656 bits del espacio de
// I/O implementado no queda ninguno sin decir qué es**.
struct Clase { const char *reg; uint8_t rw; const char *motivo; };

static const Clase CLASES[] = {
    // --- puertos de E/S ---
    // `PINx` NO es almacenamiento: leerlo da el pin, y ESCRIBIR UN UNO CONMUTA
    // `PORTx`. Es la hoja de datos, seccion 14.2.2, y es un atajo que usan
    // bibliotecas de verdad para hacer un `toggle` de un ciclo.
    {"PINB", 0x00, "lectura del pin; escribir un uno CONMUTA PORTx"},
    {"PINC", 0x00, "lectura del pin; escribir un uno CONMUTA PORTx"},
    {"PIND", 0x00, "lectura del pin; escribir un uno CONMUTA PORTx"},
    {"DDRB", 0xFF, ""}, {"DDRC", 0x7F, ""}, {"DDRD", 0xFF, ""},
    {"PORTB",0xFF, ""}, {"PORTC",0x7F, ""}, {"PORTD",0xFF, ""},

    // --- banderas: se limpian ESCRIBIENDO UN UNO, las pone el hardware ---
    {"TIFR0", 0x00, "banderas: las pone el hardware y se limpian con un uno"},
    {"TIFR1", 0x00, "banderas: las pone el hardware y se limpian con un uno"},
    {"TIFR2", 0x00, "banderas: las pone el hardware y se limpian con un uno"},
    {"PCIFR", 0x00, "banderas: las pone el hardware y se limpian con un uno"},
    {"EIFR",  0x00, "banderas: las pone el hardware y se limpian con un uno"},

    // --- de proposito general: almacenamiento y nada mas, a proposito ---
    {"GPIOR0", 0xFF, ""}, {"GPIOR1", 0xFF, ""}, {"GPIOR2", 0xFF, ""},

    // --- prescaler compartido ---
    {"GTCCR", 0x80, "PSRASY y PSRSYNC son estrobos: reinician el prescaler y el "
                    "hardware los baja, salvo con TSM puesto"},

    // --- Timer0 ---
    {"TCCR0A", 0xF3, ""},
    {"TCCR0B", 0x0F, "FOC0A y FOC0B son de SOLO ESCRITURA: fuerzan una "
                     "comparacion y se leen siempre a cero"},
    {"TCNT0", 0xFF, ""}, {"OCR0A", 0xFF, ""}, {"OCR0B", 0xFF, ""},
    {"TIMSK0", 0x07, ""},

    // --- Timer1 ---
    {"TIMSK1", 0x27, ""},
    {"TCCR1A", 0xF3, ""}, {"TCCR1B", 0xDF, ""},
    {"TCCR1C", 0x00, "FOC1A y FOC1B son de SOLO ESCRITURA, como en el Timer0"},
    {"TCNT1L", 0xFF, ""}, {"TCNT1H", 0xFF, ""},
    {"ICR1L",  0xFF, ""}, {"ICR1H",  0xFF, ""},
    {"OCR1AL", 0xFF, ""}, {"OCR1AH", 0xFF, ""},
    {"OCR1BL", 0xFF, ""}, {"OCR1BH", 0xFF, ""},

    // --- Timer2 ---
    {"TIMSK2", 0x07, ""},
    {"TCCR2A", 0xF3, ""},
    {"TCCR2B", 0x0F, "FOC2A y FOC2B son de SOLO ESCRITURA, como en el Timer0"},
    {"TCNT2", 0xFF, ""}, {"OCR2A", 0xFF, ""}, {"OCR2B", 0xFF, ""},
    {"ASSR",  0x60, "los cinco bits de ocupado -TCN2UB y compania- se leen "
                    "siempre a cero: es la deuda D10, declarada"},

    // --- SPI ---
    // MSTR NO ES ALMACENAMIENTO, y lo dijo este mismo banco: escribir 0xFF lo
    // pedia y el registro devolvia un cero en ese bit. Es la hoja de datos —«if
    // SS is configured as an input and is driven low while MSTR is set, MSTR
    // will be cleared»—, y con el modelo de pad de lazo cerrado un `SS` de
    // entrada se lee a cero. Un maestro cuyo `SS` alguien tira abajo deja de
    // ser maestro EN EL ACTO, que es como se detecta otro maestro en el bus.
    {"SPCR", 0xEF, "MSTR lo LIMPIA EL HARDWARE si SS es entrada y esta a cero: "
                   "es la deteccion de colision de maestros"},
    {"SPSR", 0x01, "SPIF y WCOL los pone el hardware y se limpian con la "
                   "secuencia de dos accesos de la hoja de datos"},
    {"SPDR", 0x00, "no es almacenamiento: escribir arranca una transferencia y "
                   "leer devuelve lo que entro por MISO"},

    // --- TWI ---
    {"TWBR", 0xFF, ""},
    {"TWSR", 0x03, "TWS7..TWS3 son el codigo de estado: los pone el hardware"},
    {"TWAR", 0xFF, ""},
    // TWDR TAMPOCO ES ALMACENAMIENTO LLANO, y tambien lo dijo el banco:
    // escribir un cero lo dejaba en 0xFF. Solo se deja cargar con `TWINT`
    // puesto, y una escritura fuera de tiempo levanta `TWWC` en vez de
    // perderse en silencio. La hoja de datos lo dice al reves de como uno lo
    // esperaria: «note that TWDR cannot be initialized by the user before the
    // first interrupt occurs».
    {"TWDR", 0x00, "solo se deja cargar con TWINT puesto; fuera de tiempo "
                   "levanta TWWC. Su valor de reinicio es 0xFF"},
    {"TWCR", 0x65, "TWINT se limpia con un uno, TWSTO lo baja el hardware al "
                   "terminar el STOP, y TWWC es de solo lectura"},
    {"TWAMR", 0xFE, ""},

    // --- interrupciones externas ---
    {"EIMSK", 0x03, ""}, {"PCICR", 0x07, ""}, {"EICRA", 0x0F, ""},
    {"PCMSK0", 0xFF, ""}, {"PCMSK1", 0x7F, ""}, {"PCMSK2", 0xFF, ""},

    // --- USART ---
    {"UCSR0A", 0x03, "RXC, UDRE, FE, DOR y UPE los pone el hardware; TXC se "
                     "limpia escribiendo un uno"},
    {"UCSR0B", 0xFD, "RXB8 es el noveno bit RECIBIDO: de solo lectura"},
    {"UCSR0C", 0xFF, ""}, {"UBRR0L", 0xFF, ""}, {"UBRR0H", 0x0F, ""},
    {"UDR0", 0x00, "no es almacenamiento: son DOS registros, el bufer de "
                   "transmision al escribir y el de recepcion al leer"},

    // --- EEPROM ---
    {"EECR", 0x38, "EEMPE la lleva su ventana de cuatro ciclos, EEPE lo baja el "
                   "hardware al terminar la grabacion, y EERE es un estrobo"},
    {"EEDR", 0xFF, ""}, {"EEARL", 0xFF, ""}, {"EEARH", 0x03, ""},

    // --- perro guardian ---
    {"WDTCSR", 0x40, "WDIF se limpia con un uno, WDCE la lleva su ventana, y "
                     "WDE y los WDP solo se dejan tocar dentro de ella"},

    // --- comparador analogico ---
    {"ACSR", 0xCF, "ACO es la salida del comparador, de solo lectura, y ACI se "
                   "limpia escribiendo un uno"},
    {"DIDR1", 0x03, ""},

    // --- control de reloj, consumo y sueño ---
    // `SPMEN` lo baja el hardware —a los cuatro ciclos o al terminar de
    // programar—, y `RWWSB` es de solo lectura y aqui vale siempre cero: no hay
    // secciones que puedan estar ocupadas. Ver la deuda D18 para BLBSET y SIGRD,
    // que SI se almacenan pero no hacen nada.
    {"SPMCSR", 0xBE, "SPMEN lo baja el hardware al terminar, y RWWSB es de solo "
                     "lectura: no hay seccion ocupada que señalar"},
    {"SMCR", 0x0F, ""},
    {"MCUSR", 0x00, "banderas de reinicio: las pone el hardware y se limpian "
                    "escribiendo CERO, al reves que el resto del chip"},
    {"MCUCR", 0x70, "IVSEL solo se deja tocar dentro de la ventana de IVCE, y "
                    "IVCE lo baja el hardware"},
    {"CLKPR", 0x00, "CLKPCE lo lleva el hardware y los CLKPS solo se dejan "
                    "tocar dentro de su ventana, con la escritura que la abre "
                    "llevando CLKPCE SOLO"},
    {"PRR", 0xEF, ""},

    // --- ADC ---
    {"ADCL", 0x00, "el resultado de la conversion, de solo lectura"},
    {"ADCH", 0x00, "el resultado de la conversion, de solo lectura"},
    {"ADCSRA", 0xAF, "ADSC lo baja el hardware al terminar y ADIF se limpia "
                     "escribiendo un uno"},
    {"ADCSRB", 0x47, ""}, {"ADMUX", 0xEF, ""}, {"DIDR0", 0x3F, ""},
};
static const int N_CLASES = sizeof(CLASES) / sizeof(CLASES[0]);

static const Clase *clase_de(const char *n) {
    for (int i = 0; i < N_CLASES; i++)
        if (!strcmp(n, CLASES[i].reg)) return &CLASES[i];
    return nullptr;
}

static bool implementado(const char *n) {
    for (int i = 0; i < N_IMPL; i++)
        if (!strcmp(n, IMPLEMENTADOS[i])) return true;
    return false;
}

// Carga un programa que escribe `val` en `dir` y despues la lee, y devuelve lo
// que salio por el bus en esa lectura.
static int escribe_y_lee(uint16_t dir, uint8_t val) {
    std::vector<uint16_t> p;
    // LDI r16, val
    p.push_back(0xE000 | ((val & 0xF0) << 4) | (0 << 4) | (val & 0x0F));
    // STS dir, r16
    p.push_back(0x9200 | (16 << 4));  p.push_back(dir);
    // LDS r17, dir
    p.push_back(0x9000 | (17 << 4));  p.push_back(dir);
    p.push_back(0xCFFF);

    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < p.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = p[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();

    const uint8_t io = (uint8_t)(dir - 0x20);
    int leido = -1;
    for (int c = 0; c < 64; c++) {
        dut->eval();
        if (dut->io_re && dut->io_addr == io) leido = dut->io_rdata;
        tick();
    }
    return leido;
}

// LA TERCERA PASADA: SATURAR Y LEER. Las dos primeras prueban cada registro
// desde un reinicio limpio, y eso esta bien razonado —escribir 0xFF en WDTCSR
// arma el perro y en EECR lanza una grabacion—, pero deja fuera un modo de
// fallo entero: **los bits reservados de un registro alimentados desde OTRO**.
//
// Paso de verdad: el mutante que hacia `EEARH` devolver `{eear[7:2], eear[9:8]}`
// SOBREVIVIA, porque con `EEARL` a cero esos seis bits salian a cero igualmente.
// Aislado, el banco no podia verlo.
//
// Asi que aqui se escribe 0xFF en TODOS los registros implementados y despues
// se leen TODOS, de una sola vez. La afirmacion que se comprueba es mas fuerte
// que la de las otras dos pasadas y no depende del estado: **un bit reservado
// se lee a cero pase lo que pase en el chip**.
static void saturar_y_leer(uint8_t *leido, bool *visto) {
    std::vector<uint16_t> p;
    p.push_back(0xEF0F);                       // LDI r16, 0xFF
    std::vector<uint16_t> dirs;
    for (int i = 0; i < N_REGBITS; i++) {
        if (!implementado(REGBITS[i].nombre)) continue;
        dirs.push_back(REGBITS[i].dato);
        p.push_back(0x9200 | (16 << 4)); p.push_back(REGBITS[i].dato);
    }
    for (uint16_t d : dirs) { p.push_back(0x9000 | (17 << 4)); p.push_back(d); }
    p.push_back(0xCFFF);

    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < p.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = p[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();

    for (long c = 0; c < (long)p.size() * 8 + 64; c++) {
        dut->eval();
        if (dut->io_re) { leido[dut->io_addr] = dut->io_rdata;
                          visto[dut->io_addr] = true; }
        tick();
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_top;

    int vistos = 0;
    printf("  %d registros implementados, escritos con unos y con ceros\n", N_IMPL);

    for (int i = 0; i < N_REGBITS; i++) {
        const RegBits &r = REGBITS[i];
        if (!implementado(r.nombre)) continue;
        vistos++;

        const uint8_t reservados = (uint8_t)~r.existen;

        const int con_unos  = escribe_y_lee(r.dato, 0xFF);
        const int con_ceros = escribe_y_lee(r.dato, 0x00);

        comprobaciones += 2;
        if (con_unos < 0 || con_ceros < 0) {
            printf("    FALLA %-8s no respondio en el bus\n", r.nombre);
            fallos += 2;
            continue;
        }
        // ---- la clase de cada bit que SI existe ----
        const Clase *c = clase_de(r.nombre);
        comprobaciones++;
        if (!c) {
            printf("    FALLA %-8s implementado y sin clasificar\n", r.nombre);
            fallos++;
        } else {
            const uint8_t otros = (uint8_t)(r.existen & ~c->rw);

            // NINGUN BIT SIN EXPLICAR. Si un registro tiene bits que no son
            // almacenamiento llano, hay que haber escrito por que. Es la regla
            // que impide que la tabla se convierta en una lista de mascaras
            // copiadas del RTL hasta que deje de fallar.
            comprobaciones++;
            if (otros && c->motivo[0] == '\0') {
                printf("    FALLA %-8s tiene bits que no son almacenamiento "
                       "(0x%02X) y no dice por que\n", r.nombre, otros);
                fallos++;
            }
            comprobaciones++;
            if (!otros && c->motivo[0] != '\0') {
                printf("    FALLA %-8s da un motivo pero todos sus bits son "
                       "almacenamiento\n", r.nombre);
                fallos++;
            }
            // Un `rw` que se saliera de los bits que existen seria una tabla
            // hablando de un bit que avr-libc no conoce.
            comprobaciones++;
            if (c->rw & ~r.existen) {
                printf("    FALLA %-8s clasifica como almacenamiento bits que "
                       "no existen: 0x%02X\n", r.nombre, c->rw & ~r.existen);
                fallos++;
            }

            // Y LO QUE SE DECLARA ALMACENAMIENTO, QUE LO SEA.
            comprobaciones += 2;
            if ((con_unos & c->rw) != c->rw) {
                printf("    FALLA %-8s declarado almacenamiento pero tras 0xFF "
                       "lee 0x%02X (faltan 0x%02X)\n", r.nombre, con_unos,
                       (uint8_t)(c->rw & ~con_unos));
                fallos++;
            }
            if (con_ceros & c->rw) {
                printf("    FALLA %-8s declarado almacenamiento pero tras 0x00 "
                       "lee 0x%02X (sobran 0x%02X)\n", r.nombre, con_ceros,
                       (uint8_t)(con_ceros & c->rw));
                fallos++;
            }
        }

        if (reservados == 0) continue;     // sin bits reservados, nada que mirar

        if (con_unos & reservados) {
            printf("    FALLA %-8s tras escribir 0xFF, bits reservados a uno: "
                   "0x%02X (reservados 0x%02X)\n",
                   r.nombre, con_unos & reservados, reservados);
            fallos++;
        }
        if (con_ceros & reservados) {
            printf("    FALLA %-8s tras escribir 0x00, bits reservados a uno: "
                   "0x%02X (reservados 0x%02X)\n",
                   r.nombre, con_ceros & reservados, reservados);
            fallos++;
        }
    }

    // Que la lista de arriba y la del generador hablen del mismo chip. Si
    // alguien implementa un registro nuevo y no lo nombra, esto lo dice.
    comprobaciones++;
    if (vistos != N_IMPL) {
        printf("    FALLA se nombran %d registros implementados pero el mapa "
               "generado solo conoce %d\n", N_IMPL, vistos);
        fallos++;
    }

    // ---- tercera pasada: con el espacio entero saturado ----
    {
        static uint8_t leido[256];
        static bool    visto[256];
        saturar_y_leer(leido, visto);
        int mirados = 0;
        for (int i = 0; i < N_REGBITS; i++) {
            const RegBits &r = REGBITS[i];
            if (!implementado(r.nombre)) continue;
            const uint8_t io  = (uint8_t)(r.dato - 0x20);
            const uint8_t res = (uint8_t)~r.existen;
            if (!visto[io]) continue;
            mirados++;
            comprobaciones++;
            if (leido[io] & res) {
                printf("    FALLA %-8s con el espacio saturado, bits reservados "
                       "a uno: 0x%02X\n", r.nombre, leido[io] & res);
                fallos++;
            }
        }
        printf("  y otra vez con los %d registros escritos a 0xFF antes de leer\n",
               mirados);
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
        printf("  Los bits reservados salen de avr-libc, no de una lectura del PDF:\n"
               "  `sim/soc/regbits.h` lo genera `tools/gen_regmap.py`.\n");
        return 1;
    }
    // El recuento, que es lo que se persigue: cuantos bits del espacio de I/O
    // implementado quedan sin decir que son. Tiene que ser cero.
    long total = 0, almacenan = 0, otros = 0, reservados = 0;
    for (int i = 0; i < N_REGBITS; i++) {
        const RegBits &r = REGBITS[i];
        if (!implementado(r.nombre)) continue;
        const Clase *c = clase_de(r.nombre);
        if (!c) continue;
        for (int b = 0; b < 8; b++) {
            total++;
            if (!((r.existen >> b) & 1))      reservados++;
            else if ((c->rw >> b) & 1)        almacenan++;
            else                              otros++;
        }
    }
    printf("  %ld bits en %d registros: %ld de almacenamiento, %ld con "
           "comportamiento propio, %ld reservados\n",
           total, N_IMPL, almacenan, otros, reservados);
    printf("  ningun bit reservado devuelve un uno, y ninguno sin clasificar\n");
    return 0;
}
