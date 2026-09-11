; AxiomaCore-328 - interrupciones del Timer0
; SPDX-License-Identifier: Apache-2.0
;
; El primer programa que ejercita la ENTRADA A INTERRUPCIÓN, que era la última
; parte del núcleo sin verificar: la máquina de estados estaba escrita desde la
; fase 1, pero `irq_req` estaba atado a cero y no había forma de dispararla.
;
; Enciende los tres vectores del Timer0 a la vez —comparación A, comparación B y
; desbordamiento— para que además se ejercite la PRIORIDAD FIJA: cuando hay dos
; pendientes gana el vector de número más bajo, que es COMPA (14), luego COMPB
; (15) y por último OVF (16).
;
; LO QUE ESTE PROGRAMA NO PUEDE TOCAR:
;   TCNT0  simavr lo interpola desde su propio contador de ciclos y no coincide
;          con una cuenta real; leerlo haría divergir el contraste sin que haya
;          nada roto.
;   TIFR0  aquí la pone el temporizador al desbordar y en simavr sólo cuando el
;          arnés levanta el vector.
; Los dos están fuera del barrido del espacio de datos por el mismo motivo.
;
; La tabla de vectores va en su sitio de verdad: el vector n ocupa la palabra 2n
; —dos palabras por vector, porque el salto es un JMP—, así que COMPA cae en el
; byte 0x38, COMPB en 0x3C y OVF en 0x40. Un programa así es lo que destapó que
; el secuenciador multiplicaba el número de vector por cuatro en vez de por dos.

    .section .text
    .global _start

; ----------------------------------------------------- tabla de vectores
    .org 0x00
    jmp  _start                 ; RESET
    .org 0x38
    jmp  isr_compa              ; vector 14, TIMER0_COMPA
    .org 0x3C
    jmp  isr_compb              ; vector 15, TIMER0_COMPB
    .org 0x40
    jmp  isr_ovf                ; vector 16, TIMER0_OVF

; ------------------------------------------------------------- programa
    .org 0x80
_start:
    ; pila en RAMEND
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    clr  r20                    ; cuenta de COMPA
    clr  r21                    ; cuenta de COMPB
    clr  r22                    ; cuenta de OVF
    clr  r23                    ; testigo del retardo de SEI

    ; ------------------------------------------------ Timer0
    ; Modo normal, TOP=0xFF, sin PWM y sin tocar los pines de comparación.
    ldi  r16, 0x00
    out  0x24, r16              ; TCCR0A
    ldi  r16, 0x55
    out  0x27, r16              ; OCR0A = 0x55
    ldi  r16, 0xAA
    out  0x28, r16              ; OCR0B = 0xAA

    ; TIMSK0 vive en 0x6E, fuera del alcance de IN/OUT: sólo LD/ST.
    ldi  r30, 0x6E
    ldi  r31, 0x00
    ldi  r16, 0x07              ; OCIE0B | OCIE0A | TOIE0
    st   Z, r16

    ; Arranca sin prescaler: una cuenta por ciclo de reloj.
    ldi  r16, 0x01
    out  0x25, r16              ; TCCR0B = CS00

    ; ------------------------------------ CLI es inmediato, SEI tiene retardo
    cli
    ldi  r24, 0x11              ; sección crítica: no puede entrar nada aquí
    ldi  r25, 0x22

    ; Se deja una bandera YA PENDIENTE antes de habilitar, para que el retardo
    ; de SEI se ejerza de verdad: con la cuenta en 0x54 y OCR0A en 0x55, la
    ; comparación salta en un par de ciclos. Escribir TCNT0 tapa la comparación
    ; del ciclo siguiente —por eso 0x54 y no 0x55—, así que hacen falta los NOP.
    ldi  r16, 0x54
    out  0x26, r16              ; TCNT0
    nop
    nop
    nop

    sei
    inc  r23                    ; ESTA instrucción se ejecuta SÍ o SÍ antes de
                                ; atender nada (trampa nº 2). El arnés lo
                                ; comprueba: si el RTL entra en la ISR justo
                                ; después del SEI, lo dice y para.

    ; ------------------------------------------------- bucle de trabajo
    ; Instrucciones normales para que pasen ciclos y las interrupciones caigan
    ; en sitios distintos del bucle. Se usan los GPIOR y PORTB, que son los
    ; únicos sitios de E/S que los dos lados modelan igual.
    ldi  r17, 0xFF
    out  0x04, r17              ; DDRB: puerto B a salida
loop:
    inc  r18
    out  0x05, r18              ; PORTB
    lsl  r19
    inc  r19
    out  0x1E, r19              ; GPIOR0
    subi r18, 0x03
    sbci r19, 0x01
    in   r16, 0x1E
    eor  r16, r18
    mov  r27, r16
    rjmp loop

; ------------------------------------------------------------------ ISR
; Cada una guarda el SREG a mano, como manda el AVR: el hardware no lo apila.
isr_compa:
    push r16
    in   r16, 0x3F              ; SREG
    push r16
    inc  r20
    pop  r16
    out  0x3F, r16
    pop  r16
    reti

isr_compb:
    push r16
    in   r16, 0x3F
    push r16
    inc  r21
    pop  r16
    out  0x3F, r16
    pop  r16
    reti

isr_ovf:
    push r16
    in   r16, 0x3F
    push r16
    inc  r22
    pop  r16
    out  0x3F, r16
    pop  r16
    reti
