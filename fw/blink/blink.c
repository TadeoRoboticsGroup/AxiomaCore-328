/* AxiomaCore-328 - Blink, el criterio de aceptación de la fase 2
 * SPDX-License-Identifier: Apache-2.0
 *
 * Se compila con avr-gcc y avr-libc SIN TOCAR NADA: las mismas cabeceras
 * <avr/io.h> e <avr/interrupt.h> que usaría un ATmega328P de verdad. Que
 * compile y corra sin modificaciones es medio criterio de compatibilidad de
 * nivel L2; el otro medio es que los registros estén donde dice avr-libc, y de
 * eso se encarga el mapa generado.
 *
 * NO ES UN BUCLE DE ESPERA. Cuenta desbordamientos del Timer0 en su ISR, que es
 * el mismo camino por el que Arduino implementa millis() y delay(). Así el
 * parpadeo ejercita, de una vez: el arranque de avr-gcc —que monta la pila con
 * `out SPL,r28` y copia .data—, la tabla de vectores, la entrada y la salida de
 * interrupción, el prescaler compartido, el Timer0 y el puerto de E/S.
 *
 * F_CPU NO ES 16 000 000, y hay dos razones encadenadas. La primera: el PLL del
 * ECP5 no puede sacar exactamente 16 MHz de los 25 de la placa. La segunda: el
 * diseño cierra timing a 14,74 MHz, medido con nextpnr, asi que se corre a
 * 12,5 MHz —la mitad justa del oscilador— con margen. Lo que importa no es el
 * numero sino que sea EXACTO: con F_CPU correcto, la cuenta no deriva.
 *
 * La cadencia se deriva de F_CPU en tiempo de compilacion, de modo que cambiar
 * el reloj no obliga a tocar ninguna constante a mano.
 */
#include <avr/io.h>
#include <avr/interrupt.h>

/* Con el prescaler en clk/64, el Timer0 desborda cada 256 * 64 = 16 384 ciclos. */
#define OVF_POR_SEGUNDO  (F_CPU / 64UL / 256UL)
#define MEDIO_SEGUNDO    ((uint16_t)(OVF_POR_SEGUNDO / 2))

/* volatile: lo escribe la ISR y lo lee el bucle principal. Sin esto el
 * compilador se lo guarda en un registro y el bucle no ve nunca el cambio. */
static volatile uint16_t desbordes;

ISR(TIMER0_OVF_vect)
{
    desbordes++;
}

int main(void)
{
    /* Puerto B entero a salida. El LED de toda la vida de Arduino es el pin 13,
     * que es PB5. */
    DDRB = 0xFF;
    PORTB = 0x00;

    /* Timer0 en modo normal, prescaler clk/64, interrupción por desbordamiento. */
    TCCR0A = 0x00;
    TCCR0B = (1 << CS01) | (1 << CS00);
    TIMSK0 = (1 << TOIE0);

    sei();

    for (;;) {
        if (desbordes >= MEDIO_SEGUNDO) {
            /* Sección crítica: `desbordes` son dos bytes y la ISR puede caer
             * entre uno y otro. Es la misma razón por la que millis() de
             * Arduino guarda y restaura SREG. */
            uint8_t sreg = SREG;
            cli();
            desbordes = 0;
            SREG = sreg;

            PINB = (1 << PB5);   /* escribir PINx CONMUTA PORTx: la trampa nº 5 */
        }
    }
}
