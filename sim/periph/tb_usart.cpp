// AxiomaCore-328 - USART0 contra un receptor de verdad
// SPDX-License-Identifier: Apache-2.0
//
// POR QUÉ ESTE BANCO ES OBLIGATORIO Y NO UN EXTRA. Porque simavr NO MODELA EL
// CABLE. Su USART transporta bytes enteros por IRQs internas y aproxima el
// tiempo con `cycles_per_byte`: no hay bit de arranque, ni paridad, ni bits de
// parada, ni pin. Un RTL que pusiera los bits en orden inverso, o que se comiera
// el bit de parada, o que contara mal el divisor, pasaría el contraste contra
// simavr sin despeinarse.
//
// (Y su cuenta de tiempo de trama SUMA SIEMPRE un bit de paridad, esté activada
// o no. Otra razón para no usarlo como referencia de temporización.)
//
// Así que aquí hay dos modelos escritos desde la hoja de datos, y ninguno mira
// el RTL:
//
//   RECEPTOR   muestrea el pin TXD y decodifica la trama: encuentra el flanco
//              de arranque, mide el periodo de bit y saca dato, paridad y
//              parada. Comprueba ADEMÁS que el periodo sea exactamente
//              (UBRR+1)·16 ciclos —u 8 con U2X—, que es la fórmula del manual.
//   EMISOR     genera tramas sobre RXD con esa misma temporización, incluidas
//              las deliberadamente rotas: paridad mala y bit de parada a cero.
//
// Lo que se certifica: las cinco longitudes de palabra, las tres paridades, uno
// y dos bits de parada, con y sin U2X, varios divisores, el búfer de recepción
// de DOS niveles, el desbordamiento, y el efecto lateral de lectura de UDR0.

#include "Vaxioma_usart.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cstdint>
#include <random>
#include <vector>

static Vaxioma_usart *dut;
static int  fails = 0;
static long checks = 0;
static const char *fase = "";

static void chk(const char *que, uint32_t got, uint32_t exp) {
    checks++;
    if (got != exp && ++fails <= 15)
        printf("    FALLA [%s] %-30s obtenido=0x%02X esperado=0x%02X\n",
               fase, que, got, exp);
}

enum { A_UCSR0A = 0xA0, A_UCSR0B = 0xA1, A_UCSR0C = 0xA2,
       A_UBRR0L = 0xA4, A_UBRR0H = 0xA5, A_UDR0 = 0xA6 };

// Bits, con los nombres de avr-libc.
enum { RXC = 0x80, TXC = 0x40, UDRE = 0x20, FE = 0x10, DOR = 0x08, UPE = 0x04,
       U2X = 0x02, MPCM = 0x01 };
enum { RXEN = 0x10, TXEN = 0x08, UCSZ2 = 0x04 };

static void tick() { dut->clk = 1; dut->eval(); dut->clk = 0; dut->eval(); }

// Observación del banco: no levanta io_re, así que no dispara efectos
// laterales. Es la ventana del banco, no una lectura del programa.
static uint8_t peek(uint8_t a) {
    dut->io_addr = a; dut->io_re = 0; dut->io_we = 0; dut->eval();
    return dut->io_rdata;
}

// Lectura como la haría un programa: io_re alto durante un ciclo. Sobre UDR0
// esto SACA un byte del búfer — la trampa nº 11.
static uint8_t rd(uint8_t a) {
    dut->io_addr = a; dut->io_re = 1; dut->io_we = 0; dut->eval();
    uint8_t v = dut->io_rdata;
    tick();
    dut->io_re = 0; dut->eval();
    return v;
}

static void wr(uint8_t a, uint8_t d) {
    dut->io_addr = a; dut->io_wdata = d; dut->io_we = 1; dut->io_re = 0;
    dut->eval();
    tick();
    dut->io_we = 0; dut->eval();
}

static void run(int n) { for (int i = 0; i < n; i++) tick(); }

// ------------------------------------------------------------ configuración
struct Cfg {
    int  ubrr;
    bool u2x;
    int  databits;     // 5..9
    int  parity;       // 0 ninguna, 2 par, 3 impar
    int  stop;         // 1 o 2
    // El periodo de bit que manda la hoja de datos.
    int  periodo() const { return (ubrr + 1) * (u2x ? 8 : 16); }
    int  bits_trama() const { return 1 + databits + (parity ? 1 : 0) + stop; }
};

// NO SE RECONFIGURA CON EL TRANSMISOR EN MARCHA. La hoja de datos dice que el
// formato se fija antes de habilitar, y con razón: una trama en vuelo cambiaría
// de longitud a mitad de camino. Cambiarlo sin esperar hacía fallar la paridad
// de la PRIMERA trama de cada formato — y era fallo del banco, no del RTL.
// Mirar UDRE y TXC no vale: UDRE dice que el BUFER esta libre, no que el turno
// haya salido, y TXC se queda puesta de una trama anterior si nadie la limpia.
// Con los dos a uno el transmisor puede estar todavia sacando bits. Asi que se
// espera por tiempo: la trama mas larga posible del formato ANTERIOR.
static Cfg cfg_previa { 0, false, 9, 2, 2 };

static void configurar(const Cfg &c, bool rx, bool tx) {
    for (int i = 0; i < cfg_previa.periodo() * (cfg_previa.bits_trama() + 2); i++)
        tick();
    cfg_previa = c;
    uint8_t ucsz = (c.databits == 9) ? 3 : (c.databits - 5);
    wr(A_UCSR0C, (uint8_t)((c.parity << 4) | ((c.stop == 2) << 3) |
                           ((ucsz & 3) << 1)));
    wr(A_UBRR0H, (uint8_t)(c.ubrr >> 8));
    wr(A_UBRR0L, (uint8_t)(c.ubrr & 0xFF));
    wr(A_UCSR0A, c.u2x ? U2X : 0);
    wr(A_UCSR0B, (uint8_t)((rx ? RXEN : 0) | (tx ? TXEN : 0) |
                           ((c.databits == 9) ? UCSZ2 : 0)));
}

// ------------------------------------------------- el receptor del banco
// Espera un flanco de bajada, mide y decodifica. Devuelve false si no llegó
// nada, y rellena `err` si la trama está mal formada.
struct Trama { uint16_t dato; bool paridad_ok; bool parada_ok; int periodo; };

static bool recibir(const Cfg &c, Trama &t, long limite) {
    // 1. esperar el bit de arranque
    long i = 0;
    while (dut->txd && i < limite) { tick(); i++; }
    if (i >= limite) return false;

    // Ya estamos en el primer ciclo del bit de arranque. Se muestrea en el
    // CENTRO de cada bit, avanzando un periodo cada vez.
    int p = c.periodo();
    auto centro = [&](int n) {
        // lleva el reloj hasta el centro del bit n contando desde aquí
        static int pos = 0;
        (void)n; (void)pos;
    };
    (void)centro;

    // Al centro del bit de arranque.
    for (int k = 0; k < p / 2; k++) tick();
    t.parada_ok = true;
    if (dut->txd) t.parada_ok = false;      // el arranque tiene que ser 0

    uint16_t d = 0;
    bool par = (c.parity == 3);             // impar arranca en 1
    for (int b = 0; b < c.databits; b++) {
        for (int k = 0; k < p; k++) tick();
        if (dut->txd) { d |= (1u << b); par = !par; }
    }
    t.dato = d;

    t.paridad_ok = true;
    if (c.parity) {
        for (int k = 0; k < p; k++) tick();
        t.paridad_ok = (dut->txd ? 1 : 0) == (par ? 1 : 0);
    }

    for (int s = 0; s < c.stop; s++) {
        for (int k = 0; k < p; k++) tick();
        if (!dut->txd) t.parada_ok = false;
    }
    t.periodo = p;
    return true;
}

// ------------------------------------------------- el emisor del banco
// Pone una trama en RXD con la temporización de la hoja de datos. `romper_par`
// invierte el bit de paridad y `romper_stop` manda un cero donde va la parada.
static void emitir(const Cfg &c, uint16_t dato, bool romper_par = false,
                   bool romper_stop = false) {
    int p = c.periodo();
    auto bit = [&](int v) { dut->rxd = v; for (int k = 0; k < p; k++) tick(); };

    bit(0);                                  // arranque
    bool par = (c.parity == 3);
    for (int b = 0; b < c.databits; b++) {
        int v = (dato >> b) & 1;
        if (v) par = !par;
        bit(v);
    }
    if (c.parity) bit(romper_par ? !par : par);
    bit(romper_stop ? 0 : 1);
    if (c.stop == 2) bit(1);
    dut->rxd = 1;
}

// Emite una trama con UN PULSO DE RUIDO dentro de un bit: invierte la línea
// durante exactamente una muestra, la que cae en el punto donde el receptor
// decide.
//
// PARA ESTO EXISTE EL VOTO POR MAYORÍA. Con tres muestras, un pulso que sólo
// alcanza a una pierde la votación y el bit se recibe bien. Un receptor que
// mirara una sola vez se lo tragaría. Y con ondas perfectas —las que genera un
// emisor ideal— los dos receptores dan el mismo resultado: sin ruido, el voto
// parece decorativo. La prueba de mutación lo dijo: el mutante que quita la
// votación SOBREVIVÍA a todo el banco hasta que apareció esta función.
static void emitir_con_ruido(const Cfg &c, uint16_t dato, int bit_ruidoso,
                             int muestra) {
    int p  = c.periodo();
    int sm = c.ubrr + 1;                    // ciclos de UNA muestra
    // El pulso dura UNA muestra y se coloca en la posición pedida. El banco las
    // recorre TODAS en vez de apuntar a la que el receptor usa para decidir:
    // así la prueba no depende de que yo haya calculado bien dónde cae esa
    // muestra —que es justo lo que tuve mal al primer intento—, y de paso
    // comprueba la propiedad entera: un pulso de una muestra, en cualquier
    // sitio del bit, pierde la votación.
    int inicio  = muestra * sm;

    auto bit_limpio = [&](int v) {
        dut->rxd = v; for (int k = 0; k < p; k++) tick();
    };
    auto bit_sucio = [&](int v) {
        for (int k = 0; k < p; k++) {
            dut->rxd = (k >= inicio && k < inicio + sm) ? !v : v;
            tick();
        }
        dut->rxd = v;
    };

    bit_limpio(0);                           // arranque
    bool par = (c.parity == 3);
    for (int b = 0; b < c.databits; b++) {
        int v = (dato >> b) & 1;
        if (v) par = !par;
        if (b == bit_ruidoso) bit_sucio(v); else bit_limpio(v);
    }
    if (c.parity) bit_limpio(par);
    bit_limpio(1);
    if (c.stop == 2) bit_limpio(1);
    dut->rxd = 1;
}

// ======================================================= el modo SINCRONO
// EL ORACULO ES EL OTRO EXTREMO DEL CABLE, igual que con el SPI y el TWI: un
// extremo sincrono escrito desde la hoja de datos que cuelga de XCK, decodifica
// TXD en el flanco de MUESTREO y presenta RXD en el de CAMBIO. Si los dos
// extremos no coinciden bit a bit, uno de los dos esta mal, y el de aqui no
// comparte una linea con el RTL.
//
// LOS DOS FLANCOS HACEN COSAS DISTINTAS, y tienen que ser distintos. Si el dato
// de salida cambiara en el mismo flanco en el que el otro extremo muestrea, el
// otro extremo lo leeria a mitad de cambio. UCPOL dice cual es cual:
//
//   UCPOL=0   se muestrea en la SUBIDA del pin y se cambia en la bajada
//   UCPOL=1   al reves
//
// simavr no modela nada de esto -ni siquiera serializa el modo asincrono-, asi
// que aqui no hay otro oraculo posible.

struct CfgSinc {
    int  ubrr;
    int  databits;     // 5..9
    int  parity;       // 0 ninguna, 2 par, 3 impar
    int  stop;         // 1 o 2
    bool ucpol;
    // f_XCK = f_CPU / (2*(UBRR+1)), que es la formula de la hoja de datos.
    int  periodo() const { return 2 * (ubrr + 1); }
    int  bits_trama() const { return 1 + databits + (parity ? 1 : 0) + stop; }
};

static bool dut_es_maestro   = true;
static bool xck_ant          = false;   // ultimo nivel visto del pin
static bool xck_banco_nivel  = false;   // el que conduce el banco de esclavo
static int  medio_banco      = 10;      // semiperiodo del banco cuando manda el

// Avanza hasta el siguiente flanco del tipo pedido. `muestreo` es el flanco en
// el que el dato VALE; el otro es el de cambio.
static bool xck_paso(bool ucpol, bool muestreo, long limite) {
    if (dut_es_maestro) {
        for (long i = 0; i < limite; i++) {
            tick();
            bool p = dut->xck_out;
            bool sube = p && !xck_ant, baja = !p && xck_ant;
            xck_ant = p;
            // El flanco de muestreo es la subida del reloj INTERNO, que en el
            // pin es subida con UCPOL=0 y bajada con UCPOL=1.
            bool interno_sube = ucpol ? baja : sube;
            bool interno_baja = ucpol ? sube : baja;
            if (muestreo ? interno_sube : interno_baja) return true;
        }
        return false;
    }
    // El DUT es esclavo: el reloj lo pone el banco.
    for (int k = 0; k < 4; k++) {
        for (int i = 0; i < medio_banco; i++) tick();
        xck_banco_nivel = !xck_banco_nivel;
        dut->xck_pin = xck_banco_nivel;
        dut->eval();
        for (int i = 0; i < 4; i++) tick();     // que el sincronizador lo vea
        bool interno = xck_banco_nivel ^ ucpol;
        if (muestreo == interno) return true;
    }
    return false;
}

static void configurar_sinc(const CfgSinc &c, bool rx, bool tx, bool maestro) {
    for (int i = 0; i < 400; i++) tick();
    dut_es_maestro = maestro;
    dut->xck_es_salida = maestro ? 1 : 0;
    if (!maestro) { xck_banco_nivel = false; dut->xck_pin = 0; }
    uint8_t ucsz = (c.databits == 9) ? 3 : (c.databits - 5);
    // UMSEL = 01: sincrono.
    wr(A_UCSR0C, (uint8_t)(0x40 | (c.parity << 4) | ((c.stop == 2) << 3) |
                           ((ucsz & 3) << 1) | (c.ucpol ? 1 : 0)));
    wr(A_UBRR0H, (uint8_t)(c.ubrr >> 8));
    wr(A_UBRR0L, (uint8_t)(c.ubrr & 0xFF));
    wr(A_UCSR0A, 0);
    wr(A_UCSR0B, (uint8_t)((rx ? RXEN : 0) | (tx ? TXEN : 0) |
                           ((c.databits == 9) ? UCSZ2 : 0)));
    for (int i = 0; i < 40; i++) tick();
    xck_ant = dut->xck_out;
}

// El banco recibe lo que el DUT transmite.
static bool recibir_sinc(const CfgSinc &c, uint16_t &dato, bool &par_ok,
                         bool &parada_ok) {
    const long tope = 40L * c.periodo() + 400;
    // Buscar el bit de arranque: el primer flanco de muestreo con TXD a cero.
    bool visto = false;
    for (int i = 0; i < 6 * c.bits_trama() + 12 && !visto; i++) {
        if (!xck_paso(c.ucpol, true, tope)) return false;
        if (!dut->txd) visto = true;
    }
    if (!visto) return false;

    dato = 0;
    bool par = (c.parity == 3);
    for (int b = 0; b < c.databits; b++) {
        if (!xck_paso(c.ucpol, true, tope)) return false;
        if (dut->txd) { dato = (uint16_t)(dato | (1u << b)); par = !par; }
    }
    par_ok = true;
    if (c.parity) {
        if (!xck_paso(c.ucpol, true, tope)) return false;
        par_ok = ((bool)dut->txd == par);
    }
    if (!xck_paso(c.ucpol, true, tope)) return false;
    parada_ok = dut->txd;
    return true;
}

// El banco emite hacia el DUT. Cada bit se presenta en el flanco de CAMBIO.
// `tipo` es el bit que MPCM mira: el noveno de datos con tramas de nueve, y el
// primero de parada con tramas de cinco a ocho.
static void emitir_sinc(const CfgSinc &c, uint16_t dato, bool tipo = true) {
    const long tope = 40L * c.periodo() + 400;
    xck_paso(c.ucpol, false, tope);
    dut->rxd = 0;                                   // arranque
    bool par = (c.parity == 3);
    for (int b = 0; b < c.databits; b++) {
        xck_paso(c.ucpol, false, tope);
        bool v = (dato >> b) & 1;
        dut->rxd = v; if (v) par = !par;
    }
    if (c.parity) { xck_paso(c.ucpol, false, tope); dut->rxd = par; }
    for (int st = 0; st < c.stop; st++) {
        xck_paso(c.ucpol, false, tope);
        // El PRIMER bit de parada lleva el tipo de trama cuando MPCM lo usa;
        // el segundo es siempre uno.
        dut->rxd = (st == 0) ? tipo : 1;
    }
    xck_paso(c.ucpol, false, tope);
    dut->rxd = 1;
    for (int i = 0; i < 8; i++) tick();
}

// ===================================================================== MSPIM
// LA USART COMO MAESTRO SPI, y el oraculo es EL OTRO EXTREMO DEL CABLE, igual
// que con axioma_spi: un esclavo escrito desde la hoja de datos que cuelga de
// XCK, muestrea MOSI en un flanco y presenta MISO en el otro. Si los dos
// extremos no coinciden bit a bit, uno de los dos esta mal.
//
// QUE FLANCO ES CUAL. La tabla de la hoja de datos se resume en un XOR: el
// flanco de MUESTREO es la subida del pin cuando UCPOL y UCPHA coinciden, y la
// bajada cuando no.
//
//   UCPOL UCPHA   entrada del pulso   salida del pulso
//     0     0     muestreo (subida)   cambio  (bajada)
//     0     1     cambio   (subida)   muestreo(bajada)
//     1     0     muestreo (bajada)   cambio  (subida)
//     1     1     cambio   (bajada)   muestreo(subida)
struct EsclavoSpi {
    bool ucpol = false, ucpha = false, udord = false;
    uint8_t a_enviar = 0;          // lo que el esclavo devuelve por MISO
    uint8_t recibido = 0;          // lo que el esclavo ve por MOSI
    int  muestras = 0, emitidos = 0, flancos = 0, pulsos = 0;
    bool xck_ant = false;
    bool armado  = false;

    bool bit_de(uint8_t v, int i) const {
        return udord ? ((v >> i) & 1) : ((v >> (7 - i)) & 1);
    }
    void mete(bool v) {
        if (muestras < 8) {
            if (v) recibido = (uint8_t)(recibido | (udord ? (1u << muestras)
                                                          : (0x80u >> muestras)));
            muestras++;
        }
    }
    // Arranca una transferencia: con UCPHA=0 el primer bit tiene que estar en
    // el pin ANTES del primer flanco, que es lo que en un SPI de verdad hace el
    // esclavo cuando le bajan SS.
    void armar(uint8_t dato) {
        a_enviar = dato; recibido = 0; muestras = 0; emitidos = 0;
        flancos = 0; pulsos = 0; armado = true;
        xck_ant = dut->xck_out;
        if (!ucpha) { dut->rxd = bit_de(a_enviar, 0); emitidos = 1; }
    }
    // Un ciclo de reloj del sistema, con el esclavo mirando el pin.
    void paso() {
        tick();
        bool x = dut->xck_out;
        bool sube = x && !xck_ant, baja = !x && xck_ant;
        xck_ant = x;
        if (!armado || (!sube && !baja)) return;
        flancos++;
        if (baja == (ucpol != 0)) pulsos++;      // un pulso por flanco de entrada
        bool muestreo = (ucpol == ucpha) ? sube : baja;
        if (muestreo) mete(dut->txd);
        else if (emitidos < 8) { dut->rxd = bit_de(a_enviar, emitidos); emitidos++; }
    }
};

static EsclavoSpi esclavo;

// UMSEL=11, y los bits de UCSR0C con su OTRO nombre: bit 2 UDORD, bit 1 UCPHA,
// bit 0 UCPOL. Los de UPM y USBS quedan reservados y se escriben a cero.
static void configurar_mspim(int ubrr, bool ucpol, bool ucpha, bool udord) {
    for (int i = 0; i < 200; i++) tick();
    dut->xck_es_salida = 1;                     // DDR_XCK0: lo que enciende el maestro
    wr(A_UCSR0B, 0);                            // apagado mientras se configura
    wr(A_UCSR0C, (uint8_t)(0xC0 | (udord ? 0x04 : 0) | (ucpha ? 0x02 : 0) |
                           (ucpol ? 0x01 : 0)));
    wr(A_UBRR0H, (uint8_t)(ubrr >> 8));
    wr(A_UBRR0L, (uint8_t)(ubrr & 0xFF));
    wr(A_UCSR0A, 0);
    wr(A_UCSR0B, (uint8_t)(RXEN | TXEN));
    esclavo.ucpol = ucpol; esclavo.ucpha = ucpha; esclavo.udord = udord;
    esclavo.armado = false;
    dut->rxd = 1;
    for (int i = 0; i < 20; i++) tick();
}

// Una transferencia entera: el maestro manda `envia`, el esclavo devuelve
// `responde`, y al terminar los dos tienen que tener el byte del otro.
static bool transferir(uint8_t envia, uint8_t responde, uint8_t &leido,
                       int periodo) {
    esclavo.armar(responde);
    wr(A_UDR0, envia);
    const long tope = 40L * periodo + 600;
    bool visto = false;
    for (long i = 0; i < tope && !visto; i++) {
        esclavo.paso();
        if (peek(A_UCSR0A) & RXC) { leido = rd(A_UDR0); visto = true; }
    }
    if (!visto) return false;
    // RXC SE LEVANTA EN LA ULTIMA MUESTRA, y con UCPHA=0 esa es la ENTRADA del
    // octavo pulso: el flanco de salida todavia no ha ocurrido. Parar aqui
    // dejaria sin contar el ultimo flanco y sin ver el pin volver al reposo,
    // que es justo lo que hay que comprobar.
    for (int i = 0; i < 2 * periodo + 8; i++) esclavo.paso();
    return true;
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_usart;

    dut->rst_n = 0; dut->clk = 0;

    dut->ce = 1;   // a reloj entero: la habilitacion es cosa de CLKPR (ADR 0003)
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->rxd = 1; dut->ack_txc = 0;
    dut->eval();
    tick();
    dut->rst_n = 1; dut->eval();

    // ------------------------------------------------ 1. valores de reset
    fase = "reset";
    chk("UCSR0A", peek(A_UCSR0A), UDRE);        // el búfer nace vacío
    chk("UCSR0B", peek(A_UCSR0B), 0x00);
    chk("UCSR0C", peek(A_UCSR0C), 0x06);        // 8 bits, como el chip
    chk("UBRR0L", peek(A_UBRR0L), 0x00);
    chk("UBRR0H", peek(A_UBRR0H), 0x00);
    chk("TXD en reposo", dut->txd, 1);
    chk("TXEN apagado", dut->txd_en, 0);

    // ----------------------------- 1bis. los registros se leen de vuelta
    // Obvio hasta que falla: si un registro de configuración no devuelve lo
    // que se le escribió, todo lo demás que pase es casualidad.
    fase = "lectura de vuelta";
    wr(A_UCSR0B, 0x98);
    chk("UCSR0B", peek(A_UCSR0B), 0x98);
    wr(A_UCSR0C, 0x2E);
    chk("UCSR0C", peek(A_UCSR0C), 0x2E);
    wr(A_UBRR0H, 0x0B);
    chk("UBRR0H", peek(A_UBRR0H), 0x0B);
    wr(A_UBRR0L, 0x67);
    chk("UBRR0L", peek(A_UBRR0L), 0x67);
    wr(A_UCSR0B, 0x00);

    // ------------------------------- 2. la forma de onda, en cada formato
    // Cinco longitudes, tres paridades, uno y dos bits de parada, con y sin
    // U2X y con varios divisores. Es la tabla de formatos del manual, entera.
    fase = "forma de onda";
    static const int datos_prueba[] = { 0x00, 0xFF, 0x55, 0xAA, 0x01, 0x80, 0x3C };
    for (int db = 5; db <= 9; db++)
      for (int par = 0; par <= 3; par++) {
        if (par == 1) continue;                 // 01 está reservado
        for (int stop = 1; stop <= 2; stop++)
          for (int u2x = 0; u2x <= 1; u2x++) {
            Cfg c { (u2x ? 3 : 1), (bool)u2x, db, par, stop };
            configurar(c, false, true);
            uint16_t mascara = (uint16_t)((1u << db) - 1);
            for (int dato : datos_prueba) {
                uint16_t d = (uint16_t)(dato & mascara);
                if (db == 9) {
                    // El noveno bit va en TXB8, dentro de UCSR0B.
                    uint8_t b = peek(A_UCSR0B);
                    wr(A_UCSR0B, (uint8_t)((b & ~1) | ((d >> 8) & 1)));
                }
                wr(A_UDR0, (uint8_t)(d & 0xFF));
                Trama t;
                if (!recibir(c, t, 4000)) { chk("no transmitió", 0, 1); continue; }
                chk("dato transmitido", t.dato, d);
                if (!t.paridad_ok && getenv("AXIOMA_DUMP"))
                    printf("        paridad mal: db=%d par=%d stop=%d u2x=%d dato=0x%03X\n",
                           db, par, stop, u2x, d);
                chk("paridad", t.paridad_ok, 1);
                chk("bits de parada", t.parada_ok, 1);
            }
          }
      }

    // ----------------------------- 3. el periodo de bit es el del manual
    // Se mide con el reloj: entre el flanco de arranque y el siguiente cambio
    // tiene que haber exactamente (UBRR+1)·16 ciclos, u 8 con U2X.
    fase = "periodo de bit";
    for (int u2x = 0; u2x <= 1; u2x++)
      for (int ubrr : { 0, 1, 7, 25, 103 }) {
        Cfg c { ubrr, (bool)u2x, 8, 0, 1 };
        configurar(c, false, true);
        // Asentar: la trama anterior puede seguir saliendo, y entonces lo que
        // se mediria seria la suya.
        run(c.periodo() * 14);
        wr(A_UDR0, 0xFE);                       // arranque 0, bit0 0, resto 1
        long i = 0;
        while (dut->txd && i < 200000) { tick(); i++; }
        // Estamos en el primer ciclo con TXD a 0. El bit 0 del dato también es
        // 0, así que la línea sube al empezar el bit 1: dos periodos.
        long largo = 0;
        while (!dut->txd && largo < 200000) { tick(); largo++; }
        chk("dos periodos de bit", (uint32_t)largo, (uint32_t)(2 * c.periodo()));
        run(c.periodo() * 12);
      }

    // ------------------------------------------ 4. recepción, y sus errores
    fase = "recepcion";
    {
        Cfg c { 1, false, 8, 0, 1 };
        configurar(c, true, false);
        run(c.periodo());

        for (int dato : { 0x00, 0xFF, 0x41, 0x5A }) {
            emitir(c, (uint16_t)dato);
            run(c.periodo() * 2);
            if (getenv("AXIOMA_DUMP"))
                printf("        tras 0x%02X: UCSR0A=0x%02X\n", dato, peek(A_UCSR0A));
            chk("RXC puesto", (peek(A_UCSR0A) & RXC) != 0, 1);
            chk("dato recibido", rd(A_UDR0), (uint32_t)dato);
            chk("RXC limpio tras leer", (peek(A_UCSR0A) & RXC) != 0, 0);
        }

        // Bit de parada a cero: error de trama, y el byte se guarda igual.
        fase = "error de trama";
        emitir(c, 0x37, false, true);
        run(c.periodo() * 2);
        chk("FE puesto", (peek(A_UCSR0A) & FE) != 0, 1);
        chk("dato pese al error", rd(A_UDR0), 0x37);
        chk("FE se va con la trama", (peek(A_UCSR0A) & FE) != 0, 0);

        // Paridad mal.
        fase = "error de paridad";
        Cfg cp { 1, false, 8, 2, 1 };
        configurar(cp, true, false);
        run(cp.periodo());
        emitir(cp, 0x5C, true, false);
        run(cp.periodo() * 2);
        chk("UPE puesto", (peek(A_UCSR0A) & UPE) != 0, 1);
        chk("dato pese al error", rd(A_UDR0), 0x5C);
        chk("UPE se va con la trama", (peek(A_UCSR0A) & UPE) != 0, 0);

        // El búfer tiene DOS niveles: dos tramas caben, la tercera desborda.
        fase = "busy y desbordamiento";
        configurar(c, true, false);
        run(c.periodo());
        emitir(c, 0x11);  run(c.periodo());
        emitir(c, 0x22);  run(c.periodo());
        chk("DOR todavia no", (peek(A_UCSR0A) & DOR) != 0, 0);
        emitir(c, 0x33);  run(c.periodo() * 2);
        chk("DOR al desbordar", (peek(A_UCSR0A) & DOR) != 0, 1);
        chk("primero en entrar", rd(A_UDR0), 0x11);
        chk("segundo en entrar", rd(A_UDR0), 0x22);
        chk("la tercera se perdio", (peek(A_UCSR0A) & RXC) != 0, 0);
    }

    // ------------------------------------------------- 5. UDRE, TXC y su ack
    fase = "banderas del transmisor";
    {
        Cfg c { 1, false, 8, 0, 1 };
        configurar(c, false, true);
        run(c.periodo() * 14);
        wr(A_UCSR0A, TXC);                      // TXC viene puesto de antes
        chk("UDRE al empezar", (peek(A_UCSR0A) & UDRE) != 0, 1);
        wr(A_UDR0, 0x5A);
        chk("UDRE baja al cargar", (peek(A_UCSR0A) & UDRE) != 0, 0);
        run(c.periodo() * 2);
        chk("UDRE sube al pasar al turno", (peek(A_UCSR0A) & UDRE) != 0, 1);
        chk("TXC todavia no", (peek(A_UCSR0A) & TXC) != 0, 0);
        run(c.periodo() * (c.bits_trama() + 2));
        chk("TXC al terminar", (peek(A_UCSR0A) & TXC) != 0, 1);

        // Se limpia escribiendo UN UNO en ella.
        wr(A_UCSR0A, TXC);
        chk("TXC limpio con un uno", (peek(A_UCSR0A) & TXC) != 0, 0);

        // Y también al atender su vector.
        wr(A_UDR0, 0x01);
        run(c.periodo() * (c.bits_trama() + 3));
        chk("TXC otra vez", (peek(A_UCSR0A) & TXC) != 0, 1);
        dut->ack_txc = 1; dut->eval(); tick(); dut->ack_txc = 0; dut->eval();
        chk("el vector limpia TXC", (peek(A_UCSR0A) & TXC) != 0, 0);
    }

    // ------------------------------------------- 6. leer UDR0 vacio no cuelga
    fase = "lectura en vacio";
    {
        Cfg c { 1, false, 8, 0, 1 };
        configurar(c, true, true);
        chk("RXC bajo", (peek(A_UCSR0A) & RXC) != 0, 0);
        rd(A_UDR0);
        chk("sigue bajo", (peek(A_UCSR0A) & RXC) != 0, 0);
    }

    // -------------------------- 6bis. ruido: para esto vota el receptor
    fase = "ruido en un bit";
    {
        // Con un divisor holgado, una muestra son ocho ciclos: el pulso de
        // ruido cabe limpio dentro de una sola.
        Cfg c { 7, false, 8, 0, 1 };
        configurar(c, true, false);
        while (peek(A_UCSR0A) & RXC) rd(A_UDR0);
        for (int dato : { 0x00, 0xFF, 0x5A }) {
            for (int b = 0; b < 8; b++)
                for (int m = 0; m < 16; m++) {
                    emitir_con_ruido(c, (uint16_t)dato, b, m);
                    run(c.periodo() * 2);
                    chk("RXC pese al ruido", (peek(A_UCSR0A) & RXC) != 0, 1);
                    chk("el voto descarta el pulso", rd(A_UDR0), (uint32_t)dato);
                }
        }
    }

    // ------------------------------------------- 7. remojo aleatorio
    // Formatos al azar, datos al azar, y tramas rotas a propósito mezcladas con
    // las buenas. Cada trama se transmite Y se recibe: la de salida la decodifica
    // el receptor del banco, y la de entrada la genera su emisor. Si el RTL y
    // los dos modelos no coinciden en los tres sitios, salta.
    fase = "aleatorio";
    {
        std::mt19937 rng(20260911);
        for (int it = 0; it < 2000; it++) {
            int db   = 5 + (int)(rng() % 5);
            int par  = (int)(rng() % 3); par = (par == 0) ? 0 : par + 1;   // 0, 2, 3
            int stop = 1 + (int)(rng() % 2);
            int u2x  = (int)(rng() % 2);
            int ubrr = (int)(rng() % 6);
            Cfg c { ubrr, (bool)u2x, db, par, stop };
            configurar(c, true, true);
            uint16_t mascara = (uint16_t)((1u << db) - 1);

            // --- transmisión ---
            for (int k = 0; k < 3; k++) {
                uint16_t d = (uint16_t)(rng() & mascara);
                if (db == 9) {
                    uint8_t b = peek(A_UCSR0B);
                    wr(A_UCSR0B, (uint8_t)((b & ~1) | ((d >> 8) & 1)));
                }
                wr(A_UDR0, (uint8_t)(d & 0xFF));
                Trama t;
                if (!recibir(c, t, 40000)) { chk("no transmitio", 0, 1); break; }
                chk("dato", t.dato, d);
                chk("paridad", t.paridad_ok, 1);
                chk("parada", t.parada_ok, 1);
            }

            // --- recepción, con tramas rotas mezcladas ---
            // El receptor se reinicia: lo que quede del turno anterior en el
            // búfer se saca antes de empezar.
            while (peek(A_UCSR0A) & RXC) rd(A_UDR0);
            for (int k = 0; k < 3; k++) {
                uint16_t d  = (uint16_t)(rng() & mascara);
                bool mal_par  = par && ((rng() % 5) == 0);
                bool mal_stop = (rng() % 7) == 0;
                emitir(c, d, mal_par, mal_stop);
                run(c.periodo() * 2);
                chk("RXC", (peek(A_UCSR0A) & RXC) != 0, 1);
                uint8_t a = peek(A_UCSR0A);
                chk("FE", (a & FE) != 0, mal_stop);
                chk("UPE", (a & UPE) != 0, mal_par);
                chk("dato recibido", rd(A_UDR0), (uint32_t)(d & 0xFF));
            }
        }
    }


    // ============================================ 9. modo SINCRONO, maestro
    // El DUT genera XCK. Lo primero que hay que comprobar es la FRECUENCIA:
    // f_XCK = f_CPU/(2*(UBRR+1)) es una promesa de la hoja de datos, y un
    // periodo mal contado funciona contra cualquier banco y luego no engancha
    // con el dispositivo de la placa.
    fase = "sincrono: periodo de XCK";
    for (int ubrr : {3, 7, 15, 40}) {
        CfgSinc c { ubrr, 8, 0, 1, false };
        configurar_sinc(c, true, true, true);
        long t[4] = {0,0,0,0};
        int n = 0; long ciclo = 0; bool ant = dut->xck_out;
        for (long i = 0; i < 40L * c.periodo() + 400 && n < 4; i++) {
            tick(); ciclo++;
            bool p = dut->xck_out;
            if (p && !ant) t[n++] = ciclo;
            ant = p;
        }
        if (n >= 4) {
            chk("periodo de XCK", (uint32_t)(t[3] - t[2]), (uint32_t)c.periodo());
            chk("periodo estable", (uint32_t)(t[2] - t[1]), (uint32_t)c.periodo());
        } else {
            chk("no se vio XCK", 0, 1);
        }
    }

    // ------------------------------------- 9bis. el sincrono A SU VELOCIDAD
    // LA HOJA DE DATOS PERMITE UBRR=0, y eso son f_CPU/2: un bit cada DOS
    // ciclos de reloj, que es la velocidad que hace util el modo sincrono. La
    // fase de arriba empieza en UBRR=3, asi que de UBRR<3 no se sabia nada.
    //
    // Es justo donde se rompe un receptor que mire el pin a traves de un
    // sincronizador: con el dato retrasado N ciclos y el semiperiodo valiendo
    // UBRR+1, el muestreo se sale del bit en cuanto UBRR+1 <= N. Con ondas
    // lentas no se nota, y ese es el problema.
    fase = "sincrono: a la velocidad maxima (UBRR 0..3)";
    for (int ubrr : {0, 1, 2, 3})
      for (bool pol : {false, true}) {
        CfgSinc c { ubrr, 8, 0, 1, pol };
        configurar_sinc(c, true, true, true);

        uint16_t patron = (uint16_t)(0xB4 ^ (ubrr * 17));
        wr(A_UDR0, (uint8_t)patron);
        uint16_t got = 0; bool pok = false, sok = false;
        if (recibir_sinc(c, got, pok, sok))
            chk("el byte sale entero a f_CPU/(2*(UBRR+1))", got, patron);
        else
            chk("no salio trama a la velocidad maxima", 0, 1);

        uint16_t envio = (uint16_t)(0x5A ^ (ubrr * 33));
        emitir_sinc(c, envio);
        for (int i = 0; i < 400 && !(peek(A_UCSR0A) & RXC); i++) tick();
        chk("RXC a la velocidad maxima", (peek(A_UCSR0A) & RXC) != 0, 1);
        chk("el byte recibido a la velocidad maxima", rd(A_UDR0), envio);
      }

    // Y la forma de onda, en los dos sentidos y con las dos polaridades.
    fase = "sincrono: maestro, los dos sentidos";
    for (bool pol : {false, true})
      for (int db : {5, 8, 9})
        for (int par : {0, 2, 3}) {
            CfgSinc c { 5, db, par, (db == 9 ? 2 : 1), pol };
            configurar_sinc(c, true, true, true);
            uint16_t patron = (uint16_t)(0x155 & ((1u << db) - 1));

            // TXB8 ANTES QUE UDR0: el noveno bit se engancha al escribir el
            // dato, que es el orden que manda la hoja de datos. Al reves sale
            // el bit de la trama ANTERIOR, y con el bufer vacio sale un cero.
            if (db == 9) wr(A_UCSR0B, (uint8_t)(RXEN | TXEN | UCSZ2 |
                                                ((patron >> 8) & 1)));
            wr(A_UDR0, (uint8_t)patron);
            uint16_t got = 0; bool pok = false, sok = false;
            if (recibir_sinc(c, got, pok, sok)) {
                chk("el byte transmitido llega entero", got, patron);
                chk("la paridad es la que toca", pok, 1);
                chk("y el bit de parada esta", sok, 1);
            } else {
                chk("no salio ninguna trama", 0, 1);
            }

            // Ahora al reves: el banco emite y el DUT recibe.
            uint16_t envio = (uint16_t)(0x0AA & ((1u << db) - 1));
            emitir_sinc(c, envio);
            for (int i = 0; i < 200 && !(peek(A_UCSR0A) & RXC); i++) tick();
            chk("RXC se levanta", (peek(A_UCSR0A) & RXC) != 0, 1);
            // RXB8 ANTES QUE UDR0. Leer UDR0 SACA el byte del bufer, y con el
            // se va su noveno bit: RXB8 es del byte que esta en la cabeza, no
            // del ultimo recibido. La hoja de datos lo dice con estas palabras
            // -«the ninth bit must be read from the RXB8n bit before reading
            // the low bits from the UDRn»- y al reves sale un cero.
            uint16_t alto = (db == 9) ? (uint16_t)((peek(A_UCSR0B) & 0x02) << 7) : 0;
            uint16_t leido = (uint16_t)(rd(A_UDR0) | alto);
            chk("el byte recibido es el que se mando", leido, envio);
            chk("sin error de trama", (peek(A_UCSR0A) & FE) != 0, 0);
            chk("sin error de paridad", (peek(A_UCSR0A) & UPE) != 0, 0);
        }

    // ============================================= 10. modo SINCRONO, esclavo
    // Ahora el reloj lo pone el banco y el DUT cuelga de el. Es el mismo motor
    // de trama: si sólo funcionara de maestro, lo que estaría mal es el reloj.
    fase = "sincrono: esclavo";
    for (bool pol : {false, true}) {
        CfgSinc c { 5, 8, 2, 1, pol };
        configurar_sinc(c, true, true, false);
        chk("de esclavo NO se adueña del pin de reloj", dut->xck_ovr, 0);

        wr(A_UDR0, 0x3C);
        uint16_t got = 0; bool pok = false, sok = false;
        if (recibir_sinc(c, got, pok, sok)) {
            chk("el esclavo transmite con el reloj ajeno", got, 0x3C);
            chk("con su paridad", pok, 1);
        } else {
            chk("el esclavo no transmitio", 0, 1);
        }

        emitir_sinc(c, 0xC3);
        for (int i = 0; i < 400 && !(peek(A_UCSR0A) & RXC); i++) tick();
        chk("RXC en esclavo", (peek(A_UCSR0A) & RXC) != 0, 1);
        chk("el byte recibido de esclavo", rd(A_UDR0), 0xC3);
    }

    // ============================ 10ter. UCPOL, comprobado en el FLANCO
    // QUE EL DATO LLEGUE NO PRUEBA QUE UCPOL ESTE BIEN. Con los dos extremos
    // equivocados de la misma manera, la trama sale perfecta: es el fallo de
    // siempre, el modelo y el diseño dandose la razon mutuamente. Lo que UCPOL
    // define es CUAL de los dos flancos vale, y eso hay que mirarlo en el
    // flanco: TXD tiene que estar QUIETO alrededor del de muestreo, porque es
    // cuando el otro extremo lo lee, y moverse en el otro.
    //
    // Un mutante que hacia al esclavo ignorar UCPOL sobrevivia a todo lo
    // anterior -incluido el trafico aleatorio con las dos polaridades- hasta
    // que se miro esto.
    fase = "sincrono: UCPOL manda en el flanco";
    for (bool pol : {false, true}) {
        CfgSinc c { 5, 8, 0, 1, pol };
        configurar_sinc(c, false, true, false);
        // El nivel de PIN que corresponde a cada nivel del reloj interno.
        auto pin_de = [&](bool interno) { return (bool)(interno ^ c.ucpol); };

        wr(A_UDR0, 0x6C);
        for (int b = 0; b < c.bits_trama() + 2; b++) {
            // Flanco de CAMBIO: el reloj interno baja. Aqui el dato PUEDE moverse.
            xck_banco_nivel = pin_de(false);
            dut->xck_pin = xck_banco_nivel; dut->eval();
            for (int i = 0; i < medio_banco; i++) tick();
            bool antes = dut->txd;

            // Flanco de MUESTREO: el reloj interno sube. Aqui el dato NO puede
            // moverse, porque es cuando el otro extremo lo lee.
            xck_banco_nivel = pin_de(true);
            dut->xck_pin = xck_banco_nivel; dut->eval();
            for (int i = 0; i < medio_banco; i++) tick();
            chk("TXD quieto alrededor del flanco de muestreo", dut->txd, antes);
        }
        xck_banco_nivel = false; dut->xck_pin = 0; dut->eval();
    }

    // ================================ 10bis. sincrono: trafico aleatorio
    // Los casos dirigidos prueban lo que a alguien se le ocurrio; esto prueba
    // combinaciones que a nadie se le habrian ocurrido. Semilla fija: un fallo
    // intermitente que no se puede reproducir no se puede arreglar.
    fase = "sincrono: trafico aleatorio";
    {
        uint32_t sem = 0xC0FFEEu;
        auto aleat = [&]() {
            sem ^= sem << 13; sem ^= sem >> 17; sem ^= sem << 5; return sem;
        };
        for (int t = 0; t < 150; t++) {
            CfgSinc c { (int)(aleat() % 8) + 2,
                        (int)(aleat() % 5) + 5,
                        (int)((aleat() % 3) ? (2 + (int)(aleat() & 1)) : 0),
                        (int)(aleat() % 2) + 1,
                        (aleat() & 1) != 0 };
            bool maestro = (aleat() & 1) != 0;
            medio_banco = (int)(aleat() % 10) + 6;
            configurar_sinc(c, true, true, maestro);

            uint16_t patron = (uint16_t)(aleat() & ((1u << c.databits) - 1));
            if (c.databits == 9)
                wr(A_UCSR0B, (uint8_t)(RXEN | TXEN | UCSZ2 | ((patron >> 8) & 1)));
            wr(A_UDR0, (uint8_t)patron);
            uint16_t got = 0; bool pok = false, sok = false;
            if (recibir_sinc(c, got, pok, sok)) {
                chk("aleatorio: el byte transmitido llega entero", got, patron);
                chk("aleatorio: paridad", pok, 1);
                chk("aleatorio: parada", sok, 1);
            } else {
                chk("aleatorio: no salio trama", 0, 1);
            }

            uint16_t envio = (uint16_t)(aleat() & ((1u << c.databits) - 1));
            emitir_sinc(c, envio);
            bool llego = false;
            for (int i = 0; i < 1200 && !llego; i++) {
                if (peek(A_UCSR0A) & RXC) llego = true; else tick();
            }
            chk("aleatorio: RXC", llego, 1);
            if (llego) {
                uint16_t alto = (c.databits == 9)
                              ? (uint16_t)((peek(A_UCSR0B) & 0x02) << 7) : 0;
                uint16_t leido = (uint16_t)(rd(A_UDR0) | alto);
                chk("aleatorio: el byte recibido", leido, envio);
                chk("aleatorio: sin error de trama", (peek(A_UCSR0A) & FE) != 0, 0);
                chk("aleatorio: sin error de paridad", (peek(A_UCSR0A) & UPE) != 0, 0);
            }
        }
        medio_banco = 10;
    }

    // ================================================== 11. MPCM
    // Varios esclavos en el mismo cable: con MPCM puesto sólo pasan las tramas
    // de DIRECCION, y las de datos se tiran EN SILENCIO —ni RXC, ni búfer, ni
    // DOR—. Es lo que permite que el que no ha sido llamado no se entere de
    // nada hasta la siguiente dirección.
    fase = "MPCM con nueve bits de datos";
    {
        CfgSinc c { 5, 9, 0, 1, false };
        configurar_sinc(c, true, false, true);
        wr(A_UCSR0A, 0x01);                       // MPCM
        chk("MPCM se lee de vuelta", peek(A_UCSR0A) & 0x01, 0x01);

        // Trama de DATOS: noveno bit a cero. Tiene que desaparecer.
        emitir_sinc(c, 0x055);
        for (int i = 0; i < 200; i++) tick();
        chk("una trama de datos con MPCM no levanta RXC",
            (peek(A_UCSR0A) & RXC) != 0, 0);

        // Trama de DIRECCION: noveno bit a uno. Esta si entra.
        emitir_sinc(c, 0x1AA);
        for (int i = 0; i < 400 && !(peek(A_UCSR0A) & RXC); i++) tick();
        chk("una trama de direccion si", (peek(A_UCSR0A) & RXC) != 0, 1);
        chk("y el noveno bit dice que era direccion",
            (peek(A_UCSR0B) & 0x02) != 0, 1);
        chk("y trae el byte correcto", rd(A_UDR0), 0x0AA);

        // Al limpiar MPCM vuelven a entrar las de datos.
        wr(A_UCSR0A, 0x00);
        emitir_sinc(c, 0x033);
        for (int i = 0; i < 400 && !(peek(A_UCSR0A) & RXC); i++) tick();
        chk("sin MPCM las tramas de datos entran", (peek(A_UCSR0A) & RXC) != 0, 1);
        chk("con su byte", rd(A_UDR0), 0x033);
    }

    fase = "MPCM con el primer bit de parada";
    {
        // Con tramas de cinco a ocho bits el tipo va en el PRIMER BIT DE
        // PARADA, y por eso la hoja de datos exige dos: el primero deja de ser
        // parada y pasa a ser la marca.
        CfgSinc c { 5, 8, 0, 2, false };
        configurar_sinc(c, true, false, true);
        wr(A_UCSR0A, 0x01);                       // MPCM

        emitir_sinc(c, 0x5A, false);              // parada a cero: es dato
        for (int i = 0; i < 200; i++) tick();
        chk("el primer bit de parada a cero marca DATO y se tira",
            (peek(A_UCSR0A) & RXC) != 0, 0);

        emitir_sinc(c, 0xA5, true);               // parada a uno: es direccion
        for (int i = 0; i < 400 && !(peek(A_UCSR0A) & RXC); i++) tick();
        chk("a uno marca DIRECCION y entra", (peek(A_UCSR0A) & RXC) != 0, 1);
        chk("con su byte", rd(A_UDR0), 0xA5);
        wr(A_UCSR0A, 0x00);
    }

    // El modo asincrono tambien tiene MPCM, y ahi el tipo va igual.
    fase = "MPCM en asincrono";
    {
        Cfg c { 5, false, 9, 0, 1 };
        dut_es_maestro = true; dut->xck_es_salida = 0;
        configurar(c, true, false);
        wr(A_UCSR0A, 0x01);
        emitir(c, 0x055);                         // noveno bit a cero: dato
        for (int i = 0; i < 400; i++) tick();
        chk("en asincrono la trama de datos tambien se tira",
            (peek(A_UCSR0A) & RXC) != 0, 0);
        emitir(c, 0x1AA);
        for (int i = 0; i < 400 && !(peek(A_UCSR0A) & RXC); i++) tick();
        chk("y la de direccion entra", (peek(A_UCSR0A) & RXC) != 0, 1);
        chk("con su byte", rd(A_UDR0), 0x0AA);
        wr(A_UCSR0A, 0x00);
    }


    // ======================================================= 13. MSPIM
    // La USART como MAESTRO SPI. Lo primero, el reloj: f_XCK = f_CPU/(2*(UBRR+1))
    // es la misma formula que el sincrono, y ademas hay que comprobar dos cosas
    // que el sincrono NO tiene: que el reloj este QUIETO entre tramas y que una
    // trama sean OCHO PULSOS, ni uno mas. Un pulso de sobra descoloca a un
    // esclavo de verdad para siempre, y con ondas bonitas no se ve.
    fase = "MSPIM: ocho pulsos y el reloj quieto entre tramas";
    for (int ubrr : {0, 1, 3, 7})
      for (bool pol : {false, true}) {
        configurar_mspim(ubrr, pol, false, false);
        const int periodo = 2 * (ubrr + 1);

        chk("XCK en reposo vale UCPOL", dut->xck_out, pol ? 1 : 0);
        chk("y el maestro se adueña del pin", dut->xck_ovr, 1);

        // Quieto ANTES de que haya nada que transmitir.
        int flancos_ocioso = 0; bool ant = dut->xck_out;
        for (int i = 0; i < 200; i++) {
            tick();
            if ((bool)dut->xck_out != ant) flancos_ocioso++;
            ant = dut->xck_out;
        }
        chk("XCK no se mueve sin trama", flancos_ocioso, 0);

        uint8_t leido = 0;
        bool ok = transferir(0xA5, 0x3C, leido, periodo);
        chk("la transferencia termina", ok, 1);
        chk("el esclavo recibio lo que mando el maestro", esclavo.recibido, 0xA5);
        chk("y el maestro recibio lo que mando el esclavo", leido, 0x3C);
        chk("una trama son OCHO pulsos", esclavo.pulsos, 8);
        chk("o sea dieciseis flancos", esclavo.flancos, 16);

        // Y vuelve a quedarse quieto, en su nivel de reposo.
        chk("XCK vuelve al reposo", dut->xck_out, pol ? 1 : 0);
        flancos_ocioso = 0; ant = dut->xck_out;
        for (int i = 0; i < 200; i++) {
            tick();
            if ((bool)dut->xck_out != ant) flancos_ocioso++;
            ant = dut->xck_out;
        }
        chk("y no se mueve despues", flancos_ocioso, 0);
      }

    // El periodo, medido. Es la misma promesa que en sincrono y se rompe igual
    // de silenciosamente: un esclavo lento no se queja, se equivoca.
    fase = "MSPIM: el periodo de XCK";
    for (int ubrr : {1, 3, 7, 15}) {
        configurar_mspim(ubrr, false, false, false);
        esclavo.armar(0x00);
        wr(A_UDR0, 0x5A);
        long t[3] = {0,0,0}; int n = 0; long ciclo = 0; bool ant = dut->xck_out;
        for (long i = 0; i < 40L * 2 * (ubrr + 1) + 600 && n < 3; i++) {
            esclavo.paso(); ciclo++;
            bool p = dut->xck_out;
            if (p && !ant) t[n++] = ciclo;
            ant = p;
        }
        if (n >= 3) {
            chk("periodo de XCK en MSPIM", (uint32_t)(t[2] - t[1]),
                (uint32_t)(2 * (ubrr + 1)));
            chk("y es estable", (uint32_t)(t[1] - t[0]),
                (uint32_t)(2 * (ubrr + 1)));
        } else {
            chk("no se vieron tres flancos de XCK", 0, 1);
        }
    }

    // LOS CUATRO MODOS Y LOS DOS ORDENES DE BIT. Que el dato llegue con un modo
    // no dice nada de los otros tres: con los dos extremos equivocados de la
    // misma manera la trama sale perfecta, y por eso el esclavo del banco
    // calcula sus flancos desde la tabla y no desde el DUT.
    fase = "MSPIM: los cuatro modos por los dos ordenes";
    for (bool pol : {false, true})
      for (bool pha : {false, true})
        for (bool ord : {false, true}) {
            configurar_mspim(3, pol, pha, ord);
            static const uint8_t casos[4][2] = {
                {0x00, 0xFF}, {0xFF, 0x00}, {0x80, 0x01}, {0x96, 0x69}
            };
            for (int k = 0; k < 4; k++) {
                uint8_t leido = 0;
                bool ok = transferir(casos[k][0], casos[k][1], leido, 8);
                chk("la transferencia termina", ok, 1);
                chk("el esclavo ve el byte del maestro", esclavo.recibido,
                    casos[k][0]);
                chk("el maestro ve el byte del esclavo", leido, casos[k][1]);
                chk("ocho pulsos en todos los modos", esclavo.pulsos, 8);
            }
        }

    // TRAFICO ALEATORIO, que es lo unico que destapa los casos que a nadie se
    // le ocurre escribir. Semilla fija: un fallo se reproduce.
    fase = "MSPIM: trafico aleatorio";
    {
        std::mt19937 rng(20260914);
        for (int i = 0; i < 120; i++) {
            bool pol = rng() & 1, pha = rng() & 1, ord = rng() & 1;
            int ubrr = (int)(rng() % 5);
            configurar_mspim(ubrr, pol, pha, ord);
            for (int k = 0; k < 3; k++) {
                uint8_t a = (uint8_t)(rng() & 0xFF), b = (uint8_t)(rng() & 0xFF);
                uint8_t leido = 0;
                if (transferir(a, b, leido, 2 * (ubrr + 1))) {
                    chk("ida", esclavo.recibido, a);
                    chk("vuelta", leido, b);
                    chk("ocho pulsos", esclavo.pulsos, 8);
                } else {
                    chk("la transferencia aleatoria no termino", 0, 1);
                }
            }
        }
    }

    // LO QUE MSPIM *NO* TIENE, y que hay que comprobar que no aparece: ni
    // paridad, ni bit de parada, ni MPCM. Los bits de UCSR0C siguen siendo los
    // mismos biestables -se leen de vuelta-, pero no los mira nadie: con UPM,
    // USBS y MPCM puestos la trama tiene que salir IDENTICA.
    fase = "MSPIM: paridad, parada y MPCM no existen aqui";
    {
        configurar_mspim(3, false, false, false);
        uint8_t limpio = 0;
        transferir(0x5A, 0xC3, limpio, 8);
        int pulsos_limpios = esclavo.pulsos;

        // Ahora con toda la parafernalia de la USART encendida.
        wr(A_UCSR0C, 0xF9);                      // UMSEL=11, UPM=11, USBS=1, ...
        chk("UCSR0C se lee de vuelta entera", peek(A_UCSR0C), 0xF9);
        wr(A_UCSR0A, MPCM);
        esclavo.ucpol = true; esclavo.ucpha = false; esclavo.udord = false;
        uint8_t sucio = 0;
        bool ok = transferir(0x5A, 0xC3, sucio, 8);
        chk("la trama sale igual con UPM y USBS puestos", ok, 1);
        chk("mismo byte de ida", esclavo.recibido, 0x5A);
        chk("mismo byte de vuelta", sucio, limpio);
        chk("y los mismos pulsos", esclavo.pulsos, pulsos_limpios);
        chk("MPCM no tira la trama", (peek(A_UCSR0A) & RXC) != 0, 0);
        wr(A_UCSR0A, 0);
    }

    // EL BUFER DE DOS NIVELES TAMBIEN EXISTE EN MSPIM, y es el mismo: un
    // programa que encadene dos transferencias sin leer UDR0 tiene que
    // encontrarse los DOS bytes, en orden, y sin DOR. La cobertura lo destapo:
    // el banco leia siempre justo despues de RXC, asi que el segundo nivel no
    // lo pisaba nadie y la rama salia sin cubrir.
    fase = "MSPIM: el bufer de dos niveles";
    {
        configurar_mspim(3, false, false, false);
        const int periodo = 8;

        // Dos tramas seguidas SIN leer UDR0 en medio.
        esclavo.armar(0x11);
        wr(A_UDR0, 0xAA);
        for (int i = 0; i < 20 * periodo + 200; i++) esclavo.paso();
        chk("la primera trama entra", (peek(A_UCSR0A) & RXC) != 0, 1);

        esclavo.armar(0x22);
        wr(A_UDR0, 0xBB);
        for (int i = 0; i < 20 * periodo + 200; i++) esclavo.paso();
        chk("el segundo byte cabe, sin desbordar", (peek(A_UCSR0A) & DOR) != 0, 0);

        chk("y salen en orden: primero el que llego antes", rd(A_UDR0), 0x11);
        chk("y despues el segundo", rd(A_UDR0), 0x22);
        chk("el bufer queda vacio", (peek(A_UCSR0A) & RXC) != 0, 0);

        // Y el tercero SI desborda, como en cualquier otro modo.
        for (uint8_t v : {0x33, 0x44, 0x55}) {
            esclavo.armar(v);
            wr(A_UDR0, 0x00);
            for (int i = 0; i < 20 * periodo + 200; i++) esclavo.paso();
        }
        chk("el tercero desborda y lo dice", (peek(A_UCSR0A) & DOR) != 0, 1);
        chk("los dos primeros siguen intactos", rd(A_UDR0), 0x33);
        chk("en su orden", rd(A_UDR0), 0x44);
    }

    // SIN DDR_XCK0 NO HAY MAESTRO, que es como la hoja de datos enciende el
    // modo: "setting the XCKn port pin as output enables master mode".
    fase = "MSPIM: sin DDR_XCK0 no hay reloj";
    {
        configurar_mspim(3, false, false, false);
        dut->xck_es_salida = 0;
        for (int i = 0; i < 20; i++) tick();
        chk("no se adueña del pin", dut->xck_ovr, 0);
        wr(A_UDR0, 0x77);
        int flancos = 0; bool ant = dut->xck_out;
        for (int i = 0; i < 400; i++) {
            tick();
            if ((bool)dut->xck_out != ant) flancos++;
            ant = dut->xck_out;
        }
        chk("y no genera ni un flanco", flancos, 0);
        chk("la trama se queda esperando", (peek(A_UCSR0A) & UDRE) != 0, 0);
        dut->xck_es_salida = 1;
    }

#if VM_COVERAGE
    // Sólo existe al compilar con `--coverage`. Sin esta llamada la
    // instrumentación corre y se tira a la basura.
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;
    printf("  %ld comprobaciones, %d fallos\n", checks, fails);
    if (fails) {
        printf("  el receptor y el emisor del banco salen de la hoja de datos:\n"
               "  simavr no modela el cable y no puede desmentir a ninguno.\n");
        return 1;
    }
    printf("  forma de onda, formatos, banderas y busqueda de errores correctos\n");
    return 0;
}
