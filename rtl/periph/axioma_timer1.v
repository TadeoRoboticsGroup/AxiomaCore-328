// AxiomaCore-328 - Timer/Counter1, 16 bits
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El temporizador del que dependen `micros()`, `Servo` y cualquier medida de
// tiempo fina. Es el que trae LA TRAMPA Nº 4, que es la razón por la que este
// módulo no es «el Timer0 con más bits».
//
//   TIFR1   dato 0x36   - - ICF1 - - OCF1B OCF1A TOV1
//   TIMSK1  dato 0x6F   - - ICIE1 - - OCIE1B OCIE1A TOIE1
//   TCCR1A  dato 0x80   COM1A1 COM1A0 COM1B1 COM1B0 - - WGM11 WGM10
//   TCCR1B  dato 0x81   ICNC1 ICES1 - WGM13 WGM12 CS12 CS11 CS10
//   TCCR1C  dato 0x82   FOC1A FOC1B - - - - - -
//   TCNT1L/H  0x84/0x85      ICR1L/H  0x86/0x87
//   OCR1AL/H  0x88/0x89      OCR1BL/H 0x8A/0x8B
//
// EL REGISTRO TEMP, QUE ES UNO SOLO Y ES COMPARTIDO. El bus del AVR es de 8
// bits y estos registros son de 16, así que el chip los empareja con un octavo
// registro invisible:
//
//   LEER    TCNT1L captura el byte alto en TEMP y devuelve el bajo;
//           TCNT1H devuelve TEMP. Hay que leer BAJO y luego ALTO.
//   ESCRIBIR va al revés: TCNT1H se guarda en TEMP y TCNT1L escribe los dos a
//           la vez. Hay que escribir ALTO y luego BAJO.
//
// Y TEMP ES EL MISMO para TCNT1, ICR1, OCR1A y OCR1B. Eso significa que una
// interrupción que toque cualquiera de los cuatro EN MEDIO de un acceso de 16
// bits corrompe el otro: por eso las rutinas de avr-libc que leen TCNT1 lo
// hacen con las interrupciones apagadas. Modelarlo con dos registros separados
// da un chip que «funciona» en simulación y falla con código real.
//
// simavr NO MODELA TEMP EN ABSOLUTO: escribe los dos bytes por su cuenta
// (`avr->data[r_tcnth] = tcnt >> 8`). Así que esta parte no la puede verificar
// el contraste contra él; la certifica el banco propio contra la hoja de datos.
//
// LOS DIECISÉIS MODOS. WGM1[3:0] = {WGM13, WGM12, WGM11, WGM10}:
//
//    0 normal         TOP=0xFFFF   TOV en MAX       OCR inmediato
//    1 PWM fc 8 bits  TOP=0x00FF   TOV en BOTTOM    OCR en TOP
//    2 PWM fc 9 bits  TOP=0x01FF   "                "
//    3 PWM fc 10 bits TOP=0x03FF   "                "
//    4 CTC            TOP=OCR1A    TOV en MAX       OCR inmediato
//    5 PWM rápido 8   TOP=0x00FF   TOV en TOP       OCR en BOTTOM
//    6 PWM rápido 9   TOP=0x01FF   "                "
//    7 PWM rápido 10  TOP=0x03FF   "                "
//    8 PWM fase y frecuencia correctas, TOP=ICR1,  TOV en BOTTOM, OCR en BOTTOM
//    9 ídem con TOP=OCR1A
//   10 PWM fase correcta, TOP=ICR1,  TOV en BOTTOM, OCR en TOP
//   11 ídem con TOP=OCR1A
//   12 CTC           TOP=ICR1     TOV en MAX       OCR inmediato
//   13 RESERVADO — se trata como normal; nadie lo define
//   14 PWM rápido    TOP=ICR1     TOV en TOP       OCR en BOTTOM
//   15 PWM rápido    TOP=OCR1A    "                "
//
// LA DIFERENCIA ENTRE «FASE CORRECTA» Y «FASE Y FRECUENCIA CORRECTAS» está en
// CUÁNDO se refresca OCR: en TOP la primera, en BOTTOM la segunda. Con TOP fijo
// da igual; con TOP variable —modos 8 a 11— cambiar el periodo con la primera
// deja un semiciclo asimétrico, y con la segunda no. Por eso existen las dos.
//
// EL CANCELADOR DE RUIDO de la captura toma CUATRO muestras seguidas y sólo
// acepta el flanco si las cuatro coinciden. Cuesta cuatro ciclos de retardo, y
// la hoja de datos lo dice: el valor capturado va con ese retardo.
//
// EL PRESCALER ES EL COMPARTIDO con el Timer0 —la trampa nº 12—, así que llega
// de fuera, igual que allí.

`default_nettype none

module axioma_timer1 (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- tomas del prescaler COMPARTIDO ----
    input  wire       tick_1,
    input  wire       tick_8,
    input  wire       tick_64,
    input  wire       tick_256,
    input  wire       tick_1024,

    // ---- pines ----
    input  wire       t1_pin,      // reloj externo, PD5
    input  wire       icp1_pin,    // captura de entrada, PB0
    output wire       oc1a,
    output wire       oc1a_en,
    output wire       oc1b,
    output wire       oc1b_en,

    // ---- interrupciones ----
    output wire       irq_capt,    // vector 10
    output wire       irq_compa,   // vector 11
    output wire       irq_compb,   // vector 12
    output wire       irq_ovf,     // vector 13
    input  wire       ack_capt,
    input  wire       ack_compa,
    input  wire       ack_compb,
    input  wire       ack_ovf
);

    localparam [7:0] A_TIFR1  = 8'h16;
    localparam [7:0] A_TIMSK1 = 8'h4F;
    localparam [7:0] A_TCCR1A = 8'h60;
    localparam [7:0] A_TCCR1B = 8'h61;
    localparam [7:0] A_TCCR1C = 8'h62;
    localparam [7:0] A_TCNT1L = 8'h64;
    localparam [7:0] A_TCNT1H = 8'h65;
    localparam [7:0] A_ICR1L  = 8'h66;
    localparam [7:0] A_ICR1H  = 8'h67;
    localparam [7:0] A_OCR1AL = 8'h68;
    localparam [7:0] A_OCR1AH = 8'h69;
    localparam [7:0] A_OCR1BL = 8'h6A;
    localparam [7:0] A_OCR1BH = 8'h6B;

    wire hit_tifr  = (io_addr == A_TIFR1);
    wire hit_timsk = (io_addr == A_TIMSK1);
    wire hit_ccra  = (io_addr == A_TCCR1A);
    wire hit_ccrb  = (io_addr == A_TCCR1B);
    wire hit_ccrc  = (io_addr == A_TCCR1C);
    wire hit_cntl  = (io_addr == A_TCNT1L);
    wire hit_cnth  = (io_addr == A_TCNT1H);
    wire hit_icrl  = (io_addr == A_ICR1L);
    wire hit_icrh  = (io_addr == A_ICR1H);
    wire hit_ocral = (io_addr == A_OCR1AL);
    wire hit_ocrah = (io_addr == A_OCR1AH);
    wire hit_ocrbl = (io_addr == A_OCR1BL);
    wire hit_ocrbh = (io_addr == A_OCR1BH);

    assign io_sel = hit_tifr | hit_timsk | hit_ccra | hit_ccrb | hit_ccrc
                  | hit_cntl | hit_cnth | hit_icrl | hit_icrh
                  | hit_ocral | hit_ocrah | hit_ocrbl | hit_ocrbh;

    // ------------------------------------------------------------ registros
    reg [3:0]  com;              // {COM1A1, COM1A0, COM1B1, COM1B0}
    reg [3:0]  wgm;              // {WGM13, WGM12, WGM11, WGM10}
    reg [2:0]  cs;
    reg        icnc, ices;
    reg [15:0] tcnt;
    reg [15:0] ocra_act, ocra_buf, ocrb_act, ocrb_buf;
    reg [15:0] icr;
    reg [2:0]  timsk;            // {ICIE1, OCIE1B, OCIE1A, TOIE1} -> ver lectura
    reg        icie;
    reg [2:0]  tifr;             // {OCF1B, OCF1A, TOV1}
    reg        icf;
    reg        dir_down;
    reg        tcnt_block;
    reg        oc1a_q, oc1b_q;

    // EL REGISTRO TEMP: uno solo para los cuatro de 16 bits.
    reg [7:0]  temp;

    // ---------------------------------------------------------------- modo
    wire mode_pc   = (wgm == 4'd1) || (wgm == 4'd2) || (wgm == 4'd3)
                  || (wgm == 4'd10) || (wgm == 4'd11);
    wire mode_pfc  = (wgm == 4'd8) || (wgm == 4'd9);      // fase y frecuencia
    wire mode_fast = (wgm == 4'd5) || (wgm == 4'd6) || (wgm == 4'd7)
                  || (wgm == 4'd14) || (wgm == 4'd15);
    // Los modos CTC —4 y 12— no necesitan señal propia: son los únicos que
    // toman TOP de un registro sin ser PWM, y su TOV en MAX sale del caso por
    // defecto de `ev_tov`.
    wire mode_pwm  = mode_pc | mode_pfc | mode_fast;
    wire cuenta_ad = mode_pc | mode_pfc;                  // arriba y abajo

    reg [15:0] top;
    always @(*) begin
        case (wgm)
            4'd1, 4'd5:            top = 16'h00FF;
            4'd2, 4'd6:            top = 16'h01FF;
            4'd3, 4'd7:            top = 16'h03FF;
            4'd4, 4'd9, 4'd11, 4'd15: top = ocra_act;
            4'd8, 4'd10, 4'd12, 4'd14: top = icr;
            default:               top = 16'hFFFF;        // 0 y el reservado 13
        endcase
    end

    // ------------------------------------------------- reloj del contador
    // El pin T1 pasa por dos etapas de sincronización y el detector de flancos,
    // como el T0 del Timer0.
    reg [2:0] t1_sync;
    wire t1_rise = (t1_sync[2:1] == 2'b01);
    wire t1_fall = (t1_sync[2:1] == 2'b10);

    reg ck;
    always @(*) begin
        case (cs)
            3'd0:    ck = 1'b0;
            3'd1:    ck = tick_1;
            3'd2:    ck = tick_8;
            3'd3:    ck = tick_64;
            3'd4:    ck = tick_256;
            3'd5:    ck = tick_1024;
            3'd6:    ck = t1_fall;
            default: ck = t1_rise;
        endcase
    end

    // ------------------------------------------------- eventos del contador
    wire at_top    = (tcnt == top);
    wire at_max    = (tcnt == 16'hFFFF);
    wire at_bottom = (tcnt == 16'h0000);

    wire ev_tov = ck && (cuenta_ad ? (dir_down && at_bottom) :
                         mode_fast ? at_top :
                                     at_max);

    wire ev_compa = ck && !tcnt_block && (tcnt == ocra_act);
    wire ev_compb = ck && !tcnt_block && (tcnt == ocrb_act);

    // Refresco del doble búfer. En fase correcta toca en TOP; en fase Y
    // frecuencia correctas, en BOTTOM — que es toda la diferencia entre las dos
    // familias y sólo se nota con TOP variable. En PWM rápido, en BOTTOM, que
    // es el ciclo en el que el contador ESTÁ en TOP y pasa a cero.
    wire ev_update = ck && (mode_pc   ? at_top :
                            mode_pfc  ? (dir_down && at_bottom) :
                            mode_fast ? at_top : 1'b0);

    // ------------------------------------------------- siguiente cuenta
    reg [15:0] tcnt_next;
    reg        dir_next;
    always @(*) begin
        tcnt_next = tcnt;
        dir_next  = dir_down;
        if (cuenta_ad) begin
            if (dir_down) begin
                if (at_bottom) begin dir_next = 1'b0; tcnt_next = (top == 16'd0) ? 16'd0 : 16'd1; end
                else             tcnt_next = tcnt - 16'd1;
            end else begin
                if (at_top) begin dir_next = 1'b1; tcnt_next = (top == 16'd0) ? 16'd0 : (tcnt - 16'd1); end
                else          tcnt_next = tcnt + 16'd1;
            end
        end else begin
            tcnt_next = at_top ? 16'd0 : (tcnt + 16'd1);
        end
    end

    // --------------------------------------------- captura de entrada
    // Sincronización, cancelador de ruido de cuatro muestras y detector de
    // flancos. El cancelador retrasa la captura cuatro ciclos: lo dice la hoja
    // de datos y es el precio de no capturar un pico.
    reg [3:0] icp_sync;
    reg       icp_limpio;

    wire cuatro_altas = (icp_sync[3:0] == 4'b1111);
    wire cuatro_bajas = (icp_sync[3:0] == 4'b0000);
    wire icp_filtrado = icnc ? icp_limpio : icp_sync[1];

    reg  icp_prev;

    // ------------------------------------------------- salidas de comparación
    wire [1:0] com_a = com[3:2];
    wire [1:0] com_b = com[1:0];

    // COM=1 en PWM significa conmutar, y sólo vale para OC1A; para OC1B está
    // reservado y el pin queda suelto.
    assign oc1a_en = (com_a != 2'd0);
    assign oc1b_en = (com_b != 2'd0) && !(mode_pwm && (com_b == 2'd1));
    assign oc1a    = oc1a_q;
    assign oc1b    = oc1b_q;

    wire foc_a = io_we && hit_ccrc && io_wdata[7] && !mode_pwm;
    wire foc_b = io_we && hit_ccrc && io_wdata[6] && !mode_pwm;

    // ---------------------------------------------------------------- estado
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            com <= 4'h0;  wgm <= 4'h0;  cs <= 3'h0;
            icnc <= 1'b0; ices <= 1'b0;
            tcnt <= 16'h0000;
            ocra_act <= 16'h0000; ocra_buf <= 16'h0000;
            ocrb_act <= 16'h0000; ocrb_buf <= 16'h0000;
            icr <= 16'h0000;
            timsk <= 3'h0; icie <= 1'b0;
            tifr <= 3'h0;  icf <= 1'b0;
            dir_down <= 1'b0; tcnt_block <= 1'b0;
            oc1a_q <= 1'b0; oc1b_q <= 1'b0;
            temp <= 8'h00;
            t1_sync <= 3'b000;
            icp_sync <= 4'b0000; icp_limpio <= 1'b0; icp_prev <= 1'b0;
        end else begin
            t1_sync  <= {t1_sync[1:0], t1_pin};
            icp_sync <= {icp_sync[2:0], icp1_pin};
            if (cuatro_altas) icp_limpio <= 1'b1;
            if (cuatro_bajas) icp_limpio <= 1'b0;
            icp_prev <= icp_filtrado;

            // ---------------- cuenta ----------------
            if (ck) begin
                tcnt       <= tcnt_next;
                dir_down   <= dir_next;
                tcnt_block <= 1'b0;
            end

            if (ev_update) begin
                ocra_act <= ocra_buf;
                ocrb_act <= ocrb_buf;
            end

            // ---------------- captura ----------------
            // El flanco lo decide ICES1. Al capturar, TCNT1 entero pasa a ICR1
            // y se levanta ICF1. En los modos que usan ICR1 como TOP la captura
            // no tiene sentido y la hoja de datos lo desaconseja, pero no lo
            // prohíbe: aquí se hace igual, que es lo que hace el chip.
            if (icp_filtrado != icp_prev && (icp_filtrado == ices)) begin
                icr <= tcnt;
                icf <= 1'b1;
            end else if (ack_capt || (io_we && hit_tifr && io_wdata[5])) begin
                icf <= 1'b0;
            end

            // ---------------- pines de comparación ----------------
            if (!mode_pwm) begin
                if (ev_compa || foc_a) begin
                    if      (com_a == 2'd1) oc1a_q <= ~oc1a_q;
                    else if (com_a == 2'd2) oc1a_q <= 1'b0;
                    else if (com_a == 2'd3) oc1a_q <= 1'b1;
                end
                if (ev_compb || foc_b) begin
                    if      (com_b == 2'd1) oc1b_q <= ~oc1b_q;
                    else if (com_b == 2'd2) oc1b_q <= 1'b0;
                    else if (com_b == 2'd3) oc1b_q <= 1'b1;
                end
            end else if (mode_fast) begin
                if (ck && at_top) begin
                    if (com_a == 2'd2) oc1a_q <= 1'b1;
                    if (com_a == 2'd3) oc1a_q <= 1'b0;
                    if (com_b == 2'd2) oc1b_q <= 1'b1;
                    if (com_b == 2'd3) oc1b_q <= 1'b0;
                end else begin
                    if (ev_compa) begin
                        if      (com_a == 2'd1) oc1a_q <= ~oc1a_q;
                        else if (com_a == 2'd2) oc1a_q <= 1'b0;
                        else if (com_a == 2'd3) oc1a_q <= 1'b1;
                    end
                    if (ev_compb) begin
                        if      (com_b == 2'd2) oc1b_q <= 1'b0;
                        else if (com_b == 2'd3) oc1b_q <= 1'b1;
                    end
                end
            end else begin                      // fase correcta y fase+frec
                if (ev_compa) begin
                    if      (com_a == 2'd1) oc1a_q <= ~oc1a_q;
                    else if (com_a == 2'd2) oc1a_q <= dir_down;
                    else if (com_a == 2'd3) oc1a_q <= ~dir_down;
                end
                if (ev_compb) begin
                    if      (com_b == 2'd2) oc1b_q <= dir_down;
                    else if (com_b == 2'd3) oc1b_q <= ~dir_down;
                end
            end

            // ---------------- banderas ----------------
            if (ev_tov)                                  tifr[0] <= 1'b1;
            else if (ack_ovf ||
                     (io_we && hit_tifr && io_wdata[0])) tifr[0] <= 1'b0;
            if (ev_compa)                                tifr[1] <= 1'b1;
            else if (ack_compa ||
                     (io_we && hit_tifr && io_wdata[1])) tifr[1] <= 1'b0;
            if (ev_compb)                                tifr[2] <= 1'b1;
            else if (ack_compb ||
                     (io_we && hit_tifr && io_wdata[2])) tifr[2] <= 1'b0;

            // ---------------- escrituras ----------------
            // EL ORDEN IMPORTA: el byte ALTO va a TEMP y el BAJO escribe los dos
            // de golpe. Escribir sólo el alto no cambia nada visible; escribir
            // sólo el bajo usa el TEMP que hubiera, que es justo lo que hace el
            // chip y por lo que el orden está documentado.
            if (io_we) begin
                if (hit_ccra) begin com <= io_wdata[7:4]; wgm[1:0] <= io_wdata[1:0]; end
                if (hit_ccrb) begin
                    icnc <= io_wdata[7];  ices <= io_wdata[6];
                    wgm[3:2] <= {io_wdata[4], io_wdata[3]};
                    cs <= io_wdata[2:0];
                end
                if (hit_timsk) begin icie <= io_wdata[5]; timsk <= io_wdata[2:0]; end

                if (hit_cnth || hit_icrh || hit_ocrah || hit_ocrbh)
                    temp <= io_wdata;

                if (hit_cntl)  begin tcnt <= {temp, io_wdata}; tcnt_block <= 1'b1; end
                if (hit_icrl)  icr <= {temp, io_wdata};
                if (hit_ocral) begin
                    ocra_buf <= {temp, io_wdata};
                    if (!mode_pwm) ocra_act <= {temp, io_wdata};
                end
                if (hit_ocrbl) begin
                    ocrb_buf <= {temp, io_wdata};
                    if (!mode_pwm) ocrb_act <= {temp, io_wdata};
                end
            end

            // ---------------- lecturas con efecto lateral ----------------
            // Leer el byte BAJO de cualquiera de los cuatro captura su byte
            // alto en TEMP. Es la otra mitad de la trampa nº 4, y es la razón
            // por la que hay que leer bajo y luego alto.
            if (io_re) begin
                if (hit_cntl)  temp <= tcnt[15:8];
                if (hit_icrl)  temp <= icr[15:8];
                if (hit_ocral) temp <= ocra_buf[15:8];
                if (hit_ocrbl) temp <= ocrb_buf[15:8];
            end
        end
    end

    // ------------------------------------------------------------- lectura
    assign io_rdata = hit_tifr  ? {2'b00, icf, 2'b00, tifr}          :
                      hit_timsk ? {2'b00, icie, 2'b00, timsk}        :
                      hit_ccra  ? {com, 2'b00, wgm[1:0]}             :
                      hit_ccrb  ? {icnc, ices, 1'b0, wgm[3], wgm[2], cs} :
                      hit_ccrc  ? 8'h00                              :
                      hit_cntl  ? tcnt[7:0]                          :
                      hit_cnth  ? temp                               :
                      hit_icrl  ? icr[7:0]                           :
                      hit_icrh  ? temp                               :
                      hit_ocral ? ocra_buf[7:0]                      :
                      hit_ocrah ? temp                               :
                      hit_ocrbl ? ocrb_buf[7:0]                      :
                      hit_ocrbh ? temp                               : 8'h00;

    assign irq_capt  = icf     & icie;
    assign irq_compa = tifr[1] & timsk[1];
    assign irq_compb = tifr[2] & timsk[2];
    assign irq_ovf   = tifr[0] & timsk[0];

endmodule

`default_nettype wire
