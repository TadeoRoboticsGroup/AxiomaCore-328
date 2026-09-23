// AxiomaCore-328 - banco del ADC, contra un frente analogico de la hoja de datos
// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 The AxiomaCore Project
//
// EL ORACULO ES EL COMPARADOR, no el resultado. El ADR 0002 deja el DAC y el
// comparador fuera del RTL a proposito, y esto es lo que se compra con ello:
// aqui se escribe el frente analogico desde la hoja de datos -un S/H que retiene
// en su pulso y un comparador que responde `v_retenida >= v_dac`- y se comprueba
// que el SAR CONVERGE. Las diez decisiones, en orden de peso, en el numero
// exacto de ciclos.
//
// Un ADC que devuelve el valor bueno por casualidad y uno que aproxima de verdad
// dan el mismo numero. Lo que los distingue es el proceso, y el proceso solo se
// ve si el comparador esta fuera.
//
// LO QUE SIMAVR NO PUEDE DESMENTIR. Su `avr_adc.c` programa la interrupcion a
// `prescale * 11` ciclos -el manual dice 13, y 25 la primera- y entrega el valor
// de golpe desde una IRQ en milivoltios. No serializa nada. Por eso ADCL, ADCH y
// ADIF quedan FUERA de la tabla COMPARABLE[] del diferencial: compararlos seria
// comparar dos relojes distintos.

#include "Vaxioma_adc.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>

static Vaxioma_adc *dut;
static int  fails = 0;
static long checks = 0;
static const char *fase = "";

static void chk(const char *que, uint32_t got, uint32_t exp) {
    checks++;
    if (got != exp) {
        if (++fails <= 20)
            printf("    FALLA [%s] %-44s obtenido=0x%02X esperado=0x%02X\n",
                   fase, que, got, exp);
    }
}

// --------------------------------------------------------- el frente analogico
// Ocho canales mas los tres especiales del multiplexor. El valor esta en
// CODIGOS de 0 a 1023, que es lo mismo que decir en fracciones de la referencia:
// con un DAC ideal, el codigo que debe salir es exactamente ese numero.
static int  v_canal[16];
static int  v_hold = 0;       // lo que el S/H tiene retenido
static long muestreos = 0;    // cuantas veces ha cerrado
static long ciclo = 0;        // reloj de sistema, para medir instantes
static long ciclo_muestreo = 0;

static void tick() {
    // El comparador es COMBINACIONAL: responde al codigo que el SAR tiene
    // puesto ahora mismo. `>=` y no `>`, que es lo que dice la hoja de datos.
    dut->adc_cmp = (v_hold >= (int)dut->adc_dac) ? 1 : 0;
    dut->eval();
    dut->clk = 1; dut->eval();
    if (dut->adc_muestrea) {
        // El S/H cierra: a partir de aqui la tension esta quieta, aunque la
        // entrada se mueva. Es lo que hace que dos conversiones seguidas de una
        // senial que cambia den valores distintos y los dos correctos.
        v_hold = v_canal[dut->adc_canal & 0xF];
        muestreos++;
        ciclo_muestreo = ciclo;
    }
    dut->clk = 0; dut->eval();
    ciclo++;
}

static void run(int n) { for (int i = 0; i < n; i++) tick(); }

// ------------------------------------------------------- acceso a registros
enum { ADCL = 0x58, ADCH = 0x59, ADCSRA = 0x5A, ADCSRB = 0x5B,
       ADMUX = 0x5C, DIDR0 = 0x5E };
enum { ADEN = 0x80, ADSC = 0x40, ADATE = 0x20, ADIF = 0x10, ADIE = 0x08 };

static void wr(uint8_t a, uint8_t d) {
    dut->io_addr = a; dut->io_wdata = d; dut->io_we = 1;
    tick();
    dut->io_we = 0; dut->io_addr = 0; dut->eval();
}

// LEER TIENE EFECTOS LATERALES -el cerrojo de ADCL-, asi que hay dos formas de
// mirar: `rd` lee de verdad, con `io_re`; `peek` solo asoma el dato sin
// levantar la senial de lectura.
static uint8_t rd(uint8_t a) {
    dut->io_addr = a; dut->io_re = 1; dut->eval();
    uint8_t v = dut->io_rdata;
    tick();
    dut->io_re = 0; dut->io_addr = 0; dut->eval();
    return v;
}

static uint8_t peek(uint8_t a) {
    uint8_t ant = dut->io_addr;
    dut->io_addr = a; dut->eval();
    uint8_t v = dut->io_rdata;
    dut->io_addr = ant; dut->eval();
    return v;
}

// Arranca una conversion y espera a que ADSC se caiga. Devuelve los ciclos de
// reloj de SISTEMA que ha tardado, contados desde la escritura de ADSC.
static long convertir(uint8_t adcsra_base, long tope = 40000) {
    long t0 = ciclo;
    wr(ADCSRA, (uint8_t)(adcsra_base | ADSC));
    for (long i = 0; i < tope; i++) {
        if (!(peek(ADCSRA) & ADSC)) return ciclo - t0;
        tick();
    }
    return -1;
}

static uint16_t resultado(bool adlar) {
    uint8_t lo = rd(ADCL);
    uint8_t hi = rd(ADCH);
    return adlar ? (uint16_t)(((hi << 8) | lo) >> 6)
                 : (uint16_t)(((hi & 3) << 8) | lo);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_adc;

    for (int i = 0; i < 16; i++) v_canal[i] = 0;
    dut->rst_n = 0; dut->clk = 0;
    dut->ce = 1;   // a reloj entero: la habilitacion es cosa de CLKPR (ADR 0003)
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->adc_cmp = 0; dut->ack_adc = 0; dut->adc_trig = 0;
    dut->eval();
    tick();
    dut->rst_n = 1; dut->eval();

    // ------------------------------------------------ 1. valores de reset
    fase = "reset";
    chk("ADCSRA", peek(ADCSRA), 0x00);
    chk("ADCSRB", peek(ADCSRB), 0x00);
    chk("ADMUX",  peek(ADMUX),  0x00);
    chk("DIDR0",  peek(DIDR0),  0x00);
    chk("ADCL",   peek(ADCL),   0x00);
    chk("ADCH",   peek(ADCH),   0x00);
    chk("el bufer digital no se apaga solo", dut->didr_dis, 0x00);

    // -------------------------------- 2. los registros se leen de vuelta
    // Obvio hasta que falla: si un registro de configuracion no devuelve lo que
    // se le escribio, todo lo demas que pase es casualidad. Y los bits que NO
    // existen tienen que leerse a cero: el bit 4 de ADMUX y los 7, 5, 4 y 3 de
    // ADCSRB estan reservados en la hoja de datos.
    fase = "lectura de vuelta";
    wr(ADMUX, 0xFF);
    chk("ADMUX ignora el bit 4, que no existe", peek(ADMUX), 0xEF);
    wr(ADMUX, 0x00);
    wr(ADCSRB, 0xFF);
    chk("ADCSRB solo tiene ACME y los tres ADTS", peek(ADCSRB), 0x47);
    wr(ADCSRB, 0x00);
    wr(DIDR0, 0xFF);
    chk("DIDR0 tiene seis bits", peek(DIDR0), 0x3F);
    chk("y apaga el bufer de esos seis pines", dut->didr_dis, 0x3F);
    wr(DIDR0, 0x00);

    // ------------------------------- 3. ADSC no arranca con el ADC apagado
    // «ADSC will read as one as long as a conversion is in progress», y con
    // ADEN a cero no hay conversion que empezar.
    fase = "ADSC con el ADC apagado";
    wr(ADCSRA, ADSC);
    chk("ADSC no se queda puesto sin ADEN", (peek(ADCSRA) & ADSC) != 0, 0);
    run(200);
    chk("y no pasa nada", (peek(ADCSRA) & ADIF) != 0, 0);

    // ------------------------------------- 4. los 1024 codigos, uno por uno
    // CON UN DAC IDEAL EL CODIGO DE SALIDA ES EXACTO, asi que esto es una
    // comprobacion de verdad y no una tolerancia: si el SAR se equivoca en un
    // bit, el numero no cuadra.
    fase = "los 1024 codigos";
    wr(ADMUX, 0x00);                       // canal 0, referencia 0, sin ADLAR
    wr(ADCSRA, ADEN);                      // encender, prescaler /2
    for (int v = 0; v < 1024; v++) {
        v_canal[0] = v;
        long d = convertir(ADEN);
        if (d < 0) { chk("la conversion no termina", 0, 1); break; }
        chk("el codigo convertido", resultado(false), (uint16_t)v);
    }

    // ------------------------ 5. las DIEZ decisiones, en orden de peso
    // Esto es lo que no se puede comprobar si el comparador esta dentro: que el
    // SAR pruebe el bit 9 primero y el 0 el ultimo, y que cada codigo que
    // presenta al DAC sea el anterior mas el bit en prueba.
    fase = "las diez decisiones";
    {
        v_canal[0] = 0x2A5;                // 0b10_1010_0101
        wr(ADCSRA, ADEN);
        wr(ADCSRA, ADEN | ADSC);
        int vistos[16]; int n = 0;
        uint16_t ant = 0xFFFF;
        for (long i = 0; i < 4000 && n < 16; i++) {
            tick();
            uint16_t d = dut->adc_dac;
            if (d != ant && d != 0) { if (n < 16) vistos[n++] = d; ant = d; }
            if (!(peek(ADCSRA) & ADSC)) break;
        }
        chk("son diez codigos probados, ni mas ni menos", n, 10);
        if (n == 10) {
            // El primero prueba el bit 9 a solas.
            chk("el primero es el bit 9", vistos[0], 0x200);
            // Y cada uno lleva EXACTAMENTE un bit mas que lo ya decidido.
            int acumulado = 0;
            bool orden_ok = true;
            for (int k = 0; k < 10; k++) {
                int prueba = 1 << (9 - k);
                if (vistos[k] != (acumulado | prueba)) orden_ok = false;
                // si el bit cabia, se queda
                if ((v_canal[0] >> (9 - k)) & 1) acumulado |= prueba;
            }
            chk("cada decision anade su bit y conserva los anteriores",
                orden_ok, 1);
        }
        chk("y el resultado es el de siempre", resultado(false), 0x2A5);
    }

    // ------------------------------------- 6. la duracion, en ciclos de ADC
    // LA TABLA 23-1: 13 ciclos de reloj de ADC una conversion normal, 25 la
    // PRIMERA tras encender el ADC. Medirlo en ciclos de sistema no basta,
    // porque hay un desfase fijo de arranque; lo que se hace es medir con DOS
    // prescalers distintos y despejar: duracion = medio_div * medios + k.
    fase = "13 ciclos de ADC, y 25 la primera";
    {
        // MEDIR EN CICLOS DE SISTEMA NO BASTA, y la razon es fisica: la
        // conversion arranca en el PRIMER flanco del reloj de ADC posterior a
        // la escritura de ADSC -lo dice la hoja de datos-, asi que entre la
        // escritura y el arranque hay un desfase que depende del prescaler. Y
        // preguntar por ADSC desde el banco mete su propia latencia encima.
        //
        // La salida es medir SOLO ENTRE TRANSICIONES DEL DAC, que es lo unico
        // que se ve desde fuera con un registro uniforme detras: el SAR cambia
        // el codigo al arrancar, en cada una de sus diez decisiones y al
        // terminar. Todas llevan el mismo retardo, asi que en las diferencias
        // se va.
        static const int esperado_div[8] = {1, 1, 2, 4, 8, 16, 32, 64};
        for (int adps = 0; adps < 8; adps++) {
            for (int vez = 0; vez < 2; vez++) {      // la larga y una normal
                v_canal[0] = 0x155;
                if (vez == 0) { wr(ADCSRA, 0x00); run(4);
                                wr(ADCSRA, (uint8_t)(ADEN | adps)); }

                long m0 = muestreos;
                wr(ADCSRA, (uint8_t)(ADEN | adps | ADSC));

                long t[20]; int n = 0; long t_cae = -1;
                uint16_t ant = dut->adc_dac;
                for (long i = 0; i < 400000; i++) {
                    tick();
                    uint16_t d = dut->adc_dac;
                    if (d != ant) {
                        if (d == 0) { t_cae = ciclo; ant = d; break; }
                        if (n < 20) t[n++] = ciclo;
                        ant = d;
                    }
                }
                if (n < 5 || t_cae < 0 || muestreos == m0) {
                    chk("la conversion no dio sus pasos", 0, 1);
                    continue;
                }

                // El periodo de MEDIO ciclo de ADC: entre dos decisiones hay
                // dos medios, y ese es el hueco mas corto de todos -el de
                // arranque es mucho mayor-.
                long hueco = t[2] - t[1];
                for (int k = 2; k < n; k++)
                    if (t[k] - t[k-1] < hueco) hueco = t[k] - t[k-1];
                long medio = hueco / 2;
                chk("el prescaler divide lo que dice la tabla",
                    (uint32_t)medio, (uint32_t)esperado_div[adps]);

                // Del arranque a la PRIMERA decision hay el muestreo mas dos
                // medios ciclos: el comparador necesita un ciclo entero para
                // asentarse antes de que se le pregunte.
                long sh = (t[1] - t[0]) / medio - 2;
                chk(vez == 0 ? "el S/H de la primera cierra a 13,5 ciclos"
                             : "y el de una normal, a 1,5",
                    (uint32_t)sh, vez == 0 ? 27u : 3u);

                // Y del arranque al final, la conversion entera.
                long total_medido = (t_cae - t[0]) / medio;
                chk(vez == 0 ? "la primera conversion son 25 ciclos de ADC"
                             : "y una normal, 13",
                    (uint32_t)total_medido, vez == 0 ? 50u : 26u);

                for (long i = 0; i < 4000 && (peek(ADCSRA) & ADSC); i++) tick();
                chk("con su codigo", resultado(false), 0x155);
            }
        }
    }

    // --------------------------------- 7. CUANDO cierra el sample & hold
    // A 1,5 ciclos de ADC en una conversion normal y a 13,5 en la primera.
    // Se comprueba con la entrada MOVIENDOSE: lo que sale tiene que ser lo que
    // habia en el instante del muestreo, no lo que hay al final.
    fase = "el S/H retiene en su instante";
    {
        wr(ADCSRA, 0x00); run(4);
        wr(ADCSRA, ADEN);
        v_canal[0] = 100;
        long m0 = muestreos;
        wr(ADCSRA, ADEN | ADSC);
        // Esperar a que cierre, y cambiar la entrada JUSTO despues.
        for (long i = 0; i < 4000 && muestreos == m0; i++) tick();
        chk("el S/H cerro una vez", muestreos - m0, 1);
        v_canal[0] = 900;                  // ya no debe afectar
        for (long i = 0; i < 4000 && (peek(ADCSRA) & ADSC); i++) tick();
        chk("sale lo que habia al muestrear, no lo de despues",
            resultado(false), 100);

        // Y al reves: cambiar ANTES del muestreo si cuenta.
        v_canal[0] = 700;
        m0 = muestreos;
        wr(ADCSRA, ADEN | ADSC);
        for (long i = 0; i < 4000 && (peek(ADCSRA) & ADSC); i++) tick();
        chk("y el cambio anterior al muestreo si entra", resultado(false), 700);
    }

    // ----------------------------------------------------------- 8. ADLAR
    // Alinea el resultado a la izquierda, que es lo que permite leer solo ADCH
    // cuando ocho bits bastan.
    fase = "ADLAR";
    {
        wr(ADCSRA, 0x00); run(4);
        wr(ADMUX, 0x20);                   // ADLAR
        wr(ADCSRA, ADEN);
        v_canal[0] = 0x2A5;
        convertir(ADEN);
        chk("con ADLAR el resultado va arriba", resultado(true), 0x2A5);
        chk("y ADCH solo tiene los ocho altos", peek(ADCH), 0xA9);
        wr(ADMUX, 0x00);
    }

    // ------------------------------------------ 9. el cerrojo de ADCL/ADCH
    // LEER ADCL BLOQUEA los dos registros hasta que se lea ADCH. Sin eso, una
    // conversion que termine entre las dos lecturas mezcla el byte bajo de una
    // con el alto de otra y da un valor que no existio nunca.
    fase = "el cerrojo de ADCL y ADCH";
    {
        wr(ADCSRA, 0x00); run(4);
        wr(ADCSRA, ADEN);
        v_canal[0] = 0x1FF;                // el byte ALTO tiene que valer algo:
        convertir(ADEN);                   // con 0x0FF los dos casos darian 0
        uint8_t lo = rd(ADCL);             // se echa el cerrojo
        chk("el byte bajo de la primera", lo, 0xFF);

        // Otra conversion ENTERA con el cerrojo echado.
        v_canal[0] = 0x300;
        convertir(ADEN);
        uint8_t hi = rd(ADCH);             // se suelta
        chk("el byte alto sigue siendo el de la MISMA conversion", hi, 0x01);

        // Ya sin cerrojo, el valor nuevo entra.
        convertir(ADEN);
        chk("y despues si se ve la conversion nueva", resultado(false), 0x300);
    }

    // ------------------------------------------ 10. ADIF, ADIE y el vector
    fase = "la bandera y el vector";
    {
        wr(ADCSRA, 0x00); run(4);
        wr(ADCSRA, (uint8_t)(ADEN | ADIF));   // limpiar lo que dejo la fase anterior
        v_canal[0] = 42;
        chk("ADIF empieza baja", (peek(ADCSRA) & ADIF) != 0, 0);
        convertir(ADEN);
        chk("ADIF se levanta al terminar", (peek(ADCSRA) & ADIF) != 0, 1);
        chk("pero sin ADIE no hay peticion", dut->irq_adc, 0);
        wr(ADCSRA, ADEN | ADIE | ADIF);    // ADIE y limpiar ADIF de una vez
        chk("ADIF se limpia escribiendo un UNO", (peek(ADCSRA) & ADIF) != 0, 0);
        convertir((uint8_t)(ADEN | ADIE));
        chk("con ADIE la peticion sale", dut->irq_adc, 1);

        // Atender el vector limpia la bandera en su origen, como en el resto
        // del chip: si no, la ISR volveria a entrar para siempre.
        dut->ack_adc = 1; tick(); dut->ack_adc = 0; tick();
        chk("el reconocimiento limpia ADIF", (peek(ADCSRA) & ADIF) != 0, 0);
        chk("y con ella la peticion", dut->irq_adc, 0);
        wr(ADCSRA, ADEN);
    }

    // ------------------------------ 11. escribir un cero en ADSC no para nada
    // «Writing zero to this bit has no effect», dice la hoja de datos.
    fase = "ADSC no se para escribiendo un cero";
    {
        wr(ADCSRA, 0x00); run(4);
        wr(ADCSRA, ADEN);
        v_canal[0] = 555;
        wr(ADCSRA, ADEN | ADSC);
        run(4);
        wr(ADCSRA, ADEN);                  // ADSC a cero: no debe abortar
        chk("la conversion sigue en marcha", (peek(ADCSRA) & ADSC) != 0, 1);
        for (long i = 0; i < 4000 && (peek(ADCSRA) & ADSC); i++) tick();
        chk("y termina con su resultado", resultado(false), 555);
    }

    // ---------------------------------- 12. apagar el ADC aborta y rearma
    fase = "apagar el ADC";
    {
        wr(ADCSRA, ADEN);
        v_canal[0] = 123;
        wr(ADCSRA, ADEN | ADSC);
        run(6);
        wr(ADCSRA, 0x00);                  // apagar a media conversion
        run(2);                            // ADEN se registra en el flanco
        chk("ADSC se cae al apagar", (peek(ADCSRA) & ADSC) != 0, 0);
        wr(ADCSRA, ADIF);                  // limpiar la bandera vieja
        run(400);
        chk("y no termina ninguna conversion", (peek(ADCSRA) & ADIF) != 0, 0);

        // Y la siguiente vuelve a ser LA LARGA, porque el convertidor se ha
        // vuelto a inicializar.
        wr(ADCSRA, ADEN);
        long larga = convertir(ADEN);
        long corta = convertir(ADEN);
        chk("tras apagar, la primera vuelve a durar mas", larga > corta, 1);
    }

    // ------------------------------------- 13. los canales del multiplexor
    // Para el SAR un canal es un canal: el sensor de temperatura y la
    // referencia de 1,1 V son entradas del multiplexor, no casos especiales.
    fase = "los canales del multiplexor";
    {
        wr(ADCSRA, 0x00); run(4);
        wr(ADCSRA, ADEN);
        for (int c = 0; c < 16; c++) v_canal[c] = (c * 61) & 0x3FF;
        for (int c = 0; c < 16; c++) {
            wr(ADMUX, (uint8_t)c);
            chk("el multiplexor sale al frente analogico", dut->adc_canal, c);
            convertir(ADEN);
            chk("y convierte el canal pedido", resultado(false),
                (uint16_t)((c * 61) & 0x3FF));
        }
        wr(ADMUX, 0x00);
    }

    // ------------------------------------------------ 14. REFS al frente
    // La referencia es analogica: el RTL no la usa, la EXPORTA. Que llegue al
    // macro es lo unico que se puede comprobar aqui, y hay que comprobarlo.
    fase = "la referencia";
    for (int r = 0; r < 4; r++) {
        wr(ADMUX, (uint8_t)(r << 6));
        chk("REFS sale al frente analogico", dut->adc_ref, r);
    }
    wr(ADMUX, 0x00);

    // --------------------------------------------- 15. barrido aleatorio
    // Canales, prescalers y tensiones al azar, con semilla fija. Es lo unico
    // que destapa los casos que a nadie se le ocurre escribir.
    fase = "aleatorio";
    {
        std::mt19937 rng(20260917);
        for (int i = 0; i < 400; i++) {
            int c = (int)(rng() % 16);
            int v = (int)(rng() % 1024);
            int adps = (int)(rng() % 8);
            bool lar = rng() & 1;
            v_canal[c] = v;
            wr(ADMUX, (uint8_t)((c & 0xF) | (lar ? 0x20 : 0)));
            wr(ADCSRA, (uint8_t)(ADEN | adps));
            if (convertir((uint8_t)(ADEN | adps)) < 0) {
                chk("la conversion aleatoria no termina", 0, 1);
                break;
            }
            chk("el codigo", resultado(lar), (uint16_t)v);
        }
    }

    // ============================ 16. EL DISPARO AUTOMATICO (la deuda D14)
    // Ocho fuentes, y la que manda es la que diga ADTS. Lo que se comprueba no
    // es que convierta —eso ya esta probado— sino QUIEN la arranca: que sea el
    // FLANCO de la bandera elegida y no el de otra, y que el nivel no baste.
    fase = "el disparo automatico: las ocho fuentes";
    {
        for (int fuente = 1; fuente < 8; fuente++) {
            wr(ADCSRA, 0x00); run(4);
            dut->adc_trig = 0; dut->eval();
            v_canal[0] = 300 + fuente;
            wr(ADMUX, 0x00);
            wr(ADCSRB, (uint8_t)fuente);              // ADTS
            wr(ADCSRA, (uint8_t)(ADEN | ADATE | ADIF | 0x02));
            run(40);
            chk("sin flanco no arranca nada", (peek(ADCSRA) & ADSC) != 0, 0);

            // Levantar OTRA bandera no tiene que hacer nada.
            dut->adc_trig = (uint8_t)(1 << (fuente == 7 ? 1 : fuente + 1));
            dut->eval(); run(40);
            chk("otra fuente no dispara", (peek(ADCSRA) & ADSC) != 0, 0);

            // Y la suya si, EN EL FLANCO.
            dut->adc_trig = (uint8_t)(1 << fuente); dut->eval(); run(4);
            chk("su fuente dispara", (peek(ADCSRA) & ADSC) != 0, 1);
            for (long i = 0; i < 4000 && (peek(ADCSRA) & ADSC); i++) tick();
            chk("y convierte el canal pedido", resultado(false),
                (uint16_t)(300 + fuente));

            // EL NIVEL NO BASTA: la bandera se queda alta y no vuelve a
            // disparar. Si disparase por nivel, un ADC con TOV0 puesto
            // convertiria sin parar y el programa no podria leer nunca un
            // resultado quieto.
            wr(ADCSRA, (uint8_t)(ADEN | ADATE | ADIF | 0x02));
            run(60);
            chk("el nivel sostenido no vuelve a disparar",
                (peek(ADCSRA) & ADSC) != 0, 0);
        }
        dut->adc_trig = 0; dut->eval();
    }

    // CAMBIAR ADTS A UNA FUENTE YA PUESTA ES UN FLANCO, y lo dice la hoja de
    // datos con todas las letras: «switching from a trigger source that is
    // cleared to a trigger source that is set will generate a positive edge».
    fase = "cambiar de fuente es un flanco";
    {
        wr(ADCSRA, 0x00); run(4);
        v_canal[0] = 512;
        wr(ADMUX, 0x00);
        dut->adc_trig = 0x80;                          // ICF1 puesta de antes
        dut->eval();
        wr(ADCSRB, 0x03);                              // ADTS = OCF0A, que esta baja
        wr(ADCSRA, (uint8_t)(ADEN | ADATE | ADIF | 0x02));
        run(40);
        chk("con la fuente baja no pasa nada", (peek(ADCSRA) & ADSC) != 0, 0);
        wr(ADCSRB, 0x07);                              // ahora ADTS = ICF1, ya puesta
        run(6);
        chk("cambiar a una fuente puesta arranca", (peek(ADCSRA) & ADSC) != 0, 1);
        for (long i = 0; i < 4000 && (peek(ADCSRA) & ADSC); i++) tick();
        dut->adc_trig = 0; dut->eval();
    }

    // EL MODO LIBRE: ADTS=000 y la conversion se rearma sola. La PRIMERA la
    // arranca el programa con ADSC — un ADC que empezara solo al poner ADATE no
    // dejaria configurar ADMUX antes.
    fase = "el modo libre";
    {
        wr(ADCSRA, 0x00); run(4);
        v_canal[0] = 100;
        wr(ADMUX, 0x00);
        wr(ADCSRB, 0x00);                              // ADTS = modo libre
        wr(ADCSRA, (uint8_t)(ADEN | ADATE | ADIF | 0x02));
        run(200);
        chk("no arranca sola al poner ADATE", (peek(ADCSRA) & ADSC) != 0, 0);

        wr(ADCSRA, (uint8_t)(ADEN | ADATE | ADSC | 0x02));
        long m0 = muestreos;
        for (long i = 0; i < 20000 && muestreos < m0 + 4; i++) tick();
        chk("y a partir de ahi convierte sin parar", muestreos >= m0 + 4, 1);
        chk("con ADSC siempre puesto", (peek(ADCSRA) & ADSC) != 0, 1);

        // Quitar ADATE la para al terminar la que este en curso.
        wr(ADCSRA, (uint8_t)(ADEN | ADIF | 0x02));
        for (long i = 0; i < 4000 && (peek(ADCSRA) & ADSC); i++) tick();
        m0 = muestreos;
        run(2000);
        chk("quitar ADATE para el modo libre", muestreos, (uint32_t)m0);
    }

    // Y SIN ADATE, una bandera puesta no arranca nada: es el bit que manda.
    fase = "sin ADATE no hay disparo";
    {
        wr(ADCSRA, 0x00); run(4);
        wr(ADCSRB, 0x04);                              // ADTS = TOV0
        wr(ADCSRA, (uint8_t)(ADEN | ADIF | 0x02));     // sin ADATE
        dut->adc_trig = 0x10; dut->eval(); run(60);
        chk("la bandera no dispara sin ADATE", (peek(ADCSRA) & ADSC) != 0, 0);
        dut->adc_trig = 0; dut->eval();
        wr(ADCSRB, 0x00);
    }

#if VM_COVERAGE
    // Sólo existe al compilar con `--coverage`. Sin esta llamada la
    // instrumentación corre y se tira a la basura: el modulo saldria al 65 %
    // porque lo unico que lo pisaria son los programas del diferencial.
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;
    printf("  %ld comprobaciones, %d fallos\n", checks, fails);
    if (fails) {
        printf("  el comparador del banco sale de la hoja de datos: simavr no\n"
               "  serializa nada y no puede desmentir a ninguno de los dos.\n");
        return 1;
    }
    printf("  aproximacion sucesiva, ciclos, muestreo y cerrojo correctos\n");
    return 0;
}
