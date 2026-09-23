// AxiomaCore-328 - cáscara para el banco del prescaler del reloj
// SPDX-License-Identifier: Apache-2.0
//
// `axioma_clkctrl` comprueba su divisor mirando su propia salida. Lo que NO
// puede comprobar es que esa habilitación LLEGUE a alguna parte, y ése es un
// agujero de los grandes: todos los bancos de módulo del proyecto corren con
// `ce` a uno, así que **un módulo al que se le olvide la habilitación pasa
// entero su banco**. No hay nada que lo destape, porque con `CLKPS`=0 el chip
// es bit a bit el de antes — que es justo lo que hace segura la conversión y,
// a la vez, lo que la deja sin verificar.
//
// Aquí se mide por fuera. El SoC ejecuta un programa de verdad que se pone a
// mover un pin, y el banco cuenta CICLOS DEL RELOJ DE ENTRADA entre dos
// transiciones del pin. Si la habilitación llega, el periodo se multiplica por
// dos cada vez que sube `CLKPS`; si a alguien se le olvidó, no.
//
// Y se saca el tic del oscilador del perro guardián, porque la otra mitad de la
// comprobación es que ese NO se divide: es de otro reloj, y de ahí sale que el
// perro pueda morder con el reloj del sistema parado.

`default_nettype none

module tb_soc_clk_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        prog_we,
    input  wire [13:0] prog_addr,
    input  wire [15:0] prog_data,

    output wire [7:0]  pb_out_v,     // lo que el programa saca por el puerto B
    output wire [7:0]  pd_out_v,     // y por el D, donde sale OC0A (PD6)

    // Los tres buses de pull-up, para ver llegar `PUD` a los tres puertos.
    output wire [7:0]  pb_pu_v,
    output wire [7:0]  pc_pu_v,
    output wire [7:0]  pd_pu_v,
    output wire        osc_tick_v,   // el oscilador de 128 kHz, que no se divide
    output wire        wdt_reset_v   // y lo que el perro guardian hace con el
);

    wire [7:0] pb_out, pb_oe, pb_pu, pc_out, pc_oe, pc_pu, pd_out, pd_oe, pd_pu;
    wire [7:0] pb_in = (pb_out & pb_oe) | (pb_pu & ~pb_oe);
    wire [7:0] pc_in = (pc_out & pc_oe) | (pc_pu & ~pc_oe);
    wire [7:0] pd_in = (pd_out & pd_oe) | (pd_pu & ~pd_oe);

    assign pb_out_v = pb_out;
    assign pd_out_v = pd_out;
    assign pb_pu_v  = pb_pu;
    assign pc_pu_v  = pc_pu;
    assign pd_pu_v  = pd_pu;

    wire [3:0] adc_canal;
    wire [1:0] adc_ref;
    wire       adc_muestrea, adc_cmp;
    wire [9:0] adc_dac;
    wire       ac_apagado, ac_bandgap, ac_neg_mux, ac_salida;

    axioma_adc_frente frente (
        .clk(clk), .rst_n(rst_n),
        .canal(adc_canal), .ref_sel(adc_ref), .muestrea(adc_muestrea),
        .dac(adc_dac), .cmp(adc_cmp),
        .ac_apagado(ac_apagado), .ac_bandgap(ac_bandgap),
        .ac_neg_mux(ac_neg_mux), .ac_salida(ac_salida)
    );

    // El oscilador del perro guardián: MISMO divisor que en el resto de los
    // arneses, y a propósito fuera del SoC. No lo toca `CLKPR`, que es lo que
    // este banco comprueba.
    reg [6:0] osc_rc_div;
    wire      osc_rc_tick = (osc_rc_div == 7'd0);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) osc_rc_div <= 7'd97;
        else        osc_rc_div <= osc_rc_tick ? 7'd97 : osc_rc_div - 7'd1;

    assign osc_tick_v = osc_rc_tick;

    // EL REINICIO DEL PERRO NO SE REALIMENTA, a proposito: asi el programa
    // sigue corriendo y el perro vuelve a vencer, y el banco puede medir el
    // INTERVALO entre dos mordiscos. Ese intervalo es tiempo de oscilador puro
    // —no depende de cuanto tardara el programa en armarlo— y tiene que salir
    // el mismo mande lo que mande `CLKPR`.
    wire wdt_reset;
    assign wdt_reset_v = wdt_reset;

    axioma328_soc soc (
        .clk(clk), .rst_n(rst_n),
        .pb_in(pb_in), .pb_out(pb_out), .pb_oe(pb_oe), .pb_pu(pb_pu),
        .pc_in(pc_in), .pc_out(pc_out), .pc_oe(pc_oe), .pc_pu(pc_pu),
        .pd_in(pd_in), .pd_out(pd_out), .pd_oe(pd_oe), .pd_pu(pd_pu),
        .adc_canal(adc_canal), .adc_ref(adc_ref),
        .adc_muestrea(adc_muestrea), .adc_dac(adc_dac), .adc_cmp(adc_cmp),
        .ac_apagado(ac_apagado), .ac_bandgap(ac_bandgap),
        .ac_neg_mux(ac_neg_mux), .ac_salida(ac_salida),
        .osc_rc_tick(osc_rc_tick), .wdt_reset(wdt_reset),
        /* verilator lint_off PINCONNECTEMPTY */
        .dbg_pc(), .dbg_ir(), .dbg_retire(), .dbg_illegal(), .dbg_irq_entry(),
        .dbg_irq_vector(), .dbg_sp(), .dbg_sreg(), .dbg_reg_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .dbg_reg_addr(5'd0)
    );

    always @(posedge clk)
        if (prog_we) soc.pm.mem[prog_addr] <= prog_data;

endmodule

`default_nettype wire
