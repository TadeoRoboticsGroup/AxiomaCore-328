// AxiomaCore-328 - volcado del decodificador para los 65 536 opcodes
// SPDX-License-Identifier: Apache-2.0
//
// No compara nada: solo vuelca lo que decide el RTL para CADA palabra de 16
// bits posible. La comparación contra avr-objdump la hace compare_decode.py.

#include "Vaxioma_decode.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

struct __attribute__((packed)) Rec {
    uint8_t  op_class, alu_op, rd, rr, flags, imm, ptr, disp, io_addr, bit_num;
    uint16_t rel_addr;
};

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const char *out = (argc > 1) ? argv[1] : "build/decode/rtl.bin";
    FILE *f = fopen(out, "wb");
    if (!f) { fprintf(stderr, "no se puede escribir %s\n", out); return 2; }

    Vaxioma_decode *dut = new Vaxioma_decode;
    for (uint32_t i = 0; i < 65536; i++) {
        dut->insn = i;
        dut->eval();
        Rec r;
        r.op_class = dut->op_class;
        r.alu_op   = dut->alu_op;
        r.rd       = dut->rd;
        r.rr       = dut->rr;
        r.flags    = (dut->rd_we    ? 1 : 0) | (dut->rd_we16  ? 2  : 0)
                   | (dut->use_imm  ? 4 : 0) | (dut->is_32bit ? 8  : 0)
                   | (dut->illegal  ? 16: 0) | (dut->cond_set ? 32 : 0);
        r.imm      = dut->imm;
        r.ptr      = (uint8_t)(dut->ptr_sel | (dut->ptr_mode << 2));
        r.disp     = dut->disp;
        r.io_addr  = dut->io_addr;
        r.bit_num  = dut->bit_num;
        r.rel_addr = dut->rel_addr;
        fwrite(&r, sizeof(r), 1, f);
    }
    fclose(f);
    delete dut;
    printf("  volcados 65536 opcodes en %s\n", out);
    return 0;
}
