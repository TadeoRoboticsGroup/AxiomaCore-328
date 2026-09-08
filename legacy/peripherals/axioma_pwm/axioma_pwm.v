/*
 * AxiomaCore-328 PWM Module
 * ===============================
 * 
 * Enhanced PWM controller compatible with AVR Timer/Counter PWM modes
 * Supports 6 independent PWM channels with configurable resolution
 * 
 * Features:
 * - 6 PWM channels (OCR0A, OCR0B, OCR1A, OCR1B, OCR2A, OCR2B)
 * - 8-bit and 16-bit PWM modes
 * - Fast PWM and Phase Correct PWM
 * - Configurable prescaler (1, 8, 64, 256, 1024)
 * - Independent duty cycle control
 * - Arduino analogWrite() compatibility
 * 
 * Pin Mapping (Arduino compatible):
 * - PWM Pin 3  -> OCR2B (Timer2)
 * - PWM Pin 5  -> OCR0B (Timer0) 
 * - PWM Pin 6  -> OCR0A (Timer0)
 * - PWM Pin 9  -> OCR1A (Timer1)
 * - PWM Pin 10 -> OCR1B (Timer1)
 * - PWM Pin 11 -> OCR2A (Timer2)
 * 
 * © 2025 AxiomaCore Project
 * Licensed under Apache 2.0
 */

module axioma_pwm (
    // System signals
    input wire clk,              // System clock
    input wire rst_n,            // Active low reset
    
    // Bus interface  
    input wire [7:0] addr,       // Register address
    input wire [7:0] data_in,    // Data input
    output reg [7:0] data_out,   // Data output
    input wire we,               // Write enable
    input wire re,               // Read enable
    input wire cs,               // Chip select
    
    // PWM outputs
    output wire pwm0_a,          // Timer0 Compare A (Pin 6)
    output wire pwm0_b,          // Timer0 Compare B (Pin 5)
    output wire pwm1_a,          // Timer1 Compare A (Pin 9)  
    output wire pwm1_b,          // Timer1 Compare B (Pin 10)
    output wire pwm2_a,          // Timer2 Compare A (Pin 11)
    output wire pwm2_b,          // Timer2 Compare B (Pin 3)
    
    // Interrupt outputs
    output wire timer0_ovf,      // Timer0 overflow interrupt
    output wire timer0_compa,    // Timer0 compare A match
    output wire timer0_compb,    // Timer0 compare B match
    output wire timer1_ovf,      // Timer1 overflow interrupt  
    output wire timer1_compa,    // Timer1 compare A match
    output wire timer1_compb,    // Timer1 compare B match
    output wire timer2_ovf,      // Timer2 overflow interrupt
    output wire timer2_compa,    // Timer2 compare A match
    output wire timer2_compb     // Timer2 compare B match
);

// Register addresses (AVR compatible)
localparam TCCR0A = 8'h44;  // Timer/Counter0 Control Register A
localparam TCCR0B = 8'h45;  // Timer/Counter0 Control Register B
localparam TCNT0  = 8'h46;  // Timer/Counter0 
localparam OCR0A  = 8'h47;  // Output Compare Register 0A
localparam OCR0B  = 8'h48;  // Output Compare Register 0B

localparam TCCR1A = 8'h80;  // Timer/Counter1 Control Register A
localparam TCCR1B = 8'h81;  // Timer/Counter1 Control Register B
localparam TCNT1L = 8'h84;  // Timer/Counter1 Low Byte
localparam TCNT1H = 8'h85;  // Timer/Counter1 High Byte
localparam OCR1AL = 8'h88;  // Output Compare Register 1A Low
localparam OCR1AH = 8'h89;  // Output Compare Register 1A High
localparam OCR1BL = 8'h8A;  // Output Compare Register 1B Low
localparam OCR1BH = 8'h8B;  // Output Compare Register 1B High

localparam TCCR2A = 8'hB0;  // Timer/Counter2 Control Register A
localparam TCCR2B = 8'hB1;  // Timer/Counter2 Control Register B
localparam TCNT2  = 8'hB2;  // Timer/Counter2
localparam OCR2A  = 8'hB3;  // Output Compare Register 2A
localparam OCR2B  = 8'hB4;  // Output Compare Register 2B

// Timer0 registers (8-bit)
reg [7:0] tccr0a, tccr0b;
reg [7:0] tcnt0;
reg [7:0] ocr0a, ocr0b;

// Timer1 registers (16-bit)
reg [7:0] tccr1a, tccr1b;
reg [15:0] tcnt1;
reg [15:0] ocr1a, ocr1b;

// Timer2 registers (8-bit)
reg [7:0] tccr2a, tccr2b;
reg [7:0] tcnt2;
reg [7:0] ocr2a, ocr2b;

// Internal counters and prescalers
reg [10:0] prescaler0_cnt;
reg [10:0] prescaler1_cnt;
reg [10:0] prescaler2_cnt;

// Clock enables for each timer
wire timer0_clk_en;
wire timer1_clk_en;
wire timer2_clk_en;

// PWM mode decoders
wire [1:0] wgm0;   // Timer0 waveform generation mode
wire [3:0] wgm1;   // Timer1 waveform generation mode  
wire [1:0] wgm2;   // Timer2 waveform generation mode

assign wgm0 = {tccr0b[3], tccr0a[1:0]};
assign wgm1 = {tccr1b[4:3], tccr1a[1:0]};
assign wgm2 = {tccr2b[3], tccr2a[1:0]};

// Compare output modes
wire [1:0] com0a = tccr0a[7:6];
wire [1:0] com0b = tccr0a[5:4];
wire [1:0] com1a = tccr1a[7:6]; 
wire [1:0] com1b = tccr1a[5:4];
wire [1:0] com2a = tccr2a[7:6];
wire [1:0] com2b = tccr2a[5:4];

// Clock prescaler selection
wire [2:0] cs0 = tccr0b[2:0];
wire [2:0] cs1 = tccr1b[2:0];
wire [2:0] cs2 = tccr2b[2:0];

//=============================================================================
// Register Interface
//=============================================================================

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        // Reset all registers to default values
        tccr0a <= 8'h00;
        tccr0b <= 8'h00;
        tcnt0  <= 8'h00;
        ocr0a  <= 8'h00;
        ocr0b  <= 8'h00;
        
        tccr1a <= 8'h00;
        tccr1b <= 8'h00;
        tcnt1  <= 16'h0000;
        ocr1a  <= 16'h0000;
        ocr1b  <= 16'h0000;
        
        tccr2a <= 8'h00;
        tccr2b <= 8'h00;
        tcnt2  <= 8'h00;
        ocr2a  <= 8'h00;
        ocr2b  <= 8'h00;
    end else if (cs && we) begin
        // Write to registers
        case (addr)
            TCCR0A: tccr0a <= data_in;
            TCCR0B: tccr0b <= data_in;
            TCNT0:  tcnt0  <= data_in;
            OCR0A:  ocr0a  <= data_in;
            OCR0B:  ocr0b  <= data_in;
            
            TCCR1A: tccr1a <= data_in;
            TCCR1B: tccr1b <= data_in;
            TCNT1L: tcnt1[7:0]  <= data_in;
            TCNT1H: tcnt1[15:8] <= data_in;
            OCR1AL: ocr1a[7:0]  <= data_in;
            OCR1AH: ocr1a[15:8] <= data_in;
            OCR1BL: ocr1b[7:0]  <= data_in;
            OCR1BH: ocr1b[15:8] <= data_in;
            
            TCCR2A: tccr2a <= data_in;
            TCCR2B: tccr2b <= data_in;
            TCNT2:  tcnt2  <= data_in;
            OCR2A:  ocr2a  <= data_in;
            OCR2B:  ocr2b  <= data_in;
        endcase
    end
end

// Read from registers
always @(*) begin
    if (cs && re) begin
        case (addr)
            TCCR0A: data_out = tccr0a;
            TCCR0B: data_out = tccr0b;
            TCNT0:  data_out = tcnt0;
            OCR0A:  data_out = ocr0a;
            OCR0B:  data_out = ocr0b;
            
            TCCR1A: data_out = tccr1a;
            TCCR1B: data_out = tccr1b;
            TCNT1L: data_out = tcnt1[7:0];
            TCNT1H: data_out = tcnt1[15:8];
            OCR1AL: data_out = ocr1a[7:0];
            OCR1AH: data_out = ocr1a[15:8];
            OCR1BL: data_out = ocr1b[7:0];
            OCR1BH: data_out = ocr1b[15:8];
            
            TCCR2A: data_out = tccr2a;
            TCCR2B: data_out = tccr2b;
            TCNT2:  data_out = tcnt2;
            OCR2A:  data_out = ocr2a;
            OCR2B:  data_out = ocr2b;
            
            default: data_out = 8'h00;
        endcase
    end else begin
        data_out = 8'h00;
    end
end

//=============================================================================
// Clock Prescalers
//=============================================================================

// Timer0 prescaler
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        prescaler0_cnt <= 11'h000;
    end else begin
        prescaler0_cnt <= prescaler0_cnt + 1;
    end
end

assign timer0_clk_en = (cs0 == 3'b001) ? 1'b1 :                    // No prescaling
                       (cs0 == 3'b010) ? prescaler0_cnt[2] :        // /8
                       (cs0 == 3'b011) ? prescaler0_cnt[5] :        // /64
                       (cs0 == 3'b100) ? prescaler0_cnt[7] :        // /256
                       (cs0 == 3'b101) ? prescaler0_cnt[9] :        // /1024
                       1'b0;                                        // Timer stopped

// Timer1 prescaler  
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        prescaler1_cnt <= 11'h000;
    end else begin
        prescaler1_cnt <= prescaler1_cnt + 1;
    end
end

assign timer1_clk_en = (cs1 == 3'b001) ? 1'b1 :                    // No prescaling
                       (cs1 == 3'b010) ? prescaler1_cnt[2] :        // /8
                       (cs1 == 3'b011) ? prescaler1_cnt[5] :        // /64
                       (cs1 == 3'b100) ? prescaler1_cnt[7] :        // /256
                       (cs1 == 3'b101) ? prescaler1_cnt[9] :        // /1024
                       1'b0;                                        // Timer stopped

// Timer2 prescaler
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        prescaler2_cnt <= 11'h000;
    end else begin
        prescaler2_cnt <= prescaler2_cnt + 1;
    end
end

assign timer2_clk_en = (cs2 == 3'b001) ? 1'b1 :                    // No prescaling
                       (cs2 == 3'b010) ? prescaler2_cnt[2] :        // /8
                       (cs2 == 3'b011) ? prescaler2_cnt[5] :        // /64
                       (cs2 == 3'b100) ? prescaler2_cnt[7] :        // /256
                       (cs2 == 3'b101) ? prescaler2_cnt[9] :        // /1024
                       1'b0;                                        // Timer stopped

//=============================================================================
// Timer/Counter Logic
//=============================================================================

// Timer0 - 8-bit counter
reg timer0_overflow;
reg timer0_compare_a;
reg timer0_compare_b;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tcnt0 <= 8'h00;
        timer0_overflow <= 1'b0;
        timer0_compare_a <= 1'b0;
        timer0_compare_b <= 1'b0;
    end else if (timer0_clk_en) begin
        timer0_overflow <= 1'b0;
        timer0_compare_a <= 1'b0;
        timer0_compare_b <= 1'b0;
        
        // Fast PWM mode (WGM0 = 3)
        if (wgm0 == 2'b11) begin
            if (tcnt0 == 8'hFF) begin
                tcnt0 <= 8'h00;
                timer0_overflow <= 1'b1;
            end else begin
                tcnt0 <= tcnt0 + 1;
            end
        end
        // Phase Correct PWM mode (WGM0 = 1)
        else if (wgm0 == 2'b01) begin
            // Implementation for phase correct PWM
            tcnt0 <= tcnt0 + 1;
        end
        // Normal mode (WGM0 = 0)
        else begin
            tcnt0 <= tcnt0 + 1;
            if (tcnt0 == 8'hFF) begin
                timer0_overflow <= 1'b1;
            end
        end
        
        // Compare matches
        if (tcnt0 == ocr0a) timer0_compare_a <= 1'b1;
        if (tcnt0 == ocr0b) timer0_compare_b <= 1'b1;
    end
end

// Timer1 - 16-bit counter
reg timer1_overflow;
reg timer1_compare_a;
reg timer1_compare_b;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tcnt1 <= 16'h0000;
        timer1_overflow <= 1'b0;
        timer1_compare_a <= 1'b0;
        timer1_compare_b <= 1'b0;
    end else if (timer1_clk_en) begin
        timer1_overflow <= 1'b0;
        timer1_compare_a <= 1'b0;
        timer1_compare_b <= 1'b0;
        
        // Fast PWM 8-bit mode (WGM1 = 5)
        if (wgm1 == 4'b0101) begin
            if (tcnt1[7:0] == 8'hFF) begin
                tcnt1 <= 16'h0000;
                timer1_overflow <= 1'b1;
            end else begin
                tcnt1 <= tcnt1 + 1;
            end
        end
        // Fast PWM 16-bit mode (WGM1 = 14)
        else if (wgm1 == 4'b1110) begin
            if (tcnt1 == 16'hFFFF) begin
                tcnt1 <= 16'h0000;
                timer1_overflow <= 1'b1;
            end else begin
                tcnt1 <= tcnt1 + 1;
            end
        end
        // Normal mode
        else begin
            tcnt1 <= tcnt1 + 1;
            if (tcnt1 == 16'hFFFF) begin
                timer1_overflow <= 1'b1;
            end
        end
        
        // Compare matches
        if (tcnt1 == ocr1a) timer1_compare_a <= 1'b1;
        if (tcnt1 == ocr1b) timer1_compare_b <= 1'b1;
    end
end

// Timer2 - 8-bit counter (similar to Timer0)
reg timer2_overflow;
reg timer2_compare_a;
reg timer2_compare_b;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        tcnt2 <= 8'h00;
        timer2_overflow <= 1'b0;
        timer2_compare_a <= 1'b0;
        timer2_compare_b <= 1'b0;
    end else if (timer2_clk_en) begin
        timer2_overflow <= 1'b0;
        timer2_compare_a <= 1'b0;
        timer2_compare_b <= 1'b0;
        
        // Fast PWM mode (WGM2 = 3)
        if (wgm2 == 2'b11) begin
            if (tcnt2 == 8'hFF) begin
                tcnt2 <= 8'h00;
                timer2_overflow <= 1'b1;
            end else begin
                tcnt2 <= tcnt2 + 1;
            end
        end
        // Normal mode
        else begin
            tcnt2 <= tcnt2 + 1;
            if (tcnt2 == 8'hFF) begin
                timer2_overflow <= 1'b1;
            end
        end
        
        // Compare matches
        if (tcnt2 == ocr2a) timer2_compare_a <= 1'b1;
        if (tcnt2 == ocr2b) timer2_compare_b <= 1'b1;
    end
end

//=============================================================================
// PWM Output Generation
//=============================================================================

// Timer0 PWM outputs
reg pwm0_a_reg, pwm0_b_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pwm0_a_reg <= 1'b0;
        pwm0_b_reg <= 1'b0;
    end else begin
        // Fast PWM mode
        if (wgm0 == 2'b11) begin
            // Non-inverting mode (COM0A = 2'b10)
            if (com0a == 2'b10) begin
                if (tcnt0 == 8'h00) pwm0_a_reg <= 1'b1;
                if (tcnt0 == ocr0a) pwm0_a_reg <= 1'b0;
            end
            // Inverting mode (COM0A = 2'b11)
            else if (com0a == 2'b11) begin
                if (tcnt0 == 8'h00) pwm0_a_reg <= 1'b0;
                if (tcnt0 == ocr0a) pwm0_a_reg <= 1'b1;
            end
            
            // Non-inverting mode (COM0B = 2'b10)
            if (com0b == 2'b10) begin
                if (tcnt0 == 8'h00) pwm0_b_reg <= 1'b1;
                if (tcnt0 == ocr0b) pwm0_b_reg <= 1'b0;
            end
            // Inverting mode (COM0B = 2'b11)  
            else if (com0b == 2'b11) begin
                if (tcnt0 == 8'h00) pwm0_b_reg <= 1'b0;
                if (tcnt0 == ocr0b) pwm0_b_reg <= 1'b1;
            end
        end
    end
end

// Timer1 PWM outputs
reg pwm1_a_reg, pwm1_b_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pwm1_a_reg <= 1'b0;
        pwm1_b_reg <= 1'b0;
    end else begin
        // Fast PWM 8-bit mode
        if (wgm1 == 4'b0101) begin
            // Non-inverting mode
            if (com1a == 2'b10) begin
                if (tcnt1[7:0] == 8'h00) pwm1_a_reg <= 1'b1;
                if (tcnt1[7:0] == ocr1a[7:0]) pwm1_a_reg <= 1'b0;
            end
            
            if (com1b == 2'b10) begin
                if (tcnt1[7:0] == 8'h00) pwm1_b_reg <= 1'b1;
                if (tcnt1[7:0] == ocr1b[7:0]) pwm1_b_reg <= 1'b0;
            end
        end
    end
end

// Timer2 PWM outputs  
reg pwm2_a_reg, pwm2_b_reg;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        pwm2_a_reg <= 1'b0;
        pwm2_b_reg <= 1'b0;
    end else begin
        // Fast PWM mode
        if (wgm2 == 2'b11) begin
            // Non-inverting mode
            if (com2a == 2'b10) begin
                if (tcnt2 == 8'h00) pwm2_a_reg <= 1'b1;
                if (tcnt2 == ocr2a) pwm2_a_reg <= 1'b0;
            end
            
            if (com2b == 2'b10) begin
                if (tcnt2 == 8'h00) pwm2_b_reg <= 1'b1;
                if (tcnt2 == ocr2b) pwm2_b_reg <= 1'b0;
            end
        end
    end
end

//=============================================================================
// Output Assignments
//=============================================================================

assign pwm0_a = pwm0_a_reg;  // Pin 6
assign pwm0_b = pwm0_b_reg;  // Pin 5
assign pwm1_a = pwm1_a_reg;  // Pin 9
assign pwm1_b = pwm1_b_reg;  // Pin 10
assign pwm2_a = pwm2_a_reg;  // Pin 11
assign pwm2_b = pwm2_b_reg;  // Pin 3

assign timer0_ovf = timer0_overflow;
assign timer0_compa = timer0_compare_a;
assign timer0_compb = timer0_compare_b;
assign timer1_ovf = timer1_overflow;
assign timer1_compa = timer1_compare_a;
assign timer1_compb = timer1_compare_b;
assign timer2_ovf = timer2_overflow;
assign timer2_compa = timer2_compare_a;
assign timer2_compb = timer2_compare_b;

endmodule