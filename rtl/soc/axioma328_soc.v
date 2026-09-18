// AxiomaCore-328 - el dispositivo
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// ESTE fichero es el chip. Hasta ahora la integración —el mapa de direcciones
// de I/O, el cableado de los 26 vectores de interrupción, qué periférico
// cuelga de dónde— vivía en `sim/diff/axioma_sim_top.v`, un fichero que empieza
// diciendo «NO forma parte del diseño». Con eso, lo que la regresión verificaba
// era un banco de pruebas, y la integración era la única parte del chip sin
// verificación propia.
//
// No era un riesgo teórico: el desplazamiento de un bit en el vector de
// interrupciones, que convertía TIMER0_COMPA en TIMER1_OVF, estaba justo ahí.
//
// EL ESPACIO DE I/O NO ES RAM. Una dirección que ningún periférico reclama se
// lee como 0x00 y se escribe al vacío, como en el chip. El banco de pruebas
// tenía un array que fingía que todo el espacio era memoria, y eso hacía que el
// artefacto verificado y el dispositivo no fueran el mismo.
//
//   0x0000-0x001F  registros            los resuelve el bus contra el regfile
//   0x005D-0x005F  SPL, SPH, SREG       los intercepta axioma_core
//   0x0020-0x00FF  I/O y I/O extendida  lo de aquí abajo
//   0x0100-0x08FF  2 KB de SRAM         axioma_dmem
//
// Direcciones de I/O implementadas hoy (las de IN/OUT, es decir, dato - 0x20):
//
//   0x03-0x05  PINB DDRB PORTB        0x1E  GPIOR0
//   0x06-0x08  PINC DDRC PORTC        0x2A  GPIOR1
//   0x09-0x0B  PIND DDRD PORTD        0x2B  GPIOR2
//   0x15       TIFR0                  0x23  GTCCR
//   0x24-0x28  TCCR0A/B TCNT0 OCR0A/B 0x4E  TIMSK0  (sólo LD/ST)
//   0xA0-0xA6  UCSR0A/B/C UBRR0L/H UDR0      (sólo LD/ST)
//   0x16       TIFR1                  0x4F  TIMSK1  (sólo LD/ST)
//   0x60-0x62  TCCR1A/B/C             0x64-0x6B  TCNT1 ICR1 OCR1A/B
//
// Todo lo demás está sin implementar y se lee como cero. Un programa que use la
// USART, el SPI o el ADC no funcionará todavía, y es lo correcto: que lo diga
// el silencio y no un relleno que finge.

`default_nettype none

module axioma328_soc #(
    // Programa precargado. Vacío en simulación, donde el banco carga por la
    // puerta de atrás; con fichero en el bitstream de la FPGA.
    parameter INIT_HEX = ""
)(
    input  wire        clk,
    input  wire        rst_n,

    // ---------------------------------------------------------- pines
    // Cada puerto sale con las tres señales que necesita una celda de pad:
    // el dato, la dirección y la declaración de pull-up. Aplicarlo es cosa del
    // pad —el bloque de E/S del ECP5 en FPGA, la celda del PDK en silicio—,
    // no de este módulo.
    input  wire [7:0]  pb_in,
    output wire [7:0]  pb_out, pb_oe, pb_pu,
    input  wire [7:0]  pc_in,
    output wire [7:0]  pc_out, pc_oe, pc_pu,
    input  wire [7:0]  pd_in,
    output wire [7:0]  pd_out, pd_oe, pd_pu,

    // --------------------------------------- la frontera con lo analógico
    // EL SOC NO CONTIENE EL FRENTE ANALÓGICO: lo contiene quien lo instancia.
    // Aquí salen las cinco señales del ADR 0002 hacia el multiplexor, la
    // referencia, el S/H, el DAC y el comparador. En el flujo ASIC van al macro
    // del PDK; en la FPGA, que no convierte tensiones, el top de la placa lleva
    // un modelo digital. El dispositivo es el mismo en los dos destinos.
    output wire [3:0]  adc_canal,
    output wire [1:0]  adc_ref,
    output wire        adc_muestrea,
    output wire [9:0]  adc_dac,
    input  wire        adc_cmp,
    // Y las del comparador analogico, que se corta por el mismo sitio: la
    // comparacion es analogica y llega hecha.
    output wire        ac_apagado,
    output wire        ac_bandgap,
    output wire        ac_neg_mux,
    input  wire        ac_salida,

    // ---- el oscilador del perro guardian, que tampoco vive aqui ----
    // 128 kHz de RC no son logica, por el mismo criterio del ADR 0002: entra
    // como un pulso y quien instancia el SoC decide de donde sale. Y el
    // reinicio que produce SALE, en vez de morderse la cola aqui dentro: es el
    // top quien cierra la cadena de reset, igual que hace con `rst_n`.
    input  wire        wdt_osc_tick,
    output wire        wdt_reset,

    // ---------------------------------------------------- observación
    // No existen en el 328P. En la placa se quedan sin conectar y la síntesis
    // las descarta; en simulación son lo que mira el arnés diferencial.
    output wire [13:0] dbg_pc,
    output wire [15:0] dbg_ir,
    output wire        dbg_retire,
    output wire        dbg_illegal,
    output wire        dbg_irq_entry,
    output wire [4:0]  dbg_irq_vector,
    output wire [15:0] dbg_sp,
    output wire [7:0]  dbg_sreg,
    input  wire [4:0]  dbg_reg_addr,
    output wire [7:0]  dbg_reg_data
);

    // ------------------------------------------------- memoria de programa
    wire [13:0] pm_if_addr, pm_d_addr;
    wire        pm_if_en, pm_d_en, pm_d_we;
    wire [15:0] pm_d_wdata, pm_if_data, pm_d_rdata;

    axioma_progmem #(.INIT_HEX(INIT_HEX)) pm (
        .clk(clk),
        .if_addr(pm_if_addr), .if_en(pm_if_en), .if_data(pm_if_data),
        .d_addr(pm_d_addr), .d_en(pm_d_en), .d_we(pm_d_we),
        .d_wdata(pm_d_wdata), .d_rdata(pm_d_rdata)
    );

    // ------------------------------------------------------ espacio de datos
    wire [15:0] dm_addr;
    wire        dm_re, dm_we;
    wire [7:0]  dm_wdata, dm_rdata;

    wire [10:0] sram_addr;
    wire        sram_en, sram_we;
    wire [7:0]  sram_wdata, sram_rdata;

    wire [7:0]  io_addr;
    wire        io_re, io_we;
    wire [7:0]  io_wdata, io_rdata;
    wire        io_sel;

    axioma_dbus bus (
        .clk(clk), .rst_n(rst_n),
        .addr(dm_addr), .re(dm_re), .we(dm_we), .wdata(dm_wdata), .rdata(dm_rdata),
        .sram_addr(sram_addr), .sram_en(sram_en), .sram_we(sram_we),
        .sram_wdata(sram_wdata), .sram_rdata(sram_rdata),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we),
        .io_wdata(io_wdata), .io_rdata(io_rdata), .io_sel(io_sel)
    );

    axioma_dmem dm (
        .clk(clk), .addr(sram_addr), .en(sram_en), .we(sram_we),
        .wdata(sram_wdata), .rdata(sram_rdata)
    );

    // -------------------------------------- salidas de comparación a los pads
    // LOS CUATRO CANALES PWM, en los pines que les asigna el encapsulado:
    //
    //   OC0A -> PD6      OC0B -> PD5      OC1A -> PB1      OC1B -> PB2
    //
    // Se anula el VALOR del pin, nunca su dirección: el programa sigue
    // teniendo que poner DDRx, igual que en el chip.
    wire oc0a, oc0a_en, oc0b, oc0b_en;
    wire oc1a, oc1a_en, oc1b, oc1b_en;

    wire oc2a, oc2a_en, oc2b, oc2b_en;

    // EL SPI COMPARTE PINES CON LOS TEMPORIZADORES, y la hoja de datos dice
    // quién gana: con `SPE` puesto, el SPI se adueña de los suyos. PB3 es a la
    // vez MOSI y OC2A, y PB2 es a la vez SS y OC1B.
    //
    //   PB2  SS    / OC1B      PB4  MISO
    //   PB3  MOSI  / OC2A      PB5  SCK
    //
    // De la DIRECCIÓN se ocupa la otra anulación, la de la tabla 18-1: como
    // maestro se fuerza MISO a entrada, y como esclavo se fuerzan SS, MOSI y
    // SCK. Lo demás lo sigue poniendo el programa con DDRB.
    wire spi_sck, spi_sck_oe, spi_mosi, spi_mosi_oe, spi_miso, spi_miso_oe;
    wire spi_ss_force;
    wire twi_scl_pull, twi_sda_pull, twi_en;
    wire us_xck, us_xck_ovr;
    wire us_txd, us_txen, us_rxen;
    wire spi_maestro = spi_sck_oe;          // sólo el maestro conduce SCK
    wire spi_esclavo = spi_ss_force;        // sólo el esclavo fuerza SS a entrada

    wire [7:0] ovr_b_en  = {2'b0, spi_sck_oe,
                            spi_miso_oe,
                            spi_mosi_oe | oc2a_en,
                            oc1b_en, oc1a_en, 1'b0};
    wire [7:0] ovr_b_val = {2'b0, spi_sck,
                            spi_miso,
                            spi_mosi_oe ? spi_mosi : oc2a,
                            oc1b, oc1a, 1'b0};

    // Anulación de DIRECCIÓN. Sólo el SPI la usa, y sólo para forzar a ENTRADA
    // -salvo nada: el 328P no fuerza ningún pin del SPI a salida-.
    wire [7:0] dir_b_en  = {2'b0, spi_esclavo,          // PB5 SCK
                            spi_maestro,                 // PB4 MISO
                            spi_esclavo,                 // PB3 MOSI
                            spi_esclavo,                 // PB2 SS
                            2'b0};
    // Todas fuerzan ENTRADA: el 328P no fuerza a salida ningún pin del SPI.

    // ---- puerto C: el TWI se lleva PC4 (SDA) y PC5 (SCL) ----
    // COLECTOR ABIERTO, Y ASÍ ES COMO SE CONSTRUYE CON LAS DOS ANULACIONES QUE
    // YA TIENE EL PUERTO: el valor se ata a CERO permanentemente y lo que se
    // modula es la DIRECCIÓN. Salida y cero = tirar de la línea; entrada =
    // soltarla. No hay ningún camino por el que el TWI pueda conducir un uno,
    // que es justo lo que un bus de dos hilos no tolera.
    //
    // Y EL PULL-UP SIGUE SIENDO DE `PORTC`. `axioma_gpio` lo calcula como
    // `~pad_oe & port_q`, con el `pad_oe` ya anulado, así que al soltar la
    // línea el pull-up sale del bit que el programa escribió en PORTC4/PC5.
    // Es lo que hace el chip, y es lo que hace funcionar el `digitalWrite(SDA,
    // HIGH)` que `Wire.begin()` lleva dentro.
    wire [7:0] ovr_c_en  = twi_en ? 8'b0011_0000 : 8'h00;
    wire [7:0] ovr_c_val = 8'h00;                 // el TWI nunca conduce un uno
    wire [7:0] dir_c_en  = twi_en ? 8'b0011_0000 : 8'h00;
    wire [7:0] dir_c_val = {2'b0, twi_scl_pull, twi_sda_pull, 4'b0};

    // PD4 es XCK, el reloj del modo síncrono de la USART. Se anula el VALOR y
    // nunca la dirección: la hoja de datos dice que `DDR_XCK0` es precisamente
    // lo que elige entre maestro —reloj interno— y esclavo —reloj externo—, así
    // que forzarla rompería el mecanismo. Es el mismo criterio que con los
    // canales de comparación, y el contrario que con el SPI.
    // PD1 es TXD y PD0 es RXD. La tabla 14-9 de la hoja de datos dice que con
    // `TXEN0` puesto PD1 es SALIDA pase lo que pase en `DDRD1` y lo conduce el
    // transmisor, y que con `RXEN0` puesto PD0 es ENTRADA, con su pull-up
    // saliendo de `PORTD0`. Son los dos únicos pines del puerto D que llevan
    // anulación de DIRECCIÓN; los canales de comparación y `XCK` no la llevan.
    wire [7:0] ovr_d_en  = {1'b0, oc0a_en, oc0b_en, us_xck_ovr, oc2b_en,
                            1'b0, us_txen, 1'b0};
    wire [7:0] ovr_d_val = {1'b0, oc0a,    oc0b,    us_xck,     oc2b,
                            1'b0, us_txd,  1'b0};
    wire [7:0] dir_d_en  = {6'b0, us_txen, us_rxen};
    wire [7:0] dir_d_val = {6'b0, 1'b1,    1'b0};   // PD1 salida, PD0 entrada

    // ---------------------------------------------------- puertos de E/S
    wire [7:0] gb_rd, gc_rd, gd_rd;
    wire       gb_sel, gc_sel, gd_sel;

    axioma_gpio #(.IO_PIN(8'h03), .BITS(8'hFF)) gpio_b (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gb_rd), .io_sel(gb_sel),
        .ovr_en(ovr_b_en), .ovr_val(ovr_b_val),
        .dir_ovr_en(dir_b_en), .dir_ovr_val(8'h00),
        .din_dis(8'h00),
        .pad_in(pb_in), .pad_out(pb_out), .pad_oe(pb_oe), .pad_pullup(pb_pu)
    );
    // El puerto C sólo tiene siete bits: PC7 no existe en el encapsulado.
    axioma_gpio #(.IO_PIN(8'h06), .BITS(8'h7F)) gpio_c (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gc_rd), .io_sel(gc_sel),
        .ovr_en(ovr_c_en), .ovr_val(ovr_c_val),
        .dir_ovr_en(dir_c_en), .dir_ovr_val(dir_c_val),
        // DIDR0 APAGA EL BUFER DE ENTRADA DIGITAL de ADC0..ADC5, que son PC0 a
        // PC5. Es del ADC y solo lo tiene este puerto: `DIDR1`, que hace lo
        // mismo con AIN0 y AIN1 en PD6 y PD7, es del comparador analogico y
        // todavia no existe.
        .din_dis(adc_didr),
        .pad_in(pc_in), .pad_out(pc_out), .pad_oe(pc_oe), .pad_pullup(pc_pu)
    );
    axioma_gpio #(.IO_PIN(8'h09), .BITS(8'hFF)) gpio_d (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gd_rd), .io_sel(gd_sel),
        .ovr_en(ovr_d_en), .ovr_val(ovr_d_val),
        .dir_ovr_en(dir_d_en), .dir_ovr_val(dir_d_val),
        // DIDR1 apaga el bufer de entrada de AIN0 y AIN1, que son PD6 y PD7.
        .din_dis(ac_didr),
        .pad_in(pd_in), .pad_out(pd_out), .pad_oe(pd_oe), .pad_pullup(pd_pu)
    );

    // ------------------------------------------------ registros de propósito general
    wire [7:0] gr_rd;
    wire       gr_sel;
    axioma_gpior gpior (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(gr_rd), .io_sel(gr_sel)
    );

    // ------------------------------------------- Timer0 y prescaler compartido
    // El prescaler va aparte porque es un contador libre COMPARTIDO: en la
    // fase 3 el Timer1 se engancha a este mismo módulo. Es la trampa nº 12.
    wire tick_1, tick_8, tick_64, tick_256, tick_1024;
    wire [7:0] ps_rd, tm_rd;
    wire       ps_sel, tm_sel;
    wire       tm_ovf, tm_compa, tm_compb;

    axioma_prescaler presc (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(ps_rd), .io_sel(ps_sel),
        .tick_1(tick_1), .tick_8(tick_8), .tick_64(tick_64),
        .tick_256(tick_256), .tick_1024(tick_1024),
        .reset_asy(presc_reset_asy),
        /* verilator lint_off PINCONNECTEMPTY */
        .count()
        /* verilator lint_on PINCONNECTEMPTY */
    );
    axioma_timer0 timer0 (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(tm_rd), .io_sel(tm_sel),
        .tick_1(tick_1), .tick_8(tick_8), .tick_64(tick_64),
        .tick_256(tick_256), .tick_1024(tick_1024),
        .t0_pin(pd_in[4]),                       // T0 es PD4
        .oc0a(oc0a), .oc0a_en(oc0a_en), .oc0b(oc0b), .oc0b_en(oc0b_en),
        .irq_ovf(tm_ovf), .irq_compa(tm_compa), .irq_compb(tm_compb),
        .ack_ovf(irq_ack_v[16]), .ack_compa(irq_ack_v[14]), .ack_compb(irq_ack_v[15])
    );

    // ------------------------------------------------------- Timer/Counter1
    // EL MISMO PRESCALER QUE EL TIMER0. Esto es la trampa nº 12 dejando de ser
    // teoría: los dos temporizadores cuelgan del mismo contador libre, así que
    // `GTCCR.PSRSYNC` los afecta a los dos a la vez y arrancar uno no reinicia
    // la fase del otro.
    wire [7:0] t1_rd;
    wire       t1_sel;
    wire       t1_capt, t1_compa, t1_compb, t1_ovf;

    axioma_timer1 timer1 (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(t1_rd), .io_sel(t1_sel),
        .tick_1(tick_1), .tick_8(tick_8), .tick_64(tick_64),
        .tick_256(tick_256), .tick_1024(tick_1024),
        .t1_pin(pd_in[5]),                       // T1 es PD5
        // ICP1 es PB0, salvo que `ACIC` traiga la salida del comparador
        // analogico. Es lo que permite medir el tiempo entre dos cruces de
        // umbral sin que el programa tenga que mirar.
        .icp1_pin(ac_a_captura ? ac_o : pb_in[0]),
        .oc1a(oc1a), .oc1a_en(oc1a_en), .oc1b(oc1b), .oc1b_en(oc1b_en),
        .irq_capt(t1_capt), .irq_compa(t1_compa),
        .irq_compb(t1_compb), .irq_ovf(t1_ovf),
        .ack_capt(irq_ack_v[10]), .ack_compa(irq_ack_v[11]),
        .ack_compb(irq_ack_v[12]), .ack_ovf(irq_ack_v[13])
    );

    // ------------------------------------------------------------ USART0
    wire [7:0] us_rd;
    wire       us_sel;
    wire       us_rxc, us_udre, us_txc;

    axioma_usart usart (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(us_rd), .io_sel(us_sel),
        // TXD es PD1 y RXD es PD0, como en el encapsulado. Ya no hay puertos
        // aparte para el puerto serie: los dos pines son pines del puerto D,
        // con sus anulaciones, y eso es lo que hace que el programa pueda
        // usarlos como E/S general mientras la USART esté apagada.
        .rxd(pd_in[0]), .txd(us_txd), .txd_en(us_txen), .rx_en(us_rxen),
        // XCK vive en PD4. `pd_oe[4]` es DDRD4 ya resuelto, y PD4 NO lleva
        // anulación de dirección —sólo la llevan PD1 y PD0, aquí arriba—, así
        // que vale lo que el programa escribió, que es justo lo que la hoja de
        // datos quiere aquí: `DDR_XCK0` es lo que elige maestro o esclavo.
        .xck_pin(pd_in[4]), .xck_es_salida(pd_oe[4]),
        .xck_out(us_xck), .xck_ovr(us_xck_ovr),
        .irq_rxc(us_rxc), .irq_udre(us_udre), .irq_txc(us_txc),
        .ack_txc(irq_ack_v[20])
    );

    // ------------------------------------------------------------- Timer2
    // Prescaler PROPIO —no comparte el del Timer0 y el Timer1— y sin entrada de
    // reloj externo: donde el Timer0 tiene T0, éste tiene el oscilador de
    // TOSC1, que en el encapsulado es PB6.
    wire [7:0] t2_rd;
    wire       t2_sel;
    wire       t2_ovf, t2_compa, t2_compb;
    wire       presc_reset_asy;

    axioma_timer2 timer2 (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(t2_rd), .io_sel(t2_sel),
        .presc_reset(presc_reset_asy),
        .tosc(pb_in[6]),                         // TOSC1 es PB6
        .oc2a(oc2a), .oc2a_en(oc2a_en), .oc2b(oc2b), .oc2b_en(oc2b_en),
        .irq_ovf(t2_ovf), .irq_compa(t2_compa), .irq_compb(t2_compb),
        .ack_ovf(irq_ack_v[9]), .ack_compa(irq_ack_v[7]),
        .ack_compb(irq_ack_v[8])
    );

    // ---------------------------------------------------------------- SPI
    wire [7:0] sp_rd;
    wire       sp_sel, sp_irq;

    axioma_spi spi (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(sp_rd), .io_sel(sp_sel),
        // `pb_oe[2]` es DDB2 ya resuelto: PB2 sólo lleva anulación de
        // dirección cuando el SPI es esclavo, y ahí SS es entrada de todos
        // modos, así que fuera de ese caso vale exactamente lo que el programa
        // escribió en DDRB.
        .ss_es_salida(pb_oe[2]),
        .ss_pin(pb_in[2]), .sck_pin(pb_in[5]),
        .mosi_pin(pb_in[3]), .miso_pin(pb_in[4]),
        .sck_out(spi_sck),   .sck_oe(spi_sck_oe),
        .mosi_out(spi_mosi), .mosi_oe(spi_mosi_oe),
        .miso_out(spi_miso), .miso_oe(spi_miso_oe),
        .ss_oe_force(spi_ss_force),
        .irq_spi(sp_irq), .ack_spi(irq_ack_v[17])
    );

    // ---------------------------------------------------------------- TWI
    // Los seis registros viven en la I/O EXTENDIDA, 0xB8..0xBD, fuera del
    // alcance de IN/OUT. Se llega con LDS/STS y con LD/LDD, y por eso el dato
    // de lectura tiene que sobrevivir un ciclo: lo registra `axioma_dbus`.
    wire [7:0] tw_rd;
    wire       tw_sel, tw_irq;

    axioma_twi twi (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(tw_rd), .io_sel(tw_sel),
        .scl_pin(pc_in[5]), .sda_pin(pc_in[4]),
        .scl_pull(twi_scl_pull), .sda_pull(twi_sda_pull),
        .twen(twi_en),
        .irq(tw_irq)
    );

    // ---------------------------------------------------------------- ADC
    // El primero que no es digital de punta a punta. Sus seis registros viven
    // en la I/O EXTENDIDA, 0x78..0x7E, fuera del alcance de IN/OUT, igual que
    // los del TWI.
    //
    // `DIDR0` sale de aquí hacia el puerto C: son los seis bits que apagan el
    // bufer de entrada digital de ADC0..ADC5, o sea de PC0 a PC5.
    wire [7:0] ad_rd, adc_didr;
    wire       ad_sel, ad_irq, adc_acme, adc_encendido;

    axioma_adc adc (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(ad_rd), .io_sel(ad_sel),
        .adc_canal(adc_canal), .adc_ref(adc_ref),
        .adc_muestrea(adc_muestrea), .adc_dac(adc_dac), .adc_cmp(adc_cmp),
        .didr_dis(adc_didr),
        .adc_acme(adc_acme), .adc_encendido(adc_encendido),
        .irq_adc(ad_irq), .ack_adc(irq_ack_v[21])
    );

    // ------------------------------------------------------ perro guardian
    // Su reloj es propio, asi que el oscilador entra de fuera. `WDR` llega del
    // secuenciador como un pulso: la instruccion es un NOP para el nucleo y un
    // rearme para el vigilante.
    wire [7:0] wd_rd;
    wire       wd_sel, wd_irq;

    axioma_wdt wdt (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(wd_rd), .io_sel(wd_sel),
        .osc_tick(wdt_osc_tick),
        .wdr(core_wdr),
        .wdt_reset(wdt_reset),
        .irq_wdt(wd_irq), .ack_wdt(irq_ack_v[6])
    );

    // ------------------------------------------------- comparador analogico
    // Comparte el multiplexor del ADC -tabla 22-1- y puede llevar su salida a
    // la captura del Timer1 en lugar del pin ICP1. Las dos cosas las cablea el
    // SoC, que es quien tiene los dos extremos.
    wire [7:0] ac_rd, ac_didr;
    wire       ac_sel, ac_irq, ac_a_captura, ac_o;

    axioma_ac ac (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(ac_rd), .io_sel(ac_sel),
        .ac_apagado(ac_apagado), .ac_bandgap(ac_bandgap),
        .ac_neg_mux(ac_neg_mux), .ac_salida(ac_salida),
        .adc_acme(adc_acme), .adc_encendido(adc_encendido),
        .didr_dis(ac_didr),
        .ac_a_captura(ac_a_captura), .ac_o(ac_o),
        .irq_ac(ac_irq), .ack_ac(irq_ack_v[23])
    );

    // ---------------------------------------------- interrupciones externas
    // Los pines llegan tal como los ve el pad. INT0 e INT1 viven DENTRO del
    // puerto D —PD2 y PD3—, así que no se pasan aparte: un solo camino hasta
    // cada pin. PC7 no existe en el encapsulado y entra atado a cero.
    wire [7:0] ei_rd;
    wire       ei_sel;
    wire       ei_int0, ei_int1, ei_pc0, ei_pc1, ei_pc2;

    axioma_extint extint (
        .clk(clk), .rst_n(rst_n),
        .io_addr(io_addr), .io_re(io_re), .io_we(io_we), .io_wdata(io_wdata),
        .io_rdata(ei_rd), .io_sel(ei_sel),
        .pin_b(pb_in), .pin_c({1'b0, pc_in[6:0]}), .pin_d(pd_in),
        .irq_int0(ei_int0), .irq_int1(ei_int1),
        .irq_pcint0(ei_pc0), .irq_pcint1(ei_pc1), .irq_pcint2(ei_pc2),
        .ack_int0(irq_ack_v[1]),   .ack_int1(irq_ack_v[2]),
        .ack_pcint0(irq_ack_v[3]), .ack_pcint1(irq_ack_v[4]),
        .ack_pcint2(irq_ack_v[5])
    );

    // ------------------------------------------ combinación de las lecturas
    // Cada periférico deja su lectura a cero cuando no está seleccionado, así
    // que se combinan con un OR. `io_sel` dice si ALGUNO reclamó la dirección;
    // si no, el bus devuelve 0x00.
    //
    // QUE DOS PERIFÉRICOS RECLAMEN LA MISMA DIRECCIÓN sería un fallo silencioso:
    // el OR devolvería los dos valores mezclados. El espacio es enumerable —256
    // direcciones—, así que `sim/soc/tb_soc_map.cpp` lo barre entero y comprueba
    // que como mucho uno responde a cada una.
    assign io_rdata = gb_rd | gc_rd | gd_rd | gr_rd | ps_rd | tm_rd | t1_rd
                    | us_rd | ei_rd | t2_rd | sp_rd | tw_rd | ad_rd | ac_rd | wd_rd;
    assign io_sel   = gb_sel | gc_sel | gd_sel | gr_sel | ps_sel | tm_sel
                    | t1_sel | us_sel | ei_sel | t2_sel | sp_sel | tw_sel
                    | ad_sel | ac_sel | wd_sel;

    // ------------------------------------------- controlador de interrupciones
    // LOS ANCHOS DE ESTA CONCATENACIÓN SON EL MAPA DE VECTORES: 9 + 3 + 14 = 26.
    // Un bit de más abajo convierte TIMER0_COMPA en TIMER1_OVF y el núcleo salta
    // a otro sitio. Ya pasó. Lo comprueba tb_soc_map.cpp fuente por fuente.
    wire [25:0] irq_src;
    wire [25:0] irq_ack_v;
    wire        core_irq_req, core_irq_ack;
    wire [4:0]  core_irq_vector;
    wire        core_wdr;

    assign irq_src = { 1'b0,          // 25      SPM_READY, sin periférico
                       tw_irq,        // 24      TWI
                       ac_irq,        // 23      comparador analogico
                       1'b0,          // 22      EEPROM
                       ad_irq,        // 21      ADC
                       us_txc,        // 20      USART_TX
                       us_udre,       // 19      USART_UDRE
                       us_rxc,        // 18      USART_RX
                       sp_irq,        // 17      SPI_STC
                       tm_ovf,        // 16      TIMER0_OVF
                       tm_compb,      // 15      TIMER0_COMPB
                       tm_compa,      // 14      TIMER0_COMPA
                       t1_ovf,        // 13      TIMER1_OVF
                       t1_compb,      // 12      TIMER1_COMPB
                       t1_compa,      // 11      TIMER1_COMPA
                       t1_capt,       // 10      TIMER1_CAPT
                       t2_ovf,        // 9       TIMER2_OVF
                       t2_compb,      // 8       TIMER2_COMPB
                       t2_compa,      // 7       TIMER2_COMPA
                       wd_irq,        // 6       WDT
                       ei_pc2,        // 5       PCINT2
                       ei_pc1,        // 4       PCINT1
                       ei_pc0,        // 3       PCINT0
                       ei_int1,       // 2       INT1
                       ei_int0,       // 1       INT0
                       1'b0 };        // 0       RESET, que no es interrupción

    // Los reconocimientos de los vectores que aún no tienen periférico no van a
    // ninguna parte, igual que sus peticiones.
    // Los reconocimientos que no van a ninguna parte, y por qué:
    //   25, 23..21, 6, 0  vectores sin periférico todavía.
    //   24 (TWI)          TWINT no la limpia el vector: la limpia ESCRIBIR UN
    //                     UNO en ella, que es lo que arranca la operación
    //                     siguiente. Una ISR que se limitara a retornar
    //                     dejaría el bus estirado para siempre.
    //   19 (USART_UDRE)   su bandera no la limpia el vector: la limpia
    //                     ESCRIBIR UDR0, que es lo que hace la ISR.
    //   18 (USART_RX)     ídem, la limpia LEER UDR0.
    // Sólo TXC se limpia al atender su vector, y ése sí está conectado.
    wire unused_ack = &{1'b0, irq_ack_v[25:21], irq_ack_v[19:18],
                        irq_ack_v[6], irq_ack_v[0]};

    axioma_irq irqc (
        .src(irq_src),
        .irq_req(core_irq_req), .irq_vector(core_irq_vector),
        .irq_ack(core_irq_ack), .ack(irq_ack_v)
    );

    // El vector atendido, retenido para el arnés: durante los cuatro ciclos de
    // la entrada la petición ya ha desaparecido, porque el reconocimiento limpia
    // la bandera en el primero.
    reg [4:0] irq_vec_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)             irq_vec_q <= 5'd0;
        else if (core_irq_ack)  irq_vec_q <= core_irq_vector;
    end
    assign dbg_irq_vector = irq_vec_q;

    // ------------------------------------------------------------- núcleo
    axioma_core core (
        .clk(clk), .rst_n(rst_n),
        .pm_if_addr(pm_if_addr), .pm_if_en(pm_if_en), .pm_if_data(pm_if_data),
        .pm_d_addr(pm_d_addr), .pm_d_en(pm_d_en), .pm_d_we(pm_d_we),
        .pm_d_wdata(pm_d_wdata), .pm_d_rdata(pm_d_rdata),
        .dm_addr(dm_addr), .dm_re(dm_re), .dm_we(dm_we),
        .dm_wdata(dm_wdata), .dm_rdata(dm_rdata),
        .irq_req(core_irq_req), .irq_vector(core_irq_vector), .irq_ack(core_irq_ack),
        .dbg_pc(dbg_pc), .dbg_ir(dbg_ir), .dbg_retire(dbg_retire),
        .dbg_illegal(dbg_illegal), .dbg_irq_entry(dbg_irq_entry),
        .dbg_sp(dbg_sp), .dbg_sreg(dbg_sreg),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data)
    ,
        .wdr_pulso(core_wdr));

endmodule

`default_nettype wire
