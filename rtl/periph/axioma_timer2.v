// AxiomaCore-328 - Timer/Counter2, 8 bits, con prescaler propio y modo asíncrono
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El tercer temporizador. Es el que usa `tone()` del core de Arduino, y el que
// usa cualquier sketch de bajo consumo para despertar del sueño con un cristal
// de reloj de 32,768 kHz.
//
//   TCCR2A  dato 0xB0   COM2A1 COM2A0 COM2B1 COM2B0  -  -  WGM21 WGM20
//   TCCR2B  dato 0xB1   FOC2A  FOC2B   -      -     WGM22 CS22 CS21 CS20
//   TCNT2   dato 0xB2   cuenta
//   OCR2A   dato 0xB3   comparación A (y TOP en los modos 2, 5 y 7)
//   OCR2B   dato 0xB4   comparación B
//   ASSR    dato 0xB6    -  EXCLK AS2 TCN2UB OCR2AUB OCR2BUB TCR2AUB TCR2BUB
//   TIMSK2  dato 0x70   - - - - -  OCIE2B OCIE2A TOIE2
//   TIFR2   I/O  0x17   - - - - -  OCF2B  OCF2A  TOV2     (se limpia con un 1)
//
// LA MÁQUINA DE FORMA DE ONDA ES LA MISMA que la del Timer0, palabra por
// palabra en la hoja de datos, así que está una sola vez: `axioma_timer8`. Aquí
// queda lo que SÍ es distinto, que es justo lo que lo hace el Timer2:
//
//   PRESCALER PROPIO. No comparte el contador del Timer0 y el Timer1. Y tiene
//   dos tomas que ellos no tienen:
//
//       CS2 = 0 parado · 1 clk/1 · 2 clk/8 · 3 clk/32 · 4 clk/64
//             5 clk/128 · 6 clk/256 · 7 clk/1024
//
//   Las tomas /32 y /128 existen porque este temporizador está pensado para
//   dividir 32 768 Hz y dar un segundo exacto: 32768/128 = 256, que es
//   justamente un desbordamiento de 8 bits.
//
//   NO TIENE ENTRADA DE RELOJ EXTERNO. Donde el Timer0 pone T0, el Timer2 pone
//   el oscilador de reloj: CS2 = 6 y 7 son divisiones, no pines.
//
//   LO PONE A CERO GTCCR.PSRASY, no PSRSYNC. El bit vive en `axioma_prescaler`
//   —es el mismo registro GTCCR— y llega aquí por `presc_reset`.
//
// MODO ASÍNCRONO. Con `ASSR.AS2` a uno el temporizador deja de contar el reloj
// del sistema y cuenta el oscilador de TOSC1 (PB6), que en el chip es un
// cristal de 32,768 kHz. `EXCLK` cambia el cristal por un reloj externo
// metido por el mismo pin.
//
// CÓMO SE IMPLEMENTA AQUÍ, Y QUÉ SE APARTA DE LA HOJA DE DATOS. En el chip, con
// AS2 puesto, TODO el temporizador pasa a la otra frecuencia y por eso existen
// los cinco bits de ocupado —TCN2UB, OCR2AUB, OCR2BUB, TCR2AUB, TCR2BUB—: una
// escritura tarda hasta un ciclo del cristal en cruzar, y el programa tiene que
// esperar a que el bit se limpie. Aquí el temporizador sigue viviendo en el
// dominio del reloj del sistema y lo que se cuenta son los FLANCOS DE SUBIDA de
// TOSC1, sincronizados con dos biestables. Consecuencias, dichas sin adornos:
//
//   - La cuenta y las banderas salen igual, porque lo que manda es cuántos
//     flancos de TOSC1 han pasado.
//   - Las escrituras son INMEDIATAS, así que los cinco bits de ocupado se leen
//     siempre a cero. Un programa que haga `while (ASSR & (1<<TCN2UB));` sale
//     del bucle a la primera, y sale con la escritura ya hecha: lo que el
//     programa quería garantizar se cumple. Es una diferencia observable, pero
//     no de las que hacen funcionar aquí código que en el chip falla.
//   - Un dominio de reloj de verdad, con los bits de ocupado reales, es trabajo
//     de la fase 5 y hace falta verificación formal para cerrarlo. Está
//     apuntado como deuda D10 en docs/06-deuda-tecnica.md.
//
// SIN CRISTAL NO CUENTA, que es lo que hace el chip. Si un programa pone AS2 en
// una placa que no tiene el cristal de 32 kHz —la ULX3S no lo tiene, y un
// Arduino Uno tampoco—, TOSC1 no se mueve y el temporizador se para. Modelarlo
// al revés —seguir contando el reloj del sistema— haría que un sketch de RTC
// pareciera funcionar aquí y no funcionara en la placa.

`default_nettype none

module axioma_timer2 (
    input  wire       clk,
    input  wire       rst_n,

    // La habilitacion de reloj: un pulso por ciclo de sistema (ADR 0003).
    // Con CLKPS=0 vale 1 siempre y este modulo se comporta como antes.
    input  wire       ce,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- puesta a cero del prescaler: GTCCR.PSRASY ----
    input  wire       presc_reset,

    // ---- oscilador de TOSC1 (PB6), para el modo asíncrono ----
    input  wire       tosc,

    // ---- salidas de comparación OC2A (PB3) y OC2B (PD3) ----
    output wire       oc2a,
    output wire       oc2a_en,
    output wire       oc2b,
    output wire       oc2b_en,

    // ---- interrupciones ----
    output wire       irq_ovf,
    output wire       irq_compa,
    output wire       irq_compb,
    input  wire       ack_ovf,
    input  wire       ack_compa,
    input  wire       ack_compb
);

    // Direcciones de I/O = dirección del espacio de datos menos 0x20.
    localparam [7:0] A_TIFR2  = 8'h17;
    localparam [7:0] A_TIMSK2 = 8'h50;
    localparam [7:0] A_TCCR2A = 8'h90;
    localparam [7:0] A_TCCR2B = 8'h91;
    localparam [7:0] A_TCNT2  = 8'h92;
    localparam [7:0] A_OCR2A  = 8'h93;
    localparam [7:0] A_OCR2B  = 8'h94;
    localparam [7:0] A_ASSR   = 8'h96;

    wire hit_tifr  = (io_addr == A_TIFR2);
    wire hit_timsk = (io_addr == A_TIMSK2);
    wire hit_tccra = (io_addr == A_TCCR2A);
    wire hit_tccrb = (io_addr == A_TCCR2B);
    wire hit_tcnt  = (io_addr == A_TCNT2);
    wire hit_ocra  = (io_addr == A_OCR2A);
    wire hit_ocrb  = (io_addr == A_OCR2B);
    wire hit_assr  = (io_addr == A_ASSR);

    assign io_sel = hit_tifr | hit_timsk | hit_tccra | hit_tccrb
                  | hit_tcnt | hit_ocra  | hit_ocrb  | hit_assr;

    // Ningún registro de este temporizador tiene efecto lateral de LECTURA.
    wire unused_io_re = &{1'b0, io_re};

    // -------------------------------------------------------------- ASSR
    reg as2_q, exclk_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            as2_q   <= 1'b0;
            exclk_q <= 1'b0;
        end else if (ce && io_we && hit_assr) begin
            exclk_q <= io_wdata[6];
            as2_q   <= io_wdata[5];
        end
    end

    // TOSC1 es asíncrono de verdad: dos biestables de sincronización y detector
    // de flanco, igual que el pin T0 del Timer0. Con EXCLK el pin trae un reloj
    // en vez de un cristal, y eso no cambia nada de este lado: lo que se cuenta
    // son sus flancos de subida en los dos casos.
    reg [2:0] tosc_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)  tosc_sync <= 3'b000;
        else if (ce) tosc_sync <= {tosc_sync[1:0], tosc};
    end
    wire tosc_rise = (tosc_sync[2:1] == 2'b01);

    // --------------------------------------------------- prescaler propio
    // La fuente: el reloj del sistema, o un flanco de TOSC1 en asíncrono. Sin
    // cristal conectado, en asíncrono no llega ninguno y el temporizador se
    // para, que es lo que hace el chip.
    wire src = as2_q ? tosc_rise : 1'b1;

    reg [9:0] pcnt;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)           pcnt <= 10'd0;
        else if (ce) begin
            if      (presc_reset) pcnt <= 10'd0;
            else if (src)         pcnt <= pcnt + 10'd1;
        end
    end

    // Una toma da un pulso cuando los bits bajos están todos a uno, es decir
    // JUSTO ANTES de que el bit de la toma cambie: así el temporizador cuenta
    // una vez cada N fuentes exactas. Mismo criterio que el prescaler síncrono.
    wire tk_1    = src;
    wire tk_8    = src && (pcnt[2:0] == 3'b111)    && !presc_reset;
    wire tk_32   = src && (pcnt[4:0] == 5'h1F)     && !presc_reset;
    wire tk_64   = src && (pcnt[5:0] == 6'h3F)     && !presc_reset;
    wire tk_128  = src && (pcnt[6:0] == 7'h7F)     && !presc_reset;
    wire tk_256  = src && (pcnt[7:0] == 8'hFF)     && !presc_reset;
    wire tk_1024 = src && (pcnt[9:0] == 10'h3FF)   && !presc_reset;

    reg [2:0] cs_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                  cs_q <= 3'h0;
        else if (ce && io_we && hit_tccrb) cs_q <= io_wdata[2:0];
    end

    reg ck;
    always @(*) begin
        case (cs_q)
            3'd0:    ck = 1'b0;          // parado
            3'd1:    ck = tk_1;
            3'd2:    ck = tk_8;
            3'd3:    ck = tk_32;
            3'd4:    ck = tk_64;
            3'd5:    ck = tk_128;
            3'd6:    ck = tk_256;
            default: ck = tk_1024;
        endcase
    end

    // ------------------------------------------------------------ el motor
    wire [3:0] com;
    wire [2:0] wgm, timsk, tifr;
    wire [7:0] tcnt, ocra, ocrb;

    axioma_timer8 motor (
        .clk(clk), .rst_n(rst_n), .ce(ce), .ck(ck),
        .wdata(io_wdata),
        .we_tccra(io_we & hit_tccra), .we_tccrb(io_we & hit_tccrb),
        .we_tcnt (io_we & hit_tcnt),  .we_ocra (io_we & hit_ocra),
        .we_ocrb (io_we & hit_ocrb),  .we_timsk(io_we & hit_timsk),
        .we_tifr (io_we & hit_tifr),
        .com(com), .wgm(wgm), .tcnt(tcnt), .ocra(ocra), .ocrb(ocrb),
        .timsk(timsk), .tifr(tifr),
        .oca(oc2a), .oca_en(oc2a_en), .ocb(oc2b), .ocb_en(oc2b_en),
        .irq_ovf(irq_ovf), .irq_compa(irq_compa), .irq_compb(irq_compb),
        .ack_ovf(ack_ovf), .ack_compa(ack_compa), .ack_compb(ack_compb)
    );

    // ------------------------------------------------------------- lectura
    // Los cinco bits de ocupado de ASSR se leen SIEMPRE a cero, y en modo
    // síncrono eso es exactamente lo que dice la hoja de datos: las escrituras
    // son inmediatas y no hay nada que esperar. En asíncrono es la diferencia
    // declarada arriba.
    assign io_rdata = hit_tifr  ? {5'b00000, tifr}              :
                      hit_timsk ? {5'b00000, timsk}             :
                      hit_tccra ? {com, 2'b00, wgm[1:0]}        :
                      hit_tccrb ? {2'b00, 2'b00, wgm[2], cs_q}  :
                      hit_tcnt  ? tcnt                          :
                      hit_ocra  ? ocra                          :
                      hit_ocrb  ? ocrb                          :
                      hit_assr  ? {1'b0, exclk_q, as2_q, 5'b00000} : 8'h00;

endmodule

`default_nettype wire
