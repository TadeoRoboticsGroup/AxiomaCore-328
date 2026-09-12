// AxiomaCore-328 - puerto de entrada/salida de propósito general
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Un puerto. Se instancia tres veces: B, C y D.
//
//     PINx   leer  -> valor SINCRONIZADO del pad
//            escribir -> hace TOGGLE de PORTx en los bits escritos a 1
//     DDRx   dirección: 1 = salida
//     PORTx  dato de salida; en un pin de entrada, habilita el pull-up
//
// LA TRAMPA Nº 5 DEL ISA: escribir un 1 en PINx conmuta el bit correspondiente
// de PORTx, **sea cual sea la dirección del pin**. No es una curiosidad: es lo
// que usa el código optimizado de conmutación de pines, y sin ella deja de
// funcionar sin dar ningún síntoma claro.
//
// EL SINCRONIZADOR NO ES OPCIONAL. El 328P no lleva el valor del pad
// directamente a PINx: lo pasa por un sincronizador. Por eso, entre escribir
// PORTx y leer PINx hay que dejar pasar UNA instrucción —el `nop` que aparece
// en todo el código AVR que lee de vuelta un pin recién escrito—. Modelarlo sin
// sincronizador haría que el RTL fuera MÁS permisivo que el chip: código que
// funcionara aquí fallaría en silicio, que es el peor tipo de incompatibilidad.
//
// UNA sola etapa, no dos. El retardo del chip es de medio a un ciclo y medio,
// que es justo lo que cubre un `nop`. Con dos biestables harían falta dos, y el
// idioma documentado dejaría de funcionar. Para pines externos de verdad, en
// FPGA, haría falta una segunda etapa contra la metaestabilidad — pero eso
// cambia la temporización documentada y hay que decidirlo en la fase 5.
//
// DIFERENCIA CONOCIDA CON simavr: su modelo de ioport NO tiene sincronizador y
// devuelve PORTx al instante. En ese caso concreto el que se aparta de la hoja
// de datos es simavr, no este módulo. Ver docs/01-arquitectura.md §8bis.

`default_nettype none

module axioma_gpio #(
    // Dirección de I/O de PINx. DDRx va en IO_PIN+1 y PORTx en IO_PIN+2.
    parameter [7:0] IO_PIN = 8'h03,        // 0x03 = B, 0x06 = C, 0x09 = D
    // Bits realmente implementados. El puerto C sólo tiene siete.
    parameter [7:0] BITS   = 8'hFF
)(
    input  wire       clk,
    input  wire       rst_n,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- anulación por un periférico ----
    // LA HOJA DE DATOS LO LLAMA «override». Cuando un temporizador se adueña de
    // un pin para sacar su forma de onda —OC0A en PD6, OC0B en PD5, OC1A en PB1,
    // OC1B en PB2—, el valor del pad lo pone ÉL y no `PORTx`.
    //
    // LO QUE NO ANULA ES LA DIRECCIÓN. El manual es explícito: «the Data
    // Direction Register bit for the OC0A pin must be set as output before the
    // value is visible on the pin». Es decir, el programa SIGUE teniendo que
    // poner `DDRx`, y por eso un `analogWrite()` que se olvide del `pinMode()`
    // no saca nada. Modelarlo al revés —que el periférico fuerce también la
    // dirección— haría funcionar código que en el chip no funciona, que es el
    // peor tipo de incompatibilidad.
    //
    // `PORTx` se sigue escribiendo y leyendo mientras dura la anulación: al
    // soltarla, el pin vuelve al valor que el programa dejó. También eso es lo
    // que hace el chip.
    input  wire [7:0] ovr_en,
    input  wire [7:0] ovr_val,

    // ---- pines ----
    // El pull-up NO lo aplica este módulo: lo DECLARA, y lo aplica la celda de
    // pad —o el modelo de pad del banco—. Es lo que corresponde: en la FPGA lo
    // activa el bloque de E/S del ECP5 y en silicio la celda del PDK.
    input  wire [7:0] pad_in,
    output wire [7:0] pad_out,
    output wire [7:0] pad_oe,
    output wire [7:0] pad_pullup
);

    localparam [7:0] A_PIN  = IO_PIN;
    localparam [7:0] A_DDR  = IO_PIN + 8'd1;
    localparam [7:0] A_PORT = IO_PIN + 8'd2;

    wire hit_pin  = (io_addr == A_PIN);
    wire hit_ddr  = (io_addr == A_DDR);
    wire hit_port = (io_addr == A_PORT);
    assign io_sel = hit_pin | hit_ddr | hit_port;

    // Este periférico NO tiene efectos laterales de lectura, así que no mira
    // `io_re`: sus tres registros se leen de forma combinacional. El puerto se
    // mantiene porque es el contrato de la interfaz y otros periféricos sí lo
    // necesitan —leer UDR0 limpia RXC, leer ADCL bloquea ADCH—, pero aquí hay
    // que declararlo sin usar a propósito.
    wire unused_io_re = &{1'b0, io_re};

    reg [7:0] ddr_q, port_q;

    // Sincronizador de una etapa sobre el pad. Es lo que obliga a dejar una
    // instrucción entre escribir PORTx y leer PINx.
    reg [7:0] sync1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ddr_q  <= 8'h00;
            port_q <= 8'h00;
            sync1  <= 8'h00;
        end else begin
            sync1 <= pad_in & BITS;
            if (io_we) begin
                if (hit_ddr)  ddr_q  <= io_wdata & BITS;
                if (hit_port) port_q <= io_wdata & BITS;
                // Escribir PINx no escribe PINx: conmuta PORTx.
                if (hit_pin)  port_q <= (port_q ^ io_wdata) & BITS;
            end
        end
    end

    // Un periférico deja su lectura a cero cuando no está seleccionado, para
    // que el SoC pueda combinarlas todas con un OR.
    assign io_rdata = hit_pin  ? sync1  :
                      hit_ddr  ? ddr_q  :
                      hit_port ? port_q : 8'h00;

    assign pad_out = (port_q & ~ovr_en) | (ovr_val & ovr_en);
    assign pad_oe  = ddr_q;
    // Pin de entrada con su bit de PORTx a 1: pull-up activado. Es lo que hace
    // que un pin sin nada conectado se lea como 1 y no como ruido.
    assign pad_pullup = ~ddr_q & port_q;

endmodule

`default_nettype wire
