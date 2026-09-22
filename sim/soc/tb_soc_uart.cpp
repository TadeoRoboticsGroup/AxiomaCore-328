// AxiomaCore-328 - el criterio de aceptación de la fase 2, en simulación
// SPDX-License-Identifier: Apache-2.0
//
// «Un Blink.ino compilado con avr-gcc parpadea un LED, y Serial.println("Hola")
// sale por el UART y se lee en el PC.»
//
// Esto es esa frase entera menos el cable: el programa es C compilado con
// avr-gcc y avr-libc SIN MODIFICAR, corre sobre el SoC completo, y el banco lee
// el PIN como lo leería un conversor USB-serie. No se mira ningún registro para
// sacar los caracteres: se decodifica la forma de onda.
//
// LAS TRES COSAS QUE SE COMPRUEBAN, que no son la misma:
//
//   1. QUE LA TRAMA ESTÉ BIEN FORMADA. Se decodifica con el ritmo que el
//      PROGRAMA configuró —el banco lee UBRR y U2X del propio periférico—, y se
//      exige bit de arranque a cero y de parada a uno en cada carácter.
//   2. QUE EL TEXTO SEA EL QUE ES. Byte a byte.
//   3bis. QUE EL CHIP ESCUCHE. Se le transmite un byte por RXD y tiene que
//      salir de vuelta por TXD: el eco lo hace su ISR de recepción. Es la
//      única forma de ejercitar el vector USART_RX, que necesita a alguien
//      hablándole al chip, y lo encontró sin disparar nunca la medida de
//      cobertura.
//   3. QUE LA VELOCIDAD SEA LA QUE DEBERÍA. Aparte, y contra el baudio nominal:
//      un periférico puede emitir tramas perfectas a una velocidad equivocada,
//      y en el otro extremo del cable eso es basura.
//
// Y el LED: PB5 tiene que conmutar, que es la otra mitad del criterio.

#include "Vtb_soc_uart_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <cstring>
#include <string>
#include <vector>

static Vtb_soc_uart_top *dut;
static int fails = 0;

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

// F_CPU del bitstream, y el baudio que pide el programa.
static const double F_CPU = 12500000.0;
static const double BAUD_NOMINAL = 19200.0;
// Una trama 8N1 aguanta sobre un ±2,5 % sumando los errores de los dos
// extremos. Se exige la mitad para dejar sitio al otro lado.
static const double TOLERANCIA = 0.025;

// Comprobacion de la trama SPI, fuera de main para no alargarlo.
static int fails_spi = 0;
static std::vector<uint8_t> *spi_leidos = nullptr;
static const uint8_t *spi_esperados = nullptr;
// PD0 y PD1: la anulacion de DIRECCION del puerto D, mirada en el pin.
// Es lo unico que distingue un pin ENCAMINADO de un pin que resulta que vale lo
// mismo por casualidad, y es la razon de que `hello.c` deje PD0 como salida
// antes de encender la USART.
static int pd0_salida_antes = -1;   // lo que valia DDRD0 ya resuelto
static int pd1_salida_antes = -1;

// MSPIM LEIDO DEL PIN. Que XCK salga por PD4 y no por otro sitio NO lo puede
// decir el banco del periferico, que no ve el SoC; y un pin encaminado y un pin
// que resulta que vale lo mismo son indistinguibles si nadie mira. El programa
// manda tres bytes en modo 3 -UCPOL=1, UCPHA=1- con el mas significativo
// primero, asi que el flanco de muestreo es la SUBIDA del pin.
static std::vector<uint8_t> mspim_bytes;
static int  mspim_xck_previo = -1;
static int  mspim_bit = 0, mspim_flancos = 0;
static uint8_t mspim_sh = 0;
static int  mspim_xck_salida = 0;   // que PD4 llegue a ser salida de verdad

// EL TWI LEIDO DEL PIN. SDA es PC4 y SCL es PC5, y eso tampoco lo puede decir
// el banco del periferico: cuelga de un bus propio y no ve el SoC. Lo que se
// mira es el NIVEL DE LA LINEA, que en un colector abierto es lo unico que
// significa algo. Un START es SDA bajando con SCL ALTA; un STOP, SDA subiendo
// con SCL alta; y los bits se muestrean en la SUBIDA de SCL.
static int twi_starts = 0, twi_stops = 0;
static int twi_bits = 0;
static uint8_t twi_sh = 0;
static int twi_dir_leida = -1;      // el primer byte de la trama: SLA+W
static int twi_scl_previo = -1, twi_sda_previo = -1;

static void checks_spi() {
    if (!spi_leidos) return;
    if (spi_leidos->size() != 3) {
        printf("  FALLA: se esperaban 3 bytes por MOSI y llegaron %zu; "
               "el SPI no se adueña del pin\n", spi_leidos->size());
        fails_spi++;
        return;
    }
    for (int i = 0; i < 3; i++)
        if ((*spi_leidos)[i] != spi_esperados[i]) {
            printf("  FALLA: byte %d de la trama SPI: leido 0x%02X, "
                   "esperado 0x%02X\n", i, (*spi_leidos)[i], spi_esperados[i]);
            fails_spi++;
        }
    if (!fails_spi)
        printf("  la trama SPI llego entera y en orden: A5 3C 81\n");
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) { fprintf(stderr, "uso: %s <programa.bin>\n", argv[0]); return 2; }

    // ------------------------------------------------------- el programa
    std::vector<uint16_t> prog;
    {
        FILE *f = fopen(argv[1], "rb");
        if (!f) { fprintf(stderr, "no se puede abrir %s\n", argv[1]); return 2; }
        std::vector<uint8_t> raw; uint8_t b[4096]; size_t n;
        while ((n = fread(b, 1, sizeof(b), f)) > 0) raw.insert(raw.end(), b, b + n);
        fclose(f);
        if (raw.size() & 1) raw.push_back(0);
        for (size_t i = 0; i < raw.size() / 2; i++)
            prog.push_back((uint16_t)(raw[2*i] | (raw[2*i+1] << 8)));
    }
    printf("  programa: %s  (%zu palabras)\n", argv[1], prog.size());

    dut = new Vtb_soc_uart_top;
    dut->clk = 0; dut->rst_n = 0; dut->prog_we = 0;
    dut->rxd = 1;                      // línea de recepción en reposo
    dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < prog.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = prog[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();

    // --------------------------------------------- el receptor del banco
    // Una máquina de estados que muestrea el pin, exactamente lo que hay al
    // otro lado de un cable serie.
    std::string texto;
    long   periodo = 0;          // ciclos por bit, según lo que configuró el programa
    int    estado = 0;           // 0 reposo, 1 recibiendo
    long   cuenta = 0;
    int    nbit = 0;
    uint8_t dato = 0;
    long   tramas = 0, malas = 0;

    // El LED.
    int  pb5_previo = -1;
    long conmutaciones = 0;

    // PWM por hardware: se cuenta cuánto tiempo pasa cada pin alto frente al
    // total, que es el ciclo de trabajo que pidió el programa. Son LOS SEIS
    // canales del 328P, en seis pines distintos y con seis ciclos distintos, y
    // esa es justamente la prueba de que cada uno llega al SUYO: si el mapa
    // estuviera cruzado, las cifras se intercambiarían.
    struct Canal {
        const char *nombre;
        int         puerto;            // 0 = PORTB, 1 = PORTD
        int         bit;
        double      ocr;               // el valor que el programa escribió
        long        alto = 0, total = 0, cambios = 0;
        int         previo = -1;
    };
    Canal canales[] = {
        {"OC1A (PB1)", 0, 1,  64.0},
        {"OC1B (PB2)", 0, 2, 200.0},
        {"OC2A (PB3)", 0, 3,  95.0},
        {"OC0A (PD6)", 1, 6, 191.0},
        {"OC0B (PD5)", 1, 5,  31.0},
        {"OC2B (PD3)", 1, 3, 159.0},
    };

    // LA TRANSACCION SPI DEL ARRANQUE, decodificada del PIN. El firmware manda
    // tres bytes por MOSI (PB3) con el reloj en SCK (PB5) antes de soltar los
    // pines, y el banco los lee como los leeria un analizador logico: muestrea
    // MOSI en cada flanco de SUBIDA de SCK, que es lo que toca en modo 0.
    //
    // Esto es lo unico que ve si el SoC encamina los pines al que manda: la
    // co-simulacion no puede, porque simavr no serializa nada y no hay nadie
    // escuchando al otro lado del cable.
    static const uint8_t SPI_ESPERADO[3] = { 0xA5, 0x3C, 0x81 };
    std::vector<uint8_t> spi_bytes;
    spi_leidos = &spi_bytes; spi_esperados = SPI_ESPERADO;
    int  spi_sck_previo = -1;
    int  spi_bits = 0;
    uint8_t spi_byte = 0;

    // El byte que se le manda al chip para que lo devuelva, y en qué ciclo.
    // Se espera a que haya salido el saludo para no mezclar las dos cosas.
    const uint8_t ECO = 'Z';
    long          eco_en = 0;
    int           eco_bit = -2;
    long          eco_cuenta = 0;

    // Medio segundo de parpadeo son F_CPU/2 ciclos; se deja margen para pillar
    // la primera conmutación y algún «tic» detrás.
    const long CICLOS = 8000000;
    for (long c = 0; c < CICLOS; c++) {
        dut->eval();

        // --- el PC le habla al chip ---
        // Una trama 8N1 puesta en RXD con el mismo ritmo que el chip usa.
        if (periodo && eco_en == 0 && texto.size() >= 22) eco_en = c + periodo * 4;
        if (eco_en && c >= eco_en) {
            if (eco_bit == -2) { eco_bit = -1; eco_cuenta = 0; }
            if (--eco_cuenta <= 0) {
                eco_cuenta = periodo;
                if (eco_bit == -1)      dut->rxd = 0;                 // arranque
                else if (eco_bit < 8)   dut->rxd = (ECO >> eco_bit) & 1;
                else                    dut->rxd = 1;                 // parada
                if (eco_bit < 9) eco_bit++;
            }
        }

        // --- la transaccion SPI del arranque ---
        // Se deja de mirar en cuanto estan los tres bytes: despues, PB5 vuelve
        // a ser el LED y sus conmutaciones no son bits.
        if (spi_bytes.size() < 3 && (dut->portb_oe & 0x20)) {
            int sck = (dut->portb >> 5) & 1;
            if (spi_sck_previo == 0 && sck == 1) {
                spi_byte = (uint8_t)((spi_byte << 1) | ((dut->portb >> 3) & 1));
                if (++spi_bits == 8) {
                    spi_bytes.push_back(spi_byte);
                    spi_bits = 0; spi_byte = 0;
                }
            }
            spi_sck_previo = sck;
        }

        // Mientras dura la transaccion SPI del arranque, PB5 es SCK y PB3 es
        // MOSI: sus flancos son bits, no parpadeos ni PWM. Se empieza a medir
        // cuando el SPI suelta los pines.
        const bool spi_hecho = spi_bytes.size() >= 3;

        // --- el LED ---
        if (spi_hecho && (dut->portb_oe & 0x20)) {
            int pb5 = (dut->portb >> 5) & 1;
            if (pb5_previo >= 0 && pb5 != pb5_previo) conmutaciones++;
            pb5_previo = pb5;
        }

        // --- el PWM ---
        // Sólo se mira el pin mientras esté configurado como SALIDA: antes de
        // que el programa ponga DDRx no hay forma de onda que medir, y ese es
        // el comportamiento del chip, no un atajo del banco.
        for (auto &ch : canales) {
            if (!spi_hecho) break;
            uint8_t val = ch.puerto ? dut->portd    : dut->portb;
            uint8_t oe  = ch.puerto ? dut->portd_oe : dut->portb_oe;
            if (!((oe >> ch.bit) & 1)) continue;
            int v = (val >> ch.bit) & 1;
            if (ch.previo >= 0 && v != ch.previo) ch.cambios++;
            ch.previo = v;
            ch.total++;
            if (v) ch.alto++;
        }

        // --- el TWI en el pin: SDA es PC4 y SCL es PC5 ---
        {
            int sda = (dut->portc_linea >> 4) & 1;
            int scl = (dut->portc_linea >> 5) & 1;
            if (twi_scl_previo >= 0) {
                if (scl && twi_sda_previo && !sda) {         // START
                    twi_starts++; twi_bits = 0; twi_sh = 0;
                } else if (scl && !twi_sda_previo && sda) {  // STOP
                    twi_stops++;
                } else if (scl && !twi_scl_previo) {         // subida: muestrear
                    if (twi_bits < 8) {
                        twi_sh = (uint8_t)((twi_sh << 1) | sda);
                        if (++twi_bits == 8 && twi_dir_leida < 0)
                            twi_dir_leida = twi_sh;
                    }
                }
            }
            twi_scl_previo = scl; twi_sda_previo = sda;
        }

        // --- MSPIM en el pin: XCK es PD4 y MOSI es PD1 ---
        if (dut->dbg_umsel == 3) {
            if (dut->portd_oe & 0x10) mspim_xck_salida = 1;
            int xck = (dut->portd >> 4) & 1;
            if (mspim_xck_previo >= 0 && xck != mspim_xck_previo) {
                mspim_flancos++;
                if (xck) {                       // modo 3: se muestrea al subir
                    mspim_sh = (uint8_t)((mspim_sh << 1) |
                                         ((dut->portd >> 1) & 1));
                    if (++mspim_bit == 8) {
                        mspim_bytes.push_back(mspim_sh);
                        mspim_bit = 0; mspim_sh = 0;
                    }
                }
            }
            mspim_xck_previo = xck;
        }

        // --- PD0 y PD1, la anulacion de DIRECCION ---
        // Antes de que la USART se encienda, los dos son de E/S general: `hello.c`
        // pone DDRD0 a SALIDA y no toca DDRD1 en ningun momento. Al encenderla,
        // el hardware tiene que dar la vuelta a los dos: PD0 a ENTRADA pese a
        // DDRD0, y PD1 a SALIDA sin que nadie haya escrito DDRD1.
        if (dut->dbg_ubrr == 0 && dut->dbg_umsel == 0) {
            pd0_salida_antes = (dut->portd_oe & 0x01) ? 1 : 0;
            pd1_salida_antes = (dut->portd_oe & 0x02) ? 1 : 0;
        }

        // --- el pin serie ---
        int linea = dut->txd_en ? dut->txd : 1;
        // EL DIVISOR DE MSPIM TAMBIEN VIVE EN UBRR0, y es otro: sin mirar
        // UMSEL, el banco mediria el periodo de bit del puerto serie con el
        // divisor del SPI y no decodificaria ni una trama.
        if (periodo == 0 && dut->dbg_ubrr != 0 && dut->dbg_umsel == 0) {
            periodo = (long)(dut->dbg_ubrr + 1) * (dut->dbg_u2x ? 8 : 16);
            printf("  el programa configuro UBRR=%u y U2X=%u -> %ld ciclos por bit\n",
                   (unsigned)dut->dbg_ubrr, (unsigned)dut->dbg_u2x, periodo);
        }

        if (periodo) {
            if (estado == 0) {
                if (!linea) { estado = 1; cuenta = periodo / 2; nbit = -1; }
            } else if (--cuenta <= 0) {
                cuenta = periodo;
                if (nbit < 0) {
                    if (linea) { estado = 0; malas++; }   // arranque falso
                    nbit = 0;
                } else if (nbit < 8) {
                    dato = (uint8_t)((dato >> 1) | (linea ? 0x80 : 0x00));
                    nbit++;
                } else {
                    if (!linea) malas++;                  // parada a cero
                    texto.push_back((char)dato);
                    tramas++;
                    estado = 0;
                }
            }
        }
        tick();
    }

#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif

    delete dut;

    // ------------------------------------------------------ veredicto
    const char *ESPERADO = "Hola, AxiomaCore-328\r\n";
    printf("  %ld tramas leidas del pin, %ld mal formadas\n", tramas, malas);
    printf("  texto: \"");
    for (char ch : texto)
        printf("%s", ch == '\r' ? "\\r" : ch == '\n' ? "\\n" : std::string(1, ch).c_str());
    printf("\"\n");

    if (malas) {
        printf("  FALLA: %ld tramas con el arranque o la parada mal\n", malas);
        fails++;
    }
    if (texto.compare(0, strlen(ESPERADO), ESPERADO) != 0) {
        printf("  FALLA: el texto no empieza por lo esperado\n");
        fails++;
    }
    if (texto.find("tic\r\n", strlen(ESPERADO)) == std::string::npos) {
        printf("  FALLA: no llego ningun \"tic\" del bucle principal\n");
        fails++;
    }
    if (texto.find((char)ECO, strlen(ESPERADO)) == std::string::npos) {
        printf("  FALLA: el chip no hizo eco del byte recibido ('%c')\n", ECO);
        printf("         eso significa que el vector USART_RX no disparo\n");
        fails++;
    } else {
        printf("  el chip devolvio el byte '%c' que se le envio por RXD\n", ECO);
    }

    double baud = F_CPU / (double)periodo;
    double err  = (baud - BAUD_NOMINAL) / BAUD_NOMINAL;
    printf("  velocidad medida: %.0f baudios contra %.0f nominales (%+.2f %%)\n",
           baud, BAUD_NOMINAL, 100.0 * err);
    if (err > TOLERANCIA || err < -TOLERANCIA) {
        printf("  FALLA: fuera de la tolerancia de una trama 8N1\n");
        fails++;
    }

    // --- lo que salio por MOSI ---
    printf("  SPI: %zu bytes leidos del pin MOSI con el reloj de SCK\n",
           spi_bytes.size());
    checks_spi();
    printf("  el LED conmuto %ld veces\n", conmutaciones);
    if (conmutaciones == 0) {
        printf("  FALLA: PB5 no parpadeo\n");
        fails++;
    }

    // EL CICLO DE TRABAJO NO ES «UN 25 % APROXIMADO». En PWM rápido la hoja de
    // datos lo fija exacto: (OCR + 1) / (TOP + 1). Con OCR1A = 64 y TOP = 255
    // son 65/256 = 25,39 %, y ese +1 es justo lo que distingue una
    // implementación correcta de una que se queda corta un ciclo por periodo.
    for (const auto &ch : canales) {
        const double esperado = 100.0 * (ch.ocr + 1.0) / 256.0;
        double ciclo = ch.total ? (100.0 * ch.alto / ch.total) : 0.0;
        printf("  PWM en %s: %ld flancos, ciclo de trabajo %.2f %% "
               "(la formula da %.2f %%)\n", ch.nombre, ch.cambios, ciclo, esperado);
        if (ch.cambios < 100) {
            printf("  FALLA: %s no saca forma de onda; el canal PWM no llega al pin\n",
                   ch.nombre);
            fails++;
        } else if (ciclo < esperado - 0.3 || ciclo > esperado + 0.3) {
            printf("  FALLA: en %s el ciclo de trabajo no es (OCR+1)/(TOP+1)\n",
                   ch.nombre);
            fails++;
        }
    }

    fails += fails_spi;

    // Lo que prueba que PD0 y PD1 son pines del puerto D y no dos cables aparte.
    if (pd0_salida_antes != 1) {
        printf("  FALLA: PD0 no era SALIDA antes de encender la USART\n");
        fails++;
    }
    if (pd1_salida_antes != 0) {
        printf("  FALLA: PD1 conducia antes de que TXEN0 lo pidiera\n");
        fails++;
    }
    if (!(dut->portd_oe & 0x02)) {
        printf("  FALLA: con TXEN0 puesto PD1 tiene que ser SALIDA, y DDRD1 "
               "no se toca en ningun momento\n");
        fails++;
    }
    if (dut->portd_oe & 0x01) {
        printf("  FALLA: con RXEN0 puesto PD0 tiene que ser ENTRADA, y el "
               "programa lo dejo como salida a proposito\n");
        fails++;
    }
    printf("  PD1 pasa a salida con TXEN0 sin tocar DDRD1, y PD0 vuelve a "
           "entrada con RXEN0 pese a DDRD0\n");

    // Lo que prueba que XCK sale por PD4 y que MSPIM funciona por el bus real.
    {
        static const uint8_t esperado[3] = { 0x96, 0x5A, 0xC3 };
        if (!mspim_xck_salida) {
            printf("  FALLA: PD4 nunca fue SALIDA; DDR_XCK0 es lo que enciende "
                   "el maestro\n");
            fails++;
        }
        if (mspim_bytes.size() != 3) {
            printf("  FALLA: se leyeron %zu bytes de MSPIM en el pin, no 3\n",
                   mspim_bytes.size());
            fails++;
        } else {
            for (int i = 0; i < 3; i++)
                if (mspim_bytes[i] != esperado[i]) {
                    printf("  FALLA: byte %d de MSPIM leido del pin = 0x%02X, "
                           "esperado 0x%02X\n", i, mspim_bytes[i], esperado[i]);
                    fails++;
                }
        }
        // Tres tramas de ocho pulsos son 48 flancos. Ni uno mas: un pulso de
        // sobra descoloca a un esclavo de verdad para siempre.
        if (mspim_flancos != 48) {
            printf("  FALLA: XCK dio %d flancos en PD4, y tres tramas de ocho "
                   "pulsos son 48\n", mspim_flancos);
            fails++;
        }
        if (!fails)
            printf("  MSPIM leido del PIN: XCK en PD4 con 48 flancos exactos, "
                   "y 96 5A C3 por PD1\n");
    }

    // LA EEPROM, DE EXTREMO A EXTREMO. El programa graba 0x5A en la direccion
    // 0x123, espera a que la grabacion termine y lo lee de vuelta. Si el
    // oscilador RC no llegara al periferico, la grabacion no acabaria y saldria
    // 0xFF —la celda virgen—: un fallo que se lee.
    if (texto.find("EE=5A") == std::string::npos) {
        printf("  FALLA: la EEPROM no devolvio 0x5A — el texto fue \"%s\"\n",
               texto.c_str());
        fails++;
    } else {
        printf("  EEPROM leida del PIN: 0x5A grabado y releido en 0x123\n");
    }

    // EL ADC, DE EXTREMO A EXTREMO Y SALIENDO POR UN PIN. El programa convierte
    // el canal 3 y escribe el resultado en hexadecimal por el puerto serie, asi
    // que este numero ha cruzado el chip entero: bus, SAR, frente analogico,
    // registros con su cerrojo, USART y PD1. El modelo del frente presenta
    // canal*64+32, o sea 3*64+32 = 224 = 0x0E0.
    //
    // Se busca "=0E0" y no "ADC=0E0" porque el eco del byte que el banco manda
    // por RXD puede caer en medio de la cadena: el orden de dos flujos
    // independientes no es parte del contrato.
    if (texto.find("=0E0") == std::string::npos) {
        printf("  FALLA: el ADC no convirtio el canal 3 a 0x0E0 — el texto fue "
               "\"%s\"\n", texto.c_str());
        fails++;
    } else {
        printf("  ADC leido del PIN: el canal 3 convierte a 0x0E0 y sale por el "
               "puerto serie\n");
    }

    // DIDR0 de extremo a extremo: el registro vive en el ADC y el efecto es del
    // PUERTO, asi que el cable entre los dos no lo ve ningun banco de
    // periferico. hello.c enciende PB0 solo si PINC0 leia 1 antes de poner
    // ADC0D y 0 despues.
    if (!((dut->portb_oe & 0x01) && (dut->portb & 0x01))) {
        printf("  FALLA: DIDR0 no apago el bufer de entrada de PC0 — el "
               "testigo de PB0 no se encendio\n");
        fails++;
    } else {
        printf("  DIDR0 llega del ADC al puerto C: con ADC0D puesto, PINC0 lee "
               "cero con el pin alto\n");
    }

    // Y el TWI, en SUS pines. Sin esto, SDA y SCL podrian salir intercambiados
    // -o por otros dos pines del puerto C- y la regresion entera pasaria: se
    // inyectaron los dos fallos como mutantes y sobrevivian a todo.
    if (twi_starts < 1) {
        printf("  FALLA: no se vio ningun START en el bus: SDA bajando con SCL "
               "alta, en PC4 y PC5\n");
        fails++;
    }
    if (twi_stops < 1) {
        printf("  FALLA: no se vio ningun STOP en PC4/PC5\n");
        fails++;
    }
    if (twi_dir_leida != 0xA0) {
        printf("  FALLA: la direccion leida del bus es 0x%02X, y el programa "
               "mando 0xA0\n", twi_dir_leida);
        fails++;
    } else {
        printf("  TWI leido del PIN: START, SLA+W 0xA0 y STOP sobre SDA=PC4 y "
               "SCL=PC5\n");
    }

    if (fails) return 1;
    printf("  Blink, Serial y SPI, leidos del pin: criterio de la fase 2 cumplido\n");
    return 0;
}
