// AxiomaCore-328: System Tick para Arduino millis() y delay()
// Archivo: axioma_system_tick.v
// Descripción: Genera tick de 1ms para funciones Arduino de tiempo
//              Compatible con millis(), delay(), micros()
// Desarrollado en el Semillero de Robótica con asistencia de IA

`default_nettype none

module axioma_system_tick (
    input wire clk,                    // Reloj del sistema (16MHz)
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Salidas de tiempo
    output wire system_tick_1ms,       // Tick cada 1ms
    output wire system_tick_1us,       // Tick cada 1us
    output reg [31:0] millis_counter,  // Contador millis (para Arduino)
    output reg [31:0] micros_counter,  // Contador micros (para Arduino)
    
    // Control
    input wire tick_enable,            // Habilitar contadores
    
    // Debug
    output wire [15:0] debug_prescaler_count,
    output wire debug_tick_active
);

    // Direcciones I/O para acceso desde Arduino
    localparam ADDR_MILLIS_L   = 6'h30;  // millis() [7:0]
    localparam ADDR_MILLIS_H   = 6'h31;  // millis() [15:8]
    localparam ADDR_MILLIS_HL  = 6'h32;  // millis() [23:16]
    localparam ADDR_MILLIS_HH  = 6'h33;  // millis() [31:24]
    localparam ADDR_MICROS_L   = 6'h34;  // micros() [7:0]
    localparam ADDR_MICROS_H   = 6'h35;  // micros() [15:8]
    localparam ADDR_MICROS_HL  = 6'h36;  // micros() [23:16]
    localparam ADDR_MICROS_HH  = 6'h37;  // micros() [31:24]
    localparam ADDR_TICK_CTRL  = 6'h38;  // Control de tick

    // Prescalers para generar ticks de tiempo
    reg [15:0] prescaler_1ms;    // Para tick de 1ms: 16000 ciclos @ 16MHz
    reg [5:0] prescaler_1us;     // Para tick de 1us: 16 ciclos @ 16MHz
    
    // Tick signals generation
    reg tick_1ms_reg;
    reg tick_1us_reg;
    
    // Registro de control
    reg [7:0] tick_control;
    wire tick_enabled = tick_control[0] | tick_enable;

    assign system_tick_1ms = tick_1ms_reg;
    assign system_tick_1us = tick_1us_reg;
    assign debug_prescaler_count = prescaler_1ms;
    assign debug_tick_active = tick_enabled;

    // Generación de tick de 1us (cada 16 ciclos @ 16MHz)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            prescaler_1us <= 6'h00;
            tick_1us_reg <= 1'b0;
        end else if (tick_enabled) begin
            tick_1us_reg <= 1'b0;
            if (prescaler_1us >= 6'd15) begin  // 16 cycles = 1us @ 16MHz
                prescaler_1us <= 6'h00;
                tick_1us_reg <= 1'b1;
            end else begin
                prescaler_1us <= prescaler_1us + 6'h01;
            end
        end
    end

    // Generación de tick de 1ms (cada 16000 ciclos @ 16MHz)
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            prescaler_1ms <= 16'h0000;
            tick_1ms_reg <= 1'b0;
        end else if (tick_enabled) begin
            tick_1ms_reg <= 1'b0;
            if (prescaler_1ms >= 16'd15999) begin  // 16000 cycles = 1ms @ 16MHz
                prescaler_1ms <= 16'h0000;
                tick_1ms_reg <= 1'b1;
            end else begin
                prescaler_1ms <= prescaler_1ms + 16'h0001;
            end
        end
    end

    // Contador millis() - incrementa cada 1ms
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            millis_counter <= 32'h00000000;
        end else if (tick_enabled && tick_1ms_reg) begin
            millis_counter <= millis_counter + 32'h00000001;
        end
    end

    // Contador micros() - incrementa cada 1us  
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            micros_counter <= 32'h00000000;
        end else if (tick_enabled && tick_1us_reg) begin
            micros_counter <= micros_counter + 32'h00000001;
        end
    end

    // Interfaz I/O para lectura desde Arduino
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            tick_control <= 8'h01;  // Habilitado por defecto
        end else if (io_write) begin
            case (io_addr)
                ADDR_TICK_CTRL: tick_control <= io_data_in;
            endcase
        end
    end

    // Lectura de registros
    always @(*) begin
        io_data_out = 8'h00;
        if (io_read) begin
            case (io_addr)
                ADDR_MILLIS_L:   io_data_out = millis_counter[7:0];
                ADDR_MILLIS_H:   io_data_out = millis_counter[15:8];  
                ADDR_MILLIS_HL:  io_data_out = millis_counter[23:16];
                ADDR_MILLIS_HH:  io_data_out = millis_counter[31:24];
                ADDR_MICROS_L:   io_data_out = micros_counter[7:0];
                ADDR_MICROS_H:   io_data_out = micros_counter[15:8];
                ADDR_MICROS_HL:  io_data_out = micros_counter[23:16];
                ADDR_MICROS_HH:  io_data_out = micros_counter[31:24];
                ADDR_TICK_CTRL:  io_data_out = tick_control;
                default:         io_data_out = 8'h00;
            endcase
        end
    end

endmodule

`default_nettype wire