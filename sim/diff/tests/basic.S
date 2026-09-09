; AxiomaCore-328 - primer programa de la co-simulación diferencial
; SPDX-License-Identifier: Apache-2.0
;
; Solo aritmética, lógica y registros: nada de periféricos, porque el espacio
; de I/O del RTL es memoria plana en la fase 1 y simavr sí los modela.

    .section .text
    .global _start
_start:
    ldi  r16, 0x00
    ldi  r17, 0x01
    ldi  r18, 0x7F
    ldi  r19, 0x80
    ldi  r20, 0xFF

    add  r16, r17          ; 0x00 + 0x01
    add  r18, r17          ; 0x7F + 0x01 -> desborda con signo
    add  r19, r20          ; 0x80 + 0xFF -> acarreo
    adc  r16, r17          ; con el acarreo anterior

    sub  r20, r17
    subi r20, 0x10
    sbc  r18, r19
    sbci r18, 0x01

    and  r16, r17
    or   r17, r18
    eor  r18, r18          ; queda a cero
    com  r19
    neg  r20
    inc  r16
    dec  r17
    lsr  r18
    ror  r19
    asr  r20
    swap r16

    mov  r21, r16
    movw r22, r16

    ; los CUATRO pares que admiten ADIW y SBIW, no solo r24:
    ; con uno solo, un fallo de selección de par pasa desapercibido
    ldi  r24, 0x34
    ldi  r25, 0x12
    ldi  r26, 0xFF
    ldi  r27, 0x00
    ldi  r28, 0x01
    ldi  r29, 0x00
    ldi  r30, 0x00
    ldi  r31, 0x80
    adiw r24, 0x01
    adiw r26, 0x01
    adiw r28, 0x3F
    adiw r30, 0x00
    sbiw r24, 0x20
    sbiw r26, 0x01
    sbiw r28, 0x02
    sbiw r30, 0x3F

    ldi  r16, 0x0F
    ldi  r17, 0x11
    mul  r16, r17
    muls r16, r17
    mulsu r16, r17
    fmul  r16, r17

    cp   r16, r17
    cpc  r16, r17
    cpi  r16, 0x0F

    ; fin
1:  rjmp 1b
