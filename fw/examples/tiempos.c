/* AxiomaCore-328 - Servo y tone(): dos formas de onda que se miden, no se miran
 * SPDX-License-Identifier: Apache-2.0
 *
 * Dos sketches de la suite de la Capa 5 en un solo programa, porque los dos
 * producen su onda **con el hardware** y se pueden dejar corriendo a la vez:
 * una vez configurados los temporizadores, el núcleo no vuelve a tocarlos. Que
 * convivan no es una comodidad del banco — es la prueba de que dos
 * temporizadores distintos, con prescaler distinto, no se pisan.
 *
 * ---------------------------------------------------------------------------
 * SERVO: Timer1 en PWM rápido con `ICR1` de tope
 * ---------------------------------------------------------------------------
 *
 * Un servo de radiocontrol no lee un valor: lee **cuánto dura el pulso**. La
 * trama son 20 ms y el pulso va de 1 ms —todo a un lado— a 2 ms —todo al otro—,
 * con 1,5 ms en el centro. Si la trama se acorta, el servo tiembla; si el pulso
 * se pasa, fuerza contra el tope y se quema.
 *
 * Eso pide un periodo que no cabe en 8 bits, así que se usa el **modo 14**:
 * PWM rápido con el tope en `ICR1`. Es el modo que usa la biblioteca `Servo` de
 * Arduino y el que de verdad ejercita el registro `ICR1` como TOP, con su
 * registro temporal de 16 bits de por medio.
 *
 *   prescaler 8   ->  un tic son 8/12,5 MHz = 0,64 µs
 *   ICR1  = 31249 ->  (31249+1) * 0,64 µs = 20,0 ms  exactos
 *   OCR1A =  2344 ->  2344 * 0,64 µs = 1,50 ms       el centro
 *
 * ---------------------------------------------------------------------------
 * TONE: Timer2 en CTC conmutando OC2A
 * ---------------------------------------------------------------------------
 *
 * `tone()` de Arduino hace exactamente esto: poner un temporizador en CTC y
 * dejar que conmute el pin solo. El núcleo no interviene, y por eso la nota no
 * se desafina aunque el programa esté ocupado — que es justo lo que se
 * comprueba dejándolo sonar mientras el servo va por su lado.
 *
 *   prescaler 64  ->  un tic son 64/12,5 MHz = 5,12 µs
 *   OCR2A = 97    ->  conmuta cada 98 tics = 501,76 µs
 *                     periodo completo = 1003,5 µs  ->  996,6 Hz
 *
 * No son 1 000 Hz clavados, y no se disimula: con este reloj y este prescaler
 * no existe un `OCR2A` que los dé. El banco no comprueba «1 kHz», comprueba
 * **el número que sale de los registros**, que es lo único honesto — un banco
 * que redondeara a 1 kHz aceptaría un prescaler equivocado.
 */

#include <avr/io.h>
#include <stdint.h>

int main(void)
{
    /* OC1A es PB1 y OC2A es PB3. */
    DDRB |= (1 << 1) | (1 << 3);

    /* ---- Servo: Timer1, modo 14, tope en ICR1 ---- */
    /* Los registros de 16 bits se escriben BYTE ALTO PRIMERO: el alto se queda
     * en el registro temporal y la escritura del bajo los mete los dos a la
     * vez. Al revés, el temporal lleva basura y el valor sale partido. */
    ICR1H  = (uint8_t)(31249 >> 8);
    ICR1L  = (uint8_t)(31249 & 0xFF);
    OCR1AH = (uint8_t)(2344 >> 8);
    OCR1AL = (uint8_t)(2344 & 0xFF);

    /* COM1A1: no invertido. WGM = 1110 (modo 14) con CS = 010 (clk/8). */
    TCCR1A = (1 << COM1A1) | (1 << WGM11);
    TCCR1B = (1 << WGM13) | (1 << WGM12) | (1 << CS11);

    /* ---- tone(): Timer2, CTC, conmutando OC2A ---- */
    OCR2A  = 97;
    TCCR2A = (1 << COM2A0) | (1 << WGM21);      /* conmutar en comparación */
    TCCR2B = (1 << CS22);                        /* CS = 100 -> clk/64      */

    /* Y el núcleo se aparta: a partir de aquí las dos ondas las hace el
     * hardware. Que sigan siendo exactas con la CPU en un bucle cerrado es
     * parte de lo que se comprueba. */
    for (;;)
        ;
}
