/* AxiomaCore-328 - Blink y Serial, el criterio de aceptación de la fase 2
 * SPDX-License-Identifier: Apache-2.0
 *
 * Compilado con avr-gcc y avr-libc SIN MODIFICAR NADA: <avr/io.h>,
 * <avr/interrupt.h> y <util/setbaud.h> son exactamente las que usaría un
 * ATmega328P de verdad. `setbaud.h` calcula el divisor a partir de F_CPU y
 * BAUD y decide él solo si hace falta el modo de doble velocidad — es el
 * mecanismo que usa el core de Arduino, y ejercita de paso que nuestro mapa de
 * registros coincida con el que avr-libc espera.
 *
 * LA VELOCIDAD NO SON 115200, y no es un capricho. A 12,5 MHz ese baudio no
 * sale: el divisor más cercano deja un error del -3,1 %, y una trama 8N1
 * aguanta como mucho un ±2,5 % sumando los dos extremos. A 19200 el error es
 * del -0,76 %. El problema no es la USART sino el reloj, y el reloj es 12,5
 * MHz porque el diseño cierra timing a 14,74: subirlo es la tarea de
 * optimización que ya está en el plan, y arregla las dos cosas a la vez.
 *
 * Un ATmega328P real a 16 MHz tampoco llega limpio a 115200: se queda en
 * +2,1 % usando U2X. Por eso el core de Arduino activa U2X siempre.
 */
#include <avr/io.h>
#include <avr/interrupt.h>

#define BAUD 19200
#include <util/setbaud.h>

/* Timer0 a clk/64: desborda cada 256 * 64 ciclos. */
#define OVF_POR_SEGUNDO  (F_CPU / 64UL / 256UL)

static volatile uint16_t desbordes;

ISR(TIMER0_OVF_vect)
{
    desbordes++;
}

/* Eco de lo que llegue por el puerto serie. Es lo que hace una consola, y es
 * además la única forma de ejercitar el vector USART_RX: hace falta que
 * ALGUIEN transmita hacia el chip. La medida de cobertura lo encontró sin
 * disparar ni una vez. */
ISR(USART_RX_vect)
{
    uint8_t c = UDR0;                  /* leerlo limpia RXC0: la trampa nº 11 */
    while (!(UCSR0A & (1 << UDRE0)))
        ;
    UDR0 = c;
}

static void usart_init(void)
{
    UBRR0H = UBRRH_VALUE;
    UBRR0L = UBRRL_VALUE;
#if USE_2X
    UCSR0A |= (1 << U2X0);
#else
    UCSR0A &= (uint8_t)~(1 << U2X0);
#endif
    UCSR0C = (1 << UCSZ01) | (1 << UCSZ00);   /* 8 bits, sin paridad, 1 parada */
    UCSR0B = (1 << TXEN0) | (1 << RXEN0) | (1 << RXCIE0);
}

/* Espera a que el búfer de transmisión esté libre. UDRE0 dice que cabe otro
 * byte, no que el anterior haya salido entero: es TXC0 el que dice eso. */
static void usart_putchar(char c)
{
    while (!(UCSR0A & (1 << UDRE0)))
        ;
    UDR0 = (uint8_t)c;
}

static void usart_print(const char *s)
{
    while (*s)
        usart_putchar(*s++);
}

int main(void)
{
    DDRB = 0xFF;
    PORTB = 0x00;

    /* PWM por hardware TAMBIÉN en los dos canales del Timer0: OC0A es PD6 —el
     * pin 6 de Arduino— y OC0B es PD5 —el 5—. Los tres canales de un
     * `analogWrite()` que se usan de verdad salen así por pines distintos y
     * con ciclos de trabajo distintos, que es lo que permite al banco
     * distinguir un canal de otro: si el mapa de pines estuviera cruzado, las
     * cifras se intercambiarían.
     *
     * PWM rápido de 8 bits con TOP = MAX, igual que el modo normal de antes:
     * TOV0 se sigue marcando al desbordar, así que la cuenta de medio segundo
     * no cambia. */
    DDRD  |= (1 << DDD6) | (1 << DDD5);       /* el valor se anula; la dirección no */
    TCCR0A = (1 << COM0A1) | (1 << COM0B1) | (1 << WGM01) | (1 << WGM00);
    OCR0A  = 191;                             /* 192 de 256: un 75 % */
    OCR0B  = 31;                              /*  32 de 256: un 12,5 % */
    TCCR0B = (1 << CS01) | (1 << CS00);       /* clk/64 */
    TIMSK0 = (1 << TOIE0);

    /* PWM por hardware en OC1A, que es PB1 — el pin 9 de Arduino. Esto es lo
     * que hace `analogWrite(9, 64)` por dentro: PWM rápido de 8 bits con el pin
     * en modo no invertido, y el ciclo de trabajo en OCR1A.
     *
     * DDRB YA ESTÁ A SALIDA arriba, y hace falta: el temporizador anula el
     * VALOR del pin, nunca su dirección. Un analogWrite() sin pinMode() no saca
     * nada, ni aquí ni en el chip. */
    TCCR1A = (1 << COM1A1) | (1 << COM1B1) | (1 << WGM10);
    TCCR1B = (1 << WGM12) | (1 << CS11);     /* clk/8 */
    OCR1A  = 64;                             /* 64 de 256: un 25 % */
    OCR1B  = 200;                            /* 200 de 256: un 78,5 % */

    /* Y los dos del Timer2, que completan los SEIS canales del 328P: OC2A es
     * PB3 —el pin 11 de Arduino— y OC2B es PD3 —el 3—.
     *
     * El Timer2 tiene prescaler PROPIO y sus bits CS no significan lo mismo:
     * aquí CS=2 es clk/8, igual que en el Timer0, pero CS=4 es clk/64 y no
     * clk/256. Por eso el banco mide el periodo además del ciclo de trabajo.
     *
     * GTCCR.PSRASY pone a cero ESE prescaler y no el de los otros dos. Es lo
     * que se hace antes de arrancar una base de tiempos que tiene que salir en
     * fase. */
    DDRD  |= (1 << DDD3);
    GTCCR  = (1 << PSRASY);
    TCCR2A = (1 << COM2A1) | (1 << COM2B1) | (1 << WGM21) | (1 << WGM20);
    OCR2A  = 95;                             /*  96 de 256: un 37,5 % */
    OCR2B  = 159;                            /* 160 de 256: un 62,5 % */
    TCCR2B = (1 << CS21);                    /* clk/8 */

    /* SPI: una transacción de arranque, como la que configura una pantalla o
     * una tarjeta SD antes de que empiece el programa de verdad.
     *
     * PB5 ES A LA VEZ SCK Y EL LED —en un Arduino Uno también, y por eso el LED
     * parpadea cuando se usa el SPI—. Mientras `SPE` esté puesto, el pin lo
     * conduce el SPI; al soltarlo vuelve a `PORTB5` y el parpadeo sigue como si
     * nada. Que el banco vea las dos cosas es lo que verifica que el SoC
     * encamina el pin al que manda en cada momento.
     *
     * `SS` (PB2) va como SALIDA y se conduce a cero para seleccionar, que es lo
     * que hace cualquier sketch. Con SS como salida, tirarlo abajo NO borra
     * MSTR: la hoja de datos dice que ahí el pin es de propósito general. */
    {
        static const uint8_t trama[3] = { 0xA5, 0x3C, 0x81 };
        uint8_t i;

        PORTB |= (1 << PB2);                  /* SS en alto: nadie seleccionado */
        SPCR = (1 << SPE) | (1 << MSTR) | (1 << SPR0);   /* maestro, fosc/16 */
        PORTB &= (uint8_t)~(1 << PB2);        /* seleccionar */
        for (i = 0; i < sizeof(trama); i++) {
            SPDR = trama[i];
            while (!(SPSR & (1 << SPIF)))
                ;
        }
        PORTB |= (1 << PB2);                  /* soltar la seleccion */
        SPCR = 0;                             /* y los pines: PB5 vuelve al LED */
    }

    /* PD0 y PD1 SON RXD Y TXD, PERO SOLO CON LA USART ENCENDIDA. Antes son dos
     * pines de E/S general como cualquier otro, y aquí se deja PD0 como SALIDA
     * a propósito: al poner `RXEN0`, el hardware tiene que forzarlo a ENTRADA
     * pase lo que pase en `DDRD0`, que es lo que dice la tabla 14-9 de
     * anulaciones del puerto. Y `DDRD1` no se toca en ningún momento: que `TXD`
     * salga es cosa de `TXEN0`, no del programa.
     *
     * Un programa de verdad no hace esto; está aquí para que el banco lo vea en
     * el PIN, que es el único sitio donde se distingue un pin encaminado de un
     * pin que resulta que vale lo mismo. */
    DDRD |= (1 << PD0);

    /* LA USART COMO MAESTRO SPI, que es otro periférico con los mismos
     * registros. Va aquí, ANTES de encender el puerto serie, porque los dos no
     * pueden estar a la vez: `UMSEL` elige, y un programa de verdad hace lo
     * mismo si usa MSPIM para una pantalla y luego suelta el bus.
     *
     * `<avr/io.h>` ya trae `UMSEL01`, `UMSEL00`, `UCPHA0` y `UDORD0`, y `UBRR0`
     * es de 16 bits: esto compila sin tocar nada, que es medio criterio L2.
     *
     * EL ORDEN LO MANDA LA HOJA DE DATOS: `UBRR0` a cero ANTES de habilitar el
     * transmisor, y el divisor de verdad después. Y `DDR_XCK0` a salida es lo
     * que enciende el modo maestro — sin eso no hay reloj, y aquí ese pin es
     * PD4.
     *
     * Modo 3 —`UCPOL`=1, `UCPHA`=1— y el bit más significativo primero, que es
     * lo que usa casi todo el mundo en SPI. Está aquí para que el banco lo vea
     * EN EL PIN: que XCK salga por PD4 y no por otro sitio no lo puede decir el
     * banco del periférico, que no ve el SoC. */
    {
        static const uint8_t trama[3] = { 0x96, 0x5A, 0xC3 };
        uint8_t i;

        UBRR0  = 0;
        DDRD  |= (1 << DDD4);                 /* XCK: la salida enciende el maestro */
        UCSR0C = (1 << UMSEL01) | (1 << UMSEL00) | (1 << UCPHA0) | (1 << UCPOL0);
        UCSR0B = (1 << TXEN0) | (1 << RXEN0);
        UBRR0  = 3;                           /* f_XCK = f_CPU/(2*(3+1)) */

        UCSR0A = (1 << TXC0);                 /* limpiarla escribiendo un uno */
        for (i = 0; i < sizeof(trama); i++) {
            while (!(UCSR0A & (1 << UDRE0)))
                ;
            UDR0 = trama[i];
        }
        while (!(UCSR0A & (1 << TXC0)))       /* que salga la última entera */
            ;

        /* AL APAGAR, EL ORDEN IMPORTA: primero los pines, después el divisor
         * y el modo EL ÚLTIMO. Al revés queda una ventana de dos instrucciones
         * en la que `UMSEL` ya dice «asíncrono» y `UBRR0` todavía es el divisor
         * del SPI, y cualquiera que mire desde fuera —el banco lo hizo— mide un
         * periodo de bit que no existe. El chip no se entera; quien lo observa,
         * sí. */
        UCSR0B = 0;                           /* soltar los pines */
        UBRR0  = 0;
        UCSR0C = 0;
    }

    usart_init();
    sei();

    usart_print("Hola, AxiomaCore-328\r\n");

    for (;;) {
        if (desbordes >= (uint16_t)(OVF_POR_SEGUNDO / 2)) {
            uint8_t sreg = SREG;
            cli();
            desbordes = 0;
            SREG = sreg;

            PINB = (1 << PB5);                /* escribir PINx CONMUTA PORTx */
            usart_print("tic\r\n");
        }
    }
}
