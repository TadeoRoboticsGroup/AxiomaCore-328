; AxiomaCore-328 - instrucciones de bit y de espacio de I/O
; SPDX-License-Identifier: Apache-2.0
;
; IN, OUT, SBI, CBI, SBIC, SBIS, BLD, BST, SWAP y los 16 alias de BSET/BCLR.
;
; QUÉ DIRECCIONES DE I/O SE PUEDEN USAR EN LA FASE 1. El espacio de I/O del RTL
; es memoria plana y simavr sí modela periféricos, así que tocar un periférico
; haría divergir el contraste sin que hubiera nada roto. Los GPIOR son la
; excepción: son almacenamiento puro en los dos lados.
;
;   GPIOR0   dato 0x3E   I/O 0x1E   <- dentro de 0x00-0x1F: lo alcanzan SBI,
;                                      CBI, SBIC y SBIS, que no llegan más allá
;   GPIOR1   dato 0x4A   I/O 0x2A   <- sólo IN y OUT
;   GPIOR2   dato 0x4B   I/O 0x2B   <- sólo IN y OUT
;
; SPL, SPH y SREG también valen: axioma_core los intercepta antes del bus.

    .section .text
    .global _start
_start:
    ldi  r16, 0xFF
    out  0x3D, r16          ; SPL
    ldi  r16, 0x08
    out  0x3E, r16          ; SPH  -> pila en 0x08FF

    ; --------------------------------------------- IN y OUT sobre los GPIOR
    ldi  r16, 0xA5
    out  0x1E, r16          ; GPIOR0
    in   r17, 0x1E
    ldi  r18, 0x5A
    out  0x2A, r18          ; GPIOR1
    in   r19, 0x2A
    ldi  r20, 0x3C
    out  0x2B, r20          ; GPIOR2
    in   r21, 0x2B
    in   r22, 0x3F          ; SREG, que sí está soportado

    ; ------------------------------------------------------- SBI y CBI
    ; Leen, modifican un bit y escriben: 2 ciclos, y la lectura se lanza y se
    ; consume en el mismo ciclo por el flanco de bajada de la memoria.
    ldi  r16, 0x00
    out  0x1E, r16
    sbi  0x1E, 0
    sbi  0x1E, 7
    sbi  0x1E, 3
    in   r23, 0x1E          ; 0x89
    cbi  0x1E, 0
    cbi  0x1E, 7
    in   r24, 0x1E          ; 0x08
    sbi  0x1E, 5
    cbi  0x1E, 3
    in   r25, 0x1E          ; 0x20

    ; --------------------------------------- SBIC y SBIS, con y sin salto
    ldi  r16, 0x01
    out  0x1E, r16
    ; LDI sólo admite R16..R31, así que los testigos van en registros altos.
    sbic 0x1E, 0            ; bit 0 = 1 -> NO salta
    ldi  r26, 0x11
    sbis 0x1E, 0            ; bit 0 = 1 -> SÍ salta, 16 bits
    ldi  r26, 0x22          ; no debe ejecutarse
    sbic 0x1E, 1            ; bit 1 = 0 -> SÍ salta
    sts  0x0300, r16        ; 32 bits: hay que descartar DOS palabras
    ldi  r27, 0x33
    sbis 0x1E, 1            ; bit 1 = 0 -> NO salta
    ldi  r28, 0x44
    sbis 0x1E, 0            ; SÍ salta, y lo saltado es de 32 bits
    lds  r5, 0x0300         ; no debe ejecutarse
    ldi  r29, 0x55

    ; ------------------------------------------------------- BST y BLD
    ldi  r16, 0x80
    bst  r16, 7             ; T <- 1
    ldi  r17, 0x00
    bld  r17, 0             ; r17 = 0x01
    bld  r17, 4             ; r17 = 0x11
    ldi  r18, 0x00
    bst  r18, 3             ; T <- 0
    ldi  r19, 0xFF
    bld  r19, 5             ; borra el bit 5 -> 0xDF
    bld  r19, 0             ; -> 0xDE

    ; ----------------------------------------------------------- SWAP
    ldi  r20, 0x3C
    swap r20                ; 0xC3
    swap r20                ; 0x3C de vuelta
    ldi  r21, 0xF0
    swap r21                ; 0x0F

    ; ------------------------------------ los 16 alias de BSET y BCLR
    ; SEI va antes de CLI a propósito: SEI tiene un ciclo de gracia y CLI es
    ; inmediato, así que el orden importa aunque aquí no haya interrupciones.
    sec
    sez
    sen
    sev
    ses
    seh
    set
    in   r7, 0x3F           ; SREG con todo puesto menos I
    clc
    clz
    cln
    clv
    cls
    clh
    clt
    in   r8, 0x3F
    sei
    cli

1:  rjmp 1b
