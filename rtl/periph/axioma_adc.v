// AxiomaCore-328 - ADC: el controlador de aproximaciones sucesivas
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// El periférico del `analogRead()`. Y el primero del proyecto que NO ES DIGITAL
// DE PUNTA A PUNTA: aquí dentro vive el registro de aproximaciones sucesivas y
// su secuenciador, y el DAC y el comparador se quedan FUERA, detrás de cinco
// señales. Dónde se corta y por qué está razonado en
// docs/adr/0002-frontera-analogica-del-adc.md; el resumen es que ése es el
// corte que dibuja la figura 23-1 de la hoja de datos, y que un módulo que
// recibiera el valor ya convertido no sería un ADC sino un registro con retardo.
//
//   ADCL    dato 0x78   los ocho bits bajos del resultado
//   ADCH    dato 0x79   los dos altos -o los ocho altos con ADLAR-
//   ADCSRA  dato 0x7A   ADEN ADSC ADATE ADIF ADIE ADPS2 ADPS1 ADPS0
//   ADCSRB  dato 0x7B   -- ACME -- -- -- ADTS2 ADTS1 ADTS0
//   ADMUX   dato 0x7C   REFS1 REFS0 ADLAR -- MUX3 MUX2 MUX1 MUX0
//   DIDR0   dato 0x7E   ADC5D..ADC0D: apagar el bufer de entrada DIGITAL
//
// LA APROXIMACIÓN SUCESIVA, QUE ES DE LO QUE VA ESTE MÓDULO. Se prueba el bit
// más significativo: se pone a uno, se pregunta al comparador si la tensión
// retenida sigue siendo mayor que la del DAC, y si no lo es el bit se cae. Diez
// veces, de peso 9 a peso 0. Al final el registro contiene el código.
//
// Escrito así, el banco puede comprobar LAS DIEZ DECISIONES en vez de mirar si
// el número final salió bien — que es la diferencia entre verificar un ADC y
// verificar un contador con suerte.
//
// LOS CICLOS SON DE LA TABLA 23-1 Y NO SON REDONDOS. Una conversión normal dura
// **13 ciclos de reloj de ADC**; la PRIMERA tras poner `ADEN` dura **25**,
// porque el convertidor se inicializa. Y el muestreo no cae en un ciclo entero:
// el S/H cierra a **1,5** ciclos en una conversión normal y a **13,5** en la
// primera. Por eso aquí se cuenta en MEDIOS CICLOS de ADC —26 y 50— y no en
// ciclos: con enteros, el instante del muestreo no se puede escribir.
//
// Que eso importe no es teoría: dos conversiones seguidas de una señal que se
// mueve dan valores distintos, y cuál da cada una depende de cuándo cerró el
// S/H. Un programa que muestrea una senoide lo nota; un banco que sólo mire
// tensiones quietas, no.
//
// EL PRESCALER NO ES UN DIVISOR CUALQUIERA: la tabla dice que `ADPS`=0 y
// `ADPS`=1 dan los dos la división por 2. No es una errata de la hoja de datos
// —es que el contador no tiene toma para /1—, y copiarlo mal da un ADC que
// corre al doble en una configuración que medio mundo deja a cero.
//
// EL CERROJO DE ADCL/ADCH, que es la trampa que se lleva por delante a quien lee
// los registros al revés. Leer `ADCL` BLOQUEA la actualización de los dos
// registros de datos hasta que se lee `ADCH`. Sin eso, una conversión que
// termine entre las dos lecturas mezcla el byte bajo de una con el alto de otra
// y da un valor que no existió nunca. La hoja de datos lo dice con todas las
// letras, y por eso avr-libc lee siempre `ADCL` primero.
//
// SIMAVR NO SIRVE DE ORÁCULO AQUÍ, y menos que con ningún otro periférico:
// `avr_adc.c` programa la interrupción a `prescale * 11` ciclos —el manual dice
// 13— y entrega el valor de golpe desde una IRQ en milivoltios. No hay ninguna
// aproximación sucesiva en ninguna parte. El oráculo es el banco propio, con un
// comparador escrito desde la hoja de datos.
//
// EL DISPARO AUTOMÁTICO, que es `ADATE` con los tres bits de `ADTS`. Ocho
// fuentes, y la que se elige entra por `adc_trig` indexada por el propio valor
// de `ADTS` — el índice ES el número de la tabla 23-6, que es lo que hace que
// una fuente mal cableada se vea leyendo una línea:
//
//   000  modo libre         la conversión se rearma sola al terminar
//   001  comparador analógico (ACI)      101  Timer1 comparación B (OCF1B)
//   010  INT0 (INTF0)                    110  Timer1 desbordamiento (TOV1)
//   011  Timer0 comparación A (OCF0A)    111  Timer1 captura (ICF1)
//   100  Timer0 desbordamiento (TOV0)
//
// DISPARA EL FLANCO DE SUBIDA DE LA BANDERA, no su nivel, y eso tiene dos
// consecuencias que la hoja de datos menciona y que casi nadie implementa:
//
//   - la bandera dispara AUNQUE SU INTERRUPCIÓN ESTÉ DESHABILITADA, así que lo
//     que llega aquí son las banderas CRUDAS y no las peticiones de vector;
//   - «switching from a trigger source that is cleared to a trigger source that
//     is set will generate a positive edge on the trigger signal»: cambiar
//     `ADTS` es en sí mismo un flanco si la fuente nueva ya estaba puesta. Aquí
//     sale gratis porque lo que se vigila es la salida del multiplexor.
//
// EN MODO LIBRE LA PRIMERA CONVERSIÓN LA ARRANCA EL PROGRAMA con `ADSC`, y a
// partir de ahí se rearma sola. No es un detalle: un ADC que empezara a
// convertir en cuanto se pone `ADATE` no dejaría configurar `ADMUX` antes.

`default_nettype none

module axioma_adc (
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
    output wire [3:0] adc_canal,    // MUX3:0 — qué mira el multiplexor
    output wire [1:0] adc_ref,      // REFS1:0 — qué referencia alimenta el DAC
    output wire       adc_muestrea, // pulso: el S/H cierra y RETIENE
    output wire [9:0] adc_dac,      // el código que el SAR está probando
    input  wire       adc_cmp,      // 1 si la tensión retenida >= la del DAC

    // ---- el bufer de entrada digital, que DIDR0 apaga ----
    output wire [7:0] didr_dis,

    // ---- lo que el COMPARADOR ANALOGICO necesita de aqui ----
    // `ACME` vive en `ADCSRB`, que es un registro de este modulo, pero a quien
    // le sirve es al comparador: con el puesto y el ADC apagado, la entrada
    // negativa del comparador sale de ESTE multiplexor. La tabla 22-1 lo decide
    // con los dos bits, asi que los dos salen de aqui.
    output wire       adc_acme,
    output wire       adc_encendido,

    // ---- las ocho fuentes del disparo automático ----
    // Indexadas por el valor de `ADTS`: `adc_trig[n]` es la fuente n de la
    // tabla 23-6. El bit 0 no se usa —el modo libre no tiene bandera, se rearma
    // solo— y el SoC lo ata a cero.
    input  wire [7:0] adc_trig,

    // ---- interrupción ----
    output wire       irq_adc,      // vector 21
    input  wire       ack_adc
);

    localparam [7:0] A_ADCL   = 8'h58;   // dato 0x78
    localparam [7:0] A_ADCH   = 8'h59;
    localparam [7:0] A_ADCSRA = 8'h5A;
    localparam [7:0] A_ADCSRB = 8'h5B;
    localparam [7:0] A_ADMUX  = 8'h5C;
    localparam [7:0] A_DIDR0  = 8'h5E;

    wire hit_l    = (io_addr == A_ADCL);
    wire hit_h    = (io_addr == A_ADCH);
    wire hit_sra  = (io_addr == A_ADCSRA);
    wire hit_srb  = (io_addr == A_ADCSRB);
    wire hit_mux  = (io_addr == A_ADMUX);
    wire hit_didr = (io_addr == A_DIDR0);

    assign io_sel = hit_l | hit_h | hit_sra | hit_srb | hit_mux | hit_didr;

    // ---------------------------------------------------------- registros
    reg        aden, adsc, adate, adif, adie;
    reg [2:0]  adps;
    reg        acme;
    reg [2:0]  adts;
    reg [1:0]  refs;
    reg        adlar;
    reg [3:0]  mux;
    reg [5:0]  didr;

    // ------------------------------------------------------- el prescaler
    // ADPS=0 y ADPS=1 dan LOS DOS la division por 2: lo dice la tabla y no es
    // una errata. Se cuenta en MEDIOS ciclos de ADC, asi que el contador divide
    // por la mitad del factor -de 1 a 64-, y con /2 un medio ciclo es un ciclo
    // de sistema.
    wire [6:0] medio_div = (adps == 3'd0) ? 7'd1  :
                           (adps == 3'd1) ? 7'd1  :
                           (adps == 3'd2) ? 7'd2  :
                           (adps == 3'd3) ? 7'd4  :
                           (adps == 3'd4) ? 7'd8  :
                           (adps == 3'd5) ? 7'd16 :
                           (adps == 3'd6) ? 7'd32 : 7'd64;

    reg  [6:0] presc;
    wire       medio_tick = (presc == 7'd1);

    // EL PRESCALER SE MANTIENE A CERO MIENTRAS ADEN ESTE APAGADO, que es lo que
    // dice la hoja de datos: el contador arranca cuando se enciende el ADC. Sin
    // esto, la primera conversion empezaria con una fase cualquiera y su
    // duracion medida saldria distinta cada vez.
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)          presc <= 7'd1;
        else if (!aden)      presc <= medio_div;
        else if (medio_tick) presc <= medio_div;
        else                 presc <= presc - 7'd1;
    end

    // ------------------------------------------------- el secuenciador
    // En MEDIOS ciclos de ADC: 26 una conversion normal -13 ciclos- y 50 la
    // primera tras ADEN -25-. El S/H cierra a 1,5 ciclos, o sea en el medio
    // ciclo numero 3; en la primera, a 13,5, o sea en el 27.
    reg        primera;         // la proxima conversion es la larga
    reg        conv;            // hay una conversion en marcha
    reg [5:0]  mitad;           // medio ciclo dentro de la conversion
    reg [9:0]  sar_q;
    reg [3:0]  peso;            // que bit se esta probando, de 9 a 0
    reg        mues_q;

    wire [5:0] sh_en    = primera ? 6'd27 : 6'd3;
    wire [5:0] total    = primera ? 6'd50 : 6'd26;

    // El codigo que se presenta al DAC: lo ya decidido, mas el bit en prueba.
    wire [9:0] dac_prueba = sar_q | (10'd1 << peso);
    assign adc_dac = conv ? dac_prueba : 10'd0;

    // Las DIEZ decisiones caen una por ciclo de ADC -dos medios-, empezando un
    // ciclo entero despues del muestreo para que el comparador se asiente.
    //
    // Y caen en los medios ciclos IMPARES, que no es casualidad: el S/H cierra
    // a 1,5 ciclos -o a 13,5-, o sea en un medio ciclo impar, y de ahi en
    // adelante se avanza de dos en dos. Que el instante de muestreo sea medio
    // ciclo es justo lo que pone las decisiones donde estan.
    wire       decidir = conv && (mitad > sh_en) && (mitad <= sh_en + 6'd20)
                              && mitad[0];

    // ------------------------------------------------- el cerrojo de datos
    // LEER ADCL BLOQUEA los dos registros de datos hasta que se lea ADCH. Sin
    // esto, una conversion que termine entre las dos lecturas mezcla el byte
    // bajo de una con el alto de otra y da un valor que no existio nunca.
    reg        cerrojo;
    reg [9:0]  dato;

    wire       lee_l = io_re && hit_l;
    wire       lee_h = io_re && hit_h;

    wire [9:0] resultado = sar_q;
    wire       fin = conv && medio_tick && (mitad == total);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            conv <= 1'b0;  mitad <= 6'd0;  sar_q <= 10'd0;  peso <= 4'd9;
            primera <= 1'b1;  mues_q <= 1'b0;  dato <= 10'd0;  cerrojo <= 1'b0;
        end else begin
            mues_q <= 1'b0;

            // Apagar el ADC aborta lo que hubiera y rearma la conversion larga.
            if (!aden) begin
                conv    <= 1'b0;
                primera <= 1'b1;
            end else if (medio_tick && !conv) begin
                // LA CONVERSION ARRANCA EN UN FLANCO DEL RELOJ DE ADC, no en
                // cuanto se escribe ADSC: «the conversion starts at the
                // following rising edge of the ADC clock cycle after ADSC is
                // written». No es un detalle de estilo — si arranca a
                // destiempo, la cuenta de medios ciclos empieza con un trozo de
                // periodo ya gastado y la conversion dura MENOS de los 13
                // ciclos prometidos. Se midio: salian 12,5.
                if (adsc) begin
                    conv  <= 1'b1;
                    mitad <= 6'd1;      // este flanco YA es el primer medio ciclo
                    peso  <= 4'd9;
                    sar_q <= 10'd0;
                end
            end else if (conv && medio_tick) begin
                mitad <= mitad + 6'd1;

                if (mitad == sh_en) begin
                    // El S/H cierra: a partir de aqui la tension esta quieta.
                    mues_q <= 1'b1;
                    sar_q  <= 10'd0;
                    peso   <= 4'd9;
                end else if (decidir) begin
                    // El comparador ha tenido un ciclo entero para asentarse.
                    if (adc_cmp) sar_q <= dac_prueba;
                    peso <= peso - 4'd1;
                end

                if (mitad == total) begin
                    conv    <= 1'b0;
                    primera <= 1'b0;
                    // El resultado solo entra en los registros de datos si el
                    // programa no los tiene bloqueados a medio leer.
                    if (!cerrojo) dato <= resultado;
                end
            end

            // El cerrojo se echa al leer ADCL y se suelta al leer ADCH.
            if (lee_l)      cerrojo <= 1'b1;
            else if (lee_h) cerrojo <= 1'b0;
        end
    end

    assign adc_muestrea = mues_q;
    assign adc_canal    = mux;
    assign adc_ref      = refs;
    assign didr_dis     = {2'b00, didr};

    // ------------------------------------------------------------- lectura
    // ADLAR alinea el resultado a la IZQUIERDA. Es lo que permite leer solo
    // ADCH cuando ocho bits bastan, que es lo que hace medio codigo de Arduino
    // con sensores ruidosos.
    wire [15:0] alineado = adlar ? {dato, 6'd0} : {6'd0, dato};

    wire [7:0] r_adcsra = {aden, adsc, adate, adif, adie, adps};
    wire [7:0] r_adcsrb = {1'b0, acme, 3'b000, adts};
    wire [7:0] r_admux  = {refs, adlar, 1'b0, mux};

    assign io_rdata = hit_l    ? alineado[7:0]      :
                      hit_h    ? alineado[15:8]     :
                      hit_sra  ? r_adcsra           :
                      hit_srb  ? r_adcsrb           :
                      hit_mux  ? r_admux            :
                      hit_didr ? {2'b00, didr}      : 8'h00;

    // ------------------------------------------- el disparo automatico
    // La fuente elegida sale del multiplexor indexado por ADTS. El modo libre
    // -ADTS=000- no tiene bandera: se rearma al terminar la conversion.
    wire libre     = (adts == 3'd0);
    wire trig_sel  = libre ? 1'b0 : adc_trig[adts];

    reg  trig_q;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) trig_q <= 1'b0;
        else        trig_q <= trig_sel;
    end

    // EL FLANCO DE SUBIDA, no el nivel. Y como lo que se vigila es la SALIDA del
    // multiplexor, cambiar ADTS a una fuente que ya estaba puesta genera un
    // flanco — que es literalmente lo que dice la hoja de datos.
    wire trig_flanco = trig_sel & ~trig_q;

    // En modo libre el rearme es el propio final de la conversion anterior.
    wire auto_dispara = aden & adate & (libre ? fin : trig_flanco);

    // ------------------------------------------------------------ escritura
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            aden <= 1'b0;  adsc <= 1'b0;  adate <= 1'b0;  adif <= 1'b0;
            adie <= 1'b0;  adps <= 3'd0;  acme <= 1'b0;   adts <= 3'd0;
            refs <= 2'd0;  adlar <= 1'b0; mux <= 4'd0;    didr <= 6'd0;
        end else begin
            if (io_we && hit_sra) begin
                aden  <= io_wdata[7];
                // ADSC se pone escribiendo un uno; escribir un cero NO lo para.
                // Lo dice la hoja de datos: «writing zero to this bit has no
                // effect».
                //
                // Y NO SE MIRA AQUI SI EL ADC ESTA ENCENDIDO, aunque lo parezca
                // necesario: de eso se encarga el `if (!aden) adsc <= 0` de mas
                // abajo, que ademas cubre el caso de apagar el ADC a mitad de
                // una conversion. Se probo con las dos guardas y la mutacion lo
                // dijo: el mutante que quitaba esta SOBREVIVIA, porque la otra
                // ya lo impedia. Dos mecanismos para lo mismo es uno de mas.
                if (io_wdata[6]) adsc <= 1'b1;
                adate <= io_wdata[5];
                // ADIF es de las que se limpian ESCRIBIENDO UN UNO.
                if (io_wdata[4]) adif <= 1'b0;
                adie  <= io_wdata[3];
                adps  <= io_wdata[2:0];
            end
            if (io_we && hit_srb) begin
                acme <= io_wdata[6];
                adts <= io_wdata[2:0];
            end
            if (io_we && hit_mux) begin
                refs  <= io_wdata[7:6];
                adlar <= io_wdata[5];
                mux   <= io_wdata[3:0];
            end
            if (io_we && hit_didr) didr <= io_wdata[5:0];

            // El hardware manda sobre ADSC y ADIF al terminar la conversion, y
            // va DESPUES de la escritura: si el programa limpia ADIF en el
            // mismo ciclo en que la conversion acaba, gana el hardware, que es
            // lo que hace el chip -y lo que evita perder una interrupcion-.
            if (fin) begin
                adsc <= 1'b0;
                adif <= 1'b1;
            end
            if (!aden) adsc <= 1'b0;
            // Y EL DISPARO AUTOMATICO VA DESPUES DEL FINAL, porque en modo libre
            // las dos cosas caen en el mismo flanco: la conversion termina y la
            // siguiente arranca. Al reves, el rearme se perderia siempre.
            if (auto_dispara) adsc <= 1'b1;
            // Atender el vector limpia la bandera en su origen.
            if (ack_adc) adif <= 1'b0;
        end
    end

    assign adc_acme      = acme;
    assign adc_encendido = aden;

    assign irq_adc = adif & adie;

endmodule

`default_nettype wire
