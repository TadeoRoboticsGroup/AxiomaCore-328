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
    TCCR1A = (1 << COM1A1) | (1 << WGM10);   /* PWM rápido 8 bits, no invertido */
    TCCR1B = (1 << WGM12) | (1 << CS11);     /* clk/8 */
    OCR1A  = 64;                             /* 64 de 256: un 25 % */

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
