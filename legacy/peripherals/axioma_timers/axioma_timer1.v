// AxiomaCore-328: Timer/Counter 1 - Fase 4
// Archivo: axioma_timer1.v
// Descripción: Timer 1 de 16 bits compatible ATmega328P
//              Modos Normal, CTC, Fast PWM, Phase Correct PWM, Input Capture
`default_nettype none

module axioma_timer1 (
    input wire clk,                    // Reloj del sistema (16MHz)
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Pines de entrada/salida
    input wire icp1_pin,               // Input Capture Pin (PB0)
    output wire oc1a_pin,              // Output Compare A (PB1)
    output wire oc1b_pin,              // Output Compare B (PB2)
    
    // Interrupciones
    output wire timer1_overflow,       // Interrupción overflow
    output wire timer1_compa,          // Interrupción Compare Match A
    output wire timer1_compb,          // Interrupción Compare Match B
    output wire timer1_capt,           // Interrupción Input Capture
    
    // Debug
    output wire [15:0] debug_tcnt1,
    output wire [3:0] debug_mode,
    output wire [2:0] debug_prescaler
);

    // Direcciones I/O de registros Timer1 (ATmega328P compatible)
    localparam ADDR_TCNT1L = 6'h2C;    // 0x84 - Timer/Counter 1 Low
    localparam ADDR_TCNT1H = 6'h2D;    // 0x85 - Timer/Counter 1 High
    localparam ADDR_TCCR1A = 6'h20;    // 0x80 - Timer/Counter Control Register 1A
    localparam ADDR_TCCR1B = 6'h21;    // 0x81 - Timer/Counter Control Register 1B
    localparam ADDR_TCCR1C = 6'h22;    // 0x82 - Timer/Counter Control Register 1C
    localparam ADDR_OCR1AL = 6'h28;    // 0x88 - Output Compare Register 1A Low
    localparam ADDR_OCR1AH = 6'h29;    // 0x89 - Output Compare Register 1A High
    localparam ADDR_OCR1BL = 6'h2A;    // 0x8A - Output Compare Register 1B Low
    localparam ADDR_OCR1BH = 6'h2B;    // 0x8B - Output Compare Register 1B High
    localparam ADDR_ICR1L  = 6'h26;    // 0x86 - Input Capture Register 1 Low
    localparam ADDR_ICR1H  = 6'h27;    // 0x87 - Input Capture Register 1 High
    localparam ADDR_TIMSK1 = 6'h2F;    // 0x6F - Timer/Counter Interrupt Mask Register 1
    localparam ADDR_TIFR1  = 6'h16;    // 0x36 - Timer/Counter Interrupt Flag Register 1

    // Modos de funcionamiento Timer1 (WGM13:0)
    localparam MODE_NORMAL           = 4'b0000;  // Normal, TOP=0xFFFF
    localparam MODE_PWM_8BIT         = 4'b0001;  // PWM Phase Correct 8-bit, TOP=0x00FF
    localparam MODE_PWM_9BIT         = 4'b0010;  // PWM Phase Correct 9-bit, TOP=0x01FF
    localparam MODE_PWM_10BIT        = 4'b0011;  // PWM Phase Correct 10-bit, TOP=0x03FF
    localparam MODE_CTC_OCR1A        = 4'b0100;  // CTC, TOP=OCR1A
    localparam MODE_PWM_FAST_8BIT    = 4'b0101;  // PWM Fast 8-bit, TOP=0x00FF
    localparam MODE_PWM_FAST_9BIT    = 4'b0110;  // PWM Fast 9-bit, TOP=0x01FF
    localparam MODE_PWM_FAST_10BIT   = 4'b0111;  // PWM Fast 10-bit, TOP=0x03FF
    localparam MODE_PWM_PF_ICR1      = 4'b1000;  // PWM Phase/Freq Correct, TOP=ICR1
    localparam MODE_PWM_PF_OCR1A     = 4'b1001;  // PWM Phase/Freq Correct, TOP=OCR1A
    localparam MODE_PWM_PC_ICR1      = 4'b1010;  // PWM Phase Correct, TOP=ICR1
    localparam MODE_PWM_PC_OCR1A     = 4'b1011;  // PWM Phase Correct, TOP=OCR1A
    localparam MODE_CTC_ICR1         = 4'b1100;  // CTC, TOP=ICR1
    localparam MODE_PWM_FAST_ICR1    = 4'b1110;  // PWM Fast, TOP=ICR1
    localparam MODE_PWM_FAST_OCR1A   = 4'b1111;  // PWM Fast, TOP=OCR1A

    // Prescalers
    localparam PRESCALE_STOP    = 3'b000;
    localparam PRESCALE_1       = 3'b001;
    localparam PRESCALE_8       = 3'b010;
    localparam PRESCALE_64      = 3'b011;
    localparam PRESCALE_256     = 3'b100;
    localparam PRESCALE_1024    = 3'b101;
    localparam PRESCALE_EXT_F   = 3'b110;  // External clock falling edge
    localparam PRESCALE_EXT_R   = 3'b111;  // External clock rising edge

    // Registros del timer (16-bit)
    reg [15:0] reg_tcnt1;             // Timer/Counter Register
    reg [7:0] reg_tccr1a;             // Control Register A
    reg [7:0] reg_tccr1b;             // Control Register B
    reg [7:0] reg_tccr1c;             // Control Register C
    reg [15:0] reg_ocr1a;             // Output Compare A
    reg [15:0] reg_ocr1b;             // Output Compare B
    reg [15:0] reg_icr1;              // Input Capture Register
    reg [7:0] reg_timsk1;             // Interrupt Mask
    reg [7:0] reg_tifr1;              // Interrupt Flags

    // Decodificación de TCCR1A
    wire [1:0] tccr1a_com1a = reg_tccr1a[7:6];  // Compare Output Mode A
    wire [1:0] tccr1a_com1b = reg_tccr1a[5:4];  // Compare Output Mode B
    wire [1:0] tccr1a_wgm1  = reg_tccr1a[1:0];  // Waveform Generation Mode [1:0]

    // Decodificación de TCCR1B
    wire tccr1b_icnc1 = reg_tccr1b[7];          // Input Capture Noise Canceler
    wire tccr1b_ices1 = reg_tccr1b[6];          // Input Capture Edge Select
    wire [1:0] tccr1b_wgm1 = reg_tccr1b[4:3];   // Waveform Generation Mode [3:2]
    wire [2:0] tccr1b_cs1 = reg_tccr1b[2:0];    // Clock Select

    // Modo completo (4 bits)
    wire [3:0] waveform_mode = {tccr1b_wgm1, tccr1a_wgm1};

    // Decodificación de TCCR1C
    wire tccr1c_foc1a = reg_tccr1c[7];          // Force Output Compare A
    wire tccr1c_foc1b = reg_tccr1c[6];          // Force Output Compare B

    // Decodificación de TIMSK1
    wire timsk1_icie1  = reg_timsk1[5];         // Input Capture Interrupt Enable
    wire timsk1_ocie1b = reg_timsk1[2];         // Output Compare B Match Interrupt Enable
    wire timsk1_ocie1a = reg_timsk1[1];         // Output Compare A Match Interrupt Enable
    wire timsk1_toie1  = reg_timsk1[0];         // Timer Overflow Interrupt Enable

    // Flags de TIFR1
    wire tifr1_icf1  = reg_tifr1[5];            // Input Capture Flag
    wire tifr1_ocf1b = reg_tifr1[2];            // Output Compare B Match Flag
    wire tifr1_ocf1a = reg_tifr1[1];            // Output Compare A Match Flag
    wire tifr1_tov1  = reg_tifr1[0];            // Timer Overflow Flag

    // Divisor de frecuencia (prescaler)
    reg [10:0] prescaler_counter;
    reg timer_tick;
    
    // Contador principal del timer (16-bit)
    reg [15:0] timer_counter;
    reg timer_direction;                        // 0=up, 1=down (para Phase Correct PWM)
    
    // Señales de comparación y captura
    reg match_a, match_b;
    reg overflow_flag;
    reg capture_event;
    reg [15:0] top_value;
    
    // Input Capture
    reg icp1_sync1, icp1_sync2, icp1_sync3;   // Sincronizadores
    reg icp1_prev;
    reg capture_triggered;
    
    // Salidas PWM
    reg pwm_a_output, pwm_b_output;

    // Cálculo del valor TOP según el modo
    always @(*) begin
        case (waveform_mode)
            MODE_NORMAL:           top_value = 16'hFFFF;
            MODE_PWM_8BIT:         top_value = 16'h00FF;
            MODE_PWM_9BIT:         top_value = 16'h01FF;
            MODE_PWM_10BIT:        top_value = 16'h03FF;
            MODE_CTC_OCR1A:        top_value = reg_ocr1a;
            MODE_PWM_FAST_8BIT:    top_value = 16'h00FF;
            MODE_PWM_FAST_9BIT:    top_value = 16'h01FF;
            MODE_PWM_FAST_10BIT:   top_value = 16'h03FF;
            MODE_PWM_PF_ICR1:      top_value = reg_icr1;
            MODE_PWM_PF_OCR1A:     top_value = reg_ocr1a;
            MODE_PWM_PC_ICR1:      top_value = reg_icr1;
            MODE_PWM_PC_OCR1A:     top_value = reg_ocr1a;
            MODE_CTC_ICR1:         top_value = reg_icr1;
            MODE_PWM_FAST_ICR1:    top_value = reg_icr1;
            MODE_PWM_FAST_OCR1A:   top_value = reg_ocr1a;
            default:               top_value = 16'hFFFF;
        endcase
    end

    // Generación de tick del timer basado en prescaler
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            prescaler_counter <= 11'h000;
            timer_tick <= 1'b0;
        end else begin
            timer_tick <= 1'b0;
            
            case (tccr1b_cs1)
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

    // Input Capture sincronización y detección de flanco
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            icp1_sync1 <= 1'b0;
            icp1_sync2 <= 1'b0;
            icp1_sync3 <= 1'b0;
            icp1_prev <= 1'b0;
            capture_triggered <= 1'b0;
        end else begin
            // Cadena de sincronización para noise canceler
            if (tccr1b_icnc1) begin
                icp1_sync1 <= icp1_pin;
                icp1_sync2 <= icp1_sync1;
                icp1_sync3 <= icp1_sync2;
                
                // Detección de flanco con noise canceling
                if (tccr1b_ices1) begin
                    // Rising edge
                    capture_triggered <= (icp1_sync2 && icp1_sync3 && !icp1_prev);
                end else begin
                    // Falling edge
                    capture_triggered <= (!icp1_sync2 && !icp1_sync3 && icp1_prev);
                end
                icp1_prev <= icp1_sync2 && icp1_sync3;
            end else begin
                // Sin noise canceling
                if (tccr1b_ices1) begin
                    capture_triggered <= (icp1_pin && !icp1_prev);
                end else begin
                    capture_triggered <= (!icp1_pin && icp1_prev);
                end
                icp1_prev <= icp1_pin;
            end
        end
    end

    // Lógica principal del timer
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_tcnt1 <= 16'h0000;
            reg_tccr1a <= 8'h00;
            reg_tccr1b <= 8'h00;
            reg_tccr1c <= 8'h00;
            reg_ocr1a <= 16'h0000;
            reg_ocr1b <= 16'h0000;
            reg_icr1 <= 16'h0000;
            reg_timsk1 <= 8'h00;
            reg_tifr1 <= 8'h00;
            
            timer_counter <= 16'h0000;
            timer_direction <= 1'b0;
            match_a <= 1'b0;
            match_b <= 1'b0;
            overflow_flag <= 1'b0;
            capture_event <= 1'b0;
            pwm_a_output <= 1'b0;
            pwm_b_output <= 1'b0;
            
        end else begin
            // Escritura de registros (manejo de 16-bit)
            if (io_write) begin
                case (io_addr)
                    ADDR_TCNT1L: reg_tcnt1[7:0] <= io_data_in;
                    ADDR_TCNT1H: begin
                        reg_tcnt1[15:8] <= io_data_in;
                        timer_counter <= {io_data_in, reg_tcnt1[7:0]};
                    end
                    ADDR_TCCR1A: reg_tccr1a <= io_data_in;
                    ADDR_TCCR1B: reg_tccr1b <= io_data_in;
                    ADDR_TCCR1C: reg_tccr1c <= io_data_in;
                    ADDR_OCR1AL: reg_ocr1a[7:0] <= io_data_in;
                    ADDR_OCR1AH: reg_ocr1a[15:8] <= io_data_in;
                    ADDR_OCR1BL: reg_ocr1b[7:0] <= io_data_in;
                    ADDR_OCR1BH: reg_ocr1b[15:8] <= io_data_in;
                    ADDR_ICR1L:  reg_icr1[7:0] <= io_data_in;
                    ADDR_ICR1H:  reg_icr1[15:8] <= io_data_in;
                    ADDR_TIMSK1: reg_timsk1 <= io_data_in;
                    ADDR_TIFR1:  reg_tifr1 <= reg_tifr1 & ~io_data_in; // Clear flags por escritura de 1
                endcase
            end
            
            // Input Capture
            if (capture_triggered) begin
                reg_icr1 <= timer_counter;
                reg_tifr1[5] <= 1'b1;  // Set ICF1
                capture_event <= 1'b1;
            end else begin
                capture_event <= 1'b0;
            end
            
            // Lógica del timer
            if (timer_tick) begin
                match_a <= 1'b0;
                match_b <= 1'b0;
                overflow_flag <= 1'b0;
                
                case (waveform_mode)
                    MODE_NORMAL: begin
                        timer_counter <= timer_counter + 16'h0001;
                        if (timer_counter == 16'hFFFF) begin
                            overflow_flag <= 1'b1;
                            reg_tifr1[0] <= 1'b1;  // Set TOV1
                        end
                        
                        // Compare matches
                        if (timer_counter == reg_ocr1a) begin
                            match_a <= 1'b1;
                            reg_tifr1[1] <= 1'b1;  // Set OCF1A
                        end
                        if (timer_counter == reg_ocr1b) begin
                            match_b <= 1'b1;
                            reg_tifr1[2] <= 1'b1;  // Set OCF1B
                        end
                    end
                    
                    MODE_CTC_OCR1A, MODE_CTC_ICR1: begin
                        if (timer_counter == top_value) begin
                            timer_counter <= 16'h0000;  // Clear on compare match
                            if (waveform_mode == MODE_CTC_OCR1A) begin
                                match_a <= 1'b1;
                                reg_tifr1[1] <= 1'b1;
                            end
                        end else begin
                            timer_counter <= timer_counter + 16'h0001;
                        end
                        
                        if (timer_counter == reg_ocr1a) begin
                            match_a <= 1'b1;
                            reg_tifr1[1] <= 1'b1;
                        end
                        if (timer_counter == reg_ocr1b) begin
                            match_b <= 1'b1;
                            reg_tifr1[2] <= 1'b1;
                        end
                    end
                    
                    MODE_PWM_FAST_8BIT, MODE_PWM_FAST_9BIT, MODE_PWM_FAST_10BIT,
                    MODE_PWM_FAST_ICR1, MODE_PWM_FAST_OCR1A: begin
                        timer_counter <= timer_counter + 16'h0001;
                        if (timer_counter == top_value) begin
                            timer_counter <= 16'h0000;
                            overflow_flag <= 1'b1;
                            reg_tifr1[0] <= 1'b1;
                        end
                        
                        // PWM output generation Fast PWM
                        if (timer_counter == reg_ocr1a) begin
                            match_a <= 1'b1;
                            reg_tifr1[1] <= 1'b1;
                            case (tccr1a_com1a)
                                2'b10: pwm_a_output <= 1'b0;  // Clear on match
                                2'b11: pwm_a_output <= 1'b1;  // Set on match
                            endcase
                        end
                        if (timer_counter == 16'h0000) begin
                            case (tccr1a_com1a)
                                2'b10: pwm_a_output <= 1'b1;  // Set at BOTTOM
                                2'b11: pwm_a_output <= 1'b0;  // Clear at BOTTOM
                            endcase
                        end
                        
                        if (timer_counter == reg_ocr1b) begin
                            match_b <= 1'b1;
                            reg_tifr1[2] <= 1'b1;
                            case (tccr1a_com1b)
                                2'b10: pwm_b_output <= 1'b0;
                                2'b11: pwm_b_output <= 1'b1;
                            endcase
                        end
                        if (timer_counter == 16'h0000) begin
                            case (tccr1a_com1b)
                                2'b10: pwm_b_output <= 1'b1;
                                2'b11: pwm_b_output <= 1'b0;
                            endcase
                        end
                    end
                    
                    MODE_PWM_8BIT, MODE_PWM_9BIT, MODE_PWM_10BIT,
                    MODE_PWM_PC_ICR1, MODE_PWM_PC_OCR1A: begin
                        // Phase Correct PWM
                        if (timer_direction == 1'b0) begin  // Counting up
                            timer_counter <= timer_counter + 16'h0001;
                            if (timer_counter == top_value) begin
                                timer_direction <= 1'b1;
                            end
                        end else begin  // Counting down
                            timer_counter <= timer_counter - 16'h0001;
                            if (timer_counter == 16'h0001) begin
                                timer_direction <= 1'b0;
                                overflow_flag <= 1'b1;
                                reg_tifr1[0] <= 1'b1;
                            end
                        end
                        
                        // PWM output logic for phase correct
                        if (timer_counter == reg_ocr1a) begin
                            match_a <= 1'b1;
                            reg_tifr1[1] <= 1'b1;
                            if (timer_direction == 1'b0) begin  // Up counting
                                case (tccr1a_com1a)
                                    2'b10: pwm_a_output <= 1'b0;
                                    2'b11: pwm_a_output <= 1'b1;
                                endcase
                            end else begin  // Down counting
                                case (tccr1a_com1a)
                                    2'b10: pwm_a_output <= 1'b1;
                                    2'b11: pwm_a_output <= 1'b0;
                                endcase
                            end
                        end
                        
                        if (timer_counter == reg_ocr1b) begin
                            match_b <= 1'b1;
                            reg_tifr1[2] <= 1'b1;
                            if (timer_direction == 1'b0) begin
                                case (tccr1a_com1b)
                                    2'b10: pwm_b_output <= 1'b0;
                                    2'b11: pwm_b_output <= 1'b1;
                                endcase
                            end else begin
                                case (tccr1a_com1b)
                                    2'b10: pwm_b_output <= 1'b1;
                                    2'b11: pwm_b_output <= 1'b0;
                                endcase
                            end
                        end
                    end
                endcase
                
                // Actualizar TCNT1 con el valor del contador
                reg_tcnt1 <= timer_counter;
            end
        end
    end

    // Lógica de lectura de registros I/O
    always @(*) begin
        io_data_out = 8'h00;
        
        if (io_read) begin
            case (io_addr)
                ADDR_TCNT1L: io_data_out = reg_tcnt1[7:0];
                ADDR_TCNT1H: io_data_out = reg_tcnt1[15:8];
                ADDR_TCCR1A: io_data_out = reg_tccr1a;
                ADDR_TCCR1B: io_data_out = reg_tccr1b;
                ADDR_TCCR1C: io_data_out = reg_tccr1c;
                ADDR_OCR1AL: io_data_out = reg_ocr1a[7:0];
                ADDR_OCR1AH: io_data_out = reg_ocr1a[15:8];
                ADDR_OCR1BL: io_data_out = reg_ocr1b[7:0];
                ADDR_OCR1BH: io_data_out = reg_ocr1b[15:8];
                ADDR_ICR1L:  io_data_out = reg_icr1[7:0];
                ADDR_ICR1H:  io_data_out = reg_icr1[15:8];
                ADDR_TIMSK1: io_data_out = reg_timsk1;
                ADDR_TIFR1:  io_data_out = reg_tifr1;
                default:     io_data_out = 8'h00;
            endcase
        end
    end

    // Salidas PWM
    assign oc1a_pin = pwm_a_output;
    assign oc1b_pin = pwm_b_output;

    // Interrupciones
    assign timer1_overflow = tifr1_tov1 && timsk1_toie1;
    assign timer1_compa = tifr1_ocf1a && timsk1_ocie1a;
    assign timer1_compb = tifr1_ocf1b && timsk1_ocie1b;
    assign timer1_capt = tifr1_icf1 && timsk1_icie1;

    // Debug
    assign debug_tcnt1 = timer_counter;
    assign debug_mode = waveform_mode;
    assign debug_prescaler = tccr1b_cs1;

endmodule

`default_nettype wire