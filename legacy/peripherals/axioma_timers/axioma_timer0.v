// AxiomaCore-328: Timer/Counter 0 Optimizado
// Archivo: axioma_timer0_optimized.v  
// Descripción: Timer 0 de 8 bits compatible ATmega328P usando módulos comunes
// Compatible: ATmega328P - Versión optimizada
`default_nettype none

module axioma_timer0 (
    input wire clk,                    // Reloj del sistema
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

    // Constantes locales (extraídas de axioma_constants.v para evitar includes)
    localparam TIMER_MODE_NORMAL        = 3'b000;
    localparam TIMER_MODE_PWM_PHASE     = 3'b001; 
    localparam TIMER_MODE_CTC           = 3'b010;
    localparam TIMER_MODE_PWM_FAST      = 3'b011;
    localparam TIMER_MODE_PWM_PHASE_OCR = 3'b101;
    localparam TIMER_MODE_PWM_FAST_OCR  = 3'b111;

    // Direcciones I/O (ATmega328P compatible)
    localparam ADDR_TCNT0  = 6'h26;    // 0x46 - Timer/Counter Register
    localparam ADDR_TCCR0A = 6'h24;    // 0x44 - Timer/Counter Control Register A
    localparam ADDR_TCCR0B = 6'h25;    // 0x45 - Timer/Counter Control Register B
    localparam ADDR_OCR0A  = 6'h27;    // 0x47 - Output Compare Register A
    localparam ADDR_OCR0B  = 6'h28;    // 0x48 - Output Compare Register B
    localparam ADDR_TIMSK0 = 6'h2E;    // 0x6E - Timer/Counter Interrupt Mask Register
    localparam ADDR_TIFR0  = 6'h15;    // 0x35 - Timer/Counter Interrupt Flag Register

    // Registros del timer ATmega328P compatible
    reg [7:0] reg_tcnt0;              // Timer/Counter Register
    reg [7:0] reg_tccr0a;             // Control Register A
    reg [7:0] reg_tccr0b;             // Control Register B  
    reg [7:0] reg_ocr0a;              // Output Compare A
    reg [7:0] reg_ocr0b;              // Output Compare B
    reg [7:0] reg_timsk0;             // Interrupt Mask
    reg [7:0] reg_tifr0;              // Interrupt Flags

    // Decodificación de registros de control
    wire [1:0] com0a = reg_tccr0a[7:6];        // Compare Output Mode A
    wire [1:0] com0b = reg_tccr0a[5:4];        // Compare Output Mode B
    wire [1:0] wgm0_low = reg_tccr0a[1:0];     // Waveform Generation Mode [1:0]
    wire wgm02 = reg_tccr0b[3];                // Waveform Generation Mode [2]
    wire [2:0] cs0 = reg_tccr0b[2:0];          // Clock Select

    // Modo completo de funcionamiento
    wire [2:0] waveform_mode = {wgm02, wgm0_low};

    // Flags de habilitación de interrupciones
    wire ocie0b = reg_timsk0[2];               // Output Compare B Match Interrupt Enable
    wire ocie0a = reg_timsk0[1];               // Output Compare A Match Interrupt Enable  
    wire toie0 = reg_timsk0[0];                // Timer Overflow Interrupt Enable

    // Señales internas del PWM
    wire timer_tick;
    wire [7:0] tcnt_updated;
    wire comp_a_match, comp_b_match, overflow_flag;
    wire [7:0] top_value;

    // Cálculo del valor TOP según el modo
    assign top_value = (waveform_mode == TIMER_MODE_PWM_FAST_OCR || 
                       waveform_mode == TIMER_MODE_PWM_PHASE_OCR) ? reg_ocr0a : 8'hFF;

    // =========================================================================
    // INSTANCIACIÓN DEL MÓDULO PRESCALER COMÚN
    // =========================================================================
    axioma_prescaler u_prescaler (
        .clk(clk),
        .reset_n(reset_n),
        .prescale_select(cs0),
        .timer_tick(timer_tick)
    );

    // =========================================================================
    // INSTANCIACIÓN DEL GENERADOR PWM COMÚN
    // =========================================================================
    axioma_pwm_generator #(
        .WIDTH(8)
    ) u_pwm_gen (
        .clk(clk),
        .reset_n(reset_n),
        .timer_tick(timer_tick),
        .pwm_mode(waveform_mode),
        .com_a(com0a),
        .com_b(com0b),
        .ocr_a(reg_ocr0a),
        .ocr_b(reg_ocr0b),
        .top_value(top_value),
        .tcnt(reg_tcnt0),
        .tcnt_out(tcnt_updated),
        .pwm_a(oc0a_pin),
        .pwm_b(oc0b_pin),
        .comp_a_match(comp_a_match),
        .comp_b_match(comp_b_match),
        .overflow(overflow_flag)
    );

    // =========================================================================
    // LÓGICA DE REGISTROS I/O
    // =========================================================================
    
    // Escritura de registros
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_tcnt0 <= 8'h00;
            reg_tccr0a <= 8'h00;
            reg_tccr0b <= 8'h00;
            reg_ocr0a <= 8'h00;
            reg_ocr0b <= 8'h00;
            reg_timsk0 <= 8'h00;
            reg_tifr0 <= 8'h00;
        end else begin
            // Actualizar contador desde PWM generator
            reg_tcnt0 <= tcnt_updated;
            
            // Actualizar flags automáticamente
            if (comp_a_match) reg_tifr0[1] <= 1'b1;
            if (comp_b_match) reg_tifr0[2] <= 1'b1; 
            if (overflow_flag) reg_tifr0[0] <= 1'b1;
            
            // Escritura desde CPU
            if (io_write) begin
                case (io_addr)
                    ADDR_TCNT0: reg_tcnt0 <= io_data_in;
                    ADDR_TCCR0A: reg_tccr0a <= io_data_in;
                    ADDR_TCCR0B: reg_tccr0b <= io_data_in;
                    ADDR_OCR0A: reg_ocr0a <= io_data_in;
                    ADDR_OCR0B: reg_ocr0b <= io_data_in;
                    ADDR_TIMSK0: reg_timsk0 <= io_data_in;
                    ADDR_TIFR0: begin
                        // Clear flags escribiendo 1 (ATmega328P behavior)
                        if (io_data_in[0]) reg_tifr0[0] <= 1'b0; // TOV0
                        if (io_data_in[1]) reg_tifr0[1] <= 1'b0; // OCF0A  
                        if (io_data_in[2]) reg_tifr0[2] <= 1'b0; // OCF0B
                    end
                endcase
            end
        end
    end

    // Lectura de registros
    always @(*) begin
        io_data_out = 8'h00;
        if (io_read) begin
            case (io_addr)
                ADDR_TCNT0: io_data_out = reg_tcnt0;
                ADDR_TCCR0A: io_data_out = reg_tccr0a;
                ADDR_TCCR0B: io_data_out = reg_tccr0b;
                ADDR_OCR0A: io_data_out = reg_ocr0a;
                ADDR_OCR0B: io_data_out = reg_ocr0b;
                ADDR_TIMSK0: io_data_out = reg_timsk0;
                ADDR_TIFR0: io_data_out = reg_tifr0;
                default: io_data_out = 8'h00;
            endcase
        end
    end

    // =========================================================================
    // GENERACIÓN DE INTERRUPCIONES
    // =========================================================================
    assign timer0_overflow = reg_tifr0[0] & toie0;   // TOV0 & TOIE0
    assign timer0_compa = reg_tifr0[1] & ocie0a;     // OCF0A & OCIE0A
    assign timer0_compb = reg_tifr0[2] & ocie0b;     // OCF0B & OCIE0B

    // =========================================================================
    // SEÑALES DE DEBUG
    // =========================================================================
    assign debug_tcnt0 = reg_tcnt0;
    assign debug_mode = waveform_mode;
    assign debug_prescaler = cs0;

endmodule

`default_nettype wire