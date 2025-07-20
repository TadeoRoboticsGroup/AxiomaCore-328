// AxiomaCore-328: Banco de Registros AVR
// Archivo: axioma_registers.v
// Descripción: 32 registros de propósito general de 8 bits (R0-R31)
//              Compatible con arquitectura AVR
`default_nettype none

module axioma_registers (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Puerto A de lectura (RS1 - Source 1)
    input wire [4:0] rs1_addr,         // Dirección registro fuente 1 (R0-R31)
    output wire [7:0] rs1_data,        // Datos registro fuente 1
    
    // Puerto B de lectura (RS2 - Source 2) 
    input wire [4:0] rs2_addr,         // Dirección registro fuente 2 (R0-R31)
    output wire [7:0] rs2_data,        // Datos registro fuente 2
    
    // Puerto de escritura (RD - Destination)
    input wire [4:0] rd_addr,          // Dirección registro destino (R0-R31)
    input wire [7:0] rd_data,          // Datos a escribir
    input wire rd_write_en,            // Habilitador de escritura
    
    // Acceso especial para punteros X, Y, Z (registros 26-31)
    output wire [15:0] x_pointer,      // X = R27:R26
    output wire [15:0] y_pointer,      // Y = R29:R28  
    output wire [15:0] z_pointer,      // Z = R31:R30
    
    input wire [15:0] x_pointer_in,    // Escritura directa de X
    input wire [15:0] y_pointer_in,    // Escritura directa de Y
    input wire [15:0] z_pointer_in,    // Escritura directa de Z
    input wire x_write_en,             // Habilitar escritura X
    input wire y_write_en,             // Habilitar escritura Y
    input wire z_write_en              // Habilitar escritura Z
);

    // Banco de 32 registros de 8 bits
    reg [7:0] registers [0:31];
    
    // Índices para registros especiales AVR
    localparam R26 = 5'd26;  // XL
    localparam R27 = 5'd27;  // XH
    localparam R28 = 5'd28;  // YL
    localparam R29 = 5'd29;  // YH
    localparam R30 = 5'd30;  // ZL
    localparam R31 = 5'd31;  // ZH
    
    // Variable para bucle de reset
    integer i;
    
    // Reset y escritura de registros
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            // Reset: todos los registros a 0
            for (i = 0; i < 32; i = i + 1) begin
                registers[i] <= 8'h00;
            end
        end else begin
            // Escritura normal por puerto RD
            if (rd_write_en) begin
                registers[rd_addr] <= rd_data;
            end
            
            // Escritura especial de punteros de 16 bits
            if (x_write_en) begin
                registers[R26] <= x_pointer_in[7:0];   // XL
                registers[R27] <= x_pointer_in[15:8];  // XH
            end
            
            if (y_write_en) begin
                registers[R28] <= y_pointer_in[7:0];   // YL
                registers[R29] <= y_pointer_in[15:8];  // YH
            end
            
            if (z_write_en) begin
                registers[R30] <= z_pointer_in[7:0];   // ZL
                registers[R31] <= z_pointer_in[15:8];  // ZH
            end
        end
    end
    
    // Lectura asíncrona (puerto RS1)
    assign rs1_data = registers[rs1_addr];
    
    // Lectura asíncrona (puerto RS2)
    assign rs2_data = registers[rs2_addr];
    
    // Ensamblado de punteros de 16 bits
    assign x_pointer = {registers[R27], registers[R26]};  // X = XH:XL
    assign y_pointer = {registers[R29], registers[R28]};  // Y = YH:YL
    assign z_pointer = {registers[R31], registers[R30]};  // Z = ZH:ZL

endmodule

`default_nettype wire