// AxiomaCore-328 - el mapa de I/O del SoC, barrido entero
// SPDX-License-Identifier: Apache-2.0
//
// LA INTEGRACIÓN ERA LA ÚNICA PARTE DEL CHIP SIN BANCO PROPIO, y es donde ya
// había aparecido un fallo: un bit de más en la concatenación del mapa de
// vectores convertía TIMER0_COMPA en TIMER1_OVF. Cada periférico estaba
// verificado por su cuenta, pero que estuvieran bien COLOCADOS no lo comprobaba
// nadie.
//
// El espacio de I/O son 224 direcciones —de la 0x20 a la 0xFF del espacio de
// datos—, así que se barre ENTERO en vez de muestrear, como con el fabric del
// bus o con el controlador de interrupciones.
//
// Qué se comprueba, y por qué cada cosa importa:
//
//   1. COLISIONES. Que dos periféricos no reclamen la misma dirección. Es un
//      fallo silencioso: las lecturas se combinan con un OR, así que una
//      colisión devuelve los dos valores mezclados y `io_sel` vale 1 igual. No
//      hay síntoma hasta que un programa lee basura.
//   2. EL MAPA. Que el conjunto de direcciones que reclama cada periférico sea
//      EXACTAMENTE el de la hoja de datos. Una de menos es un registro que no
//      existe; una de más es un registro que responde donde no debe.
//   3. LOS HUECOS. Que una dirección sin implementar se lea como 0x00. En el
//      328P una dirección reservada no es RAM: hasta hace nada, el banco de
//      pruebas tenía un array que fingía que sí, y con él el artefacto
//      verificado y el dispositivo no eran el mismo.
//
// El barrido va POR EL CAMINO REAL: un programa de instrucciones LDS que el
// núcleo ejecuta de verdad. No se fuerza ninguna señal interna.

#include "Vtb_soc_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <map>
#include <set>
#include <string>
#include <vector>

static Vtb_soc_top *dut;
static int fails = 0;
static long checks = 0;

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

// Direcciones del espacio de DATOS que recorre el barrido.
static const uint16_t IO_LO = 0x0020, IO_HI = 0x00FF;

// El núcleo intercepta estas tres antes del bus: su estado vive dentro.
// Nunca llegan a un periférico, y por eso no aparecen en el barrido.
static bool interceptada(uint16_t a) { return a >= 0x005D && a <= 0x005F; }

// EL MAPA ESPERADO, escrito desde la hoja de datos y no desde el RTL. Índice
// de I/O = dirección de dato - 0x20.
struct Esperado { uint8_t io; const char *quien; const char *reg; };
static const Esperado MAPA[] = {
    {0x03, "gpio_b", "PINB"},  {0x04, "gpio_b", "DDRB"},  {0x05, "gpio_b", "PORTB"},
    {0x06, "gpio_c", "PINC"},  {0x07, "gpio_c", "DDRC"},  {0x08, "gpio_c", "PORTC"},
    {0x09, "gpio_d", "PIND"},  {0x0A, "gpio_d", "DDRD"},  {0x0B, "gpio_d", "PORTD"},
    {0x15, "timer0", "TIFR0"},
    {0x1E, "gpior",  "GPIOR0"},
    {0x23, "presc",  "GTCCR"},
    {0x24, "timer0", "TCCR0A"}, {0x25, "timer0", "TCCR0B"}, {0x26, "timer0", "TCNT0"},
    {0x27, "timer0", "OCR0A"},  {0x28, "timer0", "OCR0B"},
    {0x2A, "gpior",  "GPIOR1"}, {0x2B, "gpior",  "GPIOR2"},
    {0x16, "timer1", "TIFR1"},
    {0x4E, "timer0", "TIMSK0"},
    {0x4F, "timer1", "TIMSK1"},
    {0x60, "timer1", "TCCR1A"}, {0x61, "timer1", "TCCR1B"}, {0x62, "timer1", "TCCR1C"},
    {0x64, "timer1", "TCNT1L"}, {0x65, "timer1", "TCNT1H"},
    {0x66, "timer1", "ICR1L"},  {0x67, "timer1", "ICR1H"},
    {0x68, "timer1", "OCR1AL"}, {0x69, "timer1", "OCR1AH"},
    {0x6A, "timer1", "OCR1BL"}, {0x6B, "timer1", "OCR1BH"},
    {0x17, "timer2", "TIFR2"},
    {0x50, "timer2", "TIMSK2"},
    {0x90, "timer2", "TCCR2A"}, {0x91, "timer2", "TCCR2B"}, {0x92, "timer2", "TCNT2"},
    {0x93, "timer2", "OCR2A"},  {0x94, "timer2", "OCR2B"},  {0x96, "timer2", "ASSR"},
    {0x1B, "extint", "PCIFR"},  {0x1C, "extint", "EIFR"},  {0x1D, "extint", "EIMSK"},
    {0x48, "extint", "PCICR"},  {0x49, "extint", "EICRA"},
    {0x4B, "extint", "PCMSK0"}, {0x4C, "extint", "PCMSK1"}, {0x4D, "extint", "PCMSK2"},
    {0xA0, "usart",  "UCSR0A"}, {0xA1, "usart",  "UCSR0B"}, {0xA2, "usart", "UCSR0C"},
    {0xA4, "usart",  "UBRR0L"}, {0xA5, "usart",  "UBRR0H"}, {0xA6, "usart", "UDR0"},
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_top;

    // ---------------------------------------------------------- programa
    // Un LDS por dirección. LDS es de 32 bits: 1001 000d dddd 0000 seguido de
    // la dirección completa. Se usa siempre r16, que no importa: lo que se mira
    // es qué pasa en el bus, no qué se lee.
    std::vector<uint16_t> prog;
    std::vector<uint16_t> orden;              // qué dirección toca cada LDS
    for (uint16_t a = IO_LO; a <= IO_HI; a++) {
        if (interceptada(a)) continue;
        prog.push_back(0x9000 | (16 << 4));   // LDS r16, a
        prog.push_back(a);
        orden.push_back(a);
    }
    prog.push_back(0xCFFF);                   // rjmp .-2, aparcar

    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < prog.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = i; dut->prog_data = prog[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();

    printf("  %zu direcciones de I/O, una instruccion LDS por cada una\n",
           orden.size());

    // ------------------------------------------------------- el barrido
    // Se observa el bus en cada ciclo en el que hay una lectura de I/O.
    std::map<uint8_t, std::set<std::string>> visto;   // io_addr -> quién reclamó
    std::map<uint8_t, uint8_t> leido;
    long colisiones = 0;

    const long CICLOS = (long)prog.size() * 8 + 64;
    for (long c = 0; c < CICLOS; c++) {
        dut->eval();
        if (dut->io_re) {
            uint8_t a = dut->io_addr;
            struct { const char *n; uint8_t v; } quien[] = {
                {"gpio_b", dut->sel_gpio_b}, {"gpio_c", dut->sel_gpio_c},
                {"gpio_d", dut->sel_gpio_d}, {"gpior",  dut->sel_gpior},
                {"presc",  dut->sel_presc},  {"timer0", dut->sel_timer0},
                {"usart",  dut->sel_usart}, {"timer1", dut->sel_timer1},
                {"extint", dut->sel_extint}, {"timer2", dut->sel_timer2},
            };
            int n = 0;
            for (auto &q : quien)
                if (q.v) { visto[a].insert(q.n); n++; }
            checks++;
            if (n > 1) {
                // Dos periféricos en la misma dirección: el OR de lecturas
                // devuelve los dos valores mezclados.
                if (++colisiones <= 8) {
                    printf("    COLISION en la I/O 0x%02X (dato 0x%04X):",
                           a, a + 0x20);
                    for (auto &q : quien) if (q.v) printf(" %s", q.n);
                    printf("\n");
                }
                fails++;
            }
            if (n == 0) visto[a];                  // deja constancia del hueco
            leido[a] = dut->io_rdata;
        }
        tick();
    }

    // ------------------------------------------------- 1. todas visitadas
    for (uint16_t a : orden) {
        uint8_t io = (uint8_t)(a - 0x20);
        checks++;
        if (!visto.count(io)) {
            if (++fails <= 8)
                printf("    la direccion de I/O 0x%02X no llego al bus\n", io);
        }
    }

    // --------------------------------------------- 2. el mapa, exactamente
    std::map<uint8_t, std::string> debe;
    for (const auto &e : MAPA) debe[e.io] = e.quien;

    for (const auto &kv : visto) {
        uint8_t io = kv.first;
        checks++;
        if (debe.count(io)) {
            if (kv.second.size() != 1 || *kv.second.begin() != debe[io]) {
                if (++fails <= 8) {
                    printf("    la I/O 0x%02X deberia ser de %s y responde",
                           io, debe[io].c_str());
                    if (kv.second.empty()) printf(" NADIE");
                    for (const auto &q : kv.second) printf(" %s", q.c_str());
                    printf("\n");
                }
            }
        } else if (!kv.second.empty()) {
            if (++fails <= 8) {
                printf("    la I/O 0x%02X no esta implementada y responde", io);
                for (const auto &q : kv.second) printf(" %s", q.c_str());
                printf("\n");
            }
            fails++;
        }
    }

    // ------------------------------------- 3. los huecos se leen como cero
    long huecos = 0;
    for (const auto &kv : leido) {
        if (debe.count(kv.first)) continue;
        huecos++;
        checks++;
        if (kv.second != 0x00 && ++fails <= 8)
            printf("    la I/O 0x%02X no esta implementada y lee 0x%02X, "
                   "deberia leer 0x00\n", kv.first, kv.second);
    }

    delete dut;

    printf("  %ld comprobaciones · %zu registros implementados · "
           "%ld huecos que leen cero\n", checks, debe.size(), huecos);
    if (fails) {
        printf("  %d fallos. El mapa esperado sale de la hoja de datos, "
               "no del RTL.\n", fails);
        return 1;
    }
    printf("  sin colisiones · el mapa coincide con la hoja de datos\n");
    return 0;
}
