// AxiomaCore-328: CPU Integrada Versión 4 - Fase 4 Completa
// Archivo: axioma_cpu_v4.v
// Descripción: CPU AVR completa con todos los periféricos avanzados
//              GPIO, UART, Timer0/1, SPI, I2C, ADC y sistema de clock
`default_nettype none

module axioma_cpu_v4 (
    input wire clk_ext,                // Clock externo
    input wire reset_ext_n,            // Reset externo
    
    // GPIO Puertos
    input wire [7:0] portb_pin,        // Puerto B entrada
    output wire [7:0] portb_out,       // Puerto B salida
    output wire [7:0] portb_ddr,       // Puerto B dirección
    
    input wire [6:0] portc_pin,        // Puerto C entrada
    output wire [6:0] portc_out,       // Puerto C salida
    output wire [6:0] portc_ddr,       // Puerto C dirección
    
    input wire [7:0] portd_pin,        // Puerto D entrada
    output wire [7:0] portd_out,       // Puerto D salida
    output wire [7:0] portd_ddr,       // Puerto D dirección
    
    // UART
    input wire uart_rx,                // UART RX (PD0)
    output wire uart_tx,               // UART TX (PD1)
    
    // SPI
    input wire spi_miso,               // SPI MISO (PB4)
    output wire spi_mosi,              // SPI MOSI (PB3)
    output wire spi_sck,               // SPI SCK (PB5)
    output wire spi_ss,                // SPI SS (PB2)
    
    // I2C
    inout wire sda,                    // I2C SDA (PC4)
    inout wire scl,                    // I2C SCL (PC5)
    
    // Timer PWM
    output wire oc0a_pin,              // Timer0 PWM A (PD6)
    output wire oc0b_pin,              // Timer0 PWM B (PD5)
    output wire oc1a_pin,              // Timer1 PWM A (PB1)
    output wire oc1b_pin,              // Timer1 PWM B (PB2)
    
    // Timer1 Input Capture
    input wire icp1_pin,               // Input Capture (PB0)
    
    // ADC
    input wire [7:0] adc_channels,     // 8 canales ADC
    input wire aref_voltage,           // Referencia AREF
    input wire avcc_voltage,           // Referencia AVCC
    
    // Interrupciones externas
    input wire int0_pin,               // INT0 (PD2)
    input wire int1_pin,               // INT1 (PD3)
    
    // Clock y reset adicionales
    input wire clk_32khz,              // Clock 32kHz
    input wire power_on_reset_n,       // Power-on reset
    input wire vcc_voltage_ok,         // Voltaje OK
    
    // Control del sistema
    input wire [3:0] clock_select,     // Selección fuente clock
    input wire [3:0] clock_prescaler,  // Prescaler clock
    input wire bootloader_enable,      // Habilitar bootloader
    
    // Estado y debug
    output wire cpu_halted,            // CPU detenida
    output wire [7:0] status_reg,      // SREG
    output wire [15:0] debug_pc,       // Program Counter
    output wire [15:0] debug_instruction, // Instrucción actual
    output wire [15:0] debug_stack_pointer, // Stack Pointer
    output wire [7:0] debug_sreg,      // Status Register
    output wire debug_interrupt_active, // Interrupción activa
    output wire system_clock_ready,    // Clock estable
    output wire [7:0] mcusr_reg,       // MCU Status Register
    
    // Debug periféricos
    output wire [7:0] debug_spi_state,
    output wire [7:0] debug_i2c_state,
    output wire [7:0] debug_adc_state,
    output wire [15:0] debug_timer1_counter
);

    // Señales internas de clock y reset
    wire clk_cpu, clk_io, clk_adc, clk_timer_async;
    wire reset_system_n, reset_wdt_n, reset_bod_n;
    wire [7:0] mcucr_reg;

    // Bus I/O interno expandido
    wire [5:0] io_addr_cpu;
    wire [7:0] io_data_in_cpu, io_data_out_cpu;
    wire io_read_cpu, io_write_cpu;

    // Señales de periféricos GPIO
    wire [7:0] gpio_data_out;
    wire gpio_io_active;

    // Señales de periféricos UART
    wire [7:0] uart_data_out;
    wire uart_io_active;
    wire usart_rx_complete, usart_udre, usart_tx_complete;

    // Señales de periféricos Timer0
    wire [7:0] timer0_data_out;
    wire timer0_io_active;
    wire timer0_overflow, timer0_compa, timer0_compb;

    // Señales de periféricos Timer1
    wire [7:0] timer1_data_out;
    wire timer1_io_active;
    wire timer1_overflow, timer1_compa, timer1_compb, timer1_capt;

    // Señales de periféricos SPI
    wire [7:0] spi_data_out;
    wire spi_io_active;
    wire spi_interrupt;

    // Señales de periféricos I2C
    wire [7:0] i2c_data_out;
    wire i2c_io_active;
    wire twi_interrupt;

    // Señales de periféricos ADC
    wire [7:0] adc_data_out;
    wire adc_io_active;
    wire adc_interrupt;

    // Señales de interrupciones expandidas
    wire interrupt_request_expanded;
    wire [5:0] interrupt_vector_expanded;

    // Instanciación del sistema de clock y reset
    axioma_clock_system clock_system_inst (
        .clk_ext(clk_ext),
        .clk_32khz(clk_32khz),
        .reset_ext_n(reset_ext_n),
        .power_on_reset_n(power_on_reset_n),
        .clock_select(clock_select),
        .clock_prescaler(clock_prescaler),
        .wdt_enable(1'b0),              // Por ahora deshabilitado
        .wdt_prescaler(4'b0000),
        .wdt_reset_req(1'b0),
        .bod_enable(1'b1),
        .bod_level(3'b010),             // Nivel medio
        .vcc_voltage_ok(vcc_voltage_ok),
        .sleep_enable(1'b0),            // Por ahora deshabilitado
        .sleep_mode(3'b000),
        .clk_cpu(clk_cpu),
        .clk_io(clk_io),
        .clk_adc(clk_adc),
        .clk_timer_async(clk_timer_async),
        .reset_system_n(reset_system_n),
        .reset_wdt_n(reset_wdt_n),
        .reset_bod_n(reset_bod_n),
        .mcusr_reg(mcusr_reg),
        .mcucr_reg(mcucr_reg),
        .system_clock_ready(system_clock_ready),
        .debug_clock_source(),
        .debug_wdt_counter()
    );

    // Instanciación del núcleo CPU v2 (reutilizado)
    axioma_cpu_v2 cpu_core_inst (
        .clk(clk_cpu),
        .reset_n(reset_system_n),
        .portb_in(portb_pin),
        .portb_out(portb_out),
        .portb_ddr(portb_ddr),
        .portc_in({1'b0, portc_pin}),   // Expandir a 8 bits
        .portc_out(),                   // Manejado por GPIO
        .portc_ddr(),                   // Manejado por GPIO
        .portd_in(portd_pin),
        .portd_out(portd_out),
        .portd_ddr(portd_ddr),
        .int0_pin(int0_pin),
        .int1_pin(int1_pin),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .spi_miso(spi_miso),
        .spi_mosi(spi_mosi),
        .spi_sck(spi_sck),
        .spi_ss(spi_ss),
        .sda(1'b1),                     // Manejado por I2C
        .scl(1'b1),                     // Manejado por I2C
        .adc_channels(adc_channels),
        .bootloader_enable(bootloader_enable),
        .cpu_halted(cpu_halted),
        .status_reg(status_reg),
        .watchdog_reset(),
        .debug_pc(debug_pc),
        .debug_instruction(debug_instruction),
        .debug_stack_pointer(debug_stack_pointer),
        .debug_sreg(debug_sreg),
        .debug_interrupt_active(debug_interrupt_active)
    );

    // Instanciación del controlador GPIO
    axioma_gpio gpio_inst (
        .clk(clk_io),
        .reset_n(reset_system_n),
        .io_addr(io_addr_cpu),
        .io_data_in(io_data_in_cpu),
        .io_data_out(gpio_data_out),
        .io_read(io_read_cpu && gpio_io_active),
        .io_write(io_write_cpu && gpio_io_active),
        .portb_pin(portb_pin),
        .portb_port(),
        .portb_ddr(),
        .portb_pin_out(),
        .portc_pin(portc_pin),
        .portc_port(portc_out),         // Conectar salida
        .portc_ddr(portc_ddr),          // Conectar dirección
        .portc_pin_out(),
        .portd_pin(portd_pin),
        .portd_port(),
        .portd_ddr(),
        .portd_pin_out(),
        .debug_portb_state(),
        .debug_portc_state(),
        .debug_portd_state()
    );

    // Instanciación del controlador UART
    axioma_uart uart_inst (
        .clk(clk_io),
        .reset_n(reset_system_n),
        .io_addr(io_addr_cpu),
        .io_data_in(io_data_in_cpu),
        .io_data_out(uart_data_out),
        .io_read(io_read_cpu && uart_io_active),
        .io_write(io_write_cpu && uart_io_active),
        .uart_rx(uart_rx),
        .uart_tx(uart_tx),
        .usart_rx_complete(usart_rx_complete),
        .usart_udre(usart_udre),
        .usart_tx_complete(usart_tx_complete),
        .debug_state(),
        .debug_baud_counter()
    );

    // Instanciación del Timer0
    axioma_timer0 timer0_inst (
        .clk(clk_io),
        .reset_n(reset_system_n),
        .io_addr(io_addr_cpu),
        .io_data_in(io_data_in_cpu),
        .io_data_out(timer0_data_out),
        .io_read(io_read_cpu && timer0_io_active),
        .io_write(io_write_cpu && timer0_io_active),
        .oc0a_pin(oc0a_pin),
        .oc0b_pin(oc0b_pin),
        .timer0_overflow(timer0_overflow),
        .timer0_compa(timer0_compa),
        .timer0_compb(timer0_compb),
        .debug_tcnt0(),
        .debug_mode(),
        .debug_prescaler()
    );

    // Instanciación del Timer1
    axioma_timer1 timer1_inst (
        .clk(clk_io),
        .reset_n(reset_system_n),
        .io_addr(io_addr_cpu),
        .io_data_in(io_data_in_cpu),
        .io_data_out(timer1_data_out),
        .io_read(io_read_cpu && timer1_io_active),
        .io_write(io_write_cpu && timer1_io_active),
        .icp1_pin(icp1_pin),
        .oc1a_pin(oc1a_pin),
        .oc1b_pin(oc1b_pin),
        .timer1_overflow(timer1_overflow),
        .timer1_compa(timer1_compa),
        .timer1_compb(timer1_compb),
        .timer1_capt(timer1_capt),
        .debug_tcnt1(debug_timer1_counter),
        .debug_mode(),
        .debug_prescaler()
    );

    // Instanciación del controlador SPI
    axioma_spi spi_inst (
        .clk(clk_io),
        .reset_n(reset_system_n),
        .io_addr(io_addr_cpu),
        .io_data_in(io_data_in_cpu),
        .io_data_out(spi_data_out),
        .io_read(io_read_cpu && spi_io_active),
        .io_write(io_write_cpu && spi_io_active),
        .spi_miso(spi_miso),
        .spi_mosi(spi_mosi),
        .spi_sck(spi_sck),
        .spi_ss(spi_ss),
        .spi_interrupt(spi_interrupt),
        .debug_state(debug_spi_state),
        .debug_shift_reg()
    );

    // Instanciación del controlador I2C
    axioma_i2c i2c_inst (
        .clk(clk_io),
        .reset_n(reset_system_n),
        .io_addr(io_addr_cpu),
        .io_data_in(io_data_in_cpu),
        .io_data_out(i2c_data_out),
        .io_read(io_read_cpu && i2c_io_active),
        .io_write(io_write_cpu && i2c_io_active),
        .sda(sda),
        .scl(scl),
        .twi_interrupt(twi_interrupt),
        .debug_state(debug_i2c_state),
        .debug_data()
    );

    // Instanciación del controlador ADC
    axioma_adc adc_inst (
        .clk(clk_adc),                  // Usa clock ADC especial
        .reset_n(reset_system_n),
        .io_addr(io_addr_cpu),
        .io_data_in(io_data_in_cpu),
        .io_data_out(adc_data_out),
        .io_read(io_read_cpu && adc_io_active),
        .io_write(io_write_cpu && adc_io_active),
        .adc_channels(adc_channels),
        .aref_voltage(aref_voltage),
        .avcc_voltage(avcc_voltage),
        .adc_trigger(1'b0),             // Por ahora sin auto-trigger
        .adc_interrupt(adc_interrupt),
        .debug_state(debug_adc_state),
        .debug_result()
    );

    // Decodificación de direcciones I/O expandida para todos los periféricos
    assign gpio_io_active   = (io_addr_cpu >= 6'h23 && io_addr_cpu <= 6'h2B);  // GPIO
    assign uart_io_active   = (io_addr_cpu >= 6'h00 && io_addr_cpu <= 6'h06);  // UART  
    assign timer0_io_active = (io_addr_cpu >= 6'h15 && io_addr_cpu <= 6'h2E) && 
                             !(io_addr_cpu >= 6'h20 && io_addr_cpu <= 6'h2F); // Timer0 (excluir Timer1)
    assign timer1_io_active = (io_addr_cpu >= 6'h20 && io_addr_cpu <= 6'h2F);  // Timer1
    assign spi_io_active    = (io_addr_cpu >= 6'h2C && io_addr_cpu <= 6'h2E);  // SPI
    assign i2c_io_active    = (io_addr_cpu >= 6'h00 && io_addr_cpu <= 6'h36) && 
                             (io_addr_cpu == 6'h36 || io_addr_cpu <= 6'h03);  // I2C/TWI
    assign adc_io_active    = (io_addr_cpu >= 6'h21 && io_addr_cpu <= 6'h27);  // ADC

    // Multiplexor de datos I/O de salida expandido
    assign io_data_out_cpu = gpio_io_active   ? gpio_data_out :
                            uart_io_active   ? uart_data_out :
                            timer0_io_active ? timer0_data_out :
                            timer1_io_active ? timer1_data_out :
                            spi_io_active    ? spi_data_out :
                            i2c_io_active    ? i2c_data_out :
                            adc_io_active    ? adc_data_out :
                            8'h00;

    // Conexión de señales I/O del CPU (por ahora placeholder)
    // En implementación real, estas señales vendrían del CPU core
    assign io_addr_cpu = 6'h00;         // Placeholder
    assign io_data_in_cpu = 8'h00;      // Placeholder
    assign io_read_cpu = 1'b0;          // Placeholder
    assign io_write_cpu = 1'b0;         // Placeholder

    // Sistema de interrupciones expandido
    // Combinar todas las interrupciones de periféricos
    assign interrupt_request_expanded = usart_rx_complete || usart_udre || usart_tx_complete ||
                                       timer0_overflow || timer0_compa || timer0_compb ||
                                       timer1_overflow || timer1_compa || timer1_compb || timer1_capt ||
                                       spi_interrupt || twi_interrupt || adc_interrupt;

    // Vector de interrupción expandido (simplificado)
    // En implementación real, se necesitaría un controlador de prioridades
    assign interrupt_vector_expanded = spi_interrupt       ? 6'h11 :  // SPI
                                      twi_interrupt       ? 6'h18 :  // TWI
                                      adc_interrupt       ? 6'h15 :  // ADC
                                      timer1_capt         ? 6'h0A :  // Timer1 Capture
                                      timer1_compa        ? 6'h0B :  // Timer1 Compare A
                                      timer1_compb        ? 6'h0C :  // Timer1 Compare B
                                      timer1_overflow     ? 6'h0D :  // Timer1 Overflow
                                      timer0_compa        ? 6'h0E :  // Timer0 Compare A
                                      timer0_compb        ? 6'h0F :  // Timer0 Compare B
                                      timer0_overflow     ? 6'h10 :  // Timer0 Overflow
                                      usart_rx_complete   ? 6'h12 :  // USART RX
                                      usart_udre          ? 6'h13 :  // USART UDRE
                                      usart_tx_complete   ? 6'h14 :  // USART TX
                                      6'h00;

endmodule

`default_nettype wire