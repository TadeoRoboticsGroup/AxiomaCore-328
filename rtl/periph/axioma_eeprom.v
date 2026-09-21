// AxiomaCore-328 - EEPROM: 1 KB que sobrevive al corte de corriente
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El sitio donde un programa guarda lo que tiene que seguir ahi manana: la
// calibracion, el numero de serie, cuantas horas lleva funcionando la maquina.
//
//   EECR   dato 0x3F   -- -- EEPM1 EEPM0 EERIE EEMPE EEPE EERE
//   EEDR   dato 0x40   el byte
//   EEARL  dato 0x41   direccion, byte bajo
//   EEARH  dato 0x42   direccion, dos bits altos (1 KB = 10 bits)
//
// LA SECUENCIA TEMPORIZADA, otra vez, y por el mismo motivo que en el perro
// guardian: escribir en la EEPROM no se hace con una escritura. Hace falta
//
//   1. poner `EEMPE` a uno;
//   2. y DENTRO DE LOS CUATRO CICLOS SIGUIENTES, poner `EEPE`.
//
// `EEMPE` se cae solo a los cuatro ciclos. Existe porque una escritura perdida
// en la EEPROM no se nota hasta el siguiente arranque, y para entonces el dato
// bueno ya no esta: el hardware exige dos pasos para que un programa desbocado
// no borre la calibracion de la maquina.
//
// LOS TRES MODOS DE `EEPM`, tabla 8-1. La celda de EEPROM se BORRA y se ESCRIBE
// en dos operaciones fisicas distintas, y el chip deja elegir:
//
//   00  borrar y escribir en una operacion   3,4 ms
//   01  solo borrar                          1,8 ms
//   10  solo escribir                        1,8 ms
//   11  reservado
//
// Separarlas sirve para ir mas rapido cuando se sabe que la celda ya esta
// borrada -0xFF-, que es el caso de un registro que solo crece. Aqui, borrar
// pone 0xFF y escribir hace un AND con lo que ya hay, que es lo que fisicamente
// puede hacer una celda: bajar bits, nunca subirlos. Modelarlo como una
// escritura normal haria funcionar codigo que en silicio no funciona.
//
// EL TIEMPO DE ESCRITURA NO SALE DEL RELOJ DEL SISTEMA. Lo fija el oscilador
// interno, igual que el del perro guardian, y por eso entra de fuera como un
// pulso: 3,4 ms son 435 ciclos de 128 kHz, y 1,8 ms son 230.
//
// `EE_READY` NO ES UNA BANDERA, ES UN NIVEL, y es de las pocas interrupciones
// del chip que funcionan asi: «the interrupt is constantly triggered when EEPE
// is cleared». No hay nada que limpiar — la ISR tiene que quitar `EERIE` o
// lanzar otra escritura, o se vuelve a entrar para siempre. Un `ack` que
// limpiara una bandera aqui seria un invento.

`default_nettype none

module axioma_eeprom #(
    // Ciclos del oscilador de 128 kHz. Del tiempo de la hoja de datos: 3,4 ms
    // son 435 y 1,8 ms son 230. Parametrizable para que el banco no tenga que
    // simular milisegundos enteros.
    parameter [15:0] T_BORRA_ESCRIBE = 16'd435,
    parameter [15:0] T_SIMPLE        = 16'd230
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

    // ---- el oscilador que fija el tiempo de escritura ----
    input  wire       osc_tick,

    // ---- interrupción ----
    output wire       irq_ee        // vector 22, EE_READY. Es de NIVEL.
);

    localparam [7:0] A_EECR  = 8'h1F;   // dato 0x3F
    localparam [7:0] A_EEDR  = 8'h20;
    localparam [7:0] A_EEARL = 8'h21;
    localparam [7:0] A_EEARH = 8'h22;

    wire hit_cr   = (io_addr == A_EECR);
    wire hit_dr   = (io_addr == A_EEDR);
    wire hit_arl  = (io_addr == A_EEARL);
    wire hit_arh  = (io_addr == A_EEARH);

    assign io_sel = hit_cr | hit_dr | hit_arl | hit_arh;

    // ---------------------------------------------------------- registros
    reg [1:0]  eepm;
    reg        eerie, eempe, eepe;
    reg [9:0]  eear;
    reg [7:0]  eedr;

    // --------------------------------------------- la ventana de EEMPE
    // Cuatro ciclos, y el hardware la cierra sola. Igual que `WDCE` en el perro
    // guardian, y por el mismo motivo.
    reg [2:0] ventana;
    wire      abierta = (ventana != 3'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                          ventana <= 3'd0;
        else if (io_we && hit_cr && io_wdata[2]) ventana <= 3'd4;
        else if (abierta)                    ventana <= ventana - 3'd1;
    end

    // --------------------------------------------------- la memoria
    // 1 KB, memoria inferida: en simulacion y en BRAM sale sola, y en el flujo
    // ASIC se sustituye por el macro del PDK. Arranca a 0xFF, que es lo que
    // tiene una EEPROM borrada de fabrica.
    reg [7:0] mem [0:1023];
    integer   i;
    initial for (i = 0; i < 1024; i = i + 1) mem[i] = 8'hFF;

    // LA LECTURA VA REGISTRADA, y no es una preferencia de estilo: con una
    // lectura COMBINACIONAL de la celda, yosys no puede inferir memoria y
    // responde «replacing memory with list of registers» — mil veinticuatro
    // bytes convertidos en 8 192 biestables, mas que todo el resto del chip
    // junto. Lo dijo `synth-check` antes de que esto llegara a un commit.
    //
    // Y no cuesta nada: `EEAR` lo pone el programa ANTES de pedir la operacion,
    // asi que para cuando llega `EERE` o `EEPE` el puerto ya lleva un ciclo
    // entero con la celda en la salida.
    reg [7:0] mem_q;

    // -------------------------------------------------- la escritura
    wire arranca = io_we && hit_cr && io_wdata[1] && abierta && !eepe;
    wire [15:0] duracion = (eepm == 2'b00) ? T_BORRA_ESCRIBE : T_SIMPLE;

    reg [15:0] resto;

    // LA CELDA BAJA BITS, NO LOS SUBE. Borrar la pone a 0xFF; escribir sin
    // borrar solo puede apagar unos. Es lo que hace fisicamente una EEPROM, y
    // modelarlo de otra forma haria funcionar aqui codigo que en silicio no
    // funciona.
    wire [7:0] dato_nuevo = (eepm == 2'b01) ? 8'hFF :                  // borrar
                            (eepm == 2'b10) ? (mem_q & eedr) :         // escribir
                                              eedr;                    // las dos

    // El puerto de la memoria: una escritura y una lectura registrada, que es
    // lo que una BRAM sabe hacer y lo que el macro del PDK tendra.
    always @(posedge clk) begin
        // El dato se graba al ARRANCAR, no al terminar: lo que se escribe es lo
        // que habia en EEDR cuando empezo, y cambiarlo a mitad de los 3,4 ms no
        // cambia lo grabado. Es lo que hace el chip, que se lleva el byte a su
        // propio registro. Mientras tanto la celda no se puede leer -EERE esta
        // bloqueado por EEPE-, asi que el instante en que el array cambia no es
        // observable.
        if (arranca) mem[eear] <= dato_nuevo;
        mem_q <= mem[eear];
    end

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eepe  <= 1'b0;
            resto <= 16'd0;
        end else if (arranca) begin
            eepe  <= 1'b1;
            resto <= duracion;
        end else if (eepe && osc_tick) begin
            if (resto == 16'd1) eepe  <= 1'b0;
            else                resto <= resto - 16'd1;
        end
    end

    // ------------------------------------------------------------ lectura
    wire [7:0] r_eecr = {2'b00, eepm, eerie, eempe, eepe, 1'b0};

    assign io_rdata = hit_cr  ? r_eecr              :
                      hit_dr  ? eedr                :
                      hit_arl ? eear[7:0]           :
                      hit_arh ? {6'b0, eear[9:8]}   : 8'h00;

    // ------------------------------------------------------------ escritura
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            eepm <= 2'b00; eerie <= 1'b0; eempe <= 1'b0;
            eear <= 10'd0; eedr <= 8'h00;
        end else begin
            // EEMPE lo lleva la ventana, no el programa.
            eempe <= (io_we && hit_cr && io_wdata[2]) ||
                     (abierta && ventana != 3'd1);

            if (io_we && hit_cr) begin
                eerie <= io_wdata[3];
                // `EEPM` es de lectura y escritura normal, sin guarda: la hoja
                // de datos no la pone, y no hace falta. Lo que decide la
                // operacion es el modo que habia AL ARRANCAR —`resto` y el dato
                // se fijan en ese flanco—, asi que cambiarlo a mitad de los
                // 3,4 ms no cambia lo que se esta grabando. Inventar una
                // restriccion que el chip no tiene es tan incompatible como
                // saltarse una que si tiene.
                eepm <= io_wdata[5:4];
            end
            if (io_we && hit_dr)  eedr      <= io_wdata;
            // `EERE` LEE EN EL ACTO y deja el byte en el MISMO `EEDR`: es un
            // registro, no dos. Un programa que escriba `EEDR` y lo lea de
            // vuelta sin leer ninguna celda tiene que recuperar lo suyo, y uno
            // que lea una celda tiene que encontrarla ahi. Con dos registros
            // separados lo primero fallaba en silencio.
            //
            // Leer con una escritura en marcha da un valor indefinido en el
            // chip; aqui se deja el anterior, que es lo unico que no inventa
            // nada. En el chip ademas el nucleo se para cuatro ciclos, y eso
            // NO esta implementado: es la deuda D15.
            if (io_we && hit_cr && io_wdata[0] && !eepe) eedr <= mem_q;
            if (io_we && hit_arl) eear[7:0] <= io_wdata;
            if (io_we && hit_arh) eear[9:8] <= io_wdata[1:0];
        end
    end

    // EE_READY ES DE NIVEL, no de flanco: se dispara mientras EEPE este a cero.
    // No hay bandera que limpiar, y por eso este modulo no tiene `ack`.
    assign irq_ee = eerie & ~eepe;

    // Este periferico no usa `io_re`: la lectura de la celda la dispara EERE,
    // que es una ESCRITURA en EECR.
    wire unused_ee = &{1'b0, io_re};

endmodule

`default_nettype wire
