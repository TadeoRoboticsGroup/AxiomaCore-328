// AxiomaCore-328: GPIO Controller - Fase 3
// Archivo: axioma_gpio.v
// Descripción: Controlador GPIO compatible AVR con puertos B, C, D
//              Configuración por registro DDR, lectura/escritura independiente
`default_nettype none

module axioma_gpio (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O (0x20-0x5F)
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Puerto B (8 bits) - I/O digital
    input wire [7:0] portb_pin,        // Pines físicos entrada
    output wire [7:0] portb_port,      // Registro PORT salida
    output wire [7:0] portb_ddr,       // Registro DDR dirección
    output wire [7:0] portb_pin_out,   // Salida de pines
    
    // Puerto C (7 bits) - I/O digital + ADC
    input wire [6:0] portc_pin,        // Pines físicos entrada PC0-PC6
    output wire [6:0] portc_port,      // Registro PORT salida
    output wire [6:0] portc_ddr,       // Registro DDR dirección  
    output wire [6:0] portc_pin_out,   // Salida de pines
    
    // Puerto D (8 bits) - I/O digital + UART + SPI
    input wire [7:0] portd_pin,        // Pines físicos entrada
    output wire [7:0] portd_port,      // Registro PORT salida
    output wire [7:0] portd_ddr,       // Registro DDR dirección
    output wire [7:0] portd_pin_out,   // Salida de pines
    
    // Debug y estado
    output wire [7:0] debug_portb_state,
    output wire [7:0] debug_portc_state,
    output wire [7:0] debug_portd_state
);

    // Direcciones I/O de registros GPIO (ATmega328P compatible)
    localparam ADDR_PORTB = 6'h25;     // 0x25 - PORTB Data Register
    localparam ADDR_DDRB  = 6'h24;     // 0x24 - PORTB Direction Register  
    localparam ADDR_PINB  = 6'h23;     // 0x23 - PORTB Input Pins
    
    localparam ADDR_PORTC = 6'h28;     // 0x28 - PORTC Data Register
    localparam ADDR_DDRC  = 6'h27;     // 0x27 - PORTC Direction Register
    localparam ADDR_PINC  = 6'h26;     // 0x26 - PORTC Input Pins
    
    localparam ADDR_PORTD = 6'h2B;     // 0x2B - PORTD Data Register
    localparam ADDR_DDRD  = 6'h2A;     // 0x2A - PORTD Direction Register
    localparam ADDR_PIND  = 6'h29;     // 0x29 - PORTD Input Pins

    // Registros internos
    reg [7:0] reg_portb;               // PORTB - Datos de salida
    reg [7:0] reg_ddrb;                // DDRB - Dirección (1=salida, 0=entrada)
    reg [7:0] reg_pinb;                // PINB - Estado de pines de entrada
    
    reg [6:0] reg_portc;               // PORTC - Datos de salida (7 bits)
    reg [6:0] reg_ddrc;                // DDRC - Dirección
    reg [6:0] reg_pinc;                // PINC - Estado de pines de entrada
    
    reg [7:0] reg_portd;               // PORTD - Datos de salida
    reg [7:0] reg_ddrd;                // DDRD - Dirección
    reg [7:0] reg_pind;                // PIND - Estado de pines de entrada

    // Lógica de lectura/escritura de registros I/O
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            // Reset: Todos los pines como entrada con pull-up deshabilitado
            reg_portb <= 8'h00;
            reg_ddrb <= 8'h00;
            reg_pinb <= 8'h00;
            
            reg_portc <= 7'h00;
            reg_ddrc <= 7'h00;
            reg_pinc <= 7'h00;
            
            reg_portd <= 8'h00;
            reg_ddrd <= 8'h00;
            reg_pind <= 8'h00;
            
        end else begin
            // Actualizar registros PIN con los valores de entrada
            reg_pinb <= portb_pin;
            reg_pinc <= portc_pin;
            reg_pind <= portd_pin;
            
            // Escritura de registros
            if (io_write) begin
                case (io_addr)
                    ADDR_PORTB: reg_portb <= io_data_in;
                    ADDR_DDRB:  reg_ddrb <= io_data_in;
                    ADDR_PINB:  reg_pinb <= reg_pinb ^ io_data_in; // Toggle por escritura
                    
                    ADDR_PORTC: reg_portc <= io_data_in[6:0];
                    ADDR_DDRC:  reg_ddrc <= io_data_in[6:0];
                    ADDR_PINC:  reg_pinc <= reg_pinc ^ io_data_in[6:0];
                    
                    ADDR_PORTD: reg_portd <= io_data_in;
                    ADDR_DDRD:  reg_ddrd <= io_data_in;
                    ADDR_PIND:  reg_pind <= reg_pind ^ io_data_in;
                endcase
            end
        end
    end

    // Lógica de lectura de registros I/O
    always @(*) begin
        io_data_out = 8'h00;
        
        if (io_read) begin
            case (io_addr)
                ADDR_PORTB: io_data_out = reg_portb;
                ADDR_DDRB:  io_data_out = reg_ddrb;
                ADDR_PINB:  io_data_out = reg_pinb;
                
                ADDR_PORTC: io_data_out = {1'b0, reg_portc};
                ADDR_DDRC:  io_data_out = {1'b0, reg_ddrc};
                ADDR_PINC:  io_data_out = {1'b0, reg_pinc};
                
                ADDR_PORTD: io_data_out = reg_portd;
                ADDR_DDRD:  io_data_out = reg_ddrd;
                ADDR_PIND:  io_data_out = reg_pind;
                
                default:    io_data_out = 8'h00;
            endcase
        end
    end

    // Lógica de salida de pines (tri-state según DDR)
    genvar i;
    
    // Puerto B
    generate
        for (i = 0; i < 8; i = i + 1) begin : portb_pins
            assign portb_pin_out[i] = reg_ddrb[i] ? reg_portb[i] : 1'bz;
        end
    endgenerate
    
    // Puerto C (solo 7 bits)
    generate
        for (i = 0; i < 7; i = i + 1) begin : portc_pins
            assign portc_pin_out[i] = reg_ddrc[i] ? reg_portc[i] : 1'bz;
        end
    endgenerate
    
    // Puerto D
    generate
        for (i = 0; i < 8; i = i + 1) begin : portd_pins
            assign portd_pin_out[i] = reg_ddrd[i] ? reg_portd[i] : 1'bz;
        end
    endgenerate

    // Asignaciones de salida
    assign portb_port = reg_portb;
    assign portb_ddr = reg_ddrb;
    
    assign portc_port = reg_portc;
    assign portc_ddr = reg_ddrc;
    
    assign portd_port = reg_portd;
    assign portd_ddr = reg_ddrd;

    // Debug
    assign debug_portb_state = {reg_ddrb[7:4], reg_portb[3:0]};
    assign debug_portc_state = {1'b0, reg_ddrc[6:4], reg_portc[3:0]};
    assign debug_portd_state = {reg_ddrd[7:4], reg_portd[3:0]};

endmodule

`default_nettype wire