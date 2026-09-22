; AxiomaCore-328 - la interrupción de la EEPROM
; SPDX-License-Identifier: Apache-2.0
;
; POR QUÉ EXISTE: lo mismo que `adc_irq.S`, `ac_irq.S` y `wdt_irq.S` — que el
; vector 22 esté bien cableado no lo puede comprobar el banco del periférico,
; que no ve el SoC. Con éste, los 25 vectores tienen fuente salvo `SPM_READY`,
; que es de la fase 4.
;
; Y AQUÍ HAY UNA TRAMPA QUE NO TIENEN LOS OTROS TRES: `EE_READY` ES DE NIVEL, no
; de bandera. «The interrupt is constantly triggered when EEPE is cleared», dice
; la hoja de datos — así que no hay nada que limpiar al atender el vector, y una
; ISR que se limite a contar **no sale nunca**: en cuanto hace `reti`, la
; petición sigue ahí y se vuelve a entrar.
;
; La ISR tiene que QUITAR `EERIE`. Es lo que hace cualquier rutina de guardado
; de verdad, y es la razón de que este módulo no tenga `ack`: inventarle una
; bandera habría sido más cómodo y menos compatible.
;
; AQUÍ NO SE LEE `EECR`. La grabación tarda 3,4 ms contados con el oscilador
; interno, y simavr no los cuenta: sondear `EEPE` sería comparar dos relojes,
; que es la lección que dejó `adc_irq.S`. La espera va sobre el contador de la
; ISR, que sí está en lockstep porque el arnés le levanta a simavr el mismo
; vector que tomó el RTL.

    .section .text
    .global _start

    .org 0x00
    jmp  _start
    .org 0x2C                   ; vector 22, EE_READY
    jmp  isr_ee

    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    clr  r20                    ; entradas a la ISR

    sei

lazo:
    ; Dirección y dato. EEARH primero, que es lo que hace avr-libc.
    clr  r16
    out  0x22, r16              ; EEARH
    mov  r16, r20
    out  0x21, r16              ; EEARL: una celda distinta cada vuelta
    ldi  r16, 0xA5
    out  0x20, r16              ; EEDR

    ; LA SECUENCIA TEMPORIZADA, con EERIE puesto de paso: EEMPE primero y EEPE
    ; dentro de los cuatro ciclos siguientes. Entre las dos no puede haber nada
    ; que tarde, y por eso van seguidas.
    ldi  r16, 0x0C              ; EERIE | EEMPE
    out  0x1F, r16              ; EECR
    ldi  r16, 0x0A              ; EERIE | EEPE
    out  0x1F, r16

    ; A esperar. La ISR quita EERIE, así que el contador sube UNA vez por
    ; grabación: si la interrupción fuera de flanco y no de nivel, esto seguiría
    ; funcionando — lo que no funcionaría es una ISR que no quitara EERIE.
espera:
    mov  r21, r20
    cp   r21, r22
    breq espera
    mov  r22, r20               ; ya vista

    cpi  r20, 3
    brlo lazo

    ; Comprobar que lo grabado está ahí: EERE deja el byte en EEDR.
    clr  r16
    out  0x21, r16              ; EEARL = 0
    ldi  r16, 0x01              ; EERE
    out  0x1F, r16
    in   r23, 0x20              ; EEDR
    out  0x1E, r23              ; GPIOR0, que sí se compara

    cli
    sleep

isr_ee:
    push r16
    in   r16, 0x3F
    push r16
    inc  r20
    ; QUITAR EERIE, o no se sale de aquí: la petición es un NIVEL y sigue ahí
    ; en cuanto se ejecute el `reti`.
    clr  r16
    out  0x1F, r16              ; EECR = 0
    pop  r16
    out  0x3F, r16
    pop  r16
    reti
