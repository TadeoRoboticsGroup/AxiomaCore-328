; AxiomaCore-328 - las interrupciones de la USART
; SPDX-License-Identifier: Apache-2.0
;
; POR QUÉ EXISTE ESTE PROGRAMA. La medida de cobertura encontró que las tres
; salidas de interrupción de la USART —`irq_rxc`, `irq_udre` e `irq_txc`— NUNCA
; conmutaban en ningún banco. El periférico estaba verificado y el controlador
; de interrupciones también, pero que los tres vectores estuvieran BIEN
; CABLEADOS no lo comprobaba nadie.
;
; No es una preocupación teórica: el primer fallo que apareció al ejercitar las
; interrupciones del Timer0 fue exactamente ése, un bit de más en la
; concatenación que convertía TIMER0_COMPA en TIMER1_OVF.
;
; Se ejercitan dos de los tres:
;
;   UDRE (vector 19)  salta en cuanto se habilita, porque el búfer de
;                     transmisión nace vacío. La ISR lo calla escribiendo un
;                     byte, que es el patrón real de una rutina de envío.
;   TXC  (vector 20)  salta al terminar la última trama, con el búfer vacío.
;
; RXC (vector 18) necesita que ALGUIEN TRANSMITA hacia el chip, y aquí no hay
; nadie al otro lado del cable. Se ejercita en el banco de extremo a extremo,
; que sí puede poner tramas en el pin.

    .section .text
    .global _start

    .org 0x00
    jmp  _start
    .org 0x4C                   ; vector 19, USART_UDRE
    jmp  isr_udre
    .org 0x50                   ; vector 20, USART_TX
    jmp  isr_txc

    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16
    ldi  r16, 0x08
    out  0x3E, r16

    clr  r20                    ; cuenta de UDRE
    clr  r21                    ; cuenta de TXC
    ldi  r22, 'A'               ; lo que se va enviando

    ldi  r28, 0xC0              ; Y apunta a UCSR0A
    ldi  r29, 0x00

    ldi  r16, 0x00
    std  Y+5, r16               ; UBRR0H
    ldi  r16, 1                 ; divisor pequeño: las tramas salen rápido
    std  Y+4, r16               ; UBRR0L
    ldi  r16, 0x06
    std  Y+2, r16               ; UCSR0C: 8 bits, sin paridad, 1 parada

    sei

    ; TXEN con UDRIE y TXCIE. UDRE ya está alto, así que la primera
    ; interrupción entra en cuanto pase la instrucción siguiente al SEI.
    ldi  r16, 0x68              ; TXCIE0 | UDRIE0 | TXEN0
    std  Y+1, r16               ; UCSR0B

bucle:
    inc  r18
    out  0x1E, r18              ; GPIOR0
    eor  r19, r18
    rjmp bucle

; ---------------------------------------------------------------------- ISR
isr_udre:
    push r16
    in   r16, 0x3F
    push r16
    inc  r20
    ; Cuatro bytes y se calla: si no, UDRE vuelve a levantarse en cuanto el
    ; turno pasa al registro de desplazamiento y no se sale nunca del bucle.
    cpi  r20, 4
    brlo udre_envia
    ldi  r16, 0x48              ; TXCIE0 | TXEN0, sin UDRIE
    sts  0x00C1, r16
    rjmp udre_fin
udre_envia:
    sts  0x00C6, r22            ; UDR0
    inc  r22
udre_fin:
    pop  r16
    out  0x3F, r16
    pop  r16
    reti

isr_txc:
    push r16
    in   r16, 0x3F
    push r16
    inc  r21
    ; TXC se limpia sola al atender el vector, como en el chip.
    pop  r16
    out  0x3F, r16
    pop  r16
    reti
