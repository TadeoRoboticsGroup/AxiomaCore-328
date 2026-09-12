; AxiomaCore-328 - el vector del SPI contra simavr
; SPDX-License-Identifier: Apache-2.0
;
; La forma de onda del SPI la certifica `make sim-spi` contra el otro extremo
; del cable, porque simavr NO SERIALIZA: su modelo transporta el byte entero por
; una IRQ interna y programa un temporizador de clkdiv*8 ciclos para levantar la
; interrupcion. Lo que este programa verifica es lo otro:
;
;   - que SPCR sea almacenamiento con la misma semantica en los dos lados;
;   - que el vector SPI_STC (numero 17, byte 0x44) este bien cableado y el
;     nucleo entre en la ISR de verdad.
;
; LO QUE NO SE TOCA: SPDR y SPSR. En simavr, leer SPDR devuelve EL BYTE QUE SE
; ESCRIBIO -no hay nada al otro lado del cable- y leerlo limpia SPIF de golpe,
; sin la secuencia de dos accesos de la hoja de datos. En el SoC, en cambio,
; MISO esta forzado a entrada con su pull-up, asi que un maestro sin nada
; conectado recibe 0xFF. Son dos cosas distintas y ninguna es un fallo: por eso
; la ISR no lee ninguno de los dos.

    .section .text
    .global _start

    .org 0x00
    jmp  _start
    .org 0x44
    jmp  isr_spi                ; vector 17, SPI_STC

    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    clr  r20                    ; transferencias terminadas

    ; MOSI (PB3) y SCK (PB5) como salidas: el maestro sigue teniendo que
    ; ponerlas el, igual que en el chip. MISO lo fuerza a entrada el hardware.
    ldi  r16, 0x2C              ; PB5, PB3 y PB2 (SS) de salida
    out  0x04, r16              ; DDRB
    ldi  r16, 0x04
    out  0x05, r16              ; PORTB: SS en alto, que es lo normal

    ldi  r16, 0xD0              ; SPIE | SPE | MSTR, SPR=00 -> fosc/4
    out  0x2C, r16              ; SPCR
    ldi  r16, 0x00
    out  0x2D, r16              ; SPSR: sin SPI2X
    sei

bucle:
    ldi  r16, 0x5A
    out  0x2E, r16              ; SPDR: arranca la transferencia

    ; Esperar sin mirar banderas: la cuenta la lleva la ISR. Son mas ciclos de
    ; los que tarda un byte a fosc/4, asi que cada vuelta transfiere uno.
    ldi  r17, 60
espera:
    dec  r17
    brne espera

    ; Tras unas cuantas vueltas, la fase de esclavo.
    inc  r22
    cpi  r22, 40
    brne bucle
    rjmp esclavo

; --------------------------------------------------------------------
; Y una vuelta como ESCLAVO. No hay nadie que mueva SCK, asi que no
; transfiere nada; lo que se ejercita es el otro camino del SoC: con el SPI
; como esclavo, SS, MOSI y SCK quedan forzados a ENTRADA pase lo que pase con
; DDRB. La cobertura enseño que ese camino no lo pisaba nadie.
esclavo:
    cli
    ldi  r16, 0x40              ; SPE, sin MSTR: esclavo
    out  0x2C, r16              ; SPCR
    nop
    nop
    in   r21, 0x03              ; PINB con los pines ya forzados a entrada
    ldi  r16, 0x00
    out  0x2C, r16              ; soltar el SPI
    nop
    rjmp esclavo

isr_spi:
    push r0
    in   r0, 0x3F
    inc  r20
    out  0x3F, r0
    pop  r0
    reti
