// AxiomaCore-328 - top del banco del Timer2
// SPDX-License-Identifier: Apache-2.0
//
// NO forma parte del diseño. Junta el Timer2 con `axioma_prescaler` aunque el
// Timer2 tenga prescaler PROPIO: lo que los une es GTCCR, donde vive el bit
// PSRASY que pone a cero ese prescaler. Sin los dos juntos no se puede
// comprobar ni que PSRASY llegue ni que TSM lo retenga.

`default_nettype none

module tb_timer2_top (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // El oscilador de TOSC1 (PB6). El banco lo conduce como conduciría un
    // cristal de 32 768 Hz: a su ritmo, no al del reloj del sistema.
    input  wire       tosc,

    output wire       oc2a,
    output wire       oc2a_en,
    output wire       oc2b,
    output wire       oc2b_en,

    output wire       irq_ovf,
    output wire       irq_compa,
    output wire       irq_compb,
    input  wire       ack_ovf,
    input  wire       ack_compa,
    input  wire       ack_compb,

    // El prescaler PROPIO del Timer2, para poder comprobar su fase.
    output wire [9:0] presc2_count,

    // Estado interno, igual que en el banco del Timer0: el valor ACTIVO del
    // doble búfer, el sentido de la cuenta y el tapón de la comparación.
    output wire [7:0] dbg_ocra_act,
    output wire [7:0] dbg_ocrb_act,
    output wire       dbg_dir_down,
    output wire       dbg_tcnt_block
);

    wire [7:0] ps_rdata, t2_rdata;
    wire       ps_sel, t2_sel;
    wire       reset_asy;

    axioma_prescaler ps (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(ps_rdata), .io_sel(ps_sel),
        /* verilator lint_off PINCONNECTEMPTY */
        .tick_1(), .tick_8(), .tick_64(), .tick_256(), .tick_1024(),
        .count(),
        /* verilator lint_on PINCONNECTEMPTY */
        .reset_asy(reset_asy)
    );

    axioma_timer2 t2 (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(t2_rdata), .io_sel(t2_sel),
        .presc_reset(reset_asy),
        .tosc(tosc),
        .oc2a(oc2a), .oc2a_en(oc2a_en), .oc2b(oc2b), .oc2b_en(oc2b_en),
        .irq_ovf(irq_ovf), .irq_compa(irq_compa), .irq_compb(irq_compb),
        .ack_ovf(ack_ovf), .ack_compa(ack_compa), .ack_compb(ack_compb)
    );

    assign presc2_count   = t2.pcnt;
    assign dbg_ocra_act   = t2.motor.ocra_act;
    assign dbg_ocrb_act   = t2.motor.ocrb_act;
    assign dbg_dir_down   = t2.motor.dir_down;
    assign dbg_tcnt_block = t2.motor.tcnt_block;

    assign io_rdata = ps_rdata | t2_rdata;
    assign io_sel   = ps_sel | t2_sel;

endmodule

`default_nettype wire
