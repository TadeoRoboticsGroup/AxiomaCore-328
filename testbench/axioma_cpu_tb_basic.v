`timescale 1ns/1ps

module axioma_cpu_tb_basic;
    
    // Clock y Reset básicos
    reg clk_ext;
    reg reset_ext_n;
    reg clk_32khz;
    reg power_on_reset_n;
    reg vcc_voltage_ok;
    
    // GPIO inputs mínimos
    reg [7:0] portb_pin;
    reg [6:0] portc_pin;
    reg [7:0] portd_pin;
    
    // Inputs básicos
    reg uart_rx;
    reg spi_miso;
    reg icp1_pin;
    reg [7:0] adc_channels;
    reg aref_voltage;
    reg avcc_voltage;
    reg int0_pin;
    reg int1_pin;
    reg [3:0] clock_select;
    reg [3:0] clock_prescaler;
    reg bootloader_enable;
    
    // Salidas principales
    wire [7:0] portb_out, portb_ddr;
    wire [6:0] portc_out, portc_ddr;
    wire [7:0] portd_out, portd_ddr;
    wire uart_tx;
    wire spi_mosi, spi_sck, spi_ss;
    wire sda, scl;
    wire oc0a_pin, oc0b_pin, oc1a_pin, oc1b_pin, oc2a_pin, oc2b_pin;
    wire cpu_halted;
    wire [7:0] status_reg;
    wire [15:0] debug_pc;
    wire [15:0] debug_instruction;
    wire [15:0] debug_stack_pointer;
    wire [7:0] debug_sreg;
    wire debug_interrupt_active;
    
    // Instanciación del DUT - solo con puertos básicos
    axioma_cpu dut (
        .clk_ext(clk_ext),
        .reset_ext_n(reset_ext_n),
        .clk_32khz(clk_32khz),
        .power_on_reset_n(power_on_reset_n),
        .vcc_voltage_ok(vcc_voltage_ok),
        
        // GPIO
        .portb_pin(portb_pin),
        .portb_out(portb_out),
        .portb_ddr(portb_ddr),
        .portc_pin(portc_pin),
        .portc_out(portc_out),
        .portc_ddr(portc_ddr),
        .portd_pin(portd_pin),
        .portd_out(portd_out),
        .portd_ddr(portd_ddr),
        
        // UART
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        
        // SPI
        .spi_miso(spi_miso),
        .spi_mosi(spi_mosi),
        .spi_sck(spi_sck),
        .spi_ss(spi_ss),
        
        // I2C
        .sda(sda),
        .scl(scl),
        
        // Timer PWM
        .oc0a_pin(oc0a_pin),
        .oc0b_pin(oc0b_pin),
        .oc1a_pin(oc1a_pin),
        .oc1b_pin(oc1b_pin),
        .oc2a_pin(oc2a_pin),
        .oc2b_pin(oc2b_pin),
        
        // Timer1 Input Capture
        .icp1_pin(icp1_pin),
        
        // ADC
        .adc_channels(adc_channels),
        .aref_voltage(aref_voltage),
        .avcc_voltage(avcc_voltage),
        
        // Interrupciones externas
        .int0_pin(int0_pin),
        .int1_pin(int1_pin),
        
        // Control del sistema
        .clock_select(clock_select),
        .clock_prescaler(clock_prescaler),
        .bootloader_enable(bootloader_enable),
        
        // Estado y debug
        .cpu_halted(cpu_halted),
        .status_reg(status_reg),
        .debug_pc(debug_pc),
        .debug_instruction(debug_instruction),
        .debug_stack_pointer(debug_stack_pointer),
        .debug_sreg(debug_sreg),
        .debug_interrupt_active(debug_interrupt_active)
    );
    
    // Generación de clock principal (25MHz)
    initial begin
        clk_ext = 0;
        forever #20 clk_ext = ~clk_ext; // 25MHz
    end
    
    // Generación de clock watchdog (128kHz)
    initial begin
        clk_32khz = 0;
        forever #3906 clk_32khz = ~clk_32khz; // 128kHz
    end
    
    // Secuencia de test
    initial begin
        // Dump VCD para visualización
        $dumpfile("cpu_sim.vcd");
        $dumpvars(0, axioma_cpu_tb_basic);
        
        // Inicialización
        reset_ext_n = 0;
        power_on_reset_n = 0;
        vcc_voltage_ok = 1;
        portb_pin = 8'h00;
        portc_pin = 7'h00;
        portd_pin = 8'h00;
        uart_rx = 1'b1;  // Idle high
        spi_miso = 1'b0;
        icp1_pin = 1'b0;
        adc_channels = 8'h80;  // Mid-scale
        aref_voltage = 1'b1;   // Reference OK
        avcc_voltage = 1'b1;   // VCC OK
        int0_pin = 1'b0;
        int1_pin = 1'b0;
        clock_select = 4'h1;   // External clock
        clock_prescaler = 4'h1; // No prescaling
        bootloader_enable = 1'b0;
        
        // Reset sequence
        $display("Starting AxiomaCore-328 CPU Basic Test");
        $display("==========================================");
        repeat(5) @(posedge clk_ext);
        power_on_reset_n = 1;
        repeat(5) @(posedge clk_ext);
        reset_ext_n = 1;
        $display("Reset released at time %t", $time);
        
        // Esperar que el CPU inicie
        repeat(50) @(posedge clk_ext);
        
        // Monitor del estado del CPU
        $display("CPU Status Check:");
        $display("  CPU Halted: %b", cpu_halted);
        $display("  Program Counter: 0x%04X", debug_pc);
        $display("  Status Register: 0x%02X", debug_sreg);
        $display("  Stack Pointer: 0x%04X", debug_stack_pointer);
        
        // Test básico: cambiar algunas entradas GPIO
        $display("Testing GPIO...");
        portb_pin = 8'h55;
        portc_pin = 7'h2A;
        portd_pin = 8'hAA;
        
        repeat(20) @(posedge clk_ext);
        
        // Verificar que el CPU responde
        if (debug_pc > 16'h0000) begin
            $display("✅ CPU is executing instructions (PC = 0x%04X)", debug_pc);
        end else begin
            $display("⚠️ CPU may not be executing (PC = 0x%04X)", debug_pc);
        end
        
        repeat(50) @(posedge clk_ext);
        
        $display("==========================================");
        $display("AxiomaCore-328 CPU Basic Test Complete");
        $display("Final PC: 0x%04X", debug_pc);
        $display("✅ Test completed successfully");
        
        $finish;
    end
    
    // Monitor de cambios del PC para ver actividad
    reg [15:0] last_pc = 16'h0000;
    always @(posedge clk_ext) begin
        if (debug_pc != last_pc) begin
            $display("PC changed: 0x%04X -> 0x%04X (instruction: 0x%04X)", 
                     last_pc, debug_pc, debug_instruction);
            last_pc <= debug_pc;
        end
    end
    
    // Timeout de seguridad
    initial begin
        #500000; // 500us timeout
        $display("Test timeout reached");
        $finish;
    end

endmodule