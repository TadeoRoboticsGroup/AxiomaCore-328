; AxiomaCore-328 - interrupciones externas contra simavr
; SPDX-License-Identifier: Apache-2.0
;
; El banco `make sim-extint` verifica INT0, INT1 y los tres PCINT contra un
; modelo escrito desde la hoja de datos. Este programa los verifica contra una
; implementación INDEPENDIENTE, que es simavr, y ejercita de paso el camino
; completo: pin -> deteccion -> bandera -> controlador -> entrada a ISR.
;
; EL TRUCO PARA GENERAR UN FLANCO SIN CABLES. Los pines aquí son entradas del
; chip, y ningún programa puede mover una entrada. Pero la hoja de datos dice
; que la detección mira el valor del PIN y no el de PORTx, así que un pin
; configurado como SALIDA que el programa conmute se interrumpe a sí mismo. Es
; la forma más barata de generar una interrupción por software, y es un uso
; documentado — no un atajo del banco.
;
; SE ENCIENDE UN VECTOR CADA VEZ. Con varios habilitados, el arnés le dice a
; simavr qué vector tomó el RTL y un intercambio de vectores se volvería
; invisible: es exactamente el mutante que sobrevivió con el Timer1. Aquí cada
; fase habilita uno solo.

    .section .text
    .global _start

; ----------------------------------------------------- tabla de vectores
    .org 0x00
    jmp  _start                 ; RESET
    .org 0x04
    jmp  isr_int0               ; vector 1, INT0  (PD2)
    .org 0x08
    jmp  isr_int1               ; vector 2, INT1  (PD3)
    .org 0x0C
    jmp  isr_pcint0             ; vector 3, PCINT0 (PB0..PB7)
    .org 0x10
    jmp  isr_pcint1             ; vector 4, PCINT1 (PC0..PC6)
    .org 0x14
    jmp  isr_pcint2             ; vector 5, PCINT2 (PD0..PD7)

; ------------------------------------------------------------- programa
    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    clr  r20                    ; cuenta de INT0
    clr  r21                    ; cuenta de INT1
    clr  r22                    ; cuenta de PCINT0
    clr  r23                    ; cuenta de PCINT1
    clr  r24                    ; cuenta de PCINT2

    ; Los pines que se van a conmutar, como salidas y en alto.
    ldi  r16, 0x0C
    out  0x0A, r16              ; DDRD  = PD2 y PD3 de salida
    out  0x0B, r16              ; PORTD = los dos en alto
    ldi  r16, 0x01
    out  0x04, r16              ; DDRB  = PB0 de salida
    out  0x05, r16              ; PORTB = PB0 en alto
    ldi  r16, 0x01
    out  0x07, r16              ; DDRC  = PC0 de salida
    out  0x08, r16              ; PORTC = PC0 en alto
    nop
    nop

; ---------------------------------------------- fase 1: INT0 por bajada
    ldi  r16, 0x02
    sts  0x69, r16              ; EICRA = ISC01, flanco de bajada en INT0
    ldi  r16, 0x03
    out  0x1C, r16              ; EIFR: limpiar las dos banderas
    ldi  r16, 0x01
    out  0x1D, r16              ; EIMSK = INT0
    sei

    ldi  r17, 4
f1:
    ldi  r16, 0x08
    out  0x0B, r16              ; PD2 a cero -> bajada -> INT0
    nop
    nop
    nop
    ldi  r16, 0x0C
    out  0x0B, r16              ; PD2 a uno: la subida no dispara nada
    nop
    nop
    nop
    dec  r17
    brne f1

    cli
    ldi  r16, 0x00
    out  0x1D, r16              ; EIMSK = 0

; ------------------------------- fase 2: INT1 por cualquier flanco
    ldi  r16, 0x04
    sts  0x69, r16              ; EICRA = ISC10, cualquier flanco en INT1
    ldi  r16, 0x03
    out  0x1C, r16
    ldi  r16, 0x02
    out  0x1D, r16              ; EIMSK = INT1
    sei

    ldi  r17, 3
f2:
    ldi  r16, 0x04
    out  0x0B, r16              ; PD3 a cero -> flanco
    nop
    nop
    nop
    ldi  r16, 0x0C
    out  0x0B, r16              ; PD3 a uno  -> flanco tambien
    nop
    nop
    nop
    dec  r17
    brne f2

    cli
    ldi  r16, 0x00
    out  0x1D, r16

; ------------------------------------------- fase 3: PCINT0 en PB0
    ldi  r16, 0x01
    sts  0x6B, r16              ; PCMSK0 = PB0
    ldi  r16, 0x07
    out  0x1B, r16              ; PCIFR: limpiar las tres
    ldi  r16, 0x01
    sts  0x68, r16              ; PCICR = PCIE0
    sei

    ldi  r17, 3
f3:
    ldi  r16, 0x01
    out  0x05, r16              ; PB0 a uno
    nop
    nop
    nop
    ldi  r16, 0x00
    out  0x05, r16              ; PB0 a cero: cualquier cambio vale
    nop
    nop
    nop
    dec  r17
    brne f3

    cli
    ldi  r16, 0x00
    sts  0x68, r16

; ------------------------------------------- fase 4: PCINT1 en PC0
    ldi  r16, 0x01
    sts  0x6C, r16              ; PCMSK1 = PC0
    ldi  r16, 0x07
    out  0x1B, r16
    ldi  r16, 0x02
    sts  0x68, r16              ; PCICR = PCIE1
    sei

    ldi  r17, 2
f4:
    ldi  r16, 0x00
    out  0x08, r16              ; PC0 a cero
    nop
    nop
    nop
    ldi  r16, 0x01
    out  0x08, r16              ; PC0 a uno
    nop
    nop
    nop
    dec  r17
    brne f4

    cli
    ldi  r16, 0x00
    sts  0x68, r16

; ------------------------------------------- fase 5: PCINT2 en PD2
    ldi  r16, 0x04
    sts  0x6D, r16              ; PCMSK2 = PD2
    ldi  r16, 0x07
    out  0x1B, r16
    ldi  r16, 0x04
    sts  0x68, r16              ; PCICR = PCIE2
    sei

    ldi  r17, 2
f5:
    ldi  r16, 0x08
    out  0x0B, r16              ; PD2 a cero
    nop
    nop
    nop
    ldi  r16, 0x0C
    out  0x0B, r16              ; PD2 a uno
    nop
    nop
    nop
    dec  r17
    brne f5

    cli
    ldi  r16, 0x00
    sts  0x68, r16

    ; Las cuentas a la SRAM, que el arnés compara byte a byte al terminar.
    sts  0x0100, r20
    sts  0x0101, r21
    sts  0x0102, r22
    sts  0x0103, r23
    sts  0x0104, r24

fin:
    rjmp fin

; ----------------------------------------------------------------- ISRs
; Ninguna toca SREG sin guardarlo: `in r0, 0x3F` no hace falta porque no se
; ejecuta nada que escriba banderas salvo el INC, y ese sí las escribe — así
; que se guarda.
isr_int0:
    push r0
    in   r0, 0x3F
    inc  r20
    out  0x3F, r0
    pop  r0
    reti

isr_int1:
    push r0
    in   r0, 0x3F
    inc  r21
    out  0x3F, r0
    pop  r0
    reti

isr_pcint0:
    push r0
    in   r0, 0x3F
    inc  r22
    out  0x3F, r0
    pop  r0
    reti

isr_pcint1:
    push r0
    in   r0, 0x3F
    inc  r23
    out  0x3F, r0
    pop  r0
    reti

isr_pcint2:
    push r0
    in   r0, 0x3F
    inc  r24
    out  0x3F, r0
    pop  r0
    reti
