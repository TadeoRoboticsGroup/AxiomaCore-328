// AxiomaCore-328: UART Controller - Fase 3  
// Archivo: axioma_uart.v
// Descripción: UART compatible ATmega328P con baud rate configurable
//              Registros UDR0, UCSR0A, UCSR0B, UCSR0C, UBRR0H/L
`default_nettype none

module axioma_uart (
    input wire clk,                    // Reloj del sistema (16MHz)
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Interfaz serie física
    input wire uart_rx,                // Pin RX (PD0)
    output wire uart_tx,               // Pin TX (PD1)
    
    // Interrupciones
    output wire usart_rx_complete,     // Interrupción RX completa
    output wire usart_udre,            // Interrupción registro vacío
    output wire usart_tx_complete,     // Interrupción TX completa
    
    // Debug
    output wire [7:0] debug_state,
    output wire [15:0] debug_baud_counter
);

    // Direcciones I/O de registros UART (ATmega328P compatible)
    localparam ADDR_UDR0   = 6'h06;    // 0xC6 - USART I/O Data Register
    localparam ADDR_UCSR0A = 6'h00;    // 0xC0 - USART Control and Status Register A
    localparam ADDR_UCSR0B = 6'h01;    // 0xC1 - USART Control and Status Register B  
    localparam ADDR_UCSR0C = 6'h02;    // 0xC2 - USART Control and Status Register C
    localparam ADDR_UBRR0L = 6'h04;    // 0xC4 - USART Baud Rate Register Low
    localparam ADDR_UBRR0H = 6'h05;    // 0xC5 - USART Baud Rate Register High

    // Estados de la máquina de transmisión
    localparam TX_IDLE    = 3'b000;
    localparam TX_START   = 3'b001;
    localparam TX_DATA    = 3'b010;
    localparam TX_PARITY  = 3'b011;
    localparam TX_STOP    = 3'b100;

    // Estados de la máquina de recepción
    localparam RX_IDLE    = 3'b000;
    localparam RX_START   = 3'b001;
    localparam RX_DATA    = 3'b010;
    localparam RX_PARITY  = 3'b011;
    localparam RX_STOP    = 3'b100;

    // Registros UART
    reg [7:0] reg_udr0;               // Data Register
    reg [7:0] reg_ucsr0a;             // Control/Status A
    reg [7:0] reg_ucsr0b;             // Control/Status B
    reg [7:0] reg_ucsr0c;             // Control/Status C
    reg [7:0] reg_ubrr0l;             // Baud Rate Low
    reg [7:0] reg_ubrr0h;             // Baud Rate High

    // Bits de UCSR0A
    wire ucsr0a_rxc   = reg_ucsr0a[7]; // RX Complete
    wire ucsr0a_txc   = reg_ucsr0a[6]; // TX Complete
    wire ucsr0a_udre  = reg_ucsr0a[5]; // Data Register Empty
    wire ucsr0a_fe    = reg_ucsr0a[4]; // Frame Error
    wire ucsr0a_dor   = reg_ucsr0a[3]; // Data OverRun
    wire ucsr0a_upe   = reg_ucsr0a[2]; // Parity Error
    wire ucsr0a_u2x   = reg_ucsr0a[1]; // Double Speed
    wire ucsr0a_mpcm  = reg_ucsr0a[0]; // Multi-processor Mode

    // Bits de UCSR0B
    wire ucsr0b_rxcie = reg_ucsr0b[7]; // RX Complete Interrupt Enable
    wire ucsr0b_txcie = reg_ucsr0b[6]; // TX Complete Interrupt Enable
    wire ucsr0b_udrie = reg_ucsr0b[5]; // Data Register Empty Interrupt Enable
    wire ucsr0b_rxen  = reg_ucsr0b[4]; // Receiver Enable
    wire ucsr0b_txen  = reg_ucsr0b[3]; // Transmitter Enable
    wire ucsr0b_ucsz2 = reg_ucsr0b[2]; // Character Size bit 2
    wire ucsr0b_rxb8  = reg_ucsr0b[1]; // Receive Data Bit 8
    wire ucsr0b_txb8  = reg_ucsr0b[0]; // Transmit Data Bit 8

    // Bits de UCSR0C
    wire [1:0] ucsr0c_umsel = reg_ucsr0c[7:6]; // Mode Select
    wire [1:0] ucsr0c_upm   = reg_ucsr0c[5:4]; // Parity Mode
    wire ucsr0c_usbs        = reg_ucsr0c[3];   // Stop Bit Select
    wire [1:0] ucsr0c_ucsz  = reg_ucsr0c[2:1]; // Character Size
    wire ucsr0c_ucpol       = reg_ucsr0c[0];   // Clock Polarity

    // Generador de baud rate
    wire [15:0] baud_divisor = {reg_ubrr0h, reg_ubrr0l};
    reg [15:0] baud_counter;
    reg baud_tick;

    // Máquina de transmisión
    reg [2:0] tx_state;
    reg [7:0] tx_shift_reg;
    reg [3:0] tx_bit_count;
    reg tx_active;
    reg tx_output;

    // Máquina de recepción  
    reg [2:0] rx_state;
    reg [7:0] rx_shift_reg;
    reg [3:0] rx_bit_count;
    reg [1:0] rx_sample_count;
    reg rx_data_ready;

    // Buffer de recepción (simple)
    reg [7:0] rx_buffer;
    reg rx_buffer_full;

    // Inicialización y reset
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            // Reset de registros
            reg_udr0 <= 8'h00;
            reg_ucsr0a <= 8'b00100000;  // UDRE = 1 (registro vacío)
            reg_ucsr0b <= 8'h00;
            reg_ucsr0c <= 8'b00000110;  // 8N1 por defecto
            reg_ubrr0l <= 8'h67;        // 9600 baud @ 16MHz
            reg_ubrr0h <= 8'h00;
            
            // Reset de estado
            baud_counter <= 16'h0000;
            baud_tick <= 1'b0;
            
            tx_state <= TX_IDLE;
            tx_shift_reg <= 8'h00;
            tx_bit_count <= 4'h0;
            tx_active <= 1'b0;
            tx_output <= 1'b1;         // Línea idle alta
            
            rx_state <= RX_IDLE;
            rx_shift_reg <= 8'h00;
            rx_bit_count <= 4'h0;
            rx_sample_count <= 2'h0;
            rx_data_ready <= 1'b0;
            rx_buffer <= 8'h00;
            rx_buffer_full <= 1'b0;
            
        end else begin
            // Generador de baud rate
            if (baud_counter >= baud_divisor) begin
                baud_counter <= 16'h0000;
                baud_tick <= 1'b1;
            end else begin
                baud_counter <= baud_counter + 16'h0001;
                baud_tick <= 1'b0;
            end
            
            // Escritura de registros
            if (io_write) begin
                case (io_addr)
                    ADDR_UDR0: begin
                        if (ucsr0b_txen && ucsr0a_udre) begin
                            reg_udr0 <= io_data_in;
                            reg_ucsr0a[5] <= 1'b0;  // Clear UDRE
                            tx_shift_reg <= io_data_in;
                            tx_active <= 1'b1;
                        end
                    end
                    ADDR_UCSR0A: begin
                        // Solo algunos bits son escribibles
                        reg_ucsr0a[6] <= io_data_in[6]; // TXC
                        reg_ucsr0a[1] <= io_data_in[1]; // U2X
                        reg_ucsr0a[0] <= io_data_in[0]; // MPCM
                    end
                    ADDR_UCSR0B: reg_ucsr0b <= io_data_in;
                    ADDR_UCSR0C: reg_ucsr0c <= io_data_in;
                    ADDR_UBRR0L: reg_ubrr0l <= io_data_in;
                    ADDR_UBRR0H: reg_ubrr0h <= io_data_in;
                endcase
            end
            
            // Lectura de UDR0 limpia flag RXC
            if (io_read && io_addr == ADDR_UDR0) begin
                reg_ucsr0a[7] <= 1'b0;  // Clear RXC
                if (rx_buffer_full) begin
                    rx_buffer_full <= 1'b0;
                end
            end
            
            // Máquina de transmisión
            if (baud_tick && ucsr0b_txen) begin
                case (tx_state)
                    TX_IDLE: begin
                        if (tx_active) begin
                            tx_state <= TX_START;
                            tx_output <= 1'b0;     // Start bit
                            tx_bit_count <= 4'h0;
                        end else begin
                            tx_output <= 1'b1;     // Idle alta
                        end
                    end
                    
                    TX_START: begin
                        tx_state <= TX_DATA;
                        tx_output <= tx_shift_reg[0];
                        tx_shift_reg <= {1'b0, tx_shift_reg[7:1]};
                        tx_bit_count <= 4'h1;
                    end
                    
                    TX_DATA: begin
                        if (tx_bit_count < 8) begin
                            tx_output <= tx_shift_reg[0];
                            tx_shift_reg <= {1'b0, tx_shift_reg[7:1]};
                            tx_bit_count <= tx_bit_count + 4'h1;
                        end else begin
                            tx_state <= TX_STOP;
                            tx_output <= 1'b1;     // Stop bit
                        end
                    end
                    
                    TX_STOP: begin
                        tx_state <= TX_IDLE;
                        tx_active <= 1'b0;
                        reg_ucsr0a[5] <= 1'b1;  // Set UDRE
                        reg_ucsr0a[6] <= 1'b1;  // Set TXC
                        tx_output <= 1'b1;     // Mantener alta
                    end
                endcase
            end
            
            // Máquina de recepción
            if (baud_tick && ucsr0b_rxen) begin
                case (rx_state)
                    RX_IDLE: begin
                        if (!uart_rx) begin     // Start bit detectado
                            rx_state <= RX_START;
                            rx_sample_count <= 2'h0;
                        end
                    end
                    
                    RX_START: begin
                        if (rx_sample_count == 2'h1) begin  // Muestrear en el medio
                            if (!uart_rx) begin            // Confirmar start bit
                                rx_state <= RX_DATA;
                                rx_bit_count <= 4'h0;
                                rx_shift_reg <= 8'h00;
                            end else begin
                                rx_state <= RX_IDLE;       // Falso start bit
                            end
                            rx_sample_count <= 2'h0;
                        end else begin
                            rx_sample_count <= rx_sample_count + 2'h1;
                        end
                    end
                    
                    RX_DATA: begin
                        if (rx_sample_count == 2'h1) begin  // Muestrear en el medio
                            rx_shift_reg <= {uart_rx, rx_shift_reg[7:1]};
                            rx_bit_count <= rx_bit_count + 4'h1;
                            
                            if (rx_bit_count == 4'h7) begin
                                rx_state <= RX_STOP;
                            end
                            rx_sample_count <= 2'h0;
                        end else begin
                            rx_sample_count <= rx_sample_count + 2'h1;
                        end
                    end
                    
                    RX_STOP: begin
                        if (rx_sample_count == 2'h1) begin  // Muestrear stop bit
                            if (uart_rx) begin             // Stop bit válido
                                rx_buffer <= rx_shift_reg;
                                rx_buffer_full <= 1'b1;
                                reg_ucsr0a[7] <= 1'b1;      // Set RXC
                                reg_udr0 <= rx_shift_reg;
                            end else begin
                                reg_ucsr0a[4] <= 1'b1;      // Set FE (Frame Error)
                            end
                            rx_state <= RX_IDLE;
                            rx_sample_count <= 2'h0;
                        end else begin
                            rx_sample_count <= rx_sample_count + 2'h1;
                        end
                    end
                endcase
            end
        end
    end

    // Lógica de lectura de registros I/O
    always @(*) begin
        io_data_out = 8'h00;
        
        if (io_read) begin
            case (io_addr)
                ADDR_UDR0:   io_data_out = reg_udr0;
                ADDR_UCSR0A: io_data_out = reg_ucsr0a;
                ADDR_UCSR0B: io_data_out = reg_ucsr0b;
                ADDR_UCSR0C: io_data_out = reg_ucsr0c;
                ADDR_UBRR0L: io_data_out = reg_ubrr0l;
                ADDR_UBRR0H: io_data_out = reg_ubrr0h;
                default:     io_data_out = 8'h00;
            endcase
        end
    end

    // Salidas
    assign uart_tx = tx_output;
    
    // Interrupciones
    assign usart_rx_complete = ucsr0a_rxc && ucsr0b_rxcie;
    assign usart_udre = ucsr0a_udre && ucsr0b_udrie;
    assign usart_tx_complete = ucsr0a_txc && ucsr0b_txcie;

    // Debug
    assign debug_state = {tx_state, rx_state, tx_active, rx_buffer_full};
    assign debug_baud_counter = baud_counter;

endmodule

`default_nettype wire