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
// MSPIM: LA USART COMO MAESTRO SPI (UMSEL = 11). Es el mismo motor otra vez,
// con la trama más corta que se puede escribir —ocho bits de datos y nada
// más— y tres diferencias que sí son de fondo:
//
//   1. NO HAY BIT DE ARRANQUE, así que el reloj es lo ÚNICO que delimita la
//      trama. De ahí sale todo lo demás: el receptor no puede buscar un flanco
//      de bajada, tiene que arrancar con el transmisor; y la trama no puede
//      terminar «cuando toque el bit de parada», tiene que terminar en el
//      OCTAVO FLANCO DE SALIDA, que es el único instante que existe con las dos
//      fases y deja el pin en su nivel de reposo.
//   2. XCK SÓLO CORRE MIENTRAS HAY TRAMA. Un maestro SPI no puede dejar el
//      reloj suelto entre bytes: el esclavo cuenta flancos, y un pulso de más
//      lo descoloca para siempre. En el modo síncrono es al revés —ahí el
//      reloj corre libre—, y por eso son dos cosas distintas y no un parámetro.
//   3. UDORD PERMITE EL BIT MÁS SIGNIFICATIVO PRIMERO, que es lo que hace
//      casi todo el mundo en SPI. El registro de desplazamiento sigue siendo
//      el mismo, que saca el bit 0 primero: lo que se hace es DAR LA VUELTA AL
//      BYTE al cargarlo y al guardarlo. Duplicar el desplazador para leerlo al
//      revés habría sido la otra opción, y habría costado dos caminos que
//      mantener sincronizados.
//
// UCPHA dice en qué flanco del pulso se muestrea. Con UCPHA=0 el dato tiene que
// estar en el pin ANTES del primer flanco —por eso la trama pone su primer bit
// al arrancar, sin esperar a ningún reloj—; con UCPHA=1 el primer bit sale EN
// el primer flanco. Dentro no hay dos máquinas: cambia quién dice «avanza».
//
// Y EL DATO NO PASA POR EL SINCRONIZADOR DE TRES ETAPAS. En asíncrono ese
// sincronizador es parte de la recuperación de reloj, y en síncrono se lo puede
// permitir porque el bit de arranque viaja por el MISMO retardo y la trama se
// alinea sola. En MSPIM no hay bit de arranque que alinee nada: el reloj lo
// pone este mismo módulo, y tres ciclos de retraso a f_CPU/2 son bit y medio.
// Se muestrea con UNA etapa, que es la guarda de metaestabilidad y nada más.
//
// Los bits de UCSR0C son los MISMOS BIESTABLES con otro nombre, que es lo que
// hace el chip: bit 2 es UDORD donde había UCSZ01, bit 1 es UCPHA donde había
// UCSZ00, y bit 0 sigue siendo UCPOL. Los de UPM y USBS quedan reservados: se
// almacenan y se leen de vuelta, pero no los mira nadie.

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
    // UMSEL: 00 asincrono · 01 SINCRONO · 10 reservado · 11 SPI MAESTRO.
    // Los dos que cuelgan de XCK son el 01 y el 11, y eso es justo umsel[0].
    wire       sincrono  = (umsel == 2'b01);
    wire       mspim     = (umsel == 2'b11);
    wire       reloj_xck = umsel[0];
    wire [4:0] osr = reloj_xck ? 5'd1 : (u2x ? 5'd8 : 5'd16);  // muestras por bit

    // EN MSPIM LOS BITS DE UCSR0C SON LOS MISMOS BIESTABLES CON OTRO NOMBRE,
    // que es lo que hace el chip. No hay registro nuevo que almacenar.
    wire       udord = ucsz10[1];        // 0 = el mas significativo primero
    wire       ucpha = ucsz10[0];        // en que flanco del pulso se muestrea

    // LA FORMA DE LA TRAMA EN MSPIM ES FIJA: ocho bits de datos, sin arranque,
    // sin paridad y sin parada. No se toca la maquina: se le da otro numero.
    wire [3:0] databits_ef = mspim ? 4'd8 : databits;

    // Y LA PARIDAD, LA PARADA Y MPCM NO HACE FALTA APAGARLOS, aunque el programa
    // los deje puestos en UCSR0C —donde siguen siendo biestables de verdad, que
    // se leen de vuelta—. La razon es que en MSPIM la trama la delimita EL
    // RELOJ y no la cuenta de bits: el receptor cierra en su octava muestra y el
    // transmisor en el octavo flanco de salida, asi que las tres ramas que los
    // miran —paridad, bit de parada y descarte de MPCM— quedan DETRAS del final
    // de la trama y no se alcanzan nunca.
    //
    // No es una suposicion: estuvieron apagados con tres `wire` y el mutante que
    // los volvia a encender SOBREVIVIA a la regresion entera. Y no por falta de
    // banco —el de MSPIM corre con UPM=11, USBS=1 y MPCM=1 puestos a proposito—
    // sino porque era EQUIVALENTE. Tres lineas que no cambian nada son tres
    // lineas que alguien tendra que entender algun dia.

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
    // MSPIM ES MAESTRO Y NADA MAS -la hoja de datos no le da modo esclavo-, y
    // como en el sincrono es DDR_XCK0 quien enciende el maestro.
    wire       xck_maestro = reloj_xck & xck_es_salida;

    reg        xck_gen;
    reg [1:0]  xck_sync;
    reg        xck_i_q;
    reg [4:0]  m_tog;        // flancos generados en la trama de MSPIM, 0..16

    // EN MSPIM EL RELOJ SOLO CORRE MIENTRAS HAY TRAMA, y dura EXACTAMENTE ocho
    // pulsos. Contar los flancos generados -y no los detectados- es lo que
    // impide el pulso de mas: el detector de flanco va un ciclo por detras, y a
    // UBRR=0 ese ciclo es medio pulso.
    wire       xck_corre = sincrono | (mspim & tx_activo & (m_tog != 5'd16));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            xck_gen <= 1'b0;  xck_sync <= 2'b00;  xck_i_q <= 1'b0;
            m_tog   <= 5'd0;
        end else begin
            xck_sync <= {xck_sync[0], xck_pin};
            // f_XCK = f_CPU / (2*(UBRR+1)): el generador ya da un pulso cada
            // UBRR+1 ciclos, asi que basta con conmutar en cada uno.
            if (xck_maestro && brg_tick && xck_corre) begin
                xck_gen <= ~xck_gen;
                if (mspim) m_tog <= m_tog + 5'd1;
            end
            // ENTRE TRAMAS XCK SE QUEDA EN SU NIVEL DE REPOSO, que es UCPOL.
            // No basta con dejar de conmutarlo: el modo sincrono lo deja donde
            // le pilla, y al pasar a MSPIM ese uno colgado es un flanco de
            // bajada nada mas arrancar -la primera trama sale corrida un bit-.
            // La hoja de datos pide justo esto al hablar de la inicializacion
            // inmediata de XCK al encender el transmisor.
            if (mspim && !tx_activo) xck_gen <= 1'b0;
            if (m_arranca) m_tog <= 5'd0;
            xck_i_q <= xck_i;
        end
    end

    wire xck_i    = xck_maestro ? xck_gen : (xck_sync[1] ^ ucpol);
    wire xck_sube =  xck_i & ~xck_i_q;     // muestrear
    wire xck_baja = ~xck_i &  xck_i_q;     // cambiar el dato

    assign xck_out = xck_gen ^ ucpol;
    assign xck_ovr = xck_maestro;

    // QUIEN DICE «AVANZA UN BIT». UCPHA no duplica la maquina: intercambia los
    // dos flancos. Con UCPHA=0 se muestrea en el de entrada del pulso y se
    // cambia el dato en el de salida; con UCPHA=1, al reves.
    wire tx_tick = !reloj_xck ? brg_tick : ((mspim & ucpha) ? xck_sube : xck_baja);
    wire rx_tick = !reloj_xck ? brg_tick : ((mspim & ucpha) ? xck_baja : xck_sube);

    // LA TRAMA DE MSPIM TERMINA EN EL OCTAVO FLANCO DE SALIDA DEL PULSO, valga
    // lo que valga UCPHA: es el unico instante que existe en las dos fases con
    // los ocho bits ya movidos, y el que deja el pin en su nivel de reposo.
    wire m_fin = mspim & tx_activo & xck_baja & (m_tog == 5'd16);

    // Y ARRANCA AL ESCRIBIR UDR0, no en un flanco: el reloj no existe hasta que
    // hay trama, asi que esperar a un flanco seria esperar para siempre. Ademas
    // hace falta para UCPHA=0, que pide el primer bit en el pin ANTES del
    // primer flanco.
    // SIN `DDR_XCK0` NO ARRANCA NADA, y eso es deliberado: la hoja de datos
    // enciende el maestro con ese bit -«setting the XCKn port pin as output
    // enables master mode»-, y en MSPIM no hay otro modo. Si la trama arrancara
    // igual, el byte saldria del bufer -UDRE diria que hay sitio- y se quedaria
    // en el desplazador esperando un reloj que nadie va a generar: un byte
    // perdido en silencio. Asi se queda en el bufer, UDRE dice que no, y en
    // cuanto el programa ponga el DDR la trama sale.
    wire m_arranca = mspim & txen & xck_maestro & ~tx_activo & tx_buf_full;

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
    wire [3:0] tx_bit_par  = 4'd1 + databits_ef;                     // índice de la paridad
    wire [3:0] tx_bit_stop = tx_bit_par + (par_en ? 4'd1 : 4'd0); // primer bit de parada
    wire [3:0] tx_bit_fin  = tx_bit_stop + (dos_stop ? 4'd1 : 4'd0);

    // EL BYTE SE DA LA VUELTA AL CARGARLO, y con eso el desplazador de siempre
    // -que saca el bit 0 primero- emite el mas significativo primero. Es la
    // alternativa a tener dos desplazadores que mantener sincronizados.
    wire [7:0] tx_lsb = tx_buf[7:0];
    wire [7:0] tx_msb = {tx_lsb[0], tx_lsb[1], tx_lsb[2], tx_lsb[3],
                         tx_lsb[4], tx_lsb[5], tx_lsb[6], tx_lsb[7]};
    wire [8:0] tx_carga = mspim ? {1'b0, (udord ? tx_lsb : tx_msb)} : tx_buf;

    // Con UCPHA=0 el primer bit sale YA, sin esperar flanco; con UCPHA=1 sale
    // en el primero. De ahi que la carga difiera en una posicion.
    wire       m_ya      = mspim & ~ucpha;                 // adelanta el bit 1
    wire [8:0] tx_sh_ini = m_ya ? {1'b0, tx_carga[8:1]} : tx_carga;
    wire [3:0] tx_bit_ini = m_ya ? 4'd1 : 4'd0;
    wire       tx_pin_ini = m_ya ? tx_carga[0] : (mspim ? txd_q : 1'b0);

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
            end else if (m_arranca) begin
                // MSPIM: la trama arranca con la escritura, no con un flanco.
                tx_sh       <= tx_sh_ini;
                tx_buf_full <= 1'b0;
                tx_activo   <= 1'b1;
                tx_bit      <= tx_bit_ini;
                tx_cnt      <= osr - 5'd1;
                tx_par      <= 1'b0;
                txd_q       <= tx_pin_ini;
            end else if (m_fin) begin
                // Y termina en el octavo flanco de salida. Si hay otro byte
                // esperando, la siguiente trama arranca sola por `m_arranca`.
                tx_activo <= 1'b0;
                txc_q     <= ~tx_buf_full;
            end else if (tx_tick) begin
                if (!tx_activo) begin
                    if (tx_buf_full && !mspim) begin
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
                    if (mspim) begin
                        // En MSPIM no hay bit de parada que cierre: mientras la
                        // trama dure, cada flanco de cambio saca un bit mas, y
                        // el que cierra es `m_fin`.
                        if (tx_bit != tx_bit_fin) begin
                            tx_bit <= tx_bit + 4'd1;
                            txd_q  <= tx_sh[0];
                            tx_sh  <= {1'b0, tx_sh[8:1]};
                        end
                    end else if (tx_bit == tx_bit_fin) begin
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
                        if (tx_bit + 4'd1 <= databits_ef) begin
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
    wire [4:0] pos_1a  = reloj_xck ? 5'd0 : (u2x ? 5'd3 : 5'd7);
    wire [4:0] pos_3a  = reloj_xck ? 5'd0 : (u2x ? 5'd5 : 5'd9);
    wire [4:0] pos_fin = osr - 5'd1;

    // La muestra que se usa para decidir. En asincrono es el voto; en sincrono,
    // el pin. Una sola expresion para que el resto de la maquina no distinga.
    //
    // EN MSPIM SE MIRA UNA ETAPA ANTES, y no es un ajuste fino: en asincrono el
    // sincronizador de tres etapas es parte de la recuperacion de reloj, y en
    // sincrono se lo puede permitir porque el BIT DE ARRANQUE viaja por el
    // mismo retardo y la trama se alinea sola. En MSPIM no hay arranque que
    // alinee nada -el reloj lo pone este modulo- y tres ciclos a f_CPU/2 son
    // bit y medio. Queda una etapa, que es la guarda de metaestabilidad.
    wire       rx_muestra = mspim    ? rx_sync[0] :
                            sincrono ? rxd_s      : rx_voto_ahora;

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
    wire [3:0] rx_bit_par  = 4'd1 + databits_ef;

    // El desplazamiento deja el dato alineado arriba cuando son menos de nueve
    // bits. En MSPIM el ultimo bit entra EN ESTE MISMO FLANCO -no hay bit de
    // parada detras que de tiempo-, asi que hay que mirar el valor NUEVO.
    wire [8:0] rx_sh_nuevo = {rx_muestra, rx_sh[8:1]};
    wire [7:0] rx_m_lsb = rx_sh_nuevo[8:1];
    wire [7:0] rx_m_msb = {rx_m_lsb[0], rx_m_lsb[1], rx_m_lsb[2], rx_m_lsb[3],
                           rx_m_lsb[4], rx_m_lsb[5], rx_m_lsb[6], rx_m_lsb[7]};
    wire [8:0] rx_guarda = mspim ? {1'b0, (udord ? rx_m_lsb : rx_m_msb)}
                                 : (rx_sh >> (4'd9 - databits_ef));

    // MPCM: QUE BIT DICE SI LA TRAMA ES UNA DIRECCION. La hoja de datos usa dos
    // sitios distintos segun el tamaño de trama, y no es un capricho: con nueve
    // bits de datos sobra uno para marcarla, y con cinco a ocho no, asi que se
    // usa el PRIMER BIT DE PARADA. Por eso el manual exige dos bits de parada
    // cuando se usa MPCM con tramas cortas: el primero deja de ser parada.
    //
    // `rx_sh[8]` es el noveno bit de datos: el registro desplaza hacia la
    // derecha, asi que el ultimo que entra se queda arriba.
    wire       es_direccion = (databits_ef == 4'd9) ? rx_sh[8] : rx_muestra;

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
            end else if (m_arranca) begin
                // EN MSPIM EL RECEPTOR ARRANCA CON EL TRANSMISOR. No hay bit de
                // arranque que buscar: la trama la delimita el reloj, y el
                // primer flanco de muestreo ya trae el primer bit.
                rx_activo <= 1'b1;
                rx_bit    <= 4'd1;
                rx_pos    <= 5'd0;
                rx_vota   <= 2'b11;
                rx_par    <= 1'b0;
                rx_upe    <= 1'b0;
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
                    end else if (rx_bit <= databits_ef) begin
                        rx_sh  <= rx_sh_nuevo;
                        rx_par <= rx_par ^ rx_muestra;
                        rx_bit <= rx_bit + 4'd1;
                        if (mspim && rx_bit == databits_ef) begin
                            // LA ULTIMA MUESTRA CIERRA LA TRAMA, porque detras
                            // no hay nada: ni paridad, ni parada, ni otro
                            // flanco. Se guarda con el valor NUEVO del
                            // desplazador, que es el que trae este bit.
                            rx_activo <= 1'b0;
                            if (rx_lleno) dor_q <= 1'b1;
                            else begin
                                if (rx_n == 2'd0) rx_fifo0 <= {2'b00, rx_guarda};
                                else              rx_fifo1 <= {2'b00, rx_guarda};
                                rx_n <= rx_n + 2'd1;
                            end
                        end
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
                                rx_fifo0 <= {!rx_muestra, rx_upe, rx_guarda};
                            else
                                rx_fifo1 <= {!rx_muestra, rx_upe, rx_guarda};
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

    assign irq_rxc  = (!rx_vacio)   & rxcie;
    assign irq_udre = (!tx_buf_full) & udrie;
    assign irq_txc  = txc_q         & txcie;

endmodule

`default_nettype wire
