; AxiomaCore-328 - memoria de datos y pila
; SPDX-License-Identifier: Apache-2.0
;
; Cubre los modos de puntero, LDS/STS de 32 bits, el aliasing de los registros
; en 0x0000-0x001F, y PUSH/POP.

    .section .text
    .global _start
_start:
    ldi  r16, 0xFF
    out  0x3D, r16          ; SPL
    ldi  r16, 0x08
    out  0x3E, r16          ; SPH  -> pila en 0x08FF

    ; --- punteros a la SRAM ---
    ldi  r26, 0x00          ; X = 0x0200
    ldi  r27, 0x02
    ldi  r28, 0x10          ; Y = 0x0210
    ldi  r29, 0x02
    ldi  r30, 0x20          ; Z = 0x0220
    ldi  r31, 0x02

    ldi  r16, 0xA5
    st   X,   r16
    st   X+,  r16
    ldi  r16, 0x5A
    st   X+,  r16
    st   -X,  r16
    ldi  r17, 0x11
    st   Y,   r17
    st   Y+,  r17
    st   -Y,  r17
    std  Y+5, r17
    std  Y+63, r17
    st   Z,   r17
    st   Z+,  r17
    st   -Z,  r17
    std  Z+7, r17
    std  Z+31, r17

    ld   r18, X
    ld   r19, X+
    ld   r20, -X
    ld   r21, Y
    ld   r22, Y+
    ld   r23, -Y
    ldd  r24, Y+5
    ldd  r25, Y+63
    ld   r2,  Z
    ld   r3,  Z+
    ld   r4,  -Z
    ldd  r5,  Z+7
    ldd  r6,  Z+31

    ; --- LDS y STS, instrucciones de 32 bits ---
    ldi  r16, 0x77
    sts  0x0300, r16
    lds  r7, 0x0300
    sts  0x0301, r7
    lds  r8, 0x0301

    ; --- el espacio de datos 0x00-0x1F son los propios registros ---
    ldi  r26, 0x05          ; X = 0x0005  -> R5
    ldi  r27, 0x00
    ldi  r16, 0xC3
    st   X, r16             ; escribe R5
    ld   r9, X              ; lo lee de vuelta
    ldi  r26, 0x09          ; X = R9
    ld   r10, X

    ; --- pila ---
    ldi  r16, 0x12
    ldi  r17, 0x34
    push r16
    push r17
    pop  r18
    pop  r19
    push r16
    push r17
    push r18
    pop  r20
    pop  r21
    pop  r22

1:  rjmp 1b
