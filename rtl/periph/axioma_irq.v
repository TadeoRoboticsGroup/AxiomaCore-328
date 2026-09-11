// AxiomaCore-328 - controlador de interrupciones
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// 26 vectores con PRIORIDAD FIJA: gana el de número más bajo. No hay registro
// de prioridades, ni anidamiento automático, ni cola: el AVR es así de simple y
// cualquier cosa más elaborada sería incompatible.
//
//   0x0000 RESET          0x001A TIMER1_OVF
//   0x0002 INT0           0x001C TIMER0_COMPA
//   0x0004 INT1           0x001E TIMER0_COMPB
//   0x0006 PCINT0         0x0020 TIMER0_OVF
//   0x0008 PCINT1         0x0022 SPI_STC
//   0x000A PCINT2         0x0024 USART_RX
//   0x000C WDT            0x0026 USART_UDRE
//   0x000E TIMER2_COMPA   0x0028 USART_TX
//   0x0010 TIMER2_COMPB   0x002A ADC
//   0x0012 TIMER2_OVF     0x002C EE_READY
//   0x0014 TIMER1_CAPT    0x002E ANALOG_COMP
//   0x0016 TIMER1_COMPA   0x0030 TWI
//   0x0018 TIMER1_COMPB   0x0032 SPM_READY
//
// Las direcciones son de PALABRA y cada vector ocupa dos, porque en 32 KB de
// Flash el salto del vector es un JMP. El secuenciador hace la cuenta: el
// vector n está en la palabra 2n.
//
// LA PETICIÓN ES COMBINACIONAL, y tiene que serlo. La bandera de un periférico
// se puede limpiar por software entre que se levanta y que el núcleo llega a un
// hueco entre instrucciones; si aquí se registrara, se atendería un vector cuya
// causa ya no existe. El AVR permite exactamente eso: `TIFR0 = (1<<TOV0)` desde
// una sección crítica cancela la interrupción pendiente.
//
// EL RECONOCIMIENTO LIMPIA LA BANDERA EN SU ORIGEN. Cuando el núcleo salta al
// vector, el hardware del AVR limpia la bandera que lo provocó —por eso una ISR
// no tiene que escribir en TIFR—. Aquí se hace devolviendo un pulso al
// periférico que ganó la prioridad, y no a los demás: si hay dos pendientes, la
// segunda sigue pendiente y se atiende al salir de la primera.
//
// LO QUE NO ESTÁ AQUÍ. Que las interrupciones sólo se atiendan ENTRE
// instrucciones, el retardo de un ciclo de SEI y el `I` del SREG son del
// secuenciador: este módulo no sabe nada del núcleo, sólo ordena peticiones.

`default_nettype none

module axioma_irq (
    // Una entrada por vector. El bit 0 es RESET y no es una interrupción:
    // se ignora. Los vectores cuyo periférico todavía no existe se atan a cero
    // en el SoC y este módulo los trata como cualquier otro.
    input  wire [25:0] src,

    // ---- hacia el núcleo ----
    output wire        irq_req,
    output wire [4:0]  irq_vector,
    input  wire        irq_ack,

    // ---- de vuelta al periférico que ganó ----
    output wire [25:0] ack
);

    reg [4:0] vec;
    reg       any;
    integer   i;

    // Codificador de prioridad: el primer bit puesto desde el 1 hacia arriba.
    always @(*) begin
        vec = 5'd0;
        any = 1'b0;
        for (i = 25; i >= 1; i = i - 1)
            if (src[i]) begin
                vec = i[4:0];
                any = 1'b1;
            end
    end

    assign irq_req    = any;
    assign irq_vector = vec;

    // El pulso vuelve SÓLO al vector que se está atendiendo.
    genvar g;
    generate
        for (g = 0; g < 26; g = g + 1) begin : g_ack
            assign ack[g] = irq_ack && any && (vec == g[4:0]);
        end
    endgenerate

endmodule

`default_nettype wire
