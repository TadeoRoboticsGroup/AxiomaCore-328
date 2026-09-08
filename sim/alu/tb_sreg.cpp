// AxiomaCore-328 - prueba dirigida del registro de estado
// SPDX-License-Identifier: Apache-2.0
//
// Los valores esperados salen del AVR Instruction Set Manual, no del RTL.

#include "Vaxioma_sreg.h"
#include "verilated.h"
#include <cstdio>
#include <string>

static Vaxioma_sreg *dut;
static int fails = 0, checks = 0;

static void tick() {
    dut->clk = 0; dut->eval();
    dut->clk = 1; dut->eval();
}

static void idle() {
    dut->alu_we = dut->wr_en = dut->bit_en = dut->t_en = 0;
    dut->irq_enter = dut->irq_return = 0;
    dut->alu_value = dut->alu_mask = dut->wr_data = 0;
    dut->bit_num = dut->bit_val = dut->t_val = 0;
}

static void check(const std::string &what, int expect) {
    checks++;
    if (dut->sreg != expect) {
        fails++;
        printf("    FALLA  %-46s esperado %02X  obtenido %02X\n",
               what.c_str(), expect, dut->sreg);
    }
}

static void reset() {
    idle(); dut->rst_n = 0; tick(); tick(); dut->rst_n = 1;
}

// Escribe los 8 bits del SREG de golpe (equivale a OUT SREG,Rr)
static void set_sreg(int v) { idle(); dut->wr_en = 1; dut->wr_data = v; tick(); idle(); }

static void alu(int value, int mask) {
    idle(); dut->alu_we = 1; dut->alu_value = value; dut->alu_mask = mask; tick(); idle();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_sreg;

    const int C=1<<0, Z=1<<1, N=1<<2, V=1<<3, S=1<<4, H=1<<5, T=1<<6, I=1<<7;
    const int M_SVNZ   = S|V|N|Z;
    const int M_SVNZC  = M_SVNZ|C;
    const int M_HSVNZC = M_SVNZC|H;

    printf("  Prueba dirigida del SREG\n");

    reset();
    check("reset deja el SREG a cero", 0x00);

    // --- escritura directa ---
    set_sreg(0xFF);  check("OUT SREG,Rr escribe los 8 bits", 0xFF);
    set_sreg(0x00);  check("OUT SREG,Rr borra los 8 bits", 0x00);

    // --- BSET / BCLR, una por bit (SEC, SEZ, ... CLI) ---
    const char *bn[8] = {"SEC/CLC","SEZ/CLZ","SEN/CLN","SEV/CLV",
                         "SES/CLS","SEH/CLH","SET/CLT","SEI/CLI"};
    for (int b = 0; b < 8; b++) {
        set_sreg(0x00);
        idle(); dut->bit_en = 1; dut->bit_num = b; dut->bit_val = 1; tick(); idle();
        check(std::string(bn[b]) + ": pone el bit " + std::to_string(b), 1 << b);
        idle(); dut->bit_en = 1; dut->bit_num = b; dut->bit_val = 0; tick(); idle();
        check(std::string(bn[b]) + ": limpia el bit " + std::to_string(b), 0);
    }

    // --- máscara de la ALU: lo que la operación NO escribe se conserva ---
    set_sreg(C|H|T|I);                       // C, H, T e I puestos
    alu(0x00, M_SVNZ);                       // INC/DEC no tocan C ni H
    check("INC no toca C ni H (mascara S V N Z)", C|H|T|I);

    set_sreg(C|H|T|I);
    alu(0x00, M_HSVNZC);                     // ADD escribe H S V N Z C
    check("ADD si limpia C y H", T|I);

    set_sreg(0x00);
    alu(N|S, M_SVNZ);
    check("ALU escribe N y S", N|S);

    set_sreg(0xFF);
    alu(0x00, 0x00);                         // SWAP y MOV: mascara vacia
    check("mascara vacia (SWAP, MOV) no cambia nada", 0xFF);

    // --- BST escribe T sin tocar el resto ---
    set_sreg(0x00);
    idle(); dut->t_en = 1; dut->t_val = 1; tick(); idle();
    check("BST pone T", T);
    set_sreg(0xFF);
    idle(); dut->t_en = 1; dut->t_val = 0; tick(); idle();
    check("BST limpia T sin tocar el resto", 0xFF & ~T);

    // --- interrupciones ---
    set_sreg(0xFF);
    idle(); dut->irq_enter = 1; tick(); idle();
    check("entrar en ISR limpia I y conserva el resto", 0xFF & ~I);
    idle(); dut->irq_return = 1; tick(); idle();
    check("RETI pone I", 0xFF);

    // --- prioridad: la entrada a ISR gana a la ALU ---
    set_sreg(0xFF);
    idle(); dut->irq_enter = 1; dut->alu_we = 1; dut->alu_value = 0x00;
    dut->alu_mask = M_HSVNZC; tick(); idle();
    check("la entrada a ISR tiene prioridad sobre la ALU", 0xFF & ~I);

    // --- reset asincrono en cualquier estado ---
    set_sreg(0xFF);
    reset();
    check("el reset asincrono vuelve a poner el SREG a cero", 0x00);

    delete dut;
    printf("\n  %d comprobaciones, %d fallos\n", checks, fails);
    if (fails) return 1;
    printf("  0 fallos\n");
    return 0;
}
