; AxiomaCore-328 - la interrupción del ADC
; SPDX-License-Identifier: Apache-2.0
;
; POR QUÉ EXISTE ESTE PROGRAMA. La prueba de mutación lo pidió: se inyectó un
; fallo que movía el ADC al vector del comparador analógico y SOBREVIVIÓ a la
; regresión entera. El periférico estaba verificado por su banco y el
; controlador de interrupciones también, pero que el vector 21 estuviera BIEN
; CABLEADO no lo comprobaba nadie, porque ningún programa lo disparaba.
;
; Es el mismo fallo que apareció la primera vez que se ejercitaron las
; interrupciones del Timer0: un bit de más en la concatenación convertía
; TIMER0_COMPA en TIMER1_OVF. Los anchos de esa concatenación SON el mapa de
; vectores.
;
; QUÉ COMPRUEBA CADA UNO, que es el reparto de toda la co-simulación:
;
;   cuándo salta      lo decide el RTL, y lo verifica `sim/periph/tb_adc.cpp`
;                     contra un comparador escrito desde la hoja de datos;
;   qué hace el núcleo  lo verifica simavr: el arnés le levanta ESE MISMO vector
;                     y le deja ejecutar su propia secuencia de entrada, y
;                     después se comparan PC, pila, SP y SREG.
;
; simavr no puede desmentir el CUÁNDO: su `avr_adc.c` programa la interrupción a
; `prescale * 11` ciclos donde el manual dice 13, y entrega el valor de golpe.
; Por eso ADCL, ADCH y ADIF no se leen aquí: lo que se ejercita es el vector.
;
; UNA SOLA INTERRUPCIÓN HABILITADA, como manda la regla del proyecto: con varias
; a la vez, intercambiar dos vectores del mismo periférico es invisible.

    .section .text
    .global _start

    .org 0x00
    jmp  _start
    .org 0x2A                   ; vector 21, ADC
    jmp  isr_adc

    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    clr  r20                    ; cuántas veces se ha entrado en la ISR

    ; ADMUX = 3: el canal 3, con la referencia de AREF. El valor que salga lo
    ; pone el frente analógico, que no es parte del chip; aquí da igual.
    ldi  r16, 3
    sts  0x007C, r16            ; ADMUX

    sei

    ; ADEN | ADIE | ADPS=100 (reloj/16). Con el ADC encendido y la interrupción
    ; habilitada, cada ADSC deja una entrada a la ISR.
    ldi  r17, 0x8C
    sts  0x007A, r17            ; ADCSRA

    ; Arrancar la primera conversión: ADEN | ADSC | ADIE | ADPS.
    ldi  r16, 0xCC
    sts  0x007A, r16            ; ADCSRA con ADSC

    ; AQUÍ NO SE LEE NINGÚN REGISTRO DEL ADC, y es deliberado. El modismo de
    ; `analogRead()` sondea `ADSC` hasta que el hardware lo baja — pero eso, en
    ; una co-simulación, es COMPARAR DOS RELOJES: simavr programa el final de la
    ; conversión a `prescale * 11` ciclos y el manual dice 13, así que el bit ya
    ; está bajo en un lado y todavía alto en el otro. Se probó, y diverge en la
    ; primera lectura.
    ;
    ; Lo que sí está en lockstep es el vector: cuando el RTL entra en la ISR, el
    ; arnés le levanta el mismo a simavr. Así que la espera se hace sobre el
    ; contador que incrementa la ISR, no sobre el periférico.
lazo:
    cpi  r20, 6
    brlo lazo

    ; Apagar el ADC y parar. SLEEP tiene que ser la ÚLTIMA instrucción: el arnés
    ; termina ahí porque su bucle sólo avanza mientras simavr corra.
    clr  r16
    sts  0x007A, r16
    cli
    sleep

isr_adc:
    push r16
    in   r16, 0x3F
    push r16
    inc  r20
    ; La siguiente conversión la arranca la propia ISR, que es como se encadenan
    ; las lecturas de verdad cuando no hay disparo automático — la deuda D14.
    cpi  r20, 6
    brsh isr_fin
    ldi  r16, 0xCC
    sts  0x007A, r16            ; ADCSRA con ADSC
isr_fin:
    pop  r16
    out  0x3F, r16
    pop  r16
    reti
