// AxiomaCore-328 - top de la placa ULX3S (ECP5 25F)
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Lo que rodea al chip para que funcione en una placa: reloj, reset, y celdas
// de pad de verdad. El dispositivo es `axioma328_soc`; aquí no hay lógica de
// AVR, y no debe haberla.
//
// EL RELOJ: 12,5 MHz, Y LA HISTORIA DE POR QUÉ NO SON 16.
//
// Primero: el PLL del ECP5 NO PUEDE sacar exactamente 16 MHz de los 25 de la
// placa. La salida es (25/D)·M, así que 16 exige M/D = 16/25, y como 16 y 25
// son primos entre sí, D tiene que ser múltiplo de 25 — lo que deja el
// comparador de fase en 1 MHz o menos, por debajo del mínimo del ECP5. Lo más
// cercano exacto es 15,625 MHz.
//
// Segundo: a 15,625 MHz EL DISEÑO NO CIERRA TIMING. nextpnr da 14,74 MHz, y el
// camino crítico es de flanco de subida a flanco de BAJADA: sale de la BRAM de
// la memoria de programa —5,8 ns de clk a dato—, cruza el decodificador y llega
// a la memoria de datos, que va en flanco de bajada por el ADR 0001. Todo eso
// tiene que caber en MEDIO ciclo. Es el precio de la exactitud de ciclos, y
// está medido, no estimado.
//
// Así que se corre a 12,5 MHz, la mitad justa del oscilador, con un 15 % de
// margen sobre lo que el diseño aguanta hoy. Lo que importa no es el número
// sino que sea EXACTO: con `F_CPU=12500000` la cuenta de `millis()` y los
// divisores de baudios salen sin error. Subirlo es trabajo de optimización de
// timing, con un objetivo ya escrito en el plan: 32 MHz en la fase 5.
//
// EL PULL-UP NO ES DINÁMICO EN LA FPGA, y es una diferencia conocida. El SoC
// DECLARA el pull-up por pin (`pX_pu`), como hace el 328P, pero en el ECP5 el
// modo de pull-up es un atributo ESTÁTICO del bloque de E/S: se fija en el
// `.lpf` y no se puede conmutar desde la lógica. Aquí los puertos van con
// PULLMODE=UP fijo, de modo que un pin de entrada sin nada conectado se lee 1.
// Eso coincide con el chip cuando el programa activa el pull-up y NO coincide
// cuando lo apaga —caso que la hoja de datos deja indefinido de todas formas,
// porque un pad real queda flotando—. Resolverlo de verdad pide una celda de
// E/S con pull-up conmutable, que es de la fase 5.
//
// wifi_gpio0 HAY QUE CONDUCIRLO A 1. Si se deja flotando, el ESP32 de la placa
// arranca en modo programación y reinicia la FPGA. No es opcional.

`default_nettype none

module axioma_ulx3s_top #(
    // Programa precargado en la memoria de programa del bitstream. Lo genera
    // `tools/bin2mem.py` a partir del .bin que produce avr-gcc.
    // VACÍO POR DEFECTO, y es importante: el RTL no puede depender de un
    // artefacto de compilación. Con una ruta por defecto, sintetizar en una
    // copia recién clonada fallaba con «Can not open file for $readmemh», que
    // es exactamente lo que rompió la CI. Sin programa, la memoria queda a
    // 0x0000 —NOP— y el diseño sintetiza igual.
    //
    // El programa se lo pasa quien hace el bitstream, con `chparam`.
    parameter INIT_HEX = ""
)(
    input  wire       clk_25mhz,
    input  wire       btn_reset,      // FIRE1, activo ALTO en la placa
    output wire       wifi_gpio0,

    output wire [7:0] led,

    inout  wire [7:0] portb_io,
    inout  wire [6:0] portc_io,       // PC7 no existe en el 328P
    inout  wire [7:0] portd_io,

    output wire       uart_tx,
    input  wire       uart_rx
);

    // --------------------------------------------------------------- reloj
    wire clk, pll_locked;

    axioma_pll pll (
        .clk_in(clk_25mhz),
        .clk_out(clk),
        .locked(pll_locked)
    );

    // --------------------------------------------------------------- reset
    // Se mantiene el reset hasta que el PLL engancha Y han pasado unos ciclos
    // más, porque la memoria de programa del bitstream necesita que el reloj
    // sea estable antes de la primera búsqueda. El botón lo fuerza en
    // cualquier momento; en la placa es activo ALTO.
    // EL VALOR DE ENCENDIDO ES HARDWARE DE VERDAD EN UNA FPGA: lo fija el
    // bitstream al configurar el dispositivo, y es lo único que hay antes de
    // que exista ninguna señal de reset. Verilator avisa porque en simulación
    // la inicialización en la declaración y la asignación procedural son
    // ambiguas; aquí no lo son, y por eso se silencia con el motivo al lado en
    // vez de reescribirlo peor.
    /* verilator lint_off PROCASSINIT */
    reg [7:0] rst_cnt = 8'h00;
    reg       rst_n_q = 1'b0;
    /* verilator lint_on PROCASSINIT */

    always @(posedge clk) begin
        if (!pll_locked || btn_reset) begin
            rst_cnt <= 8'h00;
            rst_n_q <= 1'b0;
        end else if (!rst_cnt[7]) begin
            rst_cnt <= rst_cnt + 8'd1;
            rst_n_q <= 1'b0;
        end else begin
            rst_n_q <= 1'b1;
        end
    end

    // ------------------------------------------------------ celdas de pad
    wire [7:0] pb_out, pb_oe, pb_pu, pd_out, pd_oe, pd_pu;
    wire [7:0] pc_out, pc_oe, pc_pu;
    wire [7:0] pb_in, pd_in;
    wire [7:0] pc_in;

    // Un pin conduce cuando su DDRx lo pone a salida; si no, queda en alta
    // impedancia y se lee lo que haya fuera. Es exactamente lo que hace el
    // 328P, salvo por el pull-up estático que se explica arriba.
    genvar i;
    generate
        for (i = 0; i < 8; i = i + 1) begin : g_pb
            assign portb_io[i] = pb_oe[i] ? pb_out[i] : 1'bz;
            assign pb_in[i]    = portb_io[i];
        end
        for (i = 0; i < 7; i = i + 1) begin : g_pc
            assign portc_io[i] = pc_oe[i] ? pc_out[i] : 1'bz;
            assign pc_in[i]    = portc_io[i];
        end
        for (i = 0; i < 8; i = i + 1) begin : g_pd
            assign portd_io[i] = pd_oe[i] ? pd_out[i] : 1'bz;
            assign pd_in[i]    = portd_io[i];
        end
    endgenerate

    // PC7 NO EXISTE en el ATmega328P. El SoC lo enmascara y expone los ocho
    // bits por uniformidad, así que aquí la entrada se ata a cero y la salida y
    // la dirección del bit 7 se declaran sin usar a propósito: no hay pad al
    // que llevarlas.
    assign pc_in[7] = 1'b0;
    wire unused_pc7 = &{1'b0, pc_out[7], pc_oe[7]};

    // El pull-up declarado por el SoC no se puede aplicar desde la lógica en el
    // ECP5 (ver la cabecera). Se declara sin usar a propósito, en vez de
    // borrarlo del SoC: en silicio sí se conecta a la celda del PDK.
    wire unused_pu = &{1'b0, pb_pu, pc_pu, pd_pu};

    wire soc_txd, soc_txd_en;

    // ---------------------------------------------------------- el chip
    axioma328_soc #(.INIT_HEX(INIT_HEX)) soc (
        .clk(clk), .rst_n(rst_n_q),
        .pb_in(pb_in), .pb_out(pb_out), .pb_oe(pb_oe), .pb_pu(pb_pu),
        .pc_in(pc_in), .pc_out(pc_out), .pc_oe(pc_oe), .pc_pu(pc_pu),
        .pd_in(pd_in), .pd_out(pd_out), .pd_oe(pd_oe), .pd_pu(pd_pu),
        .uart_rxd(uart_rx), .uart_txd(soc_txd), .uart_txd_en(soc_txd_en),
        /* verilator lint_off PINCONNECTEMPTY */
        .dbg_pc(), .dbg_ir(), .dbg_retire(), .dbg_illegal(), .dbg_irq_entry(),
        .dbg_irq_vector(), .dbg_sp(), .dbg_sreg(), .dbg_reg_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .dbg_reg_addr(5'd0)
    );

    // --------------------------------------------------------- los LED
    // PORTB espejado en los ocho LED de la placa. El LED de toda la vida de
    // Arduino es el pin 13, que es PB5, así que un Blink.ino sin tocar
    // parpadea en led[5] y además se ve en el pin.
    assign led = pb_out & pb_oe;

    // La USART sale directamente al conversor USB-serie de la placa. Cuando el
    // transmisor no está habilitado, la línea queda en reposo —el 1 de un
    // UART—, que es lo que ve el PC mientras el programa no abre el puerto.
    assign uart_tx = soc_txd_en ? soc_txd : 1'b1;

    // Sin esto el ESP32 reinicia la placa.
    assign wifi_gpio0 = 1'b1;

endmodule

`default_nettype wire
