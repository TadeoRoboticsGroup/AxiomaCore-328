// AxiomaCore-328 - top del banco del Timer1
// SPDX-License-Identifier: Apache-2.0
//
// El Timer1 con el prescaler COMPARTIDO, por el mismo motivo que el del
// Timer0: la trampa nº 12 sólo se ve con los dos juntos. Y saca el estado
// interno que no aparece en ningún registro —el valor ACTIVO del doble búfer,
// el sentido de la cuenta y el propio TEMP—, porque comparar sólo lo visible
// da por buenas divergencias que se notan un periodo después.

`default_nettype none

module tb_timer1_top (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    input  wire       t1_pin,
    input  wire       icp1_pin,

    output wire       oc1a,
    output wire       oc1a_en,
    output wire       oc1b,
    output wire       oc1b_en,

    output wire       irq_capt,
    output wire       irq_compa,
    output wire       irq_compb,
    output wire       irq_ovf,
    input  wire       ack_capt,
    input  wire       ack_compa,
    input  wire       ack_compb,
    input  wire       ack_ovf,

    output wire [15:0] dbg_tcnt,
    output wire [15:0] dbg_ocra_act,
    output wire [15:0] dbg_ocrb_act,
    output wire [15:0] dbg_icr,
    output wire [7:0]  dbg_temp,
    output wire        dbg_dir_down
);

    wire tick_1, tick_8, tick_64, tick_256, tick_1024;
    wire [7:0] ps_rd, t1_rd;
    wire       ps_sel, t1_sel;

    axioma_prescaler ps (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(ps_rd), .io_sel(ps_sel),
        .tick_1(tick_1), .tick_8(tick_8), .tick_64(tick_64),
        .tick_256(tick_256), .tick_1024(tick_1024),
        /* verilator lint_off PINCONNECTEMPTY */
        .reset_asy(),                    // es del Timer2, que no esta aqui
        .count()
        /* verilator lint_on PINCONNECTEMPTY */
    );

    axioma_timer1 t1 (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(t1_rd), .io_sel(t1_sel),
        .tick_1(tick_1), .tick_8(tick_8), .tick_64(tick_64),
        .tick_256(tick_256), .tick_1024(tick_1024),
        .t1_pin(t1_pin), .icp1_pin(icp1_pin),
        .oc1a(oc1a), .oc1a_en(oc1a_en), .oc1b(oc1b), .oc1b_en(oc1b_en),
        /* verilator lint_off PINCONNECTEMPTY */
        .flags_tifr(),                   // las banderas crudas son para el
                                         // disparo del ADC, y el ADC no esta
                                         // aqui: este banco mira el registro
        /* verilator lint_on PINCONNECTEMPTY */
        .irq_capt(irq_capt), .irq_compa(irq_compa),
        .irq_compb(irq_compb), .irq_ovf(irq_ovf),
        .ack_capt(ack_capt), .ack_compa(ack_compa),
        .ack_compb(ack_compb), .ack_ovf(ack_ovf)
    );

    assign io_rdata = ps_rd | t1_rd;
    assign io_sel   = ps_sel | t1_sel;

    assign dbg_tcnt     = t1.tcnt;
    assign dbg_ocra_act = t1.ocra_act;
    assign dbg_ocrb_act = t1.ocrb_act;
    assign dbg_icr      = t1.icr;
    assign dbg_temp     = t1.temp;
    assign dbg_dir_down = t1.dir_down;

endmodule

`default_nettype wire
