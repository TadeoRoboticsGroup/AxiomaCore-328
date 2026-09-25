/* AxiomaCore-328 - gestor de arranque STK500v1
 * SPDX-License-Identifier: Apache-2.0
 * Copyright 2026 The AxiomaCore Project
 *
 * Lo que convierte este chip en algo que se puede usar: con esto, pulsar
 * *Upload* en el IDE de Arduino programa la FPGA por el puerto serie, sin un
 * programador por fuera y sin herramientas propias.
 *
 * ---------------------------------------------------------------------------
 * ESTE FICHERO NO TIENE CÓDIGO DE FLASH PROPIO, Y ESO ES DELIBERADO
 * ---------------------------------------------------------------------------
 *
 * Para borrar y escribir páginas usa `<avr/boot.h>` de **avr-libc, sin tocar
 * nada**: `boot_page_erase`, `boot_page_fill`, `boot_page_write` y
 * `boot_spm_busy_wait`. Esas macros son `asm` en línea que escriben `SPMCSR` y
 * ejecutan `SPM` con la secuencia de cuatro ciclos, y están escritas para el
 * ATmega328P de verdad.
 *
 * O sea que este programa **es en sí mismo una prueba del RTL**: si
 * `rtl/periph/axioma_spm.v` no implementara la secuencia temporizada, el búfer
 * de página o la espera de `SPMEN` exactamente como manda la hoja de datos, la
 * cabecera oficial de avr-libc no funcionaría aquí. No hay una capa de
 * compatibilidad en medio que pueda tapar una diferencia.
 *
 * ---------------------------------------------------------------------------
 * EL PROTOCOLO: STK500v1, el subconjunto que usa avrdude
 * ---------------------------------------------------------------------------
 *
 * Cada orden termina en `CRC_EOP` (0x20) y se contesta con `INSYNC` (0x14),
 * los datos que toquen, y `OK` (0x10). Si el byte de cierre no es `CRC_EOP`,
 * se contesta `NOSYNC` (0x15) y se descarta: es como avrdude vuelve a
 * sincronizarse cuando algo se pierde, y saltárselo hace que un reintento deje
 * el gestor y el programador hablando desfasados para siempre.
 *
 * Se implementa lo que avrdude usa de verdad con `-c arduino`, que es menos de
 * lo que el documento del STK500 describe. Lo que llega y no se conoce se
 * contesta con `INSYNC`+`OK` sin hacer nada, que es lo que hace Optiboot: un
 * gestor que se atragante con una orden desconocida no se puede depurar.
 *
 * ---------------------------------------------------------------------------
 * LA FIRMA ES LA DEL ATmega328P, Y ES UNA DECISIÓN
 * ---------------------------------------------------------------------------
 *
 * 0x1E 0x95 0x0F. El plan contempla una firma propia con su `axioma.conf`, y
 * tiene sentido para no hacerse pasar por otro chip. Pero el criterio de
 * aceptación de esta fase es **«desde el IDE de Arduino, sin herramientas
 * externas»**, y con una firma propia el IDE no reconoce la placa hasta que el
 * usuario instala un fichero de configuración. Las dos cosas no caben a la vez.
 *
 * Se elige responder la del 328P porque es lo que hace que el criterio se
 * cumpla, y porque este chip **es** binariamente un 328P: decir que lo es no es
 * una mentira, es la razón de ser del proyecto. La firma propia queda como
 * opción de compilación (`-DFIRMA_PROPIA`) para quien prefiera el otro camino.
 */

#include <avr/io.h>
#include <avr/boot.h>
#include <avr/pgmspace.h>
#include <avr/wdt.h>
#include <util/setbaud.h>
#include <stdint.h>

/* ------------------------------------------------------- el protocolo */
#define STK_OK              0x10
#define STK_INSYNC          0x14
#define STK_NOSYNC          0x15
#define CRC_EOP             0x20

#define STK_GET_SYNC        0x30
#define STK_GET_PARAMETER   0x41
#define STK_SET_DEVICE      0x42
#define STK_SET_DEVICE_EXT  0x45
#define STK_ENTER_PROGMODE  0x50
#define STK_LEAVE_PROGMODE  0x51
#define STK_LOAD_ADDRESS    0x55
#define STK_UNIVERSAL       0x56
#define STK_PROG_PAGE       0x64
#define STK_READ_PAGE       0x74
#define STK_READ_SIGN       0x75

#define PARM_SW_MINOR       0x82

#ifdef FIRMA_PROPIA
#  define SIG0 0x1E
#  define SIG1 0xA0
#  define SIG2 0x01
#else
#  define SIG0 0x1E     /* Atmel */
#  define SIG1 0x95     /* 32 KB de Flash */
#  define SIG2 0x0F     /* ATmega328P */
#endif

/* --------------------------------------------------------- la USART */
static void tx(uint8_t b)
{
    while (!(UCSR0A & (1 << UDRE0)))
        ;
    UDR0 = b;
}

static uint8_t rx(void)
{
    while (!(UCSR0A & (1 << RXC0)))
        ;
    return UDR0;
}

/* El byte de cierre SE COMPRUEBA. Si no es `CRC_EOP`, la orden se descarta y
 * se contesta `NOSYNC`: es el mecanismo con el que avrdude se recupera de un
 * byte perdido. Dar `INSYNC` a ciegas deja a los dos lados desfasados y el
 * síntoma es un «programmer is out of sync» que no se arregla reintentando. */
static uint8_t fin_de_orden(void)
{
    if (rx() != CRC_EOP) {
        tx(STK_NOSYNC);
        return 0;
    }
    tx(STK_INSYNC);
    return 1;
}

/* --------------------------------------------------------- estado */
/* La dirección que manda `STK_LOAD_ADDRESS` viene en PALABRAS, no en bytes: es
 * la convención del STK500 y confundirla programa la mitad de la Flash en el
 * sitio equivocado sin dar ningún error. */
static uint16_t dir_palabra;

/* El búfer de una página. avr-libc dice cuánto mide: 128 bytes en el 328P. */
static uint8_t pagina[SPM_PAGESIZE];

static void graba_pagina(uint16_t byte_addr)
{
    uint8_t i;

    /* Las tres operaciones, en el orden que manda la hoja de datos y que
     * `axioma_spm` implementa: borrar, llenar el búfer palabra a palabra, y
     * volcar. Entre una y otra se espera a que `SPMEN` se caiga. */
    boot_page_erase(byte_addr);
    boot_spm_busy_wait();

    for (i = 0; i < SPM_PAGESIZE; i += 2)
        boot_page_fill(byte_addr + i,
                       (uint16_t)pagina[i] | ((uint16_t)pagina[i + 1] << 8));

    boot_page_write(byte_addr);
    boot_spm_busy_wait();
}

/* `main` VA EN `.init9`, Y SIN ESO NO ARRANCA. Al enlazar con
 * `-nostartfiles` no hay `crt0`, y por tanto **no hay nadie que llame a
 * `main`**: el enlazador sigue metiendo `__do_clear_bss` en `.init4` —hace
 * falta, porque este gestor tiene variables estáticas—, y al terminar ese
 * bucle la ejecución **cae en la siguiente función de `.text`**, que es la que
 * el compilador haya puesto ahí. De ahí se sale por un `ret` con la pila
 * vacía, y el chip se va a la dirección cero.
 *
 * Colocando `main` en `.init9` cae justo detrás de `.init4`, que es
 * exactamente donde `crt0` pondría el salto. Es el mismo truco que usa
 * Optiboot, y `naked` quita el prólogo porque de aquí no se vuelve.
 *
 * Costó encontrarlo: el síntoma era el bucle de `.bss` dando vueltas sin
 * terminar, y el bucle estaba bien —se llevó a la co-simulación contra simavr
 * y salió idéntico, `sim/diff/tests/bss_clear.S`—. Lo que pasaba es que
 * terminaba, seguía hacia la nada y el chip volvía a empezar.
 */
__attribute__((section(".init9"), naked, used)) int main(void)
{
    /* El perro guardián puede venir armado del reinicio que trajo aquí: un
     * gestor que se deje morder a mitad de una página deja la Flash a medias. */
    MCUSR = 0;
    wdt_disable();

    UBRR0H = UBRRH_VALUE;
    UBRR0L = UBRRL_VALUE;
#if USE_2X
    UCSR0A = (1 << U2X0);
#else
    UCSR0A = 0;
#endif
    UCSR0B = (1 << RXEN0) | (1 << TXEN0);
    UCSR0C = (1 << UCSZ01) | (1 << UCSZ00);   /* 8N1 */

    for (;;) {
        uint8_t orden = rx();
        uint8_t ok = 0;

        switch (orden) {

        case STK_GET_SYNC:
            ok = fin_de_orden();
            break;

        case STK_GET_PARAMETER: {
            uint8_t p = rx();
            ok = fin_de_orden();
            /* avrdude sólo mira que haya respuesta y que la versión no sea
             * absurda; cualquier valor sensato vale. */
            if (ok)
                tx(p == PARM_SW_MINOR ? 0 : 3);
            break;
        }

        /* avrdude manda veinte bytes de descripción del dispositivo y cinco
         * más en la extendida. No se usa ninguno —la página y el tamaño de la
         * Flash los sabe este gestor mejor que el fichero de configuración—,
         * así que las dos órdenes comparten el mismo código: lo único que
         * cambia es cuántos bytes hay que tragarse. */
        /* Y `STK_UNIVERSAL` entra en el mismo saco: son cuatro bytes de una
         * orden SPI cruda que aquí tampoco sirven de nada, y lo único que la
         * distingue es que contesta un cero. Juntar las tres deja el gestor
         * unos bytes más pequeño, y en 512 eso importa. */
        case STK_SET_DEVICE:
        case STK_SET_DEVICE_EXT:
        case STK_UNIVERSAL: {
            uint8_t n = (orden == STK_SET_DEVICE) ? 20
                      : (orden == STK_UNIVERSAL)  ? 4 : 5;
            while (n--)
                (void)rx();
            ok = fin_de_orden();
            if (ok && orden == STK_UNIVERSAL)
                tx(0x00);
            break;
        }

        case STK_LOAD_ADDRESS: {
            uint8_t lo = rx();
            uint8_t hi = rx();
            dir_palabra = (uint16_t)lo | ((uint16_t)hi << 8);
            ok = fin_de_orden();
            break;
        }

        /* LA LONGITUD CABE EN OCHO BITS y el byte alto se descarta a
         * propósito: una página del 328P son 128 bytes, así que ese byte vale
         * siempre cero. Contar en 16 bits cuesta instrucciones en cada vuelta
         * del bucle, y aquí cada byte de Flash cuenta. */
        case STK_PROG_PAGE: {
            uint8_t i;
            (void)rx();                       /* byte alto de la longitud */
            uint8_t len = rx();
            (void)rx();                       /* tipo de memoria: 'F' o 'E' */
            for (i = 0; i < len; i++) {
                uint8_t b = rx();
                if (i < SPM_PAGESIZE)
                    pagina[i] = b;
            }
            /* El resto de la página, a 0xFF: es lo que tiene una Flash
             * borrada, y deja el bucle de grabación sin una rama por palabra. */
            for (; i < SPM_PAGESIZE; i++)
                pagina[i] = 0xFF;
            ok = fin_de_orden();
            if (ok)
                graba_pagina(dir_palabra << 1);
            break;
        }

        case STK_READ_PAGE: {
            (void)rx();
            uint8_t len = rx();
            (void)rx();
            ok = fin_de_orden();
            if (ok) {
                uint16_t b = dir_palabra << 1;
                for (uint8_t i = 0; i < len; i++)
                    tx(pgm_read_byte(b + i));
            }
            break;
        }

        case STK_READ_SIGN:
            ok = fin_de_orden();
            if (ok) {
                tx(SIG0);
                tx(SIG1);
                tx(SIG2);
            }
            break;

        case STK_ENTER_PROGMODE:
        case STK_LEAVE_PROGMODE:
        default:
            /* Lo desconocido se reconoce y se ignora, como hace Optiboot: un
             * gestor que se atraganta con una orden que no conoce no se puede
             * depurar desde el otro extremo del cable. */
            ok = fin_de_orden();
            break;
        }

        /* EL `OK` SOLO SI LA ORDEN LLEGO SINCRONIZADA. Mandarlo detras de un
         * `NOSYNC` es lo que convierte un byte perdido en un desfase
         * permanente: avrdude reintentaria y encontraria siempre un byte de
         * mas esperandole. */
        if (ok)
            tx(STK_OK);
    }
}
