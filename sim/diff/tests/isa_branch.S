; AxiomaCore-328 - las 16 ramas condicionales
; SPDX-License-Identifier: Apache-2.0
;
; Cada bit del SREG tiene dos ramas, una por polaridad. Se prueban las 16, cada
; una TOMADA y NO TOMADA, que son 1 y 2 ciclos respectivamente: es la única
; clase de instrucción, junto con los saltos, cuya duración depende del
; resultado.
;
;   C bit 0   BRCS / BRCC        V bit 3   BRVS / BRVC
;   Z bit 1   BREQ / BRNE        S bit 4   BRLT / BRGE
;   N bit 2   BRMI / BRPL        H bit 5   BRHS / BRHC
;   T bit 6   BRTS / BRTC        I bit 7   BRIE / BRID
;
; El SREG se fija ESCRIBIÉNDOLO ENTERO con OUT, no calculándolo con una
; operación aritmética: así cada rama se prueba con el flag exacto que le toca
; y no con el que dejó de rebote la instrucción anterior. Escribir S sin que
; coincida con N xor V es deliberado — el SREG es escribible y los dos lados
; tienen que aceptarlo igual.

    .section .text
    .global _start
_start:
    ldi  r16, 0xFF
    out  0x3D, r16
    ldi  r16, 0x08
    out  0x3E, r16

    clr  r20                ; cuenta de ramas tomadas que debían tomarse
    clr  r21                ; cuenta de ramas NO tomadas que no debían tomarse

    ; ------------------------------------------------------------- C, bit 0
    ldi  r16, 0x01
    out  0x3F, r16
    brcs 1f
    ldi  r22, 0xEE          ; no debe ejecutarse
1:  inc  r20
    brcc 2f
    inc  r21
2:  ldi  r16, 0x00
    out  0x3F, r16
    brcc 3f
    ldi  r22, 0xEE
3:  inc  r20
    brcs 4f
    inc  r21
4:
    ; ------------------------------------------------------------- Z, bit 1
    ldi  r16, 0x02
    out  0x3F, r16
    breq 5f
    ldi  r22, 0xEE
5:  inc  r20
    brne 6f
    inc  r21
6:  ldi  r16, 0x00
    out  0x3F, r16
    brne 7f
    ldi  r22, 0xEE
7:  inc  r20
    breq 8f
    inc  r21
8:
    ; ------------------------------------------------------------- N, bit 2
    ldi  r16, 0x04
    out  0x3F, r16
    brmi 9f
    ldi  r22, 0xEE
9:  inc  r20
    brpl 10f
    inc  r21
10: ldi  r16, 0x00
    out  0x3F, r16
    brpl 11f
    ldi  r22, 0xEE
11: inc  r20
    brmi 12f
    inc  r21
12:
    ; ------------------------------------------------------------- V, bit 3
    ldi  r16, 0x08
    out  0x3F, r16
    brvs 13f
    ldi  r22, 0xEE
13: inc  r20
    brvc 14f
    inc  r21
14: ldi  r16, 0x00
    out  0x3F, r16
    brvc 15f
    ldi  r22, 0xEE
15: inc  r20
    brvs 16f
    inc  r21
16:
    ; ------------------------------------------------------------- S, bit 4
    ldi  r16, 0x10
    out  0x3F, r16
    brlt 17f
    ldi  r22, 0xEE
17: inc  r20
    brge 18f
    inc  r21
18: ldi  r16, 0x00
    out  0x3F, r16
    brge 19f
    ldi  r22, 0xEE
19: inc  r20
    brlt 20f
    inc  r21
20:
    ; ------------------------------------------------------------- H, bit 5
    ldi  r16, 0x20
    out  0x3F, r16
    brhs 21f
    ldi  r22, 0xEE
21: inc  r20
    brhc 22f
    inc  r21
22: ldi  r16, 0x00
    out  0x3F, r16
    brhc 23f
    ldi  r22, 0xEE
23: inc  r20
    brhs 24f
    inc  r21
24:
    ; ------------------------------------------------------------- T, bit 6
    ldi  r16, 0x40
    out  0x3F, r16
    brts 25f
    ldi  r22, 0xEE
25: inc  r20
    brtc 26f
    inc  r21
26: ldi  r16, 0x00
    out  0x3F, r16
    brtc 27f
    ldi  r22, 0xEE
27: inc  r20
    brts 28f
    inc  r21
28:
    ; ------------------------------------------------------------- I, bit 7
    ; Con irq_req atado a 0 en el top de simulación y sin periféricos activos,
    ; poner I no dispara nada en ninguno de los dos lados.
    ldi  r16, 0x80
    out  0x3F, r16
    brie 29f
    ldi  r22, 0xEE
29: inc  r20
    brid 30f
    inc  r21
30: ldi  r16, 0x00
    out  0x3F, r16
    brid 31f
    ldi  r22, 0xEE
31: inc  r20
    brie 32f
    inc  r21
32:
    ; ---------------------------------- rama tomada con desplazamiento 0
    ; `brne .+0` avanza una palabra tanto si salta como si no, así que el PC no
    ; distingue los dos casos: son 2 ciclos frente a 1 y sólo el SREG lo dice.
    ldi  r16, 0x00
    out  0x3F, r16
    brne .+0
    ldi  r16, 0x02
    out  0x3F, r16
    brne .+0

    ; ------------------------------ rama hacia atrás, en un bucle real
    ldi  r23, 0x05
33: dec  r23
    brne 33b

    ; ---------------------------- desplazamiento largo, cerca del límite
    ; El campo de las ramas es de 7 bits con signo: -64..+63 palabras.
    ldi  r16, 0x02
    out  0x3F, r16
    breq 34f
    ldi  r22, 0xEE
    .rept 40
    nop
    .endr
34: inc  r20

35: rjmp 35b
