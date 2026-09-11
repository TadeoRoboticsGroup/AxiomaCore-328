// AxiomaCore-328 - modelo del PLL para lint y simulación
// SPDX-License-Identifier: Apache-2.0
//
// NO se sintetiza. Sustituye a `rtl/fpga/ecp5/axioma_pll.v`, que instancia la
// primitiva EHXPLLL del ECP5: yosys la conoce, Verilator no. Sin este modelo,
// `make lint` no podría elaborar el top de la placa y toda esa parte del diseño
// se quedaría sin analizar — que es justo donde vive el cableado de los pads.
//
// El modelo NO multiplica ni divide: saca el reloj de entrada tal cual. Para lo
// que se comprueba en simulación —secuencia de reset, celdas de pad, que el
// programa arranca— la frecuencia da igual, y fingir una síntesis de reloj
// sería inventarse un dato. La frecuencia de verdad la fija el bitstream, y la
// mide `nextpnr` al cerrar el timing.
//
// `locked` sube tras unos ciclos, para que la secuencia de reset del top se
// ejercite de verdad en vez de arrancar ya enganchada.

`default_nettype none

module axioma_pll (
    input  wire clk_in,
    output wire clk_out,
    output wire locked
);

    assign clk_out = clk_in;

    // Mismo caso que en el top de la placa: el valor de encendido lo fija el
    // bitstream, y aquí sólo sirve para que `locked` empiece en cero.
    /* verilator lint_off PROCASSINIT */
    reg [3:0] cnt = 4'd0;
    /* verilator lint_on PROCASSINIT */
    always @(posedge clk_in)
        if (!cnt[3]) cnt <= cnt + 4'd1;

    assign locked = cnt[3];

endmodule

`default_nettype wire
