; AxiomaCore-328 - los cuatro vectores del Timer1
; SPDX-License-Identifier: Apache-2.0
;
; La cobertura enseñó la lección con la USART: un periférico verificado cuyos
; vectores no dispara nadie NO está verificado. El cableado de vectores es donde
; apareció el primer fallo del Timer0, así que aquí se ejercitan los cuatro.
;
;   TIMER1_CAPT   vector 10, byte 0x28
;   TIMER1_COMPA  vector 11, byte 0x2C
;   TIMER1_COMPB  vector 12, byte 0x30
;   TIMER1_OVF    vector 13, byte 0x34
;
; LA CAPTURA SE DISPARA SOLA, sin nada conectado por fuera: ICP1 es PB0, así que
; el programa pone PB0 como salida y lo conmuta. En el modelo de pad del banco
; un pin de salida se lee a sí mismo, de modo que el chip se provoca su propia
; captura. Es legítimo y es lo que haría cualquiera probando la placa.
;
; LO QUE NO SE TOCA: TCNT1 y TIFR1. simavr interpola la cuenta desde su propio
; contador de ciclos y no modela el registro TEMP, así que leerlos haría
; divergir el contraste sin que haya nada roto. Lo que sí se compara —TCCR1A/B,
; TIMSK1, OCR1A/B, ICR1— es almacenamiento en los dos lados.

    .section .text
    .global _start

    .org 0x00
    jmp  _start
    .org 0x28
    jmp  isr_capt
    .org 0x2C
    jmp  isr_compa
    .org 0x30
    jmp  isr_compb
    .org 0x34
    jmp  isr_ovf

    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16
    ldi  r16, 0x08
    out  0x3E, r16

    clr  r20                    ; capturas
    clr  r21                    ; comparaciones A
    clr  r22                    ; comparaciones B
    clr  r23                    ; desbordamientos

    ; PB0 a salida: es ICP1, y con eso el programa se provoca la captura.
    ldi  r16, 0x01
    out  0x04, r16              ; DDRB
    out  0x05, r16              ; PORTB = 1: primer flanco de subida

    ; Timer1 en modo normal. TOP es 0xFFFF, asi que se precarga la cuenta
    ; cerca del final para que desborde enseguida.
    ldi  r28, 0x80
    ldi  r29, 0x00              ; Y apunta a TCCR1A

    ldi  r16, 0x00
    std  Y+0, r16               ; TCCR1A: sin PWM, pines sueltos

    ; OCR1A y OCR1B, con el orden que manda la hoja de datos: ALTO y luego BAJO.
    ldi  r16, 0xFF
    std  Y+9, r16               ; OCR1AH
    ldi  r16, 0xF8
    std  Y+8, r16               ; OCR1AL  -> 0xFFF8
    ldi  r16, 0xFF
    std  Y+11, r16              ; OCR1BH
    ldi  r16, 0xFC
    std  Y+10, r16              ; OCR1BL  -> 0xFFFC

    ; Las cuatro interrupciones del Timer1. TIMSK1 esta en 0x6F.
    ldi  r30, 0x6F
    ldi  r31, 0x00
    ldi  r16, 0x01              ; se arranca sólo con TOIE1; el bucle las rota
    st   Z, r16

    ldi  r16, 0xFF
    std  Y+5, r16               ; TCNT1H
    ldi  r16, 0xF0
    std  Y+4, r16               ; TCNT1L  -> 0xFFF0

    sei
    ldi  r16, 0x01
    std  Y+1, r16               ; TCCR1B = CS10: arranca sin prescaler

    ; --------------------------------------------------------------------
    ; SE HABILITA UNA SOLA INTERRUPCIÓN CADA VEZ, y no es un capricho: con las
    ; cuatro puestas, intercambiar dos vectores es INVISIBLE. El arnés le dice a
    ; simavr qué vector tomó el RTL, así que simavr no puede desmentirlo
    ; mientras la habilitación esté puesta. Se comprobó inyectando justo ese
    ; fallo —dos vectores del Timer1 cambiados— y SOBREVIVÍA a todo el banco.
    ;
    ; Con una sola habilitada, un vector mal cableado hace que simavr se niegue
    ; a atenderlo, y el arnés lo dice. La fase cambia cada 16 vueltas.
bucle:
    ; Recargar TCNT1 cerca del final para que los tres eventos del contador
    ; —COMPA, COMPB y desbordamiento— ocurran en cada vuelta, sea cual sea la
    ; interrupción habilitada en esta fase.
    ldi  r16, 0xFF
    std  Y+5, r16               ; TCNT1H
    ldi  r16, 0xF0
    std  Y+4, r16               ; TCNT1L

    inc  r24
    mov  r16, r24
    swap r16                    ; los bits 7:4 pasan a 3:0
    andi r16, 0x03              ; cuatro fases, de 16 vueltas cada una

    ldi  r17, 0x01              ; fase 0: TOIE1
    cpi  r16, 1
    brne .+2
    ldi  r17, 0x02              ; fase 1: OCIE1A
    cpi  r16, 2
    brne .+2
    ldi  r17, 0x04              ; fase 2: OCIE1B
    cpi  r16, 3
    brne .+2
    ldi  r17, 0x20              ; fase 3: ICIE1
    st   Z, r17                 ; TIMSK1

    ; Conmutar PB0 provoca capturas. `PINx` conmuta `PORTx`: la trampa nº 5.
    ldi  r17, 0x01
    out  0x03, r17              ; PINB
    inc  r18
    out  0x1E, r18              ; GPIOR0
    rjmp bucle

; ---------------------------------------------------------------------- ISR
isr_capt:
    push r16
    in   r16, 0x3F
    push r16
    inc  r20
    pop  r16
    out  0x3F, r16
    pop  r16
    reti

isr_compa:
    push r16
    in   r16, 0x3F
    push r16
    inc  r21
    pop  r16
    out  0x3F, r16
    pop  r16
    reti

isr_compb:
    push r16
    in   r16, 0x3F
    push r16
    inc  r22
    pop  r16
    out  0x3F, r16
    pop  r16
    reti

isr_ovf:
    push r16
    in   r16, 0x3F
    push r16
    inc  r23
    pop  r16
    out  0x3F, r16
    pop  r16
    reti
