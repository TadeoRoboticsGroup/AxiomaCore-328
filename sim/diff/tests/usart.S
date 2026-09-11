; AxiomaCore-328 - registros de la USART0
; SPDX-License-Identifier: Apache-2.0
;
; Configura el puerto serie como lo haría un programa real —divisor, formato,
; habilitación— y vuelve a leer lo que escribió.
;
; LO QUE ESTE PROGRAMA NO PUEDE TOCAR, y el motivo:
;
;   UCSR0A  lleva RXC, TXC y UDRE, que son BANDERAS DE TEMPORIZACIÓN. Aquí las
;           mueve un transmisor que serializa bits de verdad; en simavr las
;           mueve un temporizador de ciclos con su propia cuenta, que además
;           suma siempre un bit de paridad esté o no activada. Son dos relojes
;           distintos y compararlos no significa nada.
;   UDR0    son dos registros en una dirección, y leerlo TIENE EFECTO LATERAL:
;           saca un byte del búfer de recepción. Sin nada conectado al puerto,
;           aquí no llega nada nunca.
;   UCSR0B  bit 1: en el chip es RXB8, el noveno bit RECIBIDO, y es de sólo
;           lectura. simavr devuelve lo que se le escribió. Por eso el programa
;           no lo escribe: un programa real tampoco lo haría.
;
; Lo que sí se compara, y está en la tabla COMPARABLE[] del arnés: UCSR0B,
; UCSR0C, UBRR0L y UBRR0H, que son almacenamiento en los dos lados.

    .section .text
    .global _start
_start:
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    ; Los registros de la USART están en la I/O extendida: sólo LD/ST.
    ldi  r28, 0xC0
    ldi  r29, 0x00              ; Y apunta a UCSR0A

    ; 115200 baudios con F_CPU = 12,5 MHz y U2X: UBRR = 12.
    ldi  r16, 0x00
    std  Y+5, r16               ; UBRR0H = 0x00
    ldi  r16, 12
    std  Y+4, r16               ; UBRR0L = 12

    ; 8 bits, sin paridad, un bit de parada.
    ldi  r16, 0x06
    std  Y+2, r16               ; UCSR0C

    ; Transmisor y receptor en marcha, con su interrupción de recepción.
    ldi  r16, 0x98              ; RXCIE0 | RXEN0 | TXEN0
    std  Y+1, r16               ; UCSR0B

    ; Releer lo escrito: si el mapa de registros bailara, esto divergiría.
    ; LAS DOS FORMAS DE LLEGAR, a propósito. La I/O extendida sólo se alcanza
    ; con LDS, LD o LDD, y LDD consume la lectura UN CICLO DESPUÉS de lanzarla
    ; mientras que LDS lo hace dentro del mismo. Esa diferencia destapó que el
    ; bus no registraba el dato de los periféricos y toda lectura con LD o LDD
    ; devolvía cero. Si alguien vuelve a quitar ese registro, estas cuatro
    ; líneas lo cazan.
    lds  r20, 0x00C1
    ldd  r21, Y+2
    lds  r22, 0x00C4
    ldd  r23, Y+5

    ; Unos cuantos bytes al transmisor. No se espera a UDRE a propósito: eso
    ; sería mirar una bandera de temporización.
    ldi  r16, 'H'
    std  Y+6, r16               ; UDR0
    ldi  r16, 'o'
    std  Y+6, r16
    ldi  r16, 'l'
    std  Y+6, r16
    ldi  r16, 'a'
    std  Y+6, r16

    ; Y una reconfiguración, para que se vea que los registros siguen vivos.
    ldi  r16, 0x2E              ; paridad par, dos bits de parada, 8 datos
    std  Y+2, r16
    ldi  r16, 103               ; 9600 baudios sin U2X
    std  Y+4, r16
    ldd  r24, Y+2
    ldd  r25, Y+4

bucle:
    inc  r18
    out  0x1E, r18              ; GPIOR0, almacenamiento puro en los dos lados
    eor  r19, r18
    rjmp bucle
