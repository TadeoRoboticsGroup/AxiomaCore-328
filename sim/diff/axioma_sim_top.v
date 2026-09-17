// AxiomaCore-328 - cáscara de simulación sobre el SoC
// SPDX-License-Identifier: Apache-2.0
//
// NO forma parte del diseño, y ahora eso significa algo: el diseño es
// `rtl/soc/axioma328_soc.v`, y aquí sólo queda lo que un chip no tiene.
//
// Antes este fichero CONTENÍA la integración —el mapa de direcciones de I/O, el
// cableado de los 26 vectores, un array que fingía que toda la I/O era RAM—, de
// modo que la regresión verificaba un banco de pruebas y no el dispositivo. El
// desplazamiento de un bit que convertía TIMER0_COMPA en TIMER1_OVF estaba
// justo aquí. Ya no: la integración es diseño, y tiene su propio banco
// exhaustivo en `sim/soc/tb_soc_map.cpp`.
//
// Lo que queda aquí, y por qué:
//
//   1. EL MODELO DE PAD. El SoC saca dato, dirección y declaración de pull-up,
//      como una celda de pad de verdad; cerrar el lazo es cosa de fuera. Sin
//      nada conectado por fuera:
//        - un pin de SALIDA se lee a sí mismo;
//        - uno de ENTRADA con el pull-up activado se lee 1, que es lo que hace
//          un chip real;
//        - uno de entrada sin pull-up queda flotando y se modela como 0.
//      Las tres cosas juntas equivalen a que el pad siga a PORTx, pero se
//      escriben por separado porque en la FPGA son bits distintos del bloque
//      de E/S.
//
//   2. LA CARGA DEL PROGRAMA, por la puerta de atrás. El 328P no tiene un
//      puerto para que alguien le escriba la Flash desde fuera —se programa por
//      SPI o por el bootloader—, así que meterle uno al SoC sería inventar
//      hardware que no existe. En su lugar se escribe directamente en la
//      memoria por referencia jerárquica, que es lo que hace un banco de
//      pruebas. En la FPGA el programa va precargado en el bitstream con el
//      parámetro INIT_HEX.
//
//   3. LAS TOMAS DE OBSERVACIÓN de la memoria de datos, para que el arnés pueda
//      barrer la SRAM y los registros comparables al terminar cada programa.
//      Van por referencia jerárquica por el mismo motivo: no son hardware.

`default_nettype none

module axioma_sim_top (
    input  wire        clk,
    input  wire        rst_n,

    // Carga de programa, sólo simulación
    input  wire        prog_we,
    input  wire [13:0] prog_addr,
    input  wire [15:0] prog_data,

    // Observación
    output wire [13:0] dbg_pc,
    output wire [15:0] dbg_ir,
    output wire        dbg_retire,
    output wire        dbg_illegal,
    output wire        dbg_irq_entry,
    output wire [4:0]  dbg_irq_vector,
    output wire [15:0] dbg_sp,
    output wire [7:0]  dbg_sreg,
    input  wire [4:0]  dbg_reg_addr,
    output wire [7:0]  dbg_reg_data,
    input  wire [15:0] dbg_mem_addr,
    output wire [7:0]  dbg_mem_data
);

    localparam [15:0] IO_BASE   = 16'h0020;
    localparam [15:0] SRAM_BASE = 16'h0100;
    localparam [15:0] SRAM_END  = 16'h08FF;

    // ------------------------------------------------------ modelo de pad
    wire [7:0] pb_out, pb_oe, pb_pu, pc_out, pc_oe, pc_pu, pd_out, pd_oe, pd_pu;

    wire [7:0] pb_in = (pb_out & pb_oe) | (pb_pu & ~pb_oe);
    wire [7:0] pc_in = (pc_out & pc_oe) | (pc_pu & ~pc_oe);
    wire [7:1] pd_in_libre = (pd_out[7:1] & pd_oe[7:1])
                           | (pd_pu[7:1] & ~pd_oe[7:1]);
    // EL PAD DE PD0 LO CONDUCE ALGUIEN DE FUERA. En el resto de los pines, con
    // nada conectado, un pin de entrada sin pull-up queda flotando y se modela
    // como cero. En PD0 eso no vale: ahí está la línea de recepción del puerto
    // serie, y un cero permanente es un bit de arranque permanente — el
    // receptor se pondría a meter tramas de 0x00 sin parar. En una placa esa
    // línea la conduce el conversor USB-serie, y en reposo vale uno.
    wire [7:0] pd_in = {pd_in_libre, pd_oe[0] ? pd_out[0] : 1'b1};

    // EL PULL-UP DE PD0 NO SE APLICA AQUI, y es correcto: esa linea la conduce
    // el conversor USB-serie de la placa, y un pull-up interno no le gana a un
    // transistor de fuera. Se declara sin usar a proposito, no se borra del
    // SoC: el chip si lo declara, y en silicio la celda de pad lo conecta.
    wire unused_pd_pu0 = &{1'b0, pd_pu[0]};

    // ------------------------------------------------------------ el chip

    // ------------------------------------------- el frente analogico del ADC
    // No es parte del chip (ADR 0002): el SoC saca las cinco senales y quien lo
    // instancia decide que cuelga de ellas. Aqui cuelga el modelo digital.
    wire [3:0] adc_canal;
    wire [1:0] adc_ref;
    wire       adc_muestrea, adc_cmp;
    wire [9:0] adc_dac;

    axioma_adc_frente frente (
        .clk(clk), .rst_n(rst_n),
        .canal(adc_canal), .ref_sel(adc_ref), .muestrea(adc_muestrea),
        .dac(adc_dac), .cmp(adc_cmp)
    );

    axioma328_soc soc (
        .clk(clk), .rst_n(rst_n),
        .pb_in(pb_in), .pb_out(pb_out), .pb_oe(pb_oe), .pb_pu(pb_pu),
        .pc_in(pc_in), .pc_out(pc_out), .pc_oe(pc_oe), .pc_pu(pc_pu),
        .pd_in(pd_in), .pd_out(pd_out), .pd_oe(pd_oe), .pd_pu(pd_pu),
        .adc_canal(adc_canal), .adc_ref(adc_ref),
        .adc_muestrea(adc_muestrea), .adc_dac(adc_dac), .adc_cmp(adc_cmp),
        // Ya no hay ningún puerto sin conectar que silenciar: el puerto serie
        // dejó de tener puertos propios y salió de aquí con él la excepción.
        .dbg_pc(dbg_pc), .dbg_ir(dbg_ir), .dbg_retire(dbg_retire),
        .dbg_illegal(dbg_illegal), .dbg_irq_entry(dbg_irq_entry),
        .dbg_irq_vector(dbg_irq_vector), .dbg_sp(dbg_sp), .dbg_sreg(dbg_sreg),
        .dbg_reg_addr(dbg_reg_addr), .dbg_reg_data(dbg_reg_data)
    );

    // ------------------------------------------- carga por la puerta de atrás
    always @(posedge clk)
        if (prog_we) soc.pm.mem[prog_addr] <= prog_data;

    // ---------------- lectura de observación, sin perturbar al núcleo -------
    // Los registros de un periférico hay que leerlos DE su periférico: en el
    // espacio de datos ya no hay ningún array donde mirarlos.
    wire [7:0] dbg_io_index = dbg_mem_addr[7:0] - IO_BASE[7:0];
    wire       dbg_in_io    = (dbg_mem_addr >= IO_BASE) && (dbg_mem_addr < SRAM_BASE);

    reg [7:0] dbg_periph;
    always @(*) begin
        case (dbg_io_index)
            8'h03:   dbg_periph = soc.gpio_b.sync1;
            8'h04:   dbg_periph = soc.gpio_b.ddr_q;
            8'h05:   dbg_periph = soc.gpio_b.port_q;
            8'h06:   dbg_periph = soc.gpio_c.sync1;
            8'h07:   dbg_periph = soc.gpio_c.ddr_q;
            8'h08:   dbg_periph = soc.gpio_c.port_q;
            8'h09:   dbg_periph = soc.gpio_d.sync1;
            8'h0A:   dbg_periph = soc.gpio_d.ddr_q;
            8'h0B:   dbg_periph = soc.gpio_d.port_q;
            8'h15:   dbg_periph = {5'b0, soc.timer0.motor.tifr_q};
            8'h1E:   dbg_periph = soc.gpior.r0;
            8'h23:   dbg_periph = {soc.presc.tsm_q, 5'b0,
                                   soc.presc.psrasy_q, soc.presc.psrsync_q};
            8'h24:   dbg_periph = {soc.timer0.motor.com_q, 2'b00,
                                   soc.timer0.motor.wgm_q[1:0]};
            8'h25:   dbg_periph = {4'b0000, soc.timer0.motor.wgm_q[2],
                                   soc.timer0.cs_q};
            8'h26:   dbg_periph = soc.timer0.motor.tcnt_q;
            8'h27:   dbg_periph = soc.timer0.motor.ocra_buf;
            8'h28:   dbg_periph = soc.timer0.motor.ocrb_buf;
            8'h2A:   dbg_periph = soc.gpior.r1;
            8'h2B:   dbg_periph = soc.gpior.r2;
            8'h4E:   dbg_periph = {5'b0, soc.timer0.motor.timsk_q};
            // SPI. Sólo SPCR entra en la comparación —ver la tabla COMPARABLE
            // de diff.cpp—, pero la ventana da los tres: si algún día SPSR o
            // SPDR se vuelven comparables, ya están.
            8'h2C:   dbg_periph = {soc.spi.spie_q, soc.spi.spe_q,
                                   soc.spi.dord_q, soc.spi.mstr_q,
                                   soc.spi.cpol_q, soc.spi.cpha_q,
                                   soc.spi.spr_q};
            8'h2D:   dbg_periph = {soc.spi.spif_q, soc.spi.wcol_q, 5'b0,
                                   soc.spi.spi2x_q};
            8'h2E:   dbg_periph = soc.spi.rxbuf_q;
            // TWI. Comparables sólo TWBR, TWAR y TWAMR —ver COMPARABLE en
            // diff.cpp—, pero la ventana da los seis. TWSR se compone igual
            // que en el bus: el estado arriba, un cero, y TWPS abajo.
            8'h98:   dbg_periph = soc.twi.twbr_q;
            8'h99:   dbg_periph = {soc.twi.status_q, 1'b0, soc.twi.twps_q};
            8'h9A:   dbg_periph = soc.twi.twar_q;
            8'h9B:   dbg_periph = soc.twi.twdr_q;
            8'h9C:   dbg_periph = {soc.twi.twint_q, soc.twi.twea_q,
                                   soc.twi.twsta_q, soc.twi.twsto_q,
                                   soc.twi.twwc_q,  soc.twi.twen_q,
                                   1'b0, soc.twi.twie_q};
            8'h9D:   dbg_periph = soc.twi.twamr_q;
            // Timer2: mismo motor que el Timer0, en sus propias direcciones.
            8'h17:   dbg_periph = {5'b0, soc.timer2.motor.tifr_q};
            8'h50:   dbg_periph = {5'b0, soc.timer2.motor.timsk_q};
            8'h90:   dbg_periph = {soc.timer2.motor.com_q, 2'b00,
                                   soc.timer2.motor.wgm_q[1:0]};
            8'h91:   dbg_periph = {4'b0000, soc.timer2.motor.wgm_q[2],
                                   soc.timer2.cs_q};
            8'h92:   dbg_periph = soc.timer2.motor.tcnt_q;
            8'h93:   dbg_periph = soc.timer2.motor.ocra_buf;
            8'h94:   dbg_periph = soc.timer2.motor.ocrb_buf;
            8'h96:   dbg_periph = {1'b0, soc.timer2.exclk_q, soc.timer2.as2_q,
                                   5'b0};
            // Del Timer1, la ventana devuelve el valor REAL de cada registro,
            // no lo que devolvería el bus: leer un byte alto por el bus da el
            // TEMP, y aquí lo que se quiere comparar contra simavr es lo que el
            // registro guarda.
            8'h16:   dbg_periph = {2'b0, soc.timer1.icf, 2'b0, soc.timer1.tifr};
            8'h4F:   dbg_periph = {2'b0, soc.timer1.icie, 2'b0, soc.timer1.timsk};
            8'h60:   dbg_periph = {soc.timer1.com, 2'b00, soc.timer1.wgm[1:0]};
            8'h61:   dbg_periph = {soc.timer1.icnc, soc.timer1.ices, 1'b0,
                                   soc.timer1.wgm[3], soc.timer1.wgm[2],
                                   soc.timer1.cs};
            8'h62:   dbg_periph = 8'h00;
            8'h64:   dbg_periph = soc.timer1.tcnt[7:0];
            8'h65:   dbg_periph = soc.timer1.tcnt[15:8];
            8'h66:   dbg_periph = soc.timer1.icr[7:0];
            8'h67:   dbg_periph = soc.timer1.icr[15:8];
            8'h68:   dbg_periph = soc.timer1.ocra_buf[7:0];
            8'h69:   dbg_periph = soc.timer1.ocra_buf[15:8];
            8'h6A:   dbg_periph = soc.timer1.ocrb_buf[7:0];
            8'h6B:   dbg_periph = soc.timer1.ocrb_buf[15:8];
            8'hA1:   dbg_periph = {soc.usart.rxcie, soc.usart.txcie,
                                   soc.usart.udrie, soc.usart.rxen,
                                   soc.usart.txen,  soc.usart.ucsz2,
                                   1'b0, soc.usart.txb8};
            8'hA2:   dbg_periph = {soc.usart.umsel, soc.usart.upm,
                                   soc.usart.usbs, soc.usart.ucsz10,
                                   soc.usart.ucpol};
            8'hA4:   dbg_periph = soc.usart.ubrr[7:0];
            8'hA5:   dbg_periph = {4'b0, soc.usart.ubrr[11:8]};
            // Sin implementar: se lee como cero, igual que en el chip.
            default: dbg_periph = 8'h00;
        endcase
    end

    assign dbg_mem_data =
        (dbg_mem_addr >= SRAM_BASE && dbg_mem_addr <= SRAM_END)
            ? soc.dm.mem[dbg_mem_addr[10:0] - SRAM_BASE[10:0]]
        : dbg_in_io ? dbg_periph
        : 8'h00;

endmodule

`default_nettype wire
