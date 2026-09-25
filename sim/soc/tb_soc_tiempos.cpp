// AxiomaCore-328 - Servo y tone(), cronometrados en el pin
// SPDX-License-Identifier: Apache-2.0
//
// Dos sketches de la suite de la Capa 5, y los dos del mismo tipo: **lo que
// importa no es el valor de un registro sino cuánto dura una onda**.
//
//   Un servo de radiocontrol lee *cuánto dura el pulso*: 1 ms a un lado, 2 al
//   otro, 1,5 en el centro, repetido cada 20 ms. Si la trama se acorta el servo
//   tiembla; si el pulso se pasa, fuerza contra el tope.
//
//   `tone()` es una nota: si el periodo se desvía, se desafina.
//
// Los dos se miden aquí contando ciclos en el pin, sin mirar una sola señal
// interna — y **corriendo a la vez**, que es lo que demuestra que dos
// temporizadores con prescaler distinto no se pisan.
//
// LAS CIFRAS ESPERADAS NO SON «20 ms» Y «1 kHz», SON LAS QUE SALEN DE LOS
// REGISTROS. Es una distinción que importa: a 12,5 MHz con prescaler 64 no
// existe un `OCR2A` que dé 1 000 Hz clavados, y un banco que redondeara
// aceptaría un prescaler equivocado. Aquí se comprueba el número exacto que el
// programa pidió, y luego se dice si ese número cae donde el servo o el oído lo
// necesitan.

#include "Vtb_soc_uart_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static Vtb_soc_uart_top *dut;
static int fallos = 0;
static int comprobaciones = 0;

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

static void chk(const char *que, long got, long exp) {
    comprobaciones++;
    if (got != exp) {
        printf("    FALLA %-44s obtenido=%ld esperado=%ld\n", que, got, exp);
        fallos++;
    }
}

static const double NS = 80.0;          // un ciclo a 12,5 MHz

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_uart_top;
    if (argc < 2) { printf("  uso: tb_soc_tiempos <sketch.bin>\n"); return 2; }

    FILE *f = fopen(argv[1], "rb");
    if (!f) { printf("  no se pudo abrir %s\n", argv[1]); return 2; }
    std::vector<uint16_t> flash;
    int lo, hi;
    while ((lo = fgetc(f)) != EOF) {
        hi = fgetc(f);
        flash.push_back((uint16_t)lo | ((uint16_t)(hi == EOF ? 0xFF : hi) << 8));
    }
    fclose(f);

    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0; dut->rxd = 1;
    dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < flash.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = flash[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 0; dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();

    // ------------------------------------------------ el cronometro
    // Se miden los dos pines a la vez, que es la gracia: si un temporizador
    // pisara al otro, una de las dos ondas se deformaria.
    struct Medida {
        int bit;
        long alto = 0, bajo = 0;        // del pulso completo que se esta midiendo
        long cuenta_alto = 0;
        int  previo = -1;
        std::vector<long> altos, periodos;
        long ultimo_flanco_subida = -1;
    };
    Medida servo{1}, nota{3};
    Medida *m[2] = {&servo, &nota};

    // Se deja arrancar: el Timer1 tiene que completar al menos una trama de
    // 20 ms, que son 250 000 ciclos.
    for (long c = 0; c < 300000; c++) tick();

    const long VENTANA = 1600000;       // ~128 ms: seis tramas de servo
    for (long c = 0; c < VENTANA; c++) {
        tick();
        const uint8_t pb = dut->portb;
        for (Medida *x : m) {
            const int v = (pb >> x->bit) & 1;
            if (x->previo < 0) { x->previo = v; continue; }
            if (v && !x->previo) {                       // flanco de subida
                if (x->ultimo_flanco_subida >= 0)
                    x->periodos.push_back(c - x->ultimo_flanco_subida);
                x->ultimo_flanco_subida = c;
                x->cuenta_alto = 0;
            }
            if (v) x->cuenta_alto++;
            // Solo se apunta el pulso si se vio SUBIR: el primero que pilla el
            // muestreo puede estar empezado, y un pulso a medias metido en la
            // media la corre sin que nada lo diga. Costo un desajuste de 41
            // ciclos en la nota que parecia del chip y era del cronometro.
            if (!v && x->previo && x->cuenta_alto > 0) {
                if (x->ultimo_flanco_subida >= 0) x->altos.push_back(x->cuenta_alto);
                x->cuenta_alto = 0;
            }
            x->previo = v;
        }
    }

    auto media = [](const std::vector<long> &v) -> double {
        if (v.empty()) return 0;
        double s = 0; for (long x : v) s += x; return s / v.size();
    };
    auto todos_iguales = [](const std::vector<long> &v) -> bool {
        for (size_t i = 1; i < v.size(); i++) if (v[i] != v[0]) return false;
        return !v.empty();
    };

    // ------------------------------------------------------- el servo
    // ICR1 = 31249 y prescaler 8  ->  (31249+1)*8 = 250 000 ciclos = 20,0 ms
    //
    // Y el pulso son OCR1A+1 tics, NO OCR1A: en PWM rapido el pin se pone a uno
    // en BOTTOM y se baja en la comparacion, asi que esta alto durante las
    // cuentas 0..OCR1A, que son OCR1A+1. Con 2344 salen 2345*8 = 18 760 ciclos
    // = 1,5008 ms. La primera version de este banco esperaba 18 752 y el que
    // estaba equivocado era el banco: la hoja de datos dice lo que pasa.
    printf("  servo (OC1A, PB1): %zu tramas medidas\n", servo.periodos.size());
    comprobaciones++;
    if (servo.periodos.size() < 3) {
        printf("    FALLA no salieron tramas de servo suficientes\n");
        fallos++;
    } else {
        chk("la trama son 250 000 ciclos (20,0 ms)", (long)media(servo.periodos), 250000);
        chk("el pulso son 18 760 ciclos (1,5008 ms)", (long)media(servo.altos), 18760);
        // Y TODAS IGUALES: un servo tiembla con la trama que varia, no con la
        // que es larga. La media sola taparia un temblor simetrico.
        comprobaciones++;
        if (!todos_iguales(servo.periodos)) {
            printf("    FALLA las tramas del servo no son todas iguales\n");
            fallos++;
        }
        printf("    trama %.0f us · pulso %.0f us — el centro del recorrido\n",
               media(servo.periodos) * NS / 1000.0, media(servo.altos) * NS / 1000.0);
    }

    // -------------------------------------------------------- la nota
    // OCR2A = 97 y prescaler 64  ->  conmuta cada (97+1)*64 = 6272 ciclos,
    // asi que el periodo completo son 12 544 ciclos = 1003,52 us = 996,49 Hz.
    printf("  tone (OC2A, PB3): %zu periodos medidos\n", nota.periodos.size());
    comprobaciones++;
    if (nota.periodos.size() < 10) {
        printf("    FALLA no salieron periodos de nota suficientes\n");
        fallos++;
    } else {
        chk("el periodo son 12 544 ciclos", (long)media(nota.periodos), 12544);
        // Simetrica: en CTC conmutando, el alto y el bajo son iguales. Si no lo
        // fueran, la nota tendria armonicos que no deberia.
        chk("el semiperiodo alto son 6 272 ciclos", (long)media(nota.altos), 6272);
        const double hz = 1e9 / (media(nota.periodos) * NS);
        printf("    %.2f Hz — no son 1 000 clavados, y con este reloj y este\n"
               "    prescaler no existe un OCR2A que los de\n", hz);
    }

    // --------------------------------- y que uno no pise al otro
    // Es lo que justifica medirlos a la vez: dos temporizadores con prescaler
    // distinto compartiendo el contador de diez bits.
    comprobaciones++;
    if (!servo.periodos.empty() && !nota.periodos.empty() &&
        todos_iguales(servo.periodos) && todos_iguales(nota.periodos)) {
        printf("  los dos temporizadores conviven sin deformarse\n");
    } else {
        printf("    FALLA una de las dos ondas varia con la otra corriendo\n");
        fallos++;
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
    printf("  Servo y tone() salen con la duracion que pidieron los registros\n");
    return 0;
}
