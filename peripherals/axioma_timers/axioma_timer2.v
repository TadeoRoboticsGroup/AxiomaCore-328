// AxiomaCore-328: Timer2 - 8-bit Timer/Counter with PWM and Asynchronous Operation
// Archivo: axioma_timer2.v
// Descripción: Timer2 8-bit compatible ATmega328P con soporte cristal externo 32.768kHz
//              Incluye todos los modos: Normal, CTC, Fast PWM, Phase Correct PWM
//              Soporte asíncrono para Real-Time Clock (RTC) applications
`default_nettype none

module axioma_timer2 (
    input wire clk,                    // Clock del sistema
    input wire reset_n,                // Reset activo bajo
    input wire clk_32khz,             // Clock externo 32.768kHz para modo asíncrono
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Salidas PWM
    output wire oc2a,                  // Output Compare A (PWM)
    output wire oc2b,                  // Output Compare B (PWM)
    
    // Interrupciones
    output wire timer2_compa,          // Compare Match A interrupt
    output wire timer2_compb,          // Compare Match B interrupt  
    output wire timer2_ovf,            // Overflow interrupt
    
    // Debug
    output wire [7:0] debug_tcnt2,
    output wire [2:0] debug_prescaler,
    output wire debug_async_mode
);

    // Direcciones I/O de Timer2 (ATmega328P compatible)
    localparam ADDR_TCCR2A = 6'h30;   // 0xB0 - Timer/Counter Control Register A
    localparam ADDR_TCCR2B = 6'h31;   // 0xB1 - Timer/Counter Control Register B
    localparam ADDR_TCNT2  = 6'h32;   // 0xB2 - Timer/Counter Register
    localparam ADDR_OCR2A  = 6'h33;   // 0xB3 - Output Compare Register A
    localparam ADDR_OCR2B  = 6'h34;   // 0xB4 - Output Compare Register B
    localparam ADDR_ASSR   = 6'h36;   // 0xB6 - Asynchronous Status Register
    
    // Registros Timer2
    reg [7:0] tccr2a;                 // Timer Control Register A
    reg [7:0] tccr2b;                 // Timer Control Register B
    reg [7:0] tcnt2;                  // Timer Counter
    reg [7:0] ocr2a;                  // Output Compare Register A
    reg [7:0] ocr2b;                  // Output Compare Register B
    reg [7:0] assr;                   // Asynchronous Status Register
    
    // Bits de TCCR2A
    wire [1:0] com2a = tccr2a[7:6];   // Compare Output Mode A
    wire [1:0] com2b = tccr2a[5:4];   // Compare Output Mode B
    wire [1:0] wgm2_low = tccr2a[1:0]; // Waveform Generation Mode [1:0]
    
    // Bits de TCCR2B
    wire foc2a = tccr2b[7];           // Force Output Compare A
    wire foc2b = tccr2b[6];           // Force Output Compare B
    wire wgm2_high = tccr2b[3];       // Waveform Generation Mode [2]
    wire [2:0] cs2 = tccr2b[2:0];     // Clock Select
    
    // Bits de ASSR
    wire exclk = assr[6];             // Enable External Clock
    wire as2 = assr[5];               // Asynchronous Timer2
    wire tcn2ub = assr[4];            // Timer/Counter2 Update Busy
    wire ocr2aub = assr[3];           // Output Compare Register2A Update Busy
    wire ocr2bub = assr[2];           // Output Compare Register2B Update Busy
    wire tcr2aub = assr[1];           // Timer/Counter Control Register2A Update Busy
    wire tcr2bub = assr[0];           // Timer/Counter Control Register2B Update Busy
    
    // Waveform Generation Mode (combinado)
    wire [2:0] wgm2 = {wgm2_high, wgm2_low};
    
    // Modos de operación
    localparam WGM_NORMAL       = 3'b000; // Normal
    localparam WGM_PWM_PC       = 3'b001; // Phase Correct PWM
    localparam WGM_CTC          = 3'b010; // Clear Timer on Compare
    localparam WGM_FAST_PWM     = 3'b011; // Fast PWM
    localparam WGM_PWM_PC_OCRA  = 3'b101; // Phase Correct PWM, TOP=OCRA
    localparam WGM_FAST_PWM_OCRA = 3'b111; // Fast PWM, TOP=OCRA
    
    // Clock prescaler
    reg [15:0] prescaler_counter;
    reg [15:0] prescaler_max;
    reg timer_tick;
    reg timer_clock;
    
    // Selección de clock (síncrono vs asíncrono)
    always @(*) begin
        if (as2) begin
            timer_clock = clk_32khz; // Modo asíncrono - usar cristal externo
        end else begin
            timer_clock = clk;       // Modo síncrono - usar clock del sistema
        end
    end
    
    // Prescaler logic
    always @(*) begin
        case (cs2)
            3'b000: prescaler_max = 16'd0;     // Timer stopped
            3'b001: prescaler_max = 16'd1;     // clk/1
            3'b010: prescaler_max = 16'd8;     // clk/8
            3'b011: prescaler_max = 16'd32;    // clk/32
            3'b100: prescaler_max = 16'd64;    // clk/64
            3'b101: prescaler_max = 16'd128;   // clk/128
            3'b110: prescaler_max = 16'd256;   // clk/256
            3'b111: prescaler_max = 16'd1024;  // clk/1024
        endcase
    end
    
    // Prescaler counter
    always @(posedge timer_clock or negedge reset_n) begin
        if (!reset_n) begin
            prescaler_counter <= 16'd0;
            timer_tick <= 1'b0;
        end else if (cs2 == 3'b000) begin
            prescaler_counter <= 16'd0;
            timer_tick <= 1'b0;
        end else if (prescaler_counter >= (prescaler_max - 16'd1)) begin
            prescaler_counter <= 16'd0;
            timer_tick <= 1'b1;
        end else begin
            prescaler_counter <= prescaler_counter + 16'd1;
            timer_tick <= 1'b0;
        end
    end
    
    // Timer counter y compare logic
    reg compare_match_a;
    reg compare_match_b;
    reg timer_overflow;
    reg [7:0] timer_top;
    reg count_up;
    
    // Determinar TOP value
    always @(*) begin
        case (wgm2)
            WGM_NORMAL, WGM_PWM_PC, WGM_FAST_PWM: timer_top = 8'hFF;
            WGM_CTC, WGM_PWM_PC_OCRA, WGM_FAST_PWM_OCRA: timer_top = ocr2a;
            default: timer_top = 8'hFF;
        endcase
    end
    
    // Timer counting logic
    always @(posedge timer_clock or negedge reset_n) begin
        if (!reset_n) begin
            tcnt2 <= 8'h00;
            compare_match_a <= 1'b0;
            compare_match_b <= 1'b0;
            timer_overflow <= 1'b0;
            count_up <= 1'b1;
        end else if (timer_tick) begin
            compare_match_a <= 1'b0;
            compare_match_b <= 1'b0;
            timer_overflow <= 1'b0;
            
            case (wgm2)
                WGM_NORMAL: begin
                    // Normal mode - count up to 0xFF
                    if (tcnt2 == 8'hFF) begin
                        tcnt2 <= 8'h00;
                        timer_overflow <= 1'b1;
                    end else begin
                        tcnt2 <= tcnt2 + 8'h01;
                    end
                    
                    // Check compare matches
                    if (tcnt2 == ocr2a) compare_match_a <= 1'b1;
                    if (tcnt2 == ocr2b) compare_match_b <= 1'b1;
                end
                
                WGM_CTC: begin
                    // Clear Timer on Compare - count up to OCR2A
                    if (tcnt2 == ocr2a) begin
                        tcnt2 <= 8'h00;
                        compare_match_a <= 1'b1;
                    end else begin
                        tcnt2 <= tcnt2 + 8'h01;
                    end
                    
                    if (tcnt2 == ocr2b) compare_match_b <= 1'b1;
                end
                
                WGM_FAST_PWM, WGM_FAST_PWM_OCRA: begin
                    // Fast PWM - count up to TOP
                    if (tcnt2 == timer_top) begin
                        tcnt2 <= 8'h00;
                        timer_overflow <= 1'b1;
                    end else begin
                        tcnt2 <= tcnt2 + 8'h01;
                    end
                    
                    // Compare matches
                    if (tcnt2 == ocr2a && wgm2 != WGM_FAST_PWM_OCRA) compare_match_a <= 1'b1;
                    if (tcnt2 == ocr2b) compare_match_b <= 1'b1;
                end
                
                WGM_PWM_PC, WGM_PWM_PC_OCRA: begin
                    // Phase Correct PWM - count up and down
                    if (count_up) begin
                        if (tcnt2 == timer_top) begin
                            count_up <= 1'b0;
                            timer_overflow <= 1'b1;
                        end else begin
                            tcnt2 <= tcnt2 + 8'h01;
                        end
                    end else begin
                        if (tcnt2 == 8'h00) begin
                            count_up <= 1'b1;
                        end else begin
                            tcnt2 <= tcnt2 - 8'h01;
                        end
                    end
                    
                    // Compare matches
                    if (tcnt2 == ocr2a && wgm2 != WGM_PWM_PC_OCRA) compare_match_a <= 1'b1;
                    if (tcnt2 == ocr2b) compare_match_b <= 1'b1;
                end
                
                default: begin
                    tcnt2 <= tcnt2 + 8'h01;
                end
            endcase
        end
    end
    
    // PWM Output generation
    reg oc2a_reg, oc2b_reg;
    
    always @(posedge timer_clock or negedge reset_n) begin
        if (!reset_n) begin
            oc2a_reg <= 1'b0;
            oc2b_reg <= 1'b0;
        end else begin
            // Force Output Compare
            if (foc2a && (wgm2[1:0] == 2'b00)) oc2a_reg <= ~oc2a_reg;
            if (foc2b && (wgm2[1:0] == 2'b00)) oc2b_reg <= ~oc2b_reg;
            
            case (wgm2)
                WGM_NORMAL, WGM_CTC: begin
                    // Normal/CTC mode
                    if (compare_match_a) begin
                        case (com2a)
                            2'b01: oc2a_reg <= ~oc2a_reg; // Toggle
                            2'b10: oc2a_reg <= 1'b0;      // Clear
                            2'b11: oc2a_reg <= 1'b1;      // Set
                        endcase
                    end
                    if (compare_match_b) begin
                        case (com2b)
                            2'b01: oc2b_reg <= ~oc2b_reg; // Toggle
                            2'b10: oc2b_reg <= 1'b0;      // Clear
                            2'b11: oc2b_reg <= 1'b1;      // Set
                        endcase
                    end
                end
                
                WGM_FAST_PWM, WGM_FAST_PWM_OCRA: begin
                    // Fast PWM mode
                    if (compare_match_a && wgm2 != WGM_FAST_PWM_OCRA) begin
                        case (com2a)
                            2'b10: oc2a_reg <= 1'b0;      // Clear on compare, set at BOTTOM
                            2'b11: oc2a_reg <= 1'b1;      // Set on compare, clear at BOTTOM
                        endcase
                    end
                    if (compare_match_b) begin
                        case (com2b)
                            2'b10: oc2b_reg <= 1'b0;      // Clear on compare, set at BOTTOM
                            2'b11: oc2b_reg <= 1'b1;      // Set on compare, clear at BOTTOM
                        endcase
                    end
                    if (tcnt2 == 8'h00) begin
                        if (com2a == 2'b10) oc2a_reg <= 1'b1;
                        if (com2a == 2'b11) oc2a_reg <= 1'b0;
                        if (com2b == 2'b10) oc2b_reg <= 1'b1;
                        if (com2b == 2'b11) oc2b_reg <= 1'b0;
                    end
                end
                
                WGM_PWM_PC, WGM_PWM_PC_OCRA: begin
                    // Phase Correct PWM mode
                    if (compare_match_a && wgm2 != WGM_PWM_PC_OCRA) begin
                        if (count_up) begin
                            case (com2a)
                                2'b10: oc2a_reg <= 1'b0;      // Clear on up-counting
                                2'b11: oc2a_reg <= 1'b1;      // Set on up-counting
                            endcase
                        end else begin
                            case (com2a)
                                2'b10: oc2a_reg <= 1'b1;      // Set on down-counting
                                2'b11: oc2a_reg <= 1'b0;      // Clear on down-counting
                            endcase
                        end
                    end
                    if (compare_match_b) begin
                        if (count_up) begin
                            case (com2b)
                                2'b10: oc2b_reg <= 1'b0;
                                2'b11: oc2b_reg <= 1'b1;
                            endcase
                        end else begin
                            case (com2b)
                                2'b10: oc2b_reg <= 1'b1;
                                2'b11: oc2b_reg <= 1'b0;
                            endcase
                        end
                    end
                end
            endcase
        end
    end
    
    // Asynchronous status register updates
    reg [3:0] async_update_busy;
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            async_update_busy <= 4'b0000;
            assr[4:1] <= 4'b0000;
        end else if (as2) begin
            // En modo asíncrono, simular busy flags por algunos ciclos
            if (io_write && (io_addr == ADDR_TCNT2 || io_addr == ADDR_OCR2A || 
                           io_addr == ADDR_OCR2B || io_addr == ADDR_TCCR2A || 
                           io_addr == ADDR_TCCR2B)) begin
                async_update_busy <= 4'b1111;
                assr[4:1] <= 4'b1111;
            end else if (async_update_busy != 4'b0000) begin
                async_update_busy <= async_update_busy - 4'b0001;
                assr[4:1] <= async_update_busy;
            end
        end else begin
            assr[4:1] <= 4'b0000; // No busy en modo síncrono
        end
    end
    
    // I/O Register access
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tccr2a <= 8'h00;
            tccr2b <= 8'h00;
            ocr2a <= 8'h00;
            ocr2b <= 8'h00;
            assr[7:5] <= 3'b000;
            assr[0] <= 1'b0;
        end else if (io_write) begin
            case (io_addr)
                ADDR_TCCR2A: tccr2a <= io_data_in;
                ADDR_TCCR2B: tccr2b <= io_data_in;
                ADDR_TCNT2:  tcnt2 <= io_data_in;
                ADDR_OCR2A:  ocr2a <= io_data_in;
                ADDR_OCR2B:  ocr2b <= io_data_in;
                ADDR_ASSR: begin
                    assr[7:5] <= io_data_in[7:5];
                    assr[0] <= io_data_in[0];
                end
            endcase
        end
    end
    
    // I/O Register read
    always @(*) begin
        io_data_out = 8'h00;
        if (io_read) begin
            case (io_addr)
                ADDR_TCCR2A: io_data_out = tccr2a;
                ADDR_TCCR2B: io_data_out = tccr2b;
                ADDR_TCNT2:  io_data_out = tcnt2;
                ADDR_OCR2A:  io_data_out = ocr2a;
                ADDR_OCR2B:  io_data_out = ocr2b;
                ADDR_ASSR:   io_data_out = assr;
                default:     io_data_out = 8'h00;
            endcase
        end
    end
    
    // Output assignments
    assign oc2a = (com2a != 2'b00) ? oc2a_reg : 1'b0;
    assign oc2b = (com2b != 2'b00) ? oc2b_reg : 1'b0;
    
    // Interrupt flags
    assign timer2_compa = compare_match_a;
    assign timer2_compb = compare_match_b;
    assign timer2_ovf = timer_overflow;
    
    // Debug outputs
    assign debug_tcnt2 = tcnt2;
    assign debug_prescaler = cs2;
    assign debug_async_mode = as2;

endmodule

`default_nettype wire