// AxiomaCore-328: Timer/Counter 0 - Fase 3
// Archivo: axioma_timer0.v
// Descripción: Timer 0 de 8 bits compatible ATmega328P
//              Modos Normal, CTC, Fast PWM, Phase Correct PWM
`default_nettype none

module axioma_timer0 (
    input wire clk,                    // Reloj del sistema (16MHz)
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Pines de salida PWM
    output wire oc0a_pin,              // Output Compare A (PD6)
    output wire oc0b_pin,              // Output Compare B (PD5)
    
    // Interrupciones
    output wire timer0_overflow,       // Interrupción overflow
    output wire timer0_compa,          // Interrupción Compare Match A
    output wire timer0_compb,          // Interrupción Compare Match B
    
    // Debug
    output wire [7:0] debug_tcnt0,
    output wire [2:0] debug_mode,
    output wire [2:0] debug_prescaler
);

    // Direcciones I/O de registros Timer0 (ATmega328P compatible)
    localparam ADDR_TCNT0  = 6'h26;    // 0x46 - Timer/Counter Register
    localparam ADDR_TCCR0A = 6'h24;    // 0x44 - Timer/Counter Control Register A
    localparam ADDR_TCCR0B = 6'h25;    // 0x45 - Timer/Counter Control Register B
    localparam ADDR_OCR0A  = 6'h27;    // 0x47 - Output Compare Register A
    localparam ADDR_OCR0B  = 6'h28;    // 0x48 - Output Compare Register B
    localparam ADDR_TIMSK0 = 6'h2E;    // 0x6E - Timer/Counter Interrupt Mask Register
    localparam ADDR_TIFR0  = 6'h15;    // 0x35 - Timer/Counter Interrupt Flag Register

    // Modos de funcionamiento
    localparam MODE_NORMAL        = 3'b000;
    localparam MODE_PWM_PHASE     = 3'b001;
    localparam MODE_CTC           = 3'b010;
    localparam MODE_PWM_FAST      = 3'b011;
    localparam MODE_PWM_PHASE_OCR = 3'b101;
    localparam MODE_PWM_FAST_OCR  = 3'b111;

    // Prescalers
    localparam PRESCALE_STOP  = 3'b000;
    localparam PRESCALE_1     = 3'b001;
    localparam PRESCALE_8     = 3'b010;
    localparam PRESCALE_64    = 3'b011;
    localparam PRESCALE_256   = 3'b100;
    localparam PRESCALE_1024  = 3'b101;
    localparam PRESCALE_EXT_F = 3'b110;  // External clock falling edge
    localparam PRESCALE_EXT_R = 3'b111;  // External clock rising edge

    // Registros del timer
    reg [7:0] reg_tcnt0;              // Timer/Counter Register
    reg [7:0] reg_tccr0a;             // Control Register A
    reg [7:0] reg_tccr0b;             // Control Register B
    reg [7:0] reg_ocr0a;              // Output Compare A
    reg [7:0] reg_ocr0b;              // Output Compare B
    reg [7:0] reg_timsk0;             // Interrupt Mask
    reg [7:0] reg_tifr0;              // Interrupt Flags

    // Decodificación de TCCR0A
    wire [1:0] tccr0a_com0a = reg_tccr0a[7:6];  // Compare Output Mode A
    wire [1:0] tccr0a_com0b = reg_tccr0a[5:4];  // Compare Output Mode B
    wire [1:0] tccr0a_wgm0  = reg_tccr0a[1:0];  // Waveform Generation Mode

    // Decodificación de TCCR0B
    wire tccr0b_foc0a = reg_tccr0b[7];          // Force Output Compare A
    wire tccr0b_foc0b = reg_tccr0b[6];          // Force Output Compare B
    wire tccr0b_wgm02 = reg_tccr0b[3];          // Waveform Generation Mode bit 2
    wire [2:0] tccr0b_cs0 = reg_tccr0b[2:0];    // Clock Select

    // Modo completo (3 bits)
    wire [2:0] waveform_mode = {tccr0b_wgm02, tccr0a_wgm0};

    // Decodificación de TIMSK0
    wire timsk0_ocie0b = reg_timsk0[2];         // Output Compare B Match Interrupt Enable
    wire timsk0_ocie0a = reg_timsk0[1];         // Output Compare A Match Interrupt Enable
    wire timsk0_toie0  = reg_timsk0[0];         // Timer Overflow Interrupt Enable

    // Flags de TIFR0
    wire tifr0_ocf0b = reg_tifr0[2];            // Output Compare B Match Flag
    wire tifr0_ocf0a = reg_tifr0[1];            // Output Compare A Match Flag
    wire tifr0_tov0  = reg_tifr0[0];            // Timer Overflow Flag

    // Divisor de frecuencia (prescaler)
    reg [10:0] prescaler_counter;
    reg timer_tick;
    
    // Contador principal del timer
    reg [7:0] timer_counter;
    reg timer_direction;                        // 0=up, 1=down (para Phase Correct PWM)
    
    // Señales de comparación
    reg match_a, match_b;
    reg overflow_flag;
    
    // Salidas PWM
    reg pwm_a_output, pwm_b_output;

    // Generación de tick del timer basado en prescaler
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            prescaler_counter <= 11'h000;
            timer_tick <= 1'b0;
        end else begin
            timer_tick <= 1'b0;
            
            case (tccr0b_cs0)
                PRESCALE_STOP: begin
                    prescaler_counter <= 11'h000;
                end
                
                PRESCALE_1: begin
                    timer_tick <= 1'b1;  // Cada ciclo de clock
                end
                
                PRESCALE_8: begin
                    if (prescaler_counter >= 11'd7) begin
                        prescaler_counter <= 11'h000;
                        timer_tick <= 1'b1;
                    end else begin
                        prescaler_counter <= prescaler_counter + 11'h001;
                    end
                end
                
                PRESCALE_64: begin
                    if (prescaler_counter >= 11'd63) begin
                        prescaler_counter <= 11'h000;
                        timer_tick <= 1'b1;
                    end else begin
                        prescaler_counter <= prescaler_counter + 11'h001;
                    end
                end
                
                PRESCALE_256: begin
                    if (prescaler_counter >= 11'd255) begin
                        prescaler_counter <= 11'h000;
                        timer_tick <= 1'b1;
                    end else begin
                        prescaler_counter <= prescaler_counter + 11'h001;
                    end
                end
                
                PRESCALE_1024: begin
                    if (prescaler_counter >= 11'd1023) begin
                        prescaler_counter <= 11'h000;
                        timer_tick <= 1'b1;
                    end else begin
                        prescaler_counter <= prescaler_counter + 11'h001;
                    end
                end
                
                default: begin
                    prescaler_counter <= 11'h000;
                end
            endcase
        end
    end

    // Lógica principal del timer
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_tcnt0 <= 8'h00;
            reg_tccr0a <= 8'h00;
            reg_tccr0b <= 8'h00;
            reg_ocr0a <= 8'h00;
            reg_ocr0b <= 8'h00;
            reg_timsk0 <= 8'h00;
            reg_tifr0 <= 8'h00;
            
            timer_counter <= 8'h00;
            timer_direction <= 1'b0;
            match_a <= 1'b0;
            match_b <= 1'b0;
            overflow_flag <= 1'b0;
            pwm_a_output <= 1'b0;
            pwm_b_output <= 1'b0;
            
        end else begin
            // Escritura de registros
            if (io_write) begin
                case (io_addr)
                    ADDR_TCNT0:  begin
                        reg_tcnt0 <= io_data_in;
                        timer_counter <= io_data_in;
                    end
                    ADDR_TCCR0A: reg_tccr0a <= io_data_in;
                    ADDR_TCCR0B: reg_tccr0b <= io_data_in;
                    ADDR_OCR0A:  reg_ocr0a <= io_data_in;
                    ADDR_OCR0B:  reg_ocr0b <= io_data_in;
                    ADDR_TIMSK0: reg_timsk0 <= io_data_in;
                    ADDR_TIFR0:  reg_tifr0 <= reg_tifr0 & ~io_data_in; // Clear flags por escritura de 1
                endcase
            end
            
            // Lógica del timer
            if (timer_tick) begin
                match_a <= 1'b0;
                match_b <= 1'b0;
                overflow_flag <= 1'b0;
                
                case (waveform_mode)
                    MODE_NORMAL: begin
                        timer_counter <= timer_counter + 8'h01;
                        if (timer_counter == 8'hFF) begin
                            overflow_flag <= 1'b1;
                            reg_tifr0[0] <= 1'b1;  // Set TOV0
                        end
                        
                        // Compare matches
                        if (timer_counter == reg_ocr0a) begin
                            match_a <= 1'b1;
                            reg_tifr0[1] <= 1'b1;  // Set OCF0A
                        end
                        if (timer_counter == reg_ocr0b) begin
                            match_b <= 1'b1;
                            reg_tifr0[2] <= 1'b1;  // Set OCF0B
                        end
                    end
                    
                    MODE_CTC: begin
                        if (timer_counter == reg_ocr0a) begin
                            timer_counter <= 8'h00;  // Clear on compare match
                            match_a <= 1'b1;
                            reg_tifr0[1] <= 1'b1;
                        end else begin
                            timer_counter <= timer_counter + 8'h01;
                        end
                        
                        if (timer_counter == reg_ocr0b) begin
                            match_b <= 1'b1;
                            reg_tifr0[2] <= 1'b1;
                        end
                    end
                    
                    MODE_PWM_FAST: begin
                        timer_counter <= timer_counter + 8'h01;
                        if (timer_counter == 8'hFF) begin
                            overflow_flag <= 1'b1;
                            reg_tifr0[0] <= 1'b1;
                        end
                        
                        // PWM output generation
                        if (timer_counter == reg_ocr0a) begin
                            match_a <= 1'b1;
                            reg_tifr0[1] <= 1'b1;
                            case (tccr0a_com0a)
                                2'b10: pwm_a_output <= 1'b0;  // Clear on match
                                2'b11: pwm_a_output <= 1'b1;  // Set on match
                            endcase
                        end
                        if (timer_counter == 8'h00) begin
                            case (tccr0a_com0a)
                                2'b10: pwm_a_output <= 1'b1;  // Set at BOTTOM
                                2'b11: pwm_a_output <= 1'b0;  // Clear at BOTTOM
                            endcase
                        end
                        
                        if (timer_counter == reg_ocr0b) begin
                            match_b <= 1'b1;
                            reg_tifr0[2] <= 1'b1;
                            case (tccr0a_com0b)
                                2'b10: pwm_b_output <= 1'b0;
                                2'b11: pwm_b_output <= 1'b1;
                            endcase
                        end
                        if (timer_counter == 8'h00) begin
                            case (tccr0a_com0b)
                                2'b10: pwm_b_output <= 1'b1;
                                2'b11: pwm_b_output <= 1'b0;
                            endcase
                        end
                    end
                    
                    MODE_PWM_PHASE: begin
                        // Phase Correct PWM
                        if (timer_direction == 1'b0) begin  // Counting up
                            timer_counter <= timer_counter + 8'h01;
                            if (timer_counter == 8'hFE) begin
                                timer_direction <= 1'b1;
                            end
                        end else begin  // Counting down
                            timer_counter <= timer_counter - 8'h01;
                            if (timer_counter == 8'h01) begin
                                timer_direction <= 1'b0;
                                overflow_flag <= 1'b1;
                                reg_tifr0[0] <= 1'b1;
                            end
                        end
                        
                        // PWM output logic for phase correct
                        if (timer_counter == reg_ocr0a) begin
                            match_a <= 1'b1;
                            reg_tifr0[1] <= 1'b1;
                            if (timer_direction == 1'b0) begin  // Up counting
                                case (tccr0a_com0a)
                                    2'b10: pwm_a_output <= 1'b0;
                                    2'b11: pwm_a_output <= 1'b1;
                                endcase
                            end else begin  // Down counting
                                case (tccr0a_com0a)
                                    2'b10: pwm_a_output <= 1'b1;
                                    2'b11: pwm_a_output <= 1'b0;
                                endcase
                            end
                        end
                    end
                endcase
                
                // Actualizar TCNT0 con el valor del contador
                reg_tcnt0 <= timer_counter;
            end
        end
    end

    // Lógica de lectura de registros I/O
    always @(*) begin
        io_data_out = 8'h00;
        
        if (io_read) begin
            case (io_addr)
                ADDR_TCNT0:  io_data_out = reg_tcnt0;
                ADDR_TCCR0A: io_data_out = reg_tccr0a;
                ADDR_TCCR0B: io_data_out = reg_tccr0b;
                ADDR_OCR0A:  io_data_out = reg_ocr0a;
                ADDR_OCR0B:  io_data_out = reg_ocr0b;
                ADDR_TIMSK0: io_data_out = reg_timsk0;
                ADDR_TIFR0:  io_data_out = reg_tifr0;
                default:     io_data_out = 8'h00;
            endcase
        end
    end

    // Salidas PWM
    assign oc0a_pin = pwm_a_output;
    assign oc0b_pin = pwm_b_output;

    // Interrupciones
    assign timer0_overflow = tifr0_tov0 && timsk0_toie0;
    assign timer0_compa = tifr0_ocf0a && timsk0_ocie0a;
    assign timer0_compb = tifr0_ocf0b && timsk0_ocie0b;

    // Debug
    assign debug_tcnt0 = timer_counter;
    assign debug_mode = waveform_mode;
    assign debug_prescaler = tccr0b_cs0;

endmodule

`default_nettype wire