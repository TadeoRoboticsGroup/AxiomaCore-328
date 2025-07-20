// AxiomaCore-328: CPU Integrada Versión 2 - Núcleo AVR Completo
// Archivo: axioma_cpu_v2.v
// Descripción: CPU AVR completa con memory controllers, interrupts y instruction set expandido
//              Pipeline de 2 etapas con soporte completo para ATmega328P
`default_nettype none

module axioma_cpu_v2 (
    input wire clk,                    // Reloj del sistema
    input wire reset_n,                // Reset activo bajo
    
    // Interfaz externa (pines del chip)
    input wire [7:0] portb_in,         // Puerto B entrada
    output wire [7:0] portb_out,       // Puerto B salida
    output wire [7:0] portb_ddr,       // Puerto B dirección
    
    input wire [7:0] portc_in,         // Puerto C entrada  
    output wire [7:0] portc_out,       // Puerto C salida
    output wire [7:0] portc_ddr,       // Puerto C dirección
    
    input wire [7:0] portd_in,         // Puerto D entrada
    output wire [7:0] portd_out,       // Puerto D salida
    output wire [7:0] portd_ddr,       // Puerto D dirección
    
    // Interrupciones externas
    input wire int0_pin,               // INT0 (PD2)
    input wire int1_pin,               // INT1 (PD3)
    
    // Comunicaciones serie
    input wire uart_rx,                // UART RX
    output wire uart_tx,               // UART TX
    input wire spi_miso,               // SPI MISO
    output wire spi_mosi,              // SPI MOSI
    output wire spi_sck,               // SPI SCK
    output wire spi_ss,                // SPI SS
    input wire sda,                    // I2C SDA
    input wire scl,                    // I2C SCL
    
    // Entrada analógica
    input wire [7:0] adc_channels,     // 8 canales ADC
    
    // Control y estado
    input wire bootloader_enable,      // Activar bootloader
    output wire cpu_halted,            // CPU detenida
    output wire [7:0] status_reg,      // SREG para debug
    output wire watchdog_reset,        // Reset por watchdog
    
    // Debug avanzado
    output wire [15:0] debug_pc,       // Program Counter
    output wire [15:0] debug_instruction, // Instrucción actual
    output wire [15:0] debug_stack_pointer, // Stack Pointer
    output wire [7:0] debug_sreg,      // Status Register
    output wire debug_interrupt_active // Interrupción activa
);

    // Estados del pipeline
    localparam STATE_FETCH = 3'b000;
    localparam STATE_DECODE = 3'b001;
    localparam STATE_EXECUTE = 3'b010;
    localparam STATE_MEMORY = 3'b011;
    localparam STATE_INTERRUPT = 3'b100;
    localparam STATE_HALT = 3'b111;
    
    reg [2:0] cpu_state;
    reg [2:0] next_state;
    
    // Program Counter y control de flujo
    reg [15:0] pc;
    reg [15:0] next_pc;
    reg pc_update;
    reg [15:0] interrupt_return_addr;
    
    // Pipeline registers
    reg [15:0] instruction_reg;
    reg instruction_valid;
    
    // Señales internas del decodificador expandido
    wire [4:0] dec_rs1_addr, dec_rs2_addr, dec_rd_addr;
    wire dec_rd_write_en;
    wire [4:0] dec_alu_op;
    wire dec_alu_use_immediate;
    wire [7:0] dec_immediate;
    wire dec_mem_read, dec_mem_write;
    wire [2:0] dec_mem_mode;
    wire dec_use_pointer;
    wire [1:0] dec_pointer_sel;
    wire dec_pointer_post_inc, dec_pointer_pre_dec;
    wire dec_stack_push, dec_stack_pop;
    wire dec_stack_push_pc, dec_stack_pop_pc;
    wire dec_branch_en;
    wire [3:0] dec_branch_condition;
    wire [11:0] dec_branch_offset;
    wire dec_jump_en, dec_call_en, dec_ret_en;
    wire [21:0] dec_jump_addr;
    wire dec_io_read, dec_io_write;
    wire [5:0] dec_io_addr;
    wire dec_bit_set, dec_bit_clear;
    wire [2:0] dec_bit_num;
    wire dec_sreg_update;
    wire [7:0] dec_sreg_mask;
    wire dec_instruction_decoded;
    wire dec_unsupported_instruction;
    
    // Señales del banco de registros
    wire [7:0] reg_rs1_data, reg_rs2_data;
    wire [15:0] reg_x_pointer, reg_y_pointer, reg_z_pointer;
    reg reg_rd_write_en;
    reg [7:0] reg_rd_data;
    
    // Señales de la ALU
    wire [7:0] alu_result;
    wire alu_flag_c, alu_flag_z, alu_flag_n, alu_flag_v, alu_flag_s, alu_flag_h;
    reg alu_update_flags;
    
    // Operando B de la ALU
    wire [7:0] alu_operand_b = dec_alu_use_immediate ? dec_immediate : reg_rs2_data;
    
    // Status Register (SREG) expandido
    reg [7:0] sreg;
    wire sreg_c = sreg[0];  // Carry
    wire sreg_z = sreg[1];  // Zero
    wire sreg_n = sreg[2];  // Negative
    wire sreg_v = sreg[3];  // Overflow
    wire sreg_s = sreg[4];  // Sign
    wire sreg_h = sreg[5];  // Half carry
    wire sreg_t = sreg[6];  // T flag
    wire sreg_i = sreg[7];  // Global interrupt enable
    
    // Señales de memoria Flash
    wire [15:0] flash_prog_data;
    wire flash_prog_ready;
    reg flash_prog_read;
    
    // Señales de memoria SRAM
    wire [7:0] sram_data_out;
    wire sram_data_ready;
    reg [15:0] sram_data_addr;
    reg [7:0] sram_data_in;
    reg sram_data_read, sram_data_write;
    
    // Señales de stack
    wire [7:0] stack_data_out;
    wire [15:0] stack_data_16_out;
    wire [15:0] stack_pointer;
    reg stack_push, stack_pop;
    reg stack_push_16bit, stack_pop_16bit;
    reg [7:0] stack_data_in;
    reg [15:0] stack_data_16_in;
    
    // Señales de interrupciones
    wire interrupt_request;
    wire [5:0] interrupt_vector;
    reg interrupt_ack;
    reg return_from_interrupt;
    wire interrupt_in_progress;
    
    // Señales I/O
    reg [7:0] io_registers [0:63];
    wire [7:0] io_data_out;
    reg [5:0] io_addr;
    reg [7:0] io_data_in;
    reg io_read, io_write;
    
    // Variables auxiliares
    integer i;
    
    // Instanciación del decodificador expandido
    axioma_decoder_v2 decoder_inst (
        .clk(clk),
        .reset_n(reset_n),
        .instruction(instruction_reg),
        .instruction_valid(instruction_valid),
        .rs1_addr(dec_rs1_addr),
        .rs2_addr(dec_rs2_addr),
        .rd_addr(dec_rd_addr),
        .rd_write_en(dec_rd_write_en),
        .alu_op(dec_alu_op),
        .alu_use_immediate(dec_alu_use_immediate),
        .immediate(dec_immediate),
        .mem_read(dec_mem_read),
        .mem_write(dec_mem_write),
        .mem_mode(dec_mem_mode),
        .use_pointer(dec_use_pointer),
        .pointer_sel(dec_pointer_sel),
        .pointer_post_inc(dec_pointer_post_inc),
        .pointer_pre_dec(dec_pointer_pre_dec),
        .stack_push(dec_stack_push),
        .stack_pop(dec_stack_pop),
        .stack_push_pc(dec_stack_push_pc),
        .stack_pop_pc(dec_stack_pop_pc),
        .branch_en(dec_branch_en),
        .branch_condition(dec_branch_condition),
        .branch_offset(dec_branch_offset),
        .jump_en(dec_jump_en),
        .jump_addr(dec_jump_addr),
        .call_en(dec_call_en),
        .ret_en(dec_ret_en),
        .io_read(dec_io_read),
        .io_write(dec_io_write),
        .io_addr(dec_io_addr),
        .bit_set(dec_bit_set),
        .bit_clear(dec_bit_clear),
        .bit_num(dec_bit_num),
        .sreg_update(dec_sreg_update),
        .sreg_mask(dec_sreg_mask),
        .instruction_decoded(dec_instruction_decoded),
        .unsupported_instruction(dec_unsupported_instruction)
    );
    
    // Instanciación del banco de registros
    axioma_registers registers_inst (
        .clk(clk),
        .reset_n(reset_n),
        .rs1_addr(dec_rs1_addr),
        .rs1_data(reg_rs1_data),
        .rs2_addr(dec_rs2_addr),
        .rs2_data(reg_rs2_data),
        .rd_addr(dec_rd_addr),
        .rd_data(reg_rd_data),
        .rd_write_en(reg_rd_write_en),
        .x_pointer(reg_x_pointer),
        .y_pointer(reg_y_pointer),
        .z_pointer(reg_z_pointer),
        .x_pointer_in(16'h0000),
        .y_pointer_in(16'h0000),
        .z_pointer_in(16'h0000),
        .x_write_en(1'b0),
        .y_write_en(1'b0),
        .z_write_en(1'b0)
    );
    
    // Instanciación de la ALU
    axioma_alu alu_inst (
        .clk(clk),
        .reset_n(reset_n),
        .operand_a(reg_rs1_data),
        .operand_b(alu_operand_b),
        .alu_op(dec_alu_op),
        .flag_c_in(sreg_c),
        .flag_z_in(sreg_z),
        .flag_n_in(sreg_n),
        .flag_v_in(sreg_v),
        .flag_s_in(sreg_s),
        .flag_h_in(sreg_h),
        .result(alu_result),
        .flag_c_out(alu_flag_c),
        .flag_z_out(alu_flag_z),
        .flag_n_out(alu_flag_n),
        .flag_v_out(alu_flag_v),
        .flag_s_out(alu_flag_s),
        .flag_h_out(alu_flag_h)
    );
    
    // Instanciación del controlador Flash
    axioma_flash_ctrl flash_inst (
        .clk(clk),
        .reset_n(reset_n),
        .prog_addr(pc),
        .prog_data(flash_prog_data),
        .prog_read(flash_prog_read),
        .prog_ready(flash_prog_ready),
        .boot_addr(16'h0000),
        .boot_data(16'h0000),
        .boot_write(1'b0),
        .boot_erase(1'b0),
        .boot_enable(bootloader_enable),
        .boot_ready(),
        .page_buffer_load(1'b0),
        .page_write_enable(1'b0),
        .page_addr(6'h00),
        .flash_busy(),
        .flash_size(),
        .bootloader_active(),
        .debug_last_addr(),
        .debug_last_data()
    );
    
    // Instanciación del controlador SRAM
    axioma_sram_ctrl sram_inst (
        .clk(clk),
        .reset_n(reset_n),
        .data_addr(sram_data_addr),
        .data_in(sram_data_in),
        .data_out(sram_data_out),
        .data_read(sram_data_read),
        .data_write(sram_data_write),
        .data_ready(sram_data_ready),
        .stack_push(stack_push),
        .stack_pop(stack_pop),
        .stack_data_in(stack_data_in),
        .stack_data_out(stack_data_out),
        .stack_push_16bit(stack_push_16bit),
        .stack_pop_16bit(stack_pop_16bit),
        .stack_data_16_in(stack_data_16_in),
        .stack_data_16_out(stack_data_16_out),
        .io_addr(io_addr),
        .io_data_in(io_data_in),
        .io_data_out(io_data_out),
        .io_read(io_read),
        .io_write(io_write),
        .sp_init_value(16'h08FF),
        .sp_init(~reset_n),
        .stack_pointer(stack_pointer),
        .sram_error(),
        .debug_last_addr(),
        .debug_last_data()
    );
    
    // Instanciación del sistema de interrupciones
    axioma_interrupt interrupt_inst (
        .clk(clk),
        .reset_n(reset_n),
        .global_int_enable(sreg_i),
        .interrupt_request(interrupt_request),
        .interrupt_vector(interrupt_vector),
        .interrupt_ack(interrupt_ack),
        .return_from_interrupt(return_from_interrupt),
        .int0_pin(int0_pin),
        .int1_pin(int1_pin),
        .pcint0_pin(1'b0),
        .pcint1_pin(1'b0),
        .pcint2_pin(1'b0),
        .timer0_ovf(1'b0),
        .timer0_compa(1'b0),
        .timer0_compb(1'b0),
        .timer1_ovf(1'b0),
        .timer1_compa(1'b0),
        .timer1_compb(1'b0),
        .timer1_capt(1'b0),
        .timer2_ovf(1'b0),
        .timer2_compa(1'b0),
        .timer2_compb(1'b0),
        .spi_ready(1'b0),
        .usart_rx_complete(1'b0),
        .usart_udre(1'b0),
        .usart_tx_complete(1'b0),
        .adc_complete(1'b0),
        .eeprom_ready(1'b0),
        .analog_comp(1'b0),
        .twi_interrupt(1'b0),
        .spm_ready(1'b0),
        .eimsk_reg(io_registers[6'h3D]),
        .eifr_reg(io_registers[6'h3C]),
        .pcmsk0_reg(8'h00),
        .pcmsk1_reg(8'h00),
        .pcmsk2_reg(8'h00),
        .pcifr_reg(8'h00),
        .pcicr_reg(8'h00),
        .timsk0_reg(8'h00),
        .timsk1_reg(8'h00),
        .timsk2_reg(8'h00),
        .pending_interrupts(),
        .current_priority(),
        .interrupt_in_progress(interrupt_in_progress),
        .debug_last_vector()
    );
    
    // Evaluación de condiciones de branch expandida
    function branch_taken;
        input [3:0] condition;
        input [7:0] sreg_val;
        begin
            case (condition)
                4'b0001: branch_taken = sreg_val[1];      // BREQ: Z=1
                4'b0010: branch_taken = ~sreg_val[1];     // BRNE: Z=0
                4'b0011: branch_taken = sreg_val[0];      // BRCS: C=1
                4'b0100: branch_taken = ~sreg_val[0];     // BRCC: C=0
                4'b0101: branch_taken = sreg_val[2];      // BRMI: N=1
                4'b0110: branch_taken = ~sreg_val[2];     // BRPL: N=0
                4'b0111: branch_taken = sreg_val[3];      // BRVS: V=1
                4'b1000: branch_taken = ~sreg_val[3];     // BRVC: V=0
                4'b1001: branch_taken = sreg_val[4];      // BRLT: S=1
                4'b1010: branch_taken = ~sreg_val[4];     // BRGE: S=0
                default: branch_taken = 1'b0;
            endcase
        end
    endfunction
    
    // Máquina de estados principal expandida
    always @(posedge clk or negedge reset_n) begin
        if (!reset_n) begin
            cpu_state <= STATE_FETCH;
            pc <= 16'h0000;
            instruction_reg <= 16'h0000;
            instruction_valid <= 1'b0;
            sreg <= 8'h00;
            interrupt_ack <= 1'b0;
            return_from_interrupt <= 1'b0;
            flash_prog_read <= 1'b0;
            
            // Inicializar registros I/O críticos
            for (i = 0; i < 64; i = i + 1) begin
                io_registers[i] <= 8'h00;
            end
            
        end else begin
            cpu_state <= next_state;
            interrupt_ack <= 1'b0;
            return_from_interrupt <= 1'b0;
            
            case (cpu_state)
                STATE_FETCH: begin
                    if (interrupt_request && sreg_i && !interrupt_in_progress) begin
                        // Prioridad a interrupción
                        interrupt_return_addr <= pc;
                    end else if (flash_prog_ready) begin
                        instruction_reg <= flash_prog_data;
                        instruction_valid <= 1'b1;
                        flash_prog_read <= 1'b0;
                    end else begin
                        flash_prog_read <= 1'b1;
                    end
                end
                
                STATE_DECODE: begin
                    instruction_valid <= 1'b0;
                    
                    if (dec_instruction_decoded) begin
                        // Actualizar PC
                        if (dec_call_en) begin
                            stack_push_16bit <= 1'b1;
                            stack_data_16_in <= pc + 1;
                            pc <= pc + {{6{dec_jump_addr[11]}}, dec_jump_addr[11:0]};
                        end else if (dec_ret_en) begin
                            stack_pop_16bit <= 1'b1;
                            return_from_interrupt <= (instruction_reg[4:0] == 5'b11000); // RETI
                        end else if (dec_jump_en) begin
                            pc <= pc + {{6{dec_jump_addr[11]}}, dec_jump_addr[11:0]};
                        end else if (dec_branch_en && branch_taken(dec_branch_condition, sreg)) begin
                            pc <= pc + {{4{dec_branch_offset[11]}}, dec_branch_offset};
                        end else begin
                            pc <= pc + 16'h0001;
                        end
                    end
                end
                
                STATE_EXECUTE: begin
                    // Actualizar flags si es operación ALU
                    if (alu_update_flags && dec_sreg_update) begin
                        if (dec_sreg_mask[0]) sreg[0] <= alu_flag_c;
                        if (dec_sreg_mask[1]) sreg[1] <= alu_flag_z;
                        if (dec_sreg_mask[2]) sreg[2] <= alu_flag_n;
                        if (dec_sreg_mask[3]) sreg[3] <= alu_flag_v;
                        if (dec_sreg_mask[4]) sreg[4] <= alu_flag_s;
                        if (dec_sreg_mask[5]) sreg[5] <= alu_flag_h;
                    end
                end
                
                STATE_INTERRUPT: begin
                    if (interrupt_request) begin
                        interrupt_ack <= 1'b1;
                        sreg[7] <= 1'b0; // Clear I flag
                        pc <= {10'h000, interrupt_vector}; // Jump to vector
                    end
                end
                
                STATE_HALT: begin
                    // CPU detenida por instrucción no soportada
                end
            endcase
        end
    end
    
    // Lógica combinacional de siguiente estado
    always @(*) begin
        next_state = cpu_state;
        reg_rd_write_en = 1'b0;
        reg_rd_data = alu_result;
        alu_update_flags = 1'b0;
        
        // Inicializar señales de memoria y stack
        sram_data_read = 1'b0;
        sram_data_write = 1'b0;
        sram_data_addr = 16'h0000;
        sram_data_in = 8'h00;
        stack_push = 1'b0;
        stack_pop = 1'b0;
        stack_push_16bit = 1'b0;
        stack_pop_16bit = 1'b0;
        stack_data_in = 8'h00;
        stack_data_16_in = 16'h0000;
        io_read = 1'b0;
        io_write = 1'b0;
        io_addr = 6'h00;
        io_data_in = 8'h00;
        
        case (cpu_state)
            STATE_FETCH: begin
                if (interrupt_request && sreg_i && !interrupt_in_progress) begin
                    next_state = STATE_INTERRUPT;
                end else if (flash_prog_ready) begin
                    next_state = STATE_DECODE;
                end
            end
            
            STATE_DECODE: begin
                if (dec_instruction_decoded) begin
                    next_state = STATE_EXECUTE;
                end else if (dec_unsupported_instruction) begin
                    next_state = STATE_HALT;
                end else begin
                    next_state = STATE_FETCH;
                end
            end
            
            STATE_EXECUTE: begin
                // Habilitar escritura de registro si es necesario
                if (dec_rd_write_en) begin
                    reg_rd_write_en = 1'b1;
                    alu_update_flags = 1'b1;
                end
                
                // Operaciones de memoria
                if (dec_mem_read || dec_mem_write) begin
                    next_state = STATE_MEMORY;
                end else if (dec_stack_push || dec_stack_pop) begin
                    stack_push = dec_stack_push;
                    stack_pop = dec_stack_pop;
                    stack_data_in = reg_rs1_data;
                    next_state = STATE_FETCH;
                end else begin
                    next_state = STATE_FETCH;
                end
            end
            
            STATE_MEMORY: begin
                if (sram_data_ready) begin
                    next_state = STATE_FETCH;
                end
            end
            
            STATE_INTERRUPT: begin
                next_state = STATE_FETCH;
            end
            
            STATE_HALT: begin
                next_state = STATE_HALT;
            end
        endcase
    end
    
    // Asignaciones de salida
    assign cpu_halted = (cpu_state == STATE_HALT);
    assign status_reg = sreg;
    assign debug_pc = pc;
    assign debug_instruction = instruction_reg;
    assign debug_stack_pointer = stack_pointer;
    assign debug_sreg = sreg;
    assign debug_interrupt_active = interrupt_in_progress;
    
    // Por ahora, pines GPIO sin implementar
    assign portb_out = 8'h00;
    assign portb_ddr = 8'h00;
    assign portc_out = 8'h00;
    assign portc_ddr = 8'h00;
    assign portd_out = 8'h00;
    assign portd_ddr = 8'h00;
    assign uart_tx = 1'b1;
    assign spi_mosi = 1'b0;
    assign spi_sck = 1'b0;
    assign spi_ss = 1'b1;
    assign watchdog_reset = 1'b0;

endmodule

`default_nettype wire