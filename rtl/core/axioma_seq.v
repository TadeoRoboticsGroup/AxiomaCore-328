// AxiomaCore-328 - secuenciador
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Pipeline de dos etapas, como el AVR original:
//
//     IF                        ID / EX / WB
//   ┌──────────────┐          ┌───────────────────────────────┐
//   │ PC → progmem │  ──IR──► │ decodifica, ALU, memoria, wb  │
//   └──────────────┘          └───────────────────────────────┘
//           ▲                              │
//           └────────── stall / redirect ──┘
//
// Las instrucciones multiciclo se resuelven con un contador `cyc` en vez de una
// maraña de estados: cada clase declara cuántos ciclos dura y qué hace en cada
// uno. Así la tabla de ciclos del manual queda LEGIBLE en el código, que es
// justo lo que hay que poder auditar para el nivel L3 de compatibilidad.
//
// SOBRE LOS SALTOS DE INSTRUCCIÓN (la trampa nº 1):
//   CPSE, SBRC, SBRS, SBIC y SBIS descartan la instrucción siguiente. Si esa
//   siguiente es de 32 bits (LDS, STS, JMP, CALL) hay que descartar DOS
//   palabras, no una. Por eso se instancia un SEGUNDO decodificador,
//   `dec_next`, que mira la palabra ya prefetchada: su única salida que se usa
//   es `is_32bit`.
//
// SOBRE EL RETARDO DE SEI:
//   Tras SEI, la primera interrupción no se atiende hasta DESPUÉS de ejecutar
//   la instrucción siguiente. CLI, en cambio, es inmediato. Se implementa con
//   `irq_hold`, que bloquea un ciclo la atención de interrupciones.

`default_nettype none

module axioma_seq (
    input  wire        clk,
    input  wire        rst_n,

    // ---- memoria de programa ----
    output wire [13:0] pm_if_addr,
    output reg         pm_if_en,
    input  wire [15:0] pm_if_data,
    output reg  [13:0] pm_d_addr,
    output reg         pm_d_en,
    output reg         pm_d_we,
    output reg  [15:0] pm_d_wdata,
    input  wire [15:0] pm_d_rdata,

    // ---- espacio de datos (registros, I/O y SRAM los resuelve el bus) ----
    output reg  [15:0] dm_addr,
    output reg         dm_re,
    output reg         dm_we,
    output reg  [7:0]  dm_wdata,
    input  wire [7:0]  dm_rdata,

    // ---- banco de registros ----
    output wire [4:0]  rf_rd_addr,
    output wire [4:0]  rf_rr_addr,
    input  wire [7:0]  rf_rd_data,
    input  wire [7:0]  rf_rr_data,
    output reg         rf_we,
    output reg  [4:0]  rf_w_addr,
    output reg  [7:0]  rf_w_data,
    output reg  [3:0]  rf_a16_pair,
    input  wire [15:0] rf_a16_rdata,
    output reg         rf_we16,
    output wire [3:0]  rf_w16_pair,
    output reg  [15:0] rf_w16_data,

    // ---- ALU ----
    output wire [4:0]  alu_op_o,
    output wire [7:0]  alu_a,
    output wire [7:0]  alu_b,
    output wire [15:0] alu_a16,
    output wire [5:0]  alu_k6,
    input  wire [7:0]  alu_result,
    input  wire [15:0] alu_result16,
    input  wire [15:0] alu_mul_result,
    // alu_sreg_out y alu_sreg_mask NO pasan por aquí: van del ALU al SREG
    // directamente en el SoC. El secuenciador solo decide CUÁNDO se aplican,
    // con sreg_alu_we. Meterlos aquí solo añadiría un rodeo.

    // ---- SREG ----
    input  wire [7:0]  sreg,
    output reg         sreg_alu_we,
    output reg         sreg_wr_en,
    output reg  [7:0]  sreg_wr_data,
    output reg         sreg_bit_en,
    output reg  [2:0]  sreg_bit_num,
    output reg         sreg_bit_val,
    output reg         sreg_t_en,
    output reg         sreg_t_val,
    output reg         sreg_irq_enter,
    output reg         sreg_irq_return,

    // ---- interrupciones ----
    input  wire        irq_req,
    input  wire [4:0]  irq_vector,
    output reg         irq_ack,

    // ---- puntero de pila ----
    // SPL y SPH están en el espacio de datos (0x5D y 0x5E), así que un
    // `OUT SPL, r28` tiene que llegar hasta aquí. El arranque que genera
    // avr-gcc hace exactamente eso, de modo que sin esta vía ningún programa
    // real montaría bien su pila.
    input  wire        sp_wr_en,
    input  wire        sp_wr_hi,      // 0 = byte bajo (SPL), 1 = alto (SPH)
    input  wire [7:0]  sp_wr_data,
    output reg  [15:0] sp,
    output wire [13:0] dbg_pc,
    output wire [15:0] dbg_ir,
    output wire        dbg_retire,       // se retiró una instrucción este ciclo
    output wire        dbg_illegal       // codificación no válida en ejecución
);

`include "axioma_alu_ops.vh"
`include "axioma_decode_ops.vh"

    localparam [15:0] RAMEND = 16'h08FF;

    // ------------------------------------------------------------- estado
    //
    // MODELO DE BÚSQUEDA. La memoria de programa está registrada en flanco de
    // subida, así que va adelantada un ciclo:
    //
    //     pm_if_data(T) = mem[fpc(T-1)]
    //
    // Ejecutar la instrucción de la dirección A en el ciclo T significa que
    // fpc valía A en T-1. Durante T se pone fpc = A+1, de modo que en T+1 ya
    // está disponible la siguiente. Para las instrucciones de varios ciclos se
    // MANTIENE fpc, con lo que pm_if_data conserva mem[A+1]: eso es lo que da
    // la segunda palabra de LDS/STS/JMP/CALL y lo que ve el predecodificador
    // de saltos.
    reg [13:0] fpc;         // dirección presentada a la memoria de programa
    reg [13:0] pc;          // dirección de la instrucción EN EJECUCIÓN
    reg [15:0] ir_hold;     // instrucción retenida durante los ciclos extra
    reg        use_hold;
    reg [1:0]  cyc;         // ciclo dentro de la instrucción actual
    reg        irq_hold;    // ciclo de gracia tras SEI
    reg [15:0] tmp16;       // segunda palabra, dirección o dato intermedio
    reg        retire;      // esta instrucción termina en este ciclo

    // Ciclo de calentamiento tras el reset. La memoria de programa está
    // registrada: en el primer ciclo tras soltar el reset todavía no ha
    // llegado mem[0], así que pm_if_data trae basura. Sin esto se ejecutaría
    // una instrucción inventada antes de la primera de verdad.
    reg        warmup;

    wire [15:0] insn = use_hold ? ir_hold : pm_if_data;

    assign dbg_illegal = d_illegal;
    assign dbg_pc     = pc;
    assign dbg_ir     = insn;
    assign dbg_retire = retire;

    // ------------------------------------------------- decodificador principal
    wire [5:0]  d_class;
    wire [4:0]  d_alu_op;
    wire [4:0]  d_rd, d_rr;
    wire        d_rd_we, d_rd_we16, d_use_imm;
    wire [7:0]  d_imm;
    wire [1:0]  d_ptr_sel, d_ptr_mode;
    wire [5:0]  d_disp;
    wire [5:0]  d_io_addr;
    wire [2:0]  d_bit_num;
    wire [11:0] d_rel;
    wire [2:0]  d_cond_bit;
    wire        d_cond_set;
    wire        d_is32, d_illegal;

    axioma_decode dec (
        .insn(insn), .op_class(d_class), .alu_op(d_alu_op),
        .rd(d_rd), .rr(d_rr), .rd_we(d_rd_we), .rd_we16(d_rd_we16),
        .use_imm(d_use_imm), .imm(d_imm),
        .ptr_sel(d_ptr_sel), .ptr_mode(d_ptr_mode), .disp(d_disp),
        .io_addr(d_io_addr), .bit_num(d_bit_num),
        .rel_addr(d_rel), .cond_bit(d_cond_bit), .cond_set(d_cond_set),
        .is_32bit(d_is32), .illegal(d_illegal)
    );

    // ------- segundo decodificador: SOLO para saber si la siguiente es de 32 bits
    wire n_is32;
    /* verilator lint_off PINCONNECTEMPTY */
    axioma_decode dec_next (
        .insn(pm_if_data), .op_class(), .alu_op(),
        .rd(), .rr(), .rd_we(), .rd_we16(), .use_imm(), .imm(),
        .ptr_sel(), .ptr_mode(), .disp(), .io_addr(), .bit_num(),
        .rel_addr(), .cond_bit(), .cond_set(),
        .is_32bit(n_is32), .illegal()
    );
    /* verilator lint_on PINCONNECTEMPTY */

    // ------------------------------------------------- conexiones de lectura
    assign rf_rd_addr = d_rd;
    assign rf_rr_addr = d_rr;
    assign alu_op_o   = d_alu_op;
    assign alu_a      = rf_rd_data;
    assign alu_b      = d_use_imm ? d_imm : rf_rr_data;
    assign alu_a16    = rf_a16_rdata;
    assign alu_k6     = d_imm[5:0];

    // ---------------------------------------------------- puntero X / Y / Z
    reg [3:0] ptr_pair;
    always @(*) begin
        case (d_ptr_sel)
            PTR_X:   ptr_pair = 4'd13;      // R27:R26
            PTR_Y:   ptr_pair = 4'd14;      // R29:R28
            default: ptr_pair = 4'd15;      // R31:R30
        endcase
    end

    wire [15:0] ptr_base = rf_a16_rdata;
    wire [15:0] ptr_eff  = (d_ptr_mode == PTR_PREDEC) ? (ptr_base - 16'd1) :
                           (d_ptr_mode == PTR_DISP)   ? (ptr_base + {10'b0, d_disp}) :
                                                         ptr_base;
    wire [15:0] ptr_wb   = (d_ptr_mode == PTR_POSTINC) ? (ptr_base + 16'd1) :
                           (d_ptr_mode == PTR_PREDEC)  ? (ptr_base - 16'd1) :
                                                          ptr_base;
    wire ptr_updates = (d_ptr_mode == PTR_POSTINC) || (d_ptr_mode == PTR_PREDEC);

    // ------------------------------------------------------ rama condicional
    wire cond_taken = (sreg[d_cond_bit] == d_cond_set);
    wire [13:0] branch_target = pc + 14'd1 + {{2{d_rel[11]}}, d_rel};

    // ------------------------------------------------------ salto por skip
    // pc apunta a la instrucción de salto. La descartada está en pc+1, así que
    // la siguiente está en pc+2 si ocupa una palabra y en pc+3 si ocupa dos.
    wire [13:0] skip_target = pc + (n_is32 ? 14'd3 : 14'd2);

    // ¿la instrucción actual provoca un salto?
    reg skip_now;
    always @(*) begin
        case (d_class)
            OPC_CPSE: skip_now = (rf_rd_data == rf_rr_data);
            OPC_SBRC: skip_now = (rf_rr_data[d_bit_num] == 1'b0);
            OPC_SBRS: skip_now = (rf_rr_data[d_bit_num] == 1'b1);
            OPC_SBIC: skip_now = (dm_rdata[d_bit_num] == 1'b0);
            OPC_SBIS: skip_now = (dm_rdata[d_bit_num] == 1'b1);
            default:  skip_now = 1'b0;
        endcase
    end

    // Se atiende una interrupción sólo ENTRE instrucciones, con I puesto y sin
    // el ciclo de gracia de SEI pendiente.
    wire irq_take = irq_req && sreg[SREG_I] && !irq_hold && (cyc == 2'd0);


    // =====================================================================
    //  MÁQUINA DE ESTADOS
    // =====================================================================
    // Cada clase declara cuántos ciclos dura y qué hace en cada uno. La tabla
    // de ciclos del manual del ISA queda así legible en el propio código, que
    // es lo que hay que poder auditar para el nivel L3 de compatibilidad.

    reg        next_warmup;
    reg [13:0] next_fpc;

    // La dirección de búsqueda es el valor COMBINACIONAL, no el registrado.
    //
    //     pm_if_data(T+1) = mem[pm_if_addr(T)]
    //
    // y en T+1 hay que ejecutar la instrucción de pc(T+1), así que en T hay que
    // presentar ya esa dirección. Usar el `fpc` registrado la atrasa un ciclo y
    // la misma instrucción se ejecuta dos veces: fue el primer fallo que
    // encontró la co-simulación diferencial, en la segunda instrucción.
    reg [13:0] next_pc;
    reg [1:0]  next_cyc;
    reg [15:0] next_sp;
    reg [15:0] next_tmp16;
    reg        next_use_hold;
    reg        next_irq_hold;

    // La dirección de datos que se presenta a la SRAM, ya traducida.
    reg [15:0] ea;

    // Dirección de retorno que apila CALL, RCALL e ICALL.
    wire [13:0] ret_addr = pc + (d_is32 ? 14'd2 : 14'd1);

    always @(*) begin
        // ---------------- valores por defecto ----------------
        next_warmup   = 1'b0;
        next_fpc      = fpc;
        next_pc       = pc;
        next_cyc      = 2'd0;
        next_sp       = sp;
        next_tmp16    = tmp16;
        next_use_hold = 1'b0;
        next_irq_hold = 1'b0;
        retire        = 1'b0;

        pm_if_en   = 1'b1;
        pm_d_addr  = rf_a16_rdata[14:1];
        pm_d_en    = 1'b0;
        pm_d_we    = 1'b0;
        pm_d_wdata = 16'h0000;

        ea       = 16'h0000;
        dm_addr  = 16'h0000;
        dm_re    = 1'b0;
        dm_we    = 1'b0;
        dm_wdata = 8'h00;

        rf_we       = 1'b0;
        rf_w_addr   = d_rd;
        rf_w_data   = alu_result;
        rf_a16_pair = d_rd_we16 ? d_rd[4:1] : ptr_pair;
        rf_we16     = 1'b0;
        rf_w16_data = alu_result16;

        sreg_alu_we     = 1'b0;
        sreg_wr_en      = 1'b0;
        sreg_wr_data    = 8'h00;
        sreg_bit_en     = 1'b0;
        sreg_bit_num    = d_bit_num;
        sreg_bit_val    = 1'b0;
        sreg_t_en       = 1'b0;
        sreg_t_val      = 1'b0;
        sreg_irq_enter  = 1'b0;
        sreg_irq_return = 1'b0;
        irq_ack         = 1'b0;

        if (warmup) begin
            // Se mantiene fpc para que mem[0] llegue al final de este ciclo.
            next_fpc = fpc;
            next_pc  = pc;
        end else if (irq_take) begin
            // ---- entrada a interrupción: 4 ciclos + el JMP del vector ----
            next_use_hold = 1'b1;
            case (cyc)
            2'd0: begin
                sreg_irq_enter = 1'b1;
                irq_ack        = 1'b1;
                next_tmp16     = {9'b0, irq_vector, 2'b00};   // vector x2 palabras
                dm_addr = sp;  dm_we = 1'b1;  dm_wdata = pc[7:0];
                next_sp = sp - 16'd1;
                next_cyc = 2'd1;
            end
            2'd1: begin
                dm_addr = sp;  dm_we = 1'b1;  dm_wdata = {2'b00, pc[13:8]};
                next_sp = sp - 16'd1;
                next_cyc = 2'd2;
            end
            2'd2: begin
                next_fpc = tmp16[13:0];
                next_cyc = 2'd3;
            end
            default: begin
                next_fpc = tmp16[13:0];
                next_pc  = tmp16[13:0];
                next_use_hold = 1'b0;
                retire   = 1'b1;
            end
            endcase
        end else begin
        case (d_class)

        // ---------------------------------------------- un ciclo, sin memoria
        OPC_NOP, OPC_SLEEP, OPC_WDR, OPC_BREAK: begin
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        OPC_ALU_RR, OPC_ALU_RI: begin
            rf_we       = d_rd_we;
            sreg_alu_we = 1'b1;
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        OPC_ALU_1: begin
            rf_we       = d_rd_we;
            sreg_alu_we = 1'b1;
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        // MOVW es de UN ciclo: lee el par fuente y escribe el destino a la
        // vez, porque el banco direcciona ambos lados por separado.
        OPC_MOVW: begin
            rf_a16_pair = d_rr[4:1];        // origen; el destino va por rf_w16_pair
            rf_we16     = 1'b1;
            rf_w16_data = rf_a16_rdata;
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        OPC_BSET, OPC_BCLR: begin
            sreg_bit_en  = 1'b1;
            sreg_bit_val = (d_class == OPC_BSET);
            // SEI tiene un ciclo de gracia: la interrupción no entra hasta
            // después de la instrucción siguiente. CLI es inmediato.
            next_irq_hold = (d_class == OPC_BSET) && (d_bit_num == 3'd7);
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        OPC_BST: begin
            sreg_t_en  = 1'b1;
            sreg_t_val = rf_rd_data[d_bit_num];
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        OPC_BLD: begin
            rf_we     = 1'b1;
            rf_w_data = rf_rd_data;
            rf_w_data[d_bit_num] = sreg[SREG_T];
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        // ------------------------------------------------------ 2 ciclos: MUL
        OPC_MUL: begin
            if (cyc == 2'd0) begin
                next_tmp16    = alu_mul_result;
                next_use_hold = 1'b1;
                next_cyc      = 2'd1;
                sreg_alu_we   = 1'b1;
            end else begin
                rf_a16_pair = 4'd0;          // R1:R0
                rf_we16     = 1'b1;
                rf_w16_data = tmp16;
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
            end
        end

        // -------------------------------------------- 2 ciclos: ADIW y SBIW
        OPC_IW: begin
            rf_a16_pair = d_rd[4:1];
            if (cyc == 2'd0) begin
                rf_we16       = 1'b1;
                sreg_alu_we   = 1'b1;
                next_use_hold = 1'b1;
                next_cyc      = 2'd1;
            end else begin
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
            end
        end

        // ------------------------------------------------ 2 ciclos: LD y ST
        OPC_LD: begin
            ea = ptr_eff;
            if (cyc == 2'd0) begin
                dm_addr = ea;  dm_re = 1'b1;
                if (ptr_updates) begin
                    rf_we16 = 1'b1;  rf_w16_data = ptr_wb;
                end
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else begin
                rf_we = 1'b1;  rf_w_data = dm_rdata;
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
            end
        end

        OPC_ST: begin
            ea = ptr_eff;
            rf_a16_pair = ptr_pair;
            if (cyc == 2'd0) begin
                dm_addr = ea;  dm_we = 1'b1;  dm_wdata = rf_rr_data;
                if (ptr_updates) begin
                    rf_we16 = 1'b1;  rf_w16_data = ptr_wb;
                end
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else begin
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
            end
        end

        // ------------------------------------- 2 ciclos, 32 bits: LDS y STS
        OPC_LDS: begin
            if (cyc == 2'd0) begin
                next_fpc = fpc + 14'd1;      // trae la segunda palabra
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else begin
                dm_addr = pm_if_data;  dm_re = 1'b1;
                rf_we = 1'b1;  rf_w_data = dm_rdata;
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd2;  retire = 1'b1;
            end
        end

        OPC_STS: begin
            if (cyc == 2'd0) begin
                next_fpc = fpc + 14'd1;
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else begin
                dm_addr = pm_if_data;  dm_we = 1'b1;  dm_wdata = rf_rr_data;
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd2;  retire = 1'b1;
            end
        end

        // ------------------------------------------- 2 ciclos: PUSH y POP
        OPC_PUSH: begin
            if (cyc == 2'd0) begin
                dm_addr = sp;  dm_we = 1'b1;  dm_wdata = rf_rr_data;
                next_sp = sp - 16'd1;
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else begin
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
            end
        end

        OPC_POP: begin
            if (cyc == 2'd0) begin
                dm_addr = sp + 16'd1;  dm_re = 1'b1;
                next_sp = sp + 16'd1;
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else begin
                rf_we = 1'b1;  rf_w_data = dm_rdata;
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
            end
        end

        // ------------------------------------------------------ I/O directo
        OPC_IN: begin
            dm_addr = {10'b0, d_io_addr} + 16'h0020;
            dm_re   = 1'b1;
            rf_we   = 1'b1;  rf_w_data = dm_rdata;
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        OPC_OUT: begin
            dm_addr = {10'b0, d_io_addr} + 16'h0020;
            dm_we   = 1'b1;  dm_wdata = rf_rr_data;
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        OPC_SBI, OPC_CBI: begin
            dm_addr = {10'b0, d_io_addr} + 16'h0020;
            if (cyc == 2'd0) begin
                dm_re = 1'b1;
                next_tmp16 = {8'h00, dm_rdata};
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else begin
                dm_we    = 1'b1;
                dm_wdata = tmp16[7:0];
                dm_wdata[d_bit_num] = (d_class == OPC_SBI);
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
            end
        end

        // ------------------------------------------------- saltos por skip
        OPC_CPSE, OPC_SBRC, OPC_SBRS, OPC_SBIC, OPC_SBIS: begin
            if ((d_class == OPC_SBIC) || (d_class == OPC_SBIS)) begin
                dm_addr = {10'b0, d_io_addr} + 16'h0020;
                dm_re   = 1'b1;
            end
            if (cyc == 2'd0) begin
                if (skip_now) begin
                    next_fpc = fpc + 14'd1;     // hace falta ver la siguiente
                    next_use_hold = 1'b1;  next_cyc = 2'd1;
                end else begin
                    next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
                end
            end else if (cyc == 2'd1) begin
                // pm_if_data trae ya la instrucción a descartar; el segundo
                // decodificador dice si ocupa una palabra o dos.
                next_fpc = skip_target;
                if (n_is32) begin
                    next_use_hold = 1'b1;  next_cyc = 2'd2;
                end else begin
                    next_pc = skip_target;  retire = 1'b1;
                end
            end else begin
                next_fpc = fpc;  next_pc = fpc;  retire = 1'b1;
            end
        end

        // --------------------------------------------- ramas condicionales
        OPC_BRANCH: begin
            if (cyc == 2'd0) begin
                if (cond_taken) begin
                    next_fpc = branch_target;
                    next_use_hold = 1'b1;  next_cyc = 2'd1;
                end else begin
                    next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
                end
            end else begin
                next_pc = fpc;  retire = 1'b1;
            end
        end

        // ------------------------------------------ saltos incondicionales
        OPC_RJMP, OPC_IJMP: begin
            if (cyc == 2'd0) begin
                next_fpc = (d_class == OPC_RJMP) ? branch_target : rf_a16_rdata[13:0];
                rf_a16_pair = 4'd15;                       // Z
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else begin
                next_pc = fpc;  retire = 1'b1;
            end
        end

        OPC_JMP: begin
            if (cyc == 2'd0) begin
                next_fpc = fpc + 14'd1;
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end else if (cyc == 2'd1) begin
                next_tmp16 = pm_if_data;
                next_fpc   = pm_if_data[13:0];
                next_use_hold = 1'b1;  next_cyc = 2'd2;
            end else begin
                next_pc = fpc;  retire = 1'b1;
            end
        end

        // --------------------------------------------------- llamadas
        OPC_RCALL, OPC_ICALL: begin
            rf_a16_pair = 4'd15;                           // Z, para ICALL
            case (cyc)
            2'd0: begin
                dm_addr = sp;  dm_we = 1'b1;  dm_wdata = ret_addr[7:0];
                next_sp = sp - 16'd1;
                next_tmp16 = {2'b00, (d_class == OPC_RCALL) ? branch_target
                                                            : rf_a16_rdata[13:0]};
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end
            2'd1: begin
                dm_addr = sp;  dm_we = 1'b1;  dm_wdata = {2'b00, ret_addr[13:8]};
                next_sp = sp - 16'd1;
                next_fpc = tmp16[13:0];
                next_use_hold = 1'b1;  next_cyc = 2'd2;
            end
            default: begin
                next_pc = fpc;  retire = 1'b1;
            end
            endcase
        end

        OPC_CALL: begin
            case (cyc)
            2'd0: begin
                next_fpc = fpc + 14'd1;
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end
            2'd1: begin
                next_tmp16 = pm_if_data;
                dm_addr = sp;  dm_we = 1'b1;  dm_wdata = ret_addr[7:0];
                next_sp = sp - 16'd1;
                next_use_hold = 1'b1;  next_cyc = 2'd2;
            end
            2'd2: begin
                dm_addr = sp;  dm_we = 1'b1;  dm_wdata = {2'b00, ret_addr[13:8]};
                next_sp = sp - 16'd1;
                next_fpc = tmp16[13:0];
                next_use_hold = 1'b1;  next_cyc = 2'd3;
            end
            default: begin
                next_pc = fpc;  retire = 1'b1;
            end
            endcase
        end

        // ------------------------------------------------- RET y RETI
        OPC_RET, OPC_RETI: begin
            // CUIDADO CON EL FLANCO. La memoria de datos está en flanco de
            // bajada, así que una lectura lanzada en el ciclo N ya está
            // disponible para registrarse en el flanco de subida que CIERRA
            // ese mismo ciclo N, no en el siguiente.
            //
            // Escribir esto como si la memoria fuera de flanco de subida
            // —consumir la lectura anterior mientras se lanza otra— hace que
            // se capture la lectura NUEVA, porque el dato cambia a mitad de
            // ciclo. Fue el segundo fallo que encontró la co-simulación
            // diferencial: RET devolvía el byte bajo duplicado.
            case (cyc)
            2'd0: begin
                dm_addr = sp + 16'd1;  dm_re = 1'b1;       // byte alto
                next_tmp16 = {8'h00, dm_rdata};            // se captura AQUÍ
                next_sp = sp + 16'd1;
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end
            2'd1: begin
                dm_addr = sp + 16'd1;  dm_re = 1'b1;       // byte bajo
                next_fpc = {tmp16[5:0], dm_rdata};         // alto ya en tmp16
                next_sp = sp + 16'd1;
                if (d_class == OPC_RETI) sreg_irq_return = 1'b1;
                next_use_hold = 1'b1;  next_cyc = 2'd2;
            end
            2'd2: begin
                next_use_hold = 1'b1;  next_cyc = 2'd3;
            end
            default: begin
                next_pc = fpc;  retire = 1'b1;
            end
            endcase
        end

        // ------------------------------------------------- LPM (3 ciclos)
        OPC_LPM: begin
            rf_a16_pair = 4'd15;                           // Z
            case (cyc)
            2'd0: begin
                pm_d_addr = rf_a16_rdata[14:1];
                pm_d_en   = 1'b1;
                if (ptr_updates) begin
                    rf_we16 = 1'b1;  rf_w16_data = rf_a16_rdata + 16'd1;
                end
                next_tmp16 = rf_a16_rdata;
                next_use_hold = 1'b1;  next_cyc = 2'd1;
            end
            2'd1: begin
                next_use_hold = 1'b1;  next_cyc = 2'd2;
            end
            default: begin
                rf_we     = 1'b1;
                rf_w_addr = d_rd;
                rf_w_data = tmp16[0] ? pm_d_rdata[15:8] : pm_d_rdata[7:0];
                next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
            end
            endcase
        end

        OPC_SPM: begin
            pm_d_addr  = rf_a16_rdata[14:1];
            pm_d_en    = 1'b1;
            pm_d_we    = 1'b1;
            pm_d_wdata = {rf_rd_data, rf_rd_data};
            rf_a16_pair = 4'd15;
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end

        default: begin       // OPC_ILLEGAL: se trata como NOP y se señala fuera
            next_fpc = fpc + 14'd1;  next_pc = pc + 14'd1;  retire = 1'b1;
        end
        endcase
        end
    end

    assign pm_if_addr = next_fpc;

    // El par que se ESCRIBE es el mismo que se lee salvo en MOVW, que copia de
    // un par a otro. Se resuelve aquí, en un solo sitio, y no dentro del case:
    // así ninguna clase futura puede olvidarse de arrastrarlo.
    assign rf_w16_pair = (d_class == OPC_MOVW) ? d_rd[4:1] : rf_a16_pair;

    // ------------------------------------------------------- registro de estado
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            fpc      <= 14'd0;
            pc       <= 14'd0;
            cyc      <= 2'd0;
            sp       <= RAMEND;
            ir_hold  <= 16'h0000;
            use_hold <= 1'b0;
            irq_hold <= 1'b0;
            tmp16    <= 16'h0000;
            warmup   <= 1'b1;
        end else begin
            warmup   <= next_warmup;
            fpc      <= next_fpc;
            pc       <= next_pc;
            cyc      <= next_cyc;
            // La escritura desde el espacio de datos tiene prioridad sobre la
            // actualización propia: una instrucción que escribe SPL o SPH no
            // apila ni desapila a la vez, así que no compiten de verdad.
            if (sp_wr_en && sp_wr_hi)      sp <= {sp_wr_data, next_sp[7:0]};
            else if (sp_wr_en)             sp <= {next_sp[15:8], sp_wr_data};
            else                           sp <= next_sp;
            tmp16    <= next_tmp16;
            use_hold <= next_use_hold;
            irq_hold <= next_irq_hold;
            if (!use_hold) ir_hold <= pm_if_data;
        end
    end


endmodule

`default_nettype wire
