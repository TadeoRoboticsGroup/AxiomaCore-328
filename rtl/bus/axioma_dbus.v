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
    // La habilitacion de reloj (ADR 0003). OJO: este modulo registra en el
    // FLANCO DE BAJADA (ADR 0001), y `ce` se muestrea igual — vale durante
    // todo el ciclo de sistema, asi que el flanco de bajada de ese ciclo la
    // ve alta. No hay que cruzar nada.
    input  wire        ce,
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
    // Restar 0x100 no necesita un restador: es una potencia de dos, así que
    // los ocho bits bajos pasan tal cual y sólo hay que decrementar los tres
    // altos. Lo mismo abajo con los 0x20 de la I/O. Estos dos estaban en el
    // camino crítico, y en un acceso de I/O directo ese camino sólo tiene media
    // década de reloj.
    assign sram_addr  = {addr[10:8] - 3'd1, addr[7:0]};
    assign sram_en    = hit_sram & active;
    assign sram_we    = hit_sram & we;
    assign sram_wdata = wdata;

    // ------------------------------------------------------ periféricos
    // El espacio de I/O son 224 bytes, así que el desplazamiento cabe en 8
    // bits por construcción.
    assign io_addr  = {addr[7:5] - 3'd1, addr[4:0]};
    assign io_re    = hit_io & re;
    assign io_we    = hit_io & we;
    assign io_wdata = wdata;

    // --------------------------------------------- multiplexor de lectura
    // Se registra QUÉ región se leyó, no el dato: el dato lo entrega la SRAM o
    // el periférico dentro del ciclo, y lo único que hay que recordar es a
    // cuál de los dos hay que hacerle caso.
    // SE REGISTRA TAMBIÉN EL DATO DEL PERIFÉRICO, y no sólo la región. Aquí
    // hubo un fallo real escondido desde la fase 1.
    //
    // La SRAM entrega su dato REGISTRADO en flanco de bajada (ADR 0001), así
    // que sigue disponible en el ciclo siguiente. El de un periférico, en
    // cambio, es COMBINACIONAL desde `io_addr`: vale mientras la dirección esté
    // presente y desaparece en cuanto el secuenciador la suelta.
    //
    // Consecuencia: toda instrucción que consuma la lectura UN CICLO DESPUÉS de
    // lanzarla —LD y LDD lo hacen— leía 0x00 de cualquier periférico. Con la
    // SRAM no se notaba, porque su dato sí sobrevive, y con IN y LDS tampoco,
    // porque consumen dentro del mismo ciclo. No lo vio nadie hasta que un
    // programa leyó de vuelta un registro de la USART, que vive en la I/O
    // EXTENDIDA y sólo se alcanza con LD, LDD o LDS.
    //
    // Registrando el dato en el mismo flanco que la región, las dos se
    // comportan igual y la disciplina del ADR 0001 queda completa: quien lea
    // por el bus ve lo mismo venga de donde venga.
    reg       hit_io_q, hit_sram_q;
    reg [7:0] io_rdata_q;
    always @(negedge clk or negedge rst_n) begin
        if (!rst_n) begin
            hit_io_q   <= 1'b0;
            hit_sram_q <= 1'b0;
            io_rdata_q <= 8'h00;
        end else if (ce && re) begin
            hit_io_q   <= hit_io;
            hit_sram_q <= hit_sram;
            io_rdata_q <= (hit_io && io_sel) ? io_rdata : 8'h00;
        end
    end

    // Fuera de las regiones mapeadas, y en la I/O que ningún periférico
    // reclama, la lectura vale 0x00.
    assign rdata = hit_sram_q ? sram_rdata :
                   hit_io_q   ? io_rdata_q : 8'h00;

endmodule

`default_nettype wire
