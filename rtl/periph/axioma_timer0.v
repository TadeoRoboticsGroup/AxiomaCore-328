// AxiomaCore-328 - Timer/Counter0, 8 bits
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El temporizador del que cuelga `millis()`. El `delay()` de un Blink.ino
// compilado con el core de Arduino llama a `millis()`, que cuenta
// desbordamientos de este temporizador en su ISR: es el camino crítico del
// criterio de aceptación de la fase 2.
//
//   TCCR0A  I/O 0x24   COM0A1 COM0A0 COM0B1 COM0B0  -  -  WGM01 WGM00
//   TCCR0B  I/O 0x25   FOC0A  FOC0B   -      -     WGM02 CS02 CS01 CS00
//   TCNT0   I/O 0x26   cuenta
//   OCR0A   I/O 0x27   comparación A (y TOP en los modos 2, 5 y 7)
//   OCR0B   I/O 0x28   comparación B
//   TIMSK0  dato 0x6E  - - - - -  OCIE0B OCIE0A TOIE0
//   TIFR0   I/O 0x15   - - - - -  OCF0B  OCF0A  TOV0     (se limpia con un 1)
//
// EL RELOJ VIENE DE FUERA. El prescaler es compartido con el Timer1 y vive en
// `axioma_prescaler`; aquí sólo se elige la toma. Es la trampa nº 12: arrancar
// este temporizador NO pone el prescaler a cero.
//
// Y LA MÁQUINA DE FORMA DE ONDA TAMBIÉN ESTÁ FUERA: vive en `axioma_timer8`,
// porque la hoja de datos describe la del Timer0 y la del Timer2 con las mismas
// palabras. Aquí queda lo que de verdad es del Timer0: sus direcciones de I/O,
// su selector de reloj —cinco tomas del prescaler compartido, más el pin
// externo T0— y los nombres con los que un programa ve sus registros.
//
// Los ocho modos de onda, el doble búfer de OCR0x, el instante de cada bandera
// y la tabla de COM están documentados en `axioma_timer8.v`, que es donde se
// implementan.
//
// DIFERENCIAS CONOCIDAS CON simavr (docs/01-arquitectura.md §8bis). simavr no
// cuenta ciclo a ciclo: interpola TCNT0 desde `avr->cycle` cuando alguien lo
// lee, reinicia la fase del prescaler al escribir TCCR0B, devuelve 0 si el
// temporizador está parado y convierte en 0 la escritura de un valor >= TOP.
// En las cuatro manda la hoja de datos. Por eso este módulo tiene banco propio.

`default_nettype none

module axioma_timer0 (
    input  wire       clk,
    input  wire       rst_n,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- tomas del prescaler compartido ----
    input  wire       tick_1,
    input  wire       tick_8,
    input  wire       tick_64,
    input  wire       tick_256,
    input  wire       tick_1024,

    // ---- pin de reloj externo T0 (PD4) ----
    input  wire       t0_pin,

    // ---- salidas de comparación OC0A (PD6) y OC0B (PD5) ----
    // `_en` dice si el temporizador se adueña del pin; el encaminamiento al pad
    // es de la fase 3, con el resto de los canales PWM.
    output wire       oc0a,
    output wire       oc0a_en,
    output wire       oc0b,
    output wire       oc0b_en,

    // ---- interrupciones ----
    // La petición es la bandera Y su habilitación. El reconocimiento llega del
    // controlador cuando el núcleo salta al vector, y limpia la bandera: es lo
    // que hace el hardware del AVR al atender el vector.
    output wire       irq_ovf,
    output wire       irq_compa,
    output wire       irq_compb,
    input  wire       ack_ovf,
    input  wire       ack_compa,
    input  wire       ack_compb
);

    localparam [7:0] A_TIFR0  = 8'h15;
    localparam [7:0] A_TCCR0A = 8'h24;
    localparam [7:0] A_TCCR0B = 8'h25;
    localparam [7:0] A_TCNT0  = 8'h26;
    localparam [7:0] A_OCR0A  = 8'h27;
    localparam [7:0] A_OCR0B  = 8'h28;
    // TIMSK0 está en la I/O extendida: dato 0x6E, y el bus resta 0x20.
    localparam [7:0] A_TIMSK0 = 8'h4E;

    wire hit_tifr  = (io_addr == A_TIFR0);
    wire hit_tccra = (io_addr == A_TCCR0A);
    wire hit_tccrb = (io_addr == A_TCCR0B);
    wire hit_tcnt  = (io_addr == A_TCNT0);
    wire hit_ocra  = (io_addr == A_OCR0A);
    wire hit_ocrb  = (io_addr == A_OCR0B);
    wire hit_timsk = (io_addr == A_TIMSK0);

    assign io_sel = hit_tifr | hit_tccra | hit_tccrb | hit_tcnt
                  | hit_ocra | hit_ocrb | hit_timsk;

    // Ningún registro de este temporizador tiene efecto lateral de LECTURA.
    wire unused_io_re = &{1'b0, io_re};

    // ------------------------------------------------- reloj del contador
    // El pin T0 pasa por DOS biestables de sincronización y luego por el
    // detector de flancos, como describe la hoja de datos: el pin es asíncrono
    // de verdad, a diferencia de PINx, donde una sola etapa es lo que define la
    // temporización documentada del `nop`.
    reg [2:0] t0_sync;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) t0_sync <= 3'b000;
        else        t0_sync <= {t0_sync[1:0], t0_pin};
    end
    wire t0_rise = (t0_sync[2:1] == 2'b01);
    wire t0_fall = (t0_sync[2:1] == 2'b10);

    // Los bits CS viven aquí y no en el motor: los del Timer2 seleccionan otras
    // tomas y no tienen pin externo.
    reg [2:0] cs_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     cs_q <= 3'h0;
        else if (io_we && hit_tccrb)    cs_q <= io_wdata[2:0];
    end

    reg ck;
    always @(*) begin
        case (cs_q)
            3'd0:    ck = 1'b0;            // parado
            3'd1:    ck = tick_1;
            3'd2:    ck = tick_8;
            3'd3:    ck = tick_64;
            3'd4:    ck = tick_256;
            3'd5:    ck = tick_1024;
            3'd6:    ck = t0_fall;
            default: ck = t0_rise;
        endcase
    end

    // ------------------------------------------------------------ el motor
    wire [3:0] com;
    wire [2:0] wgm, timsk, tifr;
    wire [7:0] tcnt, ocra, ocrb;

    axioma_timer8 motor (
        .clk(clk), .rst_n(rst_n), .ck(ck),
        .wdata(io_wdata),
        .we_tccra(io_we & hit_tccra), .we_tccrb(io_we & hit_tccrb),
        .we_tcnt (io_we & hit_tcnt),  .we_ocra (io_we & hit_ocra),
        .we_ocrb (io_we & hit_ocrb),  .we_timsk(io_we & hit_timsk),
        .we_tifr (io_we & hit_tifr),
        .com(com), .wgm(wgm), .tcnt(tcnt), .ocra(ocra), .ocrb(ocrb),
        .timsk(timsk), .tifr(tifr),
        .oca(oc0a), .oca_en(oc0a_en), .ocb(oc0b), .ocb_en(oc0b_en),
        .irq_ovf(irq_ovf), .irq_compa(irq_compa), .irq_compb(irq_compb),
        .ack_ovf(ack_ovf), .ack_compa(ack_compa), .ack_compb(ack_compb)
    );

    // ------------------------------------------------------------- lectura
    // Cada periférico deja su lectura a cero cuando no está seleccionado.
    // Los bits reservados se leen como cero, y FOC0A/FOC0B también: son pulsos
    // de escritura, no almacenamiento.
    assign io_rdata = hit_tifr  ? {5'b00000, tifr}              :
                      hit_tccra ? {com, 2'b00, wgm[1:0]}        :
                      hit_tccrb ? {2'b00, 2'b00, wgm[2], cs_q}  :
                      hit_tcnt  ? tcnt                          :
                      hit_ocra  ? ocra                          :
                      hit_ocrb  ? ocrb                          :
                      hit_timsk ? {5'b00000, timsk}             : 8'h00;

endmodule

`default_nettype wire
