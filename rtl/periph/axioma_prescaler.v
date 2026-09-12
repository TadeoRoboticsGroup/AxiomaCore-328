// AxiomaCore-328 - prescaler compartido de los temporizadores síncronos
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// LA TRAMPA Nº 12 DEL ISA VIVE AQUÍ. El prescaler NO es del Timer0: es un
// contador de 10 bits LIBRE Y COMPARTIDO entre Timer0 y Timer1, que corre
// desde el reset y al que cada temporizador se engancha eligiendo una toma con
// sus bits CS. Consecuencias que rompen código real si se modela mal:
//
//   - Arrancar el Timer0 con CS=/64 NO pone el prescaler a cero. La primera
//     cuenta llega cuando al contador compartido le toca, entre 1 y 64 ciclos
//     después. El desfase es observable y no es un error.
//   - Reconfigurar el Timer1 afecta a la fase del Timer0 si alguien resetea el
//     prescaler, porque es el MISMO contador.
//   - Lo único que lo pone a cero es GTCCR.PSRSYNC.
//
// SE APARTA DE simavr A PROPÓSITO. `avr_timer_write` de simavr llama a
// `avr_timer_reconfigure(p, 1)` cada vez que cambian los bits CS, y eso ancla
// su base de cuenta en el ciclo de la escritura: en simavr el prescaler SÍ se
// reinicia al arrancar el temporizador, y cada temporizador tiene el suyo.
// GTCCR no lo modela en absoluto. Manda la hoja de datos.
// Ver docs/01-arquitectura.md §8bis.
//
// GTCCR (I/O 0x23):  TSM - - - - - PSRASY PSRSYNC
//
//   PSRSYNC  escribir 1 pone a cero este contador.
//   TSM      mantiene el valor escrito en PSRSYNC/PSRASY en vez de dejar que
//            el hardware los limpie, con lo que el prescaler se queda EN RESET
//            y los temporizadores se pueden configurar sin que avancen. Al
//            escribir TSM a 0 el hardware limpia los dos y arrancan a la vez.
//   PSRASY   pone a cero el prescaler del Timer2, que es OTRO contador y vive
//            dentro de `axioma_timer2` porque en modo asíncrono lo cuenta un
//            reloj distinto. Aquí está el bit, porque está en GTCCR; la señal
//            sale por `reset_asy` y TSM la retiene igual que a la síncrona.
//
// CUESTIÓN ABIERTA - la toma de clk/1. La figura «Prescaler for Timer/Counter0
// and Timer/Counter1» de la hoja de datos saca clk_I/O directamente, sin pasar
// por el contador, así que TSM no debería detener a un temporizador con
// CS=001. Se implementa esa lectura literal: `tick_1` no lo afecta ni PSRSYNC
// ni TSM. Anotado en docs/01-arquitectura.md §8bis.

`default_nettype none

module axioma_prescaler (
    input  wire       clk,
    input  wire       rst_n,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- tomas: un pulso de un ciclo cada N ciclos de clk_I/O ----
    output wire       tick_1,
    output wire       tick_8,
    output wire       tick_64,
    output wire       tick_256,
    output wire       tick_1024,

    // Puesta a cero del prescaler del Timer2 (GTCCR.PSRASY). El contador no
    // está aquí —lo cuenta otro reloj cuando el Timer2 va en asíncrono— pero el
    // bit sí, así que la orden sale de este módulo.
    output wire       reset_asy,

    // Estado del contador, para el banco.
    output wire [9:0] count
);

    localparam [7:0] A_GTCCR = 8'h23;

    wire hit = (io_addr == A_GTCCR);
    assign io_sel = hit;

    // Sin efectos laterales de lectura; el puerto es parte del contrato.
    // De GTCCR sólo existen tres bits: el resto se declara sin usar a
    // propósito, y se lee como cero.
    wire unused = &{1'b0, io_re, io_wdata[6:2]};

    reg [9:0] cnt;
    reg       tsm_q, psrasy_q, psrsync_q;

    // El reset del contador es el valor de PSRSYNC de ESTE ciclo: el que se
    // acaba de escribir si hay escritura, y el retenido si no. Escrito así,
    // una escritura de PSRSYNC=1 pone el contador a cero en el mismo flanco,
    // sin el ciclo de retraso que tendría mirando sólo al registro.
    wire psr_now = (io_we && hit) ? io_wdata[0] : psrsync_q;
    // Lo mismo para la asíncrona: vale en el mismo flanco de la escritura.
    wire psa_now = (io_we && hit) ? io_wdata[1] : psrasy_q;
    assign reset_asy = psa_now;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt       <= 10'd0;
            tsm_q     <= 1'b0;
            psrasy_q  <= 1'b0;
            psrsync_q <= 1'b0;
        end else begin
            if (io_we && hit) begin
                // «This bit is normally cleared immediately by hardware,
                // except if the TSM bit is set»: sin TSM, escribir PSRSYNC
                // dispara el reset del prescaler pero el bit NO se queda, ni
                // siquiera un ciclo. Con TSM puesto sí se retiene, y es lo que
                // mantiene el prescaler parado durante la configuración.
                tsm_q     <= io_wdata[7];
                psrasy_q  <= io_wdata[7] & io_wdata[1];
                psrsync_q <= io_wdata[7] & io_wdata[0];
            end else if (!tsm_q) begin
                psrasy_q  <= 1'b0;
                psrsync_q <= 1'b0;
            end

            cnt <= psr_now ? 10'd0 : (cnt + 10'd1);
        end
    end

    assign io_rdata = hit ? {tsm_q, 5'b00000, psrasy_q, psrsync_q} : 8'h00;

    // Una toma da un pulso en el ciclo en el que los bits bajos están todos a
    // uno, es decir, JUSTO ANTES de que el bit de la toma cambie de valor: así
    // el temporizador cuenta una vez cada N ciclos exactos y la primera cuenta
    // tras un PSRSYNC llega N ciclos después, no antes.
    assign tick_1    = 1'b1;
    assign tick_8    = (cnt[2:0] == 3'b111)        && !psr_now;
    assign tick_64   = (cnt[5:0] == 6'b111111)     && !psr_now;
    assign tick_256  = (cnt[7:0] == 8'hFF)         && !psr_now;
    assign tick_1024 = (cnt[9:0] == 10'h3FF)       && !psr_now;

    assign count = cnt;

endmodule

`default_nettype wire
