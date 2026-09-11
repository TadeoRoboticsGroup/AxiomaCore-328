// AxiomaCore-328 - registros de propósito general de I/O
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// GPIOR0, GPIOR1 y GPIOR2. Tres bytes de almacenamiento puro, sin más función
// que estar ahí: el 328P los ofrece como variables globales de acceso rápido,
// porque llegan con IN y OUT en vez de con LDS y STS.
//
//   GPIOR0   I/O 0x1E   dato 0x3E
//   GPIOR1   I/O 0x2A   dato 0x4A
//   GPIOR2   I/O 0x2B   dato 0x4B
//
// GPIOR0 CAE DENTRO DE 0x00-0x1F, así que es el único de los tres al que
// llegan SBI, CBI, SBIC y SBIS. No es una curiosidad: es lo que lo convierte en
// el sitio natural para banderas de una ISR.
//
// POR QUÉ MERECE UN MÓDULO. Porque son registros DEL CHIP, y hasta ahora los
// suplía un array en el banco de pruebas que fingía que todo el espacio de I/O
// era RAM. Con ese relleno, el artefacto verificado y el dispositivo no eran el
// mismo: en el 328P una dirección no implementada se lee como cero y una
// escritura se pierde, no se comporta como memoria.

`default_nettype none

module axioma_gpior (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel
);

    localparam [7:0] A_GPIOR0 = 8'h1E;
    localparam [7:0] A_GPIOR1 = 8'h2A;
    localparam [7:0] A_GPIOR2 = 8'h2B;

    wire hit0 = (io_addr == A_GPIOR0);
    wire hit1 = (io_addr == A_GPIOR1);
    wire hit2 = (io_addr == A_GPIOR2);
    assign io_sel = hit0 | hit1 | hit2;

    // Almacenamiento puro: ningún efecto lateral, tampoco de lectura.
    wire unused_io_re = &{1'b0, io_re};

    reg [7:0] r0, r1, r2;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            r0 <= 8'h00;
            r1 <= 8'h00;
            r2 <= 8'h00;
        end else if (io_we) begin
            if (hit0) r0 <= io_wdata;
            if (hit1) r1 <= io_wdata;
            if (hit2) r2 <= io_wdata;
        end
    end

    assign io_rdata = hit0 ? r0 :
                      hit1 ? r1 :
                      hit2 ? r2 : 8'h00;

endmodule

`default_nettype wire
