// AxiomaCore-328: Decodificador de Instrucciones AVR
// Archivo: axioma_decoder.v
// Descripción: Decodifica instrucciones AVR de 16 bits y genera señales de control
//              Implementa subset inicial de instrucciones más comunes
`default_nettype none

module axioma_decoder (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Entrada de instrucción
    input wire [15:0] instruction,     // Instrucción de 16 bits del Flash
    input wire instruction_valid,      // Instrucción válida
    
    // Señales de control de registros
    output reg [4:0] rs1_addr,         // Dirección registro fuente 1
    output reg [4:0] rs2_addr,         // Dirección registro fuente 2
    output reg [4:0] rd_addr,          // Dirección registro destino
    output reg rd_write_en,            // Habilitar escritura registro
    
    // Señales de control ALU
    output reg [4:0] alu_op,           // Operación ALU
    output reg alu_use_immediate,      // Usar inmediato en lugar de rs2
    output reg [7:0] immediate,        // Valor inmediato
    
    // Señales de control de memoria
    output reg mem_read,               // Leer de memoria
    output reg mem_write,              // Escribir a memoria
    output reg use_pointer,            // Usar puntero X/Y/Z
    output reg [1:0] pointer_sel,      // Selección de puntero (0=X, 1=Y, 2=Z)
    
    // Señales de control de flujo
    output reg branch_en,              // Habilitar branch
    output reg [2:0] branch_condition, // Condición de branch
    output reg [11:0] branch_offset,   // Offset del branch
    output reg jump_en,                // Habilitar jump
    output reg [21:0] jump_addr,       // Dirección de jump
    
    // Estado del decodificador
    output reg instruction_decoded,    // Instrucción decodificada exitosamente
    output reg unsupported_instruction // Instrucción no soportada
);

    // Campos de la instrucción (formato AVR)
    wire [3:0] opcode_high = instruction[15:12];
    wire [3:0] opcode_mid = instruction[11:8];
    wire [3:0] opcode_low = instruction[7:4];
    wire [3:0] opcode_bottom = instruction[3:0];
    
    // Decodificación de registros (Rd, Rr formato estándar AVR)
    wire [4:0] rd_field = instruction[8:4];     // Registro destino
    wire [4:0] rr_field = {instruction[9], instruction[3:0]}; // Registro fuente
    
    // Inmediatos para diferentes formatos
    wire [7:0] k8_immediate = instruction[11:4]; // Inmediato de 8 bits
    wire [5:0] k6_immediate = instruction[9:4];  // Inmediato de 6 bits
    
    // Códigos de operación principales (subset inicial)
    localparam OP_NOP     = 16'h0000;  // No operation
    localparam OP_ADD_MSK = 16'hFC00;  // ADD Rd, Rr
    localparam OP_ADD     = 16'h0C00;
    localparam OP_ADC_MSK = 16'hFC00;  // ADC Rd, Rr  
    localparam OP_ADC     = 16'h1C00;
    localparam OP_SUB_MSK = 16'hFC00;  // SUB Rd, Rr
    localparam OP_SUB     = 16'h1800;
    localparam OP_AND_MSK = 16'hFC00;  // AND Rd, Rr
    localparam OP_AND     = 16'h2000;
    localparam OP_OR_MSK  = 16'hFC00;  // OR Rd, Rr
    localparam OP_OR      = 16'h2800;
    localparam OP_EOR_MSK = 16'hFC00;  // EOR Rd, Rr
    localparam OP_EOR     = 16'h2400;
    localparam OP_MOV_MSK = 16'hFC00;  // MOV Rd, Rr
    localparam OP_MOV     = 16'h2C00;
    localparam OP_LDI_MSK = 16'hF000;  // LDI Rd, K
    localparam OP_LDI     = 16'hE000;
    localparam OP_CPI_MSK = 16'hF000;  // CPI Rd, K
    localparam OP_CPI     = 16'h3000;
    localparam OP_RJMP_MSK = 16'hF000; // RJMP k
    localparam OP_RJMP    = 16'hC000;
    localparam OP_BREQ_MSK = 16'hFC07; // BREQ k
    localparam OP_BREQ    = 16'hF001;
    localparam OP_BRNE_MSK = 16'hFC07; // BRNE k  
    localparam OP_BRNE    = 16'hF401;

    // ALU operation mappings (importados de axioma_alu.v)
    localparam ALU_ADD  = 5'b00000;
    localparam ALU_ADC  = 5'b00001;
    localparam ALU_SUB  = 5'b00010;
    localparam ALU_AND  = 5'b00100;
    localparam ALU_OR   = 5'b00101;
    localparam ALU_EOR  = 5'b00110;
    localparam ALU_CP   = 5'b10001;
    localparam ALU_PASS = 5'b11111;

    // Branch conditions
    localparam BRANCH_EQ  = 3'b001;    // Branch if equal (Z=1)
    localparam BRANCH_NE  = 3'b010;    // Branch if not equal (Z=0)

    // Lógica de decodificación principal
    always @(*) begin
        // Valores por defecto
        rs1_addr = 5'b00000;
        rs2_addr = 5'b00000;
        rd_addr = 5'b00000;
        rd_write_en = 1'b0;
        alu_op = ALU_PASS;
        alu_use_immediate = 1'b0;
        immediate = 8'h00;
        mem_read = 1'b0;
        mem_write = 1'b0;
        use_pointer = 1'b0;
        pointer_sel = 2'b00;
        branch_en = 1'b0;
        branch_condition = 3'b000;
        branch_offset = 12'h000;
        jump_en = 1'b0;
        jump_addr = 22'h000000;
        instruction_decoded = 1'b0;
        unsupported_instruction = 1'b0;
        
        if (instruction_valid) begin
            casez (instruction)
                OP_NOP: begin
                    // NOP - No operation
                    instruction_decoded = 1'b1;
                end
                
                {OP_ADD_MSK, 4'b????}: begin
                    if ((instruction & OP_ADD_MSK) == OP_ADD) begin
                        // ADD Rd, Rr
                        rs1_addr = rd_field;
                        rs2_addr = rr_field;
                        rd_addr = rd_field;
                        rd_write_en = 1'b1;
                        alu_op = ALU_ADD;
                        instruction_decoded = 1'b1;
                    end
                end
                
                {OP_ADC_MSK, 4'b????}: begin
                    if ((instruction & OP_ADC_MSK) == OP_ADC) begin
                        // ADC Rd, Rr
                        rs1_addr = rd_field;
                        rs2_addr = rr_field;
                        rd_addr = rd_field;
                        rd_write_en = 1'b1;
                        alu_op = ALU_ADC;
                        instruction_decoded = 1'b1;
                    end
                end
                
                {OP_SUB_MSK, 4'b????}: begin
                    if ((instruction & OP_SUB_MSK) == OP_SUB) begin
                        // SUB Rd, Rr
                        rs1_addr = rd_field;
                        rs2_addr = rr_field;
                        rd_addr = rd_field;
                        rd_write_en = 1'b1;
                        alu_op = ALU_SUB;
                        instruction_decoded = 1'b1;
                    end
                end
                
                {OP_AND_MSK, 4'b????}: begin
                    if ((instruction & OP_AND_MSK) == OP_AND) begin
                        // AND Rd, Rr
                        rs1_addr = rd_field;
                        rs2_addr = rr_field;
                        rd_addr = rd_field;
                        rd_write_en = 1'b1;
                        alu_op = ALU_AND;
                        instruction_decoded = 1'b1;
                    end
                end
                
                {OP_OR_MSK, 4'b????}: begin
                    if ((instruction & OP_OR_MSK) == OP_OR) begin
                        // OR Rd, Rr
                        rs1_addr = rd_field;
                        rs2_addr = rr_field;
                        rd_addr = rd_field;
                        rd_write_en = 1'b1;
                        alu_op = ALU_OR;
                        instruction_decoded = 1'b1;
                    end
                end
                
                {OP_EOR_MSK, 4'b????}: begin
                    if ((instruction & OP_EOR_MSK) == OP_EOR) begin
                        // EOR Rd, Rr
                        rs1_addr = rd_field;
                        rs2_addr = rr_field;
                        rd_addr = rd_field;
                        rd_write_en = 1'b1;
                        alu_op = ALU_EOR;
                        instruction_decoded = 1'b1;
                    end
                end
                
                {OP_MOV_MSK, 4'b????}: begin
                    if ((instruction & OP_MOV_MSK) == OP_MOV) begin
                        // MOV Rd, Rr (usar ALU en modo PASS)
                        rs1_addr = rr_field;  // Fuente
                        rd_addr = rd_field;   // Destino
                        rd_write_en = 1'b1;
                        alu_op = ALU_PASS;
                        instruction_decoded = 1'b1;
                    end
                end
                
                default: begin
                    // Verificar instrucciones con máscaras específicas
                    if ((instruction & OP_LDI_MSK) == OP_LDI) begin
                        // LDI Rd, K (Load Immediate)  
                        rd_addr = {1'b1, instruction[7:4]};  // Rd = R16-R31
                        rd_write_en = 1'b1;
                        alu_op = ALU_PASS;
                        alu_use_immediate = 1'b1;
                        immediate = {instruction[11:8], instruction[3:0]};  // K = KKKK KKKK
                        instruction_decoded = 1'b1;
                    end else if ((instruction & OP_CPI_MSK) == OP_CPI) begin
                        // CPI Rd, K (Compare with Immediate)
                        rs1_addr = {1'b1, instruction[7:4]};  // Rd = R16-R31
                        alu_op = ALU_CP;
                        alu_use_immediate = 1'b1;
                        immediate = {instruction[11:8], instruction[3:0]};  // K = KKKK KKKK
                        instruction_decoded = 1'b1;
                    end else if ((instruction & OP_RJMP_MSK) == OP_RJMP) begin
                        // RJMP k (Relative Jump)
                        jump_en = 1'b1;
                        jump_addr = {{10{instruction[11]}}, instruction[11:0]}; // Sign extend
                        instruction_decoded = 1'b1;
                    end else if ((instruction & OP_BREQ_MSK) == OP_BREQ) begin
                        // BREQ k (Branch if Equal)
                        branch_en = 1'b1;
                        branch_condition = BRANCH_EQ;
                        branch_offset = {{5{instruction[9]}}, instruction[9:3]}; // Sign extend
                        instruction_decoded = 1'b1;
                    end else if ((instruction & OP_BRNE_MSK) == OP_BRNE) begin
                        // BRNE k (Branch if Not Equal)
                        branch_en = 1'b1;
                        branch_condition = BRANCH_NE;
                        branch_offset = {{5{instruction[9]}}, instruction[9:3]}; // Sign extend
                        instruction_decoded = 1'b1;
                    end else begin
                        // Instrucción no reconocida
                        unsupported_instruction = 1'b1;
                    end
                end
                
            endcase
        end
    end

endmodule

`default_nettype wire