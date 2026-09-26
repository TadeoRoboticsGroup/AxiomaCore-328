// AxiomaCore-328 - SPM: el chip escribiéndose a sí mismo la Flash
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// Lo que permite que exista un gestor de arranque, y por tanto lo que permite
// pulsar *Upload* en el IDE de Arduino sin un programador por fuera. Es la
// deuda D2, y es la pieza que abre la fase 4.
//
//   SPMCSR  dato 0x57   SPMIE RWWSB SIGRD RWWSRE BLBSET PGWRT PGERS SPMEN
//
// HASTA AHORA `SPM` ESCRIBIA UNA PALABRA Y YA. Funcionaba, estaba verificado, y
// no servía para nada: ningún gestor de arranque escribe palabras sueltas,
// porque la Flash no se puede escribir así. Una celda de Flash sólo sabe BAJAR
// bits; para volver a subirlos hay que BORRAR, y el borrado es por PÁGINAS
// enteras. De ahí sale toda la máquina de este módulo.
//
// ---------------------------------------------------------------------------
// LAS TRES OPERACIONES, y por qué son tres
// ---------------------------------------------------------------------------
//
// Cada una se pide escribiendo `SPMCSR` y ejecutando `SPM` **dentro de los
// cuatro ciclos siguientes** — la quinta secuencia temporizada del chip, y la
// única cuyo segundo paso no es una escritura sino una INSTRUCCIÓN:
//
//   `SPMEN` solo            LLENAR EL BÚFER. La palabra R1:R0 se guarda en el
//                           búfer temporal, en la posición que dicen los bits
//                           bajos de Z. NO toca la Flash. Es inmediato.
//   `PGERS` + `SPMEN`       BORRAR LA PÁGINA que contiene Z: sus 64 palabras
//                           pasan a 0xFFFF.
//   `PGWRT` + `SPMEN`       ESCRIBIR LA PÁGINA: el búfer entero se vuelca en la
//                           página que contiene Z, y el búfer queda limpio.
//
// El búfer temporal es de 64 palabras, que es la página del ATmega328P: 128
// bytes. Z[6:1] elige la palabra dentro de la página y Z[14:7] elige la página.
// Con 16 K palabras de Flash salen 256 páginas.
//
// EL BÚFER SE LIMPIA SOLO TRAS ESCRIBIR LA PÁGINA, y eso lo dice la hoja de
// datos —«the temporary buffer will be cleared after a page write»—. No es un
// detalle: un gestor de arranque que escriba dos páginas seguidas llenando sólo
// la mitad de la segunda espera que la otra mitad salga a 0xFFFF, no con los
// restos de la primera.
//
// ---------------------------------------------------------------------------
// `SPMEN` Y LA ESPERA, que es como el gestor de arranque sabe que ya puede
// ---------------------------------------------------------------------------
//
// `SPMEN` se pone escribiéndolo y lo baja el hardware: a los cuatro ciclos si
// no llega ningún `SPM`, o **al terminar la operación** si llega. Un gestor de
// arranque hace `boot_spm_busy_wait()`, que es exactamente `while (SPMCSR &
// (1<<SPMEN));`. Si `SPMEN` se cayera antes de tiempo, el gestor seguiría
// adelante con la página a medio escribir.
//
// EL TIEMPO NO SALE DEL RELOJ DEL SISTEMA, igual que en la EEPROM y por el
// mismo motivo: son 4,5 ms de física de la celda, no de lógica. Entra como
// pulsos de `osc_tick` —576 a 128 kHz— y es parametrizable para que un banco no
// tenga que simular milisegundos enteros.
//
// `SPM_READY` ES DE NIVEL, como `EE_READY`: se dispara mientras `SPMEN` esté a
// cero y `SPMIE` puesto. No hay bandera que limpiar, y por eso este módulo no
// tiene `ack`. Es el vector 25, el último del chip que se quedaba sin fuente.
//
// ---------------------------------------------------------------------------
// LO QUE NO ESTÁ, dicho aquí y no escondido
// ---------------------------------------------------------------------------
//
// `RWWSB` y `RWWSRE` se almacenan y se leen de vuelta, y no pueden hacer más:
// la sección *Read-While-Write* separa la Flash en dos mitades para que el
// núcleo pueda seguir ejecutando de una mientras se programa la otra. Aquí la
// Flash es **una BRAM de doble puerto**, así que el puerto de búsqueda sigue
// leyendo durante la programación SIEMPRE, sin secciones. El bit de ocupado
// `RWWSB` se lee a cero por lo mismo: nunca hay una mitad inaccesible.
//
// `BLBSET` y `SIGRD` tampoco hacen nada, y tampoco pueden: los bits de cerrojo
// del gestor de arranque y la fila de firma son celdas de un PDK, no lógica.
// Están declarados como la deuda D18.
//
// EL NÚCLEO NO SE PARA durante el borrado ni la escritura. En el chip se para
// sólo si el programa corre en la misma sección que se está programando; con
// una BRAM de doble puerto esa distinción no existe. Un programa que se borre
// a sí mismo la página que está ejecutando se lleva lo que se merece, igual que
// en el chip.

`default_nettype none

module axioma_spm #(
    // Ciclos del oscilador de 128 kHz para borrar o escribir una página: 4,5 ms
    // son 576.
    //
    // ES PARAMETRO Y NADIE LO SOBREESCRIBE, y conviene decirlo en vez de
    // prometer un uso que no existe: los bancos corren el tiempo COMPLETO a
    // propósito, porque parte de lo que comprueban es justamente que dure lo
    // que la hoja de datos dice. Queda parametrizado para quien integre esto
    // con un oscilador distinto, que es la única razón honesta.
    parameter [15:0] T_PAGINA = 16'd576
)(
    input  wire        clk,
    input  wire        rst_n,

    // La habilitacion de reloj: un pulso por ciclo de sistema (ADR 0003).
    // Con CLKPS=0 vale 1 siempre y este modulo se comporta como antes.
    input  wire        ce,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0]  io_addr,
    input  wire        io_re,
    input  wire        io_we,
    input  wire [7:0]  io_wdata,
    output wire [7:0]  io_rdata,
    output wire        io_sel,

    // ---- el oscilador que fija el tiempo de programación ----
    input  wire        osc_tick,

    // ---- lo que llega del secuenciador al retirarse un `SPM` ----
    input  wire        spm_pulso,
    input  wire [15:0] spm_z,        // el puntero Z, en BYTES
    input  wire [15:0] spm_dato,     // R1:R0

    // ---- el puerto de datos de la Flash ----
    output wire        pm_we,
    output wire [13:0] pm_addr,
    output wire [15:0] pm_wdata,
    // Mientras vale uno, este módulo manda en ese puerto y el SoC no deja
    // pasar las lecturas de `LPM`. No es un arbitraje sofisticado: es que
    // durante la programación el núcleo no tiene nada que leer de ahí.
    output wire        pm_ocupado,

    // ---- interrupción ----
    output wire        irq_spm       // vector 25, SPM_READY. Es de NIVEL.
);

    localparam [7:0] A_SPMCSR = 8'h37;   // dato 0x57

    wire hit = (io_addr == A_SPMCSR);
    assign io_sel = hit;

    // ---------------------------------------------------------- registros
    reg spmie, rwwsre, blbset, pgwrt, pgers, spmen, sigrd;

    // ------------------------------------------- la ventana de cuatro ciclos
    // La quinta secuencia temporizada del chip. Se abre escribiendo `SPMEN`, y
    // su segundo paso NO es otra escritura: es la instruccion `SPM`.
    reg [2:0] ventana;
    wire      abierta = (ventana != 3'd0);
    wire      abre    = io_we && hit && io_wdata[0];

    // ------------------------------------------------- el bufer temporal
    // 64 palabras, que es la pagina del 328P. Arranca «borrado» a 0xFFFF, que
    // es lo que tiene una Flash sin programar.
    reg [15:0] bufer [0:63];
    integer    i;
    initial for (i = 0; i < 64; i = i + 1) bufer[i] = 16'hFFFF;

    // Z direcciona BYTES: la palabra dentro de la pagina son Z[6:1] y la pagina
    // Z[14:7]. El bit 0 de Z no se mira, como en `LPM`: una palabra no tiene
    // mitad.
    wire [5:0]  z_palabra = spm_z[6:1];
    wire [7:0]  z_pagina  = spm_z[14:7];

    // La pagina se congela AL ARRANCAR la operacion. Si se mirara Z en cada
    // ciclo, un `SPM Z+` o cualquier cosa que tocara Z a mitad del borrado
    // movería la pagina bajo los pies de la operación.
    reg [7:0]  pagina_q;
    reg [5:0]  cuenta;
    reg [15:0] resto;

    localparam [1:0] S_QUIETO = 2'd0,
                     S_BORRA  = 2'd1,
                     S_GRABA  = 2'd2,
                     S_ESPERA = 2'd3;
    reg [1:0] est;

    // Qué pide el `SPM` que acaba de llegar. Se mira con la ventana ABIERTA:
    // un `SPM` suelto, sin su escritura previa a `SPMCSR`, no hace nada. Es lo
    // que impide que un programa desbocado se borre la Flash.
    wire valido      = spm_pulso && abierta && spmen && (est == S_QUIETO);
    wire pide_borrar = valido &&  pgers && !pgwrt;
    wire pide_grabar = valido &&  pgwrt && !pgers;
    wire pide_bufer  = valido && !pgers && !pgwrt && !rwwsre && !blbset && !sigrd;

    wire [15:0] bufer_q = bufer[cuenta];

    always @(posedge clk) begin
        if (pide_bufer) bufer[z_palabra] <= spm_dato;
        // Tras volcar la pagina, el bufer se limpia. Se hace palabra a palabra
        // mientras se graba, que es cuando cada una ya esta a salvo en la Flash.
        else if (est == S_GRABA && ce) bufer[cuenta] <= 16'hFFFF;
    end

    // ------------------------------------------------- la maquina
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            est      <= S_QUIETO;
            cuenta   <= 6'd0;
            resto    <= 16'd0;
            pagina_q <= 8'd0;
        end else if (ce) begin
            case (est)
            S_QUIETO: begin
                cuenta   <= 6'd0;
                pagina_q <= z_pagina;
                resto    <= T_PAGINA;
                if      (pide_borrar) est <= S_BORRA;
                else if (pide_grabar) est <= S_GRABA;
            end
            // Las 64 palabras, una por ciclo. La BRAM no sabe hacer mas.
            S_BORRA, S_GRABA: begin
                cuenta <= cuenta + 6'd1;
                if (cuenta == 6'd63) est <= S_ESPERA;
            end
            // Y el resto del tiempo de la celda, que lo cuenta el oscilador.
            S_ESPERA: if (osc_tick) begin
                if (resto == 16'd1) est <= S_QUIETO;
                else                resto <= resto - 16'd1;
            end
            default: est <= S_QUIETO;
            endcase
        end
    end

    wire ocupado = (est != S_QUIETO);
    assign pm_ocupado = ocupado;
    assign pm_we      = (est == S_BORRA) || (est == S_GRABA);
    // 8 bits de pagina y 6 de palabra son los 14 de la Flash: 256 paginas de
    // 64 palabras son las 16 K palabras del 328P, justas.
    assign pm_addr    = {pagina_q, cuenta};
    assign pm_wdata   = (est == S_BORRA) ? 16'hFFFF : bufer_q;

    // ------------------------------------------------------------ escritura
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            ventana <= 3'd0;
            spmie <= 1'b0; rwwsre <= 1'b0; blbset <= 1'b0;
            pgwrt <= 1'b0; pgers  <= 1'b0; spmen  <= 1'b0; sigrd <= 1'b0;
        end else if (ce) begin
            if      (abre)         ventana <= 3'd4;
            else if (spm_pulso)    ventana <= 3'd0;   // el SPM la cierra
            else if (abierta)      ventana <= ventana - 3'd1;

            if (io_we && hit) begin
                // `SPMIE` no esta protegido: cambiarlo no puede programar nada.
                spmie  <= io_wdata[7];
                sigrd  <= io_wdata[5];
                rwwsre <= io_wdata[4];
                blbset <= io_wdata[3];
                pgwrt  <= io_wdata[2];
                pgers  <= io_wdata[1];
                spmen  <= io_wdata[0];
            end

            // `SPMEN` LO BAJA EL HARDWARE, y de tres maneras distintas:
            //
            //   al agotarse la ventana sin que llegue ningun `SPM` —el programa
            //   se lo pidio y no lo ejecuto—;
            //   al ejecutarse un `SPM` que NO arranca una operacion larga, o
            //   sea el llenado del bufer, que es inmediato;
            //   y al TERMINAR el borrado o la grabacion, que es lo que espera
            //   `boot_spm_busy_wait()`.
            //
            // Va despues de la escritura: si el programa escribe `SPMCSR` en el
            // mismo ciclo en que una operacion termina, manda el hardware.
            // Sin `!ocupado`: el `SPM` que arranca la operacion YA cierra la
            // ventana —`else if (spm_pulso) ventana <= 0`—, asi que estando
            // ocupado `abierta` vale cero y esta linea no puede dispararse. Se
            // escribio con la guarda, un mutante la quito y SOBREVIVIO: era
            // defensa contra algo que la linea de arriba ya impide.
            if (abierta && ventana == 3'd1) spmen <= 1'b0;
            if (spm_pulso && !pide_borrar && !pide_grabar) spmen <= 1'b0;
            if (ocupado && est == S_ESPERA && osc_tick && resto == 16'd1)
                spmen <= 1'b0;
        end
    end

    // ------------------------------------------------------------ lectura
    // `RWWSB` se lee SIEMPRE A CERO: la Flash es una BRAM de doble puerto y
    // nunca hay una mitad inaccesible. Ver la cabecera.
    assign io_rdata = hit ? {spmie, 1'b0, sigrd, rwwsre, blbset, pgwrt, pgers, spmen}
                          : 8'h00;

    assign irq_spm = spmie & ~spmen;

    // Este periferico no tiene efectos laterales de lectura.
    // `io_wdata[6]` es `RWWSB`, que es de SOLO LECTURA: escribirlo no hace
    // nada, que es lo que dice la hoja de datos. Y de Z no se miran ni el bit
    // 15 -la Flash del 328P son 15 bits de byte- ni el 0, porque una palabra
    // no tiene mitad.
    wire unused_spm = &{1'b0, io_re, io_wdata[6], spm_z[15], spm_z[0]};

endmodule

`default_nettype wire
