// AxiomaCore-328: Controlador de Memoria SRAM
// Archivo: axioma_sram_ctrl.v  
// Descripción: Controlador para 2KB SRAM data memory (2048 x 8 bits)
//              Incluye stack pointer automático y mapeo I/O
`default_nettype none

module axioma_sram_ctrl (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz CPU (Data Memory)
    input wire [15:0] data_addr,       // Dirección de datos
    input wire [7:0] data_in,          // Datos a escribir
    output reg [7:0] data_out,         // Datos leídos
    input wire data_read,              // Señal de lectura
    input wire data_write,             // Señal de escritura
    output reg data_ready,             // Operación completada
    
    // Interfaz Stack
    input wire stack_push,             // Push al stack
    input wire stack_pop,              // Pop del stack
    input wire [7:0] stack_data_in,    // Dato a hacer push
    output reg [7:0] stack_data_out,   // Dato del pop
    input wire stack_push_16bit,       // Push de 16 bits (PC)
    input wire stack_pop_16bit,        // Pop de 16 bits (PC)
    input wire [15:0] stack_data_16_in, // Dato 16-bit para push
    output reg [15:0] stack_data_16_out, // Dato 16-bit del pop
    
    // Interfaz I/O Memory Mapped
    input wire [5:0] io_addr,          // Dirección I/O (0x00-0x3F)
    input wire [7:0] io_data_in,       // Datos I/O a escribir
    output reg [7:0] io_data_out,      // Datos I/O leídos
    input wire io_read,                // Leer I/O
    input wire io_write,               // Escribir I/O
    
    // Control del Stack Pointer
    input wire [15:0] sp_init_value,   // Valor inicial del SP
    input wire sp_init,                // Inicializar SP
    output reg [15:0] stack_pointer,   // Stack Pointer actual
    
    // Estado y debug
    output reg sram_error,             // Error de acceso
    output wire [15:0] debug_last_addr,
    output wire [7:0] debug_last_data
);

    // Parámetros de memoria
    localparam SRAM_SIZE = 2048;           // 2KB SRAM
    localparam SRAM_START = 16'h0100;      // SRAM inicia en 0x0100
    localparam SRAM_END = 16'h08FF;        // SRAM termina en 0x08FF
    localparam IO_START = 16'h0020;        // I/O registers start
    localparam IO_END = 16'h005F;          // I/O registers end
    localparam GP_REG_START = 16'h0000;    // General purpose registers
    localparam GP_REG_END = 16'h001F;      // R0-R31 mapped to 0x00-0x1F
    localparam SP_INIT_DEFAULT = SRAM_END; // SP inicial al final de SRAM
    
    // Estados del controlador
    localparam STATE_IDLE = 2'b00;
    localparam STATE_READ = 2'b01;
    localparam STATE_WRITE = 2'b10;
    localparam STATE_STACK = 2'b11;
    
    reg [1:0] sram_state;
    reg [1:0] next_state;
    
    // Memoria SRAM (será reemplazada por SRAM Sky130 en síntesis)
    reg [7:0] sram_memory [0:SRAM_SIZE-1];
    
    // I/O Memory Map (64 registros I/O)
    reg [7:0] io_registers [0:63];
    
    // Registros de control interno
    reg [15:0] current_addr;
    reg [7:0] current_data;
    reg stack_operation_pending;
    
    // Inicialización
    integer i;
    initial begin
        // Inicializar SRAM
        for (i = 0; i < SRAM_SIZE; i = i + 1) begin
            sram_memory[i] = 8'h00;
        end
        
        // Inicializar registros I/O
        for (i = 0; i < 64; i = i + 1) begin
            io_registers[i] = 8'h00;
        end
        
        // Configurar algunos registros I/O críticos
        io_registers[6'h3D] = 8'h08; // SPL - Stack Pointer Low
        io_registers[6'h3E] = 8'h08; // SPH - Stack Pointer High  
        io_registers[6'h3F] = 8'h00; // SREG - Status Register
    end
    
    // Máquina de estados principal
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            sram_state <= STATE_IDLE;
            data_ready <= 1'b1;
            sram_error <= 1'b0;
            stack_pointer <= SP_INIT_DEFAULT;
            current_addr <= 16'h0000;
            current_data <= 8'h00;
            stack_operation_pending <= 1'b0;
            
            // Inicializar SP en registros I/O
            io_registers[6'h3D] <= SP_INIT_DEFAULT[7:0];   // SPL
            io_registers[6'h3E] <= SP_INIT_DEFAULT[15:8];  // SPH
            
        end else begin
            sram_state <= next_state;
            
            // Inicialización manual del SP
            if (sp_init) begin
                stack_pointer <= sp_init_value;
                io_registers[6'h3D] <= sp_init_value[7:0];
                io_registers[6'h3E] <= sp_init_value[15:8];
            end
            
            case (sram_state)
                STATE_IDLE: begin
                    data_ready <= 1'b1;
                    sram_error <= 1'b0;
                    stack_operation_pending <= 1'b0;
                end
                
                STATE_READ: begin
                    data_ready <= 1'b0;
                    // Leer de memoria según mapa de direcciones
                    if (is_sram_address(data_addr)) begin
                        data_out <= sram_memory[data_addr - SRAM_START];
                        data_ready <= 1'b1;
                    end else if (is_io_address(data_addr)) begin
                        data_out <= io_registers[data_addr - IO_START];
                        data_ready <= 1'b1;
                    end else begin
                        data_out <= 8'h00;
                        sram_error <= 1'b1;
                        data_ready <= 1'b1;
                    end
                    current_addr <= data_addr;
                end
                
                STATE_WRITE: begin
                    data_ready <= 1'b0;
                    // Escribir a memoria según mapa de direcciones
                    if (is_sram_address(data_addr)) begin
                        sram_memory[data_addr - SRAM_START] <= data_in;
                        data_ready <= 1'b1;
                    end else if (is_io_address(data_addr)) begin
                        io_registers[data_addr - IO_START] <= data_in;
                        // Actualizar SP si se escriben SPL/SPH
                        if (data_addr == 16'h005D) begin // SPL
                            stack_pointer[7:0] <= data_in;
                        end else if (data_addr == 16'h005E) begin // SPH
                            stack_pointer[15:8] <= data_in;
                        end
                        data_ready <= 1'b1;
                    end else begin
                        sram_error <= 1'b1;
                        data_ready <= 1'b1;
                    end
                    current_addr <= data_addr;
                    current_data <= data_in;
                end
                
                STATE_STACK: begin
                    data_ready <= 1'b0;
                    
                    if (stack_push) begin
                        // Push 8-bit
                        if (is_sram_address(stack_pointer)) begin
                            sram_memory[stack_pointer - SRAM_START] <= stack_data_in;
                            stack_pointer <= stack_pointer - 1;
                            // Actualizar registros SPL/SPH
                            io_registers[6'h3D] <= stack_pointer[7:0] - 8'h01;
                            io_registers[6'h3E] <= stack_pointer[15:8];
                        end
                        data_ready <= 1'b1;
                        
                    end else if (stack_pop) begin
                        // Pop 8-bit
                        stack_pointer <= stack_pointer + 1;
                        if (is_sram_address(stack_pointer + 1)) begin
                            stack_data_out <= sram_memory[(stack_pointer + 1) - SRAM_START];
                        end
                        // Actualizar registros SPL/SPH
                        io_registers[6'h3D] <= stack_pointer[7:0] + 8'h01;
                        io_registers[6'h3E] <= stack_pointer[15:8];
                        data_ready <= 1'b1;
                        
                    end else if (stack_push_16bit) begin
                        // Push 16-bit (PC) - Low byte first, then high byte
                        if (is_sram_address(stack_pointer) && is_sram_address(stack_pointer - 1)) begin
                            sram_memory[stack_pointer - SRAM_START] <= stack_data_16_in[7:0];     // Low byte
                            sram_memory[(stack_pointer - 1) - SRAM_START] <= stack_data_16_in[15:8]; // High byte
                            stack_pointer <= stack_pointer - 2;
                            io_registers[6'h3D] <= stack_pointer[7:0] - 8'h02;
                            io_registers[6'h3E] <= stack_pointer[15:8];
                        end
                        data_ready <= 1'b1;
                        
                    end else if (stack_pop_16bit) begin
                        // Pop 16-bit (PC) - High byte first, then low byte
                        stack_pointer <= stack_pointer + 2;
                        if (is_sram_address(stack_pointer + 1) && is_sram_address(stack_pointer + 2)) begin
                            stack_data_16_out[15:8] <= sram_memory[(stack_pointer + 1) - SRAM_START]; // High byte
                            stack_data_16_out[7:0] <= sram_memory[(stack_pointer + 2) - SRAM_START];  // Low byte
                        end
                        io_registers[6'h3D] <= stack_pointer[7:0] + 8'h02;
                        io_registers[6'h3E] <= stack_pointer[15:8];
                        data_ready <= 1'b1;
                    end else begin
                        data_ready <= 1'b1;
                    end
                end
            endcase
        end
    end
    
    // Lógica de siguiente estado
    always @(*) begin
        next_state = sram_state;
        
        case (sram_state)
            STATE_IDLE: begin
                if (stack_push || stack_pop || stack_push_16bit || stack_pop_16bit) begin
                    next_state = STATE_STACK;
                end else if (data_read) begin
                    next_state = STATE_READ;
                end else if (data_write) begin
                    next_state = STATE_WRITE;
                end
            end
            
            STATE_READ, STATE_WRITE, STATE_STACK: begin
                next_state = STATE_IDLE;
            end
        endcase
    end
    
    // I/O directo (bypass para acceso rápido)
    always @(*) begin
        if (io_read && (io_addr < 64)) begin
            io_data_out = io_registers[io_addr];
        end else begin
            io_data_out = 8'h00;
        end
    end
    
    // Escritura I/O directa
    always @(posedge clk) begin
        if (io_write && (io_addr < 64)) begin
            io_registers[io_addr] <= io_data_in;
            // Sincronizar SP si se modifica
            if (io_addr == 6'h3D || io_addr == 6'h3E) begin
                stack_pointer <= {io_registers[6'h3E], io_registers[6'h3D]};
            end
        end
    end
    
    // Funciones de verificación de direcciones
    function is_sram_address;
        input [15:0] addr;
        begin
            is_sram_address = (addr >= SRAM_START) && (addr <= SRAM_END);
        end
    endfunction
    
    function is_io_address;
        input [15:0] addr;
        begin
            is_io_address = (addr >= IO_START) && (addr <= IO_END);
        end
    endfunction
    
    // Señales de debug
    assign debug_last_addr = current_addr;
    assign debug_last_data = current_data;

endmodule

`default_nettype wire