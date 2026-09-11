// AxiomaCore-328 - cáscara para el banco de extremo a extremo
// SPDX-License-Identifier: Apache-2.0
//
// El SoC entero con un programa de verdad dentro, y los pines a la vista para
// que el banco los lea como los leería un osciloscopio: el puerto serie por
// TXD y el LED por PORTB.
//
// Saca además la configuración del generador de baudios. No es para decodificar
// «con ventaja»: el banco decodifica con el ritmo que el PROGRAMA ha
// configurado, y luego comprueba aparte que ese ritmo esté dentro de la
// tolerancia del baudio nominal. Así se separan dos preguntas que no son la
// misma: si la trama está bien formada, y si va a la velocidad que debería.

`default_nettype none

module tb_soc_uart_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        prog_we,
    input  wire [13:0] prog_addr,
    input  wire [15:0] prog_data,

    output wire        txd,
    output wire        txd_en,
    output wire [7:0]  portb,
    output wire [7:0]  portb_oe,

    output wire [11:0] dbg_ubrr,
    output wire        dbg_u2x
);

    wire [7:0] pb_out, pb_oe, pb_pu, pc_out, pc_oe, pc_pu, pd_out, pd_oe, pd_pu;
    wire [7:0] pb_in = (pb_out & pb_oe) | (pb_pu & ~pb_oe);
    wire [7:0] pc_in = (pc_out & pc_oe) | (pc_pu & ~pc_oe);
    wire [7:0] pd_in = (pd_out & pd_oe) | (pd_pu & ~pd_oe);

    axioma328_soc soc (
        .clk(clk), .rst_n(rst_n),
        .pb_in(pb_in), .pb_out(pb_out), .pb_oe(pb_oe), .pb_pu(pb_pu),
        .pc_in(pc_in), .pc_out(pc_out), .pc_oe(pc_oe), .pc_pu(pc_pu),
        .pd_in(pd_in), .pd_out(pd_out), .pd_oe(pd_oe), .pd_pu(pd_pu),
        // Nada conectado a la entrada del puerto serie: en reposo, que es el 1.
        .uart_rxd(1'b1), .uart_txd(txd), .uart_txd_en(txd_en),
        /* verilator lint_off PINCONNECTEMPTY */
        .dbg_pc(), .dbg_ir(), .dbg_retire(), .dbg_illegal(), .dbg_irq_entry(),
        .dbg_irq_vector(), .dbg_sp(), .dbg_sreg(), .dbg_reg_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .dbg_reg_addr(5'd0)
    );

    always @(posedge clk)
        if (prog_we) soc.pm.mem[prog_addr] <= prog_data;

    assign portb    = pb_out;
    assign portb_oe = pb_oe;
    assign dbg_ubrr = soc.usart.ubrr;
    assign dbg_u2x  = soc.usart.u2x;

endmodule

`default_nettype wire
