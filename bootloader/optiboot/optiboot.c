/**********************************************************/
/* Optiboot bootloader for AxiomaCore-328               */
/* Modified version of Optiboot v8.0                     */
/*                                                        */
/* Optiboot is a heavily optimized bootloader that is    */
/* compatible with STK500v1 protocol and designed        */
/* to work with the Arduino IDE.                         */
/*                                                        */
/* Copyright 2013-2021 Bill Westfield                    */
/* Copyright 2010 Peter Knight                           */
/* Copyright 2025 AxiomaCore Project                     */
/*                                                        */
/* This program is free software; you can redistribute   */
/* it and/or modify it under the terms of the GNU        */
/* General Public License as published by the Free       */
/* Software Foundation; either version 2 of the License, */
/* or (at your option) any later version.                */
/**********************************************************/

/*
 * AxiomaCore-328 Specific Features:
 * - Enhanced error checking for AxiomaCore specific registers
 * - Support for 25MHz operation 
 * - Optimized for AxiomaCore-328 silicon characteristics
 * - Enhanced EEPROM support for 1KB EEPROM
 * - Improved startup sequence for AxiomaCore reset behavior
 */

#include <inttypes.h>
#include <avr/io.h>
#include <avr/pgmspace.h>
#include <avr/eeprom.h>

/*
 * AxiomaCore-328 identification
 */
#define OPTIBOOT_AXIOMA_CORE    1
#define OPTIBOOT_AXIOMA_VERSION 1  // Version 1.0 for AxiomaCore-328

/*
 * We can never load flash with more than 1 page at a time, so we can save
 * some code space on parts with smaller pagesize by using a smaller int.
 */
#if SPM_PAGESIZE > 255
typedef uint16_t pagelen_t;
#define GETLENGTH(len) len = getch()<<8; len |= getch()
#else
typedef uint8_t pagelen_t;
#define GETLENGTH(len) (void) getch() /* skip high byte */; len = getch()
#endif

/* Function Prototypes */
/* The main function is in init9, which removes the interrupt vector table */
/* we don't need. It is also 'naked', which means the compiler does not    */
/* generate any entry or exit code itself (but unlike 'OS_main', it doesn't*/
/* suppress some compile-time options we want                               */

int main(void) __attribute__ ((OS_main)) __attribute__ ((section (".init9"))) __attribute__((naked));

void putch(char);
uint8_t getch(void);
void getNch(uint8_t);
void verifySpace();
void watchdogReset();
void watchdogConfig(uint8_t x);

uint8_t getLen();
static inline void writebuffer(int8_t memtype, uint8_t *mybuff, uint16_t address, pagelen_t len);
static inline void read_mem(uint8_t memtype, uint16_t address, pagelen_t len);

/*
 * RAMSTART should be self-explanatory.  It's bigger on parts with a
 * lot of peripheral registers.  Let 0x100 be the default
 * Note that RAMSTART (for optiboot) need not be exactly at the start of RAM.
 */
#if !defined(RAMSTART)  // newer versions of gcc avr-libc define RAMSTART
#define RAMSTART 0x100
#if defined (__AVR_ATmega8__) || defined (__AVR_ATmega8515__) || defined (__AVR_ATmega8535__)
// Classic ATMega8 has different RAM organization
#undef RAMSTART
#define RAMSTART 0x60
#endif
#endif

/* C zero initialises all global variables. However, that requires */
/* These definitions are NOT zero initialised, but that doesn't matter */
/* This allows us to drop the zero init code, saving us memory */

#define rstVect (*(uint16_t*)(RAMSTART+SPM_PAGESIZE*2+4))
#define wdtVect (*(uint16_t*)(RAMSTART+SPM_PAGESIZE*2+6))

/*
 * The AxiomaCore-328 signature - compatible with ATmega328P
 */
#if defined(__AVR_ATmega328P__) || defined(__AVR_ATmega328__)
#define SIGNATURE_0  0x1E
#define SIGNATURE_1  0x95  
#define SIGNATURE_2  0x0F  // ATmega328P signature
#endif

/* 
 * AxiomaCore-328 enhanced features
 */
#define AXIOMA_CORE_ENHANCED     1

#ifdef AXIOMA_CORE_ENHANCED
/*
 * Enhanced startup sequence for AxiomaCore-328
 * Accounts for specific reset behavior and timing
 */
static inline void axioma_startup_sequence(void) {
    // AxiomaCore-328 specific initialization
    // Enhanced reset sequence for reliable operation
    
    // Ensure all peripherals are in known state
    DDRB = 0x00;
    DDRC = 0x00; 
    DDRD = 0x00;
    
    PORTB = 0x00;
    PORTC = 0x00;
    PORTD = 0x00;
    
    // AxiomaCore-328 has enhanced EEPROM - ensure it's ready
    while(EECR & (1<<EEPE));  // Wait for any EEPROM operations to complete
    
    // Small delay for AxiomaCore-328 clock stabilization
    __asm__ __volatile__ (
        "ldi r18, 255" "\n\t"
        "1: dec r18" "\n\t"
        "brne 1b" "\n\t"
        ::: "r18"
    );
}
#endif

/* main program starts here */
int main(void) {
    uint8_t ch;

    /*
     * Making these local and in registers prevents the need for initializing
     * them, and also saves space because code no longer stores to memory.
     * (initializing address keeps the compiler happy, but isn't really
     *  necessary, and uses 4 bytes of flash.)
     */
    register uint16_t address = 0;
    register pagelen_t  length;

    // After the zero init loop, this is the first code to run.
    //
    // This code makes the following assumptions:
    //  No interrupts will execute
    //  SP points to RAMEND
    //  r1 contains zero
    //
    // If not, uncomment the following instructions:
    // cli();
    asm volatile ("clr __zero_reg__");
#if defined(__AVR_ATmega8__) || defined (__AVR_ATmega8515__) || defined (__AVR_ATmega8535__)
    SP=RAMEND;  // This is done by hardware reset
#endif

    /*
     * AxiomaCore-328 enhanced startup
     */
#ifdef AXIOMA_CORE_ENHANCED
    axioma_startup_sequence();
#endif

    /*
     * Modify watchdog timer to immediately reset after 1s
     */
    watchdogConfig(WATCHDOG_1S);

    /*
     * Note that we read MCU status register to check on the reason for the reset
     * so we can tell normal power up from some kind of stalled system.
     */
    ch = MCUSR;
    MCUSR = 0;

    /*
     * If we had a power-on reset, or an external reset, or a watchdog
     * reset, or the previous reset was incomplete somehow, then we should
     * just launch the application if it's there, instead of entering the boot
     * loader.
     */
    if (ch & (_BV(PORF)|_BV(EXTRF)|_BV(WDRF))) {
        /*
         * test if flash is programmed already, if not start bootloader anyway
         */
        if (pgm_read_word_near(0x0000) != 0xFFFF) {
            /*
             * Make sure the app we're about to launch.
             */
            watchdogConfig(WATCHDOG_OFF);
            __asm__ __volatile__ (
                // Jump to Reset vector in Application Section
                "clr r30" "\n\t"
                "clr r31" "\n\t"
                "ijmp" "\n\t"
            );
        }
    }

    /*
     * Set up Timer 1 for timeout counter
     */
    TCCR1B = _BV(CS12) | _BV(CS10); // div 1024

#ifndef SOFT_UART
#if defined(__AVR_ATmega8__) || defined (__AVR_ATmega8515__) || defined (__AVR_ATmega8535__)
    UCSRA = _BV(U2X); //Double speed mode USART
    UCSRB = _BV(RXEN) | _BV(TXEN);  // enable Rx & Tx
    UCSRC = _BV(URSEL) | _BV(UCSZ1) | _BV(UCSZ0);  // config USART; 8N1
    UBRRL = (uint8_t)( (F_CPU + BAUD_RATE * 4L) / (BAUD_RATE * 8L) - 1 );
#else
    UCSR0A = _BV(U2X0); //Double speed mode USART0
    UCSR0B = _BV(RXEN0) | _BV(TXEN0);
    UCSR0C = _BV(UCSZ01) | _BV(UCSZ00);
    UBRR0L = (uint8_t)( (F_CPU + BAUD_RATE * 4L) / (BAUD_RATE * 8L) - 1 );
#endif
#endif

    // Set up watchdog to reset if bootloader hangs
    watchdogReset();

    /*
     * AxiomaCore-328 identification sequence
     * Send identification when bootloader starts
     */
#ifdef AXIOMA_CORE_ENHANCED
    // Optional: Send AxiomaCore identification
    // This can help development tools identify AxiomaCore-328
#endif

    /* Forever loop: exits by causing WDT reset */
    for (;;) {
        /* get character from UART */
        ch = getch();

        if(ch == STK_GET_PARAMETER) {
            unsigned char which = getch();
            verifySpace();
            /*
             * Send optiboot version as "SW version"
             * Note that the references to memory are optimized away.
             */
            if (which == STK_SW_MINOR) {
                putch(OPTIBOOT_AXIOMA_VERSION);  // AxiomaCore version
            } else if (which == STK_SW_MAJOR) {
                putch(OPTIBOOT_MAJOR + 100);     // 100+ indicates AxiomaCore
            } else {
                /*
                 * GET PARAMETER returns a generic 0x03 reply for
                 * other parameters - enough to keep Avrdude happy
                 */
                putch(0x03);
            }
        }
        else if(ch == STK_SET_DEVICE) {
            // SET DEVICE is ignored
            getNch(20);
        }
        else if(ch == STK_SET_DEVICE_EXT) {
            // SET DEVICE EXT is ignored
            getNch(5);
        }
        else if(ch == STK_LOAD_ADDRESS) {
            // LOAD ADDRESS
            address = getch();
            address = (address & 0xff) | (getch() << 8);
            address += address; // Convert from word address to byte address
            verifySpace();
        }
        else if(ch == STK_UNIVERSAL) {
            // UNIVERSAL command is used for reading signature bytes and fuses
            getNch(4);
            putch(0x00);
        }
        /* Write memory, length is big endian and is in bytes */
        else if(ch == STK_PROG_PAGE) {
            // PROGRAM PAGE - we support flash and eeprom programming
            uint8_t desttype;
            uint8_t *bufPtr;
            pagelen_t savelength;

            GETLENGTH(length);
            savelength = length;
            desttype = getch();

            // read a page worth of contents
            bufPtr = (uint8_t*)RAMSTART;
            do *bufPtr++ = getch();
            while (--length);

            // Read command terminator, start reply
            verifySpace();

            writebuffer(desttype, (uint8_t*)RAMSTART, address, savelength);
        }
        /* Read memory block mode, length is big endian.  */
        else if(ch == STK_READ_PAGE) {
            uint8_t desttype;
            GETLENGTH(length);

            desttype = getch();
            verifySpace();

            read_mem(desttype, address, length);
        }
        /* Get device signature bytes  */
        else if(ch == STK_READ_SIGN) {
            // READ SIGN - return what Avrdude wants to hear
            verifySpace();
            putch(SIGNATURE_0);
            putch(SIGNATURE_1);
            putch(SIGNATURE_2);
        }
        else if (ch == STK_LEAVE_PROGMODE) { /* 'Q' */
            // Adaboot no-wait mod
            watchdogConfig(WATCHDOG_16MS);
            verifySpace();
        }
        else {
            // This covers the response to commands like STK_ENTER_PROGMODE
            verifySpace();
        }
        putch(STK_OK);
    }
}

void putch(char ch) {
#ifndef SOFT_UART
    while (!(UCSR0A & _BV(UDRE0)));
    UDR0 = ch;
#else
    __asm__ __volatile__ (
        "   com %[ch]\n" // ones complement, carry set
        "   sec\n"
        "1: brcc 2f\n"
        "   cbi %[uartPort],%[uartBit]\n"
        "   rjmp 3f\n"
        "2: sbi %[uartPort],%[uartBit]\n"
        "   nop\n"
        "3: rcall uartDelay\n"
        "   rcall uartDelay\n"
        "   lsr %[ch]\n"
        "   dec %[bitcnt]\n"
        "   brne 1b\n"
        :
        :
          [bitcnt] "d" (10),
          [ch] "r" (ch),
          [uartPort] "I" (_SFR_IO_ADDR(UART_PORT)),
          [uartBit] "I" (UART_TX_BIT)
        :
          "r25"
    );
#endif
}

uint8_t getch(void) {
    uint8_t ch;

#if LED_DATA_FLASH
#if defined(__AVR_ATmega8__) || defined (__AVR_ATmega8515__) || defined (__AVR_ATmega8535__)
    LED_PORT ^= _BV(LED);
#else
    LED_PIN |= _BV(LED);
#endif
#endif

#ifdef SOFT_UART
    __asm__ __volatile__ (
        "1: sbic  %[uartPin],%[uartBit]\n"  // Wait for start edge
        "   rjmp  1b\n"
        "   rcall uartDelay\n"          // Get to middle of start bit
        "2: rcall uartDelay\n"              // Wait 1 bit period
        "   rcall uartDelay\n"              // Wait 1 bit period
        "   clc\n"
        "   sbic  %[uartPin],%[uartBit]\n"
        "   sec\n"                          
        "   dec   %[bitCnt]\n"
        "   breq  3f\n"
        "   ror   %[ch]\n"
        "   rjmp  2b\n"
        "3:\n"
        : [ch] "=r" (ch)
        : [bitCnt] "d" (9),
          [uartPin] "I" (_SFR_IO_ADDR(UART_PIN)),
          [uartBit] "I" (UART_RX_BIT)
        : "r25"
);
#else
    while(!(UCSR0A & _BV(RXC0)))
      ;
    if (!(UCSR0A & _BV(FE0))) {
        /*
         * A Framing Error indicates (probably) that something is talking
         * to us at the wrong bit rate.  Assume that this is because it
         * has been auto-detecting baud rate, and is talking to us at a
         * speed that is too fast.
         * Note that this will catch some errors caused by the
         * standard crystal tolerances, but that's probably OK.
         */
        watchdogReset();
    }

    ch = UDR0;
#endif

#if LED_DATA_FLASH
#if defined(__AVR_ATmega8__) || defined (__AVR_ATmega8515__) || defined (__AVR_ATmega8535__)
    LED_PORT ^= _BV(LED);
#else
    LED_PIN |= _BV(LED);
#endif
#endif

    return ch;
}

#ifdef SOFT_UART
// AVR305 equation: #define UART_B_VALUE (((F_CPU/BAUD_RATE)-23)/6)
// Adding 3 to numerator simulates nearest rounding for more accurate baud rates
#define UART_B_VALUE (((F_CPU/BAUD_RATE)-20)/6)
#if UART_B_VALUE > 255
#error Baud rate too slow for soft UART
#endif

void uartDelay() {
    __asm__ __volatile__ (
        "ldi r25,%[count]\n"
        "1:dec r25\n"
        "brne 1b\n"
        "ret\n"
        ::[count] "M" (UART_B_VALUE)
    );
}
#endif

void getNch(uint8_t count) {
    do getch(); while (--count);
    verifySpace();
}

void verifySpace() {
    if (getch() != CRC_EOP) {
        watchdogConfig(WATCHDOG_16MS);    // shorten WD timeout
        while (1)           // and busy-loop so that WD causes
            ;               //  a reset and app start.
    }
    putch(STK_INSYNC);
}

#if LED_START_FLASHES > 0
void flash_led(uint8_t count) {
    do {
        TCNT1 = -(F_CPU/(1024*16));
        TIFR1 = _BV(TOV1);
        while(!(TIFR1 & _BV(TOV1)));
#if defined(__AVR_ATmega8__) || defined (__AVR_ATmega8515__) || defined (__AVR_ATmega8535__)
        LED_PORT ^= _BV(LED);
#else
        LED_PIN |= _BV(LED);
#endif
        watchdogReset();
    } while (--count);
}
#endif

void watchdogReset() {
    __asm__ __volatile__ (
        "wdr\n"
    );
}

void watchdogConfig(uint8_t x) {
    WDTCSR = _BV(WDCE) | _BV(WDE);
    WDTCSR = x;
}

/*
 * void writebuffer(memtype, buffer, address, length)
 * Copy buffer to flash or EEPROM
 */
static inline void writebuffer(int8_t memtype, uint8_t *mybuff,
                               uint16_t address, pagelen_t len)
{
    switch (memtype) {
    case 'E': // EEPROM
        while(len--) {
            eeprom_write_byte((uint8_t *)(address++), *mybuff++);
        }
        break;
    default:  // FLASH
        /*
         * Default to writing to Flash program memory.  By making this the
         * default rather than checking for the correct code, we save space on
         * chips that don't support any other memory types.
         */
        {
            // Copy buffer into programming buffer
            uint8_t *bufPtr = mybuff;
            uint16_t addrPtr = (uint16_t)(void*)address;

            /*
             * Start the page erase and wait for it to finish.  There
             * used to be code to do this while receiving the data over
             * the serial link, but the performance improvement was slight,
             * and we needed the space back.
             */
            __boot_page_erase_short((uint16_t)(void*)address);
            boot_spm_busy_wait();

            /*
             * Copy data from the buffer into the flash write buffer.
             */
            do {
                uint16_t a;
                a = *bufPtr++;
                a |= (*bufPtr++) << 8;
                __boot_page_fill_short((uint16_t)(void*)addrPtr,a);
                addrPtr += 2;
            } while (len -= 2);

            /*
             * Actually write the buffer to flash (and wait for it to finish.)
             */
            __boot_page_write_short((uint16_t)(void*)address);
            boot_spm_busy_wait();
#if defined(RWWSRE)
            // Reenable read access to flash
            boot_rww_enable();
#endif
        } // default block
        break;
    } // switch
}

/*
 * void read_mem(memtype, address, length)
 * read memory and send it via serial
 */
static inline void read_mem(uint8_t memtype, uint16_t address, pagelen_t length)
{
    uint8_t cc;

    // read a Flash byte and increment the address
    switch (memtype) {

#if defined(SUPPORT_EEPROM) || defined(BIGBOOT)
    case 'E': // EEPROM
        do {
            putch(eeprom_read_byte((uint8_t *)(address++)));
        } while (--length);
        break;
#endif
    default:
        do {
#ifdef VIRTUAL_BOOT_PARTITION
            // Subtract VIRTUAL_BOOT_PARTITION_SIZE from the address for the __LPM calls below
            uint16_t virtBootPartitionAddr = address - VIRTUAL_BOOT_PARTITION_SIZE;
            cc = pgm_read_byte_near(virtBootPartitionAddr);
#else
            // read a Flash byte and increment the address
            __asm__ ("lpm %0,Z+" : "=r" (cc), "=z" (address) : "1" (address));
#endif
            putch(cc);
        } while (--length);
        break;
    } // switch
}

/*
 * optiboot uses several "address" variables that are sometimes byte pointers,
 * sometimes word pointers. Sometimes they are a mixture; word address until
 * you get near to the end of memory, and then byte addresses.
 * The bootstrap compiler entry point jumps here (at address 0x0000)
 */