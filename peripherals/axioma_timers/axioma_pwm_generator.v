// AxiomaCore-328: Generador PWM Común
// Archivo: axioma_pwm_generator.v  
// Descripción: Módulo reutilizable para generación PWM en todos los timers
// Compatible: ATmega328P
`default_nettype none

module axioma_pwm_generator #(
    parameter WIDTH = 8  // Ancho del contador (8 para Timer0/2, 16 para Timer1)
) (
    input wire clk,                      // Reloj del sistema
    input wire reset_n,                  // Reset activo bajo
    input wire timer_tick,               // Tick del prescaler
    
    // Control de modo PWM
    input wire [2:0] pwm_mode,          // Modo PWM (normal, fast, phase correct)
    input wire [1:0] com_a,             // Compare Output Mode A
    input wire [1:0] com_b,             // Compare Output Mode B
    
    // Registros de comparación
    input wire [WIDTH-1:0] ocr_a,       // Output Compare Register A
    input wire [WIDTH-1:0] ocr_b,       // Output Compare Register B
    input wire [WIDTH-1:0] top_value,   // Valor TOP para PWM
    
    // Contador del timer
    input wire [WIDTH-1:0] tcnt,        // Timer Counter (solo lectura)
    output reg [WIDTH-1:0] tcnt_out,    // Timer Counter (salida actualizada)
    
    // Salidas PWM
    output reg pwm_a,                   // PWM Output A
    output reg pwm_b,                   // PWM Output B
    
    // Flags de comparación
    output reg comp_a_match,            // Compare Match A flag
    output reg comp_b_match,            // Compare Match B flag
    output reg overflow                 // Overflow flag
);

    // Constantes locales (extraídas de axioma_constants.v)
    localparam TIMER_MODE_NORMAL        = 3'b000;
    localparam TIMER_MODE_PWM_PHASE     = 3'b001;
    localparam TIMER_MODE_CTC           = 3'b010;
    localparam TIMER_MODE_PWM_FAST      = 3'b011;
    localparam TIMER_MODE_PWM_PHASE_OCR = 3'b101;
    localparam TIMER_MODE_PWM_FAST_OCR  = 3'b111;
    
    localparam COM_DISCONNECT = 2'b00;
    localparam COM_TOGGLE     = 2'b01;
    localparam COM_CLEAR      = 2'b10;
    localparam COM_SET        = 2'b11;

    // Estados internos
    reg [WIDTH-1:0] counter;
    reg count_up;                       // Dirección del contador (para phase correct)
    reg pwm_a_reg, pwm_b_reg;
    
    // Inicialización
    initial begin
        counter = 0;
        count_up = 1'b1;
        pwm_a = 1'b0;
        pwm_b = 1'b0;
        comp_a_match = 1'b0;
        comp_b_match = 1'b0;
        overflow = 1'b0;
    end

    // Lógica principal del PWM
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            counter <= {WIDTH{1'b0}};
            count_up <= 1'b1;
            pwm_a_reg <= 1'b0;
            pwm_b_reg <= 1'b0;
            comp_a_match <= 1'b0;
            comp_b_match <= 1'b0;
            overflow <= 1'b0;
        end else if (timer_tick) begin
            // Clear flags por defecto
            comp_a_match <= 1'b0;
            comp_b_match <= 1'b0;
            overflow <= 1'b0;
            
            case (pwm_mode)
                TIMER_MODE_NORMAL: begin
                    // Modo normal: contador libre hasta overflow
                    if (counter == {WIDTH{1'b1}}) begin
                        counter <= {WIDTH{1'b0}};
                        overflow <= 1'b1;
                    end else begin
                        counter <= counter + 1'b1;
                    end
                    
                    // Compare matches
                    if (counter == ocr_a) comp_a_match <= 1'b1;
                    if (counter == ocr_b) comp_b_match <= 1'b1;
                end
                
                TIMER_MODE_CTC: begin
                    // Modo CTC: clear on compare match A
                    if (counter >= ocr_a) begin
                        counter <= {WIDTH{1'b0}};
                        comp_a_match <= 1'b1;
                    end else begin
                        counter <= counter + 1'b1;
                    end
                    
                    // Compare match B
                    if (counter == ocr_b) comp_b_match <= 1'b1;
                end
                
                TIMER_MODE_PWM_FAST,
                TIMER_MODE_PWM_FAST_OCR: begin
                    // Fast PWM: cuenta hasta TOP, luego overflow
                    if (counter >= top_value) begin
                        counter <= {WIDTH{1'b0}};
                        overflow <= 1'b1;
                    end else begin
                        counter <= counter + 1'b1;
                    end
                    
                    // Compare matches
                    if (counter == ocr_a) comp_a_match <= 1'b1;
                    if (counter == ocr_b) comp_b_match <= 1'b1;
                end
                
                TIMER_MODE_PWM_PHASE,
                TIMER_MODE_PWM_PHASE_OCR: begin
                    // Phase Correct PWM: cuenta up/down
                    if (count_up) begin
                        if (counter >= top_value) begin
                            count_up <= 1'b0;
                            overflow <= 1'b1;  // TOP reached
                        end else begin
                            counter <= counter + 1'b1;
                        end
                    end else begin
                        if (counter == 0) begin
                            count_up <= 1'b1;
                        end else begin
                            counter <= counter - 1'b1;
                        end
                    end
                    
                    // Compare matches
                    if (counter == ocr_a) comp_a_match <= 1'b1;
                    if (counter == ocr_b) comp_b_match <= 1'b1;
                end
            endcase
        end
    end

    // Generación de señales PWM
    always @(*) begin
        // PWM Output A
        case (com_a)
            COM_DISCONNECT: pwm_a = 1'b0;
            COM_TOGGLE: pwm_a = comp_a_match ? ~pwm_a_reg : pwm_a_reg;
            COM_CLEAR: begin
                case (pwm_mode)
                    TIMER_MODE_PWM_FAST,
                    TIMER_MODE_PWM_FAST_OCR: 
                        pwm_a = (counter < ocr_a) ? 1'b1 : 1'b0;
                    TIMER_MODE_PWM_PHASE,
                    TIMER_MODE_PWM_PHASE_OCR:
                        pwm_a = (count_up && counter < ocr_a) || (!count_up && counter > ocr_a) ? 1'b1 : 1'b0;
                    default: pwm_a = 1'b0;
                endcase
            end
            COM_SET: begin
                case (pwm_mode)
                    TIMER_MODE_PWM_FAST,
                    TIMER_MODE_PWM_FAST_OCR:
                        pwm_a = (counter < ocr_a) ? 1'b0 : 1'b1;
                    TIMER_MODE_PWM_PHASE,
                    TIMER_MODE_PWM_PHASE_OCR:
                        pwm_a = (count_up && counter < ocr_a) || (!count_up && counter > ocr_a) ? 1'b0 : 1'b1;
                    default: pwm_a = 1'b0;
                endcase
            end
        endcase
        
        // PWM Output B (lógica similar)
        case (com_b)
            COM_DISCONNECT: pwm_b = 1'b0;
            COM_TOGGLE: pwm_b = comp_b_match ? ~pwm_b_reg : pwm_b_reg;
            COM_CLEAR: begin
                case (pwm_mode)
                    TIMER_MODE_PWM_FAST,
                    TIMER_MODE_PWM_FAST_OCR:
                        pwm_b = (counter < ocr_b) ? 1'b1 : 1'b0;
                    TIMER_MODE_PWM_PHASE,
                    TIMER_MODE_PWM_PHASE_OCR:
                        pwm_b = (count_up && counter < ocr_b) || (!count_up && counter > ocr_b) ? 1'b1 : 1'b0;
                    default: pwm_b = 1'b0;
                endcase
            end
            COM_SET: begin
                case (pwm_mode)
                    TIMER_MODE_PWM_FAST,
                    TIMER_MODE_PWM_FAST_OCR:
                        pwm_b = (counter < ocr_b) ? 1'b0 : 1'b1;
                    TIMER_MODE_PWM_PHASE,
                    TIMER_MODE_PWM_PHASE_OCR:
                        pwm_b = (count_up && counter < ocr_b) || (!count_up && counter > ocr_b) ? 1'b0 : 1'b1;
                    default: pwm_b = 1'b0;
                endcase
            end
        endcase
    end

    // Actualizar registros de estado para toggle mode
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            pwm_a_reg <= 1'b0;
            pwm_b_reg <= 1'b0;
        end else begin
            if (comp_a_match && com_a == COM_TOGGLE) 
                pwm_a_reg <= ~pwm_a_reg;
            if (comp_b_match && com_b == COM_TOGGLE)
                pwm_b_reg <= ~pwm_b_reg;
        end
    end

    // Salida del contador actualizado
    always @(*) begin
        tcnt_out = counter;
    end

endmodule

`default_nettype wire