// AxiomaCore-328 - memoria de programa
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// 16K x 16 bits = 32 KB. El PC es de 14 bits.
//
// LA INTERFAZ ES EL CONTRATO. El cuerpo de este módulo cambia según el
// destino; los puertos, no:
//
//   sim / FPGA   memoria inferida, que la síntesis mapea a BRAM.       <- este
//   ASIC         matriz de macros sky130_sram_2kbyte_1rw1r_32x512_8
//                más una ROM de arranque que copia desde una flash QSPI
//                externa al encender.  (fase 6)
//
// Sky130 no tiene memoria no volátil embebida: no existe IP de flash ni de
// EEPROM en el PDK abierto. Por eso en silicio la memoria de programa es SRAM
// cargada al arranque. Mantener esta frontera desde el principio es lo que
// evita que el port a ASIC sea una reescritura.
//
// Dos puertos:
//   if_*  búsqueda de instrucción, solo lectura, un ciclo de latencia
//   d_*   datos: LPM lee, SPM escribe

`default_nettype none

module axioma_progmem #(
    parameter integer WORDS    = 16384,
    parameter         INIT_HEX = ""
)(
    input  wire        clk,

    // La habilitacion de reloj (ADR 0003): `clk_FLASH` va con `clk_CPU`.
    input  wire        ce,

    input  wire [13:0] if_addr,
    input  wire        if_en,
    output reg  [15:0] if_data,

    input  wire [13:0] d_addr,
    input  wire        d_en,
    input  wire        d_we,
    input  wire [15:0] d_wdata,
    output reg  [15:0] d_rdata
);

    reg [15:0] mem [0:WORDS-1];

    integer i;
    initial begin
        for (i = 0; i < WORDS; i = i + 1)
            mem[i] = 16'h0000;              // NOP
        if (INIT_HEX != "")
            $readmemh(INIT_HEX, mem);
    end

    // FLANCO DE SUBIDA, a diferencia de la memoria de datos.
    //
    // La búsqueda de instrucción va adelantada un ciclo: mientras se ejecuta la
    // instrucción de la dirección A ya se está trayendo la de A+1. Con eso, la
    // palabra de instrucción permanece ESTABLE durante todo el ciclo, que es lo
    // que necesitan el decodificador y el camino de datos.
    //
    // Con flanco de bajada la palabra cambiaría a mitad de ciclo y habría que
    // meter decodificación, lectura de registros, ALU y escritura en media
    // década de reloj. El puerto de datos (LPM, SPM) tampoco lo necesita: LPM
    // dura 3 ciclos y va sobrado.
    //
    // Ver docs/adr/0001-memorias-en-flanco-de-bajada.md
    always @(posedge clk) if (ce) begin
        if (if_en)
            if_data <= mem[if_addr];
        if (d_en) begin
            if (d_we) begin
                mem[d_addr] <= d_wdata;
                d_rdata     <= d_wdata;
            end else begin
                d_rdata <= mem[d_addr];
            end
        end
    end

endmodule

`default_nettype wire
