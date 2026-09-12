// AxiomaCore-328 - modelo de referencia del motor de 8 bits, de la hoja de datos
// SPDX-License-Identifier: Apache-2.0
//
// El mismo motivo que `rtl/periph/axioma_timer8.v`: la hoja de datos describe
// la máquina de forma de onda del Timer0 y la del Timer2 con las mismas
// palabras, así que el modelo contra el que se comparan vive UNA SOLA VEZ. Si
// estuviera copiado en los dos bancos, dentro de un año uno tendría un arreglo
// que el otro no, y el banco dejaría de ser un oráculo para ser un espejo.
//
// Lo que NO está aquí es lo que cada temporizador tiene distinto: el prescaler
// —compartido y con GTCCR en el Timer0, propio y con dos tomas más en el
// Timer2—, la entrada de reloj externo T0 y el modo asíncrono. Eso lo modela
// cada banco, que es donde se diferencian.
//
// Está escrito desde la hoja de datos, no desde el RTL.

#ifndef AXIOMA_TIMER8_REF_H
#define AXIOMA_TIMER8_REF_H

#include <cstdint>

struct Timer8Ref {
    uint8_t com = 0;            // COMA1 COMA0 COMB1 COMB0
    uint8_t wgm = 0;            // WGM2 WGM1 WGM0
    uint8_t tcnt = 0;
    uint8_t ocra_act = 0, ocra_buf = 0;
    uint8_t ocrb_act = 0, ocrb_buf = 0;
    uint8_t timsk = 0, tifr = 0;
    bool dir_down = false;      // sólo en PWM de fase correcta
    bool tcnt_block = false;    // escribir TCNT tapa la comparación siguiente
    bool oca = false, ocb = false;

    bool pc()   const { return wgm == 1 || wgm == 5; }
    bool fast() const { return wgm == 3 || wgm == 7; }
    bool pwm()  const { return pc() || fast(); }
    uint8_t top() const { return (wgm == 2 || wgm == 5 || wgm == 7) ? ocra_act : 0xFF; }

    uint8_t com_a() const { return (com >> 2) & 3; }
    uint8_t com_b() const { return com & 3; }

    // Tabla de COM de la hoja de datos: con qué combinaciones se adueña el
    // temporizador del pin. COM=1 en PWM sólo vale para el canal A y sólo con
    // WGM2=1; para el B está reservado.
    bool oca_en() const { return com_a() != 0 && !(pwm() && com_a() == 1 && !(wgm & 4)); }
    bool ocb_en() const { return com_b() != 0 && !(pwm() && com_b() == 1); }

    // Lo que se lee de cada registro. Las direcciones las pone cada banco.
    uint8_t rd_tccra() const { return (uint8_t)((com << 4) | (wgm & 3)); }
    uint8_t rd_tcnt()  const { return tcnt; }
    uint8_t rd_ocra()  const { return ocra_buf; }     // el búfer, no el activo
    uint8_t rd_ocrb()  const { return ocrb_buf; }
    uint8_t rd_timsk() const { return (uint8_t)(timsk & 7); }
    uint8_t rd_tifr()  const { return (uint8_t)(tifr & 7); }

    bool irq_ovf()   const { return (tifr & timsk & 1) != 0; }
    bool irq_compa() const { return (tifr & timsk & 2) != 0; }
    bool irq_compb() const { return (tifr & timsk & 4) != 0; }

    // Qué escritura llega este ciclo, ya decodificada por el banco.
    struct Escritura {
        bool tccra = false, tccrb = false, tcnt = false;
        bool ocra = false, ocrb = false, timsk = false, tifr = false;
        uint8_t d = 0;
    };

    // UN CICLO DEL MOTOR. `ck` vale uno cuando al temporizador le toca contar;
    // lo decide el selector de reloj de cada banco.
    void cycle(bool ck, const Escritura &w,
               bool ack_ovf, bool ack_a, bool ack_b) {
        // ---- eventos, sobre el valor que TCNT tiene AHORA ----
        bool at_top    = (tcnt == top());
        bool at_max    = (tcnt == 0xFF);
        bool at_bottom = (tcnt == 0x00);

        bool ev_tov   = ck && (pc() ? (dir_down && at_bottom) : fast() ? at_top : at_max);
        bool ev_compa = ck && !tcnt_block && (tcnt == ocra_act);
        bool ev_compb = ck && !tcnt_block && (tcnt == ocrb_act);
        bool ev_upd   = ck && pwm() && at_top;

        // El pin de comparación se decide con el sentido que la cuenta traía
        // AL ENTRAR en este ciclo, no con el que deja al salir. Sólo se nota en
        // el modo 5, donde TOP es OCRA y la comparación cae exactamente en el
        // ciclo en que la cuenta da la vuelta.
        bool dir_prev = dir_down;

        // ---- cuenta ----
        if (ck) {
            if (pc()) {
                if (dir_down) {
                    if (at_bottom) { dir_down = false; tcnt = (top() == 0) ? 0 : 1; }
                    else             tcnt--;
                } else {
                    if (at_top)    { dir_down = true;  tcnt = (top() == 0) ? 0 : (uint8_t)(tcnt - 1); }
                    else             tcnt++;
                }
            } else {
                tcnt = at_top ? 0 : (uint8_t)(tcnt + 1);
            }
            tcnt_block = false;
        }

        if (ev_upd) { ocra_act = ocra_buf; ocrb_act = ocrb_buf; }

        // ---- pines de comparación ----
        // FOCA/FOCB: pulsos de escritura, sólo fuera de los modos PWM.
        bool foc_a = w.tccrb && (w.d & 0x80) && !pwm();
        bool foc_b = w.tccrb && (w.d & 0x40) && !pwm();

        if (!pwm()) {
            if (ev_compa || foc_a) {
                if      (com_a() == 1) oca = !oca;
                else if (com_a() == 2) oca = false;
                else if (com_a() == 3) oca = true;
            }
            if (ev_compb || foc_b) {
                if      (com_b() == 1) ocb = !ocb;
                else if (com_b() == 2) ocb = false;
                else if (com_b() == 3) ocb = true;
            }
        } else if (fast()) {
            if (ck && at_top) {          // el flanco de BOTTOM manda
                if (com_a() == 2) oca = true;
                if (com_a() == 3) oca = false;
                if (com_b() == 2) ocb = true;
                if (com_b() == 3) ocb = false;
            } else {
                if (ev_compa) {
                    if      (com_a() == 1) oca = !oca;
                    else if (com_a() == 2) oca = false;
                    else if (com_a() == 3) oca = true;
                }
                if (ev_compb) {
                    if      (com_b() == 2) ocb = false;
                    else if (com_b() == 3) ocb = true;
                }
            }
        } else {                          // fase correcta
            if (ev_compa) {
                if      (com_a() == 1) oca = !oca;
                else if (com_a() == 2) oca = dir_prev;
                else if (com_a() == 3) oca = !dir_prev;
            }
            if (ev_compb) {
                if      (com_b() == 2) ocb = dir_prev;
                else if (com_b() == 3) ocb = !dir_prev;
            }
        }

        // ---- banderas: el hardware gana a la limpieza ----
        if (ev_tov)                                     tifr |= 1;
        else if (ack_ovf || (w.tifr && (w.d & 1)))      tifr &= ~1;
        if (ev_compa)                                   tifr |= 2;
        else if (ack_a   || (w.tifr && (w.d & 2)))      tifr &= ~2;
        if (ev_compb)                                   tifr |= 4;
        else if (ack_b   || (w.tifr && (w.d & 4)))      tifr &= ~4;

        // ---- escrituras: mandan sobre la cuenta del mismo ciclo ----
        if (w.tccra) { com = (w.d >> 4) & 0xF; wgm = (uint8_t)((wgm & 4) | (w.d & 3)); }
        if (w.tccrb)   wgm = (uint8_t)((wgm & 3) | ((w.d & 8) ? 4 : 0));
        if (w.tcnt)  { tcnt = w.d; tcnt_block = true; }
        if (w.ocra)  { ocra_buf = w.d; if (!pwm()) ocra_act = w.d; }
        if (w.ocrb)  { ocrb_buf = w.d; if (!pwm()) ocrb_act = w.d; }
        if (w.timsk)   timsk = (uint8_t)(w.d & 7);
    }
};

#endif
