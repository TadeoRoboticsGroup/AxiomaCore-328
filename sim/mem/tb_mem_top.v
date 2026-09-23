// Envoltorio de simulación: instancia las dos memorias para poder ejercitarlas
// desde un único modelo de Verilator. No forma parte del diseño.
`default_nettype none

module tb_mem_top (
    input  wire        clk,
    // memoria de programa
    input  wire [13:0] pm_if_addr,
    input  wire        pm_if_en,
    output wire [15:0] pm_if_data,
    input  wire [13:0] pm_d_addr,
    input  wire        pm_d_en,
    input  wire        pm_d_we,
    input  wire [15:0] pm_d_wdata,
    output wire [15:0] pm_d_rdata,
    // memoria de datos
    input  wire [10:0] dm_addr,
    input  wire        dm_en,
    input  wire        dm_we,
    input  wire [7:0]  dm_wdata,
    output wire [7:0]  dm_rdata
);
    axioma_progmem pm (
        .clk(clk), .ce(1'b1),
        .if_addr(pm_if_addr), .if_en(pm_if_en), .if_data(pm_if_data),
        .d_addr(pm_d_addr), .d_en(pm_d_en), .d_we(pm_d_we),
        .d_wdata(pm_d_wdata), .d_rdata(pm_d_rdata)
    );
    axioma_dmem dm (
        .clk(clk), .ce(1'b1), .addr(dm_addr), .en(dm_en), .we(dm_we),
        .wdata(dm_wdata), .rdata(dm_rdata)
    );
endmodule

`default_nettype wire
