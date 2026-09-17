// AxiomaCore-328 - USART0: asíncrono, síncrono y multiprocesador
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El periférico del `Serial.println`. Y el primero del proyecto con EFECTO
// LATERAL DE LECTURA: leer UDR0 saca un byte del búfer de recepción y, si no
// queda ninguno, baja RXC. Es la trampa nº 11. Hasta ahora ningún periférico
// usaba `io_re` —ni el GPIO ni el Timer0 lo necesitan y los dos lo declaraban
// sin usar a propósito—; aquí `io_re` es parte de la función.
//
//   UCSR0A  dato 0xC0   RXC0 TXC0 UDRE0 FE0 DOR0 UPE0 U2X0 MPCM0
//   UCSR0B  dato 0xC1   RXCIE0 TXCIE0 UDRIE0 RXEN0 TXEN0 UCSZ02 RXB80 TXB80
//   UCSR0C  dato 0xC2   UMSEL01 UMSEL00 UPM01 UPM00 USBS0 UCSZ01 UCSZ00 UCPOL0
//   UBRR0L  dato 0xC4   divisor, byte bajo
//   UBRR0H  dato 0xC5   divisor, 4 bits altos
//   UDR0    dato 0xC6   DOS registros en una dirección: escribir carga el
//                       transmisor, leer saca del búfer de recepción
//
// EL DIVISOR. El generador da un pulso cada UBRR+1 ciclos, y cada bit dura 16
// de esos pulsos —8 con U2X—. De ahí la fórmula de la hoja de datos:
//
//     baudios = F_CPU / (16 · (UBRR+1))      y la mitad de divisor con U2X
//
// EL RECEPTOR MUESTREA TRES VECES Y VOTA. No basta con mirar el centro del bit:
// la hoja de datos especifica tres muestras en las posiciones 8, 9 y 10 de las
// 16, y gana la mayoría. Es lo que da tolerancia al ruido y a la desviación de
// reloj entre los dos extremos, y un receptor que mire una sola vez PARECE
// funcionar en simulación y falla con un cable real.
//
// EL BÚFER DE RECEPCIÓN TIENE DOS NIVELES. No es un detalle: con uno solo, un
// programa que tarde un byte en atender pierde datos que el chip real no
// pierde. Y FE y UPE VIAJAN CON SU TRAMA dentro del búfer —son del byte que se
// va a leer, no del último recibido—, que es la razón por la que la hoja de
// datos insiste en leer UCSR0A ANTES que UDR0.
//
// SIMAVR NO SIRVE DE ORÁCULO AQUÍ, y conviene saberlo antes de comparar nada.
// Su modelo no serializa: transporta bytes enteros por IRQs internas y aproxima
// el tiempo con `cycles_per_byte`. No hay bit de arranque, ni paridad, ni bits
// de parada, ni pin. Además su cuenta de tiempo de trama SUMA SIEMPRE un bit de
// paridad, esté activada o no. Así que el diferencial sólo puede comparar los
// registros que son almacenamiento —UCSR0B, UCSR0C, UBRR0L/H— y la forma de
// onda la certifica el banco propio con un receptor de verdad.
//
// EL MODO SÍNCRONO SALE CASI GRATIS, y eso no es casualidad: el motor de trama
// —arranque, datos, paridad, parada— es el mismo, y lo único que cambia es
// QUIÉN dice «avanza un bit». En asíncrono lo dice el generador de baudios con
// su sobremuestreo por dieciséis; en síncrono, los flancos de XCK, uno por bit.
// Con `osr` puesto a uno el contador de sobremuestreo se agota en el mismo
// pulso y la máquina de estados no se entera de nada.
//
//   XCK es PD4, y la DIRECCIÓN LA PONE EL PROGRAMA: `DDR_XCK0` es lo que elige
//   entre maestro —reloj interno, f_XCK = f_CPU/(2·(UBRR+1))— y esclavo —reloj
//   externo—. Por eso este módulo anula el VALOR del pin y nunca su dirección.
//
//   UCPOL es, visto desde dentro, UNA INVERSIÓN DEL PIN. Dentro se trabaja
//   siempre con la misma convención —se muestrea en la subida y se cambia el
//   dato en la bajada— y el pin lleva ese reloj pasado por un XOR. Sale
//   exactamente lo que dice la hoja de datos en los dos casos, sin duplicar
//   media máquina de estados.
//
// MPCM: VARIOS ESCLAVOS EN EL MISMO CABLE. Con MPCM puesto, las tramas que no
// son de dirección se tiran EN SILENCIO —ni RXC, ni búfer, ni DOR—, de modo que
// el que no ha sido llamado no se entera de nada hasta la siguiente dirección.
// Qué bit dice si la trama es una dirección depende del tamaño: con nueve bits
// de datos sobra uno para marcarla, y con cinco a ocho se usa el PRIMER BIT DE
// PARADA. Por eso el manual exige dos bits de parada al usar MPCM con tramas
// cortas: el primero deja de ser parada.
//
// FUERA DE ALCANCE, y declarado: el modo SPI MAESTRO (UMSEL = 11), que es otro
// periférico con los mismos registros. Sus bits se almacenan y se leen de
// vuelta. Está en el registro de deuda técnica como D12.

`default_nettype none

module axioma_usart (
    input  wire       clk,
    input  wire       rst_n,

    // ---- interfaz común de periférico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- pines ----
    input  wire       rxd,
    output wire       txd,
    output wire       txd_en,      // TXEN: el transmisor se adueña del pin
    output wire       rx_en,       // RXEN: el receptor fuerza su pin a ENTRADA

    // ---- XCK, el reloj del modo sincrono (PD4) ----
    // LA DIRECCION LA PONE EL PROGRAMA, no este modulo: la hoja de datos dice
    // que `DDR_XCKn` es lo que decide si el reloj es interno -maestro- o
    // externo -esclavo-. Por eso entra `xck_es_salida`, que es DDRD4 ya
    // resuelto, igual que el SPI recibe `ss_es_salida`. Lo que si anula el
    // periferico es el VALOR del pin cuando es maestro.
    input  wire       xck_pin,
    input  wire       xck_es_salida,
    output wire       xck_out,
    output wire       xck_ovr,

    // ---- interrupciones ----
    output wire       irq_rxc,     // vector 18
    output wire       irq_udre,    // vector 19
    output wire       irq_txc,     // vector 20
    input  wire       ack_txc
);

    localparam [7:0] A_UCSR0A = 8'hA0;   // dato 0xC0
    localparam [7:0] A_UCSR0B = 8'hA1;
    localparam [7:0] A_UCSR0C = 8'hA2;
    localparam [7:0] A_UBRR0L = 8'hA4;
    localparam [7:0] A_UBRR0H = 8'hA5;
    localparam [7:0] A_UDR0   = 8'hA6;

    wire hit_a    = (io_addr == A_UCSR0A);
    wire hit_b    = (io_addr == A_UCSR0B);
    wire hit_c    = (io_addr == A_UCSR0C);
    wire hit_brrl = (io_addr == A_UBRR0L);
    wire hit_brrh = (io_addr == A_UBRR0H);
    wire hit_udr  = (io_addr == A_UDR0);

    assign io_sel = hit_a | hit_b | hit_c | hit_brrl | hit_brrh | hit_udr;

    // ---------------------------------------------------------- registros
    reg        u2x, mpcm;
    reg        rxcie, txcie, udrie, rxen, txen, ucsz2, rxb8_w, txb8;
    reg [1:0]  umsel, upm;
    reg        usbs, ucpol;
    reg [1:0]  ucsz10;
    reg [11:0] ubrr;

    // Número de bits de datos. La codificación 100..110 está reservada; la hoja
    // de datos no la define, así que se trata como 8, que es lo que hace el
    // modelo de simavr y lo único que no sorprende.
    wire [3:0] databits = ({ucsz2, ucsz10} == 3'b000) ? 4'd5 :
                          ({ucsz2, ucsz10} == 3'b001) ? 4'd6 :
                          ({ucsz2, ucsz10} == 3'b010) ? 4'd7 :
                          ({ucsz2, ucsz10} == 3'b111) ? 4'd9 : 4'd8;
    wire       par_en  = upm[1];          // 10 = par, 11 = impar
    wire       par_odd = upm[0];
    wire       dos_stop = usbs;

    // --------------------------------------------------- generador de baudios
    // Un pulso cada UBRR+1 ciclos. Cada bit dura 16 pulsos, u 8 con U2X.
    reg [11:0] brg;
    wire       brg_tick = (brg == 12'd0);

    // ESCRIBIR UBRR0L RECARGA EL PRESCALER EN EL ACTO. Lo dice la hoja de
    // datos —«writing UBRRnL will trigger an immediate update of the baud rate
    // prescaler»— y no es un detalle: sin esto, bajar el divisor deja al
    // periférico sin pulsos durante lo que quedaba de la cuenta ANTERIOR, que
    // puede ser miles de ciclos. Un receptor recién configurado se perdería los
    // primeros bits de la primera trama, que es exactamente lo que pasaba.
    //
    // Por eso la hoja de datos manda escribir UBRR0H ANTES que UBRR0L: el byte
    // alto se prepara y el bajo cierra la operación.
    wire carga_brr = io_we && hit_brrl;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          brg <= 12'd0;
        else if (carga_brr)  brg <= {ubrr[11:8], io_wdata};
        else if (brg_tick)   brg <= ubrr;
        else                 brg <= brg - 12'd1;
    end

    // ------------------------------------------------- sincrono contra asincrono
    // EL MOTOR DE TRAMA ES EL MISMO, y eso es lo que hace barato el modo
    // sincrono: bit de arranque, datos, paridad y parada se cuentan igual. Lo
    // unico que cambia es QUIEN dice «avanza un bit». En asincrono lo dice el
    // generador de baudios con su sobremuestreo de 16 —u 8 con U2X—; en
    // sincrono lo dicen los flancos de XCK, uno por bit.
    //
    // Con `osr` a uno, el contador de sobremuestreo del transmisor se agota en
    // el mismo pulso y cada tick avanza un bit, sin tocar una linea de la
    // maquina de estados.
    //
    // UMSEL: 00 asincrono · 01 SINCRONO · 10 reservado · 11 SPI maestro, que no
    // esta implementado y tiene su entrada en el registro de deuda.
    wire       sincrono = (umsel == 2'b01);
    wire [4:0] osr = sincrono ? 5'd1 : (u2x ? 5'd8 : 5'd16);   // muestras por bit

    // ------------------------------------------------------------ XCK
    // UCPOL ES UNA INVERSION DEL PIN, y verlo asi ahorra media maquina de
    // estados. Dentro se trabaja siempre con la misma convencion —se MUESTREA
    // en el flanco de subida y se CAMBIA el dato en el de bajada— y el pin
    // lleva ese reloj pasado por un XOR con UCPOL. Sale exactamente lo que dice
    // la hoja de datos en los dos casos:
    //
    //   UCPOL=0  pin = reloj interno    -> muestrea en subida, cambia en bajada
    //   UCPOL=1  pin = reloj invertido  -> muestrea en bajada, cambia en subida
    //
    // El maestro usa SU reloj, sin leerlo de vuelta del pin: en el chip el
    // registro de desplazamiento cuelga del reloj interno. El esclavo si lee el
    // pin, y con dos etapas de sincronizacion porque es asincrono de verdad.
    wire       xck_maestro = sincrono & xck_es_salida;

    reg        xck_gen;
    reg [1:0]  xck_sync;
    reg        xck_i_q;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xck_gen <= 1'b0;  xck_sync <= 2'b00;  xck_i_q <= 1'b0;
        end else begin
            xck_sync <= {xck_sync[0], xck_pin};
            // f_XCK = f_CPU / (2*(UBRR+1)): el generador ya da un pulso cada
            // UBRR+1 ciclos, asi que basta con conmutar en cada uno.
            if (xck_maestro && brg_tick) xck_gen <= ~xck_gen;
            xck_i_q <= xck_i;
        end
    end

    wire xck_i    = xck_maestro ? xck_gen : (xck_sync[1] ^ ucpol);
    wire xck_sube =  xck_i & ~xck_i_q;     // muestrear
    wire xck_baja = ~xck_i &  xck_i_q;     // cambiar el dato

    assign xck_out = xck_gen ^ ucpol;
    assign xck_ovr = xck_maestro;

    wire tx_tick = sincrono ? xck_baja : brg_tick;
    wire rx_tick = sincrono ? xck_sube : brg_tick;

    // ------------------------------------------------------- transmisor
    // Un registro de desplazamiento y UN búfer, como el chip: UDRE dice que el
    // búfer está libre, TXC que la trama ha salido entera y no queda nada.
    reg [8:0]  tx_buf;
    reg        tx_buf_full;
    reg [8:0]  tx_sh;
    reg [3:0]  tx_bit;        // qué bit de la trama se está sacando
    reg [4:0]  tx_cnt;        // muestras que faltan del bit actual
    reg        tx_activo;
    reg        tx_par;        // paridad acumulada
    reg        txd_q;
    reg        txc_q;

    // Estados de la trama, contados: 0 = arranque, 1..databits = datos,
    // luego paridad si la hay, luego uno o dos de parada.
    wire [3:0] tx_bit_par  = 4'd1 + databits;                     // índice de la paridad
    wire [3:0] tx_bit_stop = tx_bit_par + (par_en ? 4'd1 : 4'd0); // primer bit de parada
    wire [3:0] tx_bit_fin  = tx_bit_stop + (dos_stop ? 4'd1 : 4'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tx_buf <= 9'd0;  tx_buf_full <= 1'b0;  tx_sh <= 9'd0;
            tx_bit <= 4'd0;  tx_cnt <= 5'd0;       tx_activo <= 1'b0;
            tx_par <= 1'b0;  txd_q <= 1'b1;        txc_q <= 1'b0;
        end else begin
            // Escribir UDR0 carga el búfer. Si el transmisor está parado, la
            // trama arranca en el siguiente pulso del generador.
            if (io_we && hit_udr && txen) begin
                tx_buf      <= {txb8, io_wdata};
                tx_buf_full <= 1'b1;
            end

            // TXC: la pone el hardware al terminar la trama sin nada pendiente,
            // y se limpia escribiendo un uno en ella o al atender su vector.
            if (io_we && hit_a && io_wdata[6]) txc_q <= 1'b0;
            if (ack_txc)                       txc_q <= 1'b0;

            if (!txen) begin
                tx_activo <= 1'b0;
                txd_q     <= 1'b1;
            end else if (tx_tick) begin
                if (!tx_activo) begin
                    if (tx_buf_full) begin
                        tx_sh       <= tx_buf;
                        tx_buf_full <= 1'b0;
                        tx_activo   <= 1'b1;
                        tx_bit      <= 4'd0;
                        tx_cnt      <= osr - 5'd1;
                        tx_par      <= par_odd;      // impar arranca en 1
                        txd_q       <= 1'b0;         // bit de arranque
                    end
                end else if (tx_cnt != 5'd0) begin
                    tx_cnt <= tx_cnt - 5'd1;
                end else begin
                    tx_cnt <= osr - 5'd1;
                    if (tx_bit == tx_bit_fin) begin
                        // Se acabó la trama. Si hay otro byte esperando, encadena
                        // sin soltar la línea; si no, TXC.
                        if (tx_buf_full) begin
                            tx_sh       <= tx_buf;
                            tx_buf_full <= 1'b0;
                            tx_bit      <= 4'd0;
                            tx_par      <= par_odd;
                            txd_q       <= 1'b0;
                        end else begin
                            tx_activo <= 1'b0;
                            txc_q     <= 1'b1;
                            txd_q     <= 1'b1;
                        end
                    end else begin
                        tx_bit <= tx_bit + 4'd1;
                        if (tx_bit + 4'd1 <= databits) begin
                            // Bit de datos, el menos significativo primero.
                            txd_q  <= tx_sh[0];
                            tx_par <= tx_par ^ tx_sh[0];
                            tx_sh  <= {1'b0, tx_sh[8:1]};
                        end else if (par_en && (tx_bit + 4'd1 == tx_bit_par)) begin
                            txd_q <= tx_par;
                        end else begin
                            txd_q <= 1'b1;           // parada
                        end
                    end
                end
            end
        end
    end

    assign txd    = txd_q;
    assign txd_en = txen;
    // La tabla 14-9 de anulaciones del puerto D: con RXEN0 puesto, PD0 es
    // ENTRADA pase lo que pase en DDRD0, y su pull-up sigue saliendo de PORTD0.
    assign rx_en  = rxen;

    // --------------------------------------------------------- receptor
    // El pin es asíncrono de verdad: dos biestables de sincronización antes de
    // mirarlo, como en el pin T0 del Timer0.
    reg [2:0]  rx_sync;
    wire       rxd_s = rx_sync[2];

    reg        rx_activo;
    reg [4:0]  rx_pos;        // posición dentro del bit, de 0 a osr-1
    reg [3:0]  rx_bit;
    reg [8:0]  rx_sh;
    reg [1:0]  rx_vota;       // las DOS primeras muestras; la tercera es la
                              // del ciclo en el que se decide
    reg        rx_par;
    reg        rx_upe;

    // LA VOTACIÓN POR MAYORÍA, tal como la define la hoja de datos: se toman
    // TRES muestras en las posiciones 8, 9 y 10 de las 16 —4, 5 y 6 de las 8
    // con U2X— y gana la que se repite. El contador va hacia ARRIBA, como en la
    // figura del manual, precisamente para que las posiciones se lean tal cual.
    //
    // Que sean tres no es adorno: con una sola muestra el receptor PARECE
    // funcionar en simulación, donde los bordes son perfectos, y falla con un
    // cable real en cuanto hay ruido o los dos extremos derivan.
    // Las dos muestras ya registradas más la de este mismo ciclo. Se escribe
    // así, y no leyendo `rx_vota` entero, porque la tercera muestra entra en el
    // flanco en el que se decide: mirar el registro daría una muestra vieja.
    wire       rx_voto_ahora = (rx_vota[0] & rx_vota[1]) | (rx_vota[0] & rxd_s)
                             | (rx_vota[1] & rxd_s);
    // EN SINCRONO NO HAY NADA QUE VOTAR: el reloj dice cuando vale el dato y
    // se toma UNA muestra por flanco, que es lo que hace el chip. La votacion
    // es de la recuperacion de reloj del modo asincrono, no del receptor.
    wire [4:0] pos_1a  = sincrono ? 5'd0 : (u2x ? 5'd3 : 5'd7);
    wire [4:0] pos_3a  = sincrono ? 5'd0 : (u2x ? 5'd5 : 5'd9);
    wire [4:0] pos_fin = osr - 5'd1;

    // La muestra que se usa para decidir. En asincrono es el voto; en sincrono,
    // el pin. Una sola expresion para que el resto de la maquina no distinga.
    wire       rx_muestra = sincrono ? rxd_s : rx_voto_ahora;

    // Búfer de DOS niveles, con su FE y su UPE pegados a cada trama.
    reg [10:0] rx_fifo0, rx_fifo1;
    reg [1:0]  rx_n;
    reg        dor_q;

    wire       rx_lleno = (rx_n == 2'd2);
    wire       rx_vacio = (rx_n == 2'd0);

    // Sacar del búfer es un EFECTO LATERAL DE LECTURA, la trampa nº 11.
    wire       rx_pop = io_re && hit_udr && !rx_vacio;

    // El receptor sólo comprueba EL PRIMER bit de parada: lo dice la hoja de
    // datos, y por eso la trama termina en la rama por defecto sin contar el
    // segundo. Con dos bits de parada, el segundo es tiempo de línea en reposo
    // y el receptor ya está esperando el siguiente arranque.
    wire [3:0] rx_bit_par  = 4'd1 + databits;

    // MPCM: QUE BIT DICE SI LA TRAMA ES UNA DIRECCION. La hoja de datos usa dos
    // sitios distintos segun el tamaño de trama, y no es un capricho: con nueve
    // bits de datos sobra uno para marcarla, y con cinco a ocho no, asi que se
    // usa el PRIMER BIT DE PARADA. Por eso el manual exige dos bits de parada
    // cuando se usa MPCM con tramas cortas: el primero deja de ser parada.
    //
    // `rx_sh[8]` es el noveno bit de datos: el registro desplaza hacia la
    // derecha, asi que el ultimo que entra se queda arriba.
    wire       es_direccion = (databits == 4'd9) ? rx_sh[8] : rx_muestra;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            rx_sync   <= 3'b111;
            rx_activo <= 1'b0;  rx_pos <= 5'd0;  rx_bit <= 4'd0;
            rx_sh     <= 9'd0;  rx_vota <= 2'b11;
            rx_par    <= 1'b0;  rx_upe <= 1'b0;
            rx_fifo0  <= 11'd0; rx_fifo1 <= 11'd0;
            rx_n      <= 2'd0;  dor_q <= 1'b0;
        end else begin
            rx_sync <= {rx_sync[1:0], rxd};

            if (rx_pop) begin
                rx_fifo0 <= rx_fifo1;
                rx_n     <= rx_n - 2'd1;
                // DOR se levanta al desbordar y se queda hasta que el búfer
                // deja de estar lleno.
                if (rx_n == 2'd2) dor_q <= 1'b0;
            end

            if (!rxen) begin
                rx_activo <= 1'b0;
                rx_n      <= 2'd0;
                dor_q     <= 1'b0;
            end else if (rx_tick) begin
                if (!rx_activo) begin
                    // Flanco de bajada en reposo: posible bit de arranque. La
                    // cuenta de posición arranca aquí, en la muestra 0.
                    if (!rxd_s) begin
                        rx_activo <= 1'b1;
                        // EN SINCRONO EL FLANCO QUE LO DETECTA ES SU MUESTRA.
                        // En asincrono no: ahi la busqueda va a 16 pulsos por
                        // bit y el arranque se confirma despues, en su centro.
                        // Sin esta distincion la trama sincrona gastaria un
                        // periodo de XCK de mas y llegaria desplazada un bit.
                        rx_bit    <= sincrono ? 4'd1 : 4'd0;
                        rx_pos    <= 5'd0;
                        rx_vota   <= 2'b11;
                        rx_par    <= par_odd;
                        rx_upe    <= 1'b0;
                    end
                end else begin
                    // La posición avanza siempre; al llegar al final del bit da
                    // la vuelta y empieza la ventana del siguiente.
                    rx_pos <= (rx_pos == pos_fin) ? 5'd0 : (rx_pos + 5'd1);

                    // Las TRES muestras.
                    if (rx_pos >= pos_1a && rx_pos <= pos_3a)
                        rx_vota <= {rx_vota[0], rxd_s};

                    if (rx_pos == pos_3a) begin
                    // La decisión se toma con la tercera muestra ya dentro: el
                    // valor que entra en este mismo flanco es el que cierra el
                    // voto, así que se mira junto con las dos anteriores.
                    if (rx_bit == 4'd0) begin
                        // Arranque. Si el centro no es cero, era ruido.
                        if (rx_muestra) rx_activo <= 1'b0;
                        else            rx_bit    <= 4'd1;
                    end else if (rx_bit <= databits) begin
                        rx_sh  <= {rx_muestra, rx_sh[8:1]};
                        rx_par <= rx_par ^ rx_muestra;
                        rx_bit <= rx_bit + 4'd1;
                    end else if (par_en && (rx_bit == rx_bit_par)) begin
                        rx_upe <= (rx_muestra != rx_par);
                        rx_bit <= rx_bit + 4'd1;
                    end else begin
                        // Bit de parada. Un cero aquí es error de trama, y el
                        // byte se guarda igual: la hoja de datos dice que FE
                        // viaja CON la trama.
                        rx_activo <= 1'b0;
                        if (mpcm && !es_direccion) begin
                            // MPCM: LAS TRAMAS DE DATOS SE TIRAN EN SILENCIO.
                            // Ni RXC, ni bufer, ni DOR. Es lo que permite que
                            // varios esclavos cuelguen del mismo cable y solo
                            // el llamado escuche: los demas siguen con MPCM
                            // puesto y no se enteran de nada hasta la siguiente
                            // trama de direccion.
                            rx_activo <= 1'b0;
                        end else if (rx_lleno) begin
                            dor_q <= 1'b1;           // se pierde la nueva
                        end else begin
                            // El desplazamiento deja el dato alineado arriba
                            // cuando son menos de 9 bits.
                            if (rx_n == 2'd0)
                                rx_fifo0 <= {!rx_muestra, rx_upe,
                                             rx_sh >> (4'd9 - databits)};
                            else
                                rx_fifo1 <= {!rx_muestra, rx_upe,
                                             rx_sh >> (4'd9 - databits)};
                            rx_n <= rx_n + 2'd1;
                        end
                    end
                    end
                end
            end
        end
    end

    // ------------------------------------------------------------- lectura
    wire [8:0] rx_dato = rx_fifo0[8:0];
    wire       fe_out  = rx_vacio ? 1'b0 : rx_fifo0[10];
    wire       upe_out = rx_vacio ? 1'b0 : rx_fifo0[9];

    wire [7:0] ucsr_a = {!rx_vacio, txc_q, !tx_buf_full, fe_out, dor_q,
                         upe_out, u2x, mpcm};
    wire [7:0] ucsr_b = {rxcie, txcie, udrie, rxen, txen, ucsz2,
                         rx_dato[8], txb8};
    wire [7:0] ucsr_c = {umsel, upm, usbs, ucsz10, ucpol};

    // UDR0 son DOS registros en la misma dirección: lo que se lee es el búfer
    // de recepción, nunca lo que se escribió para transmitir.
    assign io_rdata = hit_a    ? ucsr_a          :
                      hit_b    ? ucsr_b          :
                      hit_c    ? ucsr_c          :
                      hit_brrl ? ubrr[7:0]       :
                      hit_brrh ? {4'b0000, ubrr[11:8]} :
                      hit_udr  ? rx_dato[7:0]    : 8'h00;

    // El bit 8 recibido se lee en RXB8, dentro de UCSR0B.
    wire unused_rxb8w = &{1'b0, rxb8_w};

    // ------------------------------------------------------------ escritura
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            u2x <= 1'b0;  mpcm <= 1'b0;
            rxcie <= 1'b0; txcie <= 1'b0; udrie <= 1'b0;
            rxen <= 1'b0;  txen <= 1'b0;  ucsz2 <= 1'b0;
            rxb8_w <= 1'b0; txb8 <= 1'b0;
            umsel <= 2'b00; upm <= 2'b00; usbs <= 1'b0;
            ucsz10 <= 2'b11;              // 8 bits al reset, como el chip
            ucpol <= 1'b0; ubrr <= 12'd0;
        end else if (io_we) begin
            if (hit_a) begin
                // RXC, UDRE, FE, DOR y UPE son de sólo lectura; TXC se limpia
                // escribiendo un uno y se trata en el bloque del transmisor.
                u2x  <= io_wdata[1];
                mpcm <= io_wdata[0];
            end
            if (hit_b) begin
                rxcie  <= io_wdata[7];  txcie <= io_wdata[6];
                udrie  <= io_wdata[5];  rxen  <= io_wdata[4];
                txen   <= io_wdata[3];  ucsz2 <= io_wdata[2];
                rxb8_w <= io_wdata[1];  txb8  <= io_wdata[0];
            end
            if (hit_c) begin
                umsel  <= io_wdata[7:6]; upm <= io_wdata[5:4];
                usbs   <= io_wdata[3];   ucsz10 <= io_wdata[2:1];
                ucpol  <= io_wdata[0];
            end
            if (hit_brrl) ubrr[7:0]  <= io_wdata;
            if (hit_brrh) ubrr[11:8] <= io_wdata[3:0];
        end
    end

    // De UMSEL sólo se usa el bit bajo: 01 es el modo síncrono. El 11 -SPI
    // maestro- no está implementado y tiene su entrada en el registro de deuda.
    wire unused_modos = &{1'b0, umsel[1]};

    assign irq_rxc  = (!rx_vacio)   & rxcie;
    assign irq_udre = (!tx_buf_full) & udrie;
    assign irq_txc  = txc_q         & txcie;

endmodule

`default_nettype wire
