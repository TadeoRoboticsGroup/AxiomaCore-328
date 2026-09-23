// AxiomaCore-328 - cáscara para el banco del disparo automático del ADC
// SPDX-License-Identifier: Apache-2.0
//
// El banco de `axioma_adc` comprueba que el módulo dispara con la bandera que
// le llega por `adc_trig[ADTS]`. Lo que NO puede comprobar es que el cable
// número tres venga de `OCF0A` y no de `OCF1A`: eso se decide en el SoC, en una
// tabla de ocho líneas, y una permutación ahí pasa TODOS los bancos de módulo.
//
// Es la misma lección del mapa de pines —si nadie mira el pin, el mapa no está
// verificado—, y la respuesta es la misma: provocar cada fuente POR SU CAMINO
// REAL. Un programa de verdad configura el periférico de verdad, la bandera
// sube por donde sube en el chip, y desde fuera se mira si el ADC arrancó.
//
// Por eso esta cáscara saca dos cosas que el top de simulación normal no saca:
//
//   `ac_forzada`, para mover la salida del comparador desde el banco y fabricar
//   un flanco de `ACI` cuando se quiera —el modelo analógico la mueve sola, y
//   para esto hace falta mandar sobre ella—;
//   `adc_muestrea`, que es el pulso del S/H y por tanto la prueba observable de
//   que una conversión EMPEZÓ.
//
// Los pines siguen siendo el mismo modelo de pad de siempre, así que un
// programa que ponga PD2 como salida y la suba se fabrica su propio `INT0`, y
// uno que mueva PB0 se fabrica su propio `ICP1`.

`default_nettype none

module tb_soc_trig_top (
    input  wire        clk,
    input  wire        rst_n,

    input  wire        prog_we,
    input  wire [13:0] prog_addr,
    input  wire [15:0] prog_data,

    // la salida del comparador, en manos del banco
    input  wire        ac_forzada,

    // la prueba de que una conversión empezó
    output wire        adc_muestrea
);

    wire [7:0] pb_out, pb_oe, pb_pu, pc_out, pc_oe, pc_pu, pd_out, pd_oe, pd_pu;
    wire [7:0] pb_in = (pb_out & pb_oe) | (pb_pu & ~pb_oe);
    wire [7:0] pc_in = (pc_out & pc_oe) | (pc_pu & ~pc_oe);
    wire [7:0] pd_in = (pd_out & pd_oe) | (pd_pu & ~pd_oe);

    wire [3:0] adc_canal;
    wire [1:0] adc_ref;
    wire [9:0] adc_dac;
    wire       adc_cmp;
    wire       ac_apagado, ac_bandgap, ac_neg_mux;

    // El frente analógico del ADC sigue siendo el de siempre —la conversión
    // tiene que poder terminar—, pero su `ac_salida` se tira a la basura: aquí
    // manda el banco.
    wire ac_del_modelo;
    axioma_adc_frente frente (
        .clk(clk), .rst_n(rst_n),
        .canal(adc_canal), .ref_sel(adc_ref), .muestrea(adc_muestrea),
        .dac(adc_dac), .cmp(adc_cmp),
        .ac_apagado(ac_apagado), .ac_bandgap(ac_bandgap),
        .ac_neg_mux(ac_neg_mux), .ac_salida(ac_del_modelo)
    );
    wire unused_frente = &{1'b0, ac_del_modelo};

    reg [6:0] osc_rc_div;
    wire      osc_rc_tick = (osc_rc_div == 7'd0);
    always @(posedge clk or negedge rst_n)
        if (!rst_n) osc_rc_div <= 7'd97;
        else        osc_rc_div <= osc_rc_tick ? 7'd97 : osc_rc_div - 7'd1;

    wire wdt_reset;
    wire unused_wdt_rst = &{1'b0, wdt_reset};

    axioma328_soc soc (
        .clk(clk), .rst_n(rst_n),
        .pb_in(pb_in), .pb_out(pb_out), .pb_oe(pb_oe), .pb_pu(pb_pu),
        .pc_in(pc_in), .pc_out(pc_out), .pc_oe(pc_oe), .pc_pu(pc_pu),
        .pd_in(pd_in), .pd_out(pd_out), .pd_oe(pd_oe), .pd_pu(pd_pu),
        .adc_canal(adc_canal), .adc_ref(adc_ref),
        .adc_muestrea(adc_muestrea), .adc_dac(adc_dac), .adc_cmp(adc_cmp),
        .ac_apagado(ac_apagado), .ac_bandgap(ac_bandgap),
        .ac_neg_mux(ac_neg_mux), .ac_salida(ac_forzada),
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
