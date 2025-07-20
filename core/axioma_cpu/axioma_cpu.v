// AxiomaCore-328: Núcleo de CPU AVR Básico
// Archivo: axioma_cpu.v
// Descripción: CPU AVR de 8 bits con pipeline de 2 etapas
//              Integra ALU, registros, decodificador y control de flujo
`default_nettype none

module axioma_cpu (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz de memoria de programa (Flash)
    output reg [15:0] program_addr,    // Dirección de programa (PC)
    input wire [15:0] program_data,    // Instrucción leída
    input wire program_ready,          // Memoria lista
    
    // Interfaz de memoria de datos (SRAM)
    output reg [15:0] data_addr,       // Dirección de datos
    output reg [7:0] data_out,         // Datos a escribir
    input wire [7:0] data_in,          // Datos leídos
    output reg data_read,              // Señal de lectura
    output reg data_write,             // Señal de escritura
    input wire data_ready,             // Memoria lista
    
    // Estado de la CPU
    output reg cpu_halted,             // CPU detenida
    output reg [7:0] status_reg,       // Registro de estado (SREG)
    
    // Señales de debug
    output wire [15:0] debug_pc,       // PC actual para debug
    output wire [15:0] debug_instruction, // Instrucción actual
    output wire [7:0] debug_reg_r16,   // Contenido R16 para debug
    output wire [7:0] debug_reg_r17    // Contenido R17 para debug
);

    // Estados del pipeline
    localparam STATE_FETCH = 2'b00;    // Fetch de instrucción
    localparam STATE_DECODE = 2'b01;   // Decode y execute
    localparam STATE_WAIT = 2'b10;     // Esperar memoria
    localparam STATE_HALT = 2'b11;     // CPU detenida
    
    reg [1:0] cpu_state;
    reg [1:0] next_state;
    
    // Program Counter y control de flujo
    reg [15:0] pc;                     // Program Counter
    reg [15:0] next_pc;                // Siguiente PC
    reg pc_update;                     // Actualizar PC
    
    // Pipeline registers
    reg [15:0] instruction_reg;        // Instrucción en decode
    reg instruction_valid;             // Instrucción válida
    
    // Señales del decodificador
    wire [4:0] dec_rs1_addr, dec_rs2_addr, dec_rd_addr;
    wire dec_rd_write_en;
    wire [4:0] dec_alu_op;
    wire dec_alu_use_immediate;
    wire [7:0] dec_immediate;
    wire dec_mem_read, dec_mem_write;
    wire dec_use_pointer;
    wire [1:0] dec_pointer_sel;
    wire dec_branch_en;
    wire [2:0] dec_branch_condition;
    wire [11:0] dec_branch_offset;
    wire dec_jump_en;
    wire [21:0] dec_jump_addr;
    wire dec_instruction_decoded;
    wire dec_unsupported_instruction;
    
    // Señales del banco de registros
    wire [7:0] reg_rs1_data, reg_rs2_data;
    wire [15:0] reg_x_pointer, reg_y_pointer, reg_z_pointer;
    reg reg_rd_write_en;
    reg [7:0] reg_rd_data;
    
    // Señales de la ALU
    wire [7:0] alu_result;
    wire alu_flag_c, alu_flag_z, alu_flag_n, alu_flag_v, alu_flag_s, alu_flag_h;
    reg alu_update_flags;
    
    // Operando B de la ALU (registro o inmediato)
    wire [7:0] alu_operand_b = dec_alu_use_immediate ? dec_immediate : reg_rs2_data;
    
    // Status Register (SREG) - bits individuales
    wire sreg_c = status_reg[0];  // Carry
    wire sreg_z = status_reg[1];  // Zero
    wire sreg_n = status_reg[2];  // Negative
    wire sreg_v = status_reg[3];  // Overflow
    wire sreg_s = status_reg[4];  // Sign
    wire sreg_h = status_reg[5];  // Half carry
    wire sreg_t = status_reg[6];  // T flag
    wire sreg_i = status_reg[7];  // Global interrupt enable
    
    // Instanciación del decodificador
    axioma_decoder decoder_inst (
        .clk(clk),
        .reset_n(reset_n),
        .instruction(instruction_reg),
        .instruction_valid(instruction_valid),
        .rs1_addr(dec_rs1_addr),
        .rs2_addr(dec_rs2_addr),
        .rd_addr(dec_rd_addr),
        .rd_write_en(dec_rd_write_en),
        .alu_op(dec_alu_op),
        .alu_use_immediate(dec_alu_use_immediate),
        .immediate(dec_immediate),
        .mem_read(dec_mem_read),
        .mem_write(dec_mem_write),
        .use_pointer(dec_use_pointer),
        .pointer_sel(dec_pointer_sel),
        .branch_en(dec_branch_en),
        .branch_condition(dec_branch_condition),
        .branch_offset(dec_branch_offset),
        .jump_en(dec_jump_en),
        .jump_addr(dec_jump_addr),
        .instruction_decoded(dec_instruction_decoded),
        .unsupported_instruction(dec_unsupported_instruction)
    );
    
    // Instanciación del banco de registros
    axioma_registers registers_inst (
        .clk(clk),
        .reset_n(reset_n),
        .rs1_addr(dec_rs1_addr),
        .rs1_data(reg_rs1_data),
        .rs2_addr(dec_rs2_addr),
        .rs2_data(reg_rs2_data),
        .rd_addr(dec_rd_addr),
        .rd_data(reg_rd_data),
        .rd_write_en(reg_rd_write_en),
        .x_pointer(reg_x_pointer),
        .y_pointer(reg_y_pointer),
        .z_pointer(reg_z_pointer),
        .x_pointer_in(16'h0000),
        .y_pointer_in(16'h0000),
        .z_pointer_in(16'h0000),
        .x_write_en(1'b0),
        .y_write_en(1'b0),
        .z_write_en(1'b0)
    );
    
    // Instanciación de la ALU
    axioma_alu alu_inst (
        .clk(clk),
        .reset_n(reset_n),
        .operand_a(reg_rs1_data),
        .operand_b(alu_operand_b),
        .alu_op(dec_alu_op),
        .flag_c_in(sreg_c),
        .flag_z_in(sreg_z),
        .flag_n_in(sreg_n),
        .flag_v_in(sreg_v),
        .flag_s_in(sreg_s),
        .flag_h_in(sreg_h),
        .result(alu_result),
        .flag_c_out(alu_flag_c),
        .flag_z_out(alu_flag_z),
        .flag_n_out(alu_flag_n),
        .flag_v_out(alu_flag_v),
        .flag_s_out(alu_flag_s),
        .flag_h_out(alu_flag_h)
    );
    
    // Lógica de evaluación de condiciones de branch
    function branch_taken;
        input [2:0] condition;
        input [7:0] sreg;
        begin
            case (condition)
                3'b001: branch_taken = sreg[1];      // BREQ: Z=1
                3'b010: branch_taken = ~sreg[1];     // BRNE: Z=0
                default: branch_taken = 1'b0;
            endcase
        end
    endfunction
    
    // Máquina de estados principal
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cpu_state <= STATE_FETCH;
            pc <= 16'h0000;
            instruction_reg <= 16'h0000;
            instruction_valid <= 1'b0;
            status_reg <= 8'h00;
            cpu_halted <= 1'b0;
            program_addr <= 16'h0000;
            data_addr <= 16'h0000;
            data_out <= 8'h00;
            data_read <= 1'b0;
            data_write <= 1'b0;
        end else begin
            cpu_state <= next_state;
            
            case (cpu_state)
                STATE_FETCH: begin
                    if (program_ready) begin
                        // Capturar instrucción
                        instruction_reg <= program_data;
                        instruction_valid <= 1'b1;
                        program_addr <= pc + 16'h0001;  // Preparar siguiente fetch
                    end
                end
                
                STATE_DECODE: begin
                    instruction_valid <= 1'b0;
                    
                    if (dec_instruction_decoded) begin
                        // Actualizar PC
                        if (dec_jump_en) begin
                            pc <= pc + {{6{dec_jump_addr[11]}}, dec_jump_addr[11:0]};
                        end else if (dec_branch_en && branch_taken(dec_branch_condition, status_reg)) begin
                            pc <= pc + {{4{dec_branch_offset[11]}}, dec_branch_offset};
                        end else begin
                            pc <= pc + 16'h0001;
                        end
                        
                        // Actualizar flags si es operación ALU
                        if (alu_update_flags) begin
                            status_reg <= {sreg_i, sreg_t, alu_flag_h, alu_flag_s, 
                                         alu_flag_v, alu_flag_n, alu_flag_z, alu_flag_c};
                        end
                        
                    end else if (dec_unsupported_instruction) begin
                        // Instrucción no soportada - detener CPU
                        cpu_halted <= 1'b1;
                    end
                end
                
                STATE_WAIT: begin
                    // Esperar que la memoria esté lista
                    if (data_ready) begin
                        data_read <= 1'b0;
                        data_write <= 1'b0;
                    end
                end
                
                STATE_HALT: begin
                    // CPU detenida
                    cpu_halted <= 1'b1;
                end
            endcase
        end
    end
    
    // Lógica combinacional de siguiente estado
    always @(*) begin
        next_state = cpu_state;
        program_addr = pc;
        reg_rd_write_en = 1'b0;
        reg_rd_data = alu_result;
        alu_update_flags = 1'b0;
        data_read = 1'b0;
        data_write = 1'b0;
        data_addr = 16'h0000;
        data_out = 8'h00;
        
        case (cpu_state)
            STATE_FETCH: begin
                if (program_ready) begin
                    next_state = STATE_DECODE;
                end
            end
            
            STATE_DECODE: begin
                if (dec_instruction_decoded) begin
                    // Habilitar escritura de registro si es necesario
                    if (dec_rd_write_en) begin
                        reg_rd_write_en = 1'b1;
                        alu_update_flags = 1'b1;
                    end
                    
                    // Operaciones de memoria
                    if (dec_mem_read || dec_mem_write) begin
                        next_state = STATE_WAIT;
                        data_read = dec_mem_read;
                        data_write = dec_mem_write;
                        // Por simplicidad, usar dirección directa por ahora
                        data_addr = {8'h00, dec_immediate};
                        data_out = reg_rs1_data;
                    end else begin
                        next_state = STATE_FETCH;
                    end
                    
                end else if (dec_unsupported_instruction) begin
                    next_state = STATE_HALT;
                end else begin
                    next_state = STATE_FETCH;
                end
            end
            
            STATE_WAIT: begin
                if (data_ready) begin
                    next_state = STATE_FETCH;
                end
            end
            
            STATE_HALT: begin
                next_state = STATE_HALT;  // Permanecer detenido
            end
        endcase
    end
    
    // Señales de debug
    assign debug_pc = pc;
    assign debug_instruction = instruction_reg;
    assign debug_reg_r16 = registers_inst.registers[16];
    assign debug_reg_r17 = registers_inst.registers[17];

endmodule

`default_nettype wire