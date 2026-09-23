// AxiomaCore-328 - el barrido de direcciones I2C, con un esclavo de verdad
// SPDX-License-Identifier: Apache-2.0
//
// Es la última cláusula del criterio de aceptación de la fase 3: *«el scanner
// I2C detecta un esclavo real»*. Y está elegida con criterio, porque es la
// prueba que más cosas tiene que atravesar a la vez:
//
//   el núcleo ejecutando un bucle con saltos condicionales y espera por bandera;
//   el TWI generando START, dirección, ACK/NACK y STOP **ciento veintisiete
//   veces seguidas**, sin colgarse ni una;
//   los códigos de estado de `TWSR` siendo los de la tabla, porque el programa
//   **decide con ellos**: si 0x18 y 0x20 se confundieran, el barrido diría que
//   hay un esclavo en cada dirección o en ninguna;
//   y los pines como colector abierto de verdad, con el esclavo contestando
//   **tirando de la línea que el maestro acaba de soltar**.
//
// El esclavo es el mismo `EsclavoI2C` que usa el banco del periférico, escrito
// desde la hoja de datos y sin una línea en común con el RTL. Que sea el mismo
// importa: si el barrido usara otro, estaría probando el esclavo nuevo.
//
// Y LA PRUEBA NO ES «ENCUENTRA EL ESCLAVO». Es **encuentra el esclavo Y NO
// ENCUENTRA NADA MÁS**: un TWI que contestara ACK a todo pasaría la primera
// mitad con nota. Las 126 direcciones vacías valen tanto como la que responde.

#include "Vtb_soc_i2c_top.h"
#include "verilated.h"
#include "esclavo_i2c.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static Vtb_soc_i2c_top *dut;
static int fallos = 0;
static int comprobaciones = 0;

static EsclavoI2C esclavo;

static void tick() {
    dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval();
    esclavo.paso(dut->bus_scl, dut->bus_sda);
    dut->esc_sda_pull = esclavo.sda_pull;
    dut->esc_scl_pull = esclavo.scl_pull;
    dut->eval();
}

// ------------------------------------------------------------- ensamblador
static uint16_t LDI(int d, int k) {
    return 0xE000 | ((k & 0xF0) << 4) | (((d - 16) & 0xF) << 4) | (k & 0xF);
}
static uint16_t OUT(int a, int r) {
    return 0xB800 | ((a & 0x30) << 5) | ((r & 0x1F) << 4) | (a & 0x0F);
}
static uint16_t ANDI(int d, int k) {
    return 0x7000 | ((k & 0xF0) << 4) | (((d - 16) & 0xF) << 4) | (k & 0xF);
}
static uint16_t CPI(int d, int k) {
    return 0x3000 | ((k & 0xF0) << 4) | (((d - 16) & 0xF) << 4) | (k & 0xF);
}
static uint16_t SBRS(int r, int b) { return 0xFE00 | ((r & 0x1F) << 4) | (b & 7); }
static uint16_t INC(int d)         { return 0x9403 | ((d & 0x1F) << 4); }
static uint16_t MOV(int d, int r)  {
    return 0x2C00 | ((r & 0x10) << 5) | ((d & 0x10) << 4) | ((d & 0xF) << 4) | (r & 0xF);
}
static uint16_t ADD(int d, int r)  {
    return 0x0C00 | ((r & 0x10) << 5) | ((d & 0x10) << 4) | ((d & 0xF) << 4) | (r & 0xF);
}
static uint16_t RJMP(int delta)    { return 0xC000 | (delta & 0x0FFF); }
static uint16_t BRNE(int delta)    { return 0xF401 | ((delta & 0x7F) << 3); }
static const uint16_t NOP = 0x0000;

enum { IO_DDRB = 0x04, IO_PORTB = 0x05, IO_DDRD = 0x0A, IO_PORTD = 0x0B,
       D_TWBR = 0xB8, D_TWSR = 0xB9, D_TWDR = 0xBB, D_TWCR = 0xBC,
       D_SPL = 0x5D, D_SPH = 0x5E };

struct Prog {
    std::vector<uint16_t> p;
    void w(uint16_t x) { p.push_back(x); }
    void sts(int dir, int r) { w(0x9200 | ((r & 0x1F) << 4)); w((uint16_t)dir); }
    void lds(int r, int dir) { w(0x9000 | ((r & 0x1F) << 4)); w((uint16_t)dir); }
    int  aqui() const { return (int)p.size(); }
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_i2c_top;

    const uint8_t DIRECCION = 0x50;            // la del esclavo, 7 bits
    esclavo.activo = true;
    esclavo.direccion = DIRECCION;
    esclavo.responde = true;

    // -------------------------------------------------- el programa scanner
    // Es el bucle de un sketch de verdad: para cada direccion, START, SLA+W,
    // mirar el codigo de estado y STOP. Ni mas ni menos.
    Prog g;
    g.w(LDI(16, 0xFF)); g.sts(D_SPL, 16);
    g.w(LDI(16, 0x08)); g.sts(D_SPH, 16);
    g.w(LDI(16, 0x7F)); g.w(OUT(IO_DDRB, 16));      // PORTB: la direccion hallada
    g.w(LDI(16, 0x01)); g.w(OUT(IO_DDRD, 16));      // PD0: el estrobo

    g.w(LDI(16, 0x08)); g.sts(D_TWBR, 16);          // SCL = f/(16+2*8) = f/32
    g.w(LDI(20, 0x01));                             // r20 = direccion, de 1 a 127

    const int BUCLE = g.aqui();

    // --- START ---
    g.w(LDI(16, 0xA4)); g.sts(D_TWCR, 16);          // TWINT | TWSTA | TWEN
    const int ESP1 = g.aqui();
    g.lds(16, D_TWCR); g.w(SBRS(16, 7)); g.w(RJMP(ESP1 - g.aqui() - 1));

    // --- SLA + W ---  (la direccion va en los bits 7:1, el bit 0 es R/W)
    g.w(MOV(17, 20)); g.w(ADD(17, 17));             // r17 = r20 << 1
    g.sts(D_TWDR, 17);
    g.w(LDI(16, 0x84)); g.sts(D_TWCR, 16);          // TWINT | TWEN
    const int ESP2 = g.aqui();
    g.lds(16, D_TWCR); g.w(SBRS(16, 7)); g.w(RJMP(ESP2 - g.aqui() - 1));

    // --- el codigo de estado DECIDE ---
    // 0x18 es «SLA+W transmitido y ACK recibido»; 0x20 es el mismo con NACK.
    // El programa no mira el bus: mira TWSR, como haria cualquier biblioteca.
    g.lds(16, D_TWSR); g.w(ANDI(16, 0xF8)); g.w(CPI(16, 0x18));
    const int SALTO = g.aqui();
    g.w(NOP);                                        // BRNE, se rellena luego
    g.w(OUT(IO_PORTB, 20));                          // la direccion encontrada
    g.w(LDI(18, 0x01)); g.w(OUT(IO_PORTD, 18));      // estrobo arriba
    g.w(LDI(18, 0x00)); g.w(OUT(IO_PORTD, 18));      // y abajo
    g.p[SALTO] = BRNE(g.aqui() - SALTO - 1);

    // --- STOP, y esperar a que el hardware lo baje ---
    g.w(LDI(16, 0x94)); g.sts(D_TWCR, 16);          // TWINT | TWSTO | TWEN
    const int ESP3 = g.aqui();
    // `SBRS` salta la SIGUIENTE instruccion si el bit esta puesto, asi que el
    // `RJMP` corto tiene que caer justo detras del `RJMP` de vuelta: delta 1, no
    // 2. Con 2 se salta ademas el `INC` y el barrido se queda dando vueltas en
    // la direccion 1 para siempre, sin dar ningun error.
    g.lds(16, D_TWCR); g.w(SBRS(16, 4)); g.w(RJMP(1));
    g.w(RJMP(ESP3 - g.aqui() - 1));

    // --- siguiente direccion ---
    g.w(INC(20)); g.w(CPI(20, 0x80));
    g.w(BRNE(BUCLE - g.aqui() - 1));
    const int FIN = g.aqui();
    g.w(LDI(18, 0x02)); g.w(OUT(IO_PORTD, 18));     // PD1 arriba: barrido acabado
    g.w(RJMP(-1));
    (void)FIN;

    // -------------------------------------------------- correr
    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0;
    dut->esc_sda_pull = 0; dut->esc_scl_pull = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < g.p.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = g.p[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();

    std::vector<int> encontradas;
    bool acabado = false;
    int ant = 0;
    const long TOPE = 40000000L;
    long c = 0;
    for (; c < TOPE; c++) {
        tick();
        const int pd = dut->pd_out_v;
        if ((pd & 1) && !(ant & 1)) encontradas.push_back(dut->pb_out_v & 0x7F);
        if (pd & 2) { acabado = true; break; }
        ant = pd;
    }

    comprobaciones++;
    if (!acabado) {
        printf("    FALLA el barrido no termino en %ld ciclos (llego a %zu "
               "direcciones)\n", TOPE, encontradas.size());
        fallos++;
    }

    // 1. ENCUENTRA EL ESCLAVO.
    comprobaciones++;
    bool esta = false;
    for (int d : encontradas) if (d == DIRECCION) esta = true;
    if (!esta) {
        printf("    FALLA no encontro el esclavo en 0x%02X\n", DIRECCION);
        fallos++;
    }

    // 2. Y NO ENCUENTRA NADA MAS. Es la mitad que de verdad prueba algo: un
    //    TWI que contestara ACK a todo pasaria la primera con nota.
    comprobaciones++;
    if (encontradas.size() != 1) {
        printf("    FALLA encontro %zu direcciones y solo hay una:", encontradas.size());
        for (size_t i = 0; i < encontradas.size() && i < 12; i++)
            printf(" 0x%02X", encontradas[i]);
        printf("\n");
        fallos++;
    }

    printf("  127 direcciones barridas en %ld ciclos; una sola contesta\n", c);

    // 3. Y SI EL ESCLAVO SE CALLA, NO ENCUENTRA NINGUNA. Sin esto, un barrido
    //    que devolviera siempre «0x50» tambien pasaria.
    esclavo = EsclavoI2C();
    esclavo.activo = true; esclavo.direccion = DIRECCION; esclavo.responde = false;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();

    encontradas.clear(); acabado = false; ant = 0;
    for (long k = 0; k < TOPE; k++) {
        tick();
        const int pd = dut->pd_out_v;
        if ((pd & 1) && !(ant & 1)) encontradas.push_back(dut->pb_out_v & 0x7F);
        if (pd & 2) { acabado = true; break; }
        ant = pd;
    }
    comprobaciones += 2;
    if (!acabado) { printf("    FALLA el segundo barrido no termino\n"); fallos++; }
    if (!encontradas.empty()) {
        printf("    FALLA con el esclavo mudo encontro %zu direcciones\n",
               encontradas.size());
        fallos++;
    } else {
        printf("  y con el esclavo mudo, ninguna\n");
    }

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
    printf("  el barrido de direcciones encuentra al esclavo, y solo a el\n");
    return 0;
}
