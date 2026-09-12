// AxiomaCore-328 - interrupciones externas contra un modelo de la hoja de datos
// SPDX-License-Identifier: Apache-2.0
//
// POR QUÉ HACE FALTA ESTE BANCO. La co-simulación diferencial compara estado
// del núcleo tras cada instrucción, y para eso hace falta que ALGO mueva los
// pines. Los pines aquí son entradas del chip: ningún programa puede generar
// por sí solo el flanco que quiere detectar —salvo conmutando un pin de salida,
// que es UNA de las combinaciones—. Así que la forma de onda la pone este banco
// y el oráculo es la hoja de datos.
//
// Y hay tres cosas que ningún programa de co-simulación alcanzaría:
//
//   - EL MODO DE NIVEL BAJO. No tiene bandera, y la petición se mantiene
//     mientras el pin esté bajo. Para verlo hay que mirar la LÍNEA de petición
//     ciclo a ciclo, no el resultado de un salto.
//   - QUE LA BANDERA SE PONGA CON LA INTERRUPCIÓN DESHABILITADA. Es el sondeo
//     sin interrupciones, y es un uso normal.
//   - QUE `PCMSKn` FILTRE TAMBIÉN LA BANDERA, mientras que `PCICR` sólo filtra
//     el salto al vector.
//
// El modelo está escrito desde la hoja de datos, no desde el RTL.

#include "Vaxioma_extint.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <random>

static Vaxioma_extint *dut;
static int  fails  = 0;
static long checks = 0;

static void chk(const char *que, uint32_t got, uint32_t exp, long t) {
    checks++;
    if (got != exp && ++fails <= 12)
        printf("    FALLA %-38s t=%ld  obtenido=%02X esperado=%02X\n",
               que, t, got, exp);
}

// Direcciones de I/O = dirección del espacio de datos menos 0x20.
static const uint8_t A_PCIFR = 0x1B, A_EIFR = 0x1C, A_EIMSK = 0x1D;
static const uint8_t A_PCICR = 0x48, A_EICRA = 0x49;
static const uint8_t A_PCMSK0 = 0x4B, A_PCMSK1 = 0x4C, A_PCMSK2 = 0x4D;

// ------------------------------------------------------------------ modelo
struct Model {
    uint8_t eicra = 0, eimsk = 0, eifr = 0, pcicr = 0, pcifr = 0;
    uint8_t pcmsk0 = 0, pcmsk1 = 0, pcmsk2 = 0;
    uint8_t syn_b = 0, syn_c = 0, syn_d = 0;
    uint8_t prv_b = 0, prv_c = 0, prv_d = 0;

    // La bandera de una externa se LEE SIEMPRE COMO CERO en modo de nivel bajo.
    // No es un detalle de presentación: de ahí sale también la petición.
    uint8_t eifr_visible() const {
        uint8_t v = 0;
        if ((eicra & 0x03) != 0 && (eifr & 0x01)) v |= 0x01;
        if ((eicra & 0x0C) != 0 && (eifr & 0x02)) v |= 0x02;
        return v;
    }

    static bool flanco(int modo, int ahora, int antes) {
        switch (modo) {
            case 1:  return ahora != antes;          // cualquier cambio
            case 2:  return !ahora &&  antes;        // bajada
            case 3:  return  ahora && !antes;        // subida
            default: return false;                   // nivel bajo: sin flanco
        }
    }

    uint8_t lee(uint8_t a) const {
        switch (a) {
            case A_EICRA:  return (uint8_t)(eicra & 0x0F);
            case A_EIMSK:  return (uint8_t)(eimsk & 0x03);
            case A_EIFR:   return eifr_visible();
            case A_PCICR:  return (uint8_t)(pcicr & 0x07);
            case A_PCIFR:  return (uint8_t)(pcifr & 0x07);
            case A_PCMSK0: return pcmsk0;
            case A_PCMSK1: return pcmsk1;
            case A_PCMSK2: return pcmsk2;
            default:       return 0x00;
        }
    }

    // Las cinco líneas de petición, tal como las ve el controlador.
    uint8_t int0() const {
        bool nivel = (eicra & 0x03) == 0 && !((syn_d >> 2) & 1);
        return (eimsk & 0x01) && (nivel || (eifr_visible() & 0x01));
    }
    uint8_t int1() const {
        bool nivel = (eicra & 0x0C) == 0 && !((syn_d >> 3) & 1);
        return (eimsk & 0x02) && (nivel || (eifr_visible() & 0x02));
    }
    uint8_t pcint(int n) const { return ((pcicr >> n) & 1) && ((pcifr >> n) & 1); }

    // UN CICLO. Todo lo que el RTL calcula en el flanco sale de los valores
    // ANTERIORES al flanco: los sincronizadores se actualizan a la vez que las
    // banderas, no antes. Guardar los valores de entrada al principio es la
    // única forma de no volver a escribir un bloqueante donde el RTL tiene un
    // no bloqueante.
    void cycle(uint8_t pin_b, uint8_t pin_c, uint8_t pin_d,
               bool we, uint8_t addr, uint8_t wdata,
               bool ack_int0, bool ack_int1,
               bool ack_pc0, bool ack_pc1, bool ack_pc2) {
        const uint8_t n_syn_b = pin_b, n_syn_c = pin_c, n_syn_d = pin_d;
        const uint8_t n_prv_b = syn_b, n_prv_c = syn_c, n_prv_d = syn_d;

        const bool ev_int0 = flanco(eicra & 0x03,
                                    (syn_d >> 2) & 1, (prv_d >> 2) & 1);
        const bool ev_int1 = flanco((eicra >> 2) & 0x03,
                                    (syn_d >> 3) & 1, (prv_d >> 3) & 1);
        const bool ev_pc0 = ((syn_b ^ prv_b) & pcmsk0) != 0;
        const bool ev_pc1 = ((syn_c ^ prv_c) & pcmsk1) != 0;
        const bool ev_pc2 = ((syn_d ^ prv_d) & pcmsk2) != 0;

        if (we) {
            switch (addr) {
                case A_EICRA:  eicra  = (uint8_t)(wdata & 0x0F); break;
                case A_EIMSK:  eimsk  = (uint8_t)(wdata & 0x03); break;
                case A_PCICR:  pcicr  = (uint8_t)(wdata & 0x07); break;
                case A_PCMSK0: pcmsk0 = wdata; break;
                case A_PCMSK1: pcmsk1 = (uint8_t)(wdata & 0x7F); break;  // sin PC7
                case A_PCMSK2: pcmsk2 = wdata; break;
                default: break;
            }
        }
        const bool w_eifr  = we && addr == A_EIFR;
        const bool w_pcifr = we && addr == A_PCIFR;

        // Poner gana a limpiar: un flanco en el mismo ciclo en que el programa
        // escribe el uno NO se pierde.
        auto bandera = [](uint8_t &reg, int bit, bool ev, bool limpia) {
            if (ev)           reg |=  (uint8_t)(1u << bit);
            else if (limpia)  reg &= (uint8_t)~(1u << bit);
        };
        bandera(eifr, 0, ev_int0, ack_int0 || (w_eifr && (wdata & 0x01)));
        bandera(eifr, 1, ev_int1, ack_int1 || (w_eifr && (wdata & 0x02)));
        bandera(pcifr, 0, ev_pc0, ack_pc0 || (w_pcifr && (wdata & 0x01)));
        bandera(pcifr, 1, ev_pc1, ack_pc1 || (w_pcifr && (wdata & 0x02)));
        bandera(pcifr, 2, ev_pc2, ack_pc2 || (w_pcifr && (wdata & 0x04)));

        syn_b = n_syn_b; syn_c = n_syn_c; syn_d = n_syn_d;
        prv_b = n_prv_b; prv_c = n_prv_c; prv_d = n_prv_d;
    }
};

static Model mdl;
static long  t = 0;

// Un ciclo del banco: se ponen las entradas, se comparan las salidas ANTES del
// flanco —son combinacionales— y luego se avanza el reloj.
static void paso(uint8_t pb, uint8_t pc, uint8_t pd,
                 bool we = false, uint8_t addr = 0, uint8_t wdata = 0,
                 uint8_t ack = 0) {
    dut->pin_b = pb; dut->pin_c = (uint8_t)(pc & 0x7F); dut->pin_d = pd;
    dut->io_we = we; dut->io_addr = addr; dut->io_wdata = wdata;
    dut->io_re = 1;
    dut->ack_int0   = (ack >> 0) & 1;
    dut->ack_int1   = (ack >> 1) & 1;
    dut->ack_pcint0 = (ack >> 2) & 1;
    dut->ack_pcint1 = (ack >> 3) & 1;
    dut->ack_pcint2 = (ack >> 4) & 1;
    dut->eval();

    if (dut->io_sel) chk("lectura", dut->io_rdata, mdl.lee(addr), t);
    chk("peticion INT0",   dut->irq_int0,   mdl.int0(),   t);
    chk("peticion INT1",   dut->irq_int1,   mdl.int1(),   t);
    chk("peticion PCINT0", dut->irq_pcint0, mdl.pcint(0), t);
    chk("peticion PCINT1", dut->irq_pcint1, mdl.pcint(1), t);
    chk("peticion PCINT2", dut->irq_pcint2, mdl.pcint(2), t);

    mdl.cycle(pb, (uint8_t)(pc & 0x7F), pd, we, addr, wdata,
              (ack >> 0) & 1, (ack >> 1) & 1, (ack >> 2) & 1,
              (ack >> 3) & 1, (ack >> 4) & 1);

    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    t++;
}

static void escribe(uint8_t addr, uint8_t dato, uint8_t pd = 0xFF) {
    paso(0x00, 0x00, pd, true, addr, dato);
}

// Lee un registro del DUT sin avanzar el reloj, para las comprobaciones
// dirigidas que quieren mirar una bandera en un instante concreto.
static uint8_t mira(uint8_t addr) {
    dut->io_we = 0; dut->io_addr = addr; dut->io_re = 1; dut->eval();
    return dut->io_rdata;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_extint;

    dut->rst_n = 0; dut->clk = 0;
    dut->pin_b = 0; dut->pin_c = 0; dut->pin_d = 0;
    dut->io_we = 0; dut->io_re = 0; dut->io_addr = 0; dut->io_wdata = 0;
    dut->ack_int0 = dut->ack_int1 = 0;
    dut->ack_pcint0 = dut->ack_pcint1 = dut->ack_pcint2 = 0;
    dut->eval();
    for (int i = 0; i < 4; i++) { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }
    dut->rst_n = 1; dut->eval();

    printf("\033[1mInterrupciones externas contra la hoja de datos\033[0m\n");

    // ------------------------------------------------- 1. los cuatro modos
    // Para cada ISC, se mete una subida y una bajada en INT0 y se mira si la
    // bandera se puso. El pin arranca alto porque el sincronizador tarda dos
    // ciclos en llenarse y no se quiere contar ese arranque como flanco.
    const char *nombre[4] = {"nivel bajo", "cualquier flanco",
                             "flanco de bajada", "flanco de subida"};
    const bool esperado_bajada[4] = {false, true,  true,  false};
    const bool esperado_subida[4] = {false, true,  false, true };

    for (int isc = 0; isc < 4; isc++) {
        escribe(A_EIMSK, 0x00, 0xFF);          // sin vector: sólo la bandera
        escribe(A_EICRA, (uint8_t)isc, 0xFF);
        for (int i = 0; i < 4; i++) paso(0, 0, 0xFF);
        escribe(A_EIFR, 0x03, 0xFF);
        for (int i = 0; i < 3; i++) paso(0, 0, 0xFF);

        for (int i = 0; i < 4; i++) paso(0, 0, 0xFB);   // PD2 a cero: bajada
        bool vio_bajada = (mira(A_EIFR) & 0x01) != 0;
        checks++;
        if (vio_bajada != esperado_bajada[isc]) {
            printf("    FALLA ISC=%d (%s): la bajada %s la bandera\n",
                   isc, nombre[isc], vio_bajada ? "puso" : "NO puso");
            fails++;
        }

        escribe(A_EIFR, 0x03, 0xFB);
        for (int i = 0; i < 3; i++) paso(0, 0, 0xFB);
        for (int i = 0; i < 4; i++) paso(0, 0, 0xFF);   // PD2 a uno: subida
        bool vio_subida = (mira(A_EIFR) & 0x01) != 0;
        checks++;
        if (vio_subida != esperado_subida[isc]) {
            printf("    FALLA ISC=%d (%s): la subida %s la bandera\n",
                   isc, nombre[isc], vio_subida ? "puso" : "NO puso");
            fails++;
        }
    }
    printf("  los cuatro modos de ISC0 detectan lo que les toca\n");

    // ------------------------------------------- 2. nivel bajo: sin bandera
    // La petición se mantiene MIENTRAS el pin esté bajo, y `INTF0` se lee
    // siempre a cero. Es la diferencia que hace que una ISR de nivel bajo que
    // no quite la causa se vuelva a entrar para siempre — en el chip también.
    escribe(A_EICRA, 0x00, 0xFF);
    escribe(A_EIMSK, 0x01, 0xFF);
    for (int i = 0; i < 3; i++) paso(0, 0, 0xFF);
    chk("nivel alto: sin peticion", dut->irq_int0, 0, t);

    long ciclos_pidiendo = 0;
    for (int i = 0; i < 20; i++) {
        paso(0, 0, 0xFB);
        if (dut->irq_int0) ciclos_pidiendo++;
        checks++;
        if (mira(A_EIFR) & 0x01) {
            printf("    FALLA: en modo de nivel bajo INTF0 se lee a uno\n");
            fails++;
            break;
        }
    }
    checks++;
    if (ciclos_pidiendo < 15) {
        printf("    FALLA: el nivel bajo no sostiene la peticion "
               "(%ld ciclos de 20)\n", ciclos_pidiendo);
        fails++;
    }
    // Y un reconocimiento NO la calla: no hay bandera que limpiar.
    paso(0, 0, 0xFB, false, 0, 0, 0x01);
    paso(0, 0, 0xFB);
    chk("el ack no calla el nivel bajo", dut->irq_int0, 1, t);
    for (int i = 0; i < 3; i++) paso(0, 0, 0xFF);
    chk("al subir el pin, se calla", dut->irq_int0, 0, t);
    printf("  el nivel bajo sostiene la peticion y no deja bandera\n");

    // --------------------------- 3. la bandera se pone con EIMSK deshabilitado
    escribe(A_EIMSK, 0x00, 0xFF);
    escribe(A_EICRA, 0x02, 0xFF);              // INT0 por flanco de bajada
    escribe(A_EIFR,  0x03, 0xFF);
    for (int i = 0; i < 3; i++) paso(0, 0, 0xFF);
    for (int i = 0; i < 3; i++) paso(0, 0, 0xFB);
    checks++;
    if (!(mira(A_EIFR) & 0x01)) {
        printf("    FALLA: con EIMSK a cero el flanco no marca INTF0 "
               "(el sondeo sin interrupciones no funcionaria)\n");
        fails++;
    }
    chk("pero no hay peticion", dut->irq_int0, 0, t);

    // Escribir un CERO no limpia; escribir un UNO sí.
    escribe(A_EIFR, 0x00, 0xFB);
    paso(0, 0, 0xFB);
    checks++;
    if (!(mira(A_EIFR) & 0x01)) {
        printf("    FALLA: escribir un cero en EIFR limpio la bandera\n");
        fails++;
    }
    escribe(A_EIFR, 0x01, 0xFB);
    paso(0, 0, 0xFB);
    checks++;
    if (mira(A_EIFR) & 0x01) {
        printf("    FALLA: escribir un uno en EIFR no limpio la bandera\n");
        fails++;
    }
    printf("  la bandera se pone aunque el vector este deshabilitado, "
           "y se limpia escribiendo un uno\n");

    // ------------------------------------ 4. PCINT: la mascara filtra tambien
    escribe(A_PCICR,  0x01, 0xFF);
    escribe(A_PCMSK0, 0x01, 0xFF);             // sólo PB0
    escribe(A_PCIFR,  0x07, 0xFF);
    for (int i = 0; i < 3; i++) paso(0x00, 0, 0xFF);

    for (int i = 0; i < 3; i++) paso(0x02, 0, 0xFF);   // cambia PB1, no enmascarado
    checks++;
    if (mira(A_PCIFR) & 0x01) {
        printf("    FALLA: un pin fuera de PCMSK0 marco PCIF0\n");
        fails++;
    }
    for (int i = 0; i < 3; i++) paso(0x03, 0, 0xFF);   // cambia PB0, enmascarado
    checks++;
    if (!(mira(A_PCIFR) & 0x01)) {
        printf("    FALLA: un pin de PCMSK0 no marco PCIF0\n");
        fails++;
    }
    chk("y hay peticion", dut->irq_pcint0, 1, t);

    // PCICR sólo filtra el vector: la bandera se pone igual.
    escribe(A_PCICR, 0x00, 0xFF);
    escribe(A_PCIFR, 0x07, 0xFF);
    for (int i = 0; i < 3; i++) paso(0x03, 0, 0xFF);
    for (int i = 0; i < 3; i++) paso(0x02, 0, 0xFF);
    checks++;
    if (!(mira(A_PCIFR) & 0x01)) {
        printf("    FALLA: con PCICR a cero el cambio no marca PCIF0\n");
        fails++;
    }
    chk("pero sin peticion", dut->irq_pcint0, 0, t);

    // PC7 no existe: su bit de PCMSK1 no se guarda.
    escribe(A_PCMSK1, 0xFF, 0xFF);
    paso(0, 0, 0xFF);
    chk("PCMSK1 sin PC7", mira(A_PCMSK1), 0x7F, t);
    printf("  PCMSKn filtra la bandera y PCICR solo el vector\n");

    // ------------------------------------------- 5. el reconocimiento limpia
    escribe(A_PCICR,  0x07, 0xFF);
    escribe(A_PCMSK0, 0xFF, 0xFF);
    escribe(A_PCIFR,  0x07, 0xFF);
    for (int i = 0; i < 3; i++) paso(0x00, 0, 0xFF);
    for (int i = 0; i < 3; i++) paso(0xAA, 0, 0xFF);
    chk("PCINT0 pide", dut->irq_pcint0, 1, t);
    paso(0xAA, 0, 0xFF, false, 0, 0, 0x04);          // ack de PCINT0
    paso(0xAA, 0, 0xFF);
    chk("el ack limpio PCIF0", dut->irq_pcint0, 0, t);
    printf("  atender el vector limpia la bandera en su origen\n");

    // ------------------------------------------------- 6. regresion aleatoria
    // Pines que se mueven solos y escrituras a los ocho registros, con
    // reconocimientos sueltos. Cada ciclo se comparan las cinco peticiones y la
    // lectura del registro que toque.
    std::mt19937 rng(20260911);
    const uint8_t REGS[8] = {A_PCIFR, A_EIFR, A_EIMSK, A_PCICR,
                             A_EICRA, A_PCMSK0, A_PCMSK1, A_PCMSK2};
    uint8_t pb = 0, pc = 0, pd = 0xFF;
    const long N = 400000;
    for (long i = 0; i < N; i++) {
        // Los pines cambian poco: un flanco cada muchos ciclos es lo que pasa
        // de verdad, y así se ejercita el caso de «nada cambia» que es donde
        // una bandera pegada se notaría.
        if ((rng() & 0x0F) == 0) pb ^= (uint8_t)(1u << (rng() % 8));
        if ((rng() & 0x1F) == 0) pc ^= (uint8_t)(1u << (rng() % 7));
        if ((rng() & 0x0F) == 0) pd ^= (uint8_t)(1u << (rng() % 8));

        bool we = (rng() & 0x07) == 0;
        uint8_t addr = REGS[rng() % 8];
        uint8_t dato = (uint8_t)rng();
        uint8_t ack  = ((rng() & 0x3F) == 0) ? (uint8_t)(1u << (rng() % 5)) : 0;
        paso(pb, pc, pd, we, addr, dato, ack);

        // Una lectura de cada registro de vez en cuando, sin escribir.
        if ((rng() & 0x03) == 0) {
            uint8_t r = REGS[rng() % 8];
            chk("lectura aleatoria", mira(r), mdl.lee(r), t);
        }
        if (fails > 12) break;
    }

    delete dut;
    printf("  %ld comprobaciones en %ld ciclos\n", checks, t);
    if (fails) {
        printf("  \033[0;31m%d fallos\033[0m — el modelo sale de la hoja de "
               "datos, no del RTL\n", fails);
        return 1;
    }
    printf("  INT0/INT1 y los tres PCINT coinciden con la hoja de datos\n");
    return 0;
}
