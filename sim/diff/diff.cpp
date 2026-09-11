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
// LÍMITE CONOCIDO: el espacio de I/O del RTL sólo tiene periférico de verdad
// donde ya se ha escrito uno; el resto es memoria plana, mientras que simavr
// los modela todos. Los programas de prueba deben evitar los que aquí no
// existen. SPL, SPH y SREG los intercepta el propio núcleo.
//
// INTERRUPCIONES: QUIÉN ES EL ORÁCULO DE QUÉ.
// El Timer0 del RTL y el de simavr NO cuentan igual, y no es un fallo de
// ninguno de los dos: simavr no cuenta ciclo a ciclo, sino que interpola TCNT0
// desde `avr->cycle` y ancla su base en el ciclo en que se escribe TCCR0B, con
// lo que su cuenta va desfasada respecto de un prescaler libre. Compararlos en
// paralelo sería comparar dos relojes distintos.
//
// Así que el trabajo se reparte, que es la estrategia por capas de la fase 2:
//
//   CUÁNDO salta   lo decide el RTL, y lo verifica sim/periph/tb_timer0.cpp
//                  contra un modelo escrito desde la hoja de datos.
//   QUÉ hace el     lo verifica simavr: cuando el RTL entra en una ISR, el
//   núcleo          arnés levanta ESE MISMO vector en simavr y le deja ejecutar
//                   SU secuencia de entrada. Se comparan después el PC —es
//                   decir, la dirección del vector—, la pila, el SP y el SREG.
//
// Esa segunda mitad es justo la parte del núcleo que nunca se había ejercido, y
// encontró dos fallos reales en la primera ejecución: el vector se calculaba
// multiplicado por cuatro en vez de por dos, y la máquina de estados de entrada
// se caía al case de instrucciones en sus ciclos 1 a 3.
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
#include "sim_interrupts.h"
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

// Qué se acaba de retirar. Hay que capturarlo ANTES del flanco, a la vez que
// `dbg_retire`: después del flanco el RTL ya está en el ciclo siguiente y
// `dbg_irq_entry` habla de otra cosa. Es el mismo error de fase que en su día
// hizo que cada instrucción se ejecutara dos veces.
static bool rtl_irq_entry = false;
static int  rtl_irq_vector = 0;

// Avanza el RTL hasta retirar una instrucción. Devuelve los ciclos consumidos.
static int rtl_step(int limit = 64) {
    int cycles = 0;
    while (cycles < limit) {
        rtl->eval();
        bool retiring   = rtl->dbg_retire;
        bool irq_entry  = rtl->dbg_irq_entry;
        int  irq_vector = rtl->dbg_irq_vector;
        tick();
        cycles++;
        if (retiring) {
            rtl_irq_entry  = irq_entry;
            rtl_irq_vector = irq_vector;
            return cycles;
        }
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

// Vector de simavr por número. La tabla es pública y la rellena cada periférico
// al inicializarse, así que esto no inventa nada: pide el vector que el propio
// simavr registró para, por ejemplo, el desbordamiento del Timer0.
static avr_int_vector_t *find_vector(int n) {
    for (int i = 0; i < avr->interrupts.vector_count; i++)
        if (avr->interrupts.vector[i] &&
            avr->interrupts.vector[i]->vector == n)
            return avr->interrupts.vector[i];
    return nullptr;
}

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
    long irq_entries = 0;
    bool sei_anterior = false;

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

        bool irq_entry = rtl_irq_entry;
        if (irq_entry) {
            // ---- el RTL ha entrado en una interrupción ----
            int v = rtl_irq_vector;

            // EL RETARDO DE SEI (trampa nº 2) SE COMPRUEBA AQUÍ, y no en
            // simavr: como es el RTL quien decide cuándo salta, simavr no puede
            // desmentirle. La regla del manual es que la instrucción SIGUIENTE
            // a SEI se ejecuta entera antes de atender nada.
            if (sei_anterior) {
                printf("\n  INTERRUPCIÓN ATENDIDA DEMASIADO PRONTO\n");
                printf("    entró en el vector %d justo después de SEI, sin dejar\n"
                       "    ejecutar la instrucción siguiente (manual del ISA,\n"
                       "    trampa nº 2 de docs/01-arquitectura.md §8).\n", v);
                diverged = n; break;
            }

            avr_int_vector_t *vec = find_vector(v);
            if (!vec) {
                printf("\n  VECTOR %d DESCONOCIDO PARA simavr\n", v);
                printf("    el RTL saltó a un vector que simavr no tiene registrado.\n");
                diverged = n; break;
            }
            uint32_t pc_antes = avr->pc;

            // MANDA EL RTL, Y ESO HAY QUE IMPONERLO. simavr levanta
            // interrupciones POR SU CUENTA: su modelo de USART pone UDRE en
            // cuanto el búfer está libre, y con UDRIE habilitado se iría al
            // vector él solo, una instrucción antes que el RTL. Entonces los
            // dos estarían en el mismo sitio pero desfasados un paso, y todo lo
            // que viniera después divergiría.
            //
            // Así que antes de darle el vector se le limpia lo que tuviera
            // pendiente. Con esto su estado de interrupciones es EXACTAMENTE el
            // que decidió el RTL, que es el reparto de oráculos de este arnés:
            // el RTL decide cuándo, simavr ejecuta la entrada.
            for (int i = 0; i < avr->interrupts.vector_count; i++)
                if (avr->interrupts.vector[i])
                    avr_clear_interrupt(avr, avr->interrupts.vector[i]);

            avr_raise_interrupt(avr, vec);

            // Y SE INSISTE HASTA QUE LO ATIENDE. Limpiar `pending` no vacía la
            // cola interna de simavr: las entradas se quedan dentro y su
            // servicio, que elige la de número más bajo, descarta UNA por
            // llamada cuando encuentra que ya no está pendiente. Con una sola
            // llamada podía tocarle una entrada rancia y no atender la nuestra.
            //
            // El retardo de SEI lo gobierna y lo comprueba el propio arnés
            // —`sei_anterior`—, así que aquí se fuerza la cuenta interna: si no,
            // la primera interrupción tras un SEI se quedaría sin atender y
            // parecería un fallo del RTL.
            for (int intento = 0; intento < 32 && avr->pc == pc_antes; intento++) {
                avr->interrupt_state = 1;
                avr_service_interrupts(avr);
            }
            if (avr->pc == pc_antes) {
                printf("\n  simavr NO ATENDIÓ EL VECTOR %d\n", v);
                printf("    simavr: SREG=0x%02X (I=%d)  interrupt_state=%d\n",
                       avr_sreg_byte(), avr->sreg[S_I], avr->interrupt_state);
                printf("    UCSR0B=0x%02X UCSR0A=0x%02X TIMSK0=0x%02X\n",
                       avr->data[0xC1], avr->data[0xC0], avr->data[0x6E]);
                printf("    habilitacion del vector: %d   pendiente: %d\n",
                       avr_regbit_get(avr, vec->enable), vec->pending);
                printf("    lo habitual es que su habilitación (TIMSK) o el bit I\n"
                       "    no estén puestos en simavr, es decir, que el RTL haya\n"
                       "    saltado sin que tocara.\n");
                diverged = n; break;
            }
            irq_entries++;
        } else {
            avr->pc = avr_run_one(avr);
            // NO se llama aquí a `avr_service_interrupts`. Hacerlo dejaba que
            // simavr se fuera a un vector por su cuenta —su USART levanta UDRE
            // sola—, y quien decide cuándo salta una interrupción en este arnés
            // es el RTL. Se atiende sólo en la rama de arriba, con el vector
            // que el RTL acaba de tomar.
        }

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
        // La entrada a interrupción no es una instrucción y no está en la tabla
        // de opcodes, pero el manual sí le pone precio: 4 ciclos, más los 3 del
        // JMP del vector, que se cobran solos porque ese JMP se ejecuta como
        // cualquier otra instrucción. simavr no cobra ninguno —su servicio de
        // interrupciones no toca `avr->cycle`—, así que aquí no hay contraste
        // que hacer con él.
        if (irq_entry) {
            checked++;
            covered["entrada a ISR"]++;
            if (cyc != 4) {
                printf("\n  LA ENTRADA A ISR NO CUESTA 4 CICLOS\n");
                printf("    vector %d: RTL=%d ciclos, manual=4\n",
                       rtl_irq_vector, cyc);
                diverged = n; break;
            }
            sei_anterior = false;
            continue;
        }
        sei_anterior = (insn == 0x9478);        // SEI = BSET 7

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
            {0x0044, 0x0045, "TCCR0A y TCCR0B"},
            {0x0047, 0x0048, "OCR0A y OCR0B"},
            {0x004A, 0x004B, "GPIOR1 y GPIOR2"},
            {0x006E, 0x006E, "TIMSK0"},
            {0x00C2, 0x00C2, "UCSR0C"},
            {0x00C4, 0x00C5, "UBRR0L y UBRR0H"},
        };
        // DEL TIMER0 SE COMPARA LO QUE ES ALMACENAMIENTO EN LOS DOS LADOS, y
        // nada más. Quedan fuera, con motivo:
        //   TCNT0 (0x46)  simavr lo interpola desde `avr->cycle` con su propia
        //                 base de tiempo; son dos relojes distintos.
        //   TIFR0 (0x35)  aquí la pone el temporizador cuando desborda; en
        //                 simavr sólo cuando el arnés levanta el vector.
        //   GTCCR (0x43)  para simavr es un byte de almacenamiento; en el chip
        //                 PSRSYNC se autolimpia y se lee siempre como cero.
        // Y de TCCR0B sólo coincide lo que se lee: FOC0A y FOC0B son pulsos de
        // escritura y valen cero al leerse, mientras que simavr guarda el byte
        // entero. Ningún programa de prueba los escribe.
        //
        // DE LA USART SE COMPARA MENOS TODAVÍA, porque simavr NO MODELA EL
        // CABLE: transporta bytes enteros por IRQs internas y aproxima el
        // tiempo con `cycles_per_byte`, sumando siempre un bit de paridad esté
        // o no activada. Quedan fuera:
        //   UCSR0A (0xC0)  RXC, TXC y UDRE son banderas de temporización, y
        //                  aquí las mueve un transmisor que serializa de
        //                  verdad. Son dos relojes distintos.
        //   UDR0   (0xC6)  dos registros en una dirección, y leerlo saca un
        //                  byte del búfer: comparar tendría efectos laterales.
        //   UCSR0B (0xC1)  simavr LO ARRANCA CON TXEN PUESTO, y no por
        //                  descuido: `avr_uart_reset` lo hace con el comentario
        //                  «DEBUG allow printf without fiddling with enabling
        //                  the uart». El 328P real lo resetea a 0x00, así que
        //                  en un programa que no toque el puerto serie los dos
        //                  lados difieren desde el primer ciclo. Además su
        //                  bit 1 es RXB8 —el noveno bit RECIBIDO, de sólo
        //                  lectura— y simavr devuelve lo que se le escribió.
        //                  El registro SÍ se contrasta, pero por la vía de la
        //                  comparación por instrucción: `usart.S` lo lee de
        //                  vuelta a un registro del núcleo tras escribirlo.
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

#if VM_COVERAGE
    // COBERTURA DE CÓDIGO. Sólo existe si se compila con `--coverage`; en la
    // compilación normal esto no está. Verilator no vuelca nada por su cuenta:
    // el banco tiene que pedirlo, y sin esta llamada la instrumentación corre
    // y se tira a la basura — que es lo que pasaba.
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif

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
    // La cuenta de entradas a ISR va en esta misma línea a propósito: el
    // objetivo de `make sim-diff` imprime las tres últimas de cada programa.
    char isr[64] = "";
    if (irq_entries)
        snprintf(isr, sizeof(isr), " · %ld entradas a ISR", irq_entries);
    printf("  cobertura de ciclos: %zu mnemónicos distintos · "
           "espacio de datos idéntico%s\n", covered.size(), isr);
    return 0;
}
