; AxiomaCore-328 - LPM en sus tres formas
; SPDX-License-Identifier: Apache-2.0
;
;   1001 0101 1100 1000        LPM          implícito: R0 <- (Z)
;   1001 000d dddd 0100        LPM Rd, Z
;   1001 000d dddd 0101        LPM Rd, Z+   con post-incremento de Z
;
; Z ES UNA DIRECCIÓN DE BYTE, no de palabra. Por eso las etiquetas van con
; lo8()/hi8() y no con pm_lo8()/pm_hi8(), que son las de ICALL e IJMP. El bit 0
; de Z elige el byte bajo o el alto de la palabra de programa.
;
; Son 3 ciclos: el puerto de datos de la memoria de programa está registrado en
; flanco de subida y el secuenciador espera un ciclo entero antes de tomar el
; dato.

    .section .text
    .global _start
_start:
    ldi  r16, 0xFF
    out  0x3D, r16
    ldi  r16, 0x08
    out  0x3E, r16

    ; ------------------------------------------- LPM implícito, sobre R0
    ldi  r30, lo8(tabla)
    ldi  r31, hi8(tabla)
    lpm                     ; R0 <- 0x11

    ; --------------------------------------------------- LPM Rd, Z
    ldi  r30, lo8(tabla)
    ldi  r31, hi8(tabla)
    lpm  r18, Z             ; 0x11, byte bajo de la palabra
    ldi  r30, lo8(tabla+1)
    ldi  r31, hi8(tabla+1)
    lpm  r19, Z             ; 0x22, byte alto: el bit 0 de Z lo elige

    ; -------------------------------------------------- LPM Rd, Z+
    ldi  r30, lo8(tabla)
    ldi  r31, hi8(tabla)
    lpm  r20, Z+            ; 0x11, Z pasa a tabla+1
    lpm  r21, Z+            ; 0x22
    lpm  r22, Z+            ; 0x33
    lpm  r23, Z+            ; 0x44
    lpm  r24, Z+            ; 0x55
    lpm  r25, Z+            ; 0x66
    lpm  r26, Z+            ; 0x77
    lpm  r27, Z             ; 0x88, sin incrementar

    ; ----------------------- recorrido con puntero, que es el uso real
    ldi  r30, lo8(tabla)
    ldi  r31, hi8(tabla)
    ldi  r28, 0x00          ; Y = 0x0200, destino en SRAM
    ldi  r29, 0x02
    ldi  r17, 8
1:  lpm  r16, Z+
    st   Y+, r16
    dec  r17
    brne 1b

    ; --------------------- el acarreo del post-incremento entre bytes
    ; Z pasa de 0x00FF a 0x0100: si el incremento no propagara al byte alto,
    ; el siguiente LPM leería una dirección equivocada.
    ;
    ; Los datos del borde tienen que estar PROGRAMADOS. No vale apuntar a una
    ; dirección vacía: simavr inicializa la flash a 0xFF, como una flash
    ; borrada de verdad, y axioma_progmem la inicializa a 0x0000, que es NOP.
    ; Leer flash sin programar hace divergir el contraste sin que haya nada
    ; roto — es un fallo del programa de prueba.
    ldi  r30, lo8(borde)
    ldi  r31, hi8(borde)
    lpm  r5, Z+             ; 0xAD, en 0x00FF; Z pasa a 0x0100
    lpm  r6, Z              ; 0xBE, ya con el byte alto incrementado

2:  rjmp 2b

    .balign 2
tabla:
    .byte 0x11, 0x22, 0x33, 0x44, 0x55, 0x66, 0x77, 0x88
    .balign 2
relleno:
    .byte 0x99, 0xAA, 0xBB, 0xCC

    ; El relleno de .org va al binario, así que los dos lados leen lo mismo.
    .org 0xFF
borde:
    .byte 0xAD, 0xBE, 0xEF
