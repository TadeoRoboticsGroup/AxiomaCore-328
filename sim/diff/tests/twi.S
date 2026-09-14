; AxiomaCore-328 - el vector del TWI contra simavr
; SPDX-License-Identifier: Apache-2.0
;
; La forma de onda del TWI -los dos hilos, los 26 codigos de estado, el
; arbitraje y el estiramiento de reloj- la certifica `make sim-twi` contra un
; bus de colector abierto con un maestro y un esclavo escritos desde la hoja de
; datos. simavr NO SIRVE para eso: su avr_twi.c transporta direcciones y bytes
; enteros por IRQs internas y no serializa SDA.
;
; Lo que este programa verifica es lo otro, que es justo lo que el banco propio
; no puede ver porque alli no hay nucleo:
;
;   - que TWBR y TWAMR sean almacenamiento con la misma semantica en los dos
;     lados -entran en la tabla COMPARABLE de diff.cpp-;
;   - que el vector TWI (numero 24, byte 0x60) este bien cableado y el nucleo
;     entre en la ISR de verdad, con su pila y su SREG;
;   - que los seis registros vivan en la I/O EXTENDIDA y se alcancen con
;     LDS/STS, que es el unico camino: IN y OUT no llegan a 0xB8.
;
; LOS PULL-UP LOS PONE EL PROGRAMA, como en cualquier placa. En el TWI el pin
; suelto no lo sube nadie mas: PORTC4 y PORTC5 son los que declaran el pull-up,
; y es literalmente lo que hace el `digitalWrite(SDA, HIGH)` que `Wire.begin()`
; lleva dentro. Sin ellos el bus se lee bajo, el TWI nunca lo ve libre y no
; sale ni un START.
;
; LO QUE NO SE TOCA: TWAR, TWDR, TWCR y TWSR.
;   TWAR  el chip lo resetea a 0xFE -direccion 0x7F, TWGCE a cero- y simavr no
;         implementa ese valor de reset: su espacio de datos arranca a cero.
;         El valor correcto lo comprueba `make sim-twi` contra la hoja de datos,
;         que es el oraculo que toca.
;   TWDR  igual: 0xFF en el chip, 0x00 en simavr.
;   TWCR  TWINT y TWWC las pone el hardware, y los dos lados las mueven en
;         momentos distintos.
;   TWSR  es el codigo de estado, que depende de la temporizacion del bus.
;
; UNA SOLA INTERRUPCION HABILITADA, que es la regla de estos programas: con
; varias puestas a la vez, intercambiar dos vectores del mismo periferico es
; invisible. El TWI solo tiene uno, asi que aqui sale gratis.

    .section .text
    .global _start

    .org 0x00
    jmp  _start
    .org 0x60
    jmp  isr_twi                ; vector 24, TWI

    .org 0x80
_start:
    ldi  r16, 0xFF
    out  0x3D, r16              ; SPL
    ldi  r16, 0x08
    out  0x3E, r16              ; SPH

    clr  r20                    ; entradas a la ISR
    clr  r21                    ; guarda el ultimo TWCR leido

    ; Pull-up de SDA (PC4) y SCL (PC5). Sin esto el bus nunca esta libre.
    ldi  r16, 0x30
    out  0x08, r16              ; PORTC
    ldi  r16, 0x00
    out  0x07, r16              ; DDRC: los dos como entrada

    ; TWBR y TWAMR: almacenamiento puro, y los dos comparables.
    ldi  r16, 0x02
    sts  0xB8, r16              ; TWBR = 2 -> semiperiodo de 10 ciclos
    ldi  r16, 0x06
    sts  0xBD, r16              ; TWAMR

    ; Leerlos de vuelta obliga a que la I/O extendida funcione por LD/LDS, que
    ; es el camino que un dia devolvia 0x00 por no registrar el dato en el bus.
    lds  r22, 0xB8
    lds  r23, 0xBD

    ldi  r16, 0x05              ; TWEN | TWIE
    sts  0xBC, r16              ; TWCR
    sei

    ; Pedir un START. Con el bus libre sale enseguida, TWINT sube y salta el
    ; vector. Al no haber nadie al otro lado, el SLA+W se queda sin ACK y
    ; TWINT vuelve a subir: la ISR se encarga de encadenarlo.
    ldi  r16, 0xA5              ; TWINT | TWSTA | TWEN | TWIE
    sts  0xBC, r16

bucle:
    ; Esperar sin mirar banderas: la cuenta la lleva la ISR.
    ldi  r17, 80
espera:
    dec  r17
    brne espera

    ; GPIOR0 lleva la cuenta a un sitio que los dos lados comparan.
    out  0x1E, r20
    rjmp bucle

; --------------------------------------------------------------------- ISR
; TWINT NO SE LIMPIA SOLA NI RETORNANDO: se limpia escribiendo un UNO en ella,
; y al limpiarla arranca la operacion siguiente. Una ISR que se limitara a
; retornar dejaria SCL estirado para siempre y el bus parado. Es la trampa
; numero 11 otra vez, y aqui es mortal.
isr_twi:
    push r16
    in   r16, 0x3F
    push r16

    inc  r20
    mov  r21, r20
    andi r21, 0x03
    brne .Lsigue

    ; Cada cuatro vueltas se cierra con un STOP y se vuelve a arrancar, para
    ; que el programa recorra el ciclo entero -START, direccion, parada- y no
    ; se quede en un solo estado.
    ldi  r16, 0x95              ; TWINT | TWSTO | TWEN | TWIE
    sts  0xBC, r16
    ldi  r16, 0xA5              ; TWINT | TWSTA | TWEN | TWIE
    sts  0xBC, r16
    rjmp .Lfin

.Lsigue:
    ; Mandar la direccion. Nadie contesta, asi que vendra un NACK y otra
    ; interrupcion: es exactamente lo que se quiere ejercitar.
    ldi  r16, 0x50
    sts  0xBB, r16              ; TWDR = SLA+W de 0x28
    ldi  r16, 0x85              ; TWINT | TWEN | TWIE
    sts  0xBC, r16

.Lfin:
    pop  r16
    out  0x3F, r16
    pop  r16
    reti
