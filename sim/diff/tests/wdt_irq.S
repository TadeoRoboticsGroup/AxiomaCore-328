; AxiomaCore-328 - la interrupción del perro guardián
; SPDX-License-Identifier: Apache-2.0
;
; POR QUÉ EXISTE: lo mismo que `adc_irq.S` y `ac_irq.S` — que el vector 6 esté
; bien cableado no lo puede comprobar el banco del periférico, que no ve el SoC.
;
; Y aquí hay algo más que sólo se ve a nivel de SoC: que `WDR` LLEGUE. La
; instrucción es un NOP para el núcleo, así que el decodificador y el
; secuenciador la dan por buena sin que nadie note si el pulso sale o no. Este
; programa la usa de las dos maneras: rearmando a tiempo —y entonces el perro no
; muerde— y dejando de rearmar —y entonces sí—.
;
; AQUÍ NO SE LEE `WDTCSR`. La espera va sobre el contador que incrementa la ISR,
; que es lo que está en lockstep porque el arnés le levanta a simavr el mismo
; vector que tomó el RTL.
;
; SE USA EL MODO DE SÓLO INTERRUPCIÓN: con `WDE` puesto, el perro reiniciaría el
; chip, y el arnés diferencial no puede seguir eso —simavr no se reiniciaría—.
; Está dicho en el top del banco: allí el reinicio se declara sin usar.

    .section .text
    .global _start

    .org 0x00
    jmp  _start
    .org 0x0C                   ; vector 6, WDT
    jmp  isr_wdt

    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    clr  r20                    ; entradas a la ISR

    ; WDIE sin WDE: sólo interrumpe. El prescaler más corto, WDP=0.
    ; WDIE no está protegido por la secuencia temporizada, así que una
    ; escritura basta.
    ldi  r16, 0x40              ; WDIE
    sts  0x0060, r16            ; WDTCSR

    sei

    ; PRIMERO, REARMANDO A TIEMPO: el perro no debe morder. 400 vueltas de un
    ; bucle con WDR dentro son muchas más que un periodo, y r20 tiene que
    ; seguir a cero al salir.
    ldi  r21, 200
rearma:
    wdr
    nop
    nop
    dec  r21
    brne rearma

    ; r20 sigue a cero si WDR llega de verdad. Se guarda en GPIOR0, que es
    ; almacenamiento puro en los dos lados y sí se compara.
    out  0x1E, r20              ; GPIOR0

    ; Y AHORA SIN REARMAR: el perro muerde, una y otra vez.
espera:
    cpi  r20, 4
    brlo espera

    ; Apagar y parar. SLEEP tiene que ser la ÚLTIMA instrucción.
    clr  r16
    sts  0x0060, r16
    cli
    sleep

isr_wdt:
    push r16
    in   r16, 0x3F
    push r16
    inc  r20
    ; La bandera se limpia sola al atender el vector, y WDIE sigue puesto
    ; porque WDE está a cero: en modo de sólo interrupción el perro vuelve a
    ; morder cada periodo.
    pop  r16
    out  0x3F, r16
    pop  r16
    reti
