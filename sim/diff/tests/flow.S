; AxiomaCore-328 - control de flujo
; SPDX-License-Identifier: Apache-2.0
;
; Ramas, saltos, llamadas y —lo más delicado— los SALTOS DE INSTRUCCIÓN sobre
; instrucciones de 32 bits, que es la trampa nº 1 del ISA: CPSE, SBRC, SBRS,
; SBIC y SBIS descartan una palabra o DOS según el tamaño de la siguiente.

    .section .text
    .global _start
_start:
    ldi  r16, 0xFF
    out  0x3D, r16
    ldi  r16, 0x08
    out  0x3E, r16

    ; --- ramas condicionales, tomadas y no tomadas ---
    ldi  r16, 0x00
    ldi  r17, 0x00
    cp   r16, r17
    breq 1f
    ldi  r20, 0xEE          ; no debe ejecutarse
1:  ldi  r16, 0x01
    cp   r16, r17
    breq 2f
    ldi  r21, 0xAA          ; sí debe ejecutarse
2:  ldi  r16, 0x80
    ldi  r17, 0x01
    add  r16, r17
    brmi 3f
    ldi  r22, 0xBB
3:  sub  r16, r17
    brcc 4f
    ldi  r23, 0xCC
4:  ldi  r16, 0x0F
    sbrc r16, 0            ; bit 0 = 1 -> NO salta
    ldi  r24, 0x01
    sbrs r16, 0            ; bit 0 = 1 -> SÍ salta (16 bits)
    ldi  r24, 0x02

    ; --- salto sobre una instrucción de 32 BITS: hay que descartar 2 palabras ---
    ldi  r16, 0x0F
    sbrs r16, 0            ; salta la siguiente
    sts  0x0400, r16       ; 32 bits: si solo se descarta 1 palabra, se ejecuta basura
    ldi  r25, 0x99         ; aquí debe caer

    ldi  r16, 0x00
    sbrc r16, 0            ; bit 0 = 0 -> salta
    lds  r2, 0x0400        ; 32 bits
    ldi  r19, 0x88

    ; --- CPSE sobre 16 y 32 bits ---
    ldi  r16, 0x42
    ldi  r17, 0x42
    cpse r16, r17          ; iguales -> salta
    ldi  r18, 0xFF         ; 16 bits, se descarta
    ldi  r20, 0x11
    cpse r16, r17
    sts  0x0401, r16       ; 32 bits, se descartan 2 palabras
    ldi  r26, 0x22
    ldi  r17, 0x43
    cpse r16, r17          ; distintos -> NO salta
    ldi  r27, 0x33

    ; --- llamadas y retornos ---
    rcall sub_a
    rcall sub_a
    ldi  r30, pm_lo8(sub_b)   ; ICALL usa dirección de PALABRA
    ldi  r31, pm_hi8(sub_b)
    icall
    call sub_a             ; 32 bits
    rjmp fin

sub_a:
    inc  r10
    ret

sub_b:
    inc  r11
    ret

fin:
    ; --- saltos ---
    ldi  r30, pm_lo8(destino) ; IJMP idem
    ldi  r31, pm_hi8(destino)
    ijmp
    ldi  r28, 0xDE         ; no debe ejecutarse
destino:
    inc  r13
    jmp  final              ; 32 bits

final:
    inc  r14
5:  rjmp 5b
