// AxiomaCore-328 - SPI, maestro y esclavo
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El bus del que cuelgan la tarjeta SD, las pantallas, los NeoPixel por
// hardware y media estantería de módulos. En el 328P son tres registros y
// cuatro pines:
//
//   SPCR  I/O 0x2C   SPIE SPE DORD MSTR CPOL CPHA SPR1 SPR0
//   SPSR  I/O 0x2D   SPIF WCOL  -    -    -    -   -   SPI2X
//   SPDR  I/O 0x2E   dato: escribirlo ARRANCA una transferencia de maestro
//
//   SS    PB2      MOSI  PB3      MISO  PB4      SCK  PB5
//
// DOS FLANCOS POR BIT, Y HACEN COSAS DISTINTAS. En uno se MUESTREA lo que
// entra y en el otro se DESPLAZA lo que sale. Tienen que ser flancos distintos:
// si el dato de salida cambiara en el mismo flanco en el que el otro extremo
// muestrea, el otro extremo leería el bit a mitad de cambio. Por eso aquí hay
// dos registros de desplazamiento y un biestable de salida, y no un solo
// registro haciendo las dos cosas.
//
// LOS CUATRO MODOS. `CPOL` dice si el reloj reposa alto o bajo; `CPHA`, si el
// dato se MUESTREA en el primer flanco del bit o en el segundo. Con CPHA=0 el
// primer bit tiene que estar ya en el pin ANTES del primer flanco, así que sale
// al cargar `SPDR`; con CPHA=1 sale EN el primer flanco. Elegir mal el modo no
// da un error: da datos desplazados un bit, que es peor.
//
// De ahí sale la carga, que es lo único asimétrico del módulo:
//
//   CPHA=0   al cargar se presenta el bit 7 y el registro se queda con el
//            resto ya desplazado; el primer flanco de desplazamiento saca el 6.
//   CPHA=1   al cargar no se presenta nada; el primer flanco de desplazamiento
//            saca el 7.
//
// LA TRAMPA Nº 11 OTRA VEZ, la de los efectos laterales de LECTURA. `SPIF` y
// `WCOL` no se limpian escribiendo: se limpian LEYENDO `SPSR` con el bit
// puesto y DESPUÉS accediendo a `SPDR`. Son dos accesos en orden, y el
// hardware tiene que recordar el primero. Es lo que hace que
// `while(!(SPSR & (1<<SPIF))); dato = SPDR;` funcione sin escribir nada.
//
// WCOL: escribir `SPDR` mientras hay una transferencia en marcha NO la
// interrumpe y NO carga el dato; sólo levanta la bandera de colisión. Un
// programa que ignore WCOL pierde bytes en silencio.
//
// EL BUFER DE RECEPCION ES DOBLE, el de transmisión no. Leer `SPDR` da el byte
// recibido, que se copió del registro de desplazamiento al terminar; mientras
// tanto, la siguiente transferencia puede ir entrando. Escribir `SPDR` va
// directo al registro de desplazamiento — por eso existe WCOL.
//
// MSTR SE LIMPIA SOLO. Si se es maestro y alguien tira de `SS` hacia abajo
// estando configurado como entrada, el hardware entiende que otro maestro ha
// tomado el bus: limpia `MSTR`, levanta `SPIF` y el chip pasa a esclavo. Es la
// detección de colisión de maestros, y sin ella dos maestros se pelean por el
// bus sin que nadie se entere.
//
// LOS PINES: quién manda en cada uno (tabla 18-1 de la hoja de datos)
//
//                MOSI      MISO      SCK       SS
//     maestro    usuario   ENTRADA   usuario   usuario
//     esclavo    ENTRADA   usuario   ENTRADA   ENTRADA
//
// «Usuario» quiere decir que el programa SIGUE teniendo que poner `DDRx`: un
// maestro que se olvide de poner MOSI y SCK como salidas no saca nada, igual
// que en el chip. Lo que no es del usuario lo fuerza el hardware, y para eso
// `axioma_gpio` tiene una anulación de DIRECCIÓN separada de la de valor.
//
// EL RELOJ DEL MAESTRO sale de un divisor propio: 4, 16, 64 o 128 según
// SPR1:0, y la mitad con `SPI2X`. No usa el prescaler de los temporizadores.
//
// SIMAVR NO SIRVE DE ORACULO AQUI, igual que con la USART: su modelo de SPI
// transporta bytes enteros por IRQs internas y no serializa nada, así que no
// hay forma de onda que comparar. La comparación de registros sí vale. Ver
// docs/01-arquitectura.md §8bis.

`default_nettype none

module axioma_spi (
    input  wire       clk,
    input  wire       rst_n,

    // La habilitacion de reloj: un pulso por ciclo de sistema (ADR 0003).
    // Con CLKPS=0 vale 1 siempre y este modulo se comporta como antes.
    input  wire       ce,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- pines, tal como llegan del pad ----
    // `ss_es_salida` es `DDB2` ya resuelto. Hace falta aquí porque la detección
    // de colisión de maestros SÓLO aplica si `SS` está como ENTRADA: la hoja de
    // datos dice que si está como salida «the pin is a general output pin which
    // does not affect the SPI system». Sin esto, un `digitalWrite(SS, LOW)`
    // —que es como selecciona a su esclavo cualquier sketch de Arduino— borraría
    // `MSTR` y el maestro dejaría de serlo en mitad de la primera transferencia.
    input  wire       ss_es_salida,
    input  wire       ss_pin,
    input  wire       sck_pin,
    input  wire       mosi_pin,
    input  wire       miso_pin,

    // ---- lo que este periférico impone sobre los pines ----
    // `_oe` es la anulación de DIRECCIÓN de la tabla 18-1; `_val`, la de valor.
    output wire       sck_out,
    output wire       sck_oe,
    output wire       mosi_out,
    output wire       mosi_oe,
    output wire       miso_out,
    output wire       miso_oe,
    output wire       ss_oe_force,      // el SS del esclavo, forzado a entrada

    // ---- interrupción ----
    output wire       irq_spi,
    input  wire       ack_spi
);

    localparam [7:0] A_SPCR = 8'h2C;
    localparam [7:0] A_SPSR = 8'h2D;
    localparam [7:0] A_SPDR = 8'h2E;

    wire hit_spcr = (io_addr == A_SPCR);
    wire hit_spsr = (io_addr == A_SPSR);
    wire hit_spdr = (io_addr == A_SPDR);
    assign io_sel = hit_spcr | hit_spsr | hit_spdr;

    // ------------------------------------------------------------ registros
    reg spie_q, spe_q, dord_q, mstr_q, cpol_q, cpha_q;
    reg [1:0] spr_q;
    reg spi2x_q;
    reg spif_q, wcol_q;

    reg [7:0] tx_q;         // lo que queda por sacar
    reg [7:0] rx_q;          // lo que va entrando
    reg       out_q;         // el bit que está en el pin
    reg [7:0] rxbuf_q;      // el búfer de recepción, que es lo que se lee
    reg [2:0] bitcnt_q;
    reg       busy_q;
    // EL RELOJ TIENE QUE VOLVER AL REPOSO. Con CPHA=0 el octavo bit se muestrea
    // en el PRIMER flanco de su bit, así que cuando el byte termina al reloj le
    // queda todavía medio periodo para volver a donde `CPOL` dice. Cortarlo ahí
    // deja el último bit medio y un esclavo de verdad se queda desincronizado.
    // Este biestable es ese medio periodo: el byte ya está, pero la
    // transferencia no ha acabado.
    reg       cerrando_q;

    // LA SECUENCIA DE LIMPIEZA. `SPIF` y `WCOL` se limpian leyendo `SPSR` con
    // el bit puesto y luego accediendo a `SPDR`. Este biestable es el «luego»:
    // recuerda que ya hubo una lectura de SPSR con algo que limpiar.
    reg       spsr_leido;

    wire rd_spsr = io_re && hit_spsr;
    wire rd_spdr = io_re && hit_spdr;
    wire wr_spdr = io_we && hit_spdr;
    wire acc_spdr = rd_spdr | wr_spdr;

    // ------------------------------------------------------ sincronizadores
    // COMO ESCLAVO, el reloj y la selección vienen de otro chip y son
    // asíncronos de verdad: dos biestables antes de mirarlos, igual que el pin
    // T0 de los temporizadores. `MOSI` pasa por los MISMOS dos, y eso importa:
    // el bit se muestrea con el flanco ya retrasado por el sincronizador, así
    // que los dos tienen que llegar con el mismo retraso o se leería el bit de
    // al lado.
    //
    // COMO MAESTRO, `MISO` NO PASA POR AQUI, y es deliberado. El reloj lo
    // genera este módulo, así que el dato del esclavo es síncrono con NUESTRO
    // reloj y lo que hay entre los dos es la especificación de tiempos de
    // preparación de la hoja de datos, no una travesía entre dominios. Con dos
    // biestables el dato llegaría dos ciclos tarde, y a `fosc/4` —medio periodo
    // son dos ciclos— eso es UN BIT ENTERO: el maestro leería todo desplazado.
    // Lo cazó el banco a la primera, con los cuatro modos a la vez.
    reg [2:0] sck_s, ss_s, mosi_s;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            sck_s  <= 3'b000;  ss_s <= 3'b111;  mosi_s <= 3'b000;
        end else if (ce) begin
            sck_s  <= {sck_s[1:0],  sck_pin};
            ss_s   <= {ss_s[1:0],   ss_pin};
            mosi_s <= {mosi_s[1:0], mosi_pin};
        end
    end
    wire ss_bajo = ~ss_s[2];

    // ------------------------------------------------- generador de reloj
    // 4, 16, 64 o 128, y la mitad con SPI2X. El contador cuenta MEDIOS
    // periodos: un flanco de SCK por cada vuelta.
    reg [6:0] div_q;
    reg [6:0] div_top;
    always @(*) begin
        case (spr_q)
            2'd0: div_top = spi2x_q ? 7'd0  : 7'd1;    // /2  o /4
            2'd1: div_top = spi2x_q ? 7'd3  : 7'd7;    // /8  o /16
            2'd2: div_top = spi2x_q ? 7'd15 : 7'd31;   // /32 o /64
            default: div_top = spi2x_q ? 7'd31 : 7'd63; // /64 o /128
        endcase
    end

    wire maestro = spe_q & mstr_q;
    wire medio_periodo = maestro && busy_q && (div_q == div_top);

    // Reloj del maestro. Arranca en reposo (CPOL) y conmuta en cada medio
    // periodo mientras dure la transferencia.
    reg sck_q;

    // Flanco que corresponde a cada cosa, según CPHA:
    //   CPHA=0  se MUESTREA en el primer flanco del bit, se DESPLAZA en el 2º
    //   CPHA=1  se desplaza en el primero y se muestrea en el segundo
    // `sck_q` es el valor ANTES de conmutar, así que el primer flanco de un bit
    // es el que lo saca de reposo: sck_q == cpol.
    wire primer_flanco_m = medio_periodo && (sck_q == cpol_q);
    wire muestrea_m = cpha_q ? ~primer_flanco_m : primer_flanco_m;

    // ------------------------------------------------------- lado esclavo
    // El esclavo no tiene reloj: mira los flancos de SCK, y sólo con SS bajo.
    wire esclavo = spe_q & ~mstr_q;
    wire sck_rise = (sck_s[2:1] == 2'b01);
    wire sck_fall = (sck_s[2:1] == 2'b10);
    wire flanco_e = esclavo && ss_bajo && (sck_rise | sck_fall);
    // El primer flanco de un bit es el que saca al reloj del reposo.
    wire primer_flanco_e = cpol_q ? sck_fall : sck_rise;
    wire muestrea_e = flanco_e && (cpha_q ? ~primer_flanco_e : primer_flanco_e);
    wire desplaza_e = flanco_e && (cpha_q ?  primer_flanco_e : ~primer_flanco_e);

    // Durante el medio periodo de cierre no se muestrea ni se desplaza: ese
    // flanco sólo devuelve el reloj al reposo.
    wire muestrea = !cerrando_q &&
                    (maestro ? (medio_periodo && muestrea_m) : muestrea_e);
    wire desplaza = !cerrando_q &&
                    (maestro ? (medio_periodo && !muestrea_m) : desplaza_e);

    // El bit que entra y el que sale. DORD decide por qué punta se desplaza:
    // con DORD=0 sale primero el bit 7 y con DORD=1 el bit 0.
    wire bit_in  = maestro ? miso_pin : mosi_s[2];
    wire       tx_msb  = dord_q ? tx_q[0] : tx_q[7];
    wire [7:0] tx_next = dord_q ? {1'b0, tx_q[7:1]} : {tx_q[6:0], 1'b0};
    wire [7:0] rx_next = dord_q ? {bit_in, rx_q[7:1]} : {rx_q[6:0], bit_in};

    // Un byte se acaba cuando se ha muestreado el octavo bit.
    wire fin = muestrea && (bitcnt_q == 3'd7);

    // ------------------------------- colisión de maestros: SS tira hacia abajo
    // Sólo cuenta si SS está como ENTRADA. Si el programa lo puso como salida,
    // es él quien lo conduce —para seleccionar a su esclavo— y no hay nada que
    // detectar.
    wire colision_maestro = maestro && ss_bajo && !ss_es_salida;

    // ---------------------------------------------------------------- estado
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            spie_q <= 1'b0;  spe_q  <= 1'b0;  dord_q <= 1'b0;
            mstr_q <= 1'b0;  cpol_q <= 1'b0;  cpha_q <= 1'b0;
            spr_q  <= 2'b00; spi2x_q <= 1'b0;
            spif_q <= 1'b0;  wcol_q <= 1'b0;
            tx_q <= 8'h00; rx_q <= 8'h00; out_q <= 1'b0; rxbuf_q <= 8'h00;
            bitcnt_q <= 3'd0; busy_q <= 1'b0; cerrando_q <= 1'b0;
            div_q <= 7'd0;  sck_q <= 1'b0;
            spsr_leido <= 1'b0;
        end else if (ce) begin
            // ---------------- escrituras de control ----------------
            if (io_we && hit_spcr) begin
                spie_q <= io_wdata[7];
                spe_q  <= io_wdata[6];
                dord_q <= io_wdata[5];
                mstr_q <= io_wdata[4];
                cpol_q <= io_wdata[3];
                cpha_q <= io_wdata[2];
                spr_q  <= io_wdata[1:0];
                // Cambiar el reposo del reloj con el SPI parado mueve el pin.
                if (!busy_q) sck_q <= io_wdata[3];
            end
            // De SPSR sólo SPI2X es escribible; SPIF y WCOL son de sólo lectura
            // y se limpian con la secuencia, nunca escribiéndolos.
            if (io_we && hit_spsr) spi2x_q <= io_wdata[0];

            // ---------------- la secuencia de limpieza ----------------
            // Leer SPSR con algo puesto arma el gatillo; el siguiente acceso a
            // SPDR limpia. Leer SPSR sin nada puesto no arma nada.
            if (rd_spsr && (spif_q || wcol_q)) spsr_leido <= 1'b1;
            else if (acc_spdr)                 spsr_leido <= 1'b0;

            if (spsr_leido && acc_spdr) begin
                spif_q <= 1'b0;
                wcol_q <= 1'b0;
            end
            // El reconocimiento del vector también limpia SPIF, como en todos
            // los demás periféricos.
            if (ack_spi) spif_q <= 1'b0;

            // ---------------- escribir SPDR ----------------
            if (wr_spdr) begin
                if (busy_q) begin
                    // COLISION: no se carga nada y la transferencia sigue.
                    wcol_q <= 1'b1;
                end else begin
                    // LA CARGA, con la asimetría de CPHA. Con CPHA=0 el primer
                    // bit tiene que estar en el pin antes del primer flanco, así
                    // que se presenta ya y el registro guarda el resto
                    // desplazado; con CPHA=1 el pin no se toca hasta el primer
                    // flanco.
                    if (cpha_q) begin
                        tx_q  <= io_wdata;
                    end else begin
                        out_q <= dord_q ? io_wdata[0] : io_wdata[7];
                        tx_q  <= dord_q ? {1'b0, io_wdata[7:1]}
                                        : {io_wdata[6:0], 1'b0};
                    end
                    rx_q     <= 8'h00;
                    bitcnt_q <= 3'd0;
                    if (maestro) begin
                        busy_q     <= 1'b1;
                        cerrando_q <= 1'b0;
                        div_q      <= 7'd0;
                        sck_q      <= cpol_q;
                    end
                end
            end

            // ---------------- el reloj del maestro ----------------
            if (maestro && busy_q) begin
                if (div_q == div_top) begin
                    div_q <= 7'd0;
                    sck_q <= ~sck_q;
                end else begin
                    div_q <= div_q + 7'd1;
                end
            end else if (!busy_q) begin
                div_q <= 7'd0;
                sck_q <= cpol_q;
            end

            // ---------------- muestreo y desplazamiento ----------------
            // Cada uno en SU flanco. El de muestreo mete el bit que llega y
            // cuenta; el de desplazamiento presenta el siguiente en el pin.
            if (muestrea) begin
                rx_q     <= rx_next;
                bitcnt_q <= bitcnt_q + 3'd1;
            end
            if (desplaza) begin
                out_q <= tx_msb;
                tx_q  <= tx_next;
            end

            // ---------------- fin de byte ----------------
            // El DATO sale aquí, en cuanto se muestrea el octavo bit. LA
            // BANDERA NO: `SPIF` se pone cuando la transferencia ha terminado
            // DE VERDAD, es decir cuando el reloj ha vuelto al reposo.
            //
            // La diferencia se ve con CPHA=0 y un divisor lento. Levantar la
            // bandera medio periodo antes hace que el modismo de siempre
            //
            //     while (!(SPSR & (1<<SPIF)));  SPDR = siguiente;
            //
            // caiga dentro de la transferencia todavía en marcha y se lleve un
            // WCOL, perdiendo el byte en silencio. Es exactamente el fallo que
            // encontró el banco.
            if (fin) begin
                rxbuf_q <= rx_next;
                // OJO CON EL VALOR QUE SE MIRA: `sck_q` es el de ANTES de
                // conmutar en este mismo flanco, y lo que decide si falta medio
                // periodo es el de DESPUÉS. Con CPHA=1 el octavo bit se
                // muestrea en el flanco que ya devuelve el reloj al reposo, y
                // mirar el valor viejo añadía medio periodo de más — un noveno
                // flanco que un esclavo de verdad cuenta como bit.
                if (!maestro || sck_q != cpol_q) begin
                    busy_q <= 1'b0;
                    spif_q <= 1'b1;
                end else begin
                    cerrando_q <= 1'b1;
                end
            end
            if (cerrando_q && medio_periodo) begin
                busy_q     <= 1'b0;
                cerrando_q <= 1'b0;
                spif_q     <= 1'b1;
            end

            // ---------------- el esclavo pierde la selección ----------------
            // Si SS sube a mitad de byte, el esclavo abandona y vuelve a
            // empezar por el bit 7. La hoja de datos lo dice y es lo que
            // permite recuperarse de una trama cortada.
            if (esclavo && !ss_bajo) bitcnt_q <= 3'd0;

            // ---------------- colisión de maestros ----------------
            // Gana a todo lo demás: se deja de ser maestro en el acto.
            if (colision_maestro) begin
                mstr_q     <= 1'b0;
                spif_q     <= 1'b1;
                busy_q     <= 1'b0;
                cerrando_q <= 1'b0;
            end

            // Apagar el SPI deja el estado quieto, sin transferencia a medias.
            if (io_we && hit_spcr && !io_wdata[6]) begin
                busy_q     <= 1'b0;
                cerrando_q <= 1'b0;
                bitcnt_q   <= 3'd0;
            end
        end
    end

    // ------------------------------------------------------------- lectura
    // Leer SPDR da el BÚFER, no el registro de desplazamiento: por eso se puede
    // leer el byte anterior mientras entra el siguiente.
    assign io_rdata = hit_spcr ? {spie_q, spe_q, dord_q, mstr_q,
                                  cpol_q, cpha_q, spr_q}       :
                      hit_spsr ? {spif_q, wcol_q, 5'b00000, spi2x_q} :
                      hit_spdr ? rxbuf_q                       : 8'h00;

    // --------------------------------------------------------------- pines
    // Tabla 18-1. «Usuario» significa que el programa sigue poniendo DDRx, así
    // que ahí NO se anula la dirección; lo que la tabla marca como entrada sí
    // se fuerza.
    assign sck_out  = sck_q;
    assign sck_oe   = maestro;              // valor: sólo manda si es maestro
    assign mosi_out = out_q;
    assign mosi_oe  = maestro;
    assign miso_out = out_q;
    assign miso_oe  = esclavo && ss_bajo;   // sólo conduce si está seleccionado
    assign ss_oe_force = esclavo;           // forzado a entrada

    assign irq_spi = spif_q & spie_q;

endmodule

`default_nettype wire
