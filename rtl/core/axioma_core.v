// AxiomaCore-328 - núcleo
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Une secuenciador, ALU, SREG y banco de registros, y resuelve el ESPACIO DE
// DATOS UNIFICADO del AVR:
//
//     0x0000 - 0x001F   los 32 registros           <- se resuelve aquí dentro
//     0x0020 - 0x005F   I/O estándar               <- sale al bus, salvo los
//     0x0060 - 0x00FF   I/O extendida                 casos especiales de abajo
//     0x0100 - 0x08FF   SRAM                       <- sale al bus
//
// Tres direcciones no pueden salir al bus porque su estado vive dentro del
// núcleo, y sin interceptarlas ningún programa real funcionaría:
//
//     0x5D  SPL   puntero de pila, byte bajo    el arranque de avr-gcc hace
//     0x5E  SPH   puntero de pila, byte alto    `out SPL,r28` / `out SPH,r29`
//     0x5F  SREG  registro de estado            lo usan las secciones críticas
//
// TEMPORIZACIÓN. Las lecturas del espacio interno se registran en FLANCO DE
// BAJADA, igual que axioma_dmem, para que el dato llegue en el mismo ciclo y
// LD y LDS conserven sus cuentas. Si se devolviera de forma combinacional, el
// valor desaparecería en el segundo ciclo de LD, cuando el secuenciador ya no
// mantiene la dirección. Ver docs/adr/0001-memorias-en-flanco-de-bajada.md

`default_nettype none

module axioma_core (
    input  wire        clk,
    input  wire        rst_n,

    // Memoria de programa
    output wire [13:0] pm_if_addr,
    output wire        pm_if_en,
    input  wire [15:0] pm_if_data,
    output wire [13:0] pm_d_addr,
    output wire        pm_d_en,
    output wire        pm_d_we,
    output wire [15:0] pm_d_wdata,
    input  wire [15:0] pm_d_rdata,

    // Espacio de datos externo: I/O y SRAM
    output wire [15:0] dm_addr,
    output wire        dm_re,
    output wire        dm_we,
    output wire [7:0]  dm_wdata,
    input  wire [7:0]  dm_rdata,

    // Interrupciones
    input  wire        irq_req,
    input  wire [4:0]  irq_vector,
    output wire        irq_ack,

    // Observación, para el arnés de co-simulación
    output wire [13:0] dbg_pc,
    output wire [15:0] dbg_ir,
    output wire        dbg_retire,
    output wire        dbg_illegal,
    output wire        dbg_irq_entry,
    output wire [15:0] dbg_sp,
    output wire [7:0]  dbg_sreg,
    input  wire [4:0]  dbg_reg_addr,
    output wire [7:0]  dbg_reg_data
);

`include "axioma_alu_ops.vh"

    // ------------------------------------------------- señales del secuenciador
    wire [15:0] s_dm_addr;
    wire        s_dm_re, s_dm_we;
    wire [7:0]  s_dm_wdata;

    wire [4:0]  s_rf_rd_addr, s_rf_rr_addr;
    wire [7:0]  rf_rd_data, rf_rr_data;
    wire        s_rf_we;
    wire [4:0]  s_rf_w_addr;
    wire [7:0]  s_rf_w_data;
    wire [3:0]  s_rf_a16_pair, s_rf_w16_pair;
    wire [15:0] rf_a16_rdata;
    wire        s_rf_we16;
    wire [15:0] s_rf_w16_data;

    wire [4:0]  alu_op_w;
    wire [7:0]  alu_a_w, alu_b_w;
    wire [15:0] alu_a16_w;
    wire [5:0]  alu_k6_w;
    wire [7:0]  alu_result_w;
    wire [15:0] alu_result16_w, alu_mul_w;
    wire [7:0]  alu_sreg_out_w, alu_sreg_mask_w;

    wire [7:0]  sreg_w;
    wire        sreg_alu_we_w, sreg_bit_en_w, sreg_bit_val_w;
    wire [2:0]  sreg_bit_num_w;
    wire        sreg_t_en_w, sreg_t_val_w, sreg_irq_enter_w, sreg_irq_return_w;

    wire [15:0] sp_w;
    wire [7:0]  rf_ds_data;

    // ------------------------------------------- decodificación del espacio
    localparam [15:0] ADDR_SPL_  = 16'h005D;
    localparam [15:0] ADDR_SPH_  = 16'h005E;
    localparam [15:0] ADDR_SREG_ = 16'h005F;

    wire hit_reg  = (s_dm_addr < 16'h0020);
    wire hit_spl  = (s_dm_addr == ADDR_SPL_);
    wire hit_sph  = (s_dm_addr == ADDR_SPH_);
    wire hit_sreg = (s_dm_addr == ADDR_SREG_);
    wire hit_int  = hit_reg | hit_spl | hit_sph | hit_sreg;   // se resuelve dentro

    // Dato interno que corresponde a la dirección presentada.
    wire [7:0] internal_rdata = hit_reg  ? rf_ds_data      :
                                hit_spl  ? sp_w[7:0]       :
                                hit_sph  ? sp_w[15:8]      :
                                           sreg_w;

    // Registro en flanco de bajada, para igualar la temporización de dmem.
    reg [7:0] int_rdata_q;
    reg       int_hit_q;
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            int_rdata_q <= 8'h00;
            int_hit_q   <= 1'b0;
        end else if (s_dm_re) begin
            int_hit_q   <= hit_int;
            int_rdata_q <= internal_rdata;
        end
    end

    wire [7:0] seq_dm_rdata = int_hit_q ? int_rdata_q : dm_rdata;

    // Solo sale al bus lo que no se resuelve dentro.
    assign dm_addr  = s_dm_addr;
    assign dm_re    = s_dm_re & ~hit_int;
    assign dm_we    = s_dm_we & ~hit_int;
    assign dm_wdata = s_dm_wdata;

    // ---------------------------------------------- escrituras al banco
    // La escritura desde el espacio de datos y la de resultado de instrucción
    // no coinciden nunca: ST no escribe Rd, y LD no escribe por el espacio.
    wire        rf_we_final    = s_rf_we | (s_dm_we & hit_reg);
    wire [4:0]  rf_w_addr_fin  = (s_dm_we & hit_reg) ? s_dm_addr[4:0] : s_rf_w_addr;
    wire [7:0]  rf_w_data_fin  = (s_dm_we & hit_reg) ? s_dm_wdata     : s_rf_w_data;

    // ------------------------------------------------------ SP y SREG
    wire       sp_wr_en   = s_dm_we & (hit_spl | hit_sph);
    wire       sp_wr_hi   = hit_sph;
    wire [7:0] sp_wr_data = s_dm_wdata;

    // ESCRIBIR SREG ES UNA ESCRITURA AL ESPACIO DE DATOS, y sólo eso. El
    // secuenciador tenía además un par de puertos propios —`sreg_wr_en` y
    // `sreg_wr_data`— que nunca llegaba a activar: la medida de cobertura los
    // encontró sin conmutar nunca. Era lógica muerta, y en un diseño que va a
    // fabricarse eso no es sólo área: es un camino que nadie puede verificar y
    // que el siguiente que lea el código dará por bueno.
    //
    // `OUT 0x3F, Rr` y `STS 0x5F, Rr` entran los dos por aquí, que es como
    // funciona el chip: SREG es una dirección más del espacio de datos.
    wire       sreg_wr_final    = s_dm_we & hit_sreg;
    wire [7:0] sreg_wr_data_fin = s_dm_wdata;

    // ------------------------------------------------------- instancias
    axioma_seq seq (
        .clk(clk), .rst_n(rst_n),
        .pm_if_addr(pm_if_addr), .pm_if_en(pm_if_en), .pm_if_data(pm_if_data),
        .pm_d_addr(pm_d_addr), .pm_d_en(pm_d_en), .pm_d_we(pm_d_we),
        .pm_d_wdata(pm_d_wdata), .pm_d_rdata(pm_d_rdata),
        .dm_addr(s_dm_addr), .dm_re(s_dm_re), .dm_we(s_dm_we),
        .dm_wdata(s_dm_wdata), .dm_rdata(seq_dm_rdata),
        .rf_rd_addr(s_rf_rd_addr), .rf_rr_addr(s_rf_rr_addr),
        .rf_rd_data(rf_rd_data), .rf_rr_data(rf_rr_data),
        .rf_we(s_rf_we), .rf_w_addr(s_rf_w_addr), .rf_w_data(s_rf_w_data),
        .rf_a16_pair(s_rf_a16_pair), .rf_a16_rdata(rf_a16_rdata),
        .rf_we16(s_rf_we16), .rf_w16_pair(s_rf_w16_pair),
        .rf_w16_data(s_rf_w16_data),
        .alu_op_o(alu_op_w), .alu_a(alu_a_w), .alu_b(alu_b_w),
        .alu_a16(alu_a16_w), .alu_k6(alu_k6_w),
        .alu_result(alu_result_w), .alu_result16(alu_result16_w),
        .alu_mul_result(alu_mul_w),
        .sreg(sreg_w),
        .sreg_alu_we(sreg_alu_we_w),
        .sreg_bit_en(sreg_bit_en_w), .sreg_bit_num(sreg_bit_num_w),
        .sreg_bit_val(sreg_bit_val_w),
        .sreg_t_en(sreg_t_en_w), .sreg_t_val(sreg_t_val_w),
        .sreg_irq_enter(sreg_irq_enter_w), .sreg_irq_return(sreg_irq_return_w),
        .irq_req(irq_req), .irq_vector(irq_vector), .irq_ack(irq_ack),
        .sp_wr_en(sp_wr_en), .sp_wr_hi(sp_wr_hi), .sp_wr_data(sp_wr_data),
        .sp(sp_w),
        .dbg_pc(dbg_pc), .dbg_ir(dbg_ir), .dbg_retire(dbg_retire),
        .dbg_illegal(dbg_illegal), .dbg_irq_entry(dbg_irq_entry)
    );

    axioma_alu alu (
        .op(alu_op_w), .a(alu_a_w), .b(alu_b_w),
        .a16(alu_a16_w), .k6(alu_k6_w), .sreg_in(sreg_w),
        .result(alu_result_w), .result16(alu_result16_w),
        .mul_result(alu_mul_w),
        .sreg_out(alu_sreg_out_w), .sreg_mask(alu_sreg_mask_w)
    );

    axioma_sreg sregi (
        .clk(clk), .rst_n(rst_n),
        .alu_we(sreg_alu_we_w), .alu_value(alu_sreg_out_w), .alu_mask(alu_sreg_mask_w),
        .wr_en(sreg_wr_final), .wr_data(sreg_wr_data_fin),
        .bit_en(sreg_bit_en_w), .bit_num(sreg_bit_num_w), .bit_val(sreg_bit_val_w),
        .t_en(sreg_t_en_w), .t_val(sreg_t_val_w),
        .irq_enter(sreg_irq_enter_w), .irq_return(sreg_irq_return_w),
        .sreg(sreg_w)
    );

    axioma_regfile rf (
        .clk(clk), .rst_n(rst_n),
        .rd_addr(s_rf_rd_addr), .rr_addr(s_rf_rr_addr),
        .rd_data(rf_rd_data), .rr_data(rf_rr_data),
        .we(rf_we_final), .w_addr(rf_w_addr_fin), .w_data(rf_w_data_fin),
        .a16_pair(s_rf_a16_pair), .a16_rdata(rf_a16_rdata),
        .we16(s_rf_we16), .w16_pair(s_rf_w16_pair), .w16_data(s_rf_w16_data),
        .ds_addr(s_dm_addr[4:0]), .ds_data(rf_ds_data),
        .dbg_addr(dbg_reg_addr), .dbg_data(dbg_reg_data)
    );

    assign dbg_sp   = sp_w;
    assign dbg_sreg = sreg_w;

endmodule

`default_nettype wire
