// AxiomaCore-328 - fabric del espacio de datos
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Encamina cada acceso del núcleo a quien le corresponde dentro del espacio de
// datos UNIFICADO del AVR:
//
//     0x0000 - 0x001F   los 32 registros      <- NO llega aquí: lo resuelve
//     0x005D - 0x005F   SPL, SPH, SREG           axioma_core, porque su estado
//                                                vive dentro del núcleo
//     0x0020 - 0x00FF   I/O estándar y extendida <- bus de periféricos
//     0x0100 - 0x08FF   2048 bytes de SRAM       <- axioma_dmem
//
// Por encima de RAMEND no hay nada. Una lectura ahí devuelve 0x00 en vez de
// dejar el bus flotando o repetir el último dato: un valor definido es lo único
// que permite que la co-simulación diferencial compare algo.
//
// TEMPORIZACIÓN. La selección de región se registra en FLANCO DE BAJADA, igual
// que axioma_dmem y que las tres direcciones que intercepta axioma_core. El
// motivo está en docs/adr/0001-memorias-en-flanco-de-bajada.md: el AVR accede a
// memoria DENTRO del mismo ciclo, así que el dato tiene que estar listo para el
// flanco de subida que cierra ese ciclo. Si la selección fuera combinacional,
// en el segundo ciclo de LD —cuando el secuenciador ya no mantiene la
// dirección— el multiplexor de lectura elegiría la región equivocada.
//
// LECTURAS DE LOS PERIFÉRICOS. Cada periférico expone la interfaz que fija
// docs/01-arquitectura.md §2 y pone su `io_rdata` a cero cuando no está
// seleccionado, de modo que el SoC las combina con un OR. Este módulo recibe ya
// esa combinación; `io_sel` dice si alguien reclamó la dirección.

`default_nettype none

module axioma_dbus (
    input  wire        clk,
    input  wire        rst_n,

    // ------------------------------------------------ lado del núcleo
    input  wire [15:0] addr,
    input  wire        re,
    input  wire        we,
    input  wire [7:0]  wdata,
    output wire [7:0]  rdata,

    // ------------------------------------------------ SRAM de datos
    output wire [10:0] sram_addr,
    output wire        sram_en,
    output wire        sram_we,
    output wire [7:0]  sram_wdata,
    input  wire [7:0]  sram_rdata,

    // ------------------------------------------------ bus de periféricos
    output wire [7:0]  io_addr,
    output wire        io_re,
    output wire        io_we,
    output wire [7:0]  io_wdata,
    input  wire [7:0]  io_rdata,
    input  wire        io_sel
);

    localparam [15:0] IO_BASE   = 16'h0020;
    localparam [15:0] SRAM_BASE = 16'h0100;
    localparam [15:0] RAMEND    = 16'h08FF;

    // ------------------------------------------------------- decodificación
    // Las tres regiones son excluyentes por construcción: los rangos no se
    // solapan y se comparan con el mismo `addr`.
    wire hit_io   = (addr >= IO_BASE)   && (addr <  SRAM_BASE);
    wire hit_sram = (addr >= SRAM_BASE) && (addr <= RAMEND);

    wire active = re | we;

    // ------------------------------------------------------------ SRAM
    // La traducción de dirección la hace el bus, no la memoria: axioma_dmem ve
    // direcciones desde cero.
    assign sram_addr  = addr[10:0] - SRAM_BASE[10:0];
    assign sram_en    = hit_sram & active;
    assign sram_we    = hit_sram & we;
    assign sram_wdata = wdata;

    // ------------------------------------------------------ periféricos
    // El espacio de I/O son 224 bytes, así que el desplazamiento cabe en 8
    // bits por construcción.
    assign io_addr  = addr[7:0] - IO_BASE[7:0];
    assign io_re    = hit_io & re;
    assign io_we    = hit_io & we;
    assign io_wdata = wdata;

    // --------------------------------------------- multiplexor de lectura
    // Se registra QUÉ región se leyó, no el dato: el dato lo entrega la SRAM o
    // el periférico dentro del ciclo, y lo único que hay que recordar es a
    // cuál de los dos hay que hacerle caso.
    reg hit_io_q, hit_sram_q;
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit_io_q   <= 1'b0;
            hit_sram_q <= 1'b0;
        end else if (re) begin
            hit_io_q   <= hit_io;
            hit_sram_q <= hit_sram;
        end
    end

    // Fuera de las regiones mapeadas, y en la I/O que ningún periférico
    // reclama, la lectura vale 0x00.
    assign rdata = hit_sram_q ? sram_rdata :
                   (hit_io_q && io_sel) ? io_rdata : 8'h00;

endmodule

`default_nettype wire
