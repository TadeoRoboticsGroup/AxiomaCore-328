// AxiomaCore-328: Prescaler Común para Timers
// Archivo: axioma_prescaler.v
// Descripción: Módulo reutilizable para lógica de prescaler en todos los timers
// Compatible: ATmega328P
`default_nettype none

module axioma_prescaler (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    input wire [2:0] prescale_select,  // Selección de prescaler
    output reg timer_tick              // Tick de salida del timer
);

    // Prescaler definitions (compatible ATmega328P)
    localparam PRESCALE_STOP = 3'b000;  // Timer stopped
    localparam PRESCALE_1    = 3'b001;  // No prescaling
    localparam PRESCALE_8    = 3'b010;  // clk/8
    localparam PRESCALE_64   = 3'b011;  // clk/64
    localparam PRESCALE_256  = 3'b100;  // clk/256
    localparam PRESCALE_1024 = 3'b101;  // clk/1024
    localparam PRESCALE_EXT_FALL = 3'b110; // External T0 falling edge
    localparam PRESCALE_EXT_RISE = 3'b111; // External T0 rising edge

    // Prescaler counters
    reg [9:0] prescaler_counter;  // Sufficient for prescale_1024
    reg [3:0] prescaler_div8;     // For divide by 8
    reg [5:0] prescaler_div64;    // For divide by 64
    reg [7:0] prescaler_div256;   // For divide by 256
    reg [9:0] prescaler_div1024;  // For divide by 1024

    // Prescaler logic
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            prescaler_counter <= 10'd0;
            prescaler_div8 <= 4'd0;
            prescaler_div64 <= 6'd0;
            prescaler_div256 <= 8'd0;
            prescaler_div1024 <= 10'd0;
            timer_tick <= 1'b0;
        end else begin
            // Default no tick
            timer_tick <= 1'b0;
            
            case (prescale_select)
                PRESCALE_STOP: begin
                    // Timer stopped, no tick
                    prescaler_counter <= 10'd0;
                end
                
                PRESCALE_1: begin
                    // No prescaling, tick every clock
                    timer_tick <= 1'b1;
                end
                
                PRESCALE_8: begin
                    prescaler_div8 <= prescaler_div8 + 4'd1;
                    if (prescaler_div8 == 4'd7) begin
                        prescaler_div8 <= 4'd0;
                        timer_tick <= 1'b1;
                    end
                end
                
                PRESCALE_64: begin
                    prescaler_div64 <= prescaler_div64 + 6'd1;
                    if (prescaler_div64 == 6'd63) begin
                        prescaler_div64 <= 6'd0;
                        timer_tick <= 1'b1;
                    end
                end
                
                PRESCALE_256: begin
                    prescaler_div256 <= prescaler_div256 + 8'd1;
                    if (prescaler_div256 == 8'd255) begin
                        prescaler_div256 <= 8'd0;
                        timer_tick <= 1'b1;
                    end
                end
                
                PRESCALE_1024: begin
                    prescaler_div1024 <= prescaler_div1024 + 10'd1;
                    if (prescaler_div1024 == 10'd1023) begin
                        prescaler_div1024 <= 10'd0;
                        timer_tick <= 1'b1;
                    end
                end
                
                PRESCALE_EXT_FALL,
                PRESCALE_EXT_RISE: begin
                    // External clock sources not implemented in this version
                    // Future enhancement for T0 pin input
                    timer_tick <= 1'b0;
                end
                
                default: begin
                    timer_tick <= 1'b0;
                end
            endcase
        end
    end

endmodule

`default_nettype wire