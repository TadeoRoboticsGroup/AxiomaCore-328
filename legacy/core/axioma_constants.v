// AxiomaCore-328: Constantes Globales
// Archivo: axioma_constants.v
// Descripción: Definiciones centralizadas para todo el proyecto
// Compatible: ATmega328P
`default_nettype none

// =============================================================================
// PRESCALER CONSTANTS - Compartidos por todos los timers
// =============================================================================
`define PRESCALE_STOP     3'b000  // Timer stopped
`define PRESCALE_1        3'b001  // No prescaling (clk)
`define PRESCALE_8        3'b010  // clk/8
`define PRESCALE_64       3'b011  // clk/64  
`define PRESCALE_256      3'b100  // clk/256
`define PRESCALE_1024     3'b101  // clk/1024
`define PRESCALE_EXT_FALL 3'b110  // External clock, falling edge
`define PRESCALE_EXT_RISE 3'b111  // External clock, rising edge

// =============================================================================
// TIMER MODE CONSTANTS - Para Timer0 y Timer2 (8-bit)
// =============================================================================
`define TIMER_MODE_NORMAL        3'b000  // Normal mode
`define TIMER_MODE_PWM_PHASE     3'b001  // Phase Correct PWM
`define TIMER_MODE_CTC           3'b010  // Clear Timer on Compare
`define TIMER_MODE_PWM_FAST      3'b011  // Fast PWM
`define TIMER_MODE_PWM_PHASE_OCR 3'b101  // Phase Correct PWM, TOP=OCR
`define TIMER_MODE_PWM_FAST_OCR  3'b111  // Fast PWM, TOP=OCR

// =============================================================================
// TIMER1 MODE CONSTANTS - Para Timer1 (16-bit)
// =============================================================================
`define TIMER1_MODE_NORMAL          4'b0000  // Normal, TOP=0xFFFF
`define TIMER1_MODE_PWM_8BIT        4'b0001  // PWM Phase Correct, TOP=0xFF
`define TIMER1_MODE_PWM_9BIT        4'b0010  // PWM Phase Correct, TOP=0x1FF
`define TIMER1_MODE_PWM_10BIT       4'b0011  // PWM Phase Correct, TOP=0x3FF
`define TIMER1_MODE_CTC_OCR         4'b0100  // CTC, TOP=OCR1A
`define TIMER1_MODE_PWM_FAST_8BIT   4'b0101  // Fast PWM, TOP=0xFF
`define TIMER1_MODE_PWM_FAST_9BIT   4'b0110  // Fast PWM, TOP=0x1FF
`define TIMER1_MODE_PWM_FAST_10BIT  4'b0111  // Fast PWM, TOP=0x3FF
`define TIMER1_MODE_PWM_PC_ICR      4'b1000  // PWM Phase/Freq Correct, TOP=ICR1
`define TIMER1_MODE_PWM_PC_OCR      4'b1001  // PWM Phase/Freq Correct, TOP=OCR1A
`define TIMER1_MODE_PWM_PHASE_ICR   4'b1010  // PWM Phase Correct, TOP=ICR1
`define TIMER1_MODE_PWM_PHASE_OCR   4'b1011  // PWM Phase Correct, TOP=OCR1A
`define TIMER1_MODE_CTC_ICR         4'b1100  // CTC, TOP=ICR1
`define TIMER1_MODE_PWM_FAST_ICR    4'b1110  // Fast PWM, TOP=ICR1
`define TIMER1_MODE_PWM_FAST_OCR    4'b1111  // Fast PWM, TOP=OCR1A

// =============================================================================
// COMPARE OUTPUT MODE CONSTANTS
// =============================================================================
`define COM_DISCONNECT    2'b00  // Normal port operation, OC disconnected
`define COM_TOGGLE        2'b01  // Toggle OC on Compare Match
`define COM_CLEAR         2'b10  // Clear OC on Compare Match
`define COM_SET           2'b11  // Set OC on Compare Match

// =============================================================================
// I/O MEMORY MAP CONSTANTS - ATmega328P Compatible
// =============================================================================

// GPIO Ports
`define ADDR_PORTB        6'h25   // 0x25 - Port B Data Register
`define ADDR_DDRB         6'h24   // 0x24 - Port B Data Direction Register
`define ADDR_PINB         6'h23   // 0x23 - Port B Input Pins Register
`define ADDR_PORTC        6'h28   // 0x28 - Port C Data Register
`define ADDR_DDRC         6'h27   // 0x27 - Port C Data Direction Register
`define ADDR_PINC         6'h26   // 0x26 - Port C Input Pins Register
`define ADDR_PORTD        6'h2B   // 0x2B - Port D Data Register
`define ADDR_DDRD         6'h2A   // 0x2A - Port D Data Direction Register
`define ADDR_PIND         6'h29   // 0x29 - Port D Input Pins Register

// Timer0 Registers
`define ADDR_TCNT0        6'h26   // 0x46 - Timer/Counter Register
`define ADDR_TCCR0A       6'h24   // 0x44 - Timer/Counter Control Register A
`define ADDR_TCCR0B       6'h25   // 0x45 - Timer/Counter Control Register B
`define ADDR_OCR0A        6'h27   // 0x47 - Output Compare Register A
`define ADDR_OCR0B        6'h28   // 0x48 - Output Compare Register B
`define ADDR_TIMSK0       6'h2E   // 0x6E - Timer/Counter Interrupt Mask Register
`define ADDR_TIFR0        6'h15   // 0x35 - Timer/Counter Interrupt Flag Register

// Timer1 Registers
`define ADDR_TCNT1L       6'h2C   // 0x84 - Timer/Counter 1 Low
`define ADDR_TCNT1H       6'h2D   // 0x85 - Timer/Counter 1 High
`define ADDR_TCCR1A       6'h20   // 0x80 - Timer/Counter Control Register 1A
`define ADDR_TCCR1B       6'h21   // 0x81 - Timer/Counter Control Register 1B
`define ADDR_TCCR1C       6'h22   // 0x82 - Timer/Counter Control Register 1C
`define ADDR_OCR1AL       6'h28   // 0x88 - Output Compare Register 1A Low
`define ADDR_OCR1AH       6'h29   // 0x89 - Output Compare Register 1A High
`define ADDR_OCR1BL       6'h2A   // 0x8A - Output Compare Register 1B Low
`define ADDR_OCR1BH       6'h2B   // 0x8B - Output Compare Register 1B High
`define ADDR_ICR1L        6'h26   // 0x86 - Input Capture Register 1 Low
`define ADDR_ICR1H        6'h27   // 0x87 - Input Capture Register 1 High
`define ADDR_TIMSK1       6'h2F   // 0x6F - Timer/Counter Interrupt Mask Register 1
`define ADDR_TIFR1        6'h16   // 0x36 - Timer/Counter Interrupt Flag Register 1

// Timer2 Registers
`define ADDR_TCNT2        6'h32   // 0xB2 - Timer/Counter2
`define ADDR_TCCR2A       6'h30   // 0xB0 - Timer/Counter Control Register A
`define ADDR_TCCR2B       6'h31   // 0xB1 - Timer/Counter Control Register B
`define ADDR_OCR2A        6'h33   // 0xB3 - Output Compare Register A
`define ADDR_OCR2B        6'h34   // 0xB4 - Output Compare Register B
`define ADDR_TIMSK2       6'h10   // 0x70 - Timer/Counter Interrupt Mask Register
`define ADDR_TIFR2        6'h17   // 0x37 - Timer/Counter Interrupt Flag Register
`define ADDR_ASSR         6'h36   // 0xB6 - Asynchronous Status Register

// UART Registers
`define ADDR_UDR0         6'h06   // 0xC6 - UART Data Register
`define ADDR_UBRR0L       6'h04   // 0xC4 - UART Baud Rate Low
`define ADDR_UBRR0H       6'h05   // 0xC5 - UART Baud Rate High
`define ADDR_UCSR0A       6'h00   // 0xC0 - UART Control Status Register A
`define ADDR_UCSR0B       6'h01   // 0xC1 - UART Control Status Register B
`define ADDR_UCSR0C       6'h02   // 0xC2 - UART Control Status Register C

// SPI Registers
`define ADDR_SPCR         6'h2C   // 0x4C - SPI Control Register
`define ADDR_SPSR         6'h2D   // 0x4D - SPI Status Register
`define ADDR_SPDR         6'h2E   // 0x4E - SPI Data Register

// I2C/TWI Registers
`define ADDR_TWBR         6'h20   // 0xB8 - TWI Bit Rate Register
`define ADDR_TWSR         6'h21   // 0xB9 - TWI Status Register
`define ADDR_TWAR         6'h22   // 0xBA - TWI (Slave) Address Register
`define ADDR_TWDR         6'h23   // 0xBB - TWI Data Register
`define ADDR_TWCR         6'h24   // 0xBC - TWI Control Register
`define ADDR_TWAMR        6'h25   // 0xBD - TWI (Slave) Address Mask Register

// ADC Registers
`define ADDR_ADCL         6'h18   // 0x78 - ADC Data Register Low
`define ADDR_ADCH         6'h19   // 0x79 - ADC Data Register High
`define ADDR_ADCSRA       6'h1A   // 0x7A - ADC Control and Status Register A
`define ADDR_ADCSRB       6'h1B   // 0x7B - ADC Control and Status Register B
`define ADDR_ADMUX        6'h1C   // 0x7C - ADC Multiplexer Selection Register
`define ADDR_DIDR0        6'h1E   // 0x7E - Digital Input Disable Register 0

// Clock and Power Management
`define ADDR_CLKPR        6'h61   // 0x61 - Clock Prescaler Register
`define ADDR_OSCCAL       6'h66   // 0x66 - Oscillator Calibration Register

// Watchdog Timer
`define ADDR_WDTCSR       6'h60   // 0x60 - Watchdog Timer Control Register

// Analog Comparator
`define ADDR_ACSR         6'h30   // 0x50 - Analog Comparator Control and Status Register
`define ADDR_DIDR1        6'h1F   // 0x7F - Digital Input Disable Register 1

// =============================================================================
// SYSTEM CONSTANTS
// =============================================================================
`define SYSTEM_FREQ_HZ    25000000  // 25MHz system frequency
`define AVR_INSTRUCTION_COUNT 131   // Total AVR instructions implemented

// =============================================================================
// DEBUG AND DEVELOPMENT CONSTANTS
// =============================================================================
`define DEBUG_ENABLE      1'b1     // Enable debug outputs
`define VERSION_MAJOR     8'd1     // Major version
`define VERSION_MINOR     8'd0     // Minor version

`default_nettype wire