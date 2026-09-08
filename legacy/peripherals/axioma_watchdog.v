// AxiomaCore-328: Watchdog Timer
// Archivo: axioma_watchdog.v
// Descripción: Watchdog Timer compatible ATmega328P
//              Sistema de reset y interrupción por timeout
//              Prescaler configurable desde ~16ms hasta ~8s
`default_nettype none

module axioma_watchdog (
    input wire clk,                    // Reloj del sistema
    input wire clk_128khz,            // Clock 128kHz para watchdog
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Control externo
    input wire wdr_instruction,        // Instrucción WDR ejecutada
    
    // Salidas
    output wire wdt_reset,             // Reset por watchdog
    output wire wdt_interrupt,         // Interrupción por watchdog
    
    // Debug
    output wire [15:0] debug_wdt_counter,
    output wire [3:0] debug_wdt_prescaler,
    output wire debug_wdt_enabled
);

    // Direcciones I/O del Watchdog Timer (ATmega328P compatible)
    localparam ADDR_WDTCSR = 8'h60;    // 0x60 - Watchdog Timer Control Register
    
    // Registro Watchdog Timer Control Register
    reg [7:0] wdtcsr_reg;
    
    // Bits de WDTCSR
    wire wdif = wdtcsr_reg[7];         // Watchdog Timeout Interrupt Flag
    wire wdie = wdtcsr_reg[6];         // Watchdog Timeout Interrupt Enable
    wire [2:0] wdp_high = {wdtcsr_reg[5], wdtcsr_reg[2:1]}; // Watchdog Timer Prescaler bits
    wire wdce = wdtcsr_reg[4];         // Watchdog Change Enable
    wire wde = wdtcsr_reg[3];          // Watchdog System Reset Enable
    wire wdp0 = wdtcsr_reg[0];         // Watchdog Timer Prescaler bit 0
    wire [3:0] wdp = {wdp_high, wdp0}; // Watchdog Timer Prescaler completo
    
    // Estados internos
    reg [15:0] wdt_counter;            // Contador principal del watchdog
    reg [15:0] wdt_timeout_value;      // Valor de timeout según prescaler
    reg wdt_timeout_flag;              // Flag interno de timeout
    reg wdt_interrupt_flag;            // Flag de interrupción interno
    reg wdce_timeout;                  // Timeout para WDCE
    reg [3:0] wdce_counter;            // Contador para WDCE timeout
    
    // Prescaler lookup table para timeout values
    always @(*) begin
        case (wdp)
            4'b0000: wdt_timeout_value = 16'd2048;   // ~16ms  @ 128kHz
            4'b0001: wdt_timeout_value = 16'd4096;   // ~32ms  @ 128kHz  
            4'b0010: wdt_timeout_value = 16'd8192;   // ~64ms  @ 128kHz
            4'b0011: wdt_timeout_value = 16'd16384;  // ~125ms @ 128kHz
            4'b0100: wdt_timeout_value = 16'd32768;  // ~250ms @ 128kHz
            4'b0101: wdt_timeout_value = 16'd65535;  // ~500ms @ 128kHz
            4'b0110: wdt_timeout_value = 16'd65535;  // ~1s    @ 128kHz
            4'b0111: wdt_timeout_value = 16'd65535;  // ~2s    @ 128kHz
            4'b1000: wdt_timeout_value = 16'd65535;  // ~4s    @ 128kHz
            4'b1001: wdt_timeout_value = 16'd65535;  // ~8s    @ 128kHz
            default: wdt_timeout_value = 16'd65535;
        endcase
    end
    
    // Contador principal del watchdog
    always @(posedge clk_128khz or negedge reset_n) begin
        if (!reset_n) begin
            wdt_counter <= 16'd0;
            wdt_timeout_flag <= 1'b0;
            wdt_interrupt_flag <= 1'b0;
        end else begin
            // Reset del contador por instrucción WDR
            if (wdr_instruction) begin
                wdt_counter <= 16'd0;
                wdt_timeout_flag <= 1'b0;
                wdt_interrupt_flag <= 1'b0;
            end else if (wde || wdie) begin
                // Contar si watchdog está habilitado
                if (wdt_counter >= wdt_timeout_value) begin
                    wdt_timeout_flag <= 1'b1;
                    wdt_counter <= 16'd0;
                    
                    // Generar interrupción si está habilitada
                    if (wdie) begin
                        wdt_interrupt_flag <= 1'b1;
                    end
                end else begin
                    wdt_counter <= wdt_counter + 16'd1;
                end
            end else begin
                wdt_counter <= 16'd0;
                wdt_timeout_flag <= 1'b0;
            end
        end
    end
    
    // Lógica de control de WDTCSR
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            wdtcsr_reg <= 8'h00;
            wdce_timeout <= 1'b0;
            wdce_counter <= 4'h0;
        end else begin
            // WDCE timeout logic (4 cycles después de escribir WDCE)
            if (wdce && !wdce_timeout) begin
                wdce_counter <= wdce_counter + 4'h1;
                if (wdce_counter >= 4'd3) begin
                    wdce_timeout <= 1'b1;
                    wdtcsr_reg[4] <= 1'b0;  // Clear WDCE
                    wdce_counter <= 4'h0;
                end
            end else if (!wdce) begin
                wdce_timeout <= 1'b0;
                wdce_counter <= 4'h0;
            end
            
            // Actualizar flags automáticamente
            wdtcsr_reg[7] <= wdt_interrupt_flag;
            
            // Escribir registro WDTCSR
            if (io_write && io_addr == ADDR_WDTCSR) begin
                // Secuencia especial requerida para cambiar WDE y prescaler
                if (wdce || io_data_in[4]) begin  // WDCE habilitado o escribiendo WDCE
                    wdtcsr_reg <= io_data_in;
                    if (io_data_in[4]) begin  // Si escribiendo WDCE
                        wdce_timeout <= 1'b0;
                        wdce_counter <= 4'h0;
                    end
                    // Clear WDIF si se escribe 1
                    if (io_data_in[7]) begin
                        wdt_interrupt_flag <= 1'b0;
                        wdtcsr_reg[7] <= 1'b0;
                    end
                end else begin
                    // Solo permitir cambios en WDIE sin WDCE
                    wdtcsr_reg[6] <= io_data_in[6];
                    // Clear WDIF si se escribe 1
                    if (io_data_in[7]) begin
                        wdt_interrupt_flag <= 1'b0;
                        wdtcsr_reg[7] <= 1'b0;
                    end
                end
            end
        end
    end
    
    // I/O Register read
    always @(*) begin
        io_data_out = 8'h00;
        if (io_read && io_addr == ADDR_WDTCSR) begin
            io_data_out = wdtcsr_reg;
        end
    end
    
    // Salidas
    assign wdt_reset = wdt_timeout_flag && wde;
    assign wdt_interrupt = wdt_interrupt_flag && wdie;
    
    // Debug outputs
    assign debug_wdt_counter = wdt_counter;
    assign debug_wdt_prescaler = wdp;
    assign debug_wdt_enabled = wde || wdie;

endmodule

`default_nettype wire