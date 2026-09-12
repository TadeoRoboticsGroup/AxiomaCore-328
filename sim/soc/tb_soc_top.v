// AxiomaCore-328 - cáscara para el banco del mapa de I/O
// SPDX-License-Identifier: Apache-2.0
//
// Instancia el SoC de verdad y saca a la superficie el `io_sel` de CADA
// periférico por separado. Desde fuera del chip sólo se ve el OR de todos, y
// con el OR una colisión —dos periféricos reclamando la misma dirección— es
// invisible: `io_sel` valdría 1 igual y `io_rdata` devolvería los dos valores
// mezclados sin que nada proteste.
//
// El barrido se hace POR EL CAMINO REAL: el banco carga un programa de
// instrucciones `LDS` que leen todas las direcciones del espacio de I/O, y el
// núcleo las presenta al bus como lo haría cualquier programa. No se fuerza
// ninguna señal interna: lo que se comprueba es el chip funcionando.

`default_nettype none

module tb_soc_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        prog_we,
    input  wire [13:0] prog_addr,
    input  wire [15:0] prog_data,

    // Lo que hay en el bus de periféricos en este ciclo
    output wire [7:0]  io_addr,
    output wire        io_re,
    output wire        io_we,
    output wire        io_sel,

    // Quién reclama la dirección. Un bit por periférico.
    output wire        sel_gpio_b,
    output wire        sel_gpio_c,
    output wire        sel_gpio_d,
    output wire        sel_gpior,
    output wire        sel_presc,
    output wire        sel_timer0,
    output wire        sel_usart,
    output wire        sel_timer1,
    output wire        sel_extint,
    output wire        sel_timer2,
    output wire        sel_spi,

    output wire [7:0]  io_rdata
);

    // Modelo de pad, igual que en el arnés diferencial: sin nada conectado por
    // fuera, un pin de salida se lee a sí mismo y uno de entrada con pull-up
    // lee 1.
    wire [7:0] pb_out, pb_oe, pb_pu, pc_out, pc_oe, pc_pu, pd_out, pd_oe, pd_pu;
    wire [7:0] pb_in = (pb_out & pb_oe) | (pb_pu & ~pb_oe);
    wire [7:0] pc_in = (pc_out & pc_oe) | (pc_pu & ~pc_oe);
    wire [7:0] pd_in = (pd_out & pd_oe) | (pd_pu & ~pd_oe);

    axioma328_soc soc (
        .clk(clk), .rst_n(rst_n),
        .pb_in(pb_in), .pb_out(pb_out), .pb_oe(pb_oe), .pb_pu(pb_pu),
        .pc_in(pc_in), .pc_out(pc_out), .pc_oe(pc_oe), .pc_pu(pc_pu),
        .pd_in(pd_in), .pd_out(pd_out), .pd_oe(pd_oe), .pd_pu(pd_pu),
        .uart_rxd(1'b1),
        /* verilator lint_off PINCONNECTEMPTY */
        .uart_txd(), .uart_txd_en(),
        .dbg_pc(), .dbg_ir(), .dbg_retire(), .dbg_illegal(), .dbg_irq_entry(),
        .dbg_irq_vector(), .dbg_sp(), .dbg_sreg(), .dbg_reg_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .dbg_reg_addr(5'd0)
    );

    always @(posedge clk)
        if (prog_we) soc.pm.mem[prog_addr] <= prog_data;

    assign io_addr    = soc.io_addr;
    assign io_re      = soc.io_re;
    assign io_we      = soc.io_we;
    assign io_sel     = soc.io_sel;
    assign io_rdata   = soc.io_rdata;

    assign sel_gpio_b = soc.gb_sel;
    assign sel_gpio_c = soc.gc_sel;
    assign sel_gpio_d = soc.gd_sel;
    assign sel_gpior  = soc.gr_sel;
    assign sel_presc  = soc.ps_sel;
    assign sel_timer0 = soc.tm_sel;
    assign sel_usart  = soc.us_sel;
    assign sel_timer1 = soc.t1_sel;
    assign sel_extint = soc.ei_sel;
    assign sel_timer2 = soc.t2_sel;
    assign sel_spi    = soc.sp_sel;

endmodule

`default_nettype wire
