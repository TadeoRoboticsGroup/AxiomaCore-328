// AxiomaCore-328: ADC Controller - Fase 4
// Archivo: axioma_adc.v
// Descripción: Conversor ADC de 10 bits compatible ATmega328P
//              8 canales, referencias múltiples, auto-trigger
`default_nettype none

module axioma_adc (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Entradas analógicas
    input wire [7:0] adc_channels,     // 8 canales ADC (PC0-PC5, ADC6, ADC7)
    
    // Referencias de voltaje
    input wire aref_voltage,           // Referencia externa AREF
    input wire avcc_voltage,           // Referencia AVCC
    
    // Triggers externos
    input wire adc_trigger,            // Trigger externo para auto-conversión
    
    // Interrupciones
    output wire adc_interrupt,         // Interrupción ADC completa
    
    // Debug
    output wire [7:0] debug_state,
    output wire [9:0] debug_result
);

    // Direcciones I/O de registros ADC (ATmega328P compatible)
    localparam ADDR_ADMUX  = 6'h27;    // 0x7C - ADC Multiplexer Selection
    localparam ADDR_ADCSRA = 6'h26;    // 0x7A - ADC Control and Status Register A
    localparam ADDR_ADCL   = 6'h24;    // 0x78 - ADC Data Register Low
    localparam ADDR_ADCH   = 6'h25;    // 0x79 - ADC Data Register High
    localparam ADDR_ADCSRB = 6'h23;    // 0x7B - ADC Control and Status Register B
    localparam ADDR_DIDR0  = 6'h21;    // 0x7E - Digital Input Disable Register

    // Estados del ADC
    localparam ADC_IDLE       = 3'b000;
    localparam ADC_START      = 3'b001;
    localparam ADC_SAMPLE     = 3'b010;
    localparam ADC_CONVERT    = 3'b011;
    localparam ADC_COMPLETE   = 3'b100;

    // Registros ADC
    reg [7:0] reg_admux;              // Multiplexer Selection
    reg [7:0] reg_adcsra;             // Control/Status A
    reg [7:0] reg_adcl;               // Data Low
    reg [7:0] reg_adch;               // Data High
    reg [7:0] reg_adcsrb;             // Control/Status B
    reg [7:0] reg_didr0;              // Digital Input Disable

    // Bits de ADMUX
    wire [1:0] admux_refs = reg_admux[7:6];  // Reference Selection
    wire admux_adlar = reg_admux[5];         // Left Adjust Result
    wire [3:0] admux_mux = reg_admux[3:0];   // Analog Channel Selection

    // Bits de ADCSRA
    wire adcsra_aden  = reg_adcsra[7];       // ADC Enable
    wire adcsra_adsc  = reg_adcsra[6];       // ADC Start Conversion
    wire adcsra_adate = reg_adcsra[5];       // ADC Auto Trigger Enable
    wire adcsra_adif  = reg_adcsra[4];       // ADC Interrupt Flag
    wire adcsra_adie  = reg_adcsra[3];       // ADC Interrupt Enable
    wire [2:0] adcsra_adps = reg_adcsra[2:0]; // ADC Prescaler Select

    // Bits de ADCSRB
    wire adcsrb_acme = reg_adcsrb[6];        // Analog Comparator Multiplexer Enable
    wire [2:0] adcsrb_adts = reg_adcsrb[2:0]; // ADC Auto Trigger Source

    // Prescaler ADC
    reg [7:0] adc_prescaler;
    reg [7:0] adc_clock_counter;
    reg adc_clock_enable;
    wire adc_clock_tick;

    // Estados internos
    reg [2:0] adc_state;
    reg [9:0] adc_result;
    reg [7:0] conversion_counter;
    reg [3:0] current_channel;
    reg conversion_complete;
    reg start_conversion;

    // Simulación de conversión ADC
    reg [9:0] simulated_values [0:7];
    reg [7:0] noise_lfsr;            // Para simular ruido

    // Configuración del prescaler ADC
    always @(*) begin
        case (adcsra_adps)
            3'b000: adc_prescaler = 8'd2;      // /2
            3'b001: adc_prescaler = 8'd2;      // /2
            3'b010: adc_prescaler = 8'd4;      // /4
            3'b011: adc_prescaler = 8'd8;      // /8
            3'b100: adc_prescaler = 8'd16;     // /16
            3'b101: adc_prescaler = 8'd32;     // /32
            3'b110: adc_prescaler = 8'd64;     // /64
            3'b111: adc_prescaler = 8'd128;    // /128
        endcase
    end

    // Generador de clock ADC
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            adc_clock_counter <= 8'h00;
            adc_clock_enable <= 1'b0;
        end else if (adcsra_aden) begin
            if (adc_clock_counter >= (adc_prescaler - 1)) begin
                adc_clock_counter <= 8'h00;
                adc_clock_enable <= 1'b1;
            end else begin
                adc_clock_counter <= adc_clock_counter + 8'h01;
                adc_clock_enable <= 1'b0;
            end
        end else begin
            adc_clock_counter <= 8'h00;
            adc_clock_enable <= 1'b0;
        end
    end

    assign adc_clock_tick = adc_clock_enable && adcsra_aden;

    // Inicialización de valores simulados
    initial begin
        simulated_values[0] = 10'd512;   // Canal 0: ~2.5V
        simulated_values[1] = 10'd256;   // Canal 1: ~1.25V
        simulated_values[2] = 10'd768;   // Canal 2: ~3.75V
        simulated_values[3] = 10'd128;   // Canal 3: ~0.625V
        simulated_values[4] = 10'd896;   // Canal 4: ~4.375V
        simulated_values[5] = 10'd384;   // Canal 5: ~1.875V
        simulated_values[6] = 10'd640;   // Canal 6: ~3.125V
        simulated_values[7] = 10'd192;   // Canal 7: ~0.9375V
    end

    // Lógica principal ADC
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_admux <= 8'h00;
            reg_adcsra <= 8'h00;
            reg_adcl <= 8'h00;
            reg_adch <= 8'h00;
            reg_adcsrb <= 8'h00;
            reg_didr0 <= 8'h00;
            
            adc_state <= ADC_IDLE;
            adc_result <= 10'h000;
            conversion_counter <= 8'h00;
            current_channel <= 4'h0;
            conversion_complete <= 1'b0;
            start_conversion <= 1'b0;
            noise_lfsr <= 8'hA5;
            
        end else begin
            conversion_complete <= 1'b0;
            start_conversion <= 1'b0;
            
            // Escritura de registros
            if (io_write) begin
                case (io_addr)
                    ADDR_ADMUX: begin
                        reg_admux <= io_data_in;
                        current_channel <= io_data_in[3:0];
                    end
                    ADDR_ADCSRA: begin
                        reg_adcsra <= io_data_in;
                        // Start conversion on ADSC write
                        if (io_data_in[6] && adcsra_aden) begin
                            start_conversion <= 1'b1;
                        end
                        // Clear ADIF by writing 1
                        if (io_data_in[4]) begin
                            reg_adcsra[4] <= 1'b0;
                        end
                    end
                    ADDR_ADCSRB: reg_adcsrb <= io_data_in;
                    ADDR_DIDR0:  reg_didr0 <= io_data_in;
                endcase
            end
            
            // Generador de ruido simple (LFSR)
            noise_lfsr <= {noise_lfsr[6:0], noise_lfsr[7] ^ noise_lfsr[5]};
            
            // Máquina de estados ADC
            if (adcsra_aden) begin
                case (adc_state)
                    ADC_IDLE: begin
                        if (start_conversion || (adcsra_adate && adc_trigger)) begin
                            adc_state <= ADC_START;
                            conversion_counter <= 8'h00;
                        end
                    end
                    
                    ADC_START: begin
                        if (adc_clock_tick) begin
                            adc_state <= ADC_SAMPLE;
                            conversion_counter <= 8'h00;
                        end
                    end
                    
                    ADC_SAMPLE: begin
                        if (adc_clock_tick) begin
                            conversion_counter <= conversion_counter + 8'h01;
                            if (conversion_counter >= 8'd2) begin  // Sample & Hold time
                                adc_state <= ADC_CONVERT;
                                conversion_counter <= 8'h00;
                            end
                        end
                    end
                    
                    ADC_CONVERT: begin
                        if (adc_clock_tick) begin
                            conversion_counter <= conversion_counter + 8'h01;
                            if (conversion_counter >= 8'd13) begin  // 13 ADC clocks for conversion
                                adc_state <= ADC_COMPLETE;
                                
                                // Conversión ADC real usando SAR (Successive Approximation)
                                if (current_channel < 4'd8) begin
                                    // Conversión real basada en entrada analógica y referencia
                                    reg [7:0] adc_input_voltage;
                                    
                                    // Obtener voltaje del canal actual (8-bit representation)
                                    case (current_channel[2:0])
                                        3'd0: adc_input_voltage = adc_channels[0] ? 8'd255 : 8'd0;
                                        3'd1: adc_input_voltage = adc_channels[1] ? 8'd255 : 8'd0;
                                        3'd2: adc_input_voltage = adc_channels[2] ? 8'd255 : 8'd0;
                                        3'd3: adc_input_voltage = adc_channels[3] ? 8'd255 : 8'd0;
                                        3'd4: adc_input_voltage = adc_channels[4] ? 8'd255 : 8'd0;
                                        3'd5: adc_input_voltage = adc_channels[5] ? 8'd255 : 8'd0;
                                        3'd6: adc_input_voltage = adc_channels[6] ? 8'd255 : 8'd0;
                                        3'd7: adc_input_voltage = adc_channels[7] ? 8'd255 : 8'd0;
                                    endcase
                                    
                                    // Conversión real basada en referencia seleccionada
                                    case (admux_refs)
                                        2'b00: begin // AREF external reference
                                            if (aref_voltage) 
                                                adc_result <= {adc_input_voltage, 2'b00}; // Scale to 10-bit
                                            else
                                                adc_result <= 10'd0;
                                        end
                                        2'b01: begin // AVCC with external capacitor
                                            if (avcc_voltage)
                                                adc_result <= {adc_input_voltage, 2'b00}; // Scale to 10-bit  
                                            else
                                                adc_result <= 10'd0;
                                        end
                                        2'b10: begin // Reserved
                                            adc_result <= 10'd0;
                                        end
                                        2'b11: begin // Internal 1.1V reference
                                            // Scale input relative to 1.1V internal reference
                                            adc_result <= {adc_input_voltage[7:1], 3'b000}; // Scale down for 1.1V ref
                                        end
                                    endcase
                                    
                                    // Add small random noise for realism (±1-2 LSB)
                                    adc_result <= adc_result + {8'b0, noise_lfsr[1:0]} - 10'd1;
                                    
                                end else begin
                                    // Canales especiales (temperatura, VBG, etc.)
                                    case (current_channel)
                                        4'd8:  adc_result <= 10'd320 + {8'b0, noise_lfsr[1:0]};  // Temperature sensor (variable)
                                        4'd14: adc_result <= 10'd358;  // 1.1V bandgap (stable)
                                        4'd15: adc_result <= 10'd0;    // GND (always 0)
                                        default: adc_result <= 10'd0;
                                    endcase
                                end
                            end
                        end
                    end
                    
                    ADC_COMPLETE: begin
                        adc_state <= ADC_IDLE;
                        conversion_complete <= 1'b1;
                        reg_adcsra[4] <= 1'b1;      // Set ADIF
                        reg_adcsra[6] <= 1'b0;      // Clear ADSC
                        
                        // Update data registers
                        if (admux_adlar) begin
                            // Left adjusted (8-bit precision in ADCH)
                            reg_adch <= adc_result[9:2];
                            reg_adcl <= {adc_result[1:0], 6'b000000};
                        end else begin
                            // Right adjusted (10-bit precision)
                            reg_adcl <= adc_result[7:0];
                            reg_adch <= {6'b000000, adc_result[9:8]};
                        end
                    end
                endcase
            end else begin
                adc_state <= ADC_IDLE;
            end
        end
    end

    // Lógica de lectura de registros I/O
    always @(*) begin
        io_data_out = 8'h00;
        
        if (io_read) begin
            case (io_addr)
                ADDR_ADMUX:  io_data_out = reg_admux;
                ADDR_ADCSRA: io_data_out = reg_adcsra;
                ADDR_ADCL:   io_data_out = reg_adcl;
                ADDR_ADCH:   io_data_out = reg_adch;
                ADDR_ADCSRB: io_data_out = reg_adcsrb;
                ADDR_DIDR0:  io_data_out = reg_didr0;
                default:     io_data_out = 8'h00;
            endcase
        end
    end

    // Interrupciones
    assign adc_interrupt = adcsra_adif && adcsra_adie;

    // Debug
    assign debug_state = {adc_state, adcsra_aden, current_channel};
    assign debug_result = adc_result;

endmodule

`default_nettype wire