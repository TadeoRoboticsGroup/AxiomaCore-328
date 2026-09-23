// AxiomaCore-328 - interrupciones externas: INT0, INT1 y los tres PCINT
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Cinco de los veintiséis vectores, y los que usa `attachInterrupt()`:
//
//   INT0    PD2    vector 1     PCINT0   PB0..PB7    vector 3
//   INT1    PD3    vector 2     PCINT1   PC0..PC6    vector 4
//                               PCINT2   PD0..PD7    vector 5
//
// Registros: EICRA, EIMSK, EIFR para las dos externas; PCICR, PCIFR y
// PCMSK0/1/2 para las de cambio de pin.
//
// SON DOS MECANISMOS DISTINTOS, y confundirlos es el error clásico:
//
//   INT0/INT1  detectan lo que diga ISCn: nivel bajo, cualquier flanco, flanco
//              de bajada o flanco de subida. Son por PIN, y distinguen la
//              dirección del flanco.
//   PCINTx     detectan CUALQUIER CAMBIO, en cualquiera de los pines que
//              habilite su máscara, y los tres comparten un vector por puerto.
//              Ni distinguen flanco ni dicen QUÉ pin cambió: eso lo tiene que
//              averiguar la ISR leyendo PINx y comparándolo con lo que guardó.
//
// LA TRAMPA DEL NIVEL BAJO. Con ISCn = 00 no hay bandera: la petición se
// mantiene MIENTRAS el pin esté bajo, y por eso `INTFn` se lee siempre a cero
// en ese modo. Es lo que dice la hoja de datos —«the flag is always cleared
// when INT0 is configured as a level interrupt»—, y tiene consecuencia real:
// una ISR de nivel bajo que no quite la causa se vuelve a entrar en cuanto
// termina, para siempre. Modelarlo con bandera haría que ese programa
// funcionara aquí y se colgara en el chip.
//
// LA BANDERA SE PONE AUNQUE LA INTERRUPCIÓN ESTÉ DESHABILITADA. `EIMSK` y
// `PCICR` sólo deciden si se salta al vector; el flanco marca `INTFn`/`PCIFn`
// igual. Es lo que permite el sondeo sin interrupciones, que es un uso normal:
// habilitar el flanco, no el vector, y mirar la bandera de vez en cuando.
// Quien sí decide es `PCMSKn`: un pin que no esté en la máscara no marca nada.
//
// SE LIMPIA DE DOS MANERAS: escribiendo un UNO en su bit —no un cero— o
// atendiendo el vector. Las dos, igual que en los temporizadores.
//
// UN PIN DE SALIDA TAMBIÉN INTERRUMPE. La detección mira el valor del PIN, no
// el de `PORTx`, así que un pin configurado como salida que el programa
// conmute se detecta a sí mismo. La hoja de datos lo dice explícitamente, y es
// la forma más barata de generar una interrupción por software.
//
// SINCRONIZADOR DE UNA ETAPA, igual que en `axioma_gpio` y por el mismo
// motivo: es lo que fija la temporización documentada. La hoja de datos habla
// de reconocer el flanco en hasta un ciclo y medio, y de que el pulso tiene que
// durar más de un periodo de reloj para garantizar que se ve. Con dos etapas
// haría falta uno más y dejaría de coincidir con el chip. Ver la deuda D6 en
// docs/06-deuda-tecnica.md: para pines externos de verdad hace falta una
// segunda etapa contra la metaestabilidad, y eso se decide en la fase 5.

`default_nettype none

module axioma_extint (
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

    // ---- pines, tal como llegan al pad ----
    // Los dos de INT están DENTRO de pin_d: INT0 es PD2 e INT1 es PD3. No se
    // pasan aparte para que no haya dos caminos distintos hasta el mismo pin.
    input  wire [7:0] pin_b,
    input  wire [7:0] pin_c,       // PC7 no existe: su bit se ata a cero fuera
    input  wire [7:0] pin_d,

    // ---- hacia el controlador de interrupciones ----

    // ---- las banderas CRUDAS, para el disparo automatico del ADC ----
    // Son las mismas que se leen en el registro de banderas, SIN la mascara de
    // habilitacion: el disparo del ADC va por la bandera aunque su interrupcion
    // este apagada, y por eso no vale reutilizar las peticiones de vector.
    output wire       flag_intf0,

    output wire       irq_int0,
    output wire       irq_int1,
    output wire       irq_pcint0,
    output wire       irq_pcint1,
    output wire       irq_pcint2,
    input  wire       ack_int0,
    input  wire       ack_int1,
    input  wire       ack_pcint0,
    input  wire       ack_pcint1,
    input  wire       ack_pcint2
);

    // Direcciones de I/O = dirección del espacio de datos menos 0x20.
    localparam [7:0] A_PCIFR  = 8'h1B;
    localparam [7:0] A_EIFR   = 8'h1C;
    localparam [7:0] A_EIMSK  = 8'h1D;
    localparam [7:0] A_PCICR  = 8'h48;
    localparam [7:0] A_EICRA  = 8'h49;
    localparam [7:0] A_PCMSK0 = 8'h4B;
    localparam [7:0] A_PCMSK1 = 8'h4C;
    localparam [7:0] A_PCMSK2 = 8'h4D;

    wire hit_pcifr  = (io_addr == A_PCIFR);
    wire hit_eifr   = (io_addr == A_EIFR);
    wire hit_eimsk  = (io_addr == A_EIMSK);
    wire hit_pcicr  = (io_addr == A_PCICR);
    wire hit_eicra  = (io_addr == A_EICRA);
    wire hit_pcmsk0 = (io_addr == A_PCMSK0);
    wire hit_pcmsk1 = (io_addr == A_PCMSK1);
    wire hit_pcmsk2 = (io_addr == A_PCMSK2);

    assign io_sel = hit_pcifr | hit_eifr  | hit_eimsk  | hit_pcicr
                  | hit_eicra | hit_pcmsk0 | hit_pcmsk1 | hit_pcmsk2;

    // Sin efectos laterales de lectura: los ocho registros se leen de forma
    // combinacional. El puerto se declara sin usar a propósito, como en
    // axioma_gpio.
    wire unused_io_re = &{1'b0, io_re};

    // ------------------------------------------------------------ registros
    reg [3:0] eicra_q;                    // ISC11 ISC10 ISC01 ISC00
    reg [1:0] eimsk_q;                    // INT1 INT0
    reg [1:0] eifr_q;                     // INTF1 INTF0
    reg [2:0] pcicr_q;                    // PCIE2 PCIE1 PCIE0
    reg [2:0] pcifr_q;                    // PCIF2 PCIF1 PCIF0
    reg [7:0] pcmsk0_q, pcmsk1_q, pcmsk2_q;

    // ------------------------------------------------------- sincronización
    // Una etapa sobre el pad, y una segunda copia RETRASADA UN CICLO que es
    // contra la que se comparan los flancos. Sin la copia no hay flanco que
    // detectar: haría falta comparar el pad con él mismo.
    reg [7:0] syn_b, syn_c, syn_d;
    reg [7:0] prv_b, prv_c, prv_d;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            syn_b <= 8'h00;  syn_c <= 8'h00;  syn_d <= 8'h00;
            prv_b <= 8'h00;  prv_c <= 8'h00;  prv_d <= 8'h00;
        end else if (ce) begin
            syn_b <= pin_b;  syn_c <= pin_c;  syn_d <= pin_d;
            prv_b <= syn_b;  prv_c <= syn_c;  prv_d <= syn_d;
        end
    end

    // ------------------------------------------------------ INT0 e INT1
    // Modos de ISCn: 00 nivel bajo · 01 cualquier flanco · 10 bajada · 11 subida
    wire [1:0] isc0 = eicra_q[1:0];
    wire [1:0] isc1 = eicra_q[3:2];

    wire int0_now = syn_d[2], int0_ant = prv_d[2];
    wire int1_now = syn_d[3], int1_ant = prv_d[3];

    wire int0_ev = (isc0 == 2'b01) ? (int0_now != int0_ant) :
                   (isc0 == 2'b10) ? (~int0_now &  int0_ant) :
                   (isc0 == 2'b11) ? ( int0_now & ~int0_ant) : 1'b0;
    wire int1_ev = (isc1 == 2'b01) ? (int1_now != int1_ant) :
                   (isc1 == 2'b10) ? (~int1_now &  int1_ant) :
                   (isc1 == 2'b11) ? ( int1_now & ~int1_ant) : 1'b0;

    // Nivel bajo: la petición vale mientras el pin esté bajo, y no hay bandera.
    wire int0_nivel = (isc0 == 2'b00) & ~int0_now;
    wire int1_nivel = (isc1 == 2'b00) & ~int1_now;

    // ---------------------------------------------------------- PCINT
    // Un cambio en cualquier pin de la máscara. `|` sobre los bits que
    // cambiaron: el que no esté en PCMSKn no cuenta, ni para la bandera.
    wire pc0_ev = |((syn_b ^ prv_b) & pcmsk0_q);
    wire pc1_ev = |((syn_c ^ prv_c) & pcmsk1_q);
    wire pc2_ev = |((syn_d ^ prv_d) & pcmsk2_q);

    // ------------------------------------------------------------ escritura
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eicra_q  <= 4'h0;
            eimsk_q  <= 2'b00;
            eifr_q   <= 2'b00;
            pcicr_q  <= 3'b000;
            pcifr_q  <= 3'b000;
            pcmsk0_q <= 8'h00;
            pcmsk1_q <= 8'h00;
            pcmsk2_q <= 8'h00;
        end else if (ce) begin
            if (io_we) begin
                if (hit_eicra)  eicra_q  <= io_wdata[3:0];
                if (hit_eimsk)  eimsk_q  <= io_wdata[1:0];
                if (hit_pcicr)  pcicr_q  <= io_wdata[2:0];
                if (hit_pcmsk0) pcmsk0_q <= io_wdata;
                if (hit_pcmsk1) pcmsk1_q <= io_wdata & 8'h7F;  // PC7 no existe
                if (hit_pcmsk2) pcmsk2_q <= io_wdata;
            end

            // Poner gana a limpiar: si el flanco llega en el mismo ciclo en que
            // el programa escribe el uno, la interrupción NO se pierde. Es el
            // mismo criterio que en los temporizadores.
            if (int0_ev)                                    eifr_q[0] <= 1'b1;
            else if (ack_int0 ||
                     (io_we && hit_eifr && io_wdata[0]))    eifr_q[0] <= 1'b0;
            if (int1_ev)                                    eifr_q[1] <= 1'b1;
            else if (ack_int1 ||
                     (io_we && hit_eifr && io_wdata[1]))    eifr_q[1] <= 1'b0;

            if (pc0_ev)                                     pcifr_q[0] <= 1'b1;
            else if (ack_pcint0 ||
                     (io_we && hit_pcifr && io_wdata[0]))   pcifr_q[0] <= 1'b0;
            if (pc1_ev)                                     pcifr_q[1] <= 1'b1;
            else if (ack_pcint1 ||
                     (io_we && hit_pcifr && io_wdata[1]))   pcifr_q[1] <= 1'b0;
            if (pc2_ev)                                     pcifr_q[2] <= 1'b1;
            else if (ack_pcint2 ||
                     (io_we && hit_pcifr && io_wdata[2]))   pcifr_q[2] <= 1'b0;
        end
    end

    // ------------------------------------------------------------- lectura
    // En modo de nivel bajo INTFn se lee como cero SIEMPRE, aunque dentro haya
    // quedado un uno de cuando el modo era otro: la hoja de datos dice que la
    // bandera está siempre limpia en ese modo.
    wire [1:0] eifr_vis = { eifr_q[1] & (isc1 != 2'b00),
                            eifr_q[0] & (isc0 != 2'b00) };

    assign io_rdata = hit_eicra  ? {4'b0000, eicra_q}  :
                      hit_eimsk  ? {6'b0,    eimsk_q}  :
                      hit_eifr   ? {6'b0,    eifr_vis} :
                      hit_pcicr  ? {5'b0,    pcicr_q}  :
                      hit_pcifr  ? {5'b0,    pcifr_q}  :
                      hit_pcmsk0 ? pcmsk0_q            :
                      hit_pcmsk1 ? pcmsk1_q            :
                      hit_pcmsk2 ? pcmsk2_q            : 8'h00;

    // ------------------------------------------------------------ peticiones
    assign flag_intf0 = eifr_vis[0];

    assign irq_int0 = eimsk_q[0] & (int0_nivel | eifr_vis[0]);
    assign irq_int1 = eimsk_q[1] & (int1_nivel | eifr_vis[1]);

    assign irq_pcint0 = pcicr_q[0] & pcifr_q[0];
    assign irq_pcint1 = pcicr_q[1] & pcifr_q[1];
    assign irq_pcint2 = pcicr_q[2] & pcifr_q[2];

endmodule

`default_nettype wire
