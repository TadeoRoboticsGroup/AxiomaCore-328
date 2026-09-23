// AxiomaCore-328 - SPI contra el otro extremo del cable
// SPDX-License-Identifier: Apache-2.0
//
// POR QUÉ HACE FALTA ESTE BANCO. Igual que con la USART, simavr no sirve de
// oráculo: su modelo de SPI transporta BYTES ENTEROS por IRQs internas y no
// serializa nada, así que no hay forma de onda que comparar. Lo que el
// diferencial sí puede verificar es la semántica de los registros; la forma de
// onda la certifica esto.
//
// Y LA FORMA DE ONDA ES EL PERIFÉRICO. Un SPI con los cuatro modos mal tiene
// registros perfectos y datos desplazados un bit, que es un fallo que no da
// ningún error: la pantalla pinta basura y el programa cree que todo va bien.
//
// EL ORÁCULO ES EL OTRO EXTREMO DEL CABLE. El banco implementa un esclavo y un
// maestro escritos desde la hoja de datos —los dos flancos, los cuatro modos,
// `DORD`— y los enchufa al DUT. Si los dos extremos no coinciden bit a bit, uno
// de los dos está mal; y el de aquí no comparte una sola línea de código con el
// RTL.
//
// LOS CUATRO MODOS, en una frase: `CPOL` dice si el reloj reposa alto o bajo;
// `CPHA`, si el dato se MUESTREA en el primer flanco de cada bit o en el
// segundo. El que no muestrea, desplaza.

#include "Vaxioma_spi.h"
#include "verilated.h"
#include <cstdio>
#include <cstdint>
#include <cstdlib>
#include <vector>

static Vaxioma_spi *dut;
static int  fails  = 0;
static long checks = 0;
static const char *fase = "";

static void chk(const char *que, uint32_t got, uint32_t exp) {
    checks++;
    if (got != exp && ++fails <= 12)
        printf("    FALLA [%s] %-32s obtenido=0x%02X esperado=0x%02X\n",
               fase, que, got, exp);
}

// Direcciones de I/O (dirección de dato menos 0x20).
enum { A_SPCR = 0x2C, A_SPSR = 0x2D, A_SPDR = 0x2E };

// Bits de SPCR y SPSR, con los nombres de la hoja de datos.
enum { SPIE = 0x80, SPE = 0x40, DORD = 0x20, MSTR = 0x10,
       CPOL = 0x08, CPHA = 0x04 };
enum { SPIF = 0x80, WCOL = 0x40, SPI2X = 0x01 };

// ------------------------------------------------------------------ el cable
// Lo que hay en cada pin. El DUT conduce unos y el banco otros; quién conduce
// cada uno depende de si el DUT es maestro o esclavo, y eso lo dicen las
// señales de anulación que el propio DUT saca.
static bool pin_ss = true, pin_sck = false, pin_mosi = false, pin_miso = false;
// Lo que conduce el banco cuando le toca.
static bool ext_sck = false, ext_mosi = false, ext_miso = false, ext_ss = true;

static void aplicar_pines() {
    // El SCK y el MOSI los pone el DUT si es maestro; si no, el banco.
    pin_sck  = dut->sck_oe  ? (bool)dut->sck_out  : ext_sck;
    pin_mosi = dut->mosi_oe ? (bool)dut->mosi_out : ext_mosi;
    // El MISO lo pone el DUT si es un esclavo seleccionado; si no, el banco.
    pin_miso = dut->miso_oe ? (bool)dut->miso_out : ext_miso;
    pin_ss   = ext_ss;

    dut->ss_pin = pin_ss; dut->sck_pin = pin_sck;
    dut->mosi_pin = pin_mosi; dut->miso_pin = pin_miso;
}

static long ciclos = 0;

static void tick() {
    aplicar_pines();
    dut->eval();
    dut->clk = 1; dut->eval();
    dut->clk = 0; dut->eval();
    aplicar_pines();
    dut->eval();
    ciclos++;
}

static void wr(uint8_t a, uint8_t d) {
    dut->io_addr = a; dut->io_wdata = d; dut->io_we = 1; dut->io_re = 0;
    tick();
    dut->io_we = 0; dut->eval();
}

static uint8_t rd(uint8_t a) {
    dut->io_addr = a; dut->io_we = 0; dut->io_re = 1;
    aplicar_pines(); dut->eval();
    uint8_t v = dut->io_rdata;
    tick();
    dut->io_re = 0; dut->eval();
    return v;
}

// Lee sin consumir un ciclo, para mirar una bandera sin que avance nada.
static uint8_t mira(uint8_t a) {
    dut->io_addr = a; dut->io_we = 0; dut->io_re = 0;
    aplicar_pines(); dut->eval();
    return dut->io_rdata;
}

static void correr(int n) { for (int i = 0; i < n; i++) tick(); }

// ------------------------------------------- el otro extremo, desde la hoja
// Vale para los dos lados: cuando el DUT es maestro esto es un esclavo, y
// cuando el DUT es esclavo esto es el maestro. Lo único que cambia es quién
// genera el reloj.
struct Extremo {
    int  cpol = 0, cpha = 0, dord = 0;
    uint8_t tx = 0, rx = 0;
    int  bits = 0;
    bool out = false;
    int  sck_ant = 0;

    uint8_t msb() const { return dord ? (tx & 1) : (tx >> 7); }
    void desplaza()     { tx = dord ? (uint8_t)(tx >> 1) : (uint8_t)(tx << 1); }
    void mete(bool b)   { rx = dord ? (uint8_t)((rx >> 1) | (b ? 0x80 : 0))
                                    : (uint8_t)((rx << 1) | (b ? 1 : 0)); }

    // Cargar. Con CPHA=0 el primer bit tiene que estar en el pin ANTES del
    // primer flanco, así que sale aquí; con CPHA=1 sale en el primer flanco.
    void carga(uint8_t d) {
        tx = d; rx = 0; bits = 0;
        if (!cpha) { out = msb(); desplaza(); }
    }

    // Un flanco de SCK. `nivel` es el valor NUEVO del reloj.
    void flanco(int nivel, bool entrada) {
        bool primero = (nivel != cpol);      // el que saca al reloj del reposo
        bool muestrea = cpha ? !primero : primero;
        if (muestrea) { mete(entrada); bits++; }
        else          { out = msb(); desplaza(); }
    }

    // Mira el pin de reloj y llama a `flanco` cuando cambie.
    void observa(int sck, bool entrada) {
        if (sck != sck_ant) flanco(sck, entrada);
        sck_ant = sck;
    }
};

static Extremo otro;

// ----------------------------------------------------- el DUT como maestro
// El banco hace de esclavo: observa el SCK que genera el DUT, muestrea MOSI y
// conduce MISO.
static void maestro_byte(uint8_t del_dut, uint8_t del_banco, int espera) {
    otro.carga(del_banco);
    otro.sck_ant = pin_sck;
    ext_miso = otro.out;

    wr(A_SPDR, del_dut);
    for (int i = 0; i < espera; i++) {
        tick();
        // El esclavo reacciona AL FLANCO QUE ACABA DE PASAR y deja su bit
        // puesto antes del siguiente. Mirarlo antes del tick se comeria el
        // ultimo flanco del byte, que es justo el que cierra la cuenta.
        otro.observa(pin_sck, pin_mosi);
        ext_miso = otro.out;
        if (mira(A_SPSR) & SPIF) break;
    }
    chk("SPIF al terminar el byte", (mira(A_SPSR) & SPIF) != 0, 1);
    chk("el DUT recibio lo que mando el esclavo", mira(A_SPDR), del_banco);
    chk("el esclavo recibio lo que mando el DUT", otro.rx, del_dut);
    chk("ocho bits, ni uno mas", otro.bits, 8);
    // La secuencia de limpieza: leer SPSR y luego acceder a SPDR.
    rd(A_SPSR);
    rd(A_SPDR);
    chk("SPIF limpio tras la secuencia", (mira(A_SPSR) & SPIF) != 0, 0);
}

// ----------------------------------------------------- el DUT como esclavo
// El banco hace de maestro: genera el SCK, conduce MOSI y muestrea MISO.
static void esclavo_byte(uint8_t del_dut, uint8_t del_banco, int semiperiodo) {
    wr(A_SPDR, del_dut);                  // lo que el esclavo tendra preparado
    otro.carga(del_banco);
    ext_mosi = otro.out;
    ext_sck  = otro.cpol;
    correr(3);
    ext_ss = false;                       // seleccionar
    correr(3);

    for (int b = 0; b < 16; b++) {        // 16 semiperiodos = 8 bits
        ext_sck = !ext_sck;
        // El maestro cambia su salida y muestrea con las mismas reglas.
        bool antes = pin_miso;
        correr(semiperiodo);
        otro.flanco(ext_sck, b % 2 == 0 ? pin_miso : pin_miso);
        (void)antes;
        ext_mosi = otro.out;
        correr(semiperiodo);
    }
    correr(4);
    ext_ss = true;
    correr(3);

    chk("SPIF en el esclavo", (mira(A_SPSR) & SPIF) != 0, 1);
    chk("el esclavo recibio lo del maestro", mira(A_SPDR), del_banco);
    chk("el maestro recibio lo del esclavo", otro.rx, del_dut);
    rd(A_SPSR); rd(A_SPDR);
}

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    dut = new Vaxioma_spi;

    dut->rst_n = 0; dut->clk = 0;

    dut->ce = 1;   // a reloj entero: la habilitacion es cosa de CLKPR (ADR 0003)
    dut->io_addr = 0; dut->io_re = 0; dut->io_we = 0; dut->io_wdata = 0;
    dut->ss_pin = 1; dut->sck_pin = 0; dut->mosi_pin = 0; dut->miso_pin = 0;
    dut->ss_es_salida = 0;
    dut->ack_spi = 0;
    dut->eval();
    for (int i = 0; i < 4; i++) tick();
    dut->rst_n = 1; dut->eval();

    printf("\033[1mSPI: maestro y esclavo contra el otro extremo del cable\033[0m\n");

    // ------------------------------------------------- 1. valores de reset
    fase = "reset";
    chk("SPCR a cero", mira(A_SPCR), 0x00);
    chk("SPSR a cero", mira(A_SPSR), 0x00);
    chk("SPDR a cero", mira(A_SPDR), 0x00);

    // ------------------------------ 2. MAESTRO: los cuatro modos y los dos DORD
    // Cada combinación manda y recibe varios bytes. Si el modo estuviera mal,
    // los datos saldrian desplazados un bit y las dos comprobaciones fallarian.
    fase = "maestro";
    {
        static const uint8_t datos[][2] = {
            {0x00, 0xFF}, {0xFF, 0x00}, {0xA5, 0x5A}, {0x01, 0x80}, {0x3C, 0xC3}
        };
        for (int cpol = 0; cpol < 2; cpol++)
        for (int cpha = 0; cpha < 2; cpha++)
        for (int dord = 0; dord < 2; dord++) {
            uint8_t spcr = SPE | MSTR | (cpol ? CPOL : 0) | (cpha ? CPHA : 0)
                         | (dord ? DORD : 0);
            wr(A_SPCR, spcr);
            wr(A_SPSR, 0x00);              // sin SPI2X: fosc/4
            otro.cpol = cpol; otro.cpha = cpha; otro.dord = dord;
            ext_ss = true;                 // el maestro no esta seleccionado
            correr(4);
            for (auto &d : datos) maestro_byte(d[0], d[1], 200);
        }
    }
    printf("  maestro: los cuatro modos por los dos ordenes de bit\n");

    // ------------------------------------- 3. las ocho divisiones del reloj
    // La tabla del manual: SPR1:0 da 4, 16, 64 o 128, y SPI2X la mitad. Se mide
    // el semiperiodo de SCK contando ciclos de reloj del sistema.
    fase = "divisiones";
    {
        const int esperado[2][4] = { {4, 16, 64, 128}, {2, 8, 32, 64} };
        for (int x = 0; x < 2; x++)
        for (int spr = 0; spr < 4; spr++) {
            wr(A_SPCR, SPE | MSTR | (uint8_t)spr);
            wr(A_SPSR, x ? SPI2X : 0);
            otro.cpol = 0; otro.cpha = 0; otro.dord = 0;
            otro.carga(0x00);
            ext_miso = false;
            wr(A_SPDR, 0xAA);
            // Al primer flanco de SCK se empieza a contar; al segundo se para.
            long t0 = -1, t1 = -1;
            int ant = pin_sck;
            for (int i = 0; i < 4000 && t1 < 0; i++) {
                tick();
                if (pin_sck != ant) {
                    if (t0 < 0) t0 = ciclos;
                    else if (t1 < 0) t1 = ciclos;
                    ant = pin_sck;
                }
            }
            long semi = t1 - t0;
            checks++;
            if (semi * 2 != esperado[x][spr]) {
                printf("    FALLA SPR=%d SPI2X=%d: periodo medido %ld, "
                       "la tabla dice %d\n", spr, x, semi * 2, esperado[x][spr]);
                fails++;
            }
            correr(2000);                  // que termine el byte
            rd(A_SPSR); rd(A_SPDR);
        }
    }
    printf("  las ocho divisiones del reloj coinciden con la tabla del manual\n");

    // ------------------------- 3bis. CUANTO DURA UNA TRANSFERENCIA ENTERA
    // Ocho bits son DIECISEIS medios periodos, y el ultimo devuelve el reloj al
    // reposo. Medir solo el periodo de SCK no ve si falta ese ultimo medio:
    // el byte sale igual y el banco diria que todo va bien, pero un esclavo de
    // verdad cuenta flancos y se queda esperando el que no llega.
    //
    // Se mide desde que se escribe SPDR hasta que SPIF se levanta, y eso ademas
    // fija CUANDO se levanta la bandera: si se adelantara medio periodo, el
    // modismo de escribir el siguiente byte al verla caeria dentro de la
    // transferencia todavia en marcha.
    fase = "duracion de la transferencia";
    for (int spr = 0; spr < 4; spr++) {
        const int periodo[4] = {4, 16, 64, 128};
        wr(A_SPCR, SPE | MSTR | (uint8_t)spr);
        wr(A_SPSR, 0x00);
        otro.cpol = 0; otro.cpha = 0; otro.dord = 0;
        otro.carga(0x00); ext_miso = otro.out;
        long t0 = ciclos;
        wr(A_SPDR, 0xC3);
        long t1 = -1;
        for (int i = 0; i < 8000 && t1 < 0; i++) {
            tick();
            otro.observa(pin_sck, pin_mosi);
            ext_miso = otro.out;
            if (mira(A_SPSR) & SPIF) t1 = ciclos;
        }
        long dur = t1 - t0;
        long esperado = 8L * periodo[spr];
        checks++;
        // El margen es un cuarto de periodo: menos que el medio periodo que se
        // quiere distinguir, y mas que los ciclos que cuesta la escritura.
        if (t1 < 0 || dur < esperado - periodo[spr] / 4 - 3 ||
                      dur > esperado + periodo[spr] / 4 + 3) {
            printf("    FALLA SPR=%d: la transferencia duro %ld ciclos y ocho "
                   "bits a /%d son %ld\n", spr, dur, periodo[spr], esperado);
            fails++;
        }
        rd(A_SPSR); rd(A_SPDR);
    }
    printf("  una transferencia dura ocho periodos enteros de SCK\n");

    // ------------------------------------------------- 4. WCOL y la limpieza
    fase = "WCOL";
    wr(A_SPCR, SPE | MSTR | 0x03);         // la division mas lenta, para tener tiempo
    wr(A_SPSR, 0x00);
    otro.cpol = 0; otro.cpha = 0; otro.dord = 0;
    otro.carga(0x00); ext_miso = false;
    wr(A_SPDR, 0x55);
    correr(10);
    chk("sin WCOL todavia", (mira(A_SPSR) & WCOL) != 0, 0);
    wr(A_SPDR, 0xAA);                      // escribir a mitad: COLISION
    chk("WCOL tras escribir en marcha", (mira(A_SPSR) & WCOL) != 0, 1);
    // Y la transferencia NO se ha alterado: sigue saliendo el 0x55.
    for (int i = 0; i < 4000; i++) {
        tick();
        otro.observa(pin_sck, pin_mosi);
        ext_miso = otro.out;
        if (mira(A_SPSR) & SPIF) break;
    }
    chk("la colision no altera el byte en curso", otro.rx, 0x55);
    // La limpieza de WCOL es la misma secuencia que la de SPIF.
    chk("WCOL sigue puesto antes de la secuencia", (mira(A_SPSR) & WCOL) != 0, 1);
    rd(A_SPSR);
    rd(A_SPDR);
    chk("la secuencia limpia WCOL y SPIF", mira(A_SPSR) & (WCOL | SPIF), 0);

    // Leer SPDR sin haber leido SPSR antes NO limpia: son dos accesos en orden.
    fase = "la secuencia es en orden";
    otro.carga(0x00); ext_miso = false;
    wr(A_SPDR, 0x3C);
    for (int i = 0; i < 4000; i++) {
        tick();
        otro.observa(pin_sck, pin_mosi);
        ext_miso = otro.out;
        if (mira(A_SPSR) & SPIF) break;
    }
    rd(A_SPDR);                            // acceso a SPDR SIN leer SPSR antes
    chk("SPIF sigue puesto", (mira(A_SPSR) & SPIF) != 0, 1);
    rd(A_SPSR); rd(A_SPDR);
    chk("y ahora si se limpia", (mira(A_SPSR) & SPIF) != 0, 0);
    // EL MODISMO DE SIEMPRE. `while (!(SPSR & (1<<SPIF))); SPDR = siguiente;`
    // es como se manda un bloque entero, y no puede dar colision: si SPIF se
    // levantara antes de que la transferencia haya terminado de verdad, ese
    // codigo perderia un byte de cada dos sin decir nada.
    fase = "el modismo de siempre";
    for (int lento = 0; lento < 4; lento++) {
        wr(A_SPCR, SPE | MSTR | (uint8_t)lento);
        wr(A_SPSR, 0x00);
        otro.cpol = 0; otro.cpha = 0; otro.dord = 0;
        for (int n = 0; n < 3; n++) {
            otro.carga((uint8_t)(0x11 * n));
            ext_miso = otro.out;
            wr(A_SPDR, (uint8_t)(0x20 + n));
            for (int i = 0; i < 4000; i++) {
                tick();
                otro.observa(pin_sck, pin_mosi);
                ext_miso = otro.out;
                if (mira(A_SPSR) & SPIF) break;
            }
            // Escribir el siguiente byte JUSTO al ver SPIF, sin esperar nada.
            chk("el esclavo recibio el byte entero", otro.rx, (uint8_t)(0x20 + n));
            rd(A_SPSR); rd(A_SPDR);
            wr(A_SPDR, 0x00);
            chk("y el siguiente no da colision", (mira(A_SPSR) & WCOL) != 0, 0);
            for (int i = 0; i < 4000; i++) {
                tick();
                otro.observa(pin_sck, pin_mosi);
                ext_miso = otro.out;
                if (mira(A_SPSR) & SPIF) break;
            }
            rd(A_SPSR); rd(A_SPDR);
        }
    }
    printf("  WCOL, y la secuencia de limpieza en su orden (trampa 11)\n");
    printf("  el modismo «esperar SPIF y escribir el siguiente» no da colision\n");

    // --------------------------------------- 5. colision de maestros: SS baja
    fase = "colision de maestros";
    wr(A_SPCR, SPE | MSTR);
    correr(4);
    chk("es maestro", (mira(A_SPCR) & MSTR) != 0, 1);
    ext_ss = false;                        // otro maestro tira de SS
    correr(8);
    chk("MSTR se limpia solo", (mira(A_SPCR) & MSTR) != 0, 0);
    chk("y levanta SPIF", (mira(A_SPSR) & SPIF) != 0, 1);
    ext_ss = true;
    rd(A_SPSR); rd(A_SPDR);
    correr(4);

    // PERO SI SS ESTA COMO SALIDA, NO PASA NADA. Es el caso normal: todo sketch
    // de Arduino conduce SS a cero para seleccionar a su esclavo. La hoja de
    // datos: «if SS is configured as an output, the pin is a general output pin
    // which does not affect the SPI system». Modelarlo al reves deja al maestro
    // sin MSTR en la primera transferencia.
    dut->ss_es_salida = 1;
    wr(A_SPCR, SPE | MSTR);
    correr(4);
    ext_ss = false;                        // el programa selecciona a su esclavo
    correr(8);
    chk("con SS como salida, MSTR sigue puesto", (mira(A_SPCR) & MSTR) != 0, 1);
    chk("y no hay bandera espuria", (mira(A_SPSR) & SPIF) != 0, 0);
    // Y la transferencia funciona con SS abajo, que es como se usa de verdad.
    otro.cpol = 0; otro.cpha = 0; otro.dord = 0;
    maestro_byte(0x5A, 0xA5, 200);
    ext_ss = true;
    dut->ss_es_salida = 0;
    correr(4);
    printf("  la colision de maestros limpia MSTR y avisa\n");

    // -------------------------------------------- 6. ESCLAVO: los cuatro modos
    fase = "esclavo";
    {
        static const uint8_t datos[][2] = {
            {0xA5, 0x5A}, {0x01, 0x80}, {0xFF, 0x00}, {0x69, 0x96}
        };
        for (int cpol = 0; cpol < 2; cpol++)
        for (int cpha = 0; cpha < 2; cpha++)
        for (int dord = 0; dord < 2; dord++) {
            uint8_t spcr = SPE | (cpol ? CPOL : 0) | (cpha ? CPHA : 0)
                         | (dord ? DORD : 0);
            ext_ss = true; ext_sck = cpol;
            wr(A_SPCR, spcr);
            otro.cpol = cpol; otro.cpha = cpha; otro.dord = dord;
            correr(4);
            for (auto &d : datos) esclavo_byte(d[0], d[1], 4);
        }
    }
    printf("  esclavo: los cuatro modos por los dos ordenes de bit\n");

    // --------------------- 6bis. UN ESCLAVO SIN SELECCIONAR NO TOCA EL BUS
    // MISO es una linea COMPARTIDA por todos los esclavos del bus. Un esclavo
    // que la conduzca sin estar seleccionado cortocircuita contra el que si lo
    // esta, y en una placa de verdad eso es humo. La hoja de datos: MISO es
    // salida «only when the slave is selected».
    fase = "MISO compartido";
    ext_ss = true; ext_sck = false;
    wr(A_SPCR, SPE);                       // esclavo, sin seleccionar
    correr(4);
    chk("sin seleccionar, MISO no conduce", dut->miso_oe, 0);
    ext_ss = false;
    correr(4);
    chk("seleccionado, MISO conduce", dut->miso_oe, 1);
    ext_ss = true;
    correr(4);
    chk("al soltar SS, deja de conducir", dut->miso_oe, 0);
    // Y como maestro tampoco lo conduce nunca.
    wr(A_SPCR, SPE | MSTR);
    correr(4);
    chk("un maestro nunca conduce MISO", dut->miso_oe, 0);
    printf("  un esclavo sin seleccionar suelta MISO\n");

    // ------------------------- 7. la interrupcion, y que el ack limpie SPIF
    fase = "interrupcion";
    wr(A_SPCR, SPIE | SPE | MSTR);
    wr(A_SPSR, 0x00);
    otro.cpol = 0; otro.cpha = 0; otro.dord = 0;
    otro.carga(0x42); ext_miso = otro.out; ext_ss = true;
    wr(A_SPDR, 0x24);
    for (int i = 0; i < 400; i++) {
        tick();
        otro.observa(pin_sck, pin_mosi);
        ext_miso = otro.out;
        if (mira(A_SPSR) & SPIF) break;
    }
    chk("pide interrupcion", dut->irq_spi, 1);
    dut->ack_spi = 1; tick(); dut->ack_spi = 0; tick();
    chk("el ack limpia SPIF", (mira(A_SPSR) & SPIF) != 0, 0);
    chk("y deja de pedir", dut->irq_spi, 0);
    printf("  la interrupcion, y el vector limpia la bandera en su origen\n");

#if VM_COVERAGE
    {
        const char *cov = getenv("AXIOMA_COV");
        Verilated::threadContextp()->coveragep()->write(cov ? cov : "coverage.dat");
    }
#endif
    delete dut;

    printf("  %ld comprobaciones en %ld ciclos, %d fallos\n", checks, ciclos, fails);
    if (fails) {
        printf("  el otro extremo del cable esta escrito desde la hoja de datos, "
               "no desde el RTL\n");
        return 1;
    }
    printf("  los cuatro modos, las ocho divisiones y las dos puntas, correctos\n");
    return 0;
}
