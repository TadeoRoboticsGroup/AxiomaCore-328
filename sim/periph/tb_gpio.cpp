// AxiomaCore-328 - puerto de E/S contra un modelo de referencia
// SPDX-License-Identifier: Apache-2.0
//
// POR QUÉ HACE FALTA ESTE BANCO SI EL DIFERENCIAL YA PASA. Porque hay una
// parte del comportamiento que simavr NO modela y que por tanto el contraste
// contra él no puede verificar:
//
//   - EL SINCRONIZADOR de PINx. El 328P no lleva el pad directamente a PINx.
//     simavr devuelve PORTx al instante, así que si aquí se quitara el
//     sincronizador el diferencial seguiría pasando y el RTL sería MÁS
//     permisivo que el chip: código que funcionara en simulación fallaría en
//     silicio.
//   - EL ENMASCARADO de los bits que no existen (PC7).
//
// Es la estrategia por capas: el diferencial verifica la semántica de los
// registros, y este banco verifica lo que el oráculo no alcanza.
//
// El modelo de referencia está escrito desde la hoja de datos, no desde el RTL.

#include "Vaxioma_gpio.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>
#include <cstdlib>

static Vaxioma_gpio *dut;
static int fails = 0;
static long checks = 0;

static void chk(const char *what, uint32_t got, uint32_t exp, long t) {
    checks++;
    if (got != exp && ++fails <= 8)
        printf("    FALLA %-34s t=%ld  obtenido=%02X esperado=%02X\n",
               what, t, got, exp);
}

// Direcciones de I/O del puerto instanciado (las del puerto B).
static const uint8_t A_PIN = 0x03, A_DDR = 0x04, A_PORT = 0x05;
// Bits implementados del puerto que se está probando. Se pasa por argumento
// porque el puerto C sólo tiene siete y el enmascarado de PC7 no lo verifica
// nadie más: simavr no enmascara, así que el diferencial no puede verlo.
static uint8_t BITS = 0xFF;

// ---------------------------------------------------------------- modelo
struct Model {
    uint8_t ddr = 0, port = 0, sync = 0;

    // El pad, sin nada conectado por fuera: salida se conduce a sí misma,
    // entrada con pull-up lee 1, entrada sin pull-up queda flotando y se
    // modela como 0.
    uint8_t pad() const { return (port & ddr) | ((~ddr & port) & ~ddr); }

    // Un ciclo de reloj. El sincronizador captura el pad ANTES de que la
    // escritura de este ciclo tenga efecto: por eso se calcula primero.
    void tick(bool we, uint8_t addr, uint8_t data) {
        uint8_t nuevo_sync = pad() & BITS;
        if (we) {
            if (addr == A_DDR)  ddr  = data & BITS;
            if (addr == A_PORT) port = data & BITS;
            if (addr == A_PIN)  port = (port ^ data) & BITS;   // trampa nº 5
        }
        sync = nuevo_sync;
    }
    uint8_t read(uint8_t addr) const {
        if (addr == A_PIN)  return sync;
        if (addr == A_DDR)  return ddr;
        if (addr == A_PORT) return port;
        return 0;
    }
};

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc > 1) BITS = (uint8_t)strtol(argv[1], nullptr, 0);
    printf("  Puerto con BITS=0x%02X\n", BITS);
    dut = new Vaxioma_gpio;
    Model m;

    dut->rst_n = 0; dut->clk = 0;
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->pad_in = 0; dut->eval();
    tick();
    dut->rst_n = 1; dut->eval();

    // ---------------- 1. reset ----------------
    for (uint8_t a : {A_PIN, A_DDR, A_PORT}) {
        dut->io_addr = a; dut->io_re = 1; dut->eval();
        chk("tras el reset todo a cero", dut->io_rdata, 0, -1);
    }
    dut->io_re = 0;

    // ---------------- 2. estímulo aleatorio ----------------
    std::mt19937 rng(20260909);
    const long N = 200000;
    for (long t = 0; t < N; t++) {
        const bool we = (rng() % 100) < 45;
        const uint8_t addr = (uint8_t)(rng() % 3 == 0 ? A_PIN
                                     : rng() % 2 == 0 ? A_DDR : A_PORT);
        const uint8_t data = (uint8_t)(rng() & 0xFF);

        // El pad se realimenta como en el SoC: es lo que hace que un pin de
        // salida se lea a sí mismo y uno de entrada con pull-up lea 1.
        dut->pad_in = m.pad();
        dut->io_addr = addr;
        dut->io_we = we; dut->io_re = !we;
        dut->io_wdata = data;
        dut->eval();

        // Las salidas de pad son combinacionales sobre el estado actual.
        chk("pad_out",    dut->pad_out,    m.port,          t);
        chk("pad_oe",     dut->pad_oe,     m.ddr,           t);
        chk("pad_pullup", dut->pad_pullup, (~m.ddr) & m.port & 0xFF, t);
        chk("io_sel",     dut->io_sel,     1,               t);

        // Lectura del ciclo actual, antes del flanco.
        if (!we) chk("io_rdata", dut->io_rdata, m.read(addr), t);

        tick();
        m.tick(we, addr, data);
    }

    // ---------------- 3. el sincronizador, dirigido ----------------
    // Es la comprobación que el diferencial contra simavr NO puede hacer.
    // Se escribe PORTx con todo el puerto como salida y se lee PINx en el
    // ciclo siguiente: tiene que devolver todavía el valor ANTERIOR.
    auto escribir = [&](uint8_t a, uint8_t v) {
        dut->io_addr = a; dut->io_we = 1; dut->io_re = 0; dut->io_wdata = v;
        dut->pad_in = m.pad(); dut->eval();
        tick(); m.tick(true, a, v);
    };
    auto leer = [&](uint8_t a) {
        dut->io_addr = a; dut->io_we = 0; dut->io_re = 1;
        dut->pad_in = m.pad(); dut->eval();
        uint8_t v = dut->io_rdata;
        tick(); m.tick(false, a, 0);
        return v;
    };

    escribir(A_DDR, 0xFF);          // todo salida
    escribir(A_PORT, 0x00);
    (void)leer(A_PIN);              // deja el sincronizador asentado en 0x00
    (void)leer(A_PIN);

    // El valor llega enmascarado: en un puerto de siete bits, PC7 no existe.
    const uint8_t patron = 0xA5 & BITS;
    escribir(A_PORT, 0xA5);         // ciclo N: PORTx pasa al patrón
    uint8_t inmediato = leer(A_PIN);
    checks++;
    if (inmediato == patron) {
        fails++;
        printf("    FALLA sincronizador: PINx devolvió 0x%02X en el ciclo siguiente.\n"
               "          El 328P necesita una instrucción de por medio; sin el\n"
               "          sincronizador el RTL es MÁS permisivo que el chip.\n", patron);
    }
    uint8_t despues = leer(A_PIN);
    chk("PINx tras dejar pasar un ciclo", despues, patron, -2);

    delete dut;
    printf("  Puerto de E/S contra modelo de referencia\n");
    printf("  %ld comprobaciones en %ld ciclos aleatorios, %d fallos\n",
           checks, N, fails);
    if (fails) return 1;
    printf("  0 fallos\n");
    return 0;
}
