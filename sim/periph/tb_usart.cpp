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
       U2X = 0x02 };
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

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_usart;

    dut->rst_n = 0; dut->clk = 0;
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
