// AxiomaCore-328 - co-simulación diferencial contra simavr
// SPDX-License-Identifier: Apache-2.0
//
// Ejecuta el MISMO programa en el RTL y en simavr, y compara el estado tras
// CADA instrucción retirada: PC, R0-R31, SREG y SP. A la primera divergencia
// imprime la instrucción, el estado esperado y el obtenido, y para.
//
// Es la pieza que convierte la depuración del núcleo de días en minutos: en
// vez de mirar ondas buscando dónde se torció algo, el arnés señala la
// instrucción exacta.
//
// simavr es una implementación independiente y de terceros del núcleo AVR.
// `avr_run_one()` ejecuta UNA instrucción completa y DEVUELVE el PC nuevo; el
// llamante tiene que asignarlo.
//
// LÍMITE CONOCIDO: en la fase 1 no hay periféricos y el espacio de I/O del RTL
// es memoria plana, mientras que simavr sí los modela. Los programas de prueba
// deben evitar los periféricos. SPL, SPH y SREG sí están soportados.
//
// CAPA 3 - EXACTITUD DE CICLOS (contrato L3).
// Además del estado, se comprueba CUÁNTOS CICLOS tarda cada instrucción. El
// oráculo es la tabla del manual del ISA, transcrita en docs/01-arquitectura.md
// y proyectada sobre los 65 536 opcodes por sim/perf/cycles_ref.py, que usa el
// mnemónico de avr-objdump para identificar cada codificación.
//
// Los ciclos de simavr (`avr->cycle`) se leen también, pero NO como oráculo: el
// propio comentario de `avr_run_one` en sim_core.c avisa de que su cuenta
// "might not be entirely accurate". Se contrastan y las discrepancias se
// informan aparte, para adjudicarlas a mano contra el manual.

#include "Vaxioma_sim_top.h"
#include "verilated.h"

extern "C" {
#include "sim_avr.h"
#include "sim_core.h"
}

#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <map>
#include <string>
#include <vector>

static Vaxioma_sim_top *rtl;
static avr_t *avr;

static const uint16_t RAMEND = 0x08FF;

// -------------------------------------------------- tabla de ciclos (capa 3)
// La genera sim/perf/cycles_ref.py desde la tabla del manual del ISA.
enum { CK_FIXED = 0, CK_BRANCH = 1, CK_SKIP = 2, CK_UNCHECKED = 3 };

struct CycleTable {
    std::vector<uint8_t>     base, kind, mid;
    std::vector<std::string> names;

    bool load(const char *path) {
        FILE *f = fopen(path, "rb");
        if (!f) return false;
        char magic[5];
        if (fread(magic, 1, 5, f) != 5 || memcmp(magic, "AXCY1", 5)) { fclose(f); return false; }
        uint16_t n = 0;
        if (fread(&n, 2, 1, f) != 1) { fclose(f); return false; }
        names.resize(n);
        for (uint16_t i = 0; i < n; i++) {
            uint8_t len = 0;
            if (fread(&len, 1, 1, f) != 1) { fclose(f); return false; }
            std::string s(len, '\0');
            if (len && fread(&s[0], 1, len, f) != len) { fclose(f); return false; }
            names[i] = s;
        }
        base.resize(65536); kind.resize(65536); mid.resize(65536);
        for (int op = 0; op < 65536; op++) {
            uint8_t r[3];
            if (fread(r, 1, 3, f) != 3) { fclose(f); return false; }
            base[op] = r[0]; kind[op] = r[1]; mid[op] = r[2];
        }
        fclose(f);
        return true;
    }
    const std::string &name(uint16_t op) const { return names[mid[op]]; }
};

static CycleTable ctab;

// Ciclos que el manual atribuye a esta instrucción EN ESTA EJECUCIÓN.
//
// Dos clases dependen del resultado, y en ambas la condición se obtiene del
// LADO DEL ORÁCULO, nunca del RTL:
//
//   rama    tomada o no, según el SREG de simavr ANTES de ejecutar. No se
//           deduce del avance del PC porque `brne .+0` avanza una palabra
//           tanto si salta como si no, y son 2 ciclos frente a 1.
//   salto   1, 2 o 3 palabras según el tamaño de la instrucción descartada;
//           el avance del PC de simavr lo dice sin ambigüedad.
//
// Devuelve 0 si la instrucción no se comprueba.
static int expected_cycles(uint16_t insn, uint8_t sreg_before, int words_advanced) {
    switch (ctab.kind[insn]) {
    case CK_FIXED:  return ctab.base[insn];
    case CK_BRANCH: {
        // BRBS = 1111 00kk kkkk ksss   BRBC = 1111 01kk kkkk ksss
        int s = insn & 7;
        int want = ((insn & 0x0400) == 0) ? 1 : 0;
        return (((sreg_before >> s) & 1) == want) ? 2 : 1;
    }
    case CK_SKIP:
        // 1 palabra = no saltó; 2 = descartó una de 16 bits; 3 = una de 32.
        return (words_advanced >= 1 && words_advanced <= 3) ? words_advanced : -1;
    default:        return 0;
    }
}

// ------------------------------------------------------------------- RTL
static void tick() { rtl->clk = 1; rtl->eval(); rtl->clk = 0; rtl->eval(); }

static void rtl_reset() {
    rtl->rst_n = 0; rtl->prog_we = 0; rtl->dbg_reg_addr = 0; rtl->dbg_mem_addr = 0;
    rtl->clk = 0; rtl->eval();
    for (int i = 0; i < 4; i++) tick();
    rtl->rst_n = 1;
}

static void rtl_load(const std::vector<uint16_t> &words) {
    for (size_t i = 0; i < words.size(); i++) {
        rtl->prog_we = 1; rtl->prog_addr = i; rtl->prog_data = words[i];
        tick();
    }
    rtl->prog_we = 0;
    rtl->eval();
}

static uint8_t rtl_reg(int i) { rtl->dbg_reg_addr = i; rtl->eval(); return rtl->dbg_reg_data; }
static uint8_t rtl_mem(uint16_t a) { rtl->dbg_mem_addr = a; rtl->eval(); return rtl->dbg_mem_data; }

// Avanza el RTL hasta retirar una instrucción. Devuelve los ciclos consumidos.
static int rtl_step(int limit = 64) {
    int cycles = 0;
    while (cycles < limit) {
        rtl->eval();
        bool retiring = rtl->dbg_retire;
        tick();
        cycles++;
        if (retiring) return cycles;
    }
    return -1;                                  // atascado
}

// ---------------------------------------------------------------- simavr
static uint8_t avr_sreg_byte() {
    uint8_t s = 0;
    for (int i = 0; i < 8; i++) s |= (avr->sreg[i] & 1) << i;
    return s;
}
static uint16_t avr_sp() { return avr->data[R_SPL] | (avr->data[R_SPH] << 8); }

// -------------------------------------------------------------- programa
static std::vector<uint16_t> load_bin(const char *path) {
    FILE *f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "no se puede abrir %s\n", path); exit(2); }
    std::vector<uint8_t> raw;
    uint8_t b[4096]; size_t n;
    while ((n = fread(b, 1, sizeof(b), f)) > 0) raw.insert(raw.end(), b, b + n);
    fclose(f);
    if (raw.size() & 1) raw.push_back(0);
    std::vector<uint16_t> w(raw.size() / 2);
    for (size_t i = 0; i < w.size(); i++) w[i] = raw[2 * i] | (raw[2 * i + 1] << 8);
    return w;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    if (argc < 2) {
        fprintf(stderr, "uso: %s <programa.bin> [max_instr] [cycles.bin] [cov.txt]\n",
                argv[0]);
        return 2;
    }
    const long MAXI = (argc > 2) ? atol(argv[2]) : 100000;
    const char *ctab_path = (argc > 3) ? argv[3] : "build/perf/cycles.bin";
    const char *cov_path   = (argc > 4) ? argv[4] : nullptr;

    // La tabla de ciclos es OBLIGATORIA. Si faltara y el arnés siguiera sin
    // ella, la capa 3 se apagaría en silencio y la regresión seguiría en
    // verde sin comprobar nada de temporización.
    if (!ctab.load(ctab_path)) {
        fprintf(stderr, "no se puede leer la tabla de ciclos %s\n"
                        "  la genera: python3 sim/perf/cycles_ref.py "
                        "build/decode/objdump.npz %s\n", ctab_path, ctab_path);
        return 2;
    }

    std::vector<uint16_t> prog = load_bin(argv[1]);
    printf("  programa: %s  (%zu palabras)\n", argv[1], prog.size());

    // ---- RTL ----
    rtl = new Vaxioma_sim_top;
    rtl_reset();
    rtl_load(prog);
    rtl_reset();

    // ---- simavr ----
    avr = avr_make_mcu_by_name("atmega328p");
    if (!avr) { fprintf(stderr, "simavr no conoce atmega328p\n"); return 2; }
    avr_init(avr);
    avr->frequency = 16000000;
    for (size_t i = 0; i < prog.size(); i++) {
        avr->flash[2 * i]     = prog[i] & 0xFF;
        avr->flash[2 * i + 1] = prog[i] >> 8;
    }
    avr->codeend = prog.size() * 2;
    avr->pc = 0;
    avr->state = cpu_Running;
    avr->data[R_SPL] = RAMEND & 0xFF;
    avr->data[R_SPH] = RAMEND >> 8;

    // ---- bucle diferencial ----
    long n = 0, diverged = -1;
    long total_cycles = 0, ref_cycles = 0, checked = 0;

    // Discrepancias entre la tabla del manual y la cuenta de simavr. NO son un
    // fallo del RTL: se informan para adjudicarlas contra el manual.
    std::map<std::string, std::pair<int, int>> simavr_diff;   // mnem -> (tabla, simavr)
    std::map<std::string, long> simavr_diff_n;

    // Qué mnemónicos llegan a comprobarse. Sin esto, «0 desviaciones» no dice
    // nada sobre lo que NO se ejecutó: la cobertura tiene que ser un número,
    // no una impresión.
    std::map<std::string, long> covered;
    for (; n < MAXI; n++) {
        uint16_t pc_before = avr->pc / 2;
        if (pc_before >= prog.size()) {
            printf("\n  EL PC SE SALE DEL PROGRAMA: pc=0x%04X, programa de %zu palabras\n",
                   pc_before, prog.size());
            printf("    Casi siempre es un fallo del PROGRAMA DE PRUEBA, no del núcleo:\n"
                   "    un salto mal calculado que cae en memoria sin programar.\n"
                   "    Ojo con ICALL e IJMP: usan la dirección de PALABRA, así que\n"
                   "    en el ensamblador van con pm_lo8()/pm_hi8(), no lo8()/hi8().\n");
            diverged = n; break;
        }
        uint16_t insn = prog[pc_before];
        // El SREG de ANTES decide si una rama se toma; los ciclos de simavr se
        // miden por diferencia. Ambos se leen antes de ejecutar nada.
        uint8_t  sreg_before = avr_sreg_byte();
        uint64_t avr_cyc_before = avr->cycle;

        int cyc = rtl_step();
        if (cyc < 0) {
            printf("\n  EL RTL SE ATASCA en pc=0x%04X insn=0x%04X\n", pc_before, insn);
            diverged = n; break;
        }
        total_cycles += cyc;

        avr->pc = avr_run_one(avr);

        // --- comparación ---
        const char *what = nullptr;
        uint32_t got = 0, exp = 0;

        uint16_t rtl_pc = rtl->dbg_pc, ref_pc = avr->pc / 2;
        if (rtl_pc != ref_pc) { what = "PC"; got = rtl_pc; exp = ref_pc; }

        if (!what) {
            uint8_t g = rtl->dbg_sreg, e = avr_sreg_byte();
            if (g != e) { what = "SREG"; got = g; exp = e; }
        }
        if (!what) {
            uint16_t g = rtl->dbg_sp, e = avr_sp();
            if (g != e) { what = "SP"; got = g; exp = e; }
        }
        static char rbuf[8];
        if (!what) {
            for (int i = 0; i < 32; i++) {
                uint8_t g = rtl_reg(i), e = avr->data[i];
                if (g != e) { snprintf(rbuf, sizeof(rbuf), "R%d", i);
                              what = rbuf; got = g; exp = e; break; }
            }
        }

        if (what) {
            printf("\n  DIVERGENCIA tras %ld instrucciones\n", n + 1);
            printf("    instrucción  pc=0x%04X  opcode=0x%04X  (%d ciclos en el RTL)\n",
                   pc_before, insn, cyc);
            printf("    %-6s  RTL=0x%04X   simavr=0x%04X\n", what, got, exp);
            printf("\n    estado del RTL:    pc=0x%04X sreg=0x%02X sp=0x%04X\n",
                   rtl->dbg_pc, rtl->dbg_sreg, rtl->dbg_sp);
            printf("    estado de simavr:  pc=0x%04X sreg=0x%02X sp=0x%04X\n",
                   avr->pc / 2, avr_sreg_byte(), avr_sp());
            printf("    registros (RTL / simavr):\n     ");
            for (int i = 0; i < 32; i++) {
                uint8_t g = rtl_reg(i), e = avr->data[i];
                printf(" %s%02X/%02X%s", g != e ? "[" : "", g, e, g != e ? "]" : "");
                if (i % 8 == 7) printf("\n     ");
            }
            printf("\n");
            diverged = n; break;
        }

        // ------------------------------- capa 3: exactitud de ciclos -------
        int words = (int)(avr->pc / 2) - (int)pc_before;
        int want  = expected_cycles(insn, sreg_before, words);
        int scyc  = (int)(avr->cycle - avr_cyc_before);
        ref_cycles += scyc;

        // El ciclo de calentamiento tras el reset se le imputaría a la primera
        // instrucción. Es sobrecoste de arranque, no de la instrucción: la
        // memoria de programa está registrada y en el primer ciclo todavía no
        // ha llegado mem[0]. En vez de ignorarlo, se COMPRUEBA que cuesta
        // exactamente un ciclo; si costara más, sería un fallo de verdad.
        if (want > 0 && n == 0) {
            checked++;
            covered[ctab.name(insn)]++;
            if (cyc != want + 1) {
                printf("\n  EL CALENTAMIENTO TRAS EL RESET NO CUESTA UN CICLO\n");
                printf("    primera instrucción  opcode=0x%04X  %s\n",
                       insn, ctab.name(insn).c_str());
                printf("    RTL=%d ciclos   manual=%d + 1 de calentamiento = %d\n",
                       cyc, want, want + 1);
                diverged = n; break;
            }
        } else if (want > 0) {
            checked++;
            covered[ctab.name(insn)]++;
            if (cyc != want) {
                printf("\n  CICLOS INCORRECTOS tras %ld instrucciones\n", n + 1);
                printf("    instrucción  pc=0x%04X  opcode=0x%04X  %s\n",
                       pc_before, insn, ctab.name(insn).c_str());
                printf("    RTL=%d ciclos   manual=%d   simavr=%d\n", cyc, want, scyc);
                if (ctab.kind[insn] == CK_BRANCH)
                    printf("    (rama %s; SREG antes = 0x%02X)\n",
                           want == 2 ? "TOMADA" : "no tomada", sreg_before);
                if (ctab.kind[insn] == CK_SKIP)
                    printf("    (avance de %d palabra%s)\n", words, words == 1 ? "" : "s");
                printf("\n    La tabla está en docs/01-arquitectura.md §3 y se\n"
                       "    transcribe en sim/perf/cycles_ref.py. Si el manual dice\n"
                       "    otra cosa, se corrige la tabla ANTES que el RTL.\n");
                diverged = n; break;
            }
            if (scyc != want) {
                const std::string &nm = ctab.name(insn);
                simavr_diff[nm] = std::make_pair(want, scyc);
                simavr_diff_n[nm]++;
            }
        } else if (want < 0) {
            printf("\n  AVANCE DE PC IMPOSIBLE en un salto de instrucción\n");
            printf("    pc=0x%04X opcode=0x%04X %s avanzó %d palabras\n",
                   pc_before, insn, ctab.name(insn).c_str(), words);
            diverged = n; break;
        }

        if (avr->state != cpu_Running) { n++; break; }
    }

    // ---------------------------------------------------------------
    //  Barrido final del espacio de datos.
    //
    //  La comparación por instrucción mira PC, registros, SREG y SP, pero NO
    //  la memoria: una escritura a la dirección equivocada sólo se notaba si
    //  el programa volvía a leerla. ST, STS, PUSH, OUT, SBI y CBI escriben sin
    //  leer, así que el hueco era real.
    //
    //  Se barre la SRAM entera y, del espacio de I/O, SÓLO los tres GPIOR.
    //  El resto de la I/O no se puede comparar en la fase 1: simavr modela los
    //  periféricos y arranca varios registros con valores distintos de cero,
    //  mientras que aquí la I/O es memoria plana. Los GPIOR son almacenamiento
    //  puro en ambos lados.
    // ---------------------------------------------------------------
    long mem_bad = 0;
    if (diverged < 0) {
        // ESTA TABLA CRECE CON CADA PERIFÉRICO. Del espacio de I/O sólo se
        // puede comparar lo que MODELAN LOS DOS LADOS igual. Al principio eran
        // sólo los GPIOR, que son almacenamiento puro; conforme aterriza un
        // periférico de verdad, sus registros entran aquí.
        struct IoRango { uint16_t lo, hi; const char *que; };
        static const IoRango COMPARABLE[] = {
            {0x0024, 0x0025, "DDRB y PORTB"},
            {0x0027, 0x0028, "DDRC y PORTC"},
            {0x002A, 0x002B, "DDRD y PORTD"},
            {0x003E, 0x003E, "GPIOR0"},
            {0x004A, 0x004B, "GPIOR1 y GPIOR2"},
        };
        // PINB, PINC y PIND quedan FUERA a propósito: en un pin de entrada sin
        // pull-up el pad está flotando y su valor no lo define nadie —ni la
        // hoja de datos ni simavr—. Compararlo sería comparar ruido. Lo que sí
        // se verifica de PINx es el sincronizador, y eso lo hace su propio
        // banco, porque simavr tampoco lo modela.

        for (uint16_t a = 0x0100; a <= RAMEND; a++) {
            uint8_t g = rtl_mem(a), e = avr->data[a];
            if (g != e && ++mem_bad <= 8)
                printf("\n  MEMORIA DISTINTA en 0x%04X: RTL=0x%02X simavr=0x%02X", a, g, e);
        }
        for (const auto &r : COMPARABLE)
            for (uint16_t a = r.lo; a <= r.hi; a++) {
                uint8_t g = rtl_mem(a), e = avr->data[a];
                if (g != e && ++mem_bad <= 8)
                    printf("\n  I/O DISTINTA en 0x%04X (%s): RTL=0x%02X simavr=0x%02X",
                           a, r.que, g, e);
            }
        if (mem_bad)
            printf("\n  %ld bytes distintos en el espacio de datos\n", mem_bad);
    }

    delete rtl;

    if (cov_path) {
        FILE *cf = fopen(cov_path, "w");
        if (cf) {
            for (const auto &kv : covered)
                fprintf(cf, "%s %ld\n", kv.first.c_str(), kv.second);
            fclose(cf);
        }
    }

    if (diverged >= 0 || mem_bad) return 1;

    if (!simavr_diff.empty()) {
        printf("\n  aviso: la cuenta de ciclos de simavr difiere del manual en "
               "%zu mnemónico%s\n", simavr_diff.size(),
               simavr_diff.size() == 1 ? "" : "s");
        for (const auto &kv : simavr_diff)
            printf("    %-8s manual=%d simavr=%d  (%ld veces)\n",
                   kv.first.c_str(), kv.second.first, kv.second.second,
                   simavr_diff_n[kv.first]);
        printf("    El oráculo es el manual; simavr avisa de que su cuenta puede\n"
               "    no ser exacta. Adjudicar a mano antes de tocar nada.\n");
    }

    printf("  %ld instrucciones, %ld ciclos, 0 divergencias\n", n, total_cycles);
    printf("  ciclos: %ld comprobados contra el manual, 0 desviaciones "
           "(simavr contó %ld)\n", checked, ref_cycles);
    printf("  cobertura de ciclos: %zu mnemónicos distintos · "
           "espacio de datos idéntico\n", covered.size());
    return 0;
}
