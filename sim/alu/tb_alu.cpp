// AxiomaCore-328 - arnés de verificación exhaustiva de la ALU
// SPDX-License-Identifier: Apache-2.0
//
// Enumera el espacio de entrada completo de cada operación y compara la salida
// del RTL contra el banco de vectores que produce sim/alu/alu_ref.py a partir
// del manual del ISA.
//
// El orden de enumeración es contrato con inputs_at() en alu_ref.py.

#include "Vaxioma_alu.h"
#include "verilated.h"

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <string>
#include <vector>

struct __attribute__((packed)) Vec {
    uint8_t  r;
    uint8_t  so;
    uint8_t  sm;
    uint16_t w;
};
static_assert(sizeof(Vec) == 5, "el banco de vectores usa registros de 5 bytes");

struct OpSpec {
    std::string name;
    int         code;
    std::string cls;
    size_t      count;
};

static const int SREG_C = 0, SREG_Z = 1;

static std::vector<Vec> load(const std::string &path, size_t expect) {
    FILE *f = fopen(path.c_str(), "rb");
    if (!f) { fprintf(stderr, "no se puede abrir %s\n", path.c_str()); exit(2); }
    std::vector<Vec> v(expect);
    size_t got = fread(v.data(), sizeof(Vec), expect, f);
    fclose(f);
    if (got != expect) {
        fprintf(stderr, "%s: se esperaban %zu vectores y hay %zu\n",
                path.c_str(), expect, got);
        exit(2);
    }
    return v;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    const std::string dir = (argc > 1) ? argv[1] : "build/alu_vec";

    // ---- leer la especificación de operaciones ----
    std::vector<OpSpec> ops;
    {
        FILE *f = fopen((dir + "/spec.txt").c_str(), "r");
        if (!f) { fprintf(stderr, "falta %s/spec.txt\n", dir.c_str()); return 2; }
        char n[64], c[16]; int code; size_t cnt;
        while (fscanf(f, "%63s %d %15s %zu", n, &code, c, &cnt) == 4)
            ops.push_back({n, code, c, cnt});
        fclose(f);
    }

    Vaxioma_alu *dut = new Vaxioma_alu;
    size_t total = 0, fails = 0;
    int    ops_failed = 0;

    printf("  %-8s %12s   %s\n", "OP", "VECTORES", "RESULTADO");
    printf("  %-8s %12s   %s\n", "--------", "------------", "---------");

    for (const auto &op : ops) {
        std::vector<Vec> exp = load(dir + "/" + op.name + ".bin", op.count);
        size_t bad = 0;
        const bool is_iw  = (op.cls == "iw");
        const bool is_mul = (op.cls == "mul");

        for (size_t i = 0; i < op.count; i++) {
            uint32_t a = 0, b = 0, a16 = 0, k6 = 0, sreg = 0;

            if (op.cls == "2op") {
                uint32_t cz = i >> 16, rem = i & 0xFFFF;
                a = rem >> 8; b = rem & 0xFF; sreg = cz;
            } else if (op.cls == "1op") {
                uint32_t cz = i >> 8;
                a = i & 0xFF; sreg = cz;
            } else if (is_iw) {
                k6 = i >> 16; a16 = i & 0xFFFF;
            } else {                       // mul
                a = i >> 8; b = i & 0xFF;
            }

            dut->op      = op.code;
            dut->a       = a;
            dut->b       = b;
            dut->a16     = a16;
            dut->k6      = k6;
            dut->sreg_in = sreg;
            dut->eval();

            uint32_t got_r    = is_iw || is_mul ? 0 : dut->result;
            uint32_t got_w    = is_iw ? dut->result16 : (is_mul ? dut->mul_result : 0);
            uint32_t got_so   = dut->sreg_out;
            uint32_t got_sm   = dut->sreg_mask;

            const Vec &e = exp[i];
            if (got_r != e.r || got_so != e.so || got_sm != e.sm || got_w != e.w) {
                if (bad < 3) {
                    fprintf(stderr,
                        "\n  FALLO %s  vector %zu   a=%02X b=%02X a16=%04X k6=%02X sreg_in=%02X\n"
                        "    esperado: result=%02X sreg_out=%02X mask=%02X wide=%04X\n"
                        "    obtenido: result=%02X sreg_out=%02X mask=%02X wide=%04X\n",
                        op.name.c_str(), i, a, b, a16, k6, sreg,
                        e.r, e.so, e.sm, e.w,
                        got_r, got_so, got_sm, got_w);
                }
                bad++;
            }
        }

        total += op.count;
        fails += bad;
        if (bad) ops_failed++;
        printf("  %-8s %12zu   %s\n", op.name.c_str(), op.count,
               bad ? ("FALLA (" + std::to_string(bad) + ")").c_str() : "ok");
        fflush(stdout);
    }

    delete dut;

    printf("\n  %zu vectores comprobados en %zu operaciones\n", total, ops.size());
    if (fails) {
        printf("  %zu FALLOS en %d operaciones\n", fails, ops_failed);
        return 1;
    }
    printf("  0 fallos - cobertura exhaustiva del espacio de entrada\n");
    return 0;
}
