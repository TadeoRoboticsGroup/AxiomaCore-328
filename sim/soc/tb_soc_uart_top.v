// AxiomaCore-328 - cáscara para el banco de extremo a extremo
// SPDX-License-Identifier: Apache-2.0
//
// El SoC entero con un programa de verdad dentro, y los pines a la vista para
// que el banco los lea como los leería un osciloscopio: el puerto serie por
// TXD y el LED por PORTB.
//
// Saca además la configuración del generador de baudios. No es para decodificar
// «con ventaja»: el banco decodifica con el ritmo que el PROGRAMA ha
// configurado, y luego comprueba aparte que ese ritmo esté dentro de la
// tolerancia del baudio nominal. Así se separan dos preguntas que no son la
// misma: si la trama está bien formada, y si va a la velocidad que debería.

`default_nettype none

module tb_soc_uart_top (
    input  wire        clk,
    input  wire        rst_n,

    // La línea de recepción la conduce el banco: es el PC hablándole al chip.
    input  wire        rxd,

    input  wire        prog_we,
    input  wire [13:0] prog_addr,
    input  wire [15:0] prog_data,

    output wire        txd,
    output wire        txd_en,
    output wire [7:0]  portb,
    output wire [7:0]  portb_oe,
    // El puerto D sale entero porque ahí viven los dos canales del Timer0:
    // OC0A en PD6 y OC0B en PD5.
    output wire [7:0]  portd,
    output wire [7:0]  portd_oe,
    // EL PUERTO C ES EL DEL TWI: SDA en PC4 y SCL en PC5. Lo que se saca es el
    // NIVEL DE LA LINEA -el pad ya resuelto-, que es lo que veria una sonda:
    // en un bus de colector abierto lo que importa no es quien conduce sino a
    // que altura esta el hilo.
    output wire [7:0]  portc_linea,
    output wire [7:0]  portc_oe,

    output wire [11:0] dbg_ubrr,
    output wire        dbg_u2x,
    // QUE MODO TIENE LA USART. Hace falta para no confundir el divisor de
    // MSPIM con el del puerto serie: los dos viven en UBRR0 y el banco mide el
    // periodo de bit con el que encuentre.
    output wire [1:0]  dbg_umsel
);

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
    wire [7:0] pd_in = {pd_in_libre, pd_oe[0] ? pd_out[0] : rxd};

    // EL PULL-UP DE PD0 NO SE APLICA AQUI, y es correcto: esa linea la conduce
    // el conversor USB-serie de la placa, y un pull-up interno no le gana a un
    // transistor de fuera. Se declara sin usar a proposito, no se borra del
    // SoC: el chip si lo declara, y en silicio la celda de pad lo conecta.
    wire unused_pd_pu0 = &{1'b0, pd_pu[0]};


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
        /* verilator lint_off PINCONNECTEMPTY */
        .dbg_pc(), .dbg_ir(), .dbg_retire(), .dbg_illegal(), .dbg_irq_entry(),
        .dbg_irq_vector(), .dbg_sp(), .dbg_sreg(), .dbg_reg_data(),
        /* verilator lint_on PINCONNECTEMPTY */
        .dbg_reg_addr(5'd0)
    );

    // TXD ES PD1, y ahora se observa como lo que es: un pin del puerto D.
    assign txd    = pd_out[1];
    assign txd_en = pd_oe[1];

    always @(posedge clk)
        if (prog_we) soc.pm.mem[prog_addr] <= prog_data;

    assign portb    = pb_out;
    assign portb_oe = pb_oe;
    assign portd    = pd_out;
    assign portd_oe = pd_oe;
    assign portc_linea = pc_in;
    assign portc_oe    = pc_oe;
    assign dbg_ubrr = soc.usart.ubrr;
    assign dbg_u2x  = soc.usart.u2x;
    assign dbg_umsel = soc.usart.umsel;

endmodule

`default_nettype wire
