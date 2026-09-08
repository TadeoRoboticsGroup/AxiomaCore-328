// AxiomaCore-328 - tercer oráculo: simavr
// SPDX-License-Identifier: Apache-2.0
//
// El modelo de referencia de sim/alu/alu_ref.py y el RTL de rtl/core/axioma_alu.v
// los escribió la misma persona leyendo el mismo manual. Que coincidan demuestra
// que no hay erratas de transcripción, pero NO descarta un error conceptual
// cometido dos veces.
//
// Este programa ejecuta las instrucciones AVR REALES sobre simavr, una
// implementación independiente y de terceros, y vuelca el estado resultante.
// sim/alu/compare_simavr.py lo contrasta con nuestro modelo.
//
// Recorre la misma enumeración que inputs_at() en alu_ref.py, y escribe también
// las entradas para que el comparador pueda verificar que ambos recorren lo
// mismo.

#include "sim_avr.h"
#include "sim_core.h"
#include "sim_elf.h"

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#define RD   16           // registro destino
#define RR   17           // registro fuente
#define RDW  24           // par R25:R24 para ADIW y SBIW

struct __attribute__((packed)) Rec {
    uint8_t  a, b, sreg_in, k6;
    uint16_t a16;
    uint8_t  result, sreg_out;
    uint16_t wide;
};

// --- codificadores de instrucción, del manual del ISA ---
static uint16_t enc_2op(uint16_t base, int d, int r) {
    return base | ((r & 0x10) << 5) | ((d & 0x1F) << 4) | (r & 0x0F);
}
static uint16_t enc_1op(int d, int suffix) {
    return 0x9400 | ((d & 0x1F) << 4) | (suffix & 0x0F);
}
static uint16_t enc_iw(uint16_t base, int dd, int k) {
    return base | ((k & 0x30) << 2) | ((dd & 3) << 4) | (k & 0x0F);
}

// Barrido de sreg_in. Debe coincidir EXACTAMENTE con SREG_SET_* de
// sim/alu/alu_ref.py. No basta con recorrer C y Z: hace falta entrar con H, T
// e I puestos para verificar que las operaciones que no deben tocarlos los
// conservan.
static const uint8_t SREG_SET_2OP[] = {0x00,0x01,0x02,0x03, 0xE0,0xE1,0xE2,0xE3};
static const uint8_t SREG_SET_IW[]  = {0x00, 0xFF};
static const uint8_t SREG_SET_MUL[] = {0x00, 0xFF};
#define N_2OP (sizeof(SREG_SET_2OP)/sizeof(SREG_SET_2OP[0]))
#define N_IW  (sizeof(SREG_SET_IW)/sizeof(SREG_SET_IW[0]))
#define N_MUL (sizeof(SREG_SET_MUL)/sizeof(SREG_SET_MUL[0]))

typedef enum { C2OP, C1OP, CIW, CMUL } cls_t;

struct OpDef { const char *name; cls_t cls; uint16_t base; int suffix; };

static const struct OpDef OPS[] = {
    {"ADD",   C2OP, 0x0C00, 0}, {"ADC",   C2OP, 0x1C00, 0},
    {"SUB",   C2OP, 0x1800, 0}, {"SBC",   C2OP, 0x0800, 0},
    {"AND",   C2OP, 0x2000, 0}, {"OR",    C2OP, 0x2800, 0},
    {"EOR",   C2OP, 0x2400, 0}, {"MOV",   C2OP, 0x2C00, 0},
    {"COM",   C1OP, 0, 0x0},    {"NEG",   C1OP, 0, 0x1},
    {"INC",   C1OP, 0, 0x3},    {"DEC",   C1OP, 0, 0xA},
    {"LSR",   C1OP, 0, 0x6},    {"ROR",   C1OP, 0, 0x7},
    {"ASR",   C1OP, 0, 0x5},    {"SWAP",  C1OP, 0, 0x2},
    {"ADIW",  CIW,  0x9600, 0}, {"SBIW",  CIW,  0x9700, 0},
    {"MUL",   CMUL, 0x9C00, 0}, {"MULS",  CMUL, 0x0200, 0},
    {"MULSU", CMUL, 0x0300, 0}, {"FMUL",  CMUL, 0x0308, 0},
    {"FMULS", CMUL, 0x0380, 0}, {"FMULSU",CMUL, 0x0388, 0},
};
static const int NOPS = sizeof(OPS) / sizeof(OPS[0]);

static size_t count_of(cls_t c) {
    switch (c) {
        case C2OP: return (size_t)N_2OP * 256 * 256;
        case C1OP: return 256u * 256;
        case CIW:  return (size_t)N_IW * 64 * 65536;
        default:   return (size_t)N_MUL * 256 * 256;
    }
}

int main(int argc, char **argv) {
    if (argc < 3) {
        fprintf(stderr, "uso: %s <dir-salida> <stride>\n", argv[0]);
        return 2;
    }
    const char *outdir = argv[1];
    const size_t stride = (size_t)atol(argv[2]);

    avr_t *avr = avr_make_mcu_by_name("atmega328p");
    if (!avr) { fprintf(stderr, "simavr no conoce atmega328p\n"); return 2; }
    avr_init(avr);
    avr->frequency = 16000000;

    for (int oi = 0; oi < NOPS; oi++) {
        const struct OpDef *op = &OPS[oi];
        const size_t total = count_of(op->cls);

        char path[512];
        snprintf(path, sizeof(path), "%s/%s.simavr", outdir, op->name);
        FILE *f = fopen(path, "wb");
        if (!f) { fprintf(stderr, "no se puede escribir %s\n", path); return 2; }

        size_t emitted = 0;
        for (size_t i = 0; i < total; i += stride) {
            uint32_t a = 0, b = 0, a16 = 0, k6 = 0, sreg = 0;
            switch (op->cls) {
                case C2OP: { uint32_t si = i >> 16, rem = i & 0xFFFF;
                             a = rem >> 8; b = rem & 0xFF;
                             sreg = SREG_SET_2OP[si]; } break;
                case C1OP: { sreg = (i >> 8) & 0xFF; a = i & 0xFF; } break;
                case CIW:  { uint32_t si = i >> 22, rem = i & 0x3FFFFF;
                             k6 = rem >> 16; a16 = rem & 0xFFFF;
                             sreg = SREG_SET_IW[si]; } break;
                default:   { uint32_t si = i >> 16, rem = i & 0xFFFF;
                             a = rem >> 8; b = rem & 0xFF;
                             sreg = SREG_SET_MUL[si]; } break;
            }

            // --- codificar la instrucción ---
            uint16_t insn;
            int d = RD, r = RR;
            switch (op->cls) {
                case C2OP: insn = enc_2op(op->base, d, r); break;
                case C1OP: insn = enc_1op(d, op->suffix); break;
                case CIW:  insn = enc_iw(op->base, (RDW - 24) / 2, k6); break;
                default:
                    if (!strcmp(op->name, "MUL"))
                        insn = enc_2op(op->base, d, r);
                    else if (!strcmp(op->name, "MULS"))
                        insn = op->base | ((d - 16) << 4) | (r - 16);
                    else
                        insn = op->base | ((d - 16) << 4) | (r - 16);
                    break;
            }

            // --- preparar el estado ---
            avr->flash[0] = insn & 0xFF;
            avr->flash[1] = insn >> 8;
            avr->flash[2] = 0x00;                 // NOP de relleno
            avr->flash[3] = 0x00;
            avr->pc = 0;
            avr->state = cpu_Running;

            avr->data[RD] = a;
            avr->data[RR] = b;
            avr->data[RDW] = a16 & 0xFF;
            avr->data[RDW + 1] = a16 >> 8;
            avr->data[0] = 0; avr->data[1] = 0;   // R1:R0 para las multiplicaciones
            for (int s = 0; s < 8; s++) avr->sreg[s] = (sreg >> s) & 1;

            avr_run_one(avr);

            uint8_t sr = 0;
            for (int s = 0; s < 8; s++) sr |= (avr->sreg[s] & 1) << s;

            struct Rec rec;
            rec.a = a; rec.b = b; rec.sreg_in = sreg; rec.k6 = k6;
            rec.a16 = a16;
            rec.sreg_out = sr;
            if (op->cls == CIW) {
                rec.result = 0;
                rec.wide = avr->data[RDW] | (avr->data[RDW + 1] << 8);
            } else if (op->cls == CMUL) {
                rec.result = 0;
                rec.wide = avr->data[0] | (avr->data[1] << 8);
            } else {
                rec.result = avr->data[RD];
                rec.wide = 0;
            }
            fwrite(&rec, sizeof(rec), 1, f);
            emitted++;
        }
        fclose(f);
        printf("  %-8s %10zu casos\n", op->name, emitted);
        fflush(stdout);
    }
    return 0;
}
