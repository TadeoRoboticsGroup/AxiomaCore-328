// AxiomaCore-328 - top de simulación para la co-simulación diferencial
// SPDX-License-Identifier: Apache-2.0
//
// NO forma parte del diseño. Cablea el núcleo con el bus, las memorias y los
// periféricos que ya existen, y añade un puerto de carga de programa que sólo
// existe en simulación.
//
// CÓMO CRECE ESTE FICHERO. Cada periférico que aterriza se enchufa aquí y deja
// de estar cubierto por el array de I/O plano. Ese array es el relleno: modela
// como memoria normal todo lo que todavía no tiene periférico de verdad, para
// que los programas de prueba puedan usar direcciones libres —los GPIOR— sin
// que el contraste contra simavr se rompa.
//
// Los programas de prueba deben seguir EVITANDO los periféricos que simavr
// modela y aquí todavía no existen. Ahora mismo ya existen de verdad los tres
// puertos de E/S; SPL, SPH y SREG los intercepta axioma_core antes del bus.
//
// MODELO DE PAD. Sin nada conectado por fuera:
//   - un pin de SALIDA se lee a sí mismo;
//   - uno de ENTRADA con el pull-up activado (su bit de PORTx a 1) se lee 1,
//     que es lo que hace un chip real;
//   - uno de entrada sin pull-up queda flotando y se modela como 0.
// Las tres cosas juntas equivalen a que el pad siga a PORTx, pero se escriben
// por separado porque el motivo de cada una es distinto y en la FPGA se
// traducen a bits distintos del bloque de E/S.

`default_nettype none

module axioma_sim_top (
    input  wire        clk,
    input  wire        rst_n,

    // Carga de programa, solo simulación
    input  wire        prog_we,
    input  wire [13:0] prog_addr,
    input  wire [15:0] prog_data,

    // Observación
    output wire [13:0] dbg_pc,
    output wire [15:0] dbg_ir,
    output wire        dbg_retire,
    output wire        dbg_illegal,
    output wire [15:0] dbg_sp,
    output wire [7:0]  dbg_sreg,
    input  wire [4:0]  dbg_reg_addr,
    output wire [7:0]  dbg_reg_data,
    input  wire [15:0] dbg_mem_addr,
    output wire [7:0]  dbg_mem_data
);

    localparam [15:0] IO_BASE   = 16'h0020;
    localparam [15:0] SRAM_BASE = 16'h0100;
    localparam [15:0] SRAM_END  = 16'h08FF;

    // ----------------------------------------------------- memoria de programa
    wire [13:0] c_pm_if_addr, c_pm_d_addr;
    wire        c_pm_if_en, c_pm_d_en, c_pm_d_we;
    wire [15:0] c_pm_d_wdata, pm_if_data, pm_d_rdata;

    axioma_progmem pm (
        .clk(clk),
        .if_addr(c_pm_if_addr), .if_en(c_pm_if_en), .if_data(pm_if_data),
        .d_addr(prog_we ? prog_addr : c_pm_d_addr),
        .d_en(prog_we | c_pm_d_en),
        .d_we(prog_we | c_pm_d_we),
        .d_wdata(prog_we ? prog_data : c_pm_d_wdata),
        .d_rdata(pm_d_rdata)
    );

    // ------------------------------------------------------ núcleo y bus
    wire [15:0] dm_addr;
    wire        dm_re, dm_we;
    wire [7:0]  dm_wdata, dm_rdata;

    wire [10:0] sram_addr;
    wire        sram_en, sram_we;
    wire [7:0]  sram_wdata, sram_rdata;

    wire [7:0]  io_addr;
    wire        io_re, io_we;
    wire [7:0]  io_wdata, io_rdata;
    wire        io_sel;

    axioma_dbus bus (
        .clk(clk), .rst_n(rst_n),
        .addr(dm_addr), .re(dm_re), .we(dm_we), .wdata(dm_wdata), .rdata(dm_rdata),
        .sram_addr(sram_addr), .sram_en(sram_en), .sram_we(sram_we),
        .sram_wdata(sram_wdata), .sram_rdata(sram_rdata),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_sel(io_sel)
    );

    axioma_dmem dm (
        .clk(clk), .addr(sram_addr), .en(sram_en), .we(sram_we),
        .wdata(sram_wdata), .rdata(sram_rdata)
    );

    // ------------------------------------------------------ puertos de E/S
    wire [7:0] gb_rd, gc_rd, gd_rd;
    wire       gb_sel, gc_sel, gd_sel;
    wire [7:0] gb_out, gb_oe, gb_pu, gc_out, gc_oe, gc_pu, gd_out, gd_oe, gd_pu;

    wire [7:0] pb_in = (gb_out & gb_oe) | (gb_pu & ~gb_oe);
    wire [7:0] pc_in = (gc_out & gc_oe) | (gc_pu & ~gc_oe);
    wire [7:0] pd_in = (gd_out & gd_oe) | (gd_pu & ~gd_oe);

    axioma_gpio #(.IO_PIN(8'h03), .BITS(8'hFF)) gpio_b (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gb_rd), .io_sel(gb_sel),
        .pad_in(pb_in), .pad_out(gb_out), .pad_oe(gb_oe), .pad_pullup(gb_pu)
    );
    // El puerto C sólo tiene siete bits: PC7 no existe en el encapsulado.
    axioma_gpio #(.IO_PIN(8'h06), .BITS(8'h7F)) gpio_c (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gc_rd), .io_sel(gc_sel),
        .pad_in(pc_in), .pad_out(gc_out), .pad_oe(gc_oe), .pad_pullup(gc_pu)
    );
    axioma_gpio #(.IO_PIN(8'h09), .BITS(8'hFF)) gpio_d (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gd_rd), .io_sel(gd_sel),
        .pad_in(pd_in), .pad_out(gd_out), .pad_oe(gd_oe), .pad_pullup(gd_pu)
    );

    wire periph_sel = gb_sel | gc_sel | gd_sel;

    // ------------------------------------------ relleno: I/O plana, 224 bytes
    // Sólo responde donde no hay periférico de verdad.
    reg  [7:0] io [0:223];
    reg  [7:0] flat_rdata;
    reg        flat_sel_q;
    integer i;
    initial for (i = 0; i < 224; i = i + 1) io[i] = 8'h00;

    wire flat_hit = ~periph_sel;

    always @(negedge clk) begin
        if (flat_hit && (io_re || io_we)) begin
            if (io_we) begin
                io[io_addr] <= io_wdata;
                flat_rdata  <= io_wdata;
            end else begin
                flat_rdata <= io[io_addr];
            end
        end
    end
    always @(negedge clk) if (io_re) flat_sel_q <= flat_hit;

    // Cada fuente deja su lectura a cero cuando no le toca, y se combinan.
    assign io_rdata = (periph_sel ? (gb_rd | gc_rd | gd_rd) : 8'h00)
                    | (flat_sel_q ? flat_rdata : 8'h00);
    // El relleno reclama todo lo que no reclama un periférico, de modo que en
    // la fase 2 el espacio de I/O sigue estando completo.
    assign io_sel = 1'b1;

    // ------------------------------------------------------------- núcleo
    axioma_core core (
        .clk(clk), .rst_n(rst_n),
        .pm_if_addr(c_pm_if_addr), .pm_if_en(c_pm_if_en), .pm_if_data(pm_if_data),
        .pm_d_addr(c_pm_d_addr), .pm_d_en(c_pm_d_en), .pm_d_we(c_pm_d_we),
        .pm_d_wdata(c_pm_d_wdata), .pm_d_rdata(pm_d_rdata),
        .dm_addr(dm_addr), .dm_re(dm_re), .dm_we(dm_we),
        .dm_wdata(dm_wdata), .dm_rdata(dm_rdata),
        /* verilator lint_off PINCONNECTEMPTY */
        .irq_req(1'b0), .irq_vector(5'd0), .irq_ack(),
        /* verilator lint_on PINCONNECTEMPTY */
        .dbg_pc(dbg_pc), .dbg_ir(dbg_ir), .dbg_retire(dbg_retire),
        .dbg_illegal(dbg_illegal), .dbg_sp(dbg_sp), .dbg_sreg(dbg_sreg),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data)
    );

    // ---------------- lectura de observación, sin perturbar al núcleo -------
    wire [7:0] dbg_io_index = dbg_mem_addr[7:0] - IO_BASE[7:0];
    wire       dbg_in_io    = (dbg_mem_addr >= IO_BASE) && (dbg_mem_addr < SRAM_BASE);

    // Los registros de los tres puertos hay que leerlos de su periférico, no
    // del relleno: ahí ya no está su estado.
    reg [7:0] dbg_periph;
    always @(*) begin
        case (dbg_io_index)
            8'h03:   dbg_periph = gpio_b.sync1;
            8'h04:   dbg_periph = gpio_b.ddr_q;
            8'h05:   dbg_periph = gpio_b.port_q;
            8'h06:   dbg_periph = gpio_c.sync1;
            8'h07:   dbg_periph = gpio_c.ddr_q;
            8'h08:   dbg_periph = gpio_c.port_q;
            8'h09:   dbg_periph = gpio_d.sync1;
            8'h0A:   dbg_periph = gpio_d.ddr_q;
            8'h0B:   dbg_periph = gpio_d.port_q;
            default: dbg_periph = io[dbg_io_index];
        endcase
    end

    assign dbg_mem_data =
        (dbg_mem_addr >= SRAM_BASE && dbg_mem_addr <= SRAM_END)
            ? dm.mem[dbg_mem_addr[10:0] - SRAM_BASE[10:0]]
        : dbg_in_io ? dbg_periph
        : 8'h00;

endmodule

`default_nettype wire
