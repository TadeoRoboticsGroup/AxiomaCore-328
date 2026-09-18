; AxiomaCore-328 - la interrupción del comparador analógico
; SPDX-License-Identifier: Apache-2.0
;
; POR QUÉ EXISTE ESTE PROGRAMA. Por lo mismo que `adc_irq.S`: que el vector 23
; esté BIEN CABLEADO no lo puede comprobar el banco del periférico, que no ve el
; SoC. Sin un programa que lo dispare, mover el comparador al vector del ADC o
; al de la EEPROM pasa la regresión entera.
;
; CÓMO SE LE MUEVE LA SALIDA A UN COMPARADOR DESDE UN PROGRAMA, que es la parte
; interesante. La entrada positiva es `AIN0` y la negativa `AIN1`, y ninguna de
; las dos la controla el programa — son pines. Pero la tabla 22-1 da una puerta:
; con `ACME` puesto y el ADC APAGADO, la entrada negativa sale del multiplexor
; del ADC, o sea del canal que diga `ADMUX`.
;
; Así que cambiar `ADMUX` mueve la entrada negativa, y con ella la salida del
; comparador. Es exactamente para lo que existe `ACME`: comparar `AIN0` contra
; cualquiera de los ocho canales sin gastar pines.
;
; AQUÍ NO SE LEE `ACSR`. simavr no modela este periférico en absoluto, así que
; `ACO` no existe de su lado: leerlo sería comparar un registro contra un hueco.
; La espera se hace sobre el contador que incrementa la ISR, que es lo que sí
; está en lockstep porque el arnés le levanta a simavr el mismo vector.
;
; UNA SOLA INTERRUPCIÓN HABILITADA, como manda la regla del proyecto.

    .section .text
    .global _start

    .org 0x00
    jmp  _start
    .org 0x2E                   ; vector 23, ANALOG_COMP
    jmp  isr_ac

    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    clr  r20                    ; cuántas veces se ha entrado en la ISR

    ; El ADC APAGADO: es la condición de la tabla 22-1 para que el multiplexor
    ; alimente al comparador. Con el ADC encendido manda el ADC.
    clr  r16
    sts  0x007A, r16            ; ADCSRA = 0

    ; ACME en ADCSRB: la entrada negativa pasa a ser el canal de ADMUX.
    ldi  r16, 0x40
    sts  0x007B, r16            ; ADCSRB

    ; ACIS = 00: interrumpe en LOS DOS flancos, así que cada cambio de canal
    ; deja una entrada a la ISR.
    ldi  r17, 0x18              ; ACI | ACIE
    out  0x30, r17              ; ACSR

    sei

lazo:
    ; Canal 0: la entrada negativa baja, y la salida del comparador sube.
    clr  r16
    sts  0x007C, r16            ; ADMUX = 0
    nop
    nop
    nop
    nop

    ; Canal 7: la negativa sube por encima de la positiva y la salida cae.
    ldi  r16, 7
    sts  0x007C, r16            ; ADMUX = 7
    nop
    nop
    nop
    nop

    cpi  r20, 6
    brlo lazo

    ; Apagar el comparador y parar. SLEEP tiene que ser la ÚLTIMA instrucción.
    ldi  r16, 0x80              ; ACD
    out  0x30, r16
    cli
    sleep

isr_ac:
    push r16
    in   r16, 0x3F
    push r16
    inc  r20
    ; La bandera se limpia sola al atender el vector, como en el chip.
    pop  r16
    out  0x3F, r16
    pop  r16
    reti
