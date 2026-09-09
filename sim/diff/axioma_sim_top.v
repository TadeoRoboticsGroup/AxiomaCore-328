// AxiomaCore-328 - top de simulación para la co-simulación diferencial
// SPDX-License-Identifier: Apache-2.0
//
// NO forma parte del diseño. Cablea el núcleo con las memorias y con un
// espacio de I/O PLANO, y añade un puerto de carga de programa que solo existe
// en simulación.
//
// El espacio de I/O es plano a propósito: en la fase 1 no hay periféricos, así
// que 0x0020..0x00FF se comporta como memoria normal. Los programas de prueba
// deben EVITAR los periféricos, porque simavr sí los modela y ahí divergiría.
// Las tres direcciones que sí tienen estado —SPL, SPH y SREG— las intercepta
// axioma_core antes de llegar aquí.

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

    // ---------------------------------------------------- espacio de datos
    wire [15:0] dm_addr;
    wire        dm_re, dm_we;
    wire [7:0]  dm_wdata;

    wire hit_io   = (dm_addr >= IO_BASE)   && (dm_addr < SRAM_BASE);
    wire hit_sram = (dm_addr >= SRAM_BASE) && (dm_addr <= SRAM_END);

    // SRAM de 2 KB
    wire [7:0] sram_rdata;
    axioma_dmem dm (
        .clk(clk),
        .addr(dm_addr[10:0] - SRAM_BASE[10:0]),
        .en(hit_sram & (dm_re | dm_we)),
        .we(dm_we & hit_sram),
        .wdata(dm_wdata),
        .rdata(sram_rdata)
    );

    // Espacio de I/O plano, 224 bytes. Mismo flanco que la SRAM.
    reg [7:0] io [0:223];
    reg [7:0] io_rdata;
    integer i;
    initial for (i = 0; i < 224; i = i + 1) io[i] = 8'h00;

    // El espacio de I/O son 224 bytes: los bits altos del desplazamiento
    // sobran por construcción y se descartan a propósito.
    wire [15:0] io_off   = dm_addr - IO_BASE;
    wire [7:0]  io_index = io_off[7:0];
    wire unused_io_off = &{1'b0, io_off[15:8]};

    always @(negedge clk) begin
        if (hit_io && (dm_re || dm_we)) begin
            if (dm_we) begin
                io[io_index] <= dm_wdata;
                io_rdata     <= dm_wdata;
            end else begin
                io_rdata <= io[io_index];
            end
        end
    end

    reg hit_io_q;
    always @(negedge clk) if (dm_re) hit_io_q <= hit_io;
    wire [7:0] dm_rdata = hit_io_q ? io_rdata : sram_rdata;

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

    // Lectura de observación del espacio de datos, sin perturbar al núcleo.
    wire [15:0] dbg_io_off   = dbg_mem_addr - IO_BASE;
    wire [7:0]  dbg_io_index = dbg_io_off[7:0];
    wire unused_dbg_io_off = &{1'b0, dbg_io_off[15:8]};
    assign dbg_mem_data =
        (dbg_mem_addr >= SRAM_BASE && dbg_mem_addr <= SRAM_END)
            ? dm.mem[dbg_mem_addr[10:0] - SRAM_BASE[10:0]]
        : (dbg_mem_addr >= IO_BASE && dbg_mem_addr < SRAM_BASE)
            ? io[dbg_io_index]
        : 8'h00;

endmodule

`default_nettype wire
