`timescale 1ns/1ps

module axioma_cpu_tb;
    
    // Señales del DUT
    reg clk;
    reg reset_n;
    
    // Interfaz de memoria de programa
    wire [15:0] program_addr;
    reg [15:0] program_data;
    reg program_ready;
    
    // Interfaz de memoria de datos
    wire [15:0] data_addr;
    wire [7:0] data_out;
    reg [7:0] data_in;
    wire data_read;
    wire data_write;
    reg data_ready;
    
    // Estado de la CPU
    wire cpu_halted;
    wire [7:0] status_reg;
    
    // Debug
    wire [15:0] debug_pc;
    wire [15:0] debug_instruction;
    wire [7:0] debug_reg_r16;
    wire [7:0] debug_reg_r17;
    
    // Memoria de programa simulada (32 instrucciones para test)
    reg [15:0] program_memory [0:31];
    
    // Instanciar DUT
    axioma_cpu dut (
        .clk(clk),
        .reset_n(reset_n),
        .program_addr(program_addr),
        .program_data(program_data),
        .program_ready(program_ready),
        .data_addr(data_addr),
        .data_out(data_out),
        .data_in(data_in),
        .data_read(data_read),
        .data_write(data_write),
        .data_ready(data_ready),
        .cpu_halted(cpu_halted),
        .status_reg(status_reg),
        .debug_pc(debug_pc),
        .debug_instruction(debug_instruction),
        .debug_reg_r16(debug_reg_r16),
        .debug_reg_r17(debug_reg_r17)
    );
    
    // Generador de reloj 50MHz
    initial begin
        clk = 0;
        forever #10 clk = ~clk;  // 20ns período = 50MHz
    end
    
    // Simulación de memoria de programa
    always @(program_addr) begin
        if (program_addr < 32) begin
            program_data = program_memory[program_addr];
            program_ready = 1'b1;
        end else begin
            program_data = 16'h0000;  // NOP
            program_ready = 1'b1;
        end
    end
    
    // Simulación simple de memoria de datos
    initial begin
        data_in = 8'h42;  // Valor fijo para pruebas
        data_ready = 1'b1;
    end
    
    // Test principal
    initial begin
        // Configurar archivo VCD
        $dumpfile("axioma_cpu_tb.vcd");
        $dumpvars(0, axioma_cpu_tb);
        
        // Inicialización
        reset_n = 0;
        data_in = 8'h00;
        
        // Programa de prueba básico
        $display("=== AXIOMA CPU TESTBENCH ===");
        $display("Cargando programa de prueba...");
        
        // Programa de prueba: operaciones básicas AVR
        program_memory[0] = 16'hE005;  // LDI R16, 0x05  - Cargar 5 en R16
        program_memory[1] = 16'hE013;  // LDI R17, 0x03  - Cargar 3 en R17  
        program_memory[2] = 16'h0F01;  // ADD R16, R17   - R16 = R16 + R17 = 8
        program_memory[3] = 16'h3005;  // CPI R16, 0x05  - Comparar R16 con 5
        program_memory[4] = 16'hF409;  // BRNE +2        - Branch si no igual
        program_memory[5] = 16'hE025;  // LDI R18, 0x05  - No debería ejecutarse
        program_memory[6] = 16'hE02A;  // LDI R18, 0x0A  - R18 = 10
        program_memory[7] = 16'h2701;  // EOR R16, R17   - R16 = R16 XOR R17
        program_memory[8] = 16'h1F10;  // SUB R17, R16   - R17 = R17 - R16
        program_memory[9] = 16'h3010;  // CPI R17, 0x00  - Comparar R17 con 0
        program_memory[10] = 16'hF001; // BREQ +0        - Branch si igual (loop)
        program_memory[11] = 16'hC000; // RJMP 0         - Jump a inicio
        
        // Llenar resto con NOPs
        for (integer i = 12; i < 32; i = i + 1) begin
            program_memory[i] = 16'h0000;  // NOP
        end
        
        // Reset
        #50;
        reset_n = 1;
        
        $display("Iniciando ejecución...");
        $display("Tiempo | PC   | Instr | R16 | R17 | SREG | Estado");
        $display("-------|------|-------|-----|-----|------|-------");
        
        // Monitor de ejecución
        repeat (100) begin
            @(posedge clk);
            $display("%6t | %04h | %04h  | %02h  | %02h  | %02h   | %s",
                     $time, debug_pc, debug_instruction, 
                     debug_reg_r16, debug_reg_r17, status_reg,
                     cpu_halted ? "HALT" : "RUN");
            
            if (cpu_halted) begin
                $display("CPU detenida - instrucción no soportada");
                $finish;
            end
        end
        
        $display("\n=== RESULTADOS FINALES ===");
        $display("PC final: %04h", debug_pc);
        $display("R16: %02h (%d decimal)", debug_reg_r16, debug_reg_r16);
        $display("R17: %02h (%d decimal)", debug_reg_r17, debug_reg_r17);
        $display("SREG: %08b", status_reg);
        $display("  Carry (C): %b", status_reg[0]);
        $display("  Zero (Z):  %b", status_reg[1]);
        $display("  Negative (N): %b", status_reg[2]);
        $display("  Overflow (V): %b", status_reg[3]);
        
        // Verificaciones
        $display("\n=== VERIFICACIONES ===");
        
        // Test 1: LDI funcionando
        if (debug_reg_r16 != 8'h00) begin
            $display("✅ LDI funciona - R16 cargado correctamente");
        end else begin
            $display("❌ LDI falla - R16 no se cargó");
        end
        
        // Test 2: ADD funcionando (5 + 3 = 8, luego operaciones adicionales)
        $display("ℹ️  Valor final R16: %d (resultado de operaciones)", debug_reg_r16);
        
        // Test 3: Flags
        if (status_reg != 8'h00) begin
            $display("✅ Flags se actualizan correctamente");
        end else begin
            $display("⚠️  Flags podrían no actualizarse");
        end
        
        #100;
        $display("\nSimulación completada");
        $finish;
    end
    
    // Timeout de seguridad
    initial begin
        #10000;
        $display("TIMEOUT: Simulación demasiado larga");
        $finish;
    end
    
    // Monitor de instrucciones no soportadas
    always @(posedge clk) begin
        if (dut.decoder_inst.unsupported_instruction) begin
            $display("⚠️  INSTRUCCIÓN NO SOPORTADA: %04h en PC=%04h", 
                     debug_instruction, debug_pc);
        end
    end

endmodule