// AxiomaCore-328 - perro guardian
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El periferico que reinicia el chip cuando el programa se cuelga. Y el unico
// del proyecto cuyo reloj NO ES EL DEL SISTEMA: corre de un oscilador propio de
// 128 kHz, y esa es justamente su razon de ser — si dependiera del reloj
// principal, un fallo que parase ese reloj pararia tambien al vigilante.
//
//   WDTCSR  dato 0x60   WDIF WDIE WDP3 WDCE WDE WDP2 WDP1 WDP0
//
// FIJATE EN EL ORDEN DE LOS BITS: `WDP3` esta en el bit 5 y `WDP2..0` en los
// 2..0, con `WDCE` y `WDE` EN MEDIO. No es un capricho de la hoja de datos: es
// que el registro crecio de tres bits de prescaler a cuatro y el cuarto se metio
// donde cupo. Copiarlo «ordenado» da un perro guardian que muerde al cabo de un
// tiempo que no es el que pidio el programa, y eso no se nota hasta que el
// producto esta en el campo.
//
// LA SECUENCIA TEMPORIZADA, que es lo que de verdad hay que implementar bien.
// Cambiar `WDE` o el prescaler no se hace con una escritura: hace falta
//
//   1. escribir `WDCE` y `WDE` A UNO A LA VEZ, en la misma escritura;
//   2. y DENTRO DE LOS CUATRO CICLOS SIGUIENTES, escribir el valor que se
//      quiere, con `WDCE` a cero.
//
// Fuera de esa ventana, las escrituras a `WDE` y a los `WDP` SE IGNORAN. El
// hardware baja `WDCE` solo a los cuatro ciclos. Existe para que un programa
// desbocado —que es exactamente lo que el perro guardian vigila— no pueda
// apagarlo por accidente al escribir basura en un registro.
//
// `WDIE` NO ESTA PROTEGIDO: se escribe cuando se quiera. Lo protegido es lo que
// puede DESACTIVAR la vigilancia.
//
// LOS TRES MODOS, tabla 11-2:
//
//   WDE=0 WDIE=1   solo INTERRUPCION: el vector 6 al vencer, y nada mas;
//   WDE=1 WDIE=0   solo REINICIO: el chip se reinicia al vencer;
//   WDE=1 WDIE=1   INTERRUPCION Y DESPUES REINICIO: al vencer salta el vector y
//                  el hardware LIMPIA `WDIE`, de modo que el siguiente
//                  vencimiento ya reinicia. Es el patron de «guardar el estado
//                  y morir»: la ISR tiene un periodo entero para escribir en la
//                  EEPROM lo que haga falta antes de que el chip se caiga.
//
// `WDR` REARMA LA CUENTA, y es la instruccion que el programa mete en su bucle
// principal. Llega del secuenciador como un pulso.
//
// LA HABILITACION DE RELOJ NO LO GATEA TODO, Y ESO ES LO IMPORTANTE DE ESTE
// MODULO. `CLKPR` y `PRR` paran `clk_I/O`, y con el se paran la ventana de
// `WDCE` y las escrituras de registro, que es lo correcto: son accesos del
// programa. Pero LA CUENTA Y EL VENCIMIENTO NO SE GATEAN, porque corren con el
// oscilador propio. Un perro guardian que se parase al pararse el reloj del
// sistema no serviria para nada — un fallo que pare ese reloj es justo lo que
// vigila—, y ademas es lo que permite despertar de un `Power-down`, donde
// `clk_I/O` esta parado y no queda nadie mas mirando.
//
// EL OSCILADOR NO ESTA AQUI DENTRO, por lo mismo que el comparador del ADC no
// esta en `axioma_adc` (ADR 0002): 128 kHz de RC no son logica. Entra como un
// pulso, `osc_tick`, y quien instancia el SoC decide de donde sale — en la FPGA
// se divide del reloj de sistema, en silicio es una celda del PDK.

`default_nettype none

module axioma_wdt (
    input  wire       clk,
    input  wire       rst_n,

    // La habilitacion de reloj (ADR 0003). OJO: aqui NO lo gatea todo, y esa
    // es la gracia de este modulo — ver el comentario de mas abajo.
    input  wire       ce,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- el oscilador propio, que no vive aquí ----
    input  wire       osc_tick,     // un pulso por ciclo del oscilador de 128 kHz

    // ---- la instrucción WDR ----
    input  wire       wdr,          // rearma la cuenta

    // ---- lo que hace al vencer ----
    output wire       wdt_reset,    // reinicia el chip
    output wire       irq_wdt,      // vector 6
    input  wire       ack_wdt
);

    localparam [7:0] A_WDTCSR = 8'h40;   // dato 0x60

    wire hit = (io_addr == A_WDTCSR);
    assign io_sel = hit;

    // ---------------------------------------------------------- registros
    reg       wdif, wdie, wdce, wde;
    reg [3:0] wdp;

    // ------------------------------------------------ la ventana de WDCE
    // El hardware baja WDCE solo a los CUATRO ciclos, y mientras esta puesto -y
    // solo entonces- se pueden tocar WDE y el prescaler.
    reg [2:0] ventana;
    wire      abierta = (ventana != 3'd0);

    // Escribir WDCE y WDE a uno A LA VEZ abre la ventana. Cualquier otra
    // escritura la cierra, que es lo que dice la hoja de datos: la secuencia es
    // de dos escrituras seguidas, no de dos escrituras cuando sea.
    wire abre = io_we && hit && io_wdata[4] && io_wdata[3];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)               ventana <= 3'd0;
        else if (ce && abre)      ventana <= 3'd4;
        else if (ce && abierta)   ventana <= ventana - 3'd1;
    end

    // ---------------------------------------------------- el contador
    // El prescaler cuenta ciclos del oscilador: WDP=0 son 2K y cada paso
    // duplica, hasta 1024K con WDP=9. Los valores 10..15 no existen en la hoja
    // de datos; se tratan como el mayor, que es lo mas seguro: un perro guardian
    // que tarda de mas avisa tarde, uno que tarda de menos reinicia un chip que
    // estaba bien.
    wire [3:0]  wdp_ef = (wdp > 4'd9) ? 4'd9 : wdp;
    wire [20:0] limite = (21'd2048 << wdp_ef) - 21'd1;

    reg [20:0] cuenta;

    // El perro corre si esta habilitado el reinicio o la interrupcion.
    wire corriendo = wde | wdie;
    wire vence     = corriendo && osc_tick && (cuenta == limite);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cuenta <= 21'd0;
        end else if (wdr || !corriendo) begin
            // WDR REARMA, y apagarlo tambien: al volver a encenderlo la cuenta
            // empieza de cero, que es lo que espera un programa que lo activa
            // justo antes de una operacion larga.
            cuenta <= 21'd0;
        end else if (osc_tick) begin
            // La cuenta va de 0 a limite, asi que el ciclo en que vale `limite`
            // es el numero 2048<<WDP. Contar hasta la potencia de dos en vez de
            // hasta ella menos uno da un periodo un ciclo largo: con 8 segundos
            // no se nota, con 16 milisegundos empieza a notarse.
            cuenta <= vence ? 21'd0 : cuenta + 21'd1;
        end
    end

    // ------------------------------------------- que pasa al vencer
    // Tabla 11-2: con los dos habilitados salta la interrupcion Y SE LIMPIA
    // WDIE, de modo que el siguiente vencimiento ya reinicia. La ISR tiene un
    // periodo entero para guardar lo que haga falta antes de morir.
    reg reset_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wdif    <= 1'b0;
            reset_q <= 1'b0;
        end else begin
            reset_q <= 1'b0;
            if (io_we && hit && io_wdata[7]) wdif <= 1'b0;
            if (ack_wdt)                     wdif <= 1'b0;
            if (vence) begin
                if (wdie) wdif    <= 1'b1;
                else if (wde) reset_q <= 1'b1;
            end
        end
    end

    // ------------------------------------------------------------ lectura
    assign io_rdata = hit ? {wdif, wdie, wdp[3], wdce, wde, wdp[2:0]} : 8'h00;

    // ------------------------------------------------------------ escritura
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            wdie <= 1'b0;  wdce <= 1'b0;  wde <= 1'b0;  wdp <= 4'd0;
        end else begin
          if (ce) begin
            // WDCE lo lleva la ventana, no el programa: se pone al abrirla y se
            // cae solo cuando se agota.
            wdce <= abre | (abierta && ventana != 3'd1);

            if (io_we && hit) begin
                // WDIE no esta protegido: cambiarlo no puede desactivar la
                // vigilancia, solo cambiar que hace al vencer.
                wdie <= io_wdata[6];
                // WDE y el prescaler SOLO dentro de la ventana, y la escritura
                // que ABRE la ventana no cuenta -esa lleva WDCE puesto-.
                if (abierta && !io_wdata[4]) begin
                    wde <= io_wdata[3];
                    wdp <= {io_wdata[5], io_wdata[2:0]};
                end
            end
          end
            // EL VENCIMIENTO NO VA GATEADO, y este `end` mal alineado esta a
            // proposito para que se vea: lo de arriba corre con `clk_I/O` y
            // esto corre con el OSCILADOR. Un perro guardian que se parase al
            // pararse el reloj del sistema no serviria para nada — es
            // exactamente el caso que vigila.
            if (vence && wdie && wde) wdie <= 1'b0;
        end
    end

    assign wdt_reset = reset_q;
    assign irq_wdt   = wdif & wdie;

    // Este periferico no tiene efectos laterales de lectura.
    wire unused_wdt = &{1'b0, io_re};

endmodule

`default_nettype wire
