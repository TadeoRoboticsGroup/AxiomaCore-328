// AxiomaCore-328: EEPROM Controller - Fase 5
// Archivo: axioma_eeprom_ctrl.v
// Descripción: Controlador EEPROM de 1KB compatible ATmega328P
//              Registros EEAR, EEDR, EECR con timing de escritura/borrado
`default_nettype none

module axioma_eeprom_ctrl (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz con CPU (I/O memory-mapped)
    input wire [5:0] io_addr,          // Dirección I/O
    input wire [7:0] io_data_in,       // Datos de escritura
    output reg [7:0] io_data_out,      // Datos de lectura
    input wire io_read,                // Habilitación lectura
    input wire io_write,               // Habilitación escritura
    
    // Interrupciones
    output wire eeprom_ready,          // Interrupción EEPROM ready
    
    // Debug
    output wire [7:0] debug_state,
    output wire [9:0] debug_address
);

    // Direcciones I/O de registros EEPROM (ATmega328P compatible)
    localparam ADDR_EEARL = 6'h21;     // 0x41 - EEPROM Address Register Low
    localparam ADDR_EEARH = 6'h22;     // 0x42 - EEPROM Address Register High
    localparam ADDR_EEDR  = 6'h20;     // 0x40 - EEPROM Data Register
    localparam ADDR_EECR  = 6'h1F;     // 0x3F - EEPROM Control Register

    // Estados de la máquina EEPROM
    localparam EEPROM_IDLE    = 3'b000;
    localparam EEPROM_READ    = 3'b001;
    localparam EEPROM_WRITE   = 3'b010;
    localparam EEPROM_ERASE   = 3'b011;
    localparam EEPROM_PROGRAM = 3'b100;
    localparam EEPROM_WAIT    = 3'b101;

    // Parámetros de timing (en ciclos de clock)
    localparam ERASE_TIME  = 16'd3400;  // ~3.4ms @ 1MHz (simulado)
    localparam WRITE_TIME  = 16'd3400;  // ~3.4ms @ 1MHz (simulado)
    localparam READ_TIME   = 16'd4;     // 4 ciclos

    // Registros EEPROM
    reg [7:0] reg_eearl;              // Address Low
    reg [7:0] reg_eearh;              // Address High (solo 2 bits usados)
    reg [7:0] reg_eedr;               // Data Register
    reg [7:0] reg_eecr;               // Control Register

    // Bits de EECR
    wire eecr_eepm1 = reg_eecr[5];    // Programming Mode bit 1
    wire eecr_eepm0 = reg_eecr[4];    // Programming Mode bit 0
    wire eecr_eerie = reg_eecr[3];    // EEPROM Ready Interrupt Enable
    wire eecr_eempe = reg_eecr[2];    // EEPROM Master Programming Enable
    wire eecr_eepe  = reg_eecr[1];    // EEPROM Programming Enable
    wire eecr_eere  = reg_eecr[0];    // EEPROM Read Enable

    // Dirección completa (10 bits para 1KB)
    wire [9:0] eeprom_address = {reg_eearh[1:0], reg_eearl};

    // Memoria EEPROM simulada (1KB = 1024 bytes)
    reg [7:0] eeprom_memory [0:1023];

    // Estados internos
    reg [2:0] eeprom_state;
    reg [15:0] timing_counter;
    reg operation_complete;
    reg eeprom_busy;
    reg [7:0] read_data;

    // Inicialización de memoria EEPROM
    integer i;
    initial begin
        for (i = 0; i < 1024; i = i + 1) begin
            eeprom_memory[i] = 8'hFF; // EEPROM por defecto en 0xFF
        end
    end

    // Lógica principal EEPROM
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            reg_eearl <= 8'h00;
            reg_eearh <= 8'h00;
            reg_eedr <= 8'h00;
            reg_eecr <= 8'h00;
            
            eeprom_state <= EEPROM_IDLE;
            timing_counter <= 16'h0000;
            operation_complete <= 1'b0;
            eeprom_busy <= 1'b0;
            read_data <= 8'h00;
            
        end else begin
            operation_complete <= 1'b0;
            
            // Escritura de registros
            if (io_write) begin
                case (io_addr)
                    ADDR_EEARL: reg_eearl <= io_data_in;
                    ADDR_EEARH: reg_eearh <= io_data_in & 8'h03; // Solo 2 bits válidos
                    ADDR_EEDR:  reg_eedr <= io_data_in;
                    ADDR_EECR: begin
                        reg_eecr <= io_data_in;
                        
                        // Detectar operación de lectura
                        if (io_data_in[0] && !eeprom_busy) begin // EERE = 1
                            eeprom_state <= EEPROM_READ;
                            eeprom_busy <= 1'b1;
                            timing_counter <= 16'h0000;
                        end
                        
                        // Detectar operación de escritura/borrado
                        if (io_data_in[1] && eecr_eempe && !eeprom_busy) begin // EEPE = 1
                            case ({eecr_eepm1, eecr_eepm0})
                                2'b00: begin // Erase and Write
                                    eeprom_state <= EEPROM_ERASE;
                                    eeprom_busy <= 1'b1;
                                    timing_counter <= 16'h0000;
                                end
                                2'b01: begin // Erase only
                                    eeprom_state <= EEPROM_ERASE;
                                    eeprom_busy <= 1'b1;
                                    timing_counter <= 16'h0000;
                                end
                                2'b10: begin // Write only
                                    eeprom_state <= EEPROM_WRITE;
                                    eeprom_busy <= 1'b1;
                                    timing_counter <= 16'h0000;
                                end
                                2'b11: begin // Reserved
                                    // No operation
                                end
                            endcase
                        end
                    end
                endcase
            end
            
            // Máquina de estados EEPROM
            case (eeprom_state)
                EEPROM_IDLE: begin
                    eeprom_busy <= 1'b0;
                    reg_eecr[1] <= 1'b0; // Clear EEPE
                    reg_eecr[0] <= 1'b0; // Clear EERE
                end
                
                EEPROM_READ: begin
                    timing_counter <= timing_counter + 16'h0001;
                    if (timing_counter >= READ_time) begin
                        read_data <= eeprom_memory[eeprom_address];
                        reg_eedr <= eeprom_memory[eeprom_address];
                        eeprom_state <= EEPROM_IDLE;
                        operation_complete <= 1'b1;
                    end
                end
                
                EEPROM_ERASE: begin
                    timing_counter <= timing_counter + 16'h0001;
                    if (timing_counter >= ERASE_TIME) begin
                        eeprom_memory[eeprom_address] <= 8'hFF; // Erase = set to 0xFF
                        
                        // Si es erase and write, continuar con write
                        if ({eecr_eepm1, eecr_eepm0} == 2'b00) begin
                            eeprom_state <= EEPROM_PROGRAM;
                            timing_counter <= 16'h0000;
                        end else begin
                            eeprom_state <= EEPROM_IDLE;
                            operation_complete <= 1'b1;
                        end
                    end
                end
                
                EEPROM_WRITE: begin
                    timing_counter <= timing_counter + 16'h0001;
                    if (timing_counter >= WRITE_TIME) begin
                        // Write only: AND operation con valor existente
                        eeprom_memory[eeprom_address] <= eeprom_memory[eeprom_address] & reg_eedr;
                        eeprom_state <= EEPROM_IDLE;
                        operation_complete <= 1'b1;
                    end
                end
                
                EEPROM_PROGRAM: begin
                    timing_counter <= timing_counter + 16'h0001;
                    if (timing_counter >= WRITE_TIME) begin
                        // Program after erase: direct write
                        eeprom_memory[eeprom_address] <= reg_eedr;
                        eeprom_state <= EEPROM_IDLE;
                        operation_complete <= 1'b1;
                    end
                end
                
                default: begin
                    eeprom_state <= EEPROM_IDLE;
                end
            endcase
            
            // Clear EEMPE después de tiempo específico (simplificado)
            if (reg_eecr[2] && timing_counter > 16'd4) begin
                reg_eecr[2] <= 1'b0; // Clear EEMPE
            end
        end
    end

    // Lógica de lectura de registros I/O
    always @(*) begin
        io_data_out = 8'h00;
        
        if (io_read) begin
            case (io_addr)
                ADDR_EEARL: io_data_out = reg_eearl;
                ADDR_EEARH: io_data_out = {6'b000000, reg_eearh[1:0]};
                ADDR_EEDR:  io_data_out = reg_eedr;
                ADDR_EECR:  io_data_out = {reg_eecr[7:2], eeprom_busy ? 1'b0 : reg_eecr[1], reg_eecr[0]};
                default:    io_data_out = 8'h00;
            endcase
        end
    end

    // Interrupciones
    assign eeprom_ready = operation_complete && eecr_eerie;

    // Debug
    assign debug_state = {eeprom_state, eeprom_busy, operation_complete, 3'b000};
    assign debug_address = eeprom_address;

endmodule

`default_nettype wire