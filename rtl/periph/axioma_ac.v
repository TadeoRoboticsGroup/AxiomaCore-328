// AxiomaCore-328 - comparador analogico
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El segundo modulo que no es digital de punta a punta, y se corta por el mismo
// sitio que el ADC (ADR 0002): EL COMPARADOR ES ANALOGICO Y SE QUEDA FUERA. Aqui
// dentro vive lo que un comparador de tension no puede hacer por si solo —elegir
// sus entradas, detectar flancos, levantar banderas y disparar una captura— y
// eso es lo que se sintetiza.
//
//   ACSR   dato 0x50   ACD ACBG ACO ACI ACIE ACIC ACIS1 ACIS0
//   DIDR1  dato 0x7F   AIN1D, AIN0D: apagar el bufer de entrada DIGITAL
//
// LAS DOS ENTRADAS NO SON DOS PINES FIJOS, y esa es la unica complicacion de
// verdad de este periferico:
//
//   la POSITIVA es `AIN0` -PD6-, salvo que `ACBG` este puesto: entonces es la
//   referencia interna de 1,1 V, que es como se mide una tension de bateria sin
//   gastar un pin;
//   la NEGATIVA es `AIN1` -PD7-, salvo que `ACME` este puesto Y el ADC apagado:
//   entonces es EL CANAL QUE ELIJA `ADMUX`. Ocho pines mas, gratis.
//
// Ese `ACME` vive en `ADCSRB`, que es un registro del ADC, asi que llega de
// fuera junto con `ADEN` y el canal. La condicion es literal de la tabla 22-1 de
// la hoja de datos: con el ADC encendido manda el ADC, y el comparador se queda
// con `AIN1`. Es lo que evita que dos cosas usen el multiplexor a la vez.
//
// `ACO` SE LEE SINCRONIZADO, y la hoja de datos lo dice con un numero: la salida
// del comparador tarda «1 - 2 clock cycles» en aparecer en el registro. Aqui son
// dos biestables, que es de donde sale ese numero. No es un adorno: sin ellos,
// un comparador que oscile cerca del umbral -que es lo que hace un comparador
// sin histeresis- mete metaestabilidad en el registro que lee el programa.
//
// `ACIS` ELIGE QUE FLANCO INTERRUMPE: 00 los dos -conmutacion-, 10 el de bajada,
// 11 el de subida. El 01 esta RESERVADO, y aqui se trata como el 00, que es lo
// que hace el chip al no decodificarlo aparte.
//
// `ACIC` LLEVA LA SALIDA A LA CAPTURA DEL TIMER1, en lugar del pin `ICP1`. Es lo
// que permite medir un tiempo entre dos cruces de umbral sin que el programa
// tenga que estar mirando: el temporizador se lleva la cuenta el solo. El
// multiplexado lo hace el SoC, que es quien tiene los dos cables.

`default_nettype none

module axioma_ac (
    input  wire       clk,
    input  wire       rst_n,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- la frontera con lo analógico (ADR 0002) ----
    output wire       ac_apagado,    // ACD: el comparador se apaga para ahorrar
    output wire       ac_bandgap,    // ACBG: la positiva es la interna de 1,1 V
    output wire       ac_neg_mux,    // la negativa sale del multiplexor del ADC
    input  wire       ac_salida,     // lo que dice el comparador

    // ---- lo que viene del ADC ----
    input  wire       adc_acme,      // ACME, que vive en ADCSRB
    input  wire       adc_encendido, // ADEN: con el ADC en marcha manda el ADC

    // ---- el buffer de entrada digital, que DIDR1 apaga ----
    output wire [7:0] didr_dis,      // AIN0 es PD6 y AIN1 es PD7

    // ---- a la captura del Timer1 ----
    output wire       ac_a_captura,  // ACIC
    output wire       ac_o,          // la salida ya sincronizada


    // ---- las banderas CRUDAS, para el disparo automatico del ADC ----
    // Son las mismas que se leen en el registro de banderas, SIN la mascara de
    // habilitacion: el disparo del ADC va por la bandera aunque su interrupcion
    // este apagada, y por eso no vale reutilizar las peticiones de vector.
    output wire       flag_aci,

    // ---- interrupción ----
    output wire       irq_ac,        // vector 23
    input  wire       ack_ac
);

    localparam [7:0] A_ACSR  = 8'h30;   // dato 0x50
    localparam [7:0] A_DIDR1 = 8'h5F;   // dato 0x7F

    wire hit_acsr  = (io_addr == A_ACSR);
    wire hit_didr1 = (io_addr == A_DIDR1);

    assign io_sel = hit_acsr | hit_didr1;

    // ---------------------------------------------------------- registros
    reg       acd, acbg, aci, acie, acic;
    reg [1:0] acis;
    reg [1:0] didr1;

    // ------------------------------------------------- ACO, sincronizada
    // «1 - 2 clock cycles» dice la hoja de datos, y esos son estos dos
    // biestables. Con el comparador apagado la salida se lee como cero.
    reg [1:0] aco_sync;
    wire      aco = aco_sync[1] & ~acd;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) aco_sync <= 2'b00;
        else        aco_sync <= {aco_sync[0], ac_salida};
    end

    // ------------------------------------------------- deteccion de flanco
    reg  aco_q;
    wire sube = aco & ~aco_q;
    wire baja = ~aco & aco_q;

    // ACIS: 00 conmutacion, 01 reservado -se trata como 00-, 10 bajada,
    // 11 subida.
    wire dispara = (acis == 2'b10) ? baja :
                   (acis == 2'b11) ? sube : (sube | baja);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aco_q <= 1'b0;
            aci   <= 1'b0;
        end else begin
            aco_q <= aco;
            // El hardware manda sobre la bandera y va DESPUES de la escritura:
            // si el programa la limpia en el mismo ciclo en que llega el
            // flanco, gana el flanco. Es lo que evita perder una interrupcion.
            if (io_we && hit_acsr && io_wdata[4]) aci <= 1'b0;
            // NO SE FILTRA POR `ACD`, y eso es deliberado: apagar el comparador
            // con la salida alta hace CAER `aco`, y esa caida es un flanco que
            // levanta la bandera. La hoja de datos avisa de ello con estas
            // palabras —«when changing the ACD bit, the Analog Comparator
            // Interrupt must be disabled by clearing the ACIE bit... otherwise
            // an interrupt can occur when the bit is changed»—, o sea que el
            // chip TAMBIEN la levanta. Suprimirla aqui haria que un programa
            // escrito para el chip se comportara distinto.
            //
            // Lo destapo la mutacion: el mutante que quitaba el filtro
            // sobrevivia, y al mirar por que resulto que el equivocado era el
            // filtro. Ahora el mutante es el contrario.
            if (dispara)                          aci <= 1'b1;
            if (ack_ac)                           aci <= 1'b0;
        end
    end

    // ------------------------------------------------------------ lectura
    wire [7:0] r_acsr = {acd, acbg, aco, aci, acie, acic, acis};

    assign io_rdata = hit_acsr  ? r_acsr           :
                      hit_didr1 ? {6'b0, didr1}    : 8'h00;

    // ------------------------------------------------------------ escritura
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            acd <= 1'b0;  acbg <= 1'b0;  acie <= 1'b0;  acic <= 1'b0;
            acis <= 2'b00; didr1 <= 2'b00;
        end else begin
            if (io_we && hit_acsr) begin
                acd  <= io_wdata[7];
                acbg <= io_wdata[6];
                // ACO es de solo lectura; ACI se trata arriba.
                acie <= io_wdata[3];
                acic <= io_wdata[2];
                acis <= io_wdata[1:0];
            end
            if (io_we && hit_didr1) didr1 <= io_wdata[1:0];
        end
    end

    // ------------------------------------------------------------- salidas
    assign ac_apagado   = acd;
    assign ac_bandgap   = acbg;
    // LA TABLA 22-1, LITERAL: el multiplexor del ADC alimenta la entrada
    // negativa solo si ACME esta puesto Y el ADC esta apagado. Con el ADC en
    // marcha manda el ADC y el comparador se queda con AIN1.
    assign ac_neg_mux   = adc_acme & ~adc_encendido;
    assign ac_a_captura = acic;
    assign ac_o         = aco;
    // AIN0 es PD6 y AIN1 es PD7.
    assign didr_dis     = {didr1[1], didr1[0], 6'b0};

    // Este periferico NO tiene efectos laterales de lectura -a diferencia de la
    // USART, donde leer UDR0 saca un byte del bufer-, asi que `io_re` se declara
    // sin usar a proposito. Y el bit 5 de una escritura a ACSR es ACO, que es de
    // SOLO LECTURA: escribirlo no hace nada, que es lo que dice la hoja de
    // datos y lo que hace el chip.
    wire unused_ac = &{1'b0, io_re, io_wdata[5]};

    assign flag_aci = aci;

    assign irq_ac = aci & acie;

endmodule

`default_nettype wire
