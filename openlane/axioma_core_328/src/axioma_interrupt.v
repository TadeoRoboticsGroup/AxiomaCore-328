// AxiomaCore-328: Sistema de Interrupciones
// Archivo: axioma_interrupt.v
// Descripción: Controlador de interrupciones vectorizadas compatible AVR
//              Soporta 26 fuentes de interrupción con prioridades
`default_nettype none

module axioma_interrupt (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU
    input wire global_int_enable,      // I-flag del SREG
    output reg interrupt_request,      // Solicitud de interrupción a CPU
    output reg [5:0] interrupt_vector, // Vector de interrupción (0-63)
    input wire interrupt_ack,          // CPU acepta interrupción
    input wire return_from_interrupt,  // RETI ejecutado
    
    // Fuentes de interrupción externas
    input wire int0_pin,               // INT0 - External Interrupt 0
    input wire int1_pin,               // INT1 - External Interrupt 1
    input wire pcint0_pin,             // PCINT0 - Pin Change Interrupt 0
    input wire pcint1_pin,             // PCINT1 - Pin Change Interrupt 1
    input wire pcint2_pin,             // PCINT2 - Pin Change Interrupt 2
    
    // Fuentes de interrupción de periféricos
    input wire timer0_ovf,             // Timer0 Overflow
    input wire timer0_compa,           // Timer0 Compare Match A
    input wire timer0_compb,           // Timer0 Compare Match B
    input wire timer1_ovf,             // Timer1 Overflow
    input wire timer1_compa,           // Timer1 Compare Match A
    input wire timer1_compb,           // Timer1 Compare Match B
    input wire timer1_capt,            // Timer1 Input Capture
    input wire timer2_ovf,             // Timer2 Overflow
    input wire timer2_compa,           // Timer2 Compare Match A
    input wire timer2_compb,           // Timer2 Compare Match B
    input wire spi_ready,              // SPI Transfer Complete
    input wire usart_rx_complete,      // USART Rx Complete
    input wire usart_udre,             // USART Data Register Empty
    input wire usart_tx_complete,      // USART Tx Complete
    input wire adc_complete,           // ADC Conversion Complete
    input wire eeprom_ready,           // EEPROM Ready
    input wire analog_comp,            // Analog Comparator
    input wire twi_interrupt,          // Two-wire Interface
    input wire spm_ready,              // Store Program Memory Ready
    
    // Registros de control (memory mapped)
    input wire [7:0] eimsk_reg,        // External Interrupt Mask Register
    input wire [7:0] eifr_reg,         // External Interrupt Flag Register
    input wire [7:0] pcmsk0_reg,       // Pin Change Mask Register 0
    input wire [7:0] pcmsk1_reg,       // Pin Change Mask Register 1
    input wire [7:0] pcmsk2_reg,       // Pin Change Mask Register 2
    input wire [7:0] pcifr_reg,        // Pin Change Interrupt Flag Register
    input wire [7:0] pcicr_reg,        // Pin Change Interrupt Control Register
    input wire [7:0] timsk0_reg,       // Timer0 Interrupt Mask Register
    input wire [7:0] timsk1_reg,       // Timer1 Interrupt Mask Register
    input wire [7:0] timsk2_reg,       // Timer2 Interrupt Mask Register
    
    // Estado y debug
    output reg [25:0] pending_interrupts, // Interrupciones pendientes
    output reg [4:0] current_priority,     // Prioridad actual
    output reg interrupt_in_progress,     // Interrupción en proceso
    output reg [5:0] debug_last_vector     // Último vector procesado
);

    // Vectores de interrupción AVR (compatibles ATmega328P)
    localparam VECTOR_RESET       = 6'h00;  // Reset
    localparam VECTOR_INT0        = 6'h01;  // External Interrupt 0
    localparam VECTOR_INT1        = 6'h02;  // External Interrupt 1  
    localparam VECTOR_PCINT0      = 6'h03;  // Pin Change Interrupt 0
    localparam VECTOR_PCINT1      = 6'h04;  // Pin Change Interrupt 1
    localparam VECTOR_PCINT2      = 6'h05;  // Pin Change Interrupt 2
    localparam VECTOR_WDT         = 6'h06;  // Watchdog Timer
    localparam VECTOR_TIMER2_COMPA = 6'h07; // Timer2 Compare Match A
    localparam VECTOR_TIMER2_COMPB = 6'h08; // Timer2 Compare Match B
    localparam VECTOR_TIMER2_OVF  = 6'h09;  // Timer2 Overflow
    localparam VECTOR_TIMER1_CAPT = 6'h0A;  // Timer1 Input Capture
    localparam VECTOR_TIMER1_COMPA = 6'h0B; // Timer1 Compare Match A
    localparam VECTOR_TIMER1_COMPB = 6'h0C; // Timer1 Compare Match B
    localparam VECTOR_TIMER1_OVF  = 6'h0D;  // Timer1 Overflow
    localparam VECTOR_TIMER0_COMPA = 6'h0E; // Timer0 Compare Match A
    localparam VECTOR_TIMER0_COMPB = 6'h0F; // Timer0 Compare Match B
    localparam VECTOR_TIMER0_OVF  = 6'h10;  // Timer0 Overflow
    localparam VECTOR_SPI_STC     = 6'h11;  // SPI Transfer Complete
    localparam VECTOR_USART_RX    = 6'h12;  // USART Rx Complete
    localparam VECTOR_USART_UDRE  = 6'h13;  // USART Data Register Empty
    localparam VECTOR_USART_TX    = 6'h14;  // USART Tx Complete
    localparam VECTOR_ADC         = 6'h15;  // ADC Conversion Complete
    localparam VECTOR_EE_READY    = 6'h16;  // EEPROM Ready
    localparam VECTOR_ANALOG_COMP = 6'h17;  // Analog Comparator
    localparam VECTOR_TWI         = 6'h18;  // Two-wire Interface
    localparam VECTOR_SPM_READY   = 6'h19;  // Store Program Memory Ready
    
    // Estados del controlador de interrupciones
    localparam INT_STATE_IDLE = 2'b00;
    localparam INT_STATE_PENDING = 2'b01;
    localparam INT_STATE_ACTIVE = 2'b10;
    localparam INT_STATE_RETURN = 2'b11;
    
    reg [1:0] int_state;
    reg [1:0] next_int_state;
    
    // Registros internos
    reg [25:0] interrupt_sources;      // Fuentes de interrupción
    reg [25:0] interrupt_enables;      // Habilitaciones individuales
    reg [25:0] interrupt_flags;        // Flags de interrupción
    reg [4:0] highest_priority;        // Mayor prioridad pendiente
    reg interrupt_pending;             // Hay interrupciones pendientes
    
    // Detectores de flanco para interrupciones externas
    reg int0_prev, int1_prev;
    reg pcint0_prev, pcint1_prev, pcint2_prev;
    wire int0_edge, int1_edge;
    wire pcint0_edge, pcint1_edge, pcint2_edge;
    
    // Detección de flancos
    assign int0_edge = int0_pin ^ int0_prev;
    assign int1_edge = int1_pin ^ int1_prev;
    assign pcint0_edge = pcint0_pin ^ pcint0_prev;
    assign pcint1_edge = pcint1_pin ^ pcint1_prev;
    assign pcint2_edge = pcint2_pin ^ pcint2_prev;
    
    // Actualización de estados previos
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            int0_prev <= 1'b0;
            int1_prev <= 1'b0;
            pcint0_prev <= 1'b0;
            pcint1_prev <= 1'b0;
            pcint2_prev <= 1'b0;
        end else begin
            int0_prev <= int0_pin;
            int1_prev <= int1_pin;
            pcint0_prev <= pcint0_pin;
            pcint1_prev <= pcint1_pin;
            pcint2_prev <= pcint2_pin;
        end
    end
    
    // Recolección de fuentes de interrupción
    always @(*) begin
        interrupt_sources = 26'h0000000;
        
        // Interrupciones externas
        interrupt_sources[0] = int0_edge & eimsk_reg[0];      // INT0
        interrupt_sources[1] = int1_edge & eimsk_reg[1];      // INT1
        interrupt_sources[2] = pcint0_edge & pcicr_reg[0];    // PCINT0
        interrupt_sources[3] = pcint1_edge & pcicr_reg[1];    // PCINT1  
        interrupt_sources[4] = pcint2_edge & pcicr_reg[2];    // PCINT2
        
        // Interrupciones de timers
        interrupt_sources[5] = timer2_compa & timsk2_reg[1];  // Timer2 COMPA
        interrupt_sources[6] = timer2_compb & timsk2_reg[2];  // Timer2 COMPB
        interrupt_sources[7] = timer2_ovf & timsk2_reg[0];    // Timer2 OVF
        interrupt_sources[8] = timer1_capt & timsk1_reg[5];   // Timer1 CAPT
        interrupt_sources[9] = timer1_compa & timsk1_reg[1];  // Timer1 COMPA
        interrupt_sources[10] = timer1_compb & timsk1_reg[2]; // Timer1 COMPB
        interrupt_sources[11] = timer1_ovf & timsk1_reg[0];   // Timer1 OVF
        interrupt_sources[12] = timer0_compa & timsk0_reg[1]; // Timer0 COMPA
        interrupt_sources[13] = timer0_compb & timsk0_reg[2]; // Timer0 COMPB
        interrupt_sources[14] = timer0_ovf & timsk0_reg[0];   // Timer0 OVF
        
        // Interrupciones de periféricos
        interrupt_sources[15] = spi_ready;                    // SPI
        interrupt_sources[16] = usart_rx_complete;            // USART RX
        interrupt_sources[17] = usart_udre;                   // USART UDRE
        interrupt_sources[18] = usart_tx_complete;            // USART TX
        interrupt_sources[19] = adc_complete;                 // ADC
        interrupt_sources[20] = eeprom_ready;                 // EEPROM
        interrupt_sources[21] = analog_comp;                  // Analog Comparator
        interrupt_sources[22] = twi_interrupt;                // TWI
        interrupt_sources[23] = spm_ready;                    // SPM
    end
    
    // Máquina de estados de interrupciones
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            int_state <= INT_STATE_IDLE;
            interrupt_request <= 1'b0;
            interrupt_vector <= 6'h00;
            interrupt_in_progress <= 1'b0;
            current_priority <= 5'h1F; // Prioridad más baja
            debug_last_vector <= 6'h00;
            interrupt_flags <= 26'h0000000;
            pending_interrupts <= 26'h0000000;
        end else begin
            int_state <= next_int_state;
            
            case (int_state)
                INT_STATE_IDLE: begin
                    interrupt_request <= 1'b0;
                    interrupt_in_progress <= 1'b0;
                    
                    // Actualizar flags de interrupción
                    interrupt_flags <= interrupt_flags | interrupt_sources;
                    pending_interrupts <= interrupt_flags & {26{global_int_enable}};
                    
                    // Buscar interrupción de mayor prioridad
                    if (global_int_enable && (|pending_interrupts)) begin
                        find_highest_priority();
                    end
                end
                
                INT_STATE_PENDING: begin
                    // Enviar solicitud de interrupción a CPU
                    interrupt_request <= 1'b1;
                    interrupt_vector <= highest_priority;
                    
                    if (interrupt_ack) begin
                        // CPU acepta la interrupción
                        interrupt_flags[highest_priority] <= 1'b0; // Clear flag
                        current_priority <= highest_priority;
                        debug_last_vector <= highest_priority;
                        interrupt_in_progress <= 1'b1;
                    end
                end
                
                INT_STATE_ACTIVE: begin
                    interrupt_request <= 1'b0;
                    // Esperar RETI
                    if (return_from_interrupt) begin
                        interrupt_in_progress <= 1'b0;
                        current_priority <= 5'h1F;
                    end
                end
                
                INT_STATE_RETURN: begin
                    // Estado transitorio después de RETI
                    interrupt_in_progress <= 1'b0;
                end
            endcase
        end
    end
    
    // Lógica de siguiente estado
    always @(*) begin
        next_int_state = int_state;
        
        case (int_state)
            INT_STATE_IDLE: begin
                if (global_int_enable && (|pending_interrupts) && !interrupt_in_progress) begin
                    next_int_state = INT_STATE_PENDING;
                end
            end
            
            INT_STATE_PENDING: begin
                if (interrupt_ack) begin
                    next_int_state = INT_STATE_ACTIVE;
                end else if (!global_int_enable) begin
                    next_int_state = INT_STATE_IDLE;
                end
            end
            
            INT_STATE_ACTIVE: begin
                if (return_from_interrupt) begin
                    next_int_state = INT_STATE_RETURN;
                end
            end
            
            INT_STATE_RETURN: begin
                next_int_state = INT_STATE_IDLE;
            end
        endcase
    end
    
    // Tarea para encontrar la interrupción de mayor prioridad
    task find_highest_priority;
        integer i;
        begin
            highest_priority = 5'h1F; // Prioridad más baja por defecto
            
            // Buscar desde la prioridad más alta (0) hasta la más baja
            for (i = 0; i < 26; i = i + 1) begin
                if (pending_interrupts[i] && (i < highest_priority)) begin
                    highest_priority = i;
                end
            end
        end
    endtask

endmodule

`default_nettype wire