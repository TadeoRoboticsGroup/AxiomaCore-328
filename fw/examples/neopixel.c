/* AxiomaCore-328 - NeoPixel: el sketch que mide ciclos, no funciones
 * SPDX-License-Identifier: Apache-2.0
 *
 * El plan de la fase 4 nombra este caso por su nombre —«NeoPixel incluido»— y
 * no es por capricho. Una tira WS2812B no tiene reloj: **el bit es la anchura
 * del pulso**, y la diferencia entre un cero y un uno son 350 ns frente a
 * 700 ns. A 12,5 MHz un ciclo son 80 nanosegundos, así que todo esto se juega
 * en cuatro o cinco instrucciones.
 *
 * Por eso es la prueba que de verdad ejercita el nivel **L3** del contrato de
 * compatibilidad: no basta con que las instrucciones hagan lo correcto, tienen
 * que durar lo que dice el manual. Un `SBI` que costara tres ciclos en vez de
 * dos no rompería ningún banco de este repositorio salvo éste — y en una tira
 * de verdad se vería como colores equivocados.
 *
 * LOS TIEMPOS, de la hoja de datos del WS2812B:
 *
 *   T0H  0,35 µs ± 150 ns     un cero: pulso corto
 *   T1H  0,70 µs ± 150 ns     un uno: pulso largo
 *   T0L  0,80 µs ± 150 ns
 *   T1L  0,60 µs ± 150 ns
 *   periodo  1,25 µs ± 600 ns
 *   reposo   > 50 µs          para que la tira se quede el color
 *
 * Y lo que sale a 12,5 MHz, contando ciclos de 80 ns:
 *
 *   T0H  4 ciclos = 320 ns    dentro de los 350 ± 150
 *   T1H  9 ciclos = 720 ns    dentro de los 700 ± 150
 *   periodo 16 ciclos = 1,28 µs   dentro de los 1,25 ± 0,6
 *
 * NO SE USA LA BIBLIOTECA DE ADAFRUIT, y conviene decir por qué: sus rutinas
 * están escritas a mano para 8, 12 y 16 MHz, con un bloque de ensamblador
 * distinto por frecuencia, y 12,5 MHz no es ninguna de ellas. Eso no es un
 * problema de este chip —le pasaría igual a un ATmega328P con un cristal de
 * 12,5 MHz—, así que aquí va el bucle escrito para este reloj. Lo que se
 * comprueba es el chip, no la biblioteca.
 */

#include <avr/io.h>
#include <stdint.h>

/* El pin de datos: PB0. */
#define NEO_MASK  (1 << 0)

/* Manda 24 bits —G, R, B— por PB0 con el ritmo del WS2812B.
 *
 * El bucle está escrito para que LAS DOS RAMAS DUREN LO MISMO, que es la
 * única forma de que el periodo no dependa del dato. Sale así:
 *
 *   sbi              2      el pin sube
 *   lsl  + brcs      2      se mira el bit
 *   (cero) cbi       2      baja en el ciclo 4  -> T0H = 4 ciclos
 *   (uno)  5 nops    5
 *          cbi       2      baja en el ciclo 9  -> T1H = 9 ciclos
 *   relleno hasta 16 ciclos en las dos ramas
 */
static void neo_envia(const uint8_t *datos, uint8_t n)
{
    __asm__ volatile(
        "1:                     \n\t"   /* por cada byte                     */
        "   ld   r18, Z+        \n\t"
        "   ldi  r19, 8         \n\t"
        "2:                     \n\t"   /* por cada bit, empezando por el MSB*/
        "   sbi  %[port], %[bit]\n\t"   /* 2 : sube                          */
        "   lsl  r18            \n\t"   /* 1 : C = bit                       */
        "   brcs 3f             \n\t"   /* 1 si cero, 2 si uno               */
        /* --- CERO: el pulso se corta ya --- */
        "   cbi  %[port], %[bit]\n\t"   /* 2 : baja en el ciclo 4            */
        "   nop                 \n\t"
        "   nop                 \n\t"
        "   nop                 \n\t"
        "   nop                 \n\t"
        "   nop                 \n\t"
        "   rjmp 4f             \n\t"   /* 2                                 */
        /* --- UNO: el pulso se alarga ---
         * CUATRO nops y no cinco: el `brcs` TOMADO cuesta DOS ciclos, no uno,
         * así que esta rama entra un ciclo más tarde que la otra. Con cinco
         * salían 800 ns, que siguen estando dentro de la tolerancia pero rozan
         * el borde; con cuatro salen 720 y el nominal son 700. */
        "3:                     \n\t"
        "   nop                 \n\t"
        "   nop                 \n\t"
        "   nop                 \n\t"
        "   nop                 \n\t"
        "   cbi  %[port], %[bit]\n\t"   /* 2 : baja en el ciclo 11 -> 9 alto */
        "   nop                 \n\t"
        "   nop                 \n\t"
        "4:                     \n\t"
        "   dec  r19            \n\t"   /* 1                                 */
        "   brne 2b             \n\t"   /* 2 si sigue                        */
        "   dec  %[n]           \n\t"
        "   brne 1b             \n\t"
        : [n] "+d"(n)
        : [port] "I"(_SFR_IO_ADDR(PORTB)), [bit] "I"(0), "z"(datos)
        : "r18", "r19", "memory");
}

int main(void)
{
    DDRB |= NEO_MASK;
    PORTB &= (uint8_t)~NEO_MASK;

    /* Tres bytes en orden G, R, B — que es el del WS2812B y no el RGB que uno
     * esperaría. Los valores están elegidos para que la trama tenga de todo:
     * un byte con ceros y unos alternos, uno a cero y uno a todo unos. Así una
     * anchura mal medida se ve, en vez de esconderse en un patrón uniforme. */
    static const uint8_t color[3] = { 0xA5, 0x00, 0xFF };

    for (;;) {
        neo_envia(color, 3);

        /* El reposo: más de 50 µs para que la tira se quede con el color. A
         * 12,5 MHz eso son 625 ciclos; se dejan de sobra. */
        for (volatile uint16_t i = 0; i < 400; i++)
            ;
    }
}
