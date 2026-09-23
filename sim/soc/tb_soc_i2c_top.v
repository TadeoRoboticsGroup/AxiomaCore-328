// AxiomaCore-328 - cáscara para el barrido de direcciones I2C
// SPDX-License-Identifier: Apache-2.0
//
// Las otras cáscaras del proyecto modelan los pines en lazo cerrado: un pin de
// salida se lee a sí mismo. Para el TWI eso no sirve, y no por comodidad: `SDA`
// y `SCL` son de **colector abierto**, o sea que nadie saca un uno — se tira a
// cero o se suelta, y el uno lo pone la resistencia. Un esclavo contesta
// **tirando de la línea que el maestro acaba de soltar**, y sin modelar eso no
// hay bus, hay dos cables.
//
// Así que aquí las dos líneas se resuelven con una **Y cableada** entre lo que
// tira el chip y lo que tira el banco, y el resultado vuelve a entrar por el
// pin. Es el mismo modelo que usa el banco del periférico; lo que cambia es que
// aquí al otro lado hay un SoC entero ejecutando un programa.

`default_nettype none

module tb_soc_i2c_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        prog_we,
    input  wire [13:0] prog_addr,
    input  wire [15:0] prog_data,

    // Lo que tira el ESCLAVO del banco, activo a uno = tira a cero.
    input  wire        esc_sda_pull,
    input  wire        esc_scl_pull,

    // El estado del bus, para que el modelo del esclavo lo muestree.
    output wire        bus_sda,
    output wire        bus_scl,

    // Por donde el programa cuenta lo que encuentra.
    output wire [7:0]  pb_out_v,
    output wire [7:0]  pd_out_v
);

    wire [7:0] pb_out, pb_oe, pb_pu, pc_out, pc_oe, pc_pu, pd_out, pd_oe, pd_pu;

    assign pb_out_v = pb_out;
    assign pd_out_v = pd_out;

    // Los puertos B y D, en lazo cerrado como siempre.
    wire [7:0] pb_in = (pb_out & pb_oe) | (pb_pu & ~pb_oe);
    wire [7:0] pd_in = (pd_out & pd_oe) | (pd_pu & ~pd_oe);

    // EL PUERTO C, CON SUS DOS LINEAS DE BUS APARTE. PC4 es `SDA` y PC5 es
    // `SCL`. El chip «tira» cuando conduce un cero; si conduce un uno o no
    // conduce, suelta. La linea vale uno si NADIE tira.
    wire chip_sda_pull = pc_oe[4] & ~pc_out[4];
    wire chip_scl_pull = pc_oe[5] & ~pc_out[5];

    assign bus_sda = ~(chip_sda_pull | esc_sda_pull);
    assign bus_scl = ~(chip_scl_pull | esc_scl_pull);

    wire [7:0] pc_lazo = (pc_out & pc_oe) | (pc_pu & ~pc_oe);
    wire [7:0] pc_in   = {pc_lazo[7:6], bus_scl, bus_sda, pc_lazo[3:0]};

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

    reg [6:0] osc_rc_div;
    wire      osc_rc_tick = (osc_rc_div == 7'd0);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) osc_rc_div <= 7'd97;
        else        osc_rc_div <= osc_rc_tick ? 7'd97 : osc_rc_div - 7'd1;

    wire wdt_reset;
    // `pc_lazo[5:4]` no se usa a proposito: esos dos pines no van por el
    // modelo de lazo cerrado sino por la Y cableada del bus.
    wire unused_wdt = &{1'b0, wdt_reset, pc_pu, pc_lazo[5:4]};

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
