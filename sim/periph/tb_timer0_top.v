// AxiomaCore-328 - top del banco del Timer0
// SPDX-License-Identifier: Apache-2.0
//
// NO forma parte del diseño. Junta el temporizador con el prescaler compartido
// porque los dos son inseparables: la trampa nº 12 —que el prescaler es libre y
// no se reinicia al arrancar el temporizador— sólo se puede comprobar con los
// dos juntos.

`default_nettype none

module tb_timer0_top (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    input  wire       t0_pin,

    output wire       oc0a,
    output wire       oc0a_en,
    output wire       oc0b,
    output wire       oc0b_en,

    output wire       irq_ovf,
    output wire       irq_compa,
    output wire       irq_compb,
    input  wire       ack_ovf,
    input  wire       ack_compa,
    input  wire       ack_compb,

    output wire [9:0] presc_count,

    // Estado interno, para que el banco compare también lo que no sale por
    // ningún registro: el valor ACTIVO del doble búfer, el sentido de la
    // cuenta y el tapón de la comparación. Un modelo que sólo mira los
    // registros da por buenas divergencias que sólo se notan un periodo
    // después, cuando ya no se sabe de dónde salieron.
    output wire [7:0] dbg_ocra_act,
    output wire [7:0] dbg_ocrb_act,
    output wire       dbg_dir_down,
    output wire       dbg_tcnt_block
);

    wire tick_1, tick_8, tick_64, tick_256, tick_1024;
    wire [7:0] ps_rdata, t0_rdata;
    wire       ps_sel, t0_sel;

    axioma_prescaler ps (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(ps_rdata), .io_sel(ps_sel),
        .tick_1(tick_1), .tick_8(tick_8), .tick_64(tick_64),
        .tick_256(tick_256), .tick_1024(tick_1024),
        /* verilator lint_off PINCONNECTEMPTY */
        .reset_asy(),                    // es del Timer2, que no esta aqui
        /* verilator lint_on PINCONNECTEMPTY */
        .count(presc_count)
    );

    axioma_timer0 t0 (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(t0_rdata), .io_sel(t0_sel),
        .tick_1(tick_1), .tick_8(tick_8), .tick_64(tick_64),
        .tick_256(tick_256), .tick_1024(tick_1024),
        .t0_pin(t0_pin),
        .oc0a(oc0a), .oc0a_en(oc0a_en), .oc0b(oc0b), .oc0b_en(oc0b_en),
        /* verilator lint_off PINCONNECTEMPTY */
        .flags_tifr(),                   // las banderas crudas son para el
                                         // disparo del ADC, y el ADC no esta
                                         // aqui: este banco mira el registro
        /* verilator lint_on PINCONNECTEMPTY */
        .irq_ovf(irq_ovf), .irq_compa(irq_compa), .irq_compb(irq_compb),
        .ack_ovf(ack_ovf), .ack_compa(ack_compa), .ack_compb(ack_compb)
    );

    assign dbg_ocra_act   = t0.motor.ocra_act;
    assign dbg_ocrb_act   = t0.motor.ocrb_act;
    assign dbg_dir_down   = t0.motor.dir_down;
    assign dbg_tcnt_block = t0.motor.tcnt_block;

    assign io_rdata = ps_rdata | t0_rdata;
    assign io_sel   = ps_sel | t0_sel;

endmodule

`default_nettype wire
