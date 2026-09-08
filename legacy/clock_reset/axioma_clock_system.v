// AxiomaCore-328: Clock and Reset System - Fase 3
// Archivo: axioma_clock_system.v
// Descripción: Sistema de clock y reset compatible ATmega328P
//              Múltiples fuentes de clock, watchdog, brown-out detection
`default_nettype none

module axioma_clock_system (
    // Clock de entrada principal
    input wire clk_ext,                // Clock externo (cristal/resonador)
    input wire clk_32khz,              // Clock 32kHz para RTC
    
    // Control de reset
    input wire reset_ext_n,            // Reset externo (pin RESET)
    input wire power_on_reset_n,       // Power-on reset
    
    // Control de clock
    input wire [3:0] clock_select,     // Selección de fuente de clock
    input wire [3:0] clock_prescaler,  // Prescaler del clock
    
    // Watchdog
    input wire wdt_enable,             // Habilitación watchdog
    input wire [3:0] wdt_prescaler,    // Prescaler del watchdog
    input wire wdt_reset_req,          // Reset solicitado por watchdog
    
    // Brown-out detection
    input wire bod_enable,             // Habilitación brown-out detection
    input wire [2:0] bod_level,        // Nivel de voltaje para BOD
    input wire vcc_voltage_ok,         // Señal de voltaje OK
    
    // Sleep mode control
    input wire sleep_enable,           // Modo sleep habilitado
    input wire [2:0] sleep_mode,       // Tipo de sleep mode
    
    // Interfaz I/O para registros de control
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Salidas de clock
    output wire clk_cpu,               // Clock para CPU
    output wire clk_io,                // Clock para periféricos I/O
    output wire clk_adc,               // Clock para ADC
    output wire clk_timer_async,       // Clock asíncrono para timers
    
    // Salidas de reset
    output wire reset_system_n,        // Reset del sistema
    output wire reset_wdt_n,           // Reset por watchdog
    output wire reset_bod_n,           // Reset por brown-out
    
    // Estado del sistema
    output wire [7:0] mcusr_reg,       // MCU Status Register
    output wire [7:0] mcucr_reg,       // MCU Control Register
    output wire system_clock_ready,    // Clock del sistema estable
    
    // Debug
    output wire [3:0] debug_clock_source,
    output wire [15:0] debug_wdt_counter
);

    // Fuentes de clock internas
    localparam CLK_SOURCE_RC_8MHZ    = 4'b0000;  // RC interno 8MHz
    localparam CLK_SOURCE_RC_128KHZ  = 4'b0001;  // RC interno 128kHz
    localparam CLK_SOURCE_EXT_XTAL   = 4'b0010;  // Cristal externo
    localparam CLK_SOURCE_EXT_CLOCK  = 4'b0011;  // Clock externo
    localparam CLK_SOURCE_RC_32KHZ   = 4'b0100;  // RC interno 32kHz

    // Sleep modes
    localparam SLEEP_IDLE         = 3'b000;
    localparam SLEEP_ADC_NOISE    = 3'b001;
    localparam SLEEP_POWER_DOWN   = 3'b010;
    localparam SLEEP_POWER_SAVE   = 3'b011;
    localparam SLEEP_STANDBY      = 3'b110;
    localparam SLEEP_EXT_STANDBY  = 3'b111;

    // Direcciones I/O para registros de control
    localparam ADDR_CLKPR  = 8'h61;   // 0x61 - Clock Prescaler Register
    localparam ADDR_OSCCAL = 8'h66;   // 0x66 - Oscillator Calibration Register

    // Registros de control ATmega328P
    reg [7:0] clkpr_reg;              // Clock Prescaler Register
    reg [7:0] osccal_reg;             // Oscillator Calibration Register
    
    // Bits de CLKPR
    wire clkpce = clkpr_reg[7];       // Clock Prescaler Change Enable
    wire [3:0] clkps = clkpr_reg[3:0]; // Clock Prescaler Select Bits
    
    // Osciladores internos
    reg clk_rc_8mhz;
    reg clk_rc_128khz;
    reg clk_rc_32khz;
    reg [7:0] rc_8mhz_counter;
    reg [15:0] rc_128khz_counter;
    reg [15:0] rc_32khz_counter;
    reg [7:0] rc_8mhz_cal_counter;    // Contador para calibración

    // Clock seleccionado
    reg clk_selected;
    reg clk_prescaled;
    reg [7:0] prescaler_counter;

    // Watchdog timer
    reg [15:0] wdt_counter;
    reg wdt_reset_flag;
    reg wdt_timeout;

    // Brown-out detection
    reg bod_reset_flag;
    reg [7:0] bod_counter;

    // Registros de estado
    reg [7:0] mcusr_internal;          // MCU Status Register
    reg [7:0] mcucr_internal;          // MCU Control Register

    // Reset interno
    reg system_reset_n;
    reg clock_stable;

    // Generación de osciladores internos con calibración
    always @(posedge clk_ext or negedge power_on_reset_n) begin
        if (!power_on_reset_n) begin
            clk_rc_8mhz <= 1'b0;
            clk_rc_128khz <= 1'b0;
            clk_rc_32khz <= 1'b0;
            rc_8mhz_counter <= 8'h00;
            rc_128khz_counter <= 16'h0000;
            rc_32khz_counter <= 16'h0000;
            rc_8mhz_cal_counter <= 8'h80; // Valor inicial centrado
        end else begin
            // RC 8MHz calibrado con OSCCAL
            if (rc_8mhz_counter >= rc_8mhz_cal_counter) begin
                rc_8mhz_counter <= 8'h00;
                clk_rc_8mhz <= ~clk_rc_8mhz;
            end else begin
                rc_8mhz_counter <= rc_8mhz_counter + 8'h01;
            end
            
            // Aplicar calibración OSCCAL al RC 8MHz
            rc_8mhz_cal_counter <= osccal_reg;
            
            // RC 128kHz
            if (rc_128khz_counter >= 16'd124) begin  // 16MHz/128kHz = 125
                rc_128khz_counter <= 16'h0000;
                clk_rc_128khz <= ~clk_rc_128khz;
            end else begin
                rc_128khz_counter <= rc_128khz_counter + 16'h0001;
            end
            
            // RC 32kHz
            if (rc_32khz_counter >= 16'd499) begin  // 16MHz/32kHz = 500
                rc_32khz_counter <= 16'h0000;
                clk_rc_32khz <= ~clk_rc_32khz;
            end else begin
                rc_32khz_counter <= rc_32khz_counter + 16'h0001;
            end
        end
    end

    // Selección de fuente de clock
    always @(*) begin
        case (clock_select)
            CLK_SOURCE_RC_8MHZ:   clk_selected = clk_rc_8mhz;
            CLK_SOURCE_RC_128KHZ: clk_selected = clk_rc_128khz;
            CLK_SOURCE_EXT_XTAL:  clk_selected = clk_ext;
            CLK_SOURCE_EXT_CLOCK: clk_selected = clk_ext;
            CLK_SOURCE_RC_32KHZ:  clk_selected = clk_rc_32khz;
            default:              clk_selected = clk_rc_8mhz;  // Default interno
        endcase
    end

    // Prescaler de clock usando CLKPR register
    always @(posedge clk_selected or negedge system_reset_n) begin
        if (!system_reset_n) begin
            prescaler_counter <= 8'h00;
            clk_prescaled <= 1'b0;
        end else begin
            if (!sleep_enable || sleep_mode == SLEEP_IDLE) begin
                case (clkps)  // Usar CLKPS de registro CLKPR
                    4'b0000: begin  // /1
                        clk_prescaled <= clk_selected;
                    end
                    4'b0001: begin  // /2
                        prescaler_counter <= prescaler_counter + 8'h01;
                        if (prescaler_counter[0]) clk_prescaled <= ~clk_prescaled;
                    end
                    4'b0010: begin  // /4
                        prescaler_counter <= prescaler_counter + 8'h01;
                        if (prescaler_counter[1:0] == 2'b11) clk_prescaled <= ~clk_prescaled;
                    end
                    4'b0011: begin  // /8
                        prescaler_counter <= prescaler_counter + 8'h01;
                        if (prescaler_counter[2:0] == 3'b111) clk_prescaled <= ~clk_prescaled;
                    end
                    4'b0100: begin  // /16
                        prescaler_counter <= prescaler_counter + 8'h01;
                        if (prescaler_counter[3:0] == 4'b1111) clk_prescaled <= ~clk_prescaled;
                    end
                    4'b0101: begin  // /32
                        prescaler_counter <= prescaler_counter + 8'h01;
                        if (prescaler_counter[4:0] == 5'b11111) clk_prescaled <= ~clk_prescaled;
                    end
                    4'b0110: begin  // /64
                        prescaler_counter <= prescaler_counter + 8'h01;
                        if (prescaler_counter[5:0] == 6'b111111) clk_prescaled <= ~clk_prescaled;
                    end
                    4'b0111: begin  // /128
                        prescaler_counter <= prescaler_counter + 8'h01;
                        if (prescaler_counter[6:0] == 7'b1111111) clk_prescaled <= ~clk_prescaled;
                    end
                    4'b1000: begin  // /256
                        prescaler_counter <= prescaler_counter + 8'h01;
                        if (prescaler_counter == 8'hFF) clk_prescaled <= ~clk_prescaled;
                    end
                    default: begin
                        clk_prescaled <= clk_selected;
                    end
                endcase
            end else begin
                // En sleep mode, detener o reducir clocks
                case (sleep_mode)
                    SLEEP_POWER_DOWN: clk_prescaled <= 1'b0;
                    SLEEP_STANDBY:    clk_prescaled <= 1'b0;
                    default:          clk_prescaled <= clk_selected;
                endcase
            end
        end
    end

    // Watchdog Timer
    always @(posedge clk_rc_128khz or negedge system_reset_n) begin
        if (!system_reset_n) begin
            wdt_counter <= 16'h0000;
            wdt_timeout <= 1'b0;
            wdt_reset_flag <= 1'b0;
        end else if (wdt_enable) begin
            if (wdt_reset_req) begin
                wdt_counter <= 16'h0000;  // Reset por software
            end else begin
                wdt_counter <= wdt_counter + 16'h0001;
                
                // Timeout basado en prescaler
                case (wdt_prescaler)
                    4'b0000: wdt_timeout <= (wdt_counter >= 16'd2048);   // ~16ms
                    4'b0001: wdt_timeout <= (wdt_counter >= 16'd4096);   // ~32ms
                    4'b0010: wdt_timeout <= (wdt_counter >= 16'd8192);   // ~64ms
                    4'b0011: wdt_timeout <= (wdt_counter >= 16'd16384);  // ~125ms
                    4'b0100: wdt_timeout <= (wdt_counter >= 16'd32768);  // ~250ms
                    4'b0101: wdt_timeout <= (wdt_counter >= 16'd65535);  // ~500ms
                    4'b0110: wdt_timeout <= (wdt_counter >= 16'd65535);  // ~1s
                    4'b0111: wdt_timeout <= (wdt_counter >= 16'd65535);  // ~2s
                    default: wdt_timeout <= 1'b0;
                endcase
                
                if (wdt_timeout) begin
                    wdt_reset_flag <= 1'b1;
                    wdt_counter <= 16'h0000;
                end
            end
        end else begin
            wdt_counter <= 16'h0000;
            wdt_timeout <= 1'b0;
        end
    end

    // Brown-out Detection
    always @(posedge clk_rc_32khz or negedge power_on_reset_n) begin
        if (!power_on_reset_n) begin
            bod_counter <= 8'h00;
            bod_reset_flag <= 1'b0;
        end else if (bod_enable) begin
            if (!vcc_voltage_ok) begin
                if (bod_counter < 8'hFF) begin
                    bod_counter <= bod_counter + 8'h01;
                end else begin
                    bod_reset_flag <= 1'b1;
                end
            end else begin
                bod_counter <= 8'h00;
                bod_reset_flag <= 1'b0;
            end
        end else begin
            bod_counter <= 8'h00;
            bod_reset_flag <= 1'b0;
        end
    end

    // Generación de reset del sistema
    always @(*) begin
        system_reset_n = reset_ext_n && 
                        power_on_reset_n && 
                        !wdt_reset_flag && 
                        !bod_reset_flag;
    end

    // MCU Status Register (MCUSR)
    always @(posedge clk_prescaled or negedge power_on_reset_n) begin
        if (!power_on_reset_n) begin
            mcusr_internal <= 8'b00000001;  // PORF = 1
            clock_stable <= 1'b0;
        end else begin
            // Clear flags when written to
            if (!reset_ext_n) mcusr_internal[0] <= 1'b1;     // PORF
            if (bod_reset_flag) mcusr_internal[1] <= 1'b1;   // BORF
            if (wdt_reset_flag) mcusr_internal[2] <= 1'b1;   // WDRF
            
            // Clock stability detection
            if (!clock_stable) begin
                clock_stable <= 1'b1;  // Simplified - assume stable after reset
            end
        end
    end

    // MCU Control Register (MCUCR) - simplified
    always @(*) begin
        mcucr_internal = 8'h00;
        mcucr_internal[6] = bod_enable;
        mcucr_internal[5:3] = sleep_mode;
        mcucr_internal[2] = sleep_enable;
    end

    // Asignación de salidas
    assign clk_cpu = clk_prescaled && system_reset_n;
    assign clk_io = clk_prescaled && system_reset_n;
    assign clk_adc = clk_rc_128khz && system_reset_n;  // ADC usa clock más lento
    assign clk_timer_async = clk_32khz;                // Timer asíncrono

    assign reset_system_n = system_reset_n;
    assign reset_wdt_n = !wdt_reset_flag;
    assign reset_bod_n = !bod_reset_flag;

    assign mcusr_reg = mcusr_internal;
    assign mcucr_reg = mcucr_internal;
    assign system_clock_ready = clock_stable;

    // I/O Register access para CLKPR y OSCCAL
    reg clkpce_timeout;
    reg [7:0] clkpce_counter;
    
    always @(posedge clk_prescaled or negedge system_reset_n) begin
        if (!system_reset_n) begin
            clkpr_reg <= 8'h00;
            osccal_reg <= 8'h80;  // Valor de calibración por defecto
            clkpce_timeout <= 1'b0;
            clkpce_counter <= 8'h00;
        end else begin
            // CLKPCE timeout (4 cycles después de escribir CLKPCE)
            if (clkpce && !clkpce_timeout) begin
                clkpce_counter <= clkpce_counter + 8'h01;
                if (clkpce_counter >= 8'd3) begin
                    clkpce_timeout <= 1'b1;
                    clkpr_reg[7] <= 1'b0;  // Clear CLKPCE
                    clkpce_counter <= 8'h00;
                end
            end else if (!clkpce) begin
                clkpce_timeout <= 1'b0;
                clkpce_counter <= 8'h00;
            end
            
            // Escribir registros I/O
            if (io_write) begin
                case (io_addr)
                    ADDR_CLKPR: begin
                        if (clkpce || io_data_in[7]) begin  // CLKPCE habilitado o escribiendo CLKPCE
                            clkpr_reg <= io_data_in;
                            if (io_data_in[7]) begin
                                clkpce_timeout <= 1'b0;
                                clkpce_counter <= 8'h00;
                            end
                        end
                    end
                    ADDR_OSCCAL: osccal_reg <= io_data_in;
                endcase
            end
        end
    end
    
    // I/O Register read
    always @(*) begin
        io_data_out = 8'h00;
        if (io_read) begin
            case (io_addr)
                ADDR_CLKPR:  io_data_out = clkpr_reg;
                ADDR_OSCCAL: io_data_out = osccal_reg;
                default:     io_data_out = 8'h00;
            endcase
        end
    end

    // Debug
    assign debug_clock_source = clock_select;
    assign debug_wdt_counter = wdt_counter;

endmodule

`default_nettype wire