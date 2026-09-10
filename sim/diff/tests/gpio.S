; AxiomaCore-328 - puertos de entrada/salida
; SPDX-License-Identifier: Apache-2.0
;
; PINx, DDRx y PORTx de los tres puertos, incluida la TRAMPA Nº 5: escribir un
; 1 en PINx conmuta el bit correspondiente de PORTx.
;
; EL NOP NO ES DECORATIVO. Entre escribir PORTx y leer PINx hay que dejar pasar
; una instrucción, porque el valor del pad pasa por un sincronizador. Es el
; idioma que aparece en todo el código AVR que lee de vuelta un pin recién
; escrito, y aquí es obligatorio: sin él se lee el valor ANTERIOR.
;
; TRES DIFERENCIAS CONOCIDAS CON simavr. En las dos primeras el que se aparta
; de la hoja de datos es simavr; la tercera no la define nadie:
;   - su modelo de ioport NO tiene sincronizador y devuelve PORTx al instante;
;   - no enmascara el bit 7 del puerto C, que en el 328P no existe;
;   - al APAGAR el pull-up de un pin de entrada, simavr conserva el ultimo
;     valor leido y este arnes lo suelta a 0. En un chip real ese pin queda
;     FLOTANDO y lo que se lee es indefinido, igual que los casos de "resultado
;     indefinido" del manual del ISA. Ningun programa debe depender de ello, y
;     este no lo hace: cuando lee PINx, o el pin es salida, o su pull-up sigue
;     encendido.
; Respetando esas tres cosas los dos lados coinciden, y lo que se verifica es
; el comportamiento del chip.

    .section .text
    .global _start
_start:
    ldi  r16, 0xFF
    out  0x3D, r16
    ldi  r16, 0x08
    out  0x3E, r16

    ; ------------------------------------------- puerto B, todo salida
    ldi  r16, 0xFF
    out  0x04, r16          ; DDRB = 0xFF
    ldi  r16, 0xA5
    out  0x05, r16          ; PORTB = 0xA5
    nop                     ; el sincronizador necesita un ciclo
    in   r17, 0x03          ; PINB  -> 0xA5
    in   r18, 0x05          ; PORTB -> 0xA5
    in   r19, 0x04          ; DDRB  -> 0xFF

    ; --------------------------- trampa 5: escribir PINx conmuta PORTx
    ldi  r16, 0x0F
    out  0x03, r16          ; PINB: conmuta los cuatro bits bajos
    nop
    in   r20, 0x05          ; PORTB -> 0xAA
    in   r21, 0x03          ; PINB  -> 0xAA
    ldi  r16, 0xFF
    out  0x03, r16          ; conmuta los ocho
    nop
    in   r22, 0x05          ; PORTB -> 0x55

    ; el toggle funciona tambien con el pin como ENTRADA
    ldi  r16, 0x00
    out  0x04, r16          ; DDRB = 0x00, todo entrada
    ldi  r16, 0xF0
    out  0x03, r16          ; sigue conmutando PORTB
    in   r23, 0x05          ; PORTB -> 0xA5

    ; ------------------------------------------- puerto D, mitad y mitad
    ldi  r16, 0x0F
    out  0x0A, r16          ; DDRD = 0x0F: bajos salida, altos entrada
    ldi  r16, 0xFF
    out  0x0B, r16          ; PORTD = 0xFF
    nop
    in   r24, 0x09          ; PIND: salidas a 1 y entradas con pull-up -> 0xFF
    in   r25, 0x0B          ; PORTD -> 0xFF
    ; Se cambian solo los bits de SALIDA. Los de entrada mantienen su pull-up
    ; encendido: apagarlo dejaria el pin flotando y la lectura seria indefinida.
    ldi  r16, 0xF3
    out  0x0B, r16          ; salidas 0011, entradas siguen con pull-up
    nop
    in   r26, 0x09          ; PIND -> 0xF3

    ; ------------------------------------------- puerto C, siete bits
    ; No se toca PC7: no existe en el 328P y simavr no lo enmascara.
    ldi  r16, 0x7F
    out  0x07, r16          ; DDRC = 0x7F
    ldi  r16, 0x55
    out  0x08, r16          ; PORTC = 0x55
    nop
    in   r2, 0x06           ; PINC  -> 0x55
    in   r3, 0x08           ; PORTC -> 0x55
    in   r4, 0x07           ; DDRC  -> 0x7F
    ldi  r16, 0x2A
    out  0x06, r16          ; PINC: conmuta
    nop
    in   r5, 0x08           ; PORTC -> 0x7F

    ; --------------------------- que un puerto no pisa a los otros
    in   r6, 0x05           ; PORTB
    in   r7, 0x0B           ; PORTD
    in   r8, 0x08           ; PORTC

    ; --------------------------- SBI y CBI sobre un puerto de verdad
    ldi  r16, 0xFF
    out  0x04, r16          ; DDRB = 0xFF
    ldi  r16, 0x00
    out  0x05, r16          ; PORTB = 0x00
    sbi  0x05, 0
    sbi  0x05, 7
    nop
    in   r9,  0x05          ; PORTB -> 0x81
    in   r10, 0x03          ; PINB  -> 0x81
    cbi  0x05, 0
    nop
    in   r11, 0x05          ; PORTB -> 0x80

    ; --------------------------- SBIC y SBIS sobre PINB
    sbic 0x03, 7            ; bit 7 = 1 -> NO salta
    ldi  r27, 0x11
    sbis 0x03, 7            ; bit 7 = 1 -> SI salta
    ldi  r27, 0x22
    sbic 0x03, 0            ; bit 0 = 0 -> SI salta
    ldi  r28, 0x33
    ldi  r29, 0x44

1:  rjmp 1b
