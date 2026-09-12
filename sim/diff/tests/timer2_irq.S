; AxiomaCore-328 - los tres vectores del Timer2
; SPDX-License-Identifier: Apache-2.0
;
;   TIMER2_COMPA  vector 7, byte 0x1C
;   TIMER2_COMPB  vector 8, byte 0x20
;   TIMER2_OVF    vector 9, byte 0x24
;
; El Timer2 tiene PRESCALER PROPIO y sus bits CS no significan lo mismo que los
; del Timer0: aqui CS=4 es clk/64 y no clk/256. Este programa usa CS=2 (clk/8)
; y CS=4 (clk/64), que son dos de los que se solapan en numero pero no en
; division, de modo que si alguien hubiera copiado la tabla del Timer0 la
; cuenta de interrupciones no cuadraria con la de simavr.
;
; SE HABILITA UNA SOLA INTERRUPCION CADA VEZ. Con varias puestas, el arnes le
; dice a simavr que vector tomo el RTL y un intercambio de vectores se vuelve
; invisible: es el mutante que sobrevivio con el Timer1.
;
; LO QUE NO SE TOCA: TCNT2 y TIFR2. simavr interpola la cuenta desde su propio
; contador de ciclos, asi que leerlos haria divergir el contraste sin que haya
; nada roto. TCCR2A/B, TIMSK2, OCR2A/B y ASSR si son almacenamiento en los dos
; lados y se comparan.
;
; ASSR SE QUEDA A CERO. El modo asincrono cuenta TOSC1, que en el banco no se
; mueve, asi que poner AS2 pararia el temporizador — aqui, y en el chip.

    .section .text
    .global _start

    .org 0x00
    jmp  _start
    .org 0x1C
    jmp  isr_compa
    .org 0x20
    jmp  isr_compb
    .org 0x24
    jmp  isr_ovf

    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    clr  r20                    ; comparaciones A
    clr  r21                    ; comparaciones B
    clr  r22                    ; desbordamientos
    clr  r24                    ; vueltas del bucle

    ; Los registros del Timer2 viven en la I/O extendida: solo se llega con
    ; LDS/STS o con un puntero.
    ldi  r28, 0xB0
    ldi  r29, 0x00              ; Y apunta a TCCR2A

    ldi  r16, 0x00
    std  Y+0, r16               ; TCCR2A: modo normal, pines sueltos
    ldi  r16, 0x40
    std  Y+3, r16               ; OCR2A = 0x40
    ldi  r16, 0xC0
    std  Y+4, r16               ; OCR2B = 0xC0

    ldi  r30, 0x70
    ldi  r31, 0x00              ; Z apunta a TIMSK2
    ldi  r16, 0x01
    st   Z, r16                 ; TOIE2

    sei
    ldi  r16, 0x02
    std  Y+1, r16               ; TCCR2B = CS21: clk/8

bucle:
    inc  r24
    mov  r16, r24
    swap r16                    ; los bits 7:4 pasan a 3:0
    andi r16, 0x03

    ldi  r17, 0x01              ; fase 0: TOIE2
    cpi  r16, 1
    brne .+2
    ldi  r17, 0x02              ; fase 1: OCIE2A
    cpi  r16, 2
    brne .+2
    ldi  r17, 0x04              ; fase 2: OCIE2B
    cpi  r16, 3
    brne .+2
    ldi  r17, 0x01              ; fase 3: TOIE2 otra vez, con otra division
    st   Z, r17                 ; TIMSK2

    ; En la fase 3 se cambia a clk/64, que es CS=4. Si alguien hubiera copiado
    ; la tabla del Timer0, CS=4 seria clk/256 y saldrian cuatro veces menos
    ; interrupciones que en simavr.
    cpi  r16, 3
    brne otra_div
    ldi  r18, 0x04              ; clk/64
    rjmp pon_div
otra_div:
    ldi  r18, 0x02              ; clk/8
pon_div:
    std  Y+1, r18               ; TCCR2B

    ; Algo de trabajo entre vueltas, para que las interrupciones caigan en
    ; sitios distintos del flujo.
    ldi  r19, 12
espera:
    dec  r19
    brne espera

    rjmp bucle

; ----------------------------------------------------------------- ISRs
isr_compa:
    push r0
    in   r0, 0x3F
    inc  r20
    out  0x3F, r0
    pop  r0
    reti

isr_compb:
    push r0
    in   r0, 0x3F
    inc  r21
    out  0x3F, r0
    pop  r0
    reti

isr_ovf:
    push r0
    in   r0, 0x3F
    inc  r22
    out  0x3F, r0
    pop  r0
    reti
