; AxiomaCore-328 - el bucle de limpieza de .bss que genera avr-gcc
; SPDX-License-Identifier: Apache-2.0
;
; Este programa no lo escribí yo: es LITERALMENTE lo que el enlazador de
; avr-gcc pone delante de `main` en cualquier binario con variables estáticas
; —`__do_clear_bss`—, copiado del desensamblado. Está aquí porque el gestor de
; arranque de la fase 4 se quedó colgado exactamente en él, dando vueltas sin
; salir, y un bucle que no termina no es algo que se pueda depurar a ojo: se
; lleva al oráculo y que hable simavr.
;
; El patrón que ejercita es `ST X+` seguido de una comparación de 16 bits con
; `CPI`/`CPC`, que es como el compilador compara punteros. Si el
; post-incremento o el acarreo entre los dos bytes no fueran exactos, el bucle
; recorrería la SRAM entera y daría la vuelta — que es justo el síntoma.

    .section .text
    .global _start
_start:
    ldi  r16, 0xFF
    out  0x3D, r16          ; SPL
    ldi  r16, 0x08
    out  0x3E, r16          ; SPH

    clr  r1                 ; el registro cero, como hace crt0

    ; --- el bucle, tal cual lo emite el enlazador ---
    ldi  r18, 0x01
    ldi  r26, 0x00
    ldi  r27, 0x01          ; X = 0x0100
    rjmp .Lcmp
.Lloop:
    st   X+, r1
.Lcmp:
    cpi  r26, 0x82
    cpc  r27, r18
    brne .Lloop             ; hasta X = 0x0182

    ; Lo que quede en X y en los flags es lo que el arnés compara. Si el bucle
    ; no terminara, el programa no llegaría aquí y el contraste lo diría.
    mov  r20, r26
    mov  r21, r27

    ; --- y el mismo patrón cruzando el acarreo del byte bajo ---
    ; De 0x01FE a 0x0202: el byte alto cambia a mitad del recorrido, que es
    ; donde un `CPC` mal hecho se delata.
    ldi  r18, 0x02
    ldi  r26, 0xFE
    ldi  r27, 0x01
    rjmp .Lcmp2
.Lloop2:
    st   X+, r1
.Lcmp2:
    cpi  r26, 0x02
    cpc  r27, r18
    brne .Lloop2
    mov  r22, r26
    mov  r23, r27

.Lfin:
    rjmp .Lfin
