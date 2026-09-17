// AxiomaCore-328 - modelo DIGITAL del frente analogico del ADC
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// ESTO NO ES PARTE DEL DISPOSITIVO. El ADR 0002 deja el multiplexor, la
// referencia, el sample & hold, el DAC y el comparador FUERA del RTL del chip,
// detras de cinco senales. En el flujo ASIC esas senales van al macro analogico
// del PDK. Pero una FPGA no convierte tensiones, y los bancos de simulacion
// tampoco tienen ninguna: hace falta algo al otro lado del cable.
//
// Esto es ese algo, y vive aqui —en `rtl/fpga/`, no en `rtl/soc/`— a proposito:
// quien instancia el SoC decide que cuelga de esas cinco senales, igual que
// decide que celda de pad va en cada pin.
//
// LO QUE SI ES DE VERDAD: el comparador. Responde `retenida >= dac`, que es lo
// que dice la hoja de datos, y el S/H retiene en el pulso `muestrea`. Con eso,
// el SAR del chip aproxima EXACTAMENTE igual que con un comparador de silicio
// —las mismas diez decisiones, en los mismos ciclos— y lo unico sintetico es de
// donde sale la tension.
//
// LO QUE ES UN INVENTO, y conviene que se sepa: la tension de cada canal. Aqui
// es una constante por canal, escalonada para que dos canales nunca den el
// mismo numero y un multiplexor cruzado se note. En una placa de verdad seria
// lo que haya en el pin; en el ECP5 no hay pin analogico que valga.
//
// Y LA REFERENCIA TAMBIEN SE MODELA, porque si no seria un puerto sin usar y el
// mutante que la ignorase sobreviviria. `REFS`=11 es la interna de 1,1 V, o sea
// un fondo de escala cuatro veces menor que AVCC: la misma tension da un codigo
// cuatro veces mayor, saturado a 1023. Es una aproximacion, y como toda esta
// caja, un modelo — la linealidad de verdad se mide en el macro, no aqui.

`default_nettype none

module axioma_adc_frente (
    input  wire       clk,
    input  wire       rst_n,

    input  wire [3:0] canal,
    input  wire [1:0] ref_sel,
    input  wire       muestrea,
    input  wire [9:0] dac,
    output wire       cmp
);

    // Una constante por canal, escalonada: canal 0 = 32, canal 1 = 96, ... y el
    // 15 = 992. Ningun par de canales coincide, asi que cruzar el multiplexor
    // cambia el numero.
    wire [9:0] v_canal = {canal, 6'd32};

    // La referencia interna de 1,1 V tiene un fondo de escala unas cuatro veces
    // menor que AVCC, asi que la misma tension da un codigo cuatro veces mayor.
    wire [11:0] v_escalado = (ref_sel == 2'b11) ? {v_canal, 2'b00}
                                                : {2'b00, v_canal};
    wire [9:0]  v_entrada  = (v_escalado[11:10] != 2'b00) ? 10'd1023
                                                          : v_escalado[9:0];

    reg [9:0] retenida;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        retenida <= 10'd0;
        else if (muestrea) retenida <= v_entrada;
    end

    assign cmp = (retenida >= dac);

endmodule

`default_nettype wire
