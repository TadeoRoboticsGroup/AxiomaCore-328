// AxiomaCore-328 - motor de forma de onda de 8 bits, comun al Timer0 y al Timer2
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// EXISTE PORQUE LA HOJA DE DATOS DICE QUE SON EL MISMO. Los capítulos del
// Timer/Counter0 y del Timer/Counter2 describen, palabra por palabra, la misma
// máquina de forma de onda: los mismos ocho modos, el mismo doble búfer, el
// mismo instante para cada bandera y la misma tabla de lo que hace cada
// combinación de COM con el pin. Lo que cambia en el 328P es lo de ALREDEDOR:
//
//   Timer0   sus tomas del prescaler son /1 /8 /64 /256 /1024, y CS 6 y 7
//            seleccionan el pin externo T0.
//   Timer2   tiene prescaler PROPIO con dos tomas más —/32 y /128—, no tiene
//            entrada de reloj externo, y en su sitio lleva el modo asíncrono
//            con `ASSR`.
//
// Copiar este motor en los dos módulos sería garantizar que dentro de un año
// uno tenga un arreglo que el otro no. Así que vive una sola vez, y cada
// temporizador aporta su decodificación de direcciones y su selector de reloj.
//
// EL MOTOR NO SABE DIRECCIONES. Recibe pulsos de escritura ya decodificados
// —`we_tccra`, `we_tcnt`…— y un `ck` que vale uno en el ciclo en el que le toca
// contar. Quien traduce direcciones es el módulo de cada temporizador, porque
// son distintas, y quien decide cuándo hay `ck` también.
//
// MODOS (WGM[2:0] = {WGM2, WGM1, WGM0}):
//
//   0  normal            TOP=0xFF    TOV en MAX      OCRx inmediato
//   1  PWM fase corr.    TOP=0xFF    TOV en BOTTOM   OCRx se actualiza en TOP
//   2  CTC               TOP=OCRA    TOV en MAX      OCRx inmediato
//   3  PWM rápido        TOP=0xFF    TOV en TOP      OCRx se actualiza en BOTTOM
//   5  PWM fase corr.    TOP=OCRA    TOV en BOTTOM   OCRx se actualiza en TOP
//   7  PWM rápido        TOP=OCRA    TOV en TOP      OCRx se actualiza en BOTTOM
//   4 y 6                RESERVADOS
//
// OJO CON CTC: su TOP es OCRA, pero su TOV se pone en MAX (0xFF), NO en TOP.
// Sólo se ve si alguien baja OCRA por debajo de la cuenta actual: entonces la
// comparación se pierde, el contador sigue hasta 0xFF y ahí desborda. Es la
// clase de detalle que separa «pasa mis tests» de «ejecuta código real».
//
// MODOS RESERVADOS. Los WGM 4 y 6 no los define nadie: la hoja de datos los
// marca reservados y simavr los deja a cero en su tabla, con lo que se comporta
// de una tercera manera. Aquí cuentan como el modo normal. Ningún programa
// puede depender de ellos.
//
// DOBLE BÚFER DE OCRx. En los modos PWM una escritura a OCRx va a un búfer y
// sólo pasa al comparador en TOP (fase correcta) o en BOTTOM (PWM rápido). Sin
// esto, cambiar el ciclo de trabajo a mitad de periodo genera un pulso
// asimétrico —un glitch— en el pin. En los modos sin PWM la escritura es
// inmediata.
//
// ESCRIBIR TCNT TAPA LA COMPARACIÓN del siguiente ciclo de temporizador; lo
// dice la hoja de datos y es lo que evita una interrupción espuria al
// reinicializar la cuenta.

`default_nettype none

module axioma_timer8 (
    input  wire       clk,
    input  wire       rst_n,

    // Un pulso de un ciclo cada vez que al temporizador le toca contar. Lo
    // produce el selector de reloj de cada temporizador.
    input  wire       ck,

    // ---- escrituras ya decodificadas, con el dato en bruto ----
    input  wire [7:0] wdata,
    input  wire       we_tccra,
    input  wire       we_tccrb,
    input  wire       we_tcnt,
    input  wire       we_ocra,
    input  wire       we_ocrb,
    input  wire       we_timsk,
    input  wire       we_tifr,

    // ---- estado, para que cada temporizador lo presente en SUS direcciones --
    output wire [3:0] com,          // {COMA1, COMA0, COMB1, COMB0}
    output wire [2:0] wgm,          // {WGM2, WGM1, WGM0}
    output wire [7:0] tcnt,
    output wire [7:0] ocra,         // lo que se lee es el BÚFER, no el activo
    output wire [7:0] ocrb,
    output wire [2:0] timsk,        // {OCIEB, OCIEA, TOIE}
    output wire [2:0] tifr,         // {OCFB,  OCFA,  TOV}

    // ---- salidas de comparación ----
    output wire       oca,
    output wire       oca_en,
    output wire       ocb,
    output wire       ocb_en,

    // ---- interrupciones ----
    output wire       irq_ovf,
    output wire       irq_compa,
    output wire       irq_compb,
    input  wire       ack_ovf,
    input  wire       ack_compa,
    input  wire       ack_compb
);

    // ------------------------------------------------------------ registros
    reg [3:0] com_q;
    reg [2:0] wgm_q;
    reg [7:0] tcnt_q;
    reg [7:0] ocra_act, ocra_buf;
    reg [7:0] ocrb_act, ocrb_buf;
    reg [2:0] timsk_q;
    reg [2:0] tifr_q;
    reg       dir_down;     // sólo en PWM de fase correcta
    reg       tcnt_block;   // una escritura a TCNT tapa la comparación siguiente
    reg       oca_q, ocb_q;

    // ------------------------------------------------------------- modo
    wire mode_pc   = (wgm_q == 3'd1) || (wgm_q == 3'd5);
    wire mode_fast = (wgm_q == 3'd3) || (wgm_q == 3'd7);
    wire mode_pwm  = mode_pc | mode_fast;
    // El modo CTC (wgm 2) no necesita señal propia: es el único que toma TOP de
    // OCRA sin ser PWM, y su TOV en MAX sale del caso por defecto.
    wire top_ocra  = (wgm_q == 3'd2) || (wgm_q == 3'd5) || (wgm_q == 3'd7);
    wire [7:0] top = top_ocra ? ocra_act : 8'hFF;

    // ------------------------------------------------- eventos del contador
    // Se calculan sobre el valor ACTUAL de TCNT, en el ciclo de temporizador en
    // el que ese valor está presente. La bandera se registra al final de ese
    // ciclo, que es lo que la hoja de datos llama «se pone en el siguiente
    // ciclo de reloj del temporizador».
    wire at_top    = (tcnt_q == top);
    wire at_max    = (tcnt_q == 8'hFF);
    wire at_bottom = (tcnt_q == 8'h00);

    wire ev_tov = ck && (mode_pc   ? (dir_down && at_bottom) :
                         mode_fast ? at_top :
                                     at_max);

    wire ev_compa = ck && !tcnt_block && (tcnt_q == ocra_act);
    wire ev_compb = ck && !tcnt_block && (tcnt_q == ocrb_act);

    // Momento de refrescar el doble búfer. En PWM rápido la hoja de datos dice
    // BOTTOM y en fase correcta dice TOP, pero el instante es el mismo en los
    // dos: el ciclo de temporizador en el que el contador ESTÁ en TOP, que en
    // PWM rápido es el que lo lleva a BOTTOM. Refrescar un ciclo más tarde
    // dejaría fuera la comparación con OCRx = 0.
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
            // TOP. Si TCNT se pasa de TOP —porque alguien bajó OCRA— sigue
            // contando hasta 0xFF y da la vuelta ahí sola, que es justo lo que
            // hace el chip.
            tcnt_next = at_top ? 8'h00 : (tcnt_q + 8'd1);
        end
    end

    // ------------------------------------------------- salidas OCA y OCB
    // Qué hace cada combinación de COM con el pin, según el modo.
    //   sin PWM:  1 conmuta, 2 baja, 3 sube, en la comparación
    //   rápido:   2 baja en la comparación y sube en BOTTOM; 3 al revés
    //   fase c.:  2 baja contando hacia arriba y sube contando hacia abajo
    //   COM=1 sólo existe para OCA y sólo con WGM2=1 (conmuta en cada
    //         comparación); para OCB está reservado y el pin queda suelto.
    wire [1:0] com_a = com_q[3:2];
    wire [1:0] com_b = com_q[1:0];

    assign oca_en = (com_a != 2'd0) && !(mode_pwm && (com_a == 2'd1) && !wgm_q[2]);
    assign ocb_en = (com_b != 2'd0) && !(mode_pwm && (com_b == 2'd1));
    assign oca    = oca_q;
    assign ocb    = ocb_q;

    // FOCA y FOCB: pulsos de escritura, sin registro. Fuerzan el cambio del pin
    // como lo haría una comparación, pero NO ponen la bandera ni tocan el
    // contador, y no tienen efecto en los modos PWM.
    wire foc_a = we_tccrb && wdata[7] && !mode_pwm;
    wire foc_b = we_tccrb && wdata[6] && !mode_pwm;

    // ---------------------------------------------------------------- estado
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            com_q      <= 4'h0;
            wgm_q      <= 3'h0;
            tcnt_q     <= 8'h00;
            ocra_act   <= 8'h00;  ocra_buf <= 8'h00;
            ocrb_act   <= 8'h00;  ocrb_buf <= 8'h00;
            timsk_q    <= 3'h0;
            tifr_q     <= 3'h0;
            dir_down   <= 1'b0;
            tcnt_block <= 1'b0;
            oca_q      <= 1'b0;
            ocb_q      <= 1'b0;
        end else begin
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
                    if      (com_a == 2'd1) oca_q <= ~oca_q;
                    else if (com_a == 2'd2) oca_q <= 1'b0;
                    else if (com_a == 2'd3) oca_q <= 1'b1;
                end
                if (ev_compb || foc_b) begin
                    if      (com_b == 2'd1) ocb_q <= ~ocb_q;
                    else if (com_b == 2'd2) ocb_q <= 1'b0;
                    else if (com_b == 2'd3) ocb_q <= 1'b1;
                end
            end else if (mode_fast) begin
                // En BOTTOM manda el flanco de arranque del periodo; si la
                // comparación cae también en BOTTOM, gana BOTTOM.
                if (ck && at_top) begin           // el siguiente es BOTTOM
                    if (com_a == 2'd2) oca_q <= 1'b1;
                    if (com_a == 2'd3) oca_q <= 1'b0;
                    if (com_b == 2'd2) ocb_q <= 1'b1;
                    if (com_b == 2'd3) ocb_q <= 1'b0;
                end else begin
                    if (ev_compa) begin
                        if      (com_a == 2'd1) oca_q <= ~oca_q;   // sólo con WGM2
                        else if (com_a == 2'd2) oca_q <= 1'b0;
                        else if (com_a == 2'd3) oca_q <= 1'b1;
                    end
                    if (ev_compb) begin
                        if      (com_b == 2'd2) ocb_q <= 1'b0;
                        else if (com_b == 2'd3) ocb_q <= 1'b1;
                    end
                end
            end else begin   // fase correcta
                if (ev_compa) begin
                    if      (com_a == 2'd1) oca_q <= ~oca_q;       // sólo con WGM2
                    else if (com_a == 2'd2) oca_q <= dir_down;
                    else if (com_a == 2'd3) oca_q <= ~dir_down;
                end
                if (ev_compb) begin
                    if      (com_b == 2'd2) ocb_q <= dir_down;
                    else if (com_b == 2'd3) ocb_q <= ~dir_down;
                end
            end

            // ---------------- banderas ----------------
            // El hardware gana a la escritura de limpieza: si la bandera se
            // pone en el mismo ciclo en que el programa escribe un 1 para
            // limpiarla, queda puesta. Y el reconocimiento del vector la
            // limpia, como hace el AVR al saltar a la ISR.
            if (ev_tov)                                  tifr_q[0] <= 1'b1;
            else if (ack_ovf   || (we_tifr && wdata[0])) tifr_q[0] <= 1'b0;

            if (ev_compa)                                tifr_q[1] <= 1'b1;
            else if (ack_compa || (we_tifr && wdata[1])) tifr_q[1] <= 1'b0;

            if (ev_compb)                                tifr_q[2] <= 1'b1;
            else if (ack_compb || (we_tifr && wdata[2])) tifr_q[2] <= 1'b0;

            // ---------------- escrituras ----------------
            // Van DESPUÉS del conteo: si en el mismo ciclo llega una cuenta y
            // una escritura a TCNT, manda la escritura.
            if (we_tccra) begin
                com_q      <= wdata[7:4];
                wgm_q[1:0] <= wdata[1:0];
            end
            if (we_tccrb) wgm_q[2] <= wdata[3];
            if (we_tcnt) begin
                tcnt_q     <= wdata;
                tcnt_block <= 1'b1;
            end
            if (we_ocra) begin
                ocra_buf <= wdata;
                if (!mode_pwm) ocra_act <= wdata;
            end
            if (we_ocrb) begin
                ocrb_buf <= wdata;
                if (!mode_pwm) ocrb_act <= wdata;
            end
            if (we_timsk) timsk_q <= wdata[2:0];
        end
    end

    assign com   = com_q;
    assign wgm   = wgm_q;
    assign tcnt  = tcnt_q;
    assign ocra  = ocra_buf;      // se lee el búfer, no el registro activo
    assign ocrb  = ocrb_buf;
    assign timsk = timsk_q;
    assign tifr  = tifr_q;

    // La petición es bandera Y habilitación, combinacional: el controlador de
    // interrupciones decide la prioridad y el núcleo sólo atiende entre
    // instrucciones.
    assign irq_ovf   = tifr_q[0] & timsk_q[0];
    assign irq_compa = tifr_q[1] & timsk_q[1];
    assign irq_compb = tifr_q[2] & timsk_q[2];

endmodule

`default_nettype wire
