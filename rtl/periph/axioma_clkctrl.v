// AxiomaCore-328 - control de reloj, consumo y sueño
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El decimo y ultimo periferico de la fase 3, y el unico que no hace nada por
// si solo: lo que hace es DECIDIR QUIEN SE MUEVE Y CUANDO. Todos los demas
// cuelgan de el.
//
//   SMCR    dato 0x53   --   --   --   --   SM2  SM1  SM0  SE
//   MCUSR   dato 0x54   --   --   --   --   WDRF BORF EXTRF PORF
//   MCUCR   dato 0x55   --   BODS BODSE PUD --   --   IVSEL IVCE
//   CLKPR   dato 0x61   CLKPCE --  --   --   CLKPS3..CLKPS0
//   PRR     dato 0x64   PRTWI PRTIM2 PRTIM0 -- PRTIM1 PRSPI PRUSART0 PRADC
//
// ---------------------------------------------------------------------------
// LA DECISION DE FONDO: AQUI SE CORTAN RELOJES DE VERDAD
// ---------------------------------------------------------------------------
//
// `CLKPR` divide el reloj del sistema y `PRR` apaga perifericos uno a uno. Se
// puede implementar de tres maneras y solo una es honesta:
//
//   1. guardar los bits y no hacer nada — un programa que baje a f/8 para
//      ahorrar corriente seguiria viendo la USART a la velocidad de antes, y
//      eso no es incompatibilidad de detalle: es que el baudio sale mal;
//   2. generar un reloj dividido de verdad y repartirlo — en FPGA eso es un
//      reloj en la malla general y en ASIC una celda de puerta de reloj; hecho
//      a mano en Verilog es una puerta combinacional sobre el reloj, que genera
//      picos y que ninguna herramienta analiza bien;
//   3. HABILITACION DE RELOJE — un pulso `ce` que deja pasar un ciclo de cada
//      2^CLKPS. Es lo que sintetiza bien en las dos tecnologias: en la FPGA es
//      la entrada `CE` del biestable, que ya esta ahi, y en el flujo ASIC es de
//      donde las herramientas DERIVAN las celdas de puerta de reloj.
//
// Aqui se hace la tercera. La consecuencia buena es que **con `CLKPS`=0 la
// habilitacion vale 1 siempre**, o sea que el chip de hoy queda bit a bit
// identico y toda la regresion anterior sigue valiendo de red.
//
// LOS DOS RELOJES NO SON UNO, y esto sale directo de la figura 9-1 de la hoja
// de datos: `clk_CPU` alimenta al nucleo y `clk_I/O` a los perifericos. Se
// dividen por lo mismo, pero **se paran por separado**, y eso es justo lo que
// hace falta para el sueño: en modo `Idle` el nucleo se para y los
// temporizadores siguen contando.
//
// ---------------------------------------------------------------------------
// LA SECUENCIA TEMPORIZADA DE `CLKPCE`, QUE NO ES LA DEL PERRO GUARDIAN
// ---------------------------------------------------------------------------
//
// Es la tercera del chip y la mas estricta de las tres:
//
//   1. escribir `CLKPCE` a uno Y TODOS LOS DEMAS BITS A CERO, en la misma
//      escritura — el perro guardian pide `WDCE` y `WDE` a uno A LA VEZ, aqui
//      se pide `CLKPCE` SOLO;
//   2. y dentro de los cuatro ciclos siguientes, escribir `CLKPS` con `CLKPCE`
//      a cero.
//
// Copiar la del perro guardian aqui da un control de reloj que se deja cambiar
// con una escritura que el chip ignora, y al reves: un programa correcto no
// consigue cambiar el prescaler. La hoja de datos lo dice con estas palabras:
// «write the CLKPCE bit to one and all other bits in CLKPR to zero».
//
// Y HAY UNA CUARTA, `IVCE`, para mover la tabla de vectores al gestor de
// arranque. Misma forma, cuatro ciclos, y con una regla de mas que si esta en
// la hoja de datos: escribir `IVCE` **deshabilita las interrupciones** durante
// la ventana, porque mover los vectores a medias es la unica forma de que un
// salto acabe en cualquier parte. `IVSEL` sale de aqui, pero el gestor de
// arranque es de la fase 4: hasta entonces el SoC lo deja sin conectar, y eso
// es la deuda D16 — declarada, no olvidada.
//
// ---------------------------------------------------------------------------
// LOS SEIS MODOS DE SUEÑO, tabla 10-1
// ---------------------------------------------------------------------------
//
//   SM2:0   modo                     clk_CPU  clk_I/O
//    000    Idle                       no       SI
//    001    reduccion de ruido del ADC  no       no
//    010    Power-down                  no       no
//    011    Power-save                  no       no
//    100    reservado          -se trata como Idle, ver abajo-
//    101    reservado
//    110    Standby                     no       no
//    111    Standby extendido           no       no
//
// `SLEEP` solo duerme si `SE` esta puesto; sin el es un `NOP`, y eso no es un
// detalle de estilo: avr-libc escribe `SE`, ejecuta `SLEEP` y **vuelve a
// borrar `SE`** justo para que un `SLEEP` perdido en medio del codigo no pare
// el chip.
//
// SE DESPIERTA CON UNA INTERRUPCION HABILITADA, y basta con que lo este EN SU
// MASCARA: el bit `I` global no hace falta para despertar. La hoja de datos lo
// dice —«if an enabled interrupt occurs while the MCU is in a sleep mode, the
// MCU wakes up»— y la diferencia importa: con `I` a cero el chip despierta y
// SIGUE por la instruccion de despues del `SLEEP`, sin entrar en ninguna ISR.
// Es el idioma de «esperar a que pase algo» sin gastar una rutina.
//
// LOS MODOS QUE PARAN `clk_I/O` TIENEN UNA CONSECUENCIA QUE SE HEREDA: sin
// reloj de perifericos no hay deteccion de FLANCOS, asi que de `Power-down`
// solo despierta lo que no necesita reloj. Aqui eso son EL PERRO GUARDIAN, con
// su oscilador propio, y la EEPROM, que cuenta sus milisegundos con el mismo.
// No es una limitacion de esta implementacion: es lo que dice la hoja de datos,
// y sale solo de parar el reloj de verdad en vez de fingirlo.
//
// EN EL CHIP HAY UNA TERCERA, y aqui todavia no: la interrupcion externa de
// NIVEL BAJO, que se detecta de forma ASINCRONA —«the low level interrupt on
// INT0/INT1 is detected asynchronously... this interrupt can be used for waking
// the part also from sleep modes other than Idle mode»—. En `axioma_extint` el
// nivel se mira sobre el pin YA SINCRONIZADO, y ese sincronizador se para con
// `clk_I/O`, de modo que un nivel que llegue estando el chip dormido no se ve.
// Es la deuda D17, declarada el dia que este modulo entro.
//
// LOS RESERVADOS 100 Y 101 se tratan como `Idle`, que es el modo mas suave. Es
// la eleccion contraria a la del perro guardian —alli un valor reservado se
// trata como el mas LARGO— y por el mismo motivo en los dos casos: quedarse del
// lado que no rompe. Un modo de sueño de mas apaga un reloj que alguien
// esperaba encendido y el chip no despierta nunca; uno de menos solo gasta.

`default_nettype none

module axioma_clkctrl #(
    // El fusible CKDIV8 del chip viene programado de fabrica y arranca a f/8.
    // En una placa Arduino se desprograma, y aqui el valor por defecto es 0
    // —sin division— porque es lo que hace que el contraste ciclo a ciclo
    // contra simavr siga siendo valido: simavr no modela CLKPR.
    parameter [3:0] CLKPS_RESET = 4'd0
)(
    input  wire       clk,          // el reloj SIN dividir
    input  wire       rst_n,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- la instrucción SLEEP, que llega del secuenciador ----
    input  wire       sleep_pulso,

    // ---- lo que despierta ----
    input  wire       irq_pendiente,  // una interrupción habilitada EN SU MÁSCARA

    // ---- las fuentes de reinicio, para MCUSR ----
    input  wire       wdt_reset,

    // ---- los dos relojes, en forma de habilitación ----
    output wire       ce_cpu,       // clk_CPU
    output wire       ce_io,        // clk_I/O

    // ---- PRR, un bit por periférico ----
    output wire [7:0] prr,

    // ---- MCUCR ----
    output wire       pud,          // el pull-up global
    output wire       ivsel,        // la tabla de vectores, al gestor de arranque

    // ---- para quien quiera verlo ----
    output wire       dormido
);

    localparam [7:0] A_SMCR  = 8'h33;   // dato 0x53
    localparam [7:0] A_MCUSR = 8'h34;
    localparam [7:0] A_MCUCR = 8'h35;
    localparam [7:0] A_CLKPR = 8'h41;   // dato 0x61
    localparam [7:0] A_PRR   = 8'h44;

    wire hit_smcr  = (io_addr == A_SMCR);
    wire hit_mcusr = (io_addr == A_MCUSR);
    wire hit_mcucr = (io_addr == A_MCUCR);
    wire hit_clkpr = (io_addr == A_CLKPR);
    wire hit_prr   = (io_addr == A_PRR);

    assign io_sel = hit_smcr | hit_mcusr | hit_mcucr | hit_clkpr | hit_prr;

    // ---------------------------------------------------------- registros
    reg [3:0] clkps;
    reg       clkpce;
    reg [7:0] prr_q;
    reg [2:0] sm;
    reg       se;
    reg       bods, bodse, pud_q, ivsel_q, ivce;
    reg [3:0] mcusr_q;

    // ------------------------------------------------------- EL DIVISOR
    // Corre con el reloj SIN dividir, que es lo unico que puede hacer: es quien
    // fabrica la division. Todo lo demas de este modulo va con `ce_base`, igual
    // que el resto del chip, para que una escritura no se vea 2^CLKPS veces.
    //
    // Los valores 9..15 de CLKPS estan RESERVADOS. Se tratan como el 8 -la
    // division mayor-, que es la eleccion segura: un chip mas lento de lo que
    // pidio el programa funciona despacio, uno mas rapido incumple los tiempos.
    wire [3:0] clkps_ef = (clkps > 4'd8) ? 4'd8 : clkps;
    wire [8:0] limite   = (9'd1 << clkps_ef) - 9'd1;

    reg [8:0] divisor;
    wire      ce_base = (divisor == 9'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        divisor <= 9'd0;
        else if (ce_base)  divisor <= limite;
        else               divisor <= divisor - 9'd1;
    end

    // ------------------------------------------------------- EL SUEÑO
    // `SLEEP` llega del secuenciador como un pulso, pero el secuenciador corre
    // con `ce_cpu`: con el prescaler puesto, ese pulso dura 2^CLKPS ciclos del
    // reloj de entrada. Por eso se mira SOLO en `ce_base`, igual que todo lo
    // demas de aqui.
    reg durmiendo;

    // Tabla 10-1: en `Idle` el reloj de perifericos SIGUE. En todos los demas
    // se para, y de ahi sale solo que de un `Power-down` no despierte un flanco.
    wire idle = (sm == 3'b000) || (sm == 3'b100) || (sm == 3'b101);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            durmiendo <= 1'b0;
        end else if (ce_base) begin
            // Despertar gana sobre dormirse: si la interrupcion llega en el
            // mismo ciclo que el `SLEEP`, el chip no se duerme. Al reves se
            // perderia el despertar y el chip no volveria nunca.
            if (irq_pendiente)              durmiendo <= 1'b0;
            else if (sleep_pulso && se)     durmiendo <= 1'b1;
        end
    end

    assign dormido = durmiendo;

    // El nucleo se para SIEMPRE que se duerme; los perifericos solo si el modo
    // lo dice.
    assign ce_cpu = ce_base & ~durmiendo;
    assign ce_io  = ce_base & ~(durmiendo & ~idle);

    // ------------------------------------------- las dos ventanas de 4 ciclos
    // `CLKPCE` e `IVCE` son dos secuencias temporizadas distintas en el mismo
    // modulo, y cada una tiene su contador porque son independientes: un
    // programa puede estar a medias de una y empezar la otra.
    reg [2:0] vent_clk, vent_ivce;
    wire      abierta_clk  = (vent_clk  != 3'd0);
    wire      abierta_ivce = (vent_ivce != 3'd0);

    // LA ESCRITURA QUE ABRE: `CLKPCE` a uno Y TODO LO DEMAS A CERO. No es la
    // del perro guardian, que pide DOS bits a uno. Literal de la hoja de datos.
    wire abre_clk  = io_we && hit_clkpr && (io_wdata == 8'h80);
    wire abre_ivce = io_we && hit_mcucr && io_wdata[0];

    // LA ESCRITURA QUE CIERRA, y aqui esta la segunda diferencia con el perro
    // guardian: alli `WDCE` se cae SOLO a los cuatro ciclos, y aqui la hoja de
    // datos añade una mitad mas —«CLKPCE is cleared by hardware four cycles
    // after it is written OR WHEN CLKPS BITS ARE WRITTEN»—. O sea que la
    // segunda escritura de la secuencia cierra la ventana en el acto, y lo
    // mismo con `IVCE` cuando se escribe `IVSEL`.
    //
    // No es cosmetico: sin esto, tras cambiar el prescaler la ventana sigue
    // abierta tres ciclos mas y una escritura cualquiera a CLKPR —por ejemplo
    // la de un programa que lo lea y lo vuelva a escribir— cambiaria el reloj
    // del chip sin hacer la secuencia. Lo encontro el banco.
    wire cierra_clk  = io_we && hit_clkpr && abierta_clk  && !io_wdata[7];
    wire cierra_ivce = io_we && hit_mcucr && abierta_ivce && !io_wdata[0];

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            vent_clk  <= 3'd0;
            vent_ivce <= 3'd0;
        end else if (ce_base) begin
            if      (abre_clk)     vent_clk  <= 3'd4;
            else if (cierra_clk)   vent_clk  <= 3'd0;
            else if (abierta_clk)  vent_clk  <= vent_clk - 3'd1;

            if      (abre_ivce)    vent_ivce <= 3'd4;
            else if (cierra_ivce)  vent_ivce <= 3'd0;
            else if (abierta_ivce) vent_ivce <= vent_ivce - 3'd1;
        end
    end

    // ------------------------------------------------------------ escritura
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            clkps   <= CLKPS_RESET;
            clkpce  <= 1'b0;
            prr_q   <= 8'h00;
            sm      <= 3'b000;
            se      <= 1'b0;
            bods    <= 1'b0;  bodse <= 1'b0;  pud_q <= 1'b0;
            ivsel_q <= 1'b0;  ivce  <= 1'b0;
            // PORF: el unico reinicio que este chip tiene de verdad es el de
            // encendido, asi que arranca puesto. Es lo que hace el chip, y un
            // programa que mire MCUSR para saber POR QUE arranco tiene que
            // encontrar algo.
            mcusr_q <= 4'b0001;
        end else if (ce_base) begin
            // Los dos bits de habilitacion los lleva su ventana, no el
            // programa: se ponen al abrirla y se caen solos al agotarse.
            clkpce <= abre_clk  | (abierta_clk  && !cierra_clk  && vent_clk  != 3'd1);
            ivce   <= abre_ivce | (abierta_ivce && !cierra_ivce && vent_ivce != 3'd1);

            // CLKPS solo dentro de la ventana, y la escritura que la ABRE no
            // cuenta: esa lleva CLKPCE puesto y los CLKPS a cero.
            if (cierra_clk) clkps <= io_wdata[3:0];

            if (io_we && hit_smcr) begin
                sm <= io_wdata[3:1];
                se <= io_wdata[0];
            end

            // EL BIT 4 DE `PRR` NO EXISTE -la tabla 10-2 tiene siete bits y el
            // hueco esta en medio-, y un bit reservado SE LEE A CERO. Guardarlo
            // tal cual lo devolvia a uno, que es lo que un programa que lea el
            // registro para volver a escribirlo propagaria sin enterarse. Lo
            // encontro el barrido semantico contrastando contra avr-libc.
            if (io_we && hit_prr) prr_q <= io_wdata & 8'hEF;

            if (io_we && hit_mcucr) begin
                bods  <= io_wdata[6];
                bodse <= io_wdata[5];
                pud_q <= io_wdata[4];
                // IVSEL, como CLKPS, solo dentro de SU ventana.
                if (cierra_ivce) ivsel_q <= io_wdata[1];
            end

            // MCUSR SE LIMPIA ESCRIBIENDO CERO, no uno: es al reves que casi
            // todas las banderas del chip. La hoja de datos manda leerlo y
            // limpiarlo cuanto antes, porque si no las causas de dos reinicios
            // seguidos se acumulan y ya no se sabe cual fue.
            if (io_we && hit_mcusr) mcusr_q <= mcusr_q & io_wdata[3:0];

            // El hardware manda sobre la bandera y va DESPUES de la escritura.
            if (wdt_reset) mcusr_q[3] <= 1'b1;
        end
    end

    // ------------------------------------------------------------ lectura
    wire [7:0] r_smcr  = {4'b0000, sm, se};
    wire [7:0] r_mcusr = {4'b0000, mcusr_q};
    wire [7:0] r_mcucr = {1'b0, bods, bodse, pud_q, 2'b00, ivsel_q, ivce};
    wire [7:0] r_clkpr = {clkpce, 3'b000, clkps};

    assign io_rdata = hit_smcr  ? r_smcr  :
                      hit_mcusr ? r_mcusr :
                      hit_mcucr ? r_mcucr :
                      hit_clkpr ? r_clkpr :
                      hit_prr   ? prr_q   : 8'h00;

    // ------------------------------------------------------------- salidas
    assign prr   = prr_q;
    assign pud   = pud_q;
    assign ivsel = ivsel_q;

    // Este periferico no tiene efectos laterales de lectura.
    wire unused_clk = &{1'b0, io_re};

endmodule

`default_nettype wire
