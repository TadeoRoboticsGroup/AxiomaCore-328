; AxiomaCore-328 - control del sistema, inmediatos lógicos y multiplicación con signo
; SPDX-License-Identifier: Apache-2.0
;
; NOP, WDR, BREAK, RETI, ANDI, ORI, FMULS, FMULSU y SLEEP.
;
; DOS INSTRUCCIONES CON TRATO ESPECIAL EN simavr:
;
;   BREAK  sin un gdb conectado no hace nada, igual que aquí. Es comparable.
;   SLEEP  pone el núcleo de simavr en `cpu_Sleeping` y el arnés termina ahí,
;          porque su bucle sólo avanza mientras simavr esté corriendo. Por eso
;          SLEEP es la ÚLTIMA instrucción del programa: si estuviera en medio,
;          todo lo que viniera detrás quedaría sin ejecutar en silencio.
;
; SPM no está: el manual no le fija ciclos —dependen del backend de memoria de
; programa— y la emulación de simavr no es comparable. Ver docs/01-arquitectura.md.

    .section .text
    .global _start
_start:
    ldi  r16, 0xFF
    out  0x3D, r16
    ldi  r16, 0x08
    out  0x3E, r16

    ; ------------------------------------------------------ ANDI y ORI
    ldi  r16, 0xF0
    andi r16, 0x3C          ; 0x30
    ori  r16, 0x03          ; 0x33
    ldi  r17, 0xFF
    andi r17, 0x00          ; 0x00, pone Z
    ori  r17, 0x80          ; 0x80, pone N
    ldi  r18, 0x0F
    andi r18, 0xF0          ; 0x00
    ori  r18, 0xFF          ; 0xFF
    andi r18, 0x7F          ; limpia N

    ; -------------------------------------- multiplicación fraccional
    ; FMULS y FMULSU sólo admiten R16..R23.
    ldi  r16, 0x40          ; +0.5 en Q1.7
    ldi  r17, 0x40
    fmuls r16, r17          ; R1:R0
    ldi  r18, 0x80          ; -1.0
    ldi  r19, 0x40
    fmuls r18, r19
    fmulsu r18, r19
    ldi  r20, 0x7F
    ldi  r21, 0xFF
    fmuls r20, r21
    fmulsu r20, r21
    fmul r20, r21

    ; ------------------------------------------------------------ RETI
    ; Se llega con RCALL y se vuelve con RETI, que además pone I. No hay
    ; interrupciones activas, así que poner I no dispara nada.
    rcall rutina
    in   r9, 0x3F           ; SREG con I puesto por el RETI
    cli
    in   r10, 0x3F

    ; ------------------------------------------- NOP, WDR y BREAK
    nop
    nop
    wdr
    break
    nop
    wdr

    ; ----------------------- que las tres dejan el estado intacto
    ldi  r22, 0x5A
    ldi  r23, 0x00
    sec                     ; C = 1
    nop
    wdr
    break
    brcs 1f                 ; C tiene que seguir puesto
    ldi  r23, 0xEE          ; no debe ejecutarse
1:  ldi  r23, 0x11

    rjmp fin

rutina:
    inc  r11
    reti

fin:
    ; SLEEP la última: simavr pasa a cpu_Sleeping y el arnés para aquí.
    sleep
2:  rjmp 2b
