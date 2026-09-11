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
// MODOS (WGM0[2:0] = {WGM02, WGM01, WGM00}):
//
//   0  normal            TOP=0xFF    TOV en MAX      OCR0x inmediato
//   1  PWM fase corr.    TOP=0xFF    TOV en BOTTOM   OCR0x se actualiza en TOP
//   2  CTC               TOP=OCR0A   TOV en MAX      OCR0x inmediato
//   3  PWM rápido        TOP=0xFF    TOV en TOP      OCR0x se actualiza en BOTTOM
//   5  PWM fase corr.    TOP=OCR0A   TOV en BOTTOM   OCR0x se actualiza en TOP
//   7  PWM rápido        TOP=OCR0A   TOV en TOP      OCR0x se actualiza en BOTTOM
//   4 y 6                RESERVADOS
//
// OJO CON CTC: su TOP es OCR0A, pero su TOV0 se pone en MAX (0xFF), NO en TOP.
// Sólo se ve si alguien baja OCR0A por debajo de la cuenta actual: entonces la
// comparación se pierde, el contador sigue hasta 0xFF y ahí desborda. Es la
// clase de detalle que separa «pasa mis tests» de «ejecuta código real».
//
// MODOS RESERVADOS. Los WGM 4 y 6 no los define nadie: la hoja de datos los
// marca reservados y simavr los deja a cero en su tabla, con lo que se comporta
// de una tercera manera. Aquí cuentan como el modo normal. Ningún programa
// puede depender de ellos y ninguno de prueba los usa, igual que con los demás
// «resultados indefinidos» del manual.
//
// DOBLE BÚFER DE OCR0x. En los modos PWM una escritura a OCR0x va a un búfer y
// sólo pasa al comparador en TOP (fase correcta) o en BOTTOM (PWM rápido). Sin
// esto, cambiar el ciclo de trabajo a mitad de periodo genera un pulso
// asimétrico —un glitch— en el pin. En los modos sin PWM la escritura es
// inmediata.
//
// ESCRIBIR TCNT0 TAPA LA COMPARACIÓN del siguiente ciclo de temporizador; lo
// dice la hoja de datos y es lo que evita una interrupción espuria al
// reinicializar la cuenta.
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

    // ------------------------------------------------------------ registros
    reg [3:0] com_q;        // {COM0A1, COM0A0, COM0B1, COM0B0}
    reg [2:0] wgm_q;        // {WGM02, WGM01, WGM00}
    reg [2:0] cs_q;         // CS0[2:0]
    reg [7:0] tcnt_q;
    reg [7:0] ocra_act, ocra_buf;
    reg [7:0] ocrb_act, ocrb_buf;
    reg [2:0] timsk_q;      // {OCIE0B, OCIE0A, TOIE0}
    reg [2:0] tifr_q;       // {OCF0B,  OCF0A,  TOV0}
    reg       dir_down;     // sólo en PWM de fase correcta
    reg       tcnt_block;   // una escritura a TCNT0 tapa la comparación siguiente
    reg       oc0a_q, oc0b_q;

    // ------------------------------------------------------------- modo
    wire mode_pc   = (wgm_q == 3'd1) || (wgm_q == 3'd5);
    wire mode_fast = (wgm_q == 3'd3) || (wgm_q == 3'd7);
    wire mode_pwm  = mode_pc | mode_fast;
    // El modo CTC (wgm 2) no necesita señal propia: es el único que toma TOP de
    // OCR0A sin ser PWM, y su TOV0 en MAX sale del caso por defecto.
    wire top_ocra  = (wgm_q == 3'd2) || (wgm_q == 3'd5) || (wgm_q == 3'd7);
    wire [7:0] top = top_ocra ? ocra_act : 8'hFF;

    // ------------------------------------------------- reloj del contador
    // El pin T0 pasa por DOS biestables de sincronización y luego por el
    // detector de flancos, como describe la hoja de datos: el pin es asíncrono
    // de verdad, a diferencia de PINx, donde una sola etapa es lo que define la
    // temporización documentada del `nop`.
    reg [2:0] t0_sync;
    wire t0_rise = (t0_sync[2:1] == 2'b01);
    wire t0_fall = (t0_sync[2:1] == 2'b10);

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

    // ------------------------------------------------- eventos del contador
    // Se calculan sobre el valor ACTUAL de TCNT0, en el ciclo de temporizador
    // en el que ese valor está presente. La bandera se registra al final de ese
    // ciclo, que es lo que la hoja de datos llama «se pone en el siguiente
    // ciclo de reloj del temporizador».
    wire at_top    = (tcnt_q == top);
    wire at_max    = (tcnt_q == 8'hFF);
    wire at_bottom = (tcnt_q == 8'h00);

    // Desbordamiento: en MAX salvo en PWM, donde depende del modo.
    wire ev_tov = ck && (mode_pc   ? (dir_down && at_bottom) :
                         mode_fast ? at_top :
                                     at_max);

    // Comparación. Tapada el ciclo siguiente a escribir TCNT0.
    wire ev_compa = ck && !tcnt_block && (tcnt_q == ocra_act);
    wire ev_compb = ck && !tcnt_block && (tcnt_q == ocrb_act);

    // Momento de refrescar el doble búfer de OCR0x. En PWM rápido la hoja de
    // datos dice BOTTOM y en fase correcta dice TOP, pero el instante es el
    // mismo en los dos: el ciclo de temporizador en el que el contador ESTÁ en
    // TOP, que en PWM rápido es el que lo lleva a BOTTOM. Refrescar un ciclo
    // más tarde dejaría fuera la comparación con OCR0x = 0.
    wire ev_update = ck && mode_pwm && at_top;

    // ------------------------------------------------- siguiente cuenta
    reg [7:0] tcnt_next;
    reg       dir_next;
    always @(*) begin
        tcnt_next = tcnt_q;
        dir_next  = dir_down;
        if (mode_pc) begin
            if (dir_down) begin
                if (at_bottom) begin dir_next = 1'b0; tcnt_next = (top == 8'h00) ? 8'h00 : 8'h01; end
                else           tcnt_next = tcnt_q - 8'd1;
            end else begin
                if (at_top)   begin dir_next = 1'b1; tcnt_next = (top == 8'h00) ? 8'h00 : (tcnt_q - 8'd1); end
                else           tcnt_next = tcnt_q + 8'd1;
            end
        end else begin
            // Normal, CTC y PWM rápido cuentan hacia arriba y vuelven a cero en
            // TOP. Si TCNT0 se pasa de TOP —porque alguien bajó OCR0A— sigue
            // contando hasta 0xFF y da la vuelta ahí sola, que es justo lo que
            // hace el chip.
            tcnt_next = at_top ? 8'h00 : (tcnt_q + 8'd1);
        end
    end

    // ------------------------------------------------- salidas OC0A y OC0B
    // Qué hace cada combinación de COM con el pin, según el modo.
    //   sin PWM:  1 conmuta, 2 baja, 3 sube, en la comparación
    //   rápido:   2 baja en la comparación y sube en BOTTOM; 3 al revés
    //   fase c.:  2 baja contando hacia arriba y sube contando hacia abajo
    //   COM=1 sólo existe para OC0A y sólo con WGM02=1 (conmuta en cada
    //         comparación); para OC0B está reservado y el pin queda suelto.
    wire [1:0] com_a = com_q[3:2];
    wire [1:0] com_b = com_q[1:0];

    assign oc0a_en = (com_a != 2'd0) && !(mode_pwm && (com_a == 2'd1) && !wgm_q[2]);
    assign oc0b_en = (com_b != 2'd0) && !(mode_pwm && (com_b == 2'd1));
    assign oc0a    = oc0a_q;
    assign oc0b    = oc0b_q;

    // FOC0A y FOC0B: pulsos de escritura, sin registro. Fuerzan el cambio del
    // pin como lo haría una comparación, pero NO ponen la bandera ni tocan el
    // contador, y no tienen efecto en los modos PWM.
    wire foc_a = io_we && hit_tccrb && io_wdata[7] && !mode_pwm;
    wire foc_b = io_we && hit_tccrb && io_wdata[6] && !mode_pwm;

    // ---------------------------------------------------------------- estado
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            com_q      <= 4'h0;
            wgm_q      <= 3'h0;
            cs_q       <= 3'h0;
            tcnt_q     <= 8'h00;
            ocra_act   <= 8'h00;  ocra_buf <= 8'h00;
            ocrb_act   <= 8'h00;  ocrb_buf <= 8'h00;
            timsk_q    <= 3'h0;
            tifr_q     <= 3'h0;
            dir_down   <= 1'b0;
            tcnt_block <= 1'b0;
            oc0a_q     <= 1'b0;
            oc0b_q     <= 1'b0;
            t0_sync    <= 3'b000;
        end else begin
            t0_sync <= {t0_sync[1:0], t0_pin};

            // ---------------- contador ----------------
            if (ck) begin
                tcnt_q     <= tcnt_next;
                dir_down   <= dir_next;
                tcnt_block <= 1'b0;
            end

            // ---------------- doble búfer ----------------
            if (ev_update) begin
                ocra_act <= ocra_buf;
                ocrb_act <= ocrb_buf;
            end

            // ---------------- pines de comparación ----------------
            if (!mode_pwm) begin
                if (ev_compa || foc_a) begin
                    if      (com_a == 2'd1) oc0a_q <= ~oc0a_q;
                    else if (com_a == 2'd2) oc0a_q <= 1'b0;
                    else if (com_a == 2'd3) oc0a_q <= 1'b1;
                end
                if (ev_compb || foc_b) begin
                    if      (com_b == 2'd1) oc0b_q <= ~oc0b_q;
                    else if (com_b == 2'd2) oc0b_q <= 1'b0;
                    else if (com_b == 2'd3) oc0b_q <= 1'b1;
                end
            end else if (mode_fast) begin
                // En BOTTOM manda el flanco de arranque del periodo; si la
                // comparación cae también en BOTTOM, gana BOTTOM.
                if (ck && at_top) begin           // el siguiente es BOTTOM
                    if (com_a == 2'd2) oc0a_q <= 1'b1;
                    if (com_a == 2'd3) oc0a_q <= 1'b0;
                    if (com_b == 2'd2) oc0b_q <= 1'b1;
                    if (com_b == 2'd3) oc0b_q <= 1'b0;
                end else begin
                    if (ev_compa) begin
                        if      (com_a == 2'd1) oc0a_q <= ~oc0a_q;   // sólo con WGM02
                        else if (com_a == 2'd2) oc0a_q <= 1'b0;
                        else if (com_a == 2'd3) oc0a_q <= 1'b1;
                    end
                    if (ev_compb) begin
                        if      (com_b == 2'd2) oc0b_q <= 1'b0;
                        else if (com_b == 2'd3) oc0b_q <= 1'b1;
                    end
                end
            end else begin   // fase correcta
                if (ev_compa) begin
                    if      (com_a == 2'd1) oc0a_q <= ~oc0a_q;       // sólo con WGM02
                    else if (com_a == 2'd2) oc0a_q <= dir_down;
                    else if (com_a == 2'd3) oc0a_q <= ~dir_down;
                end
                if (ev_compb) begin
                    if      (com_b == 2'd2) oc0b_q <= dir_down;
                    else if (com_b == 2'd3) oc0b_q <= ~dir_down;
                end
            end

            // ---------------- banderas ----------------
            // El hardware gana a la escritura de limpieza: si la bandera se
            // pone en el mismo ciclo en que el programa escribe un 1 para
            // limpiarla, queda puesta. Y el reconocimiento del vector la
            // limpia, como hace el AVR al saltar a la ISR.
            if (ev_tov)                                  tifr_q[0] <= 1'b1;
            else if (ack_ovf ||
                     (io_we && hit_tifr && io_wdata[0])) tifr_q[0] <= 1'b0;

            if (ev_compa)                                tifr_q[1] <= 1'b1;
            else if (ack_compa ||
                     (io_we && hit_tifr && io_wdata[1])) tifr_q[1] <= 1'b0;

            if (ev_compb)                                tifr_q[2] <= 1'b1;
            else if (ack_compb ||
                     (io_we && hit_tifr && io_wdata[2])) tifr_q[2] <= 1'b0;

            // ---------------- escrituras ----------------
            // Van DESPUÉS del conteo: si en el mismo ciclo llega una cuenta y
            // una escritura a TCNT0, manda la escritura.
            if (io_we) begin
                if (hit_tccra) begin
                    com_q      <= io_wdata[7:4];
                    wgm_q[1:0] <= io_wdata[1:0];
                end
                if (hit_tccrb) begin
                    wgm_q[2] <= io_wdata[3];
                    cs_q     <= io_wdata[2:0];
                end
                if (hit_tcnt) begin
                    tcnt_q     <= io_wdata;
                    tcnt_block <= 1'b1;
                end
                if (hit_ocra) begin
                    ocra_buf <= io_wdata;
                    if (!mode_pwm) ocra_act <= io_wdata;
                end
                if (hit_ocrb) begin
                    ocrb_buf <= io_wdata;
                    if (!mode_pwm) ocrb_act <= io_wdata;
                end
                if (hit_timsk) timsk_q <= io_wdata[2:0];
            end
        end
    end

    // ------------------------------------------------------------- lectura
    // Cada periférico deja su lectura a cero cuando no está seleccionado.
    // Los bits reservados se leen como cero, y FOC0A/FOC0B también: son pulsos
    // de escritura, no almacenamiento.
    assign io_rdata = hit_tifr  ? {5'b00000, tifr_q}                :
                      hit_tccra ? {com_q, 2'b00, wgm_q[1:0]}        :
                      hit_tccrb ? {2'b00, 2'b00, wgm_q[2], cs_q}    :
                      hit_tcnt  ? tcnt_q                            :
                      hit_ocra  ? ocra_buf                          :
                      hit_ocrb  ? ocrb_buf                          :
                      hit_timsk ? {5'b00000, timsk_q}               : 8'h00;

    // La petición es bandera Y habilitación, combinacional: el controlador de
    // interrupciones decide la prioridad y el núcleo sólo atiende entre
    // instrucciones.
    assign irq_ovf   = tifr_q[0] & timsk_q[0];
    assign irq_compa = tifr_q[1] & timsk_q[1];
    assign irq_compb = tifr_q[2] & timsk_q[2];

endmodule

`default_nettype wire
