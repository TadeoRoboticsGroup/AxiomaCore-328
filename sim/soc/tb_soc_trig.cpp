// AxiomaCore-328 - las siete fuentes del disparo automático, una por una
// SPDX-License-Identifier: Apache-2.0
//
// La tabla 23-6 de la hoja de datos dice de dónde sale cada disparo:
//
//   ADTS  fuente
//    000  modo libre (se rearma con el fin de la conversión anterior)
//    001  ACI      comparador analógico
//    010  INTF0    interrupción externa 0
//    011  OCF0A    comparación A del Timer0
//    100  TOV0     desbordamiento del Timer0
//    101  OCF1B    comparación B del Timer1
//    110  TOV1     desbordamiento del Timer1
//    111  ICF1     captura del Timer1
//
// Ocho entradas de un multiplexor, y el banco de `axioma_adc` no puede decir
// nada sobre ellas: allí `adc_trig` es un puerto, y da igual qué haya al otro
// lado del cable. Una permutación en la tabla del SoC —que OCF0A y OCF1B se
// crucen, por ejemplo— pasa entero el banco de módulo, pasa lint, pasa síntesis
// y sale en el chip.
//
// Así que aquí cada fuente se provoca POR SU CAMINO: un programa de verdad
// configura el periférico de verdad, la bandera sube donde sube en el chip, y
// se mira `adc_muestrea` —el pulso del S/H— para saber si el ADC arrancó.
//
// Y con la prueba positiva NO BASTA. Si el multiplexor estuviera roto de forma
// que TODO dispara, las siete pruebas pasarían igual. Por eso cada fuente se
// comprueba dos veces: se provoca con ADTS apuntando a ella (tiene que
// arrancar) y con ADTS apuntando a OTRA que nadie provoca (NO tiene que
// arrancar). Eso es lo que distingue un cable de un cortocircuito.

#include "Vtb_soc_trig_top.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <vector>
#include <string>

static Vtb_soc_trig_top *dut;
static int fallos = 0;

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

// ------------------------------------------------------------- opcodes
static uint16_t LDI(int d, int k) {
    return 0xE000 | ((k & 0xF0) << 4) | (((d - 16) & 0xF) << 4) | (k & 0xF);
}
static const uint16_t RJMP_AQUI = 0xCFFF;

// STS ocupa dos palabras: la instrucción y la dirección.
static void STS(std::vector<uint16_t> &p, int dir, int reg) {
    p.push_back(0x9200 | (reg << 4));
    p.push_back((uint16_t)dir);
}
// Cargar un valor y dejarlo en una dirección del espacio de datos.
static void PON(std::vector<uint16_t> &p, int dir, int val) {
    p.push_back(LDI(16, val));
    STS(p, dir, 16);
}

// ------------------------------------------- direcciones del espacio de datos
enum {
    DDRB = 0x24, PORTB = 0x25, DDRD = 0x2A, PORTD = 0x2B,
    TCCR0A = 0x44, TCCR0B = 0x45, TCNT0 = 0x46, OCR0A = 0x47,
    EICRA = 0x69,
    ADMUX = 0x7C, ADCSRA = 0x7A, ADCSRB = 0x7B,
    TCCR1A = 0x80, TCCR1B = 0x81, TCNT1L = 0x84, TCNT1H = 0x85,
    OCR1BL = 0x8A, OCR1BH = 0x8B
};

// ADCSRA: ADEN=7 ADSC=6 ADATE=5 ADIF=4 ADIE=3 ADPS=2:0.
// El prescaler se deja al mínimo (÷2) para que una conversión quepa en pocos
// ciclos: aquí no se mide cuánto dura, se mira si EMPIEZA.
static const int ADEN_ADATE = 0xA0;
static const int ADEN_SOLO  = 0x80;

// --------------------------------------------------------------- el arnés
static void cargar(const std::vector<uint16_t> &p) {
    dut->rst_n = 0; dut->clk = 0; dut->prog_we = 0; dut->ac_forzada = 0;
    dut->eval();
    for (int i = 0; i < 4; i++) tick();
    for (size_t i = 0; i < p.size(); i++) {
        dut->prog_we = 1; dut->prog_addr = (uint16_t)i; dut->prog_data = p[i];
        tick();
    }
    dut->prog_we = 0;
    dut->rst_n = 1; dut->eval();
}

// Corre `n` ciclos y devuelve si el S/H se cerró alguna vez, o sea si el ADC
// arrancó una conversión. `mover_ac` mueve la salida del comparador a mitad de
// camino, que es como se fabrica un flanco de ACI desde fuera.
static bool corre(int n, bool mover_ac) {
    bool arranco = false;
    for (int c = 0; c < n; c++) {
        if (mover_ac && c == n / 2) { dut->ac_forzada = 1; dut->eval(); }
        tick();
        if (dut->adc_muestrea) arranco = true;
    }
    return arranco;
}

// El programa de cada fuente: deja el periférico produciendo su bandera y se
// queda en un bucle. Lo que cambia entre la prueba positiva y la negativa es
// SOLO el valor de ADTS, de modo que si la negativa también arranca es que el
// multiplexor no está seleccionando nada.
static std::vector<uint16_t> programa(int fuente, int adts, bool con_adate) {
    std::vector<uint16_t> p;
    // El ADC, encendido y apuntando al canal 0.
    PON(p, ADMUX, 0x00);

    switch (fuente) {
    case 1:  // ACI: el comparador arranca listo tras el reinicio -ACD=0,
             // ACIS=00, o sea conmutación-, así que no hay nada que configurar;
             // el flanco lo pone el banco moviendo `ac_forzada`.
        break;
    case 2:  // INTF0: PD2 como SALIDA, a cero, y el flanco de subida elegido.
             // El programa se fabrica su propia interrupción externa subiendo
             // el pin que él mismo maneja.
        PON(p, DDRD,  0x04);
        PON(p, PORTD, 0x00);
        PON(p, EICRA, 0x03);        // ISC01:ISC00 = 11, flanco de subida
        break;
    case 3:  // OCF0A: comparación a un valor pequeño, reloj sin dividir.
        PON(p, TCCR0A, 0x00);
        PON(p, OCR0A,  0x08);
        PON(p, TCCR0B, 0x01);
        break;
    case 4:  // TOV0: el mismo temporizador, pero esperando la vuelta entera.
        PON(p, TCCR0A, 0x00);
        PON(p, TCNT0,  0xF0);       // adelantado, para no esperar 256 ciclos
        PON(p, TCCR0B, 0x01);
        break;
    case 5:  // OCF1B: el de 16 bits, byte alto PRIMERO -pasa por el registro
             // temporal- y bajo después, que es como se escribe en este chip.
        PON(p, TCCR1A, 0x00);
        PON(p, OCR1BH, 0x00);
        PON(p, OCR1BL, 0x08);
        PON(p, TCCR1B, 0x01);
        break;
    case 6:  // TOV1: se precarga la cuenta cerca del final.
        PON(p, TCCR1A, 0x00);
        PON(p, TCNT1H, 0xFF);
        PON(p, TCNT1L, 0xF0);
        PON(p, TCCR1B, 0x01);
        break;
    case 7:  // ICF1: la captura entra por ICP1, que es PB0. El programa lo pone
             // como salida a cero y lo sube al final: su propia captura.
        PON(p, DDRB,   0x01);
        PON(p, PORTB,  0x00);
        PON(p, TCCR1A, 0x00);
        PON(p, TCCR1B, 0x41);       // ICES1 = flanco de subida, reloj sin dividir
        break;
    default: break;
    }

    // ADTS va en ADCSRB, y ADEN/ADATE en ADCSRA. Este orden importa: encender
    // el ADC DESPUÉS de elegir la fuente evita que el cambio de ADTS cuente
    // como flanco, que es un caso real de la hoja de datos y que el banco de
    // módulo ya comprueba aparte.
    PON(p, ADCSRB, adts);
    PON(p, ADCSRA, con_adate ? ADEN_ADATE : ADEN_SOLO);

    // Y ahora, y sólo ahora, el pin que fabrica el evento.
    if (fuente == 2) PON(p, PORTD, 0x04);
    if (fuente == 7) PON(p, PORTB, 0x01);

    p.push_back(RJMP_AQUI);
    return p;
}

static const char *NOMBRE[8] = {
    "modo libre", "ACI", "INTF0", "OCF0A", "TOV0", "OCF1B", "TOV1", "ICF1"
};

static void caso(const char *que, bool obtenido, bool esperado) {
    if (obtenido != esperado) {
        printf("    FALLA %-46s arranco=%d esperado=%d\n",
               que, obtenido ? 1 : 0, esperado ? 1 : 0);
        fallos++;
    }
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vtb_soc_trig_top;
    int comprobaciones = 0;

    printf("  cada fuente, por su camino real\n");
    for (int f = 1; f <= 7; f++) {
        // POSITIVA: ADTS apunta a la fuente que el programa provoca.
        cargar(programa(f, f, true));
        bool si = corre(900, f == 1);
        caso((std::string("ADTS=") + std::to_string(f) + " (" + NOMBRE[f] +
              ") dispara").c_str(), si, true);
        comprobaciones++;

        // NEGATIVA: el mismo programa, el mismo evento, pero ADTS apuntando a
        // otra fuente que NADIE provoca. Si esto arranca, el multiplexor no
        // está eligiendo: está pasando cualquier cosa.
        //
        // La fuente señuelo es ICF1 para todas menos para ICF1, que usa OCF1B;
        // ninguna de las dos se produce sola porque su programa no arranca ese
        // temporizador ni mueve ese pin.
        int senuelo = (f == 7) ? 5 : 7;
        cargar(programa(f, senuelo, true));
        bool no = corre(900, f == 1);
        caso((std::string("ADTS=") + std::to_string(senuelo) + " no dispara con " +
              NOMBRE[f]).c_str(), no, false);
        comprobaciones++;

        // SIN ADATE no hay disparo automático, apunte donde apunte ADTS. Es el
        // mismo programa con un bit menos.
        cargar(programa(f, f, false));
        bool sin = corre(900, f == 1);
        caso((std::string("ADTS=") + std::to_string(f) + " sin ADATE no dispara").c_str(),
             sin, false);
        comprobaciones++;
    }

    dut->final();
#if VM_COVERAGE
    const char *cov = getenv("AXIOMA_COV");
    if (cov) VerilatedCov::write(cov);
#endif
    delete dut;

    printf("  %d comprobaciones, %d fallos\n", comprobaciones, fallos);
    return fallos ? 1 : 0;
}
