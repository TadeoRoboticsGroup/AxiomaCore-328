// AxiomaCore-328 - TWI (I2C): maestro, esclavo y arbitraje
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El bus del que cuelga media estanteria de sensores, y el que usa `Wire`.
// En el 328P son seis registros y DOS pines de colector abierto:
//
//   TWBR  0xB8   divisor del reloj de SCL
//   TWSR  0xB9   TWS7..TWS3 estado (solo lectura) | - | TWPS1 TWPS0
//   TWAR  0xBA   TWA6..TWA0 direccion de esclavo | TWGCE
//   TWDR  0xBB   dato
//   TWCR  0xBC   TWINT TWEA TWSTA TWSTO TWWC TWEN - TWIE
//   TWAMR 0xBD   TWAM6..TWAM0 mascara de direccion | -
//
//   SDA = PC4      SCL = PC5
//
// ESTO NO ES UN CABLE, ES UN BUS. Es la diferencia con el SPI, y manda en
// todo el modulo. Nadie conduce nunca una linea hacia arriba: se TIRA HACIA
// ABAJO o se SUELTA, y la resistencia de pull-up es la que sube el nivel. De
// ahi salen las tres propiedades que un SPI no tiene:
//
//   1. ARBITRAJE. Dos maestros pueden arrancar a la vez sin estropear la
//      trama. Quien suelta la linea y la lee BAJA ha perdido: otro esta
//      tirando de ella. El perdedor se calla en ese mismo bit -sin STOP y sin
//      perder el dato- y pasa a esclavo. Codigo de estado 0x38.
//   2. SINCRONIZACION DE RELOJ. El SCL alto no empieza a contar cuando lo
//      soltamos, sino cuando el PIN sube de verdad. Si otro dispositivo sigue
//      tirando de el, esperamos.
//   3. ESTIRAMIENTO DE RELOJ. Mientras TWINT este puesto, el hardware tira de
//      SCL hacia abajo, y el otro extremo espera. Es lo que le da tiempo al
//      programa a leer TWDR entre byte y byte, y es la razon de que una ISR
//      lenta ralentice el bus en vez de corromperlo.
//
// POR ESO EL PIN SE LEE SIEMPRE. `scl_pin` y `sda_pin` no son adornos de
// observacion: son entradas de la maquina de estados. Un TWI que use su
// propia salida en vez del pin funciona perfectamente contra un banco ideal y
// se rompe en la primera placa con dos maestros o un esclavo lento.
//
// LA FRECUENCIA: f_SCL = f_CPU / (16 + 2*TWBR*4^TWPS). O sea, cada semiperiodo
// dura 8 + TWBR*4^TWPS ciclos de CPU. Con TWBR=72 y TWPS=0 a 16 MHz salen los
// 100 kHz de siempre, que es lo que pone `Wire.begin()`.
//
// LA TRAMPA Nº 11 OTRA VEZ, la de los efectos laterales. Aqui son dos:
//   - TWINT NO se limpia escribiendo cero: se limpia escribiendo UNO, y al
//     limpiarlo ARRANCA la siguiente operacion. Un programa que haga
//     `TWCR &= ~(1<<TWINT)` no para el bus: lo deja colgado para siempre.
//   - TWWC se pone al escribir TWDR con TWINT BAJO, es decir, con una
//     transferencia en marcha. El dato no se carga. Sin esta bandera, un
//     programa que escriba fuera de tiempo pierde bytes en silencio.
//
// LA MASCARA DE DIRECCION. TWAMR no es un segundo esclavo: es una mascara de
// «no me importa». El bit a 1 de TWAMR hace que ese bit de la direccion no se
// compare, con lo que el chip responde a un RANGO de direcciones. Se compara
//     ((recibida ^ TWAR) & ~TWAMR) == 0
// y la llamada general (direccion 0x00 con R/W=0) va aparte, con TWGCE.
//
// SIMAVR NO SIRVE DE ORACULO PARA LA FORMA DE ONDA, igual que con la USART y
// el SPI: su `avr_twi.c` transporta direcciones y bytes enteros por IRQs
// internas y no serializa nada, asi que no hay SDA que comparar. Lo que el
// diferencial si verifica es el almacenamiento de TWBR, TWAR y TWAMR. La forma
// de onda, los 26 codigos de estado y el arbitraje los certifica el banco
// propio contra un bus modelado desde la hoja de datos.
// Ver docs/01-arquitectura.md §8bis.

`default_nettype none

module axioma_twi (
    input  wire       clk,
    input  wire       rst_n,

    // La habilitacion de reloj: un pulso por ciclo de sistema (ADR 0003).
    // Con CLKPS=0 vale 1 siempre y este modulo se comporta como antes.
    input  wire       ce,

    // ---- interfaz comun de periferico (docs/01-arquitectura.md §2) ----
    input  wire [7:0] io_addr,
    input  wire       io_re,
    input  wire       io_we,
    input  wire [7:0] io_wdata,
    output wire [7:0] io_rdata,
    output wire       io_sel,

    // ---- pines, tal como llegan del pad ----
    // Colector abierto: no hay `*_out`. La linea se TIRA A CERO cuando el
    // `*_oe` correspondiente esta alto, y se SUELTA cuando esta bajo. El SoC
    // ata el valor de anulacion a cero permanentemente y modula la DIRECCION,
    // que es exactamente lo que hace una salida de colector abierto.
    input  wire       scl_pin,
    input  wire       sda_pin,
    output wire       scl_pull,     // 1 = tirar de SCL hacia abajo
    output wire       sda_pull,     // 1 = tirar de SDA hacia abajo
    output wire       twen,         // TWEN: el TWI se adueña de PC4 y PC5

    // ---- interrupcion ----
    output wire       irq
);

    // Direcciones de I/O, que es la del espacio de datos menos 0x20. Los seis
    // registros del TWI viven en la I/O EXTENDIDA -0xB8..0xBD en el espacio de
    // datos-, fuera del alcance de IN/OUT: solo se llega con LDS/STS y LD/LDD.
    // Por eso el dato de lectura tiene que sobrevivir al ciclo siguiente, y por
    // eso lo registra el bus. Quien verifica que estas seis constantes sean las
    // de la hoja de datos es la tabla MAPA[] de sim/soc/tb_soc_map.cpp, que es
    // una fuente independiente de este fichero.
    localparam [7:0] A_TWBR  = 8'h98;   // dato 0xB8
    localparam [7:0] A_TWSR  = 8'h99;   // dato 0xB9
    localparam [7:0] A_TWAR  = 8'h9A;   // dato 0xBA
    localparam [7:0] A_TWDR  = 8'h9B;   // dato 0xBB
    localparam [7:0] A_TWCR  = 8'h9C;   // dato 0xBC
    localparam [7:0] A_TWAMR = 8'h9D;   // dato 0xBD

    wire hit_twbr  = (io_addr == A_TWBR);
    wire hit_twsr  = (io_addr == A_TWSR);
    wire hit_twar  = (io_addr == A_TWAR);
    wire hit_twdr  = (io_addr == A_TWDR);
    wire hit_twcr  = (io_addr == A_TWCR);
    wire hit_twamr = (io_addr == A_TWAMR);
    assign io_sel = hit_twbr | hit_twsr | hit_twar | hit_twdr | hit_twcr | hit_twamr;

    // ------------------------------------------------------------- registros
    reg [7:0] twbr_q;
    reg [1:0] twps_q;
    reg [7:0] twar_q;
    reg [7:0] twamr_q;
    reg [7:0] twdr_q;
    reg [4:0] status_q;            // TWS7..TWS3: el codigo, ya desplazado

    reg       twint_q, twea_q, twsta_q, twsto_q, twwc_q, twen_q, twie_q;

    assign twen = twen_q;
    assign irq  = twint_q & twie_q;

    // -------------------------------------- sincronizador y filtro de picos
    // DOS ETAPAS DE SINCRONIZACION, y aqui si. El sincronizador de una sola
    // etapa de `PINx` y de las interrupciones externas es deliberado: lo exige
    // la temporizacion documentada del `nop`. El TWI no tiene ninguna
    // temporizacion de ese tipo que cumplir -sus semiperiodos son de 80 ciclos
    // o mas- y lo que si tiene es una entrada verdaderamente asincrona: otro
    // maestro en la placa. Dos etapas es lo correcto y no añade deuda D6.
    //
    // Y ADEMAS UN FILTRO, QUE NO ES LO MISMO. Un sincronizador resuelve
    // metaestabilidad; NO descarta nada. Un pico de un ciclo entra por la
    // primera etapa, sale por la segunda y del otro lado es indistinguible de
    // un flanco de verdad. En un bus de dos hilos eso no es un bit erroneo:
    // un flanco falso de SDA con SCL alto es un START o un STOP INVENTADO, y
    // se lleva por delante la trama entera.
    //
    // La hoja de datos lo pide explicitamente -«spike suppression»- para
    // pulsos de menos de 50 ns. Aqui el valor filtrado solo cambia cuando DOS
    // muestras consecutivas coinciden, asi que se descarta cualquier pulso mas
    // corto que un ciclo de reloj: a 12,5 MHz son 80 ns, con margen sobre los
    // 50 que exige el bus. Lo prueba la fase de ruido de `make sim-twi`, que
    // barre un pico por todas las posiciones de una trama entera; sin filtro,
    // esa fase no pasa.
    reg scl_s1, scl_s2, sda_s1, sda_s2;
    reg scl_f, sda_f, sda_prev;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            scl_s1 <= 1'b1; scl_s2 <= 1'b1; scl_f <= 1'b1;
            sda_s1 <= 1'b1; sda_s2 <= 1'b1; sda_f <= 1'b1; sda_prev <= 1'b1;
        end else if (ce) begin
            scl_s1 <= scl_pin;  scl_s2 <= scl_s1;
            sda_s1 <= sda_pin;  sda_s2 <= sda_s1;
            if (scl_s1 == scl_s2) scl_f <= scl_s2;
            if (sda_s1 == sda_s2) sda_f <= sda_s2;
            sda_prev <= sda_f;
        end
    end
    wire scl_hi   =  scl_f;
    wire sda_rise =  sda_f & ~sda_prev;
    wire sda_fall = ~sda_f &  sda_prev;

    // El TWI no tiene NINGUN efecto lateral de lectura: TWINT no se limpia
    // leyendo TWSR, como haria un SPIF. Se limpia escribiendo un uno. Por eso
    // `io_re` no se usa, y el puerto sigue en la interfaz porque es parte del
    // contrato comun de periferico.
    wire unused_io_re = &{1'b0, io_re};

    // START y STOP: la linea de datos se mueve mientras el reloj esta ALTO.
    // Es la unica combinacion que un dato valido nunca produce, y por eso
    // sirve de marca de trama.
    wire start_det = scl_hi & sda_fall;
    wire stop_det  = scl_hi & sda_rise;

    // ------------------------------------------------ generador de bit rate
    // f_SCL = f_CPU / (16 + 2*TWBR*4^TWPS)  =>  semiperiodo = 8 + TWBR*4^TWPS
    // El desplazamiento es por 0, 2, 4 o 6, que es un multiplexor de cuatro
    // entradas y no un multiplicador.
    wire [14:0] twbr_esc = {7'b0, twbr_q} << {twps_q, 1'b0};
    wire [14:0] semiper  = twbr_esc + 15'd8;

    reg  [14:0] div_q;
    wire        div_fin = (div_q == 15'd0);

    // ------------------------------------------------------- estado del bus
    // `bus_libre` cuenta el tiempo que las dos lineas llevan altas. Un maestro
    // no puede arrancar un START sobre un bus ocupado: si lo hace, corrompe la
    // trama de otro. Es lo que hace que un maestro que pierde el arbitraje y
    // tiene TWSTA puesto reintente SOLO cuando el otro ha terminado.
    // Al reset se da por libre: el chip no tiene historia del bus, igual que
    // el de verdad. Si alguien esta tirando de una linea, el sincronizador lo
    // ve en dos ciclos y lo recarga. Lo que si cuenta de verdad es el tiempo
    // de bus libre TRAS UN STOP, y ese lo da la recarga.
    reg [14:0] libre_q;
    wire       bus_libre = (libre_q == 15'd0);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)                     libre_q <= 15'd0;
        else if (ce) begin
            if      (start_det)          libre_q <= 15'h7FFF;   // bus tomado
            else if (!scl_hi || !sda_f)  libre_q <= semiper;    // alguien tira
            else if (!bus_libre)         libre_q <= libre_q - 15'd1;
        end
    end

    // --------------------------------------------------- maquina de estados
    // ONCE ESTADOS. Las cuatro fases de bit -CAE, BAJO, SUBE, ALTO- son las
    // que valen para maestro Y esclavo: las dos esperas miran el PIN, asi que
    // el esclavo simplemente no cuenta semiperiodos ni conduce SCL. Con dos
    // maquinas separadas habria dos registros de desplazamiento y dos sitios
    // donde equivocarse.
    localparam [3:0] S_IDLE     = 4'd0,   // sin actividad: las dos lineas sueltas
                     S_ST_ESPERA= 4'd1,   // START pedido: esperar bus libre
                     S_ST_SDA   = 4'd2,   // SDA abajo con SCL alto: eso ES el START
                     S_BIT_CAE  = 4'd3,   // esperar a que SCL caiga; presentar el bit
                     S_BIT_BAJO = 4'd4,   // semiperiodo bajo
                     S_BIT_SUBE = 4'd5,   // esperar a que SCL suba; muestrear
                     S_BIT_ALTO = 4'd6,   // semiperiodo alto
                     S_SP_BAJO  = 4'd7,   // preparar STOP: SDA abajo con SCL abajo
                     S_SP_SUBE  = 4'd8,   // soltar SCL y esperar a que suba
                     S_SP_SDA   = 4'd9,   // soltar SDA con SCL alto: eso ES el STOP
                     S_RETENIDO = 4'd10;  // TWINT puesto: tiramos de SCL

    reg [3:0] est_q;
    reg [3:0] bit_q;              // 0..7 datos, 8 = el bit de ACK
    reg [7:0] sh_q;               // registro de desplazamiento
    reg       sda_drv_q;          // lo que presentamos: 0 = tirar, 1 = soltar
    reg       scl_drv_q;          // 0 = tirar de SCL, 1 = soltarlo
    reg       maestro_q;          // somos nosotros quien genera el reloj
    reg       mtx_q;              // maestro transmisor (R/W del SLA era 0)
    reg       stx_q;              // esclavo transmisor
    reg       dirigido_q;         // el esclavo esta seleccionado
    reg       gencall_q;          // seleccionado por llamada general
    reg       addr_fase_q;        // el byte en curso es el de direccion
    reg       ack_rx_q;           // el ACK que nos devolvieron (0 = ACK)
    reg       ack_tx_q;           // el ACK que mandamos NOSOTROS (1 = ACK)
    reg       perdido_q;          // arbitraje perdido en este byte

    // QUIEN TRANSMITE EL BYTE EN CURSO decide dos cosas: quien conduce SDA en
    // los ocho bits y quien conduce el noveno. En la fase de direccion el
    // maestro transmite aunque vaya a leer -el SLA+R lo manda el-, y por eso
    // no basta con mirar `mtx_q`.
    wire tx_byte = maestro_q ? (addr_fase_q | mtx_q) : (dirigido_q & stx_q);

    // ARBITRAJE: solo se mira cuando SOMOS NOSOTROS quien deberia estar
    // dejando la linea alta. La hoja de datos lo enumera exactamente asi:
    // «arbitration lost in SLA+R/W or data bytes» -transmitiendo, bits 0..7- y
    // «arbitration lost in SLA+R or NOT ACK bit» -recibiendo, el noveno-.
    //
    // EL NOVENO BIT MIENTRAS TRANSMITIMOS NO CUENTA, y confundirlo es un fallo
    // que se traga toda transferencia: ahi la linea es del OTRO extremo, y el
    // cero que se lee es su ACK. Tratarlo como arbitraje hace que el maestro
    // se rinda justo cuando le acaban de contestar que si.
    //
    // Y durante la RECEPCION de los ocho bits tampoco: es el esclavo quien
    // conduce, y cada cero recibido pareceria una perdida.
    wire arb_check = maestro_q & sda_drv_q
                   & ((tx_byte & (bit_q <= 4'd7)) | (~tx_byte & (bit_q == 4'd8)));

    // LA PUERTA DE `TWEN` AQUI ES REDUNDANTE, Y SE QUEDA. Hoy no cambia nada:
    // la escritura que baja TWEN suelta las dos lineas en el mismo ciclo, asi
    // que `scl_drv_q` y `sda_drv_q` ya valen uno cuando `twen_q` vale cero.
    // Un mutante que la quite es EQUIVALENTE, y por eso no esta en el
    // catalogo: no se puede distinguir desde fuera.
    //
    // Se queda porque dice en UN SITIO lo que si no habria que comprobar en
    // todos: con TWEN bajo, este modulo no toca PC4 ni PC5. Eso deja de ser
    // gratis en cuanto alguien añada un camino que conduzca una linea sin
    // acordarse de mirar TWEN, y en un bus de colector abierto ese descuido no
    // da un bit raro: cuelga el bus de la placa entera.
    assign scl_pull = twen_q & ~scl_drv_q;
    assign sda_pull = twen_q & ~sda_drv_q;

    // ------------------------------------------------ codigos de estado (>>3)
    // Los 26 de las tablas 21-2 a 21-6 de la hoja de datos. Se guardan ya
    // desplazados porque TWSR solo tiene cinco bits de estado; al leerlo se
    // vuelven a poner arriba. Guardar el byte entero dejaria dos bits que
    // pueden contradecir a TWPS.
    localparam [4:0] ST_BUS_ERROR = 5'h00,  // 0x00
                     ST_START     = 5'h01,  // 0x08
                     ST_REPSTART  = 5'h02,  // 0x10
                     ST_MT_SLA_A  = 5'h03,  // 0x18
                     ST_MT_SLA_N  = 5'h04,  // 0x20
                     ST_MT_DAT_A  = 5'h05,  // 0x28
                     ST_MT_DAT_N  = 5'h06,  // 0x30
                     ST_ARB_LOST  = 5'h07,  // 0x38
                     ST_MR_SLA_A  = 5'h08,  // 0x40
                     ST_MR_SLA_N  = 5'h09,  // 0x48
                     ST_MR_DAT_A  = 5'h0A,  // 0x50
                     ST_MR_DAT_N  = 5'h0B,  // 0x58
                     ST_SR_SLA_A  = 5'h0C,  // 0x60
                     ST_SR_ARB_SLA= 5'h0D,  // 0x68
                     ST_SR_GC_A   = 5'h0E,  // 0x70
                     ST_SR_ARB_GC = 5'h0F,  // 0x78
                     ST_SR_DAT_A  = 5'h10,  // 0x80
                     ST_SR_DAT_N  = 5'h11,  // 0x88
                     ST_SR_GDAT_A = 5'h12,  // 0x90
                     ST_SR_GDAT_N = 5'h13,  // 0x98
                     ST_SR_STOP   = 5'h14,  // 0xA0
                     ST_ST_SLA_A  = 5'h15,  // 0xA8
                     ST_ST_ARB_SLA= 5'h16,  // 0xB0
                     ST_ST_DAT_A  = 5'h17,  // 0xB8
                     ST_ST_DAT_N  = 5'h18,  // 0xC0
                     ST_ST_LAST_A = 5'h19,  // 0xC8
                     ST_NADA      = 5'h1F;  // 0xF8

    // ------------------------------------------------------ escritura de TWCR
    // ESCRIBIR UNO EN TWINT LO LIMPIA, Y AL LIMPIARLO ARRANCA LA OPERACION.
    // La decision de QUE operacion usa los bits de ESTA MISMA escritura, no los
    // guardados: el programa pone TWINT, TWSTA y TWEN de un golpe, y leer los
    // registrados daria los de la operacion anterior.
    wire wr_twcr = io_we & hit_twcr;
    wire arranca = wr_twcr & io_wdata[7];
    wire n_twea  = wr_twcr ? io_wdata[6] : twea_q;
    wire n_twsta = wr_twcr ? io_wdata[5] : twsta_q;
    wire n_twsto = wr_twcr ? io_wdata[4] : twsto_q;
    wire n_twen  = wr_twcr ? io_wdata[2] : twen_q;

    // ---------------------------------------------- reconocimiento de direccion
    // La mascara TWAMR no es un segundo esclavo: es un «no me importa» por bit.
    wire dir_coincide = ((sh_q[7:1] ^ twar_q[7:1]) & ~twamr_q[7:1]) == 7'd0;
    wire es_gencall   = (sh_q[7:1] == 7'd0) & ~sh_q[0] & twar_q[0];
    wire pide_lectura = sh_q[0];

    // ------------------------------------------------------ maquina de estados
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            twbr_q <= 8'h00;  twps_q <= 2'b00;
            twar_q <= 8'hFE;  twamr_q <= 8'h00;   // TWAR arranca a 0xFE, TWAMR a 0x00
            twdr_q <= 8'hFF;                      // TWDR arranca a 0xFF
            status_q <= ST_NADA;
            twint_q <= 1'b0; twea_q <= 1'b0; twsta_q <= 1'b0;
            twsto_q <= 1'b0; twwc_q <= 1'b0; twen_q <= 1'b0; twie_q <= 1'b0;
            est_q <= S_IDLE;  bit_q <= 4'd0;  sh_q <= 8'hFF;
            sda_drv_q <= 1'b1; scl_drv_q <= 1'b1;
            maestro_q <= 1'b0; mtx_q <= 1'b0; stx_q <= 1'b0;
            dirigido_q <= 1'b0; gencall_q <= 1'b0; addr_fase_q <= 1'b0;
            ack_rx_q <= 1'b1; ack_tx_q <= 1'b0; perdido_q <= 1'b0;
            div_q <= 15'd0;
        end else if (ce) begin
            // ---------------------------------------------------- temporizador
            if (!div_fin) div_q <= div_q - 15'd1;

            // ------------------------------------------- escrituras del programa
            if (io_we) begin
                if (hit_twbr)  twbr_q  <= io_wdata;
                if (hit_twsr)  twps_q  <= io_wdata[1:0];   // TWS7..3 son de solo lectura
                if (hit_twar)  twar_q  <= io_wdata;
                if (hit_twamr) twamr_q <= io_wdata & 8'hFE; // el bit 0 no existe
                if (hit_twdr) begin
                    // TWWC: escribir TWDR con TWINT BAJO no carga el dato, solo
                    // levanta la bandera. Es lo que delata una escritura fuera
                    // de tiempo, que si no se pierde en silencio.
                    if (twint_q) twdr_q <= io_wdata;
                    else         twwc_q <= 1'b1;
                end
                if (hit_twcr) begin
                    twea_q <= io_wdata[6];
                    twsta_q <= io_wdata[5];
                    twsto_q <= io_wdata[4];
                    twen_q <= io_wdata[2];
                    twie_q <= io_wdata[0];
                    if (io_wdata[7]) begin
                        twint_q <= 1'b0;
                        twwc_q  <= 1'b0;      // la escritura valida limpia la colision
                    end
                    if (!io_wdata[2]) begin   // TWEN=0: el TWI suelta los pines
                        est_q <= S_IDLE;
                        sda_drv_q <= 1'b1; scl_drv_q <= 1'b1;
                        maestro_q <= 1'b0; dirigido_q <= 1'b0;
                        status_q <= ST_NADA;
                    end
                end
            end

            // ------------------------------------------------ maquina de bus
            // Solo corre con TWEN puesto. Con TWEN bajo el TWI no existe: los
            // pines vuelven a ser PC4 y PC5 normales.
            if (n_twen) case (est_q)

            // ---- sin actividad ------------------------------------------
            S_IDLE: begin
                sda_drv_q <= 1'b1; scl_drv_q <= 1'b1;
                maestro_q <= 1'b0; dirigido_q <= 1'b0; perdido_q <= 1'b0;
                // EL START PEDIDO ES DE NIVEL, NO DE FLANCO. La hoja de datos:
                // «a START condition will be transmitted when the bus becomes
                // free». TWSTA se queda puesto hasta que se transmite, asi que
                // basta con mirarlo. Con un disparo por flanco -reaccionar solo
                // a la escritura de TWCR- una peticion que llegue en el mismo
                // ciclo que un STOP ajeno se pierde, y el TWI se queda parado
                // con TWSTA puesto para siempre. Paso: el STOP era el NUESTRO,
                // que el sincronizador entrega dos ciclos tarde.
                if (twsta_q & ~twint_q) begin
                    est_q <= S_ST_ESPERA;
                end else if (arranca & n_twsto) begin
                    // STOP en esclavo: NO se genera nada en el bus. Es la
                    // recuperacion de un error: volver a esclavo sin dirigir.
                    twsto_q <= 1'b0;
                    status_q <= ST_NADA;
                end
                // Un START ajeno NO se atiende aqui: lo hace el manejador
                // global del final, que corre DESPUES del `case` y pisaria
                // cualquier cosa que se pusiera en esta rama. Tenerlo escrito
                // en los dos sitios no era redundancia inofensiva: era codigo
                // muerto que se puede desincronizar del que si manda, y lo
                // delato un mutante que sobrevivia por estar inyectado en el
                // lado que no se ejecuta.
            end

            // ---- START propio -------------------------------------------
            S_ST_ESPERA: begin
                // No se puede arrancar sobre un bus ocupado: se corromperia la
                // trama de otro. Esto es tambien lo que hace que el maestro que
                // pierde el arbitraje con TWSTA puesto reintente cuando el otro
                // termina.
                sda_drv_q <= 1'b1; scl_drv_q <= 1'b1;
                if (bus_libre) begin
                    sda_drv_q <= 1'b0;          // tirar de SDA con SCL alto: START
                    div_q <= semiper - 15'd1;
                    est_q <= S_ST_SDA;
                end else if (start_det & n_twea & ~maestro_q) begin
                    // Otro se nos adelanto: pasamos a escuchar. TWSTA sigue
                    // puesto, asi que lo reintentaremos al quedar libre.
                    est_q <= S_BIT_CAE;  bit_q <= 4'd0;  sh_q <= 8'hFF;   // soltamos SDA: vamos a RECIBIR
                    addr_fase_q <= 1'b1;
                end
            end

            S_ST_SDA: begin
                if (div_fin) begin
                    scl_drv_q <= 1'b0;          // bajar SCL: el START queda hecho
                    div_q     <= semiper - 15'd1;
                    maestro_q <= 1'b1;
                    twsta_q   <= 1'b0;          // TWSTA se limpia al transmitirlo
                    status_q  <= maestro_q ? ST_REPSTART : ST_START;
                    twint_q   <= 1'b1;
                    est_q     <= S_RETENIDO;
                end
            end

            // ---- TWINT puesto: tiramos de SCL y esperamos al programa ----
            // ESTE ES EL ESTIRAMIENTO DE RELOJ, y es lo que hace que una ISR
            // lenta ralentice el bus en vez de corromperlo.
            // NO SE FUERZA SCL AQUI. Lo decide quien entra en el estado, y es
            // una diferencia que importa: tras un STOP recibido -codigo 0xA0-
            // el bus esta LIBRE, y un esclavo que siguiera tirando de SCL lo
            // bloquearia para todos hasta que su ISR se dignara a contestar.
            // Retienen el reloj los puntos que estan a mitad de trama; el
            // STOP, el error de bus y el arbitraje perdido sueltan.
            S_RETENIDO: begin
                if (arranca) begin
                    perdido_q <= 1'b0;
                    if (n_twsta) begin
                        // START repetido: primero hay que soltar las dos lineas
                        est_q <= S_ST_ESPERA;
                    end else if (n_twsto & maestro_q) begin
                        sda_drv_q <= 1'b0;      // SDA abajo con SCL abajo
                        div_q <= semiper - 15'd1;
                        est_q <= S_SP_BAJO;
                    end else if (n_twsto) begin
                        // En esclavo, TWSTO no genera nada: solo recupera
                        twsto_q <= 1'b0;
                        status_q <= ST_NADA;
                        dirigido_q <= 1'b0;
                        est_q <= S_IDLE;
                    end else if (maestro_q) begin
                        // Siguiente byte del maestro. El semiperiodo bajo
                        // empieza a contar AHORA: es cuando el programa suelta
                        // el bus al limpiar TWINT.
                        div_q <= semiper - 15'd1;
                        bit_q <= 4'd0;
                        addr_fase_q <= (status_q == ST_START) | (status_q == ST_REPSTART);
                        if ((status_q == ST_START) | (status_q == ST_REPSTART)) begin
                            sh_q  <= twdr_q;    // SLA+R/W
                            mtx_q <= ~twdr_q[0];
                        end else if (mtx_q) begin
                            sh_q  <= twdr_q;    // dato a transmitir
                        end else begin
                            sh_q  <= 8'hFF;     // recibimos: soltamos SDA
                        end
                        est_q <= S_BIT_CAE;
                    end else if (dirigido_q) begin
                        // Siguiente byte del esclavo. Soltar SCL es lo que
                        // TERMINA el estiramiento: el reloj vuelve a ser del
                        // maestro en cuanto el programa contesta.
                        scl_drv_q <= 1'b1;
                        bit_q <= 4'd0;
                        addr_fase_q <= 1'b0;
                        sh_q <= stx_q ? twdr_q : 8'hFF;
                        est_q <= S_BIT_CAE;
                    end else begin
                        // No dirigido: volvemos a escuchar
                        status_q <= ST_NADA;
                        est_q <= S_IDLE;
                    end
                end
            end

            // ---- un bit: cuatro fases, TODAS atadas al PIN ---------------
            // El maestro cuenta semiperiodos, pero espera al pin en las dos
            // transiciones. De ahi salen gratis el estiramiento de reloj ajeno
            // y el tiempo de mantenimiento de SDA: la linea de datos no se
            // mueve hasta que SCL ha caido DE VERDAD.
            S_BIT_CAE: begin
                if (!scl_hi) begin
                    // Presentar el bit que toca. CON EL ARBITRAJE YA PERDIDO
                    // se suelta: a partir de ese bit somos un oyente, y seguir
                    // sacando los bits que ibamos a mandar corrompe la trama
                    // del que gano -y de paso la nuestra, porque lo que se lee
                    // del bus es el Y de los dos-. Es lo que impide reconocer
                    // que el ganador nos estaba llamando justo a nosotros.
                    if (bit_q <= 4'd7)          sda_drv_q <= perdido_q ? 1'b1 : sh_q[7];
                    else if (tx_byte)           sda_drv_q <= 1'b1;   // soltar: contesta el otro
                    else if (~maestro_q & addr_fase_q) begin
                        sda_drv_q <= ~((dir_coincide | es_gencall) & n_twea);
                        ack_tx_q  <=  ((dir_coincide | es_gencall) & n_twea);
                    end else begin
                        sda_drv_q <= ~n_twea;
                        ack_tx_q  <=  n_twea;
                    end
                    // `div_q` NO se recarga aqui: viene contando desde que se
                    // tiro de SCL, en S_BIT_ALTO o al salir de S_RETENIDO. Es
                    // lo que hace que el semiperiodo bajo dure `semiper`
                    // EXACTOS y no `semiper` mas lo que tarde el
                    // sincronizador en ver el flanco.
                    est_q <= S_BIT_BAJO;
                end
            end

            S_BIT_BAJO: begin
                if (maestro_q) begin
                    if (div_fin) begin
                        scl_drv_q <= 1'b1;      // soltar SCL
                        div_q     <= semiper - 15'd1;   // arranca el ALTO
                        est_q <= S_BIT_SUBE;
                    end
                end else begin
                    est_q <= S_BIT_SUBE;        // el esclavo no manda en el reloj
                end
            end

            S_BIT_SUBE: begin
                if (scl_hi) begin
                    if (arb_check & ~sda_f) begin
                        // ARBITRAJE PERDIDO: soltamos la linea sin STOP y sin
                        // perder el dato. Si estabamos en la direccion seguimos
                        // escuchando, porque puede que nos esten llamando.
                        perdido_q <= 1'b1;
                        maestro_q <= 1'b0;
                        scl_drv_q <= 1'b1;
                        if (addr_fase_q) begin
                            sh_q <= {sh_q[6:0], sda_f};
                            if (div_fin) div_q <= semiper - 15'd3;
                            est_q <= S_BIT_ALTO;
                        end else begin
                            sda_drv_q <= 1'b1;
                            status_q <= ST_ARB_LOST;
                            twint_q  <= 1'b1;
                            est_q    <= S_RETENIDO;
                        end
                    end else begin
                        if (bit_q <= 4'd7) sh_q     <= {sh_q[6:0], sda_f};
                        else               ack_rx_q <= sda_f;
                        // NORMALMENTE NO SE RECARGA: la cuenta del alto arranco
                        // al soltar SCL, asi que el semiperiodo sale exacto sin
                        // compensar nada. Solo si la cuenta YA se agoto
                        // esperando -es decir, si alguien estaba estirando el
                        // reloj- hace falta un alto minimo desde que el pin
                        // sube de verdad, que es lo que exige el bus.
                        if (div_fin) div_q <= semiper - 15'd3;
                        est_q <= S_BIT_ALTO;
                    end
                end
            end

            S_BIT_ALTO: begin
                if (maestro_q ? div_fin : !scl_hi) begin
                    if (maestro_q) begin
                        scl_drv_q <= 1'b0;              // bajar SCL
                        div_q     <= semiper - 15'd1;   // arranca el BAJO
                    end
                    if (bit_q != 4'd8) begin
                        bit_q <= bit_q + 4'd1;
                        est_q <= S_BIT_CAE;
                    end else begin
                        bit_q <= 4'd0;
                        est_q <= S_RETENIDO;
                        twint_q <= 1'b1;
                        // ---------------------------------- byte completo
                        if (maestro_q & addr_fase_q) begin
                            // SLA+R/W transmitido
                            dirigido_q <= 1'b0;
                            status_q <= mtx_q ? (ack_rx_q ? ST_MT_SLA_N : ST_MT_SLA_A)
                                              : (ack_rx_q ? ST_MR_SLA_N : ST_MR_SLA_A);
                            if (~mtx_q & ~ack_rx_q) sda_drv_q <= 1'b1;
                        end else if (maestro_q & mtx_q) begin
                            status_q <= ack_rx_q ? ST_MT_DAT_N : ST_MT_DAT_A;
                        end else if (maestro_q) begin
                            twdr_q <= sh_q;
                            sda_drv_q <= 1'b1;
                            status_q <= ack_tx_q ? ST_MR_DAT_A : ST_MR_DAT_N;
                        end else if (addr_fase_q) begin
                            // Direccion recibida como esclavo. Si es para
                            // nosotros retenemos SCL hasta que el programa
                            // conteste; si no, no tocamos el bus.
                            sda_drv_q <= 1'b1;
                            if ((dir_coincide | es_gencall) & n_twea)
                                scl_drv_q <= 1'b0;
                            if (dir_coincide & n_twea) begin
                                dirigido_q <= 1'b1;
                                gencall_q  <= 1'b0;
                                stx_q      <= pide_lectura;
                                if (pide_lectura)
                                    status_q <= perdido_q ? ST_ST_ARB_SLA : ST_ST_SLA_A;
                                else
                                    status_q <= perdido_q ? ST_SR_ARB_SLA : ST_SR_SLA_A;
                            end else if (es_gencall & n_twea) begin
                                dirigido_q <= 1'b1;
                                gencall_q  <= 1'b1;
                                stx_q      <= 1'b0;
                                status_q   <= perdido_q ? ST_SR_ARB_GC : ST_SR_GC_A;
                            end else if (perdido_q) begin
                                // Perdimos el bus y ademas no nos llamaban
                                status_q <= ST_ARB_LOST;
                                est_q    <= S_RETENIDO;
                            end else begin
                                // No es para nosotros: ni interrupcion ni nada
                                twint_q <= 1'b0;
                                est_q   <= S_IDLE;
                            end
                            perdido_q <= 1'b0;
                        end else if (stx_q) begin
                            // Esclavo transmisor: el maestro nos contesta
                            sda_drv_q <= 1'b1;
                            scl_drv_q <= 1'b0;
                            if (ack_rx_q) begin
                                status_q   <= ST_ST_DAT_N;
                                dirigido_q <= 1'b0;
                                stx_q      <= 1'b0;
                            end else begin
                                status_q <= twea_q ? ST_ST_DAT_A : ST_ST_LAST_A;
                            end
                        end else begin
                            // Esclavo receptor
                            twdr_q <= sh_q;
                            sda_drv_q <= 1'b1;
                            scl_drv_q <= 1'b0;
                            if (gencall_q) status_q <= ack_tx_q ? ST_SR_GDAT_A : ST_SR_GDAT_N;
                            else           status_q <= ack_tx_q ? ST_SR_DAT_A  : ST_SR_DAT_N;
                        end
                    end
                end
            end

            // ---- STOP propio --------------------------------------------
            S_SP_BAJO: begin
                if (div_fin) begin
                    scl_drv_q <= 1'b1;          // soltar SCL
                    div_q     <= semiper - 15'd1;
                    est_q <= S_SP_SUBE;
                end
            end
            S_SP_SUBE: begin
                if (scl_hi) begin
                    if (div_fin) div_q <= semiper - 15'd3;
                    est_q <= S_SP_SDA;
                end
            end
            S_SP_SDA: begin
                if (div_fin) begin
                    sda_drv_q <= 1'b1;          // soltar SDA con SCL alto: STOP
                    twsto_q   <= 1'b0;          // TWSTO se limpia solo al ejecutarlo
                    maestro_q <= 1'b0;
                    dirigido_q <= 1'b0;
                    status_q  <= ST_NADA;       // tras un STOP no hay TWINT
                    est_q     <= S_IDLE;
                end
            end

            default: est_q <= S_IDLE;
            endcase

            // ------------------------------------- START y STOP ajenos
            // MANDAN SOBRE CUALQUIER ESTADO, y por eso van DESPUES del case:
            // en Verilog la ultima asignacion no bloqueante de un ciclo es la
            // que vale, asi que esto es la prioridad maxima sin anidar el case.
            //
            // DONDE LLEGAN DECIDE SI SON LEGALES. Un dato solo cambia con SCL
            // abajo, asi que un flanco de SDA con SCL arriba solo puede ser un
            // START o un STOP. Lo que separa la marca legal del error es el
            // CONTADOR DE BITS, no el estado: con `bit_q` a cero todavia no ha
            // entrado ni un bit de este byte, asi que es un fin de trama en
            // regla; con el contador dentro del byte es un error de bus, y la
            // hoja de datos le da codigo propio, 0x00, del que solo se sale
            // escribiendo TWSTO.
            //
            // Mirar el ESTADO no vale, y costo una depuracion: en cuanto el
            // programa limpia TWINT el esclavo avanza a esperar el reloj del
            // maestro, de modo que el STOP que cierra la trama le llega en un
            // estado distinto del que se esperaria. El bit que muestrea antes
            // de verlo es el propio SDA bajando para el STOP.
            if (n_twen & (start_det | stop_det)
                       & (est_q != S_ST_SDA) & (est_q != S_SP_SDA)
                       & (est_q != S_ST_ESPERA)
                       & ~maestro_q) begin
                if (bit_q == 4'd0) begin
                    // Limite de byte: fin de trama legal
                    if (dirigido_q) begin
                        status_q   <= ST_SR_STOP;
                        twint_q    <= 1'b1;
                        dirigido_q <= 1'b0;  stx_q <= 1'b0;  gencall_q <= 1'b0;
                        sda_drv_q  <= 1'b1;  scl_drv_q <= 1'b1;
                        est_q      <= S_RETENIDO;
                    end else if (start_det & n_twea) begin
                        // START ajeno: a escuchar la direccion. EL ESTADO SE
                        // PONE AQUI, y no en el `case` de arriba: este
                        // manejador corre DESPUES y pisaria lo que aquel
                        // dejara. Tenerlo repartido entre los dos costo un
                        // mutante que sobrevivia -el `case` ponia el estado y
                        // esto el registro de desplazamiento, asi que romper
                        // el del `case` no cambiaba nada-.
                        bit_q <= 4'd0;  sh_q <= 8'hFF;  addr_fase_q <= 1'b1;
                        sda_drv_q <= 1'b1;
                        est_q <= S_BIT_CAE;
                    end else begin
                        est_q <= S_IDLE;
                    end
                end else if ((est_q == S_BIT_BAJO) | (est_q == S_BIT_SUBE)
                           | (est_q == S_BIT_ALTO) | (est_q == S_BIT_CAE)) begin
                    // En mitad de un byte: error de bus
                    status_q   <= ST_BUS_ERROR;
                    twint_q    <= 1'b1;
                    dirigido_q <= 1'b0;  stx_q <= 1'b0;
                    sda_drv_q  <= 1'b1;  scl_drv_q <= 1'b1;
                    est_q      <= S_RETENIDO;
                end
            end
        end
    end

    // --------------------------------------------------------- lectura de I/O
    // TWSR devuelve el estado en TWS7..TWS3, el bit 2 a cero -no existe- y
    // TWPS abajo. TWCR devuelve TWWC en su sitio y un cero en el bit 1.
    assign io_rdata = hit_twbr  ? twbr_q :
                      hit_twsr  ? {status_q, 1'b0, twps_q} :
                      hit_twar  ? twar_q :
                      hit_twdr  ? twdr_q :
                      hit_twcr  ? {twint_q, twea_q, twsta_q, twsto_q,
                                   twwc_q, twen_q, 1'b0, twie_q} :
                      hit_twamr ? twamr_q : 8'h00;

endmodule

`default_nettype wire
