// AxiomaCore-328: Controlador de Interrupciones COMPLETO - Fase 8
// Archivo: axioma_interrupt_v2.v  
// Descripción: Controlador de interrupciones completo con 26 vectores
//              Compatible 100% con ATmega328P interrupt system
//              Prioridades, máscaras, nested interrupts
`default_nettype none

module axioma_interrupt (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU
    input wire [15:0] pc_current,      // Program Counter actual
    output reg [15:0] pc_interrupt,    // Program Counter para ISR
    output reg interrupt_request,      // Solicitud de interrupción
    output reg [4:0] interrupt_vector, // Vector de interrupción (0-25)
    input wire interrupt_acknowledge, // CPU acepta la interrupción
    input wire interrupt_return,      // Retorno de interrupción (RETI)
    
    // Control de interrupciones globales
    input wire global_interrupt_enable, // I flag del SREG
    input wire interrupt_enable_write,  // Escritura al I flag
    input wire interrupt_disable_write, // Clear del I flag
    
    // Fuentes de interrupción externas
    input wire int0_pin,               // INT0 (PD2)
    input wire int1_pin,               // INT1 (PD3)
    input wire pcint0_req,             // Pin Change Interrupt 0 (PORTB)
    input wire pcint1_req,             // Pin Change Interrupt 1 (PORTC)
    input wire pcint2_req,             // Pin Change Interrupt 2 (PORTD)
    
    // Fuentes de interrupción de timers
    input wire timer2_compa,           // Timer2 Compare Match A
    input wire timer2_compb,           // Timer2 Compare Match B
    input wire timer2_ovf,             // Timer2 Overflow
    input wire timer1_capt,            // Timer1 Input Capture
    input wire timer1_compa,           // Timer1 Compare Match A
    input wire timer1_compb,           // Timer1 Compare Match B
    input wire timer1_ovf,             // Timer1 Overflow
    input wire timer0_compa,           // Timer0 Compare Match A
    input wire timer0_compb,           // Timer0 Compare Match B
    input wire timer0_ovf,             // Timer0 Overflow
    
    // Fuentes de interrupción de comunicación
    input wire spi_stc,                // SPI Serial Transfer Complete
    input wire usart_rx_complete,      // USART RX Complete
    input wire usart_udre,             // USART Data Register Empty
    input wire usart_tx_complete,      // USART TX Complete
    
    // Fuentes de interrupción analógicas
    input wire adc_complete,           // ADC Conversion Complete
    input wire analog_comp,            // Analog Comparator
    
    // Fuentes de interrupción I2C
    input wire twi_interrupt,          // Two-wire Interface
    
    // Fuentes de interrupción de memoria/sistema
    input wire spm_ready,              // Store Program Memory Ready
    input wire wdt_interrupt,          // Watchdog Timer
    input wire ee_ready,               // EEPROM Ready
    
    // Control de configuración de interrupciones
    input wire [5:0] io_addr,          // Dirección I/O para registros
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura  
    input wire io_read,                // Lectura de registro
    input wire io_write,               // Escritura de registro
    
    // Estado y debug
    output wire [7:0] debug_active_interrupts,
    output wire [4:0] debug_current_priority,
    output wire [7:0] debug_pending_mask
);

    // Vectores de interrupción ATmega328P (direcciones en Flash)
    localparam VEC_RESET     = 5'd0;   // 0x0000 - Reset
    localparam VEC_INT0      = 5'd1;   // 0x0002 - External Interrupt 0
    localparam VEC_INT1      = 5'd2;   // 0x0004 - External Interrupt 1
    localparam VEC_PCINT0    = 5'd3;   // 0x0006 - Pin Change Interrupt 0
    localparam VEC_PCINT1    = 5'd4;   // 0x0008 - Pin Change Interrupt 1
    localparam VEC_PCINT2    = 5'd5;   // 0x000A - Pin Change Interrupt 2
    localparam VEC_WDT       = 5'd6;   // 0x000C - Watchdog Timer
    localparam VEC_TIMER2_COMPA = 5'd7; // 0x000E - Timer2 Compare A
    localparam VEC_TIMER2_COMPB = 5'd8; // 0x0010 - Timer2 Compare B
    localparam VEC_TIMER2_OVF   = 5'd9; // 0x0012 - Timer2 Overflow
    localparam VEC_TIMER1_CAPT  = 5'd10; // 0x0014 - Timer1 Input Capture
    localparam VEC_TIMER1_COMPA = 5'd11; // 0x0016 - Timer1 Compare A
    localparam VEC_TIMER1_COMPB = 5'd12; // 0x0018 - Timer1 Compare B
    localparam VEC_TIMER1_OVF   = 5'd13; // 0x001A - Timer1 Overflow
    localparam VEC_TIMER0_COMPA = 5'd14; // 0x001C - Timer0 Compare A
    localparam VEC_TIMER0_COMPB = 5'd15; // 0x001E - Timer0 Compare B
    localparam VEC_TIMER0_OVF   = 5'd16; // 0x0020 - Timer0 Overflow
    localparam VEC_SPI_STC      = 5'd17; // 0x0022 - SPI Transfer Complete
    localparam VEC_USART_RX     = 5'd18; // 0x0024 - USART RX Complete
    localparam VEC_USART_UDRE   = 5'd19; // 0x0026 - USART Data Register Empty
    localparam VEC_USART_TX     = 5'd20; // 0x0028 - USART TX Complete
    localparam VEC_ADC          = 5'd21; // 0x002A - ADC Conversion Complete
    localparam VEC_EE_READY     = 5'd22; // 0x002C - EEPROM Ready
    localparam VEC_ANALOG_COMP  = 5'd23; // 0x002E - Analog Comparator
    localparam VEC_TWI          = 5'd24; // 0x0030 - Two-wire Interface
    localparam VEC_SPM_READY    = 5'd25; // 0x0032 - Store Program Memory Ready

    // Direcciones de registros de control de interrupciones
    localparam ADDR_EIMSK  = 6'h1D;    // External Interrupt Mask Register
    localparam ADDR_EIFR   = 8'h1C;    // External Interrupt Flag Register
    localparam ADDR_EICRA  = 8'h29;    // External Interrupt Control Register A
    localparam ADDR_PCMSK0 = 8'h6B;    // Pin Change Mask Register 0
    localparam ADDR_PCMSK1 = 8'h6C;    // Pin Change Mask Register 1
    localparam ADDR_PCMSK2 = 8'h6D;    // Pin Change Mask Register 2
    localparam ADDR_PCIFR  = 8'h1B;    // Pin Change Interrupt Flag Register
    localparam ADDR_PCICR  = 8'h28;    // Pin Change Interrupt Control Register
    localparam ADDR_TIMSK0 = 8'h6E;    // Timer0 Interrupt Mask Register
    localparam ADDR_TIMSK1 = 8'h6F;    // Timer1 Interrupt Mask Register
    localparam ADDR_TIMSK2 = 8'h70;    // Timer2 Interrupt Mask Register
    localparam ADDR_TIFR0  = 8'h15;    // Timer0 Interrupt Flag Register
    localparam ADDR_TIFR1  = 8'h16;    // Timer1 Interrupt Flag Register
    localparam ADDR_TIFR2  = 8'h17;    // Timer2 Interrupt Flag Register

    // Registros de control de interrupciones
    reg [7:0] reg_eimsk;              // External Interrupt Mask
    reg [7:0] reg_eifr;               // External Interrupt Flags
    reg [7:0] reg_eicra;              // External Interrupt Control A
    reg [7:0] reg_pcmsk0, reg_pcmsk1, reg_pcmsk2; // Pin Change Masks
    reg [7:0] reg_pcifr;              // Pin Change Interrupt Flags
    reg [7:0] reg_pcicr;              // Pin Change Interrupt Control
    reg [7:0] reg_timsk0, reg_timsk1, reg_timsk2; // Timer Interrupt Masks
    reg [7:0] reg_tifr0, reg_tifr1, reg_tifr2;    // Timer Interrupt Flags

    // Estado interno del controlador
    reg [25:0] interrupt_pending;     // Bits de interrupciones pendientes
    reg [25:0] interrupt_enable;      // Bits de habilitación por vector
    reg [4:0] current_priority;       // Prioridad actual (vector activo)
    reg interrupt_active;             // Hay una interrupción activa
    reg [7:0] nested_count;           // Contador de interrupciones anidadas
    
    // Stack de prioridades para interrupciones anidadas
    reg [4:0] priority_stack [0:7];   // Stack de hasta 8 niveles
    reg [2:0] stack_pointer;          // Puntero del stack de prioridades

    // Detector de flancos para interrupciones externas
    reg int0_prev, int1_prev;
    reg int0_edge, int1_edge;

    // Función para calcular la dirección del vector
    function [15:0] vector_address;
        input [4:0] vector;
        begin
            vector_address = {11'h000, vector, 1'b0}; // Vector * 2
        end
    endfunction

    // Inicialización
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            // Reset de todos los registros
            reg_eimsk <= 8'h00;
            reg_eifr <= 8'h00;
            reg_eicra <= 8'h00;
            reg_pcmsk0 <= 8'h00;
            reg_pcmsk1 <= 8'h00;
            reg_pcmsk2 <= 8'h00;
            reg_pcifr <= 8'h00;
            reg_pcicr <= 8'h00;
            reg_timsk0 <= 8'h00;
            reg_timsk1 <= 8'h00;
            reg_timsk2 <= 8'h00;
            reg_tifr0 <= 8'h00;
            reg_tifr1 <= 8'h00;
            reg_tifr2 <= 8'h00;
            
            interrupt_pending <= 26'h0000000;
            interrupt_enable <= 26'h0000000;
            current_priority <= 5'd0;
            interrupt_active <= 1'b0;
            nested_count <= 8'h00;
            stack_pointer <= 3'h0;
            
            int0_prev <= 1'b1;
            int1_prev <= 1'b1;
            int0_edge <= 1'b0;
            int1_edge <= 1'b0;
            
            interrupt_request <= 1'b0;
            interrupt_vector <= 5'h00;
            pc_interrupt <= 16'h0000;
        end else begin
            // Escritura de registros
            if (io_write) begin
                case (io_addr)
                    ADDR_EIMSK:  reg_eimsk <= io_data_in;
                    ADDR_EIFR:   reg_eifr <= reg_eifr & ~io_data_in; // Clear on write
                    ADDR_EICRA:  reg_eicra <= io_data_in;
                    ADDR_PCMSK0: reg_pcmsk0 <= io_data_in;
                    ADDR_PCMSK1: reg_pcmsk1 <= io_data_in;
                    ADDR_PCMSK2: reg_pcmsk2 <= io_data_in;
                    ADDR_PCIFR:  reg_pcifr <= reg_pcifr & ~io_data_in;
                    ADDR_PCICR:  reg_pcicr <= io_data_in;
                    ADDR_TIMSK0: reg_timsk0 <= io_data_in;
                    ADDR_TIMSK1: reg_timsk1 <= io_data_in;
                    ADDR_TIMSK2: reg_timsk2 <= io_data_in;
                    ADDR_TIFR0:  reg_tifr0 <= reg_tifr0 & ~io_data_in;
                    ADDR_TIFR1:  reg_tifr1 <= reg_tifr1 & ~io_data_in;
                    ADDR_TIFR2:  reg_tifr2 <= reg_tifr2 & ~io_data_in;
                endcase
            end
            
            // Detección de flancos para INT0/INT1
            int0_prev <= int0_pin;
            int1_prev <= int1_pin;
            
            // INT0 edge detection basado en EICRA[1:0]
            case (reg_eicra[1:0])
                2'b00: int0_edge <= int0_pin == 1'b0;                    // Low level
                2'b01: int0_edge <= int0_pin != int0_prev;               // Any edge
                2'b10: int0_edge <= !int0_pin && int0_prev;              // Falling edge
                2'b11: int0_edge <= int0_pin && !int0_prev;              // Rising edge
            endcase
            
            // INT1 edge detection basado en EICRA[3:2]
            case (reg_eicra[3:2])
                2'b00: int1_edge <= int1_pin == 1'b0;                    // Low level
                2'b01: int1_edge <= int1_pin != int1_prev;               // Any edge
                2'b10: int1_edge <= !int1_pin && int1_prev;              // Falling edge
                2'b11: int1_edge <= int1_pin && !int1_prev;              // Rising edge
            endcase
            
            // Actualizar flags de interrupción
            if (int0_edge && reg_eimsk[0]) reg_eifr[0] <= 1'b1;
            if (int1_edge && reg_eimsk[1]) reg_eifr[1] <= 1'b1;
            
            if (pcint0_req && reg_pcicr[0]) reg_pcifr[0] <= 1'b1;
            if (pcint1_req && reg_pcicr[1]) reg_pcifr[1] <= 1'b1;
            if (pcint2_req && reg_pcicr[2]) reg_pcifr[2] <= 1'b1;
            
            if (timer0_compa && reg_timsk0[1]) reg_tifr0[1] <= 1'b1;
            if (timer0_compb && reg_timsk0[2]) reg_tifr0[2] <= 1'b1;
            if (timer0_ovf && reg_timsk0[0]) reg_tifr0[0] <= 1'b1;
            
            if (timer1_capt && reg_timsk1[5]) reg_tifr1[5] <= 1'b1;
            if (timer1_compa && reg_timsk1[1]) reg_tifr1[1] <= 1'b1;
            if (timer1_compb && reg_timsk1[2]) reg_tifr1[2] <= 1'b1;
            if (timer1_ovf && reg_timsk1[0]) reg_tifr1[0] <= 1'b1;
            
            if (timer2_compa && reg_timsk2[1]) reg_tifr2[1] <= 1'b1;
            if (timer2_compb && reg_timsk2[2]) reg_tifr2[2] <= 1'b1;
            if (timer2_ovf && reg_timsk2[0]) reg_tifr2[0] <= 1'b1;
            
            // Manejar acknowledgment de interrupción
            if (interrupt_acknowledge) begin
                interrupt_request <= 1'b0;
                interrupt_active <= 1'b1;
                
                // Push current priority to stack
                if (stack_pointer < 7) begin
                    priority_stack[stack_pointer] <= current_priority;
                    stack_pointer <= stack_pointer + 1;
                end
                
                current_priority <= interrupt_vector;
                nested_count <= nested_count + 1;
                
                // Clear interrupt flag correspondiente
                case (interrupt_vector)
                    VEC_INT0: reg_eifr[0] <= 1'b0;
                    VEC_INT1: reg_eifr[1] <= 1'b0;
                    VEC_PCINT0: reg_pcifr[0] <= 1'b0;
                    VEC_PCINT1: reg_pcifr[1] <= 1'b0;
                    VEC_PCINT2: reg_pcifr[2] <= 1'b0;
                    VEC_TIMER0_COMPA: reg_tifr0[1] <= 1'b0;
                    VEC_TIMER0_COMPB: reg_tifr0[2] <= 1'b0;
                    VEC_TIMER0_OVF: reg_tifr0[0] <= 1'b0;
                    VEC_TIMER1_CAPT: reg_tifr1[5] <= 1'b0;
                    VEC_TIMER1_COMPA: reg_tifr1[1] <= 1'b0;
                    VEC_TIMER1_COMPB: reg_tifr1[2] <= 1'b0;
                    VEC_TIMER1_OVF: reg_tifr1[0] <= 1'b0;
                    VEC_TIMER2_COMPA: reg_tifr2[1] <= 1'b0;
                    VEC_TIMER2_COMPB: reg_tifr2[2] <= 1'b0;
                    VEC_TIMER2_OVF: reg_tifr2[0] <= 1'b0;
                endcase
            end
            
            // Manejar retorno de interrupción
            if (interrupt_return) begin
                interrupt_active <= 1'b0;
                
                // Pop priority from stack
                if (stack_pointer > 0) begin
                    stack_pointer <= stack_pointer - 1;
                    current_priority <= priority_stack[stack_pointer - 1];
                end else begin
                    current_priority <= 5'd0;
                end
                
                if (nested_count > 0) begin
                    nested_count <= nested_count - 1;
                end
            end
        end
    end

    // Lógica combinacional para determinar interrupciones pendientes
    always @(*) begin
        // Mapear todas las fuentes de interrupción a bits pendientes
        interrupt_pending[VEC_INT0] = reg_eifr[0] && reg_eimsk[0];
        interrupt_pending[VEC_INT1] = reg_eifr[1] && reg_eimsk[1];
        interrupt_pending[VEC_PCINT0] = reg_pcifr[0] && reg_pcicr[0];
        interrupt_pending[VEC_PCINT1] = reg_pcifr[1] && reg_pcicr[1];
        interrupt_pending[VEC_PCINT2] = reg_pcifr[2] && reg_pcicr[2];
        interrupt_pending[VEC_WDT] = wdt_interrupt;
        interrupt_pending[VEC_TIMER2_COMPA] = reg_tifr2[1] && reg_timsk2[1];
        interrupt_pending[VEC_TIMER2_COMPB] = reg_tifr2[2] && reg_timsk2[2];
        interrupt_pending[VEC_TIMER2_OVF] = reg_tifr2[0] && reg_timsk2[0];
        interrupt_pending[VEC_TIMER1_CAPT] = reg_tifr1[5] && reg_timsk1[5];
        interrupt_pending[VEC_TIMER1_COMPA] = reg_tifr1[1] && reg_timsk1[1];
        interrupt_pending[VEC_TIMER1_COMPB] = reg_tifr1[2] && reg_timsk1[2];
        interrupt_pending[VEC_TIMER1_OVF] = reg_tifr1[0] && reg_timsk1[0];
        interrupt_pending[VEC_TIMER0_COMPA] = reg_tifr0[1] && reg_timsk0[1];
        interrupt_pending[VEC_TIMER0_COMPB] = reg_tifr0[2] && reg_timsk0[2];
        interrupt_pending[VEC_TIMER0_OVF] = reg_tifr0[0] && reg_timsk0[0];
        interrupt_pending[VEC_SPI_STC] = spi_stc;
        interrupt_pending[VEC_USART_RX] = usart_rx_complete;
        interrupt_pending[VEC_USART_UDRE] = usart_udre;
        interrupt_pending[VEC_USART_TX] = usart_tx_complete;
        interrupt_pending[VEC_ADC] = adc_complete;
        interrupt_pending[VEC_EE_READY] = ee_ready;
        interrupt_pending[VEC_ANALOG_COMP] = analog_comp;
        interrupt_pending[VEC_TWI] = twi_interrupt;
        interrupt_pending[VEC_SPM_READY] = spm_ready;
    end

    // Priority encoder para encontrar la interrupción de mayor prioridad
    reg [4:0] highest_priority;
    reg has_pending_interrupt;
    
    always @(*) begin
        highest_priority = 5'd0;
        has_pending_interrupt = 1'b0;
        
        // Buscar desde la prioridad más alta (vector más bajo)
        for (integer i = 1; i <= 25; i = i + 1) begin
            if (interrupt_pending[i] && i > current_priority && !has_pending_interrupt) begin
                highest_priority = i;
                has_pending_interrupt = 1'b1;
                // Primera coincidencia es la de mayor prioridad
            end
        end
    end

    // Lógica de solicitud de interrupción
    always @(*) begin
        if (global_interrupt_enable && has_pending_interrupt && !interrupt_active) begin
            interrupt_request = 1'b1;
            interrupt_vector = highest_priority;
            pc_interrupt = vector_address(highest_priority);
        end else begin
            interrupt_request = 1'b0;
            interrupt_vector = 5'h00;
            pc_interrupt = 16'h0000;
        end
    end

    // Lectura de registros
    always @(*) begin
        io_data_out = 8'h00;
        
        if (io_read) begin
            case (io_addr)
                ADDR_EIMSK:  io_data_out = reg_eimsk;
                ADDR_EIFR:   io_data_out = reg_eifr;
                ADDR_EICRA:  io_data_out = reg_eicra;
                ADDR_PCMSK0: io_data_out = reg_pcmsk0;
                ADDR_PCMSK1: io_data_out = reg_pcmsk1;
                ADDR_PCMSK2: io_data_out = reg_pcmsk2;
                ADDR_PCIFR:  io_data_out = reg_pcifr;
                ADDR_PCICR:  io_data_out = reg_pcicr;
                ADDR_TIMSK0: io_data_out = reg_timsk0;
                ADDR_TIMSK1: io_data_out = reg_timsk1;
                ADDR_TIMSK2: io_data_out = reg_timsk2;
                ADDR_TIFR0:  io_data_out = reg_tifr0;
                ADDR_TIFR1:  io_data_out = reg_tifr1;
                ADDR_TIFR2:  io_data_out = reg_tifr2;
                default:     io_data_out = 8'h00;
            endcase
        end
    end

    // Señales de debug
    assign debug_active_interrupts = interrupt_pending[7:0];
    assign debug_current_priority = current_priority;
    assign debug_pending_mask = {3'b000, has_pending_interrupt, 
                                 interrupt_active, nested_count[2:0]};

endmodule

`default_nettype wire