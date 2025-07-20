// AxiomaCore-328: Unidad Aritmético-Lógica AVR
// Archivo: axioma_alu.v
// Descripción: ALU compatible con instrucciones AVR de 8 bits
//              Soporta operaciones aritméticas, lógicas y de comparación
`default_nettype none

module axioma_alu (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Entradas de datos
    input wire [7:0] operand_a,        // Operando A (registro fuente)
    input wire [7:0] operand_b,        // Operando B (registro fuente o inmediato)
    input wire [4:0] alu_op,           // Código de operación ALU
    
    // Flags de entrada (Status Register - SREG)
    input wire flag_c_in,              // Carry flag entrada
    input wire flag_z_in,              // Zero flag entrada
    input wire flag_n_in,              // Negative flag entrada
    input wire flag_v_in,              // Overflow flag entrada
    input wire flag_s_in,              // Sign flag entrada
    input wire flag_h_in,              // Half carry flag entrada
    
    // Resultado y flags de salida
    output reg [7:0] result,           // Resultado de la operación
    output reg flag_c_out,             // Carry flag salida
    output reg flag_z_out,             // Zero flag salida
    output reg flag_n_out,             // Negative flag salida
    output reg flag_v_out,             // Overflow flag salida
    output reg flag_s_out,             // Sign flag salida (N ⊕ V)
    output reg flag_h_out              // Half carry flag salida
);

    // Códigos de operación ALU (compatibles con AVR)
    localparam ALU_ADD  = 5'b00000;    // ADD - Suma sin carry
    localparam ALU_ADC  = 5'b00001;    // ADC - Suma con carry
    localparam ALU_SUB  = 5'b00010;    // SUB - Resta sin borrow
    localparam ALU_SBC  = 5'b00011;    // SBC - Resta con borrow
    localparam ALU_AND  = 5'b00100;    // AND - AND lógico
    localparam ALU_OR   = 5'b00101;    // OR - OR lógico
    localparam ALU_EOR  = 5'b00110;    // EOR - XOR lógico
    localparam ALU_COM  = 5'b00111;    // COM - Complemento a 1
    localparam ALU_NEG  = 5'b01000;    // NEG - Complemento a 2
    localparam ALU_INC  = 5'b01001;    // INC - Incremento
    localparam ALU_DEC  = 5'b01010;    // DEC - Decremento
    localparam ALU_LSL  = 5'b01011;    // LSL - Shift izquierda lógico
    localparam ALU_LSR  = 5'b01100;    // LSR - Shift derecha lógico
    localparam ALU_ROL  = 5'b01101;    // ROL - Rotación izquierda
    localparam ALU_ROR  = 5'b01110;    // ROR - Rotación derecha
    localparam ALU_ASR  = 5'b01111;    // ASR - Shift derecha aritmético
    localparam ALU_SWAP = 5'b10000;    // SWAP - Intercambio de nibbles
    localparam ALU_CP   = 5'b10001;    // CP - Comparación (A - B)
    localparam ALU_CPC  = 5'b10010;    // CPC - Comparación con carry
    localparam ALU_TST  = 5'b10011;    // TST - Test (A AND A)
    localparam ALU_PASS = 5'b11111;    // PASS - Pasar operando A

    // Señales internas para cálculos
    wire [8:0] add_result;             // Resultado suma con carry extendido
    wire [8:0] sub_result;             // Resultado resta con borrow extendido
    wire [7:0] logic_result;           // Resultado operaciones lógicas
    wire [7:0] shift_result;           // Resultado operaciones de shift
    
    // Cálculos combinacionales
    assign add_result = {1'b0, operand_a} + {1'b0, operand_b} + 
                       ((alu_op == ALU_ADC) ? {8'b0, flag_c_in} : 9'b0);
    
    assign sub_result = {1'b0, operand_a} - {1'b0, operand_b} - 
                       ((alu_op == ALU_SBC) ? {8'b0, flag_c_in} : 9'b0);

    // Lógica principal de la ALU
    always @(*) begin
        // Valores por defecto
        result = 8'h00;
        flag_c_out = flag_c_in;
        flag_z_out = 1'b0;
        flag_n_out = 1'b0;
        flag_v_out = flag_v_in;
        flag_h_out = flag_h_in;
        
        case (alu_op)
            ALU_ADD, ALU_ADC: begin
                result = add_result[7:0];
                flag_c_out = add_result[8];
                flag_h_out = (operand_a[3] & operand_b[3]) | 
                            (operand_b[3] & ~result[3]) | 
                            (~result[3] & operand_a[3]);
                flag_v_out = (operand_a[7] & operand_b[7] & ~result[7]) |
                            (~operand_a[7] & ~operand_b[7] & result[7]);
            end
            
            ALU_SUB, ALU_SBC, ALU_CP, ALU_CPC: begin
                result = sub_result[7:0];
                flag_c_out = sub_result[8];
                flag_h_out = (~operand_a[3] & operand_b[3]) | 
                            (operand_b[3] & result[3]) | 
                            (result[3] & ~operand_a[3]);
                flag_v_out = (operand_a[7] & ~operand_b[7] & ~result[7]) |
                            (~operand_a[7] & operand_b[7] & result[7]);
                // Para CP y CPC, no actualizar el registro destino
                if (alu_op == ALU_CP || alu_op == ALU_CPC) begin
                    result = operand_a;  // No modificar operando A
                end
            end
            
            ALU_AND: begin
                result = operand_a & operand_b;
                flag_v_out = 1'b0;
            end
            
            ALU_OR: begin
                result = operand_a | operand_b;
                flag_v_out = 1'b0;
            end
            
            ALU_EOR: begin
                result = operand_a ^ operand_b;
                flag_v_out = 1'b0;
            end
            
            ALU_COM: begin
                result = ~operand_a;
                flag_c_out = 1'b1;
                flag_v_out = 1'b0;
            end
            
            ALU_NEG: begin
                result = -operand_a;
                flag_c_out = (result != 8'h00);
                flag_h_out = result[3] | operand_a[3];
                flag_v_out = (result == 8'h80);
            end
            
            ALU_INC: begin
                result = operand_a + 8'h01;
                flag_v_out = (operand_a == 8'h7F);
            end
            
            ALU_DEC: begin
                result = operand_a - 8'h01;
                flag_v_out = (operand_a == 8'h80);
            end
            
            ALU_LSL: begin
                result = {operand_a[6:0], 1'b0};
                flag_c_out = operand_a[7];
                flag_v_out = operand_a[7] ^ operand_a[6];
            end
            
            ALU_LSR: begin
                result = {1'b0, operand_a[7:1]};
                flag_c_out = operand_a[0];
                flag_v_out = operand_a[0] ^ result[7];
            end
            
            ALU_ROL: begin
                result = {operand_a[6:0], flag_c_in};
                flag_c_out = operand_a[7];
                flag_v_out = operand_a[7] ^ operand_a[6];
            end
            
            ALU_ROR: begin
                result = {flag_c_in, operand_a[7:1]};
                flag_c_out = operand_a[0];
                flag_v_out = result[7] ^ result[6];
            end
            
            ALU_ASR: begin
                result = {operand_a[7], operand_a[7:1]};
                flag_c_out = operand_a[0];
                flag_v_out = result[7] ^ result[6];
            end
            
            ALU_SWAP: begin
                result = {operand_a[3:0], operand_a[7:4]};
                flag_c_out = 1'b0;
                flag_v_out = 1'b0;
            end
            
            ALU_TST: begin
                result = operand_a & operand_a;
                flag_v_out = 1'b0;
            end
            
            ALU_PASS: begin
                result = operand_a;
            end
            
            default: begin
                result = operand_a;
            end
        endcase
        
        // Flags comunes calculados después de la operación
        flag_z_out = (result == 8'h00);
        flag_n_out = result[7];
        flag_s_out = flag_n_out ^ flag_v_out;  // Sign = N ⊕ V
    end

endmodule

`default_nettype wire