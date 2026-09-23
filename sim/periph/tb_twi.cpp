// AxiomaCore-328 - TWI contra un bus de colector abierto de verdad
// SPDX-License-Identifier: Apache-2.0
//
// POR QUÉ HACE FALTA ESTE BANCO. Como con la USART y el SPI, simavr no sirve
// de oráculo: su `avr_twi.c` transporta direcciones y bytes enteros por IRQs
// internas y no serializa nada, así que no hay SDA que comparar. Lo que el
// diferencial sí verifica es el almacenamiento de TWBR, TWAR y TWAMR; todo lo
// demás lo certifica esto.
//
// Y AQUÍ HAY MÁS QUE CERTIFICAR QUE EN EL SPI, porque el TWI no es un cable:
// es un bus. Tres cosas que un SPI no tiene y que aquí SÍ se prueban:
//
//   1. COLECTOR ABIERTO. Nadie conduce hacia arriba. La línea es el Y de todo
//      el mundo, y lo que la sube es el pull-up. El modelo de bus de este
//      banco es literalmente eso, y por eso un mutante que ponga el TWI a
//      conducir un uno se ve enseguida: cortocircuitaría contra el otro.
//   2. ARBITRAJE. Dos maestros arrancan a la vez y uno tiene que callarse en
//      el bit exacto en el que se da cuenta, sin STOP y sin perder el dato.
//   3. ESTIRAMIENTO DE RELOJ. El esclavo del banco tira de SCL cuando le
//      apetece, y el maestro del DUT tiene que ESPERAR. Un maestro que cuente
//      semiperiodos sin mirar el pin pasa todos los tests con ondas perfectas
//      y se rompe en la primera placa con un sensor lento.
//
// EL ORÁCULO SON LOS DOS EXTREMOS DEL BUS Y LAS TABLAS DE ESTADO. El banco
// implementa un esclavo y un maestro I2C escritos desde la hoja de datos, sin
// compartir una línea con el RTL, y después de cada paso comprueba TWSR contra
// el código que las tablas 21-2 a 21-6 dicen que toca.

#include "Vaxioma_twi.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>
#include <cstring>

static Vaxioma_twi *dut;
static int  fails  = 0;
static long checks = 0;
static long ciclos = 0;
static const char *fase = "";

// Inyeccion de ruido: un pico de un ciclo en la linea y el momento que se
// digan. La fase que lo usa esta al final.
static bool ruido_activo = false;
static long ruido_en = -1;   // ciclo en el que meter el pico
static int  ruido_linea = 0; // 0 = SDA, 1 = SCL

// CORTE RAPIDO. Con el RTL roto -y la prueba de mutacion lo rompe quince
// veces- cada espera agota su tope y el banco tarda mas en fallar que en
// pasar. Un banco asi no lo ejecuta nadie, y sin ejecutarlo no protege nada.
// A los 20 fallos se para: ya se sabe lo que hacia falta saber.
static const int TOPE_FALLOS = 20;

static void rendirse() {
    printf("  %ld comprobaciones en %ld ciclos, %d fallos "
           "(cortado en el fallo %d: el DUT no responde)\n",
           checks, ciclos, fails, TOPE_FALLOS);
    exit(1);
}

static void chk(const char *que, uint32_t got, uint32_t exp) {
    checks++;
    if (got != exp) {
        if (++fails <= 14)
            printf("    FALLA [%s] %-38s obtenido=0x%02X esperado=0x%02X\n",
                   fase, que, got, exp);
        if (fails >= TOPE_FALLOS) rendirse();
    }
}

static void chk_bool(const char *que, bool got, bool exp) {
    checks++;
    if (got != exp) {
        if (++fails <= 14)
            printf("    FALLA [%s] %-38s obtenido=%d esperado=%d\n",
                   fase, que, (int)got, (int)exp);
        if (fails >= TOPE_FALLOS) rendirse();
    }
}

// Direcciones de I/O (dirección de dato menos 0x20).
enum { A_TWBR = 0x98, A_TWSR = 0x99, A_TWAR = 0x9A,
       A_TWDR = 0x9B, A_TWCR = 0x9C, A_TWAMR = 0x9D };

// Bits de TWCR, con los nombres de la hoja de datos.
enum { TWINT = 0x80, TWEA = 0x40, TWSTA = 0x20, TWSTO = 0x10,
       TWWC = 0x08, TWEN = 0x04, TWIE = 0x01 };

// Los 26 códigos de estado de las tablas 21-2 a 21-6.
enum { ST_BUS_ERROR = 0x00, ST_START = 0x08, ST_REPSTART = 0x10,
       ST_MT_SLA_A = 0x18, ST_MT_SLA_N = 0x20, ST_MT_DAT_A = 0x28,
       ST_MT_DAT_N = 0x30, ST_ARB_LOST = 0x38, ST_MR_SLA_A = 0x40,
       ST_MR_SLA_N = 0x48, ST_MR_DAT_A = 0x50, ST_MR_DAT_N = 0x58,
       ST_SR_SLA_A = 0x60, ST_SR_ARB_SLA = 0x68, ST_SR_GC_A = 0x70,
       ST_SR_ARB_GC = 0x78, ST_SR_DAT_A = 0x80, ST_SR_DAT_N = 0x88,
       ST_SR_GDAT_A = 0x90, ST_SR_GDAT_N = 0x98, ST_SR_STOP = 0xA0,
       ST_ST_SLA_A = 0xA8, ST_ST_ARB_SLA = 0xB0, ST_ST_DAT_A = 0xB8,
       ST_ST_DAT_N = 0xC0, ST_ST_LAST_A = 0xC8, ST_NADA = 0xF8 };

// ---------------------------------------------------------------- el bus
// COLECTOR ABIERTO: la línea vale 1 salvo que ALGUIEN tire de ella. Es un Y
// de todos los participantes, y es la diferencia de fondo con el SPI, donde
// cada pin tiene un dueño. Aquí el DUT y el banco pueden tirar los dos a la
// vez y eso NO es un conflicto: es el mecanismo del arbitraje.
// Lo que tira de cada linea: el DUT, el esclavo del banco y el maestro del
// banco. Los tres pueden coincidir, y eso no es un conflicto sino el bus
// funcionando.
static bool mm_sda_pull = false, mm_scl_pull = false;   // el maestro del banco
static bool bus_sda = true, bus_scl = true;
static bool esclavo_sda_pull();                          // definidos tras el modelo
static bool esclavo_scl_pull();

static void resolver() {
    bus_scl = !(dut->scl_pull || mm_scl_pull || esclavo_scl_pull());
    bus_sda = !(dut->sda_pull || mm_sda_pull || esclavo_sda_pull());
    // UN PICO DE UN CICLO, EN EL PIN DEL DUT Y SOLO AHI. Se invierte el
    // nivel un ciclo, que es lo que hace un acoplamiento en una placa.
    //
    // Y va en el pin, no en el bus, a proposito: el maestro y el esclavo del
    // banco son el ORACULO, y un oraculo con el mismo filtro que el DUT deja
    // de serlo -seria el fallo de siempre, el modelo y el RTL dandose la razon
    // mutuamente-. Inyectandolo aqui, el oraculo ve la trama limpia y sabe
    // exactamente que tendria que haber pasado; la pregunta que se contesta es
    // si el DUT se comporta como si no hubiera habido ruido.
    bool scl_dut = bus_scl, sda_dut = bus_sda;
    if (ruido_activo && ciclos == ruido_en) {
        if (ruido_linea) scl_dut = !scl_dut;
        else             sda_dut = !sda_dut;
    }
    dut->scl_pin = scl_dut;
    dut->sda_pin = sda_dut;
}

// Los dos modelos del banco avanzan dentro del tick, viendo el mismo bus que
// el DUT. Se declaran abajo; esto es el gancho.
static void modelos_paso();

// Traza del bus, para depurar. Se enciende con TWI_TRACE=1 en el entorno.
static bool traza = false;
static bool tr_scl = true, tr_sda = true;

static void tick() {
    resolver();
    dut->eval();
    dut->clk = 1; dut->eval();
    modelos_paso();
    dut->clk = 0; dut->eval();
    resolver();
    dut->eval();
    if (traza && (bus_scl != tr_scl || bus_sda != tr_sda)) {
        printf("  %6ld SCL=%d SDA=%d  (dut scl=%d sda=%d)\n", ciclos,
               bus_scl, bus_sda, dut->scl_pull, dut->sda_pull);
        tr_scl = bus_scl; tr_sda = bus_sda;
    }
    ciclos++;
}

static void wr(uint8_t a, uint8_t d) {
    dut->io_addr = a; dut->io_wdata = d; dut->io_we = 1; dut->io_re = 0;
    tick();
    dut->io_we = 0; dut->eval();
}

// Lee sin consumir un ciclo, para mirar una bandera sin que avance el bus.
static uint8_t mira(uint8_t a) {
    dut->io_addr = a; dut->io_we = 0; dut->io_re = 0;
    resolver(); dut->eval();
    return dut->io_rdata;
}

static uint8_t rd(uint8_t a) {
    uint8_t v = mira(a);
    dut->io_re = 1; tick(); dut->io_re = 0; dut->eval();
    return v;
}

static void correr(int n) { for (int i = 0; i < n; i++) tick(); }

// Espera a que TWINT suba. Devuelve false si no llega: un TWI colgado es un
// fallo, y sin tope el banco se quedaría dando vueltas para siempre.
static bool esperar_twint(long tope = 20000) {
    for (long i = 0; i < tope; i++) {
        if (mira(A_TWCR) & TWINT) return true;
        tick();
    }
    printf("      [diag] TWCR=%02X TWSR=%02X bus SCL=%d SDA=%d "
           "dut scl_pull=%d sda_pull=%d\n",
           mira(A_TWCR), mira(A_TWSR), bus_scl, bus_sda,
           dut->scl_pull, dut->sda_pull);
    return false;
}

static uint8_t estado() { return mira(A_TWSR) & 0xF8; }

// El esclavo vive en `esclavo_i2c.h`, porque lo comparte con el banco de SoC
// que hace el barrido de direcciones. Ver alli el razonamiento.
#include "esclavo_i2c.h"

static EsclavoI2C esclavo;
static bool esclavo_sda_pull() { return esclavo.sda_pull; }
static bool esclavo_scl_pull() { return esclavo.scl_pull; }
static void modelos_paso() { esclavo.paso(bus_scl, bus_sda); }

// ------------------------------------------ el otro extremo: un maestro I2C
// Va como funciones que bloquean llamando a `tick()`, porque un maestro es una
// secuencia y escribirlo como maquina de estados solo lo haria ilegible. El
// DUT sigue corriendo dentro de cada tick, asi que esto convive con el.
//
// MIRA EL PIN EN LAS DOS TRANSICIONES, igual que el del RTL: cuando suelta SCL
// espera a que suba DE VERDAD. Sin eso, el estiramiento de reloj del DUT -que
// es obligatorio entre byte y byte- rompería este maestro y no el otro.
static int  mm_semiper = 40;

// EL PROGRAMA DEL DUT CUANDO HACE DE ESCLAVO. Un esclavo TWI estira SCL
// mientras TWINT este puesto, asi que si nadie atiende la bandera el bus se
// para y este maestro se queda esperando para siempre. Eso no es un defecto
// del banco: es exactamente lo que le pasa a una placa cuya ISR no responde.
// La funcion hace de ISR, y se la llama desde las esperas del maestro.
static void (*atiende)() = nullptr;

static void servicio() {
    static bool dentro = false;
    if (!atiende || dentro) return;
    if (!(mira(A_TWCR) & TWINT)) return;
    dentro = true; atiende(); dentro = false;
}

static void mm_espera(int n) { for (int i = 0; i < n; i++) { tick(); servicio(); } }

static bool mm_soltar_scl() {
    mm_scl_pull = false;
    for (int i = 0; i < 40000; i++) {
        if (bus_scl) return true;
        tick(); servicio();
    }
    return false;                       // el otro extremo se quedo colgado
}

static void mm_start() {
    mm_sda_pull = false; mm_scl_pull = false;
    mm_espera(mm_semiper);
    mm_sda_pull = true;                 // SDA abajo con SCL alto: START
    mm_espera(mm_semiper);
    mm_scl_pull = true;
    mm_espera(mm_semiper);
}

// Un bit. Devuelve lo que habia en la linea mientras SCL estaba alto, que es
// lo que permite al llamante ver un ACK ajeno y detectar que ha perdido.
static bool mm_bit(bool valor) {
    mm_sda_pull = !valor;
    mm_espera(mm_semiper);
    mm_soltar_scl();
    bool leido = bus_sda;
    mm_espera(mm_semiper);
    mm_scl_pull = true;
    mm_espera(2);
    return leido;
}

// Transmite un byte y devuelve el ACK (true = ACK, o sea SDA abajo).
static bool mm_tx(uint8_t d) {
    for (int i = 7; i >= 0; i--) mm_bit((d >> i) & 1);
    return !mm_bit(true);               // soltamos y leemos la respuesta
}

// Recibe un byte contestando con `ack`.
static uint8_t mm_rx(bool ack) {
    uint8_t v = 0;
    for (int i = 0; i < 8; i++) v = (uint8_t)((v << 1) | (mm_bit(true) ? 1 : 0));
    mm_bit(!ack);
    return v;
}

static void mm_stop() {
    mm_sda_pull = true;
    mm_espera(mm_semiper);
    mm_soltar_scl();
    mm_espera(mm_semiper);
    mm_sda_pull = false;                // SDA arriba con SCL alto: STOP
    mm_espera(mm_semiper);
}

static void mm_reposo() { mm_sda_pull = false; mm_scl_pull = false; }

// --------------------------------------------------------------- utilidades
static void reset_dut() {
    atiende = nullptr;
    mm_reposo();
    esclavo = EsclavoI2C();
    dut->rst_n = 0; dut->io_we = 0; dut->io_re = 0; dut->io_addr = 0;
    dut->ce = 1;   // a reloj entero: la habilitacion es cosa de CLKPR (ADR 0003)
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1;
    for (int i = 0; i < 4; i++) tick();
}

// Arranca el DUT como maestro con un semiperiodo corto: el banco no necesita
// los 100 kHz de una placa, y con TWBR grande cada trama costaria millones de
// ciclos. La FRECUENCIA se mide aparte, en la fase G, y ahi si con los valores
// de verdad.
static void maestro_listo(uint8_t twbr = 2, uint8_t twps = 0) {
    wr(A_TWBR, twbr);
    wr(A_TWSR, twps);
    wr(A_TWCR, TWEN);
}

// Un paso del maestro: limpiar TWINT con los bits que toquen y esperar al
// siguiente. Devuelve el codigo de estado.
static uint8_t paso_maestro(uint8_t twcr_extra) {
    wr(A_TWCR, (uint8_t)(TWINT | TWEN | twcr_extra));
    if (!esperar_twint()) { chk("TWINT no llego: bus colgado", 0, 1); return 0xFF; }
    return estado();
}

// ============================================================ A. maestro TX
static void fase_maestro_tx() {
    fase = "maestro transmisor";
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    maestro_listo();

    chk("TWSR en reposo", estado(), ST_NADA);
    chk("TWAR tras el reset", mira(A_TWAR), 0xFE);
    chk("TWDR tras el reset", mira(A_TWDR), 0xFF);

    chk("START", paso_maestro(TWSTA), ST_START);
    chk("TWSTA se limpia al transmitirlo", mira(A_TWCR) & TWSTA, 0);

    wr(A_TWDR, (uint8_t)(0x50 << 1));            // SLA+W
    chk("SLA+W con ACK", paso_maestro(0), ST_MT_SLA_A);

    const uint8_t datos[] = {0xA5, 0x3C, 0x00, 0xFF, 0x55};
    for (uint8_t d : datos) {
        wr(A_TWDR, d);
        chk("dato con ACK", paso_maestro(0), ST_MT_DAT_A);
    }

    // STOP: no levanta TWINT, y TWSTO se limpia solo al ejecutarse.
    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 4000 && (mira(A_TWCR) & TWSTO); i++) tick();
    chk("TWSTO se limpia al ejecutarse", mira(A_TWCR) & TWSTO, 0);
    chk_bool("el bus queda libre tras el STOP", bus_sda && bus_scl, true);

    chk("bytes que llegaron al esclavo", (uint32_t)esclavo.recibido.size(),
        (uint32_t)(sizeof(datos)));
    for (size_t i = 0; i < esclavo.recibido.size() && i < sizeof(datos); i++)
        chk("byte recibido por el esclavo", esclavo.recibido[i], datos[i]);
}

// ==================================================== A bis. NACK y ausencia
static void fase_nack() {
    fase = "NACK del esclavo";
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    maestro_listo();

    // Una direccion que no es de nadie: nadie tira de SDA en el noveno bit.
    chk("START", paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)(0x22 << 1));
    chk("SLA+W sin nadie que conteste", paso_maestro(0), ST_MT_SLA_N);
    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 4000 && (mira(A_TWCR) & TWSTO); i++) tick();

    // Ahora el esclavo si esta, pero da NACK al segundo dato.
    esclavo.recibido.clear(); esclavo.nack_tras = 1; esclavo.bytes_rx = 0;
    chk("START otra vez", paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)(0x50 << 1));
    chk("SLA+W con ACK", paso_maestro(0), ST_MT_SLA_A);
    wr(A_TWDR, 0x11);
    chk("primer dato con ACK", paso_maestro(0), ST_MT_DAT_A);
    wr(A_TWDR, 0x22);
    chk("segundo dato con NACK", paso_maestro(0), ST_MT_DAT_N);
    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 4000 && (mira(A_TWCR) & TWSTO); i++) tick();
}

// ============================================================ B. maestro RX
static void fase_maestro_rx() {
    fase = "maestro receptor";
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    esclavo.a_enviar = {0x11, 0x22, 0x33, 0x44};
    maestro_listo();

    chk("START", paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)((0x50 << 1) | 1));      // SLA+R
    chk("SLA+R con ACK", paso_maestro(0), ST_MR_SLA_A);

    // Los tres primeros con ACK, el ultimo con NACK: es como se cierra una
    // lectura en I2C, y es lo que hace `Wire.requestFrom()`.
    for (int i = 0; i < 3; i++) {
        chk("dato leido con ACK", paso_maestro(TWEA), ST_MR_DAT_A);
        chk("TWDR trae el byte", mira(A_TWDR), esclavo.a_enviar[i]);
    }
    chk("ultimo dato con NACK", paso_maestro(0), ST_MR_DAT_N);
    chk("TWDR trae el ultimo byte", mira(A_TWDR), esclavo.a_enviar[3]);

    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 4000 && (mira(A_TWCR) & TWSTO); i++) tick();
    chk_bool("bus libre", bus_sda && bus_scl, true);
}

// ================================================= B bis. START repetido
static void fase_repstart() {
    fase = "START repetido";
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    esclavo.a_enviar = {0x77};
    maestro_listo();

    chk("START", paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)(0x50 << 1));
    chk("SLA+W", paso_maestro(0), ST_MT_SLA_A);
    wr(A_TWDR, 0x09);                            // registro que se quiere leer
    chk("dato", paso_maestro(0), ST_MT_DAT_A);

    // Sin STOP: se vuelve a arrancar. Es LA operacion de cualquier sensor.
    chk("START repetido", paso_maestro(TWSTA), ST_REPSTART);
    wr(A_TWDR, (uint8_t)((0x50 << 1) | 1));
    chk("SLA+R tras el repetido", paso_maestro(0), ST_MR_SLA_A);
    chk("dato leido con NACK", paso_maestro(0), ST_MR_DAT_N);
    chk("el byte es el del esclavo", mira(A_TWDR), 0x77);

    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 4000 && (mira(A_TWCR) & TWSTO); i++) tick();
    chk("el esclavo vio el registro pedido",
        esclavo.recibido.empty() ? 0xFFu : esclavo.recibido[0], 0x09u);
}

// ================================================ el programa del DUT esclavo
// Hace de ISR: se le llama cada vez que TWINT sube. Anota el codigo de estado
// y contesta lo que la tabla de la hoja de datos dice que hay que contestar.
// La SECUENCIA de codigos anotada es el oraculo: no basta con que cada uno sea
// valido, tienen que salir en el orden que manda el protocolo.
static std::vector<uint8_t> log_estados;
static std::vector<uint8_t> log_datos;
static uint8_t  resp_twcr = TWINT | TWEN | TWEA;
static std::vector<uint8_t> esclavo_envia;
static size_t   esclavo_idx = 0;

static void isr_esclavo() {
    uint8_t st = estado();
    log_estados.push_back(st);
    switch (st) {
        case ST_SR_DAT_A: case ST_SR_DAT_N:
        case ST_SR_GDAT_A: case ST_SR_GDAT_N:
            log_datos.push_back(mira(A_TWDR));
            break;
        case ST_ST_SLA_A: case ST_ST_ARB_SLA: case ST_ST_DAT_A:
            wr(A_TWDR, esclavo_idx < esclavo_envia.size()
                       ? esclavo_envia[esclavo_idx++] : 0xFF);
            break;
        default: break;
    }
    wr(A_TWCR, resp_twcr);
}

static void chk_seq(const char *que, const std::vector<uint8_t> &got,
                    const std::vector<uint8_t> &exp) {
    checks++;
    if (got == exp) return;
    if (++fails <= 14) {
        printf("    FALLA [%s] %s\n      obtenido:", fase, que);
        for (uint8_t v : got) printf(" %02X", v);
        printf("\n      esperado:");
        for (uint8_t v : exp) printf(" %02X", v);
        printf("\n");
    }
    if (fails >= TOPE_FALLOS) rendirse();
}

static void esclavo_listo(uint8_t dir7, uint8_t twamr = 0x00, bool gce = false) {
    log_estados.clear(); log_datos.clear();
    esclavo_envia.clear(); esclavo_idx = 0;
    resp_twcr = TWINT | TWEN | TWEA;
    wr(A_TWAR, (uint8_t)((dir7 << 1) | (gce ? 1 : 0)));
    wr(A_TWAMR, twamr);
    wr(A_TWCR, TWEN | TWEA);
    atiende = isr_esclavo;
}

// ========================================================== C. esclavo RX
static void fase_esclavo_rx() {
    fase = "esclavo receptor";
    reset_dut();
    mm_semiper = 24;
    esclavo_listo(0x42);

    mm_start();
    chk_bool("el DUT reconoce su direccion", mm_tx((uint8_t)(0x42 << 1)), true);
    chk_bool("ACK del primer dato", mm_tx(0x11), true);
    chk_bool("ACK del segundo dato", mm_tx(0x22), true);
    mm_stop();
    mm_espera(60);

    chk_seq("secuencia de estados del esclavo receptor", log_estados,
            {ST_SR_SLA_A, ST_SR_DAT_A, ST_SR_DAT_A, ST_SR_STOP});
    chk_seq("bytes recibidos", log_datos, {0x11, 0x22});

    // Una direccion ajena no debe levantar TWINT ni tirar de SDA.
    log_estados.clear();
    mm_start();
    chk_bool("una direccion ajena NO se reconoce", mm_tx((uint8_t)(0x11 << 1)), false);
    mm_stop();
    mm_espera(60);
    chk("una direccion ajena no genera ningun estado",
        (uint32_t)log_estados.size(), 0u);
}

// =================================================== C bis. TWEA, llamada general
static void fase_esclavo_opciones() {
    fase = "esclavo: TWEA, llamada general y mascara";
    reset_dut();
    mm_semiper = 24;

    // TWEA=0: el esclavo no contesta ni a su propia direccion.
    esclavo_listo(0x42);
    wr(A_TWCR, TWEN);                       // TWEN sin TWEA
    mm_start();
    chk_bool("con TWEA a cero no se reconoce nada", mm_tx((uint8_t)(0x42 << 1)), false);
    mm_stop(); mm_espera(40);

    // Llamada general: direccion 0x00 con TWGCE puesto.
    reset_dut(); mm_semiper = 24;
    esclavo_listo(0x42, 0x00, true);
    mm_start();
    chk_bool("la llamada general se reconoce con TWGCE", mm_tx(0x00), true);
    chk_bool("ACK del dato de llamada general", mm_tx(0x7E), true);
    mm_stop(); mm_espera(60);
    chk_seq("estados de la llamada general", log_estados,
            {ST_SR_GC_A, ST_SR_GDAT_A, ST_SR_STOP});
    chk_seq("dato de la llamada general", log_datos, {0x7E});

    // Sin TWGCE la llamada general se ignora.
    reset_dut(); mm_semiper = 24;
    esclavo_listo(0x42, 0x00, false);
    mm_start();
    chk_bool("sin TWGCE la llamada general se ignora", mm_tx(0x00), false);
    mm_stop(); mm_espera(40);

    // TWAMR: la mascara hace que un bit no se compare, asi que el chip
    // responde a un RANGO. Con 0x02 (bit 1 de la direccion) responde a 0x42 y
    // a 0x43, pero no a 0x44.
    reset_dut(); mm_semiper = 24;
    esclavo_listo(0x42, 0x02);
    mm_start();
    chk_bool("con mascara responde a su direccion", mm_tx((uint8_t)(0x42 << 1)), true);
    mm_stop(); mm_espera(40);
    mm_start();
    chk_bool("con mascara responde a la vecina enmascarada",
             mm_tx((uint8_t)(0x43 << 1)), true);
    mm_stop(); mm_espera(40);
    mm_start();
    chk_bool("la mascara NO abre direcciones de otro bit",
             mm_tx((uint8_t)(0x44 << 1)), false);
    mm_stop(); mm_espera(40);
}

// ========================================================== D. esclavo TX
static void fase_esclavo_tx() {
    fase = "esclavo transmisor";
    reset_dut();
    mm_semiper = 24;
    esclavo_listo(0x42);
    esclavo_envia = {0xDE, 0xAD, 0xBE};

    mm_start();
    chk_bool("reconoce su direccion con R/W=1",
             mm_tx((uint8_t)((0x42 << 1) | 1)), true);
    chk("primer byte que manda el esclavo", mm_rx(true), 0xDE);
    chk("segundo byte", mm_rx(true), 0xAD);
    chk("tercer byte, con NACK del maestro", mm_rx(false), 0xBE);
    mm_stop();
    mm_espera(80);

    // Tras el NACK el esclavo se retira: la hoja de datos da 0xC0 y vuelve a
    // no dirigido. El STOP posterior ya no le concierne, asi que NO hay 0xA0.
    chk_seq("secuencia del esclavo transmisor", log_estados,
            {ST_ST_SLA_A, ST_ST_DAT_A, ST_ST_DAT_A, ST_ST_DAT_N});
}

// ============================================== E. estiramiento de reloj
// El esclavo del banco retiene SCL despues de cada byte. Un maestro que cuente
// semiperiodos sin mirar el pin manda el bit siguiente encima, y aqui se ve.
static void fase_estiramiento() {
    fase = "estiramiento de reloj";
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    esclavo.estirar = 137;                  // un numero feo a proposito
    esclavo.a_enviar = {0x5A, 0xA5};
    maestro_listo();

    chk("START", paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)(0x50 << 1));
    chk("SLA+W con el esclavo estirando", paso_maestro(0), ST_MT_SLA_A);
    wr(A_TWDR, 0x99);
    chk("dato con el esclavo estirando", paso_maestro(0), ST_MT_DAT_A);
    chk("START repetido", paso_maestro(TWSTA), ST_REPSTART);
    wr(A_TWDR, (uint8_t)((0x50 << 1) | 1));
    chk("SLA+R con el esclavo estirando", paso_maestro(0), ST_MR_SLA_A);
    chk("lectura con ACK", paso_maestro(TWEA), ST_MR_DAT_A);
    chk("el byte llega intacto pese al estiramiento", mira(A_TWDR), 0x5A);
    chk("segunda lectura con NACK", paso_maestro(0), ST_MR_DAT_N);
    chk("segundo byte intacto", mira(A_TWDR), 0xA5);
    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 20000 && (mira(A_TWCR) & TWSTO); i++) tick();
    chk("el esclavo recibio el dato correcto",
        esclavo.recibido.empty() ? 0xFFu : esclavo.recibido[0], 0x99u);
}

// ==================================================== F. arbitraje
// LO QUE DEFINE EL ARBITRAJE: quien SUELTA la linea y la lee BAJA es que tiene
// enfrente a alguien tirando de ella, y ha perdido. Quien la lee tal como la
// dejo sigue. No hace falta un segundo maestro completo para probarlo: basta
// con tirar de SDA en el bit exacto, que es lo que haria ese otro maestro.
//
// Y HAY QUE TIRAR CON SCL BAJO. Tirar de SDA con SCL alto no es un bit: es un
// START, y el DUT lo leeria como tal. Esa es justamente la disciplina que
// hace que un bus de dos hilos pueda distinguir datos de marcas de trama.
static void espera_scl(bool nivel, long tope = 40000) {
    for (long i = 0; i < tope; i++) { if (bus_scl == nivel) return; tick(); }
    chk("SCL no llego al nivel esperado", 0, 1);
}

static void fase_arbitraje() {
    // --- PERDER EN UN DATO: 0x38 inmediato ---
    // Aqui el DUT ya esta dirigido, asi que la hoja de datos no espera a nada:
    // suelta el bus en ese mismo bit, sin STOP y sin perder el dato.
    fase = "arbitraje: perder en un dato";
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    maestro_listo();
    chk("START", paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)(0x50 << 1));
    chk("SLA+W", paso_maestro(0), ST_MT_SLA_A);
    wr(A_TWDR, 0xFF);                            // todos unos: soltamos siempre
    wr(A_TWCR, TWINT | TWEN);
    correr(4);
    mm_sda_pull = true;                          // otro maestro manda un cero
    if (!esperar_twint(40000)) chk("el DUT nota que perdio", 0, 1);
    chk("arbitraje perdido en un dato", estado(), ST_ARB_LOST);
    chk_bool("suelta SCL al perder", dut->scl_pull == 0, true);
    chk_bool("suelta SDA al perder", dut->sda_pull == 0, true);
    chk("el dato NO se pierde: TWDR sigue cargado", mira(A_TWDR), 0xFF);
    mm_sda_pull = false;
    wr(A_TWCR, TWINT | TWEN);
    mm_espera(40);

    // --- NO perder con los ceros propios ---
    // Un maestro que mire la linea sin tener en cuenta lo que el mismo conduce
    // se rinde en cada cero que transmite. Aqui el otro tira a la vez que el
    // DUT, que es lo que pasa cuando los dos mandan el mismo bit.
    fase = "arbitraje: coincidir no es perder";
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    maestro_listo();
    chk("START", paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)(0x50 << 1));            // 1010 0000
    wr(A_TWCR, TWINT | TWEN);
    // Acompañar al DUT en sus cinco ceros del final (bits 4..0).
    for (int b = 7; b >= 4; b--) { espera_scl(true); espera_scl(false); }
    correr(3);
    mm_sda_pull = true;
    for (int b = 3; b >= 0; b--) { espera_scl(true); espera_scl(false); }
    mm_sda_pull = false;
    if (!esperar_twint(40000)) chk("el DUT sigue de maestro", 0, 1);
    chk("coincidir en un cero NO es perder", estado(), ST_MT_SLA_A);
    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 20000 && (mira(A_TWCR) & TWSTO); i++) tick();

    // --- PERDER EN LA DIRECCION y resultar ser el llamado ---
    // La hoja de datos no da 0x38 aqui, sino 0x68: perdimos el bus Y el que
    // gano nos esta hablando a nosotros. Un TWI que se limite a reportar 0x38
    // pierde la trama entera, y el sensor que hablaba con nosotros se queda
    // sin respuesta.
    //
    // Este es el unico sitio del banco donde el maestro del banco conduce las
    // DOS lineas a la vez que el DUT: es multimaestro de verdad, con la
    // sincronizacion de reloj saliendo sola del colector abierto.
    fase = "arbitraje: perder y ser llamado";
    reset_dut();
    mm_semiper = 10;
    esclavo_listo(0x44);                         // nuestra direccion de esclavo
    wr(A_TWBR, 2); wr(A_TWSR, 0);
    wr(A_TWCR, (uint8_t)(TWINT | TWSTA | TWEN | TWEA));
    if (!esperar_twint(40000)) chk("START del DUT", 0, 1);
    chk("START", estado(), ST_START);
    log_estados.clear();
    wr(A_TWDR, (uint8_t)(0x50 << 1));            // queremos hablar con 0x50
    wr(A_TWCR, TWINT | TWEN | TWEA);

    mm_scl_pull = true;                          // el banco entra en el reloj
    {
        uint8_t otro = (uint8_t)(0x44 << 1);     // 1000 1000: gana en el bit 6
        for (int b = 7; b >= 0; b--) mm_bit(((otro >> b) & 1) != 0);
        bool ack = !mm_bit(true);
        chk_bool("el DUT reconoce la direccion aunque acabe de perder", ack, true);
    }
    mm_espera(60);
    chk_seq("perder el bus y ser llamado da 0x68, no 0x38", log_estados,
            {ST_SR_ARB_SLA});
    atiende = nullptr;
    mm_reposo();
}

// ================================================= G. frecuencia de SCL
// f_SCL = f_CPU / (16 + 2*TWBR*4^TWPS). Es una promesa de la hoja de datos y
// la unica forma de comprobarla es MEDIR el pin: un TWI que cuente mal el
// semiperiodo funciona perfectamente contra cualquier banco y luego pone el
// bus de una placa a 71 kHz cuando el programa pidio 100.
static void fase_frecuencia() {
    fase = "frecuencia de SCL";
    struct Caso { uint8_t twbr, twps; };
    const Caso casos[] = {{0,0},{2,0},{10,0},{72,0},{255,0},{3,1},{5,2},{2,3}};

    for (const Caso &c : casos) {
        reset_dut();
        esclavo.activo = true; esclavo.direccion = 0x50;
        maestro_listo(c.twbr, c.twps);
        chk("START", paso_maestro(TWSTA), ST_START);
        wr(A_TWDR, (uint8_t)(0x50 << 1));
        wr(A_TWCR, TWINT | TWEN);

        // Medir entre flancos de subida consecutivos, ya dentro del byte.
        long t[4] = {0,0,0,0};
        int n = 0;
        bool ant = bus_scl;
        for (long i = 0; i < 400000 && n < 4; i++) {
            tick();
            if (bus_scl && !ant) t[n++] = ciclos;
            ant = bus_scl;
        }
        long esperado = 16 + 2L * c.twbr * (1L << (2 * c.twps));
        if (n >= 4) {
            chk("periodo de SCL", (uint32_t)(t[3] - t[2]), (uint32_t)esperado);
            chk("periodo estable", (uint32_t)(t[2] - t[1]), (uint32_t)esperado);
        } else {
            chk("no se vieron flancos de SCL", 0, 1);
        }
        esperar_twint();
        wr(A_TWCR, TWINT | TWSTO | TWEN);
        for (int i = 0; i < 200000 && (mira(A_TWCR) & TWSTO); i++) tick();
    }
}

// ====================================== H. TWWC, error de bus y recuperacion
static void fase_banderas() {
    fase = "TWWC, error de bus y TWSTO";
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    maestro_listo();

    // TWWC: escribir TWDR con TWINT bajo no carga el dato, solo marca.
    chk("START", paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)(0x50 << 1));
    wr(A_TWCR, TWINT | TWEN);
    correr(6);                                  // ya en marcha: TWINT bajo
    chk_bool("TWINT esta bajo durante la transferencia",
             (mira(A_TWCR) & TWINT) == 0, true);
    wr(A_TWDR, 0x5A);                           // escritura fuera de tiempo
    chk("TWWC se levanta", mira(A_TWCR) & TWWC, TWWC);
    chk("TWDR NO se carga con TWINT bajo", mira(A_TWDR), (uint8_t)(0x50 << 1));
    if (!esperar_twint()) chk("TWINT", 0, 1);
    chk("la transferencia sigue su curso", estado(), ST_MT_SLA_A);
    wr(A_TWDR, 0x33);
    chk("ahora TWDR si se carga", mira(A_TWDR), 0x33);
    wr(A_TWCR, TWINT | TWEN);
    chk("TWWC se limpia con la escritura valida de TWCR",
        mira(A_TWCR) & TWWC, 0);
    if (!esperar_twint()) chk("TWINT", 0, 1);
    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 8000 && (mira(A_TWCR) & TWSTO); i++) tick();

    // Error de bus: un STOP en mitad de un byte, con el DUT de esclavo.
    fase = "error de bus";
    reset_dut();
    mm_semiper = 24;
    esclavo_listo(0x42);
    mm_start();
    chk_bool("la direccion se reconoce", mm_tx((uint8_t)(0x42 << 1)), true);
    // Medio byte y un STOP ilegal: SDA sube con SCL alto en mitad del dato.
    for (int b = 0; b < 4; b++) {
        mm_sda_pull = true;  mm_espera(mm_semiper);
        mm_soltar_scl();     mm_espera(mm_semiper);
        mm_scl_pull = true;  mm_espera(2);
    }
    mm_sda_pull = true;  mm_espera(mm_semiper);
    mm_soltar_scl();     mm_espera(mm_semiper);
    mm_sda_pull = false;                        // STOP a mitad de byte
    mm_espera(mm_semiper * 3);
    chk_seq("el STOP ilegal da error de bus", log_estados,
            {ST_SR_SLA_A, ST_BUS_ERROR});

    // De 0x00 solo se sale escribiendo TWSTO, y en esclavo NO genera STOP.
    atiende = nullptr;
    wr(A_TWCR, TWINT | TWSTO | TWEN | TWEA);
    mm_espera(60);
    chk("TWSTO se limpia solo", mira(A_TWCR) & TWSTO, 0);
    chk("y el TWI vuelve a reposo", estado(), ST_NADA);
    chk_bool("sin generar nada en el bus", bus_sda && bus_scl, true);
}

// =============================================== I. TWEN a cero suelta los pines
static void fase_twen() {
    fase = "TWEN";
    reset_dut();
    chk_bool("con TWEN a cero el TWI no toca los pines",
             dut->scl_pull == 0 && dut->sda_pull == 0, true);
    chk_bool("y lo dice", dut->twen == 0, true);
    wr(A_TWCR, TWEN);
    chk_bool("con TWEN a uno se adueña de PC4 y PC5", dut->twen == 1, true);

    // A mitad de una transferencia, quitar TWEN suelta el bus.
    esclavo.activo = true; esclavo.direccion = 0x50;
    maestro_listo();
    wr(A_TWCR, TWINT | TWSTA | TWEN);
    esperar_twint();
    wr(A_TWDR, (uint8_t)(0x50 << 1));
    wr(A_TWCR, TWINT | TWEN);
    correr(8);
    wr(A_TWCR, 0x00);                           // TWEN fuera
    correr(4);
    chk_bool("al quitar TWEN se sueltan las dos lineas",
             dut->scl_pull == 0 && dut->sda_pull == 0, true);
    chk_bool("y el bus vuelve arriba", bus_sda && bus_scl, true);

    // Los registros siguen ahi: TWEN no es un reset.
    chk("TWBR sobrevive a TWEN=0", mira(A_TWBR), 2);

    // PERO LA MAQUINA SI VUELVE A REPOSO. Apagar el TWI a mitad de trama y
    // volver a encenderlo no puede reanudar la transferencia vieja: el bus ya
    // no es el que era. Tiene que quedarse esperando un START como si acabara
    // de arrancar, y eso se comprueba haciendo uno.
    wr(A_TWCR, TWEN);
    correr(4);
    chk_bool("con el TWI recien encendido las lineas estan sueltas",
             dut->scl_pull == 0 && dut->sda_pull == 0, true);
    chk("y no hay estado pendiente", estado(), ST_NADA);
    chk("un START limpio tras apagar y encender",
        paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)(0x50 << 1));
    chk("y la trama arranca de cero", paso_maestro(0), ST_MT_SLA_A);
    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 8000 && (mira(A_TWCR) & TWSTO); i++) tick();
}

// ============================== J. barrido de las 128 direcciones de esclavo
// Reconocer la direccion propia es lo unico que hace que un esclavo sea ESE
// esclavo, y un fallo de un solo bit en la comparacion solo se ve si se
// prueban todas. Cada direccion se prueba dos veces: que conteste a la suya y
// que NO conteste a la de al lado.
static void fase_barrido_direcciones() {
    fase = "barrido de las 128 direcciones";
    reset_dut();
    mm_semiper = 6;
    for (int propia = 0; propia < 128; propia++) {
        esclavo_listo((uint8_t)propia);
        esclavo_envia = {(uint8_t)(propia ^ 0x5A)};

        mm_start();
        chk_bool("contesta a su direccion",
                 mm_tx((uint8_t)(propia << 1)), true);
        mm_stop(); mm_espera(12);

        int otra = (propia + 1) & 0x7F;
        mm_start();
        chk_bool("no contesta a la de al lado",
                 mm_tx((uint8_t)(otra << 1)), false);
        mm_stop(); mm_espera(12);

        // Y con R/W=1, que ademas manda un byte.
        esclavo_idx = 0;
        mm_start();
        chk_bool("contesta a su direccion con R/W=1",
                 mm_tx((uint8_t)((propia << 1) | 1)), true);
        chk("manda el byte que le dio el programa",
            mm_rx(false), (uint8_t)(propia ^ 0x5A));
        mm_stop(); mm_espera(12);
    }
    atiende = nullptr;
}

// ==================== K. barrido de la mascara de direccion sobre las 128
// TWAMR no es un segundo esclavo: es una mascara de «no me importa» por bit,
// y define un CONJUNTO de direcciones. El oraculo es la formula de la hoja de
// datos, ((recibida ^ TWAR) & ~TWAMR) == 0, evaluada aparte del RTL.
static void fase_barrido_mascara() {
    fase = "barrido de TWAMR sobre las 128 direcciones";
    reset_dut();
    mm_semiper = 6;
    const uint8_t mascaras[] = {0x00, 0x02, 0x06, 0x1E, 0x60, 0xFE};
    const uint8_t bases[]    = {0x42, 0x50, 0x01, 0x7F};

    for (uint8_t base : bases) {
        for (uint8_t m : mascaras) {
            esclavo_listo(base, m);
            for (int a = 0; a < 128; a++) {
                bool esperado = (((uint8_t)a ^ base) & (uint8_t)(~(m >> 1) & 0x7F)) == 0;
                mm_start();
                bool ack = mm_tx((uint8_t)(a << 1));
                chk_bool("la mascara decide igual que la formula", ack, esperado);
                mm_stop(); mm_espera(8);
            }
        }
    }
    atiende = nullptr;
}

// ================================ L. trafico aleatorio en los dos sentidos
// Semilla fija: el banco tiene que dar lo mismo en cada ejecucion, si no un
// fallo intermitente es imposible de perseguir.
static uint32_t sem = 0x1234ABCDu;
static uint32_t aleat() {
    sem ^= sem << 13; sem ^= sem >> 17; sem ^= sem << 5;
    return sem;
}

static void fase_aleatorio() {
    fase = "trafico aleatorio";
    const int TRANSACCIONES = 120;

    for (int t = 0; t < TRANSACCIONES; t++) {
        reset_dut();
        uint8_t dir  = (uint8_t)(aleat() % 127 + 1);       // 0 es la llamada general
        uint8_t twbr = (uint8_t)(aleat() % 8);
        int     n    = (int)(aleat() % 4) + 1;
        bool    leer = (aleat() & 1) != 0;

        esclavo.activo = true; esclavo.direccion = dir;
        std::vector<uint8_t> esperados;
        for (int i = 0; i < n; i++) esperados.push_back((uint8_t)aleat());
        if (leer) esclavo.a_enviar = esperados;
        maestro_listo(twbr, 0);

        chk("START", paso_maestro(TWSTA), ST_START);
        wr(A_TWDR, (uint8_t)((dir << 1) | (leer ? 1 : 0)));
        chk("SLA reconocido", paso_maestro(0), leer ? ST_MR_SLA_A : ST_MT_SLA_A);

        if (leer) {
            for (int i = 0; i < n; i++) {
                bool ultimo = (i == n - 1);
                chk("lectura", paso_maestro(ultimo ? 0 : TWEA),
                    ultimo ? ST_MR_DAT_N : ST_MR_DAT_A);
                chk("byte leido", mira(A_TWDR), esperados[i]);
            }
        } else {
            for (int i = 0; i < n; i++) {
                wr(A_TWDR, esperados[i]);
                chk("escritura", paso_maestro(0), ST_MT_DAT_A);
            }
        }
        wr(A_TWCR, TWINT | TWSTO | TWEN);
        for (int i = 0; i < 40000 && (mira(A_TWCR) & TWSTO); i++) tick();
        chk_bool("el bus queda libre", bus_sda && bus_scl, true);

        if (!leer) {
            chk("bytes que llegaron", (uint32_t)esclavo.recibido.size(), (uint32_t)n);
            for (int i = 0; i < n && i < (int)esclavo.recibido.size(); i++)
                chk("byte entregado", esclavo.recibido[i], esperados[i]);
        }
    }
}

// ================================================== M. ruido en las lineas
// CON ONDAS PERFECTAS UN FILTRO PARECE DECORATIVO. Es la leccion que este
// proyecto ya pago con la USART: el mutante que quitaba el voto por mayoria
// del receptor sobrevivia a todo el banco hasta que se inyecto ruido de
// verdad. Aqui es peor que en la USART, porque en un bus de dos hilos un pico
// no produce un bit erroneo: un flanco falso de SDA con SCL alto es un START o
// un STOP INVENTADO, y se lleva la trama entera por delante.
//
// El pico se barre por TODAS las posiciones de una transferencia completa, una
// posicion por pasada, en las dos lineas. Un sincronizador de dos etapas NO
// basta para esto -propaga el pulso, que es justo lo que hace un
// sincronizador-; hace falta el filtro de coincidencia.
static void fase_ruido() {
    fase = "ruido de un ciclo barrido por la trama";

    // Primero, medir cuanto dura una transferencia limpia para saber por
    // cuantas posiciones hay que barrer.
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    maestro_listo();
    long t0 = ciclos;
    chk("START", paso_maestro(TWSTA), ST_START);
    wr(A_TWDR, (uint8_t)(0x50 << 1));
    chk("SLA+W", paso_maestro(0), ST_MT_SLA_A);
    wr(A_TWDR, 0x5A);
    chk("dato", paso_maestro(0), ST_MT_DAT_A);
    long duracion = ciclos - t0;

    // Y ahora la misma transferencia con un pico en cada posicion.
    for (int linea = 0; linea < 2; linea++) {
        for (long pos = 4; pos < duracion; pos += 3) {
            reset_dut();
            esclavo = EsclavoI2C();
            esclavo.activo = true; esclavo.direccion = 0x50;
            esclavo.recibido.clear();
            maestro_listo();

            ruido_linea = linea;
            ruido_activo = true;
            ruido_en = ciclos + pos + 30;   // 30: lo que cuesta el START

            uint8_t e1 = paso_maestro(TWSTA);
            wr(A_TWDR, (uint8_t)(0x50 << 1));
            uint8_t e2 = paso_maestro(0);
            wr(A_TWDR, 0x5A);
            uint8_t e3 = paso_maestro(0);
            ruido_activo = false;

            // El pico no puede cambiar NADA: ni el estado, ni el byte que
            // recibe el esclavo. Es un pulso mas corto que un ciclo de reloj y
            // el bus lo tiene que descartar, como dice la hoja de datos.
            chk("el pico no altera el START", e1, ST_START);
            chk("el pico no altera la direccion", e2, ST_MT_SLA_A);
            chk("el pico no altera el dato", e3, ST_MT_DAT_A);
            chk("y el esclavo recibe el byte intacto",
                esclavo.recibido.empty() ? 0xFFu : esclavo.recibido[0], 0x5Au);

            wr(A_TWCR, TWINT | TWSTO | TWEN);
            for (int i = 0; i < 8000 && (mira(A_TWCR) & TWSTO); i++) tick();
        }
    }
}

// ============================ N. un START pedido justo despues de un STOP
// EL FALLO ORIGINAL ERA UNA CARRERA, y una carrera no se prueba esperando a
// caer en el ciclo exacto. El `stop_det` del propio STOP llega tres ciclos
// tarde -sincronizador mas filtro-, cuando la maquina ya ha cambiado de
// estado, y pisaba el START que el programa acababa de pedir: el TWI se
// quedaba parado con TWSTA puesto para siempre.
//
// Se caza barriendo el RETARDO entero entre que TWSTO se limpia y que el
// programa escribe TWCR. Una de las posiciones cae en el ciclo malo, y con
// barrerlas todas deja de depender de la suerte.
static void fase_start_tras_stop() {
    fase = "START pedido justo despues de un STOP";
    for (int d = 0; d < 40; d++) {
        reset_dut();
        esclavo.activo = true; esclavo.direccion = 0x50;
        maestro_listo();

        chk("primer START", paso_maestro(TWSTA), ST_START);
        wr(A_TWDR, (uint8_t)(0x50 << 1));
        chk("SLA+W", paso_maestro(0), ST_MT_SLA_A);
        wr(A_TWCR, TWINT | TWSTO | TWEN);
        for (int i = 0; i < 8000 && (mira(A_TWCR) & TWSTO); i++) tick();

        correr(d);                       // el retardo que se barre
        chk("el START siguiente sale sea cual sea el retardo",
            paso_maestro(TWSTA), ST_START);
        wr(A_TWDR, (uint8_t)(0x50 << 1));
        chk("y la trama sigue", paso_maestro(0), ST_MT_SLA_A);
        wr(A_TWCR, TWINT | TWSTO | TWEN);
        for (int i = 0; i < 8000 && (mira(A_TWCR) & TWSTO); i++) tick();
    }
}

// ========================= O. los rincones que destapo la puerta de cobertura
// «0 divergencias» no dice nada de lo que no se ejecuto. Estos cuatro caminos
// existian en el RTL, se sintetizaban y no los pisaba nadie; los senalo `make
// coverage`, no el banco. Cada uno es un comportamiento de la hoja de datos.
static void fase_rincones() {
    // ---- TWIE: la bandera y la INTERRUPCION son cosas distintas ----
    // TWINT se pone igual con TWIE bajo -eso es el sondeo sin interrupciones,
    // que es como trabaja `Wire` por dentro-, pero la linea de interrupcion
    // solo se levanta con TWIE puesto.
    fase = "TWIE separa la bandera de la interrupcion";
    reset_dut();
    esclavo.activo = true; esclavo.direccion = 0x50;
    maestro_listo();
    chk("START sin TWIE", paso_maestro(TWSTA), ST_START);
    chk_bool("TWINT se pone igual sin TWIE", (mira(A_TWCR) & TWINT) != 0, true);
    chk_bool("pero la interrupcion NO se levanta", dut->irq == 0, true);
    wr(A_TWCR, (uint8_t)(TWEN | TWIE));          // encender TWIE sin tocar TWINT
    correr(2);
    chk_bool("al encender TWIE la interrupcion sale", dut->irq == 1, true);
    chk_bool("y sigue TWINT puesta", (mira(A_TWCR) & TWINT) != 0, true);
    wr(A_TWCR, (uint8_t)(TWINT | TWEN));         // limpiar TWINT y apagar TWIE
    correr(2);
    chk_bool("al limpiar TWINT la interrupcion cae", dut->irq == 0, true);
    wr(A_TWCR, TWINT | TWSTO | TWEN);
    for (int i = 0; i < 8000 && (mira(A_TWCR) & TWSTO); i++) tick();

    // ---- otro maestro se adelanta mientras esperamos el bus ----
    // Con TWSTA puesto y el bus OCUPADO, el TWI espera. Si mientras espera
    // llega un START ajeno, tiene que ponerse a escuchar por si le llaman, y
    // reintentar su propio START cuando el bus quede libre.
    fase = "otro se adelanta mientras esperamos el bus";
    reset_dut();
    mm_semiper = 10;
    esclavo_listo(0x44);
    wr(A_TWBR, 2); wr(A_TWSR, 0);
    log_estados.clear();
    mm_sda_pull = true; mm_scl_pull = true;      // el bus, tomado por otro
    correr(30);
    wr(A_TWCR, (uint8_t)(TWINT | TWSTA | TWEN | TWEA));
    correr(30);
    chk_bool("con el bus ocupado no sale ningun START", dut->sda_pull == 0, true);
    // Y ahora el otro hace su START ANTES de que el bus llegue a declararse
    // libre. El momento importa: si se le da tiempo al TWI a ver el bus libre,
    // arranca su propio START -y hace bien-, y entonces lo que se prueba es el
    // arbitraje, no la espera. El TWI cuenta `semiper` ciclos con las dos
    // lineas altas, asi que el START ajeno tiene que caer dentro de esa
    // ventana.
    mm_scl_pull = false; mm_sda_pull = false;
    correr(2);
    mm_sda_pull = true;                          // START, con el TWI aun esperando
    correr(mm_semiper);
    mm_scl_pull = true;
    correr(2);
    {
        uint8_t sla = (uint8_t)(0x44 << 1);
        for (int b = 7; b >= 0; b--) mm_bit(((sla >> b) & 1) != 0);
        bool ack = !mm_bit(true);
        chk_bool("nos ponemos a escuchar y reconocemos la llamada", ack, true);
    }
    mm_espera(40);
    chk_seq("y el estado es el de esclavo receptor, sin haber arrancado nada",
            log_estados, {ST_SR_SLA_A});
    atiende = nullptr;  mm_reposo();

    // ---- perder el arbitraje en la direccion SIN ser el llamado ----
    // La hoja de datos distingue: si el que gana nos llama, 0x68; si no, 0x38
    // al terminar el byte de direccion, y a esperar.
    fase = "perder la direccion y no ser el llamado";
    reset_dut();
    mm_semiper = 10;
    esclavo_listo(0x11);                          // nuestra direccion, distinta
    wr(A_TWBR, 2); wr(A_TWSR, 0);
    wr(A_TWCR, (uint8_t)(TWINT | TWSTA | TWEN | TWEA));
    if (!esperar_twint()) chk("START", 0, 1);
    chk("START", estado(), ST_START);
    log_estados.clear();
    wr(A_TWDR, (uint8_t)(0x50 << 1));             // queriamos hablar con 0x50
    wr(A_TWCR, TWINT | TWEN | TWEA);
    mm_scl_pull = true;
    {
        uint8_t otro = (uint8_t)(0x44 << 1);      // gana, y no es nuestra
        for (int b = 7; b >= 0; b--) mm_bit(((otro >> b) & 1) != 0);
        mm_bit(true);                             // nadie contesta
    }
    mm_espera(40);
    chk_seq("sin ser el llamado, el codigo es 0x38", log_estados, {ST_ARB_LOST});
    atiende = nullptr;  mm_reposo();

    // ---- TWSTO en esclavo: recupera sin generar nada en el bus ----
    fase = "TWSTO en esclavo recupera sin tocar el bus";
    reset_dut();
    mm_semiper = 10;
    esclavo_listo(0x42);
    atiende = nullptr;                            // atendemos a mano
    mm_start();
    mm_tx((uint8_t)(0x42 << 1));
    if (!esperar_twint()) chk("direccion reconocida", 0, 1);
    chk("dirigido como esclavo receptor", estado(), ST_SR_SLA_A);
    // El programa decide abandonar: TWSTO en esclavo no genera STOP, sólo
    // devuelve el TWI a no dirigido y suelta las lineas.
    wr(A_TWCR, (uint8_t)(TWINT | TWSTO | TWEN | TWEA));
    correr(20);
    chk("TWSTO se limpia solo", mira(A_TWCR) & TWSTO, 0);
    chk("y el estado vuelve a reposo", estado(), ST_NADA);
    chk_bool("sin conducir nada", dut->sda_pull == 0 && dut->scl_pull == 0, true);
    mm_reposo();
    correr(20);
    chk_bool("el bus queda como estaba", bus_sda && bus_scl, true);
}

// ================================== P. semantica de registros (nivel L2)
// Los bits que la hoja de datos declara de SOLO LECTURA o INEXISTENTES tienen
// que comportarse como tales. Es compatibilidad L2 pura, y es de lo que nadie
// se acuerda hasta que un programa escribe un registro entero con `|=` y se
// lleva por delante el estado.
static void fase_registros() {
    fase = "semantica de registros";
    reset_dut();

    // ---- TWSR: TWS7..TWS3 son de solo lectura, el bit 2 no existe ----
    wr(A_TWCR, TWEN);
    chk("TWSR en reposo trae el estado 0xF8", mira(A_TWSR) & 0xF8, ST_NADA);
    wr(A_TWSR, 0x00);
    chk("escribir ceros en TWSR NO borra el estado", mira(A_TWSR) & 0xF8, ST_NADA);
    wr(A_TWSR, 0xFF);
    chk("ni escribir unos lo cambia", mira(A_TWSR) & 0xF8, ST_NADA);
    chk("el bit 2 de TWSR no existe y se lee cero", mira(A_TWSR) & 0x04, 0);
    chk("y TWPS si se guarda", mira(A_TWSR) & 0x03, 0x03);
    wr(A_TWSR, 0x02);
    chk("TWPS se puede cambiar", mira(A_TWSR) & 0x03, 0x02);

    // ---- TWCR: el bit 1 no existe; TWWC es de solo lectura ----
    wr(A_TWCR, 0xFF);
    chk("el bit 1 de TWCR no existe y se lee cero", mira(A_TWCR) & 0x02, 0);
    wr(A_TWCR, (uint8_t)(TWEN | TWWC));
    chk("TWWC no se puede poner escribiendo", mira(A_TWCR) & TWWC, 0);

    // ---- TWAMR: el bit 0 no existe ----
    wr(A_TWAMR, 0xFF);
    chk("el bit 0 de TWAMR no existe", mira(A_TWAMR) & 0x01, 0);
    chk("y los otros siete si se guardan", mira(A_TWAMR), 0xFE);

    // ---- TWAR y TWBR son almacenamiento entero ----
    for (int v = 0; v < 256; v += 17) {
        wr(A_TWAR, (uint8_t)v);
        chk("TWAR guarda el byte entero", mira(A_TWAR), (uint8_t)v);
        wr(A_TWBR, (uint8_t)v);
        chk("TWBR guarda el byte entero", mira(A_TWBR), (uint8_t)v);
    }

    // ---- los seis viven en la I/O extendida y nadie mas contesta ----
    // El espacio de I/O NO es RAM: una direccion sin implementar se lee 0x00.
    for (int a = 0x90; a < 0xA0; a++) {
        bool mio = (a >= A_TWBR && a <= A_TWAMR);
        dut->io_addr = (uint8_t)a; dut->io_we = 0; dut->io_re = 0;
        resolver(); dut->eval();
        chk_bool("solo las seis direcciones del TWI responden",
                 dut->io_sel != 0, mio);
    }
}

// ===================================================================== main
int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    traza = getenv("TWI_TRACE") != nullptr;
    dut = new Vaxioma_twi;
    dut->clk = 0; dut->rst_n = 0;
    dut->io_addr = 0; dut->io_we = 0; dut->io_re = 0; dut->io_wdata = 0;
    dut->scl_pin = 1; dut->sda_pin = 1;

    auto pedida = [&](const char *n) {
        if (argc <= 1) return true;
        for (int i = 1; i < argc; i++) if (!strcmp(argv[i], n)) return true;
        return false;
    };
    #define CORRE(n, f) if (pedida(n)) f()
    CORRE("mtx", fase_maestro_tx);
    CORRE("nack", fase_nack);
    CORRE("mrx", fase_maestro_rx);
    CORRE("rep", fase_repstart);
    CORRE("srx", fase_esclavo_rx);
    CORRE("sopt", fase_esclavo_opciones);
    CORRE("stx", fase_esclavo_tx);
    CORRE("estira", fase_estiramiento);
    CORRE("arb", fase_arbitraje);
    CORRE("freq", fase_frecuencia);
    CORRE("band", fase_banderas);
    CORRE("twen", fase_twen);
    CORRE("dirs", fase_barrido_direcciones);
    CORRE("mask", fase_barrido_mascara);
    CORRE("rand", fase_aleatorio);
    CORRE("ruido", fase_ruido);
    CORRE("tras_stop", fase_start_tras_stop);
    CORRE("rincones", fase_rincones);
    CORRE("regs", fase_registros);

    // LA COBERTURA HAY QUE ESCRIBIRLA, no basta con compilar con --coverage.
    // Sin esto el banco se ejecuta entero, pasa entero, y sus 5 800
    // comprobaciones no cuentan para `make coverage`: el modulo sale al 65 %
    // porque lo unico que lo pisa son los programas del diferencial. Es un
    // septimo sitio que tocar al añadir un periferico, y no estaba en la lista
    // de seis.
#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    printf("  %ld comprobaciones en %ld ciclos, %d fallos\n", checks, ciclos, fails);
    delete dut;
    return fails ? 1 : 0;
}
