// AxiomaCore-328 - banco de 32 registros de propósito general
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// R0..R31, de 8 bits. Los seis últimos forman los punteros:
//     X = R27:R26    Y = R29:R28    Z = R31:R30
//
// Puertos:
//   - dos lecturas de 8 bits (Rd y Rr), combinacionales
//   - una escritura de 8 bits
//   - una lectura y una escritura de 16 bits sobre pares, con ÍNDICE DE PAR
//     INDEPENDIENTE para cada una, que cubre MOVW, ADIW, SBIW y el acceso a
//     X/Y/Z con post-incremento y pre-decremento
//   - una lectura de depuración, que usa el arnés diferencial contra simavr
//
// POR QUÉ EL PAR DE LECTURA Y EL DE ESCRITURA SON INDEPENDIENTES: MOVW copia
// de un par a OTRO. Con un solo índice compartido haría falta un ciclo para
// leer el origen y otro para escribir el destino, y MOVW pasaría a costar 2
// ciclos cuando el manual dice 1. Rompería el contrato L3. ADIW, SBIW y los
// punteros con post-incremento o pre-decremento sí usan el mismo par en ambos
// lados, y el secuenciador se lo pasa igual a los dos puertos.
//
// PRIORIDAD de escritura, si coincidieran en el mismo ciclo: la de 16 bits
// gana. En ejecución normal no coinciden sobre el mismo registro; la única
// forma de provocarlo es `LD Rd, X+` con Rd = R26 o R27, que el manual del ISA
// declara resultado indefinido.
//
// LECTURA DURANTE ESCRITURA: las lecturas son del valor ANTES del flanco. Es lo
// que hace falta para que `LD Rd, X+` lea X y escriba X+1 en el mismo ciclo.
//
// ESTADO TRAS RESET: todos a cero. El AVR real no lo garantiza, pero un valor
// determinista es imprescindible para el diferencial contra simavr, que también
// arranca a cero.

`default_nettype none

module axioma_regfile (
    input  wire        clk,
    input  wire        rst_n,

    // Lecturas de 8 bits
    input  wire [4:0]  rd_addr,
    input  wire [4:0]  rr_addr,
    output wire [7:0]  rd_data,
    output wire [7:0]  rr_data,

    // Escritura de 8 bits
    input  wire        we,
    input  wire [4:0]  w_addr,
    input  wire [7:0]  w_data,

    // Acceso de 16 bits, direccionado por ÍNDICE DE PAR, no por registro.
    // El par p cubre los registros 2p y 2p+1:  X = par 13, Y = par 14, Z = 15.
    // Se usa el índice de par y no un registro de 5 bits con el bit 0 ignorado
    // porque así la interfaz NO PUEDE expresar una dirección impar: la
    // ambigüedad desaparece por construcción en vez de por convenio.
    input  wire [3:0]  a16_pair,     // par que se LEE
    output wire [15:0] a16_rdata,
    input  wire        we16,
    input  wire [3:0]  w16_pair,     // par que se ESCRIBE; MOVW los usa distintos
    input  wire [15:0] w16_data,

    // Tercera lectura de 8 bits, para el ACCESO AL ESPACIO DE DATOS.
    // El AVR mapea R0..R31 en 0x0000..0x001F del espacio de datos, así que
    // `LD Rd, X` con X < 0x20 lee un registro. Hace falta un puerto propio
    // porque los dos primeros los ocupan Rd y Rr de la instrucción en curso.
    input  wire [4:0]  ds_addr,
    output wire [7:0]  ds_data,

    // Lectura de depuración, para el arnés de co-simulación
    input  wire [4:0]  dbg_addr,
    output wire [7:0]  dbg_data
);

    reg [7:0] r [0:31];

    integer i;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            for (i = 0; i < 32; i = i + 1)
                r[i] <= 8'h00;
        end else begin
            if (we16) begin
                r[{w16_pair, 1'b0}] <= w16_data[7:0];
                r[{w16_pair, 1'b1}] <= w16_data[15:8];
            end
            // La escritura de 8 bits cede ante la de 16 sobre el MISMO registro.
            if (we && !(we16 && (w_addr[4:1] == w16_pair)))
                r[w_addr] <= w_data;
        end
    end

    assign rd_data   = r[rd_addr];
    assign rr_data   = r[rr_addr];
    assign a16_rdata = {r[{a16_pair, 1'b1}], r[{a16_pair, 1'b0}]};
    assign ds_data   = r[ds_addr];
    assign dbg_data  = r[dbg_addr];

endmodule

`default_nettype wire
