// AxiomaCore-328 - que la base de tiempo NO DERIVE
// SPDX-License-Identifier: Apache-2.0
//
// Es una de las tres cláusulas del criterio de aceptación de la fase 3:
// *«`micros()` no deriva»*. Conviene decir qué significa eso en un chip, porque
// «micros()» es una función de una biblioteca y aquí no se compila ninguna.
//
// `micros()` y `millis()` de Arduino se apoyan en **una sola cosa del
// hardware**: que el Timer0 desborde cada 256 cuentas y que **ninguno de esos
// desbordamientos se pierda**. El valor que devuelven es
//
//     (contador_de_desbordamientos << 8) + TCNT0
//
// escalado. Si un desbordamiento se pierde, el reloj del programa se retrasa
// 1 024 µs de golpe y **no se recupera nunca**: eso es la deriva. No es un
// error de redondeo que se promedie, es un escalón permanente.
//
// Así que lo que hay que demostrar es exacto y medible: **el número de entradas
// a la ISR de desbordamiento en una ventana larga es el que sale de la cuenta,
// sin uno de más ni de menos**, y el intervalo medio entre ellas es exactamente
// el periodo del temporizador.
//
// Y SE MIDE CON EL CHIP INCÓMODO, que es donde se pierden los desbordamientos:
//
//   - **otra interrupción compitiendo** — el Timer1 desbordando también, con su
//     propia ISR, para que haya solapes y colas;
//   - **secciones con las interrupciones apagadas** — `cli` … `sei` en el bucle
//     principal, que es lo que hace cualquier biblioteca que toque una variable
//     de 16 bits compartida con una ISR. Es el caso clásico: si el hardware
//     perdiera la bandera mientras `I` está a cero, la cuenta se iría.
//
// Un chip que pase esto con esas dos cosas encima tiene la base de tiempo sana.

#include "Vtb_soc_clk_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <utility>
#include <cmath>

static Vtb_soc_clk_top *dut;
static int fallos = 0;
static int comprobaciones = 0;

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static uint16_t LDI(int d, int k) {
    return 0xE000 | ((k & 0xF0) << 4) | (((d - 16) & 0xF) << 4) | (k & 0xF);
}
static uint16_t OUT(int a, int r) {
    return 0xB800 | ((a & 0x30) << 5) | ((r & 0x1F) << 4) | (a & 0x0F);
}
static uint16_t RJMP(int delta) { return 0xC000 | (delta & 0x0FFF); }
static const uint16_t RETI = 0x9518;
static const uint16_t SEI  = 0x9478;
static const uint16_t CLI  = 0x94F8;
static const uint16_t NOP  = 0x0000;

enum { IO_DDRB = 0x04, IO_PINB = 0x03,
       D_TCCR0B = 0x45, D_TIMSK0 = 0x6E, D_TCCR1B = 0x81, D_TIMSK1 = 0x6F,
       D_SPL = 0x5D, D_SPH = 0x5E };

// Vectores, en direcciones de PALABRA — que es como los da la tabla de
// `docs/05-register-map.md`, y su columna se llama «Palabra» justamente por
// esto. El vector `n` ocupa la palabra `2n`: DOS palabras por vector, porque el
// salto de la tabla es un `JMP`, que ocupa dos. Dividir por dos «para pasar de
// bytes a palabras» deja los saltos en mitad de la tabla y no entra ninguna
// interrupcion, sin ningun error: la primera version de este banco lo hizo.
enum { V_T1OVF = 0x001A, V_T0OVF = 0x0020 };

static void cargar(const std::vector<uint16_t> &p) {
    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < p.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = p[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_clk_top;

    // -------------------------------------------------- el programa
    // El principal ocupa hasta 0x68: las ISR van DESPUES, con hueco. La
    // primera version las puso en 0x60 y el bucle principal las machacaba.
    // La tabla llega hasta la palabra 2*25 = 0x32, asi que el principal
    // empieza en 0x40 y las ISR van detras de el, con hueco.
    const int MAIN = 0x40, ISR_T0 = 0x70, ISR_T1 = 0x78;
    std::vector<uint16_t> p(0x80, NOP);

    p[0]       = RJMP(MAIN - 0 - 1);
    p[V_T0OVF] = RJMP(ISR_T0 - V_T0OVF - 1);
    p[V_T1OVF] = RJMP(ISR_T1 - V_T1OVF - 1);

    // --- la ISR del desbordamiento del Timer0: conmuta PB0 y vuelve ---
    // Se conmuta con una escritura a `PINx`, que es de un ciclo y es lo que
    // usa cualquier biblioteca que quiera ir rapido. Cada conmutacion es UNA
    // entrada a la ISR, y eso es lo que el banco cuenta.
    {
        int a = ISR_T0;
        p[a++] = LDI(18, 0x01);
        p[a++] = OUT(IO_PINB, 18);
        p[a++] = RETI;
    }

    // --- la ISR del Timer1: existe solo para estorbar ---
    // Hace trabajo suficiente para solaparse con la del Timer0 y obligar a que
    // una espere a la otra, que es donde se pierden los desbordamientos.
    {
        int a = ISR_T1;
        for (int i = 0; i < 8; i++) p[a++] = NOP;
        p[a++] = RETI;
    }

    // --- el programa principal ---
    {
        int a = MAIN;
        // La pila, que hace falta para entrar en una ISR.
        p[a++] = LDI(16, 0xFF);  p[a++] = 0x9200 | (16 << 4); p[a++] = D_SPL;
        p[a++] = LDI(16, 0x08);  p[a++] = 0x9200 | (16 << 4); p[a++] = D_SPH;

        p[a++] = LDI(16, 0x01);  p[a++] = OUT(IO_DDRB, 16);   // PB0 salida

        p[a++] = LDI(16, 0x01);                               // TOIE0
        p[a++] = 0x9200 | (16 << 4); p[a++] = D_TIMSK0;
        p[a++] = LDI(16, 0x01);                               // TOIE1
        p[a++] = 0x9200 | (16 << 4); p[a++] = D_TIMSK1;

        p[a++] = LDI(16, 0x03);                               // CS=011, clk/64
        p[a++] = 0x9200 | (16 << 4); p[a++] = D_TCCR0B;
        p[a++] = LDI(16, 0x02);                               // CS=010, clk/8
        p[a++] = 0x9200 | (16 << 4); p[a++] = D_TCCR1B;

        p[a++] = SEI;

        // El bucle: apaga y enciende las interrupciones, que es lo que hace
        // cualquier biblioteca al tocar una variable compartida con una ISR.
        const int bucle = a;
        p[a++] = CLI;
        for (int i = 0; i < 12; i++) p[a++] = NOP;
        p[a++] = SEI;
        for (int i = 0; i < 4; i++) p[a++] = NOP;
        // El salto atras, con el indice calculado ANTES de incrementar: con
        // `p[a++] = RJMP(... a ...)` el orden de evaluacion se las trae.
        const int aqui = a;
        p[aqui] = RJMP(bucle - aqui - 1);
        a = aqui + 1;
    }

    cargar(p);

    // -------------------------------------------------- la medida
    // El Timer0 con clk/64 desborda cada 256*64 = 16 384 ciclos.
    //
    // HAY QUE SEPARAR DOS COSAS QUE NO SON LO MISMO, y la primera version de
    // este banco las confundia:
    //
    //   **jitter de latencia** — que una ISR entre unos ciclos mas tarde que
    //   otra porque el nucleo estaba a mitad de una instruccion, o con las
    //   interrupciones apagadas. Es ACOTADO, no se acumula, y lo hace un AVR
    //   de verdad. Prohibirlo seria pedirle al chip algo que el original no
    //   cumple.
    //
    //   **deriva** — que el periodo medio NO sea el del temporizador, porque se
    //   pierde un desbordamiento. Eso si se acumula, y es lo que rompe
    //   `micros()`: 1 024 us de retraso permanente por cada uno perdido.
    //
    // Se distinguen midiendo DOS ventanas de longitud muy distinta. Si hubiera
    // deriva, el desvio crecería con la ventana; si solo hay jitter, se queda
    // donde esta. Con 800 periodos, UN SOLO ciclo de deriva por periodo daria
    // 800 ciclos de desvio.
    const long PERIODO = 256L * 64L;
    const long LATENCIA_MAX = 64;      // holgura para el jitter, generosa

    struct Medida { long n, span, desvio; };
    auto medir = [&](long periodos) -> Medida {
        long n = 0, primera = -1, ultima = -1;
        int ant = dut->pb_out_v & 1;
        for (long c = 0; c < PERIODO * periodos; c++) {
            tick();
            int v = dut->pb_out_v & 1;
            if (v != ant) { n++; if (primera < 0) primera = c; ultima = c; }
            ant = v;
        }
        if (n < 2) return {n, 0, 0};
        const long span = ultima - primera;
        return {n, span, span - (n - 1) * PERIODO};
    };

    cargar(p);
    const Medida corta = medir(200);
    cargar(p);
    const Medida larga = medir(800);

    comprobaciones++;
    if (corta.n < 2 || larga.n < 2) {
        printf("    FALLA la ISR de desbordamiento no llego a entrar\n");
        fallos++;
    } else {
        // 1. NO SE PIERDE NINGUNO. Es la comprobacion decisiva: cada uno
        //    perdido es una entrada de menos.
        for (auto m : {std::pair<const char*, Medida>{"200", corta},
                       std::pair<const char*, Medida>{"800", larga}}) {
            const long caben = m.second.span / PERIODO + 1;
            comprobaciones++;
            if (m.second.n != caben) {
                printf("    FALLA en %s periodos hubo %ld entradas y caben %ld: "
                       "se ha perdido alguna\n", m.first, m.second.n, caben);
                fallos++;
            }
        }

        // 2. EL DESVIO ESTA ACOTADO Y NO CRECE. Si creciera con la ventana
        //    seria deriva; quedandose donde esta, es latencia.
        comprobaciones += 2;
        if (labs(corta.desvio) > LATENCIA_MAX) {
            printf("    FALLA con 200 periodos el desvio ya es %ld ciclos\n",
                   corta.desvio);
            fallos++;
        }
        if (labs(larga.desvio) > LATENCIA_MAX) {
            printf("    FALLA con 800 periodos el desvio sube a %ld ciclos: "
                   "eso se acumula, y es deriva\n", larga.desvio);
            fallos++;
        }

        printf("  200 periodos: %ld entradas, desvio %+ld ciclos\n",
               corta.n, corta.desvio);
        printf("  800 periodos: %ld entradas, desvio %+ld ciclos — no crece, "
               "asi que es latencia y no deriva\n", larga.n, larga.desvio);
    }

    // ------------------------------------------------------------------
    // EL CASO QUE DE VERDAD PIERDE DESBORDAMIENTOS: una ISR casi tan larga
    // como el periodo.
    //
    // Arriba el periodo son 16 384 ciclos y la ISR entra trece ciclos despues
    // del desbordamiento: el siguiente esta a 16 384 de distancia y NUNCA
    // coinciden. Eso deja sin probar el instante que importa — aquel en el que
    // el nucleo entra en el vector Y el temporizador desborda EN EL MISMO
    // CICLO—, que es donde se decide si gana poner la bandera o limpiarla.
    //
    // Lo dijo un mutante superviviente: invertir esa prioridad no rompia nada
    // medible, porque la colision no llegaba a ocurrir.
    //
    // Asi que aqui el temporizador va SIN DIVIDIR -periodo de 256- y la ISR se
    // alarga hasta ROZARLO, barriendo su longitud.
    //
    // Y LA AFIRMACION HAY QUE MEDIRLA BIEN, que es donde fallo la primera
    // version: con la ISR en 248 ciclos, mas la entrada al vector, el `RETI` y
    // la conmutacion, el servicio pasa de 256 y el desbordamiento se pierde
    // — TAMBIEN EN UN AVR DE VERDAD—. Exigir que no se pierda ahi es exigirle
    // al chip algo que el original no cumple. Lo que si se exige, y es lo que
    // importa para `micros()`, es que **mientras la ISR quepa en el periodo no
    // se pierda ni uno**, por poco que sobre.
    printf("  y con una ISR casi tan larga como el periodo, barriendo su largo\n");
    {
        const long P = 256;
        int peor = 0;
        for (int largo = 180; largo <= 240; largo++) {
            std::vector<uint16_t> q(0x200, NOP);
            const int MAIN2 = 0x40, ISR2 = 0x80;
            q[0]       = RJMP(MAIN2 - 1);
            q[V_T0OVF] = RJMP(ISR2 - V_T0OVF - 1);
            {
                int a = ISR2;
                q[a++] = LDI(18, 0x01);
                q[a++] = OUT(IO_PINB, 18);
                for (int i = 0; i < largo; i++) q[a++] = NOP;
                q[a++] = RETI;
            }
            {
                int a = MAIN2;
                q[a++] = LDI(16, 0xFF); q[a++] = 0x9200|(16<<4); q[a++] = D_SPL;
                q[a++] = LDI(16, 0x08); q[a++] = 0x9200|(16<<4); q[a++] = D_SPH;
                q[a++] = LDI(16, 0x01); q[a++] = OUT(IO_DDRB, 16);
                q[a++] = LDI(16, 0x01); q[a++] = 0x9200|(16<<4); q[a++] = D_TIMSK0;
                q[a++] = LDI(16, 0x01); q[a++] = 0x9200|(16<<4); q[a++] = D_TCCR0B;
                q[a++] = SEI;
                const int aqui = a;
                q[aqui] = RJMP(-1);          // rjmp aqui
            }
            cargar(q);

            long n = 0, primera = -1, ultima = -1;
            int ant = dut->pb_out_v & 1;
            for (long c = 0; c < P * 80; c++) {
                tick();
                int v = dut->pb_out_v & 1;
                if (v != ant) { n++; if (primera < 0) primera = c; ultima = c; }
                ant = v;
            }
            comprobaciones++;
            const long caben = (ultima - primera) / P + 1;
            if (n != caben) {
                if (peor++ < 3)
                    printf("    FALLA con la ISR de %d ciclos: %ld entradas y "
                           "caben %ld — se ha perdido un desbordamiento\n",
                           largo, n, caben);
                fallos++;
            }
        }
        if (!peor)
            printf("    de 180 a 240 ciclos de ISR, ninguna longitud pierde uno\n");
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
    if (fallos) {
        printf("  Un desbordamiento perdido retrasa el reloj del programa\n"
               "  1 024 us de golpe y no se recupera nunca: eso es la deriva.\n");
        return 1;
    }
    printf("  la base de tiempo no deriva, ni con otra ISR compitiendo ni con\n"
           "  las interrupciones apagadas a ratos\n");
    return 0;
}
