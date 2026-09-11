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
//   3. QUE LA VELOCIDAD SEA LA QUE DEBERÍA. Aparte, y contra el baudio nominal:
//      un periférico puede emitir tramas perfectas a una velocidad equivocada,
//      y en el otro extremo del cable eso es basura.
//
// Y el LED: PB5 tiene que conmutar, que es la otra mitad del criterio.

#include "Vtb_soc_uart_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
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
    dut->clk = 0; dut->rst_n = 0; dut->prog_we = 0; dut->eval();
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

    // Medio segundo de parpadeo son F_CPU/2 ciclos; se deja margen para pillar
    // la primera conmutación y algún «tic» detrás.
    const long CICLOS = 8000000;
    for (long c = 0; c < CICLOS; c++) {
        dut->eval();

        // --- el LED ---
        if (dut->portb_oe & 0x20) {
            int pb5 = (dut->portb >> 5) & 1;
            if (pb5_previo >= 0 && pb5 != pb5_previo) conmutaciones++;
            pb5_previo = pb5;
        }

        // --- el pin serie ---
        int linea = dut->txd_en ? dut->txd : 1;
        if (periodo == 0 && dut->dbg_ubrr != 0) {
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

    double baud = F_CPU / (double)periodo;
    double err  = (baud - BAUD_NOMINAL) / BAUD_NOMINAL;
    printf("  velocidad medida: %.0f baudios contra %.0f nominales (%+.2f %%)\n",
           baud, BAUD_NOMINAL, 100.0 * err);
    if (err > TOLERANCIA || err < -TOLERANCIA) {
        printf("  FALLA: fuera de la tolerancia de una trama 8N1\n");
        fails++;
    }

    printf("  el LED conmuto %ld veces\n", conmutaciones);
    if (conmutaciones == 0) {
        printf("  FALLA: PB5 no parpadeo\n");
        fails++;
    }

    if (fails) return 1;
    printf("  Blink y Serial, leidos del pin: criterio de la fase 2 cumplido\n");
    return 0;
}
