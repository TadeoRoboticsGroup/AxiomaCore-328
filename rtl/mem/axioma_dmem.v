// AxiomaCore-328 - SRAM de datos
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// 2 KB. Ocupa 0x0100..0x08FF del espacio de datos unificado; la traducción de
// dirección la hace el bus, no este módulo, que ve direcciones desde cero.
//
// Misma frontera que axioma_progmem: la interfaz es el contrato y el cuerpo
// cambia según el destino. En ASIC pasa a ser un macro sky130_sram con
// escritura por byte.
//
// Lectura síncrona, un ciclo de latencia, para que se corresponda con una BRAM
// real y con un macro de SRAM. Una lectura asíncrona funcionaría en simulación
// y luego no cerraría timing.

`default_nettype none

module axioma_dmem #(
    parameter integer BYTES = 2048
)(
    input  wire        clk,
    // La habilitacion de reloj (ADR 0003). OJO: este modulo registra en el
    // FLANCO DE BAJADA (ADR 0001), y `ce` se muestrea igual — vale durante
    // todo el ciclo de sistema, asi que el flanco de bajada de ese ciclo la
    // ve alta. No hay que cruzar nada.
    input  wire        ce,
    input  wire [10:0] addr,
    input  wire        en,
    input  wire        we,
    input  wire [7:0]  wdata,
    output reg  [7:0]  rdata
);

    reg [7:0] mem [0:BYTES-1];

    integer i;
    initial begin
        for (i = 0; i < BYTES; i = i + 1)
            mem[i] = 8'h00;
    end

    // FLANCO DE BAJADA, a propósito. El AVR accede a memoria dentro del mismo
    // ciclo; una BRAM en flanco de subida devolvería el dato un ciclo tarde y
    // eso rompería las cuentas de ciclos de LD, LDS y ST. Capturando a mitad de
    // ciclo, el dato llega a tiempo para el flanco de subida siguiente.
    // Coste: el camino de memoria dispone de media década de reloj.
    // Ver docs/adr/0001-memorias-en-flanco-de-bajada.md
    always @(negedge clk) begin
        if (ce && en) begin
            if (we) begin
                mem[addr] <= wdata;
                rdata     <= wdata;         // lectura-tras-escritura coherente
            end else begin
                rdata <= mem[addr];
            end
        end
    end

endmodule

`default_nettype wire
