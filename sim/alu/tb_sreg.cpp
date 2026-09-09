// AxiomaCore-328 - prueba dirigida del registro de estado
// SPDX-License-Identifier: Apache-2.0
//
// Los valores esperados salen del AVR Instruction Set Manual, no del RTL.

#include "Vaxioma_sreg.h"
#include "verilated.h"
#include <cstdio>
#include <string>
#include <random>

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

    // ======================================================================
    //  Estímulo aleatorio contra modelo sombra
    // ======================================================================
    // Las comprobaciones dirigidas de arriba solo cubren lo que a uno se le
    // ocurrió. Esto barre combinaciones que nadie escribiría a mano, incluidas
    // las de PRIORIDAD entre fuentes simultáneas.
    {
        std::mt19937 rng(20260908);
        auto R = [&](int n) { return (int)(rng() % n); };
        reset();
        int model = 0;
        const int N = 200000;
        for (int i = 0; i < N; i++) {
            int a_we  = R(100) < 45, a_val = R(256), a_mask = R(256);
            int w_en  = R(100) < 12, w_dat = R(256);
            int b_en  = R(100) < 12, b_num = R(8), b_val = R(2);
            int t_en_ = R(100) < 10, t_val = R(2);
            int ie    = R(100) < 6,  ir    = R(100) < 6;

            idle();
            dut->alu_we = a_we; dut->alu_value = a_val; dut->alu_mask = a_mask;
            dut->wr_en = w_en;  dut->wr_data = w_dat;
            dut->bit_en = b_en; dut->bit_num = b_num; dut->bit_val = b_val;
            dut->t_en = t_en_;  dut->t_val = t_val;
            dut->irq_enter = ie; dut->irq_return = ir;
            tick();
            idle();

            // Misma prioridad que documenta el RTL.
            if (ie)            model = (model & ~I) ;
            else if (ir)       model = model | I;
            else if (w_en)     model = w_dat;
            else if (b_en)     model = b_val ? (model | (1 << b_num))
                                             : (model & ~(1 << b_num));
            else if (t_en_)    model = t_val ? (model | T) : (model & ~T);
            else if (a_we)     model = (model & ~a_mask) | (a_val & a_mask);
            model &= 0xFF;

            checks++;
            if (dut->sreg != model) {
                if (++fails <= 6)
                    printf("    FALLA aleatorio i=%d  obtenido %02X esperado %02X\n",
                           i, dut->sreg, model);
            }
        }
        printf("  %d ciclos aleatorios contra modelo sombra\n", N);
    }

    delete dut;
    printf("\n  %d comprobaciones, %d fallos\n", checks, fails);
    if (fails) return 1;
    printf("  0 fallos\n");
    return 0;
}
