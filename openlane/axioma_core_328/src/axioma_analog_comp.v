// AxiomaCore-328: Analog Comparator
// Archivo: axioma_analog_comp.v
// Descripción: Comparador analógico compatible ATmega328P
//              Compara voltajes en pines AIN0 (PD6) y AIN1 (PD7)
`default_nettype none

module axioma_analog_comp (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Entradas analógicas
    input wire ain0,                   // Entrada positiva del comparador (PD6)
    input wire ain1,                   // Entrada negativa del comparador (PD7)
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Interrupción
    output wire analog_comp_interrupt, // Interrupción del comparador
    
    // Debug
    output wire debug_aco,
    output wire debug_acie
);

    // Direcciones I/O del Analog Comparator (ATmega328P compatible)
    localparam ADDR_ACSR = 6'h10;      // 0x30 - Analog Comparator Control and Status Register
    localparam ADDR_DIDR1 = 6'h3F;     // 0x7F - Digital Input Disable Register 1
    
    // Registros del Analog Comparator
    reg [7:0] acsr_reg;                // Analog Comparator Control and Status Register
    reg [7:0] didr1_reg;               // Digital Input Disable Register 1
    
    // Bits de ACSR
    wire acd = acsr_reg[7];            // Analog Comparator Disable
    wire acbg = acsr_reg[6];           // Analog Comparator Bandgap Select
    wire aco = acsr_reg[5];            // Analog Comparator Output
    wire aci = acsr_reg[4];            // Analog Comparator Interrupt Flag
    wire acie = acsr_reg[3];           // Analog Comparator Interrupt Enable
    wire acic = acsr_reg[2];           // Analog Comparator Input Capture Enable
    wire [1:0] acis = acsr_reg[1:0];   // Analog Comparator Interrupt Mode Select
    
    // Bits de DIDR1
    wire ain1d = didr1_reg[1];         // AIN1 Digital Input Disable
    wire ain0d = didr1_reg[0];         // AIN0 Digital Input Disable
    
    // Estados internos
    reg aco_internal;                  // Salida del comparador interno
    reg aco_prev;                      // Valor anterior para detectar cambios
    reg aci_flag;                      // Flag de interrupción interno
    reg [3:0] comparator_delay;        // Delay para estabilización
    
    // Voltaje de referencia interno (1.1V simulado)
    wire bandgap_ref = 1'b0;           // Simulado - siempre menor que entradas
    
    // Lógica del comparador analógico
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            aco_internal <= 1'b0;
            aco_prev <= 1'b0;
            aci_flag <= 1'b0;
            comparator_delay <= 4'h0;
        end else if (!acd) begin  // Si el comparador está habilitado
            // Delay de estabilización del comparador
            if (comparator_delay < 4'hF) begin
                comparator_delay <= comparator_delay + 4'h1;
            end else begin
                // Lógica de comparación simplificada
                if (acbg) begin
                    // Comparar AIN0 con bandgap interno (1.1V)
                    aco_internal <= ain0;  // Simplificado: ain0 > bandgap
                end else begin
                    // Comparar AIN0 con AIN1
                    aco_internal <= ain0;  // Simplificado: ain0 > ain1 cuando ain0=1
                end
                
                // Detección de cambios para interrupciones
                aco_prev <= aco_internal;
                
                // Generar interrupción basada en ACIS
                case (acis)
                    2'b00: begin  // Toggle - cualquier cambio lógico
                        if (aco_internal != aco_prev) begin
                            aci_flag <= 1'b1;
                        end
                    end
                    2'b10: begin  // Falling edge
                        if (aco_prev && !aco_internal) begin
                            aci_flag <= 1'b1;
                        end
                    end
                    2'b11: begin  // Rising edge
                        if (!aco_prev && aco_internal) begin
                            aci_flag <= 1'b1;
                        end
                    end
                    default: begin
                        // Modo reservado - no generar interrupción
                    end
                endcase
            end
        end else begin
            // Comparador deshabilitado
            aco_internal <= 1'b0;
            comparator_delay <= 4'h0;
        end
    end
    
    // Actualización del registro ACSR
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            acsr_reg <= 8'h00;
            didr1_reg <= 8'h00;
        end else begin
            // Actualizar bit ACO automáticamente
            acsr_reg[5] <= aco_internal;
            acsr_reg[4] <= aci_flag;
            
            // Escribir registros I/O
            if (io_write) begin
                case (io_addr)
                    ADDR_ACSR: begin
                        acsr_reg[7:6] <= io_data_in[7:6];  // ACD, ACBG
                        acsr_reg[3:0] <= io_data_in[3:0];  // ACIE, ACIC, ACIS
                        // Clear ACI flag si se escribe 1
                        if (io_data_in[4]) begin
                            aci_flag <= 1'b0;
                            acsr_reg[4] <= 1'b0;
                        end
                    end
                    ADDR_DIDR1: didr1_reg <= io_data_in;
                endcase
            end
        end
    end
    
    // I/O Register read
    always @(*) begin
        io_data_out = 8'h00;
        if (io_read) begin
            case (io_addr)
                ADDR_ACSR:  io_data_out = acsr_reg;
                ADDR_DIDR1: io_data_out = didr1_reg;
                default:    io_data_out = 8'h00;
            endcase
        end
    end
    
    // Salida de interrupción
    assign analog_comp_interrupt = aci_flag && acie;
    
    // Debug outputs
    assign debug_aco = aco_internal;
    assign debug_acie = acie;

endmodule

`default_nettype wire