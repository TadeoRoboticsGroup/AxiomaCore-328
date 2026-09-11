// AxiomaCore-328 - controlador de interrupciones, EXHAUSTIVO
// SPDX-License-Identifier: Apache-2.0
//
// El espacio de entrada de este módulo es enumerable entero: 26 peticiones son
// 67 108 864 combinaciones. Igual que con el fabric del espacio de datos, se
// barre completo en vez de muestrear, porque se puede.
//
// Lo que se comprueba en cada combinación:
//   - si hay petición o no, ignorando el bit 0, que es RESET y no interrumpe;
//   - qué vector gana: SIEMPRE el número más bajo, que es la prioridad fija
//     del AVR;
//   - a quién vuelve el reconocimiento: sólo al que gana, para que una segunda
//     petición simultánea siga pendiente al salir de la primera.
//
// El modelo son tres líneas de C, y esa es la gracia: la especificación de la
// prioridad del AVR cabe en tres líneas, así que cualquier diferencia con el
// RTL es un fallo del RTL.

#include "Vaxioma_irq.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Vaxioma_irq *dut = new Vaxioma_irq;

    long fails = 0, checks = 0;

    for (uint32_t s = 0; s < (1u << 26); s++) {
        // Se alterna el reconocimiento con la propia combinación, de modo que
        // las dos ramas se recorren sobre todo el espacio.
        bool ackin = (s & 1) != 0;

        dut->src = s;
        dut->irq_ack = ackin;
        dut->eval();

        uint32_t pend = s & ~1u;                 // el bit 0 es RESET
        bool     exp_req = pend != 0;
        uint32_t exp_vec = 0;
        if (exp_req) exp_vec = (uint32_t)__builtin_ctz(pend);
        uint32_t exp_ack = (ackin && exp_req) ? (1u << exp_vec) : 0u;

        checks += 3;
        if (dut->irq_req != (exp_req ? 1 : 0) ||
            (exp_req && dut->irq_vector != exp_vec) ||
            dut->ack != exp_ack) {
            if (++fails <= 8)
                printf("    FALLA src=0x%07X ack_in=%d  req=%d/%d vec=%d/%d "
                       "ack=0x%07X/0x%07X\n", s, ackin,
                       dut->irq_req, exp_req ? 1 : 0,
                       dut->irq_vector, exp_vec,
                       (uint32_t)dut->ack, exp_ack);
        }
    }

    delete dut;
    printf("  %ld comprobaciones sobre las 67 108 864 combinaciones, %ld fallos\n",
           checks, fails);
    return fails ? 1 : 0;
}
