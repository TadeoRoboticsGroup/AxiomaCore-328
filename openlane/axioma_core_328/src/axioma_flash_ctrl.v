// AxiomaCore-328: Controlador de Memoria Flash
// Archivo: axioma_flash_ctrl.v
// Descripción: Controlador para 32KB Flash program memory (16K x 16 bits)
//              Compatible con tecnología Sky130 y bootloader AxiomaBoot
`default_nettype none

module axioma_flash_ctrl (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz CPU (Program Memory)
    input wire [15:0] prog_addr,       // Dirección de programa (word address)
    output reg [15:0] prog_data,       // Instrucción leída
    input wire prog_read,              // Señal de lectura
    output reg prog_ready,             // Memoria lista
    
    // Interfaz de programación/bootloader
    input wire [15:0] boot_addr,       // Dirección para programación
    input wire [15:0] boot_data,       // Datos a programar
    input wire boot_write,             // Escribir página
    input wire boot_erase,             // Borrar página
    input wire boot_enable,            // Habilitar modo bootloader
    output reg boot_ready,             // Operación completada
    
    // Control de páginas Flash
    input wire page_buffer_load,       // Cargar en buffer de página
    input wire page_write_enable,      // Escribir página desde buffer
    input wire [5:0] page_addr,        // Dirección de página (0-511)
    
    // Estado y configuración
    output reg flash_busy,             // Flash ocupado
    output reg [15:0] flash_size,      // Tamaño en words
    output reg bootloader_active,      // Bootloader activo
    
    // Señales de debug
    output wire [15:0] debug_last_addr,
    output wire [15:0] debug_last_data
);

    // Parámetros de la Flash
    localparam FLASH_SIZE_WORDS = 16384;  // 32KB = 16K words
    localparam PAGE_SIZE_WORDS = 64;      // 128 bytes = 64 words por página
    localparam NUM_PAGES = 256;           // 16K / 64 = 256 páginas
    localparam BOOTLOADER_START = 15872;  // Últimas 512 words para bootloader
    
    // Estados del controlador Flash
    localparam STATE_IDLE = 3'b000;
    localparam STATE_READ = 3'b001;
    localparam STATE_ERASE = 3'b010;
    localparam STATE_WRITE = 3'b011;
    localparam STATE_VERIFY = 3'b100;
    localparam STATE_BUSY = 3'b101;
    
    reg [2:0] flash_state;
    reg [2:0] next_state;
    
    // Memoria Flash simulada (para síntesis será reemplazada por SRAM Sky130)
    reg [15:0] flash_memory [0:FLASH_SIZE_WORDS-1];
    
    // Buffer de página para programación
    reg [15:0] page_buffer [0:PAGE_SIZE_WORDS-1];
    reg page_buffer_loaded;
    reg [5:0] buffer_word_count;
    
    // Registros de control
    reg [15:0] current_addr;
    reg [15:0] current_data;
    reg [7:0] operation_timer;
    reg flash_write_enable;
    
    // Inicialización de Flash con programa básico
    integer i;
    initial begin
        // Inicializar Flash con un programa de prueba
        for (i = 0; i < FLASH_SIZE_WORDS; i = i + 1) begin
            flash_memory[i] = 16'h0000; // NOP por defecto
        end
        
        // Programa de prueba básico en las primeras direcciones
        flash_memory[0] = 16'hE005;  // LDI R16, 0x05
        flash_memory[1] = 16'hE013;  // LDI R17, 0x03
        flash_memory[2] = 16'h0F01;  // ADD R16, R17
        flash_memory[3] = 16'h3005;  // CPI R16, 0x05
        flash_memory[4] = 16'hF409;  // BRNE +2
        flash_memory[5] = 16'hE025;  // LDI R18, 0x05
        flash_memory[6] = 16'hE02A;  // LDI R18, 0x0A
        flash_memory[7] = 16'hCFFF;  // RJMP -1 (loop)
        
        // Bootloader básico al final de la Flash
        flash_memory[BOOTLOADER_START] = 16'hE010;     // LDI R17, 0x00
        flash_memory[BOOTLOADER_START+1] = 16'hC000;   // RJMP 0 (saltar a aplicación)
        
        flash_size = FLASH_SIZE_WORDS;
    end
    
    // Máquina de estados Flash
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            flash_state <= STATE_IDLE;
            prog_ready <= 1'b1;
            boot_ready <= 1'b1;
            flash_busy <= 1'b0;
            bootloader_active <= 1'b0;
            page_buffer_loaded <= 1'b0;
            buffer_word_count <= 6'h00;
            operation_timer <= 8'h00;
            current_addr <= 16'h0000;
            current_data <= 16'h0000;
            flash_write_enable <= 1'b0;
        end else begin
            flash_state <= next_state;
            
            case (flash_state)
                STATE_IDLE: begin
                    prog_ready <= 1'b1;
                    boot_ready <= 1'b1;
                    flash_busy <= 1'b0;
                    operation_timer <= 8'h00;
                    
                    // Activar bootloader si se requiere
                    if (boot_enable) begin
                        bootloader_active <= 1'b1;
                    end
                end
                
                STATE_READ: begin
                    // Lectura de programa (1 ciclo)
                    if (prog_addr < FLASH_SIZE_WORDS) begin
                        prog_data <= flash_memory[prog_addr];
                        prog_ready <= 1'b1;
                    end else begin
                        prog_data <= 16'h0000; // NOP para direcciones inválidas
                        prog_ready <= 1'b1;
                    end
                end
                
                STATE_ERASE: begin
                    flash_busy <= 1'b1;
                    boot_ready <= 1'b0;
                    operation_timer <= operation_timer + 1;
                    
                    // Simular tiempo de borrado (16 ciclos)
                    if (operation_timer >= 15) begin
                        // Borrar página completa
                        for (i = 0; i < PAGE_SIZE_WORDS; i = i + 1) begin
                            flash_memory[{page_addr, 6'h00} + i] = 16'hFFFF;
                        end
                        operation_timer <= 8'h00;
                    end
                end
                
                STATE_WRITE: begin
                    flash_busy <= 1'b1;
                    boot_ready <= 1'b0;
                    operation_timer <= operation_timer + 1;
                    
                    // Simular tiempo de escritura (32 ciclos)
                    if (operation_timer >= 31) begin
                        // Escribir buffer de página a Flash
                        if (page_buffer_loaded) begin
                            for (i = 0; i < PAGE_SIZE_WORDS; i = i + 1) begin
                                flash_memory[{page_addr, 6'h00} + i] = page_buffer[i];
                            end
                            page_buffer_loaded <= 1'b0;
                        end
                        operation_timer <= 8'h00;
                    end
                end
                
                STATE_BUSY: begin
                    // Estado de espera para operaciones complejas
                    operation_timer <= operation_timer + 1;
                    if (operation_timer >= 7) begin
                        operation_timer <= 8'h00;
                    end
                end
            endcase
        end
    end
    
    // Lógica combinacional de siguiente estado
    always @(*) begin
        next_state = flash_state;
        
        case (flash_state)
            STATE_IDLE: begin
                if (prog_read) begin
                    next_state = STATE_READ;
                end else if (boot_erase && bootloader_active) begin
                    next_state = STATE_ERASE;
                end else if (page_write_enable && bootloader_active) begin
                    next_state = STATE_WRITE;
                end
            end
            
            STATE_READ: begin
                next_state = STATE_IDLE;
            end
            
            STATE_ERASE: begin
                if (operation_timer >= 15) begin
                    next_state = STATE_IDLE;
                end
            end
            
            STATE_WRITE: begin
                if (operation_timer >= 31) begin
                    next_state = STATE_IDLE;
                end
            end
            
            STATE_BUSY: begin
                if (operation_timer >= 7) begin
                    next_state = STATE_IDLE;
                end
            end
            
            default: begin
                next_state = STATE_IDLE;
            end
        endcase
    end
    
    // Lógica del buffer de página
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            buffer_word_count <= 6'h00;
            for (i = 0; i < PAGE_SIZE_WORDS; i = i + 1) begin
                page_buffer[i] <= 16'h0000;
            end
        end else begin
            if (page_buffer_load && bootloader_active) begin
                // Cargar datos en buffer de página
                if (buffer_word_count < PAGE_SIZE_WORDS) begin
                    page_buffer[buffer_word_count] <= boot_data;
                    buffer_word_count <= buffer_word_count + 1;
                    if (buffer_word_count == PAGE_SIZE_WORDS - 1) begin
                        page_buffer_loaded <= 1'b1;
                        buffer_word_count <= 6'h00;
                    end
                end
            end else if (page_write_enable && flash_state == STATE_IDLE) begin
                // Reset buffer después de escribir
                buffer_word_count <= 6'h00;
            end
        end
    end
    
    // Protección contra escritura de bootloader
    function is_bootloader_protected;
        input [15:0] addr;
        begin
            is_bootloader_protected = (addr >= BOOTLOADER_START) && !bootloader_active;
        end
    endfunction
    
    // Señales de debug
    assign debug_last_addr = current_addr;
    assign debug_last_data = current_data;
    
    // Actualizar direcciones para debug
    always @(posedge clk) begin
        if (prog_read) begin
            current_addr <= prog_addr;
            current_data <= prog_data;
        end else if (boot_write) begin
            current_addr <= boot_addr;
            current_data <= boot_data;
        end
    end

endmodule

`default_nettype wire