// AxiomaCore-328 - un esclavo I2C escrito desde la hoja de datos
// SPDX-License-Identifier: Apache-2.0
//
// Vive aparte porque lo usan DOS bancos: el del periferico
// -`sim/periph/tb_twi.cpp`, que lo cuelga directamente del modulo- y el del
// SoC -`sim/soc/tb_soc_i2c.cpp`, donde un programa de verdad barre el bus
// buscandolo-. Es el mismo modelo en los dos sitios a proposito: si el
// esclavo del barrido fuera otro, el barrido probaria el esclavo nuevo.
//
// NO COMPARTE UNA SOLA LINEA CON EL RTL, que es lo que lo hace valer de
// oraculo.

#pragma once
#include <cstdint>
#include <vector>

// ------------------------------------------ el otro extremo: un esclavo I2C
// Escrito desde la hoja de datos y desde la especificación del bus, sin una
// sola línea en común con el RTL. Muestrea en el flanco de SUBIDA de SCL y
// cambia el dato en el de BAJADA, que es la única disciplina que hace que un
// START y un STOP -SDA moviéndose con SCL alto- no puedan confundirse nunca
// con un dato.
struct EsclavoI2C {
    bool    activo    = false;
    uint8_t direccion = 0x50;      // 7 bits
    bool    responde  = true;      // si no, no reconoce ni su propia dirección
    int     estirar   = 0;         // ciclos que retiene SCL tras cada byte
    std::vector<uint8_t> recibido;
    std::vector<uint8_t> a_enviar;
    size_t  idx_env   = 0;
    int     nack_tras = -1;        // NACK al recibir el byte n (−1 = nunca)

    bool sda_pull = false, scl_pull = false;

    enum Fase { ESPERA, DIRECCION, RX, TX } f = ESPERA;
    int     bit = 0;
    uint8_t sh  = 0;
    bool    dirigido = false, tx_modo = false;
    bool    scl_ant = true, sda_ant = true;
    int     estirando = 0;
    int     bytes_rx = 0;

    void soltar() { sda_pull = false; scl_pull = false; }

    // LA CUENTA DE BITS VA EN EL FLANCO DE SUBIDA, NO EN EL DE BAJADA, y eso
    // no es un detalle de estilo: el flanco de bajada que CIERRA el START es
    // el primero que se ve, y contarlo como bit se come el ultimo bit de la
    // direccion y desplaza el ACK un puesto. La regla correcta es la del bus:
    // en la subida el dato VALE -se muestrea y se avanza-, y en la bajada se
    // PRESENTA el siguiente.
    void paso(bool scl, bool sda) {
        if (!activo) { soltar(); scl_ant = scl; sda_ant = sda; return; }

        // Estiramiento: mientras retengamos SCL no pasa nada mas. Es lo que
        // obliga al maestro del DUT a mirar el PIN y no su propio contador.
        if (estirando > 0) {
            if (--estirando == 0) scl_pull = false;
            scl_ant = scl; sda_ant = sda;
            return;
        }

        bool scl_sube = scl && !scl_ant;
        bool scl_baja = !scl && scl_ant;
        bool sda_baja = !sda && sda_ant;
        bool sda_sube = sda && !sda_ant;

        // START y STOP mandan sobre cualquier estado: son las dos unicas
        // marcas que un dato no puede producir.
        if (scl && sda_baja) {                    // START o START repetido
            f = DIRECCION; bit = 0; sh = 0;
            dirigido = false; tx_modo = false; sda_pull = false;
            scl_ant = scl; sda_ant = sda; return;
        }
        if (scl && sda_sube) {                    // STOP
            f = ESPERA; dirigido = false; sda_pull = false;
            scl_ant = scl; sda_ant = sda; return;
        }

        if (scl_sube) {
            if (bit < 8) {
                if (f == DIRECCION || f == RX)
                    sh = (uint8_t)((sh << 1) | (sda ? 1 : 0));
            } else if (f == TX) {
                sh = sda ? 1 : 0;                 // el ACK que manda el maestro
            }
            bit++;
        } else if (scl_baja) {
            if (f == DIRECCION) {
                if (bit == 8) {
                    // Noveno pulso: contestamos si la direccion es nuestra.
                    dirigido = responde && ((sh >> 1) == direccion);
                    tx_modo  = (sh & 1) != 0;
                    sda_pull = dirigido;          // tirar de SDA = ACK
                } else if (bit == 9) {
                    sda_pull = false; bit = 0;
                    if (!dirigido) { f = ESPERA; sh = 0; }
                    else if (tx_modo) {
                        f = TX;
                        sh = idx_env < a_enviar.size() ? a_enviar[idx_env++] : 0xFF;
                        sda_pull = (sh & 0x80) == 0;   // el primer bit ya al pin
                        if (estirar) { scl_pull = true; estirando = estirar; }
                    } else {
                        f = RX; sh = 0;
                        if (estirar) { scl_pull = true; estirando = estirar; }
                    }
                }
            } else if (f == RX) {
                if (bit == 8) {
                    recibido.push_back(sh);
                    bool nack = (nack_tras >= 0 && bytes_rx == nack_tras);
                    bytes_rx++;
                    sda_pull = !nack;
                } else if (bit == 9) {
                    sda_pull = false; bit = 0; sh = 0;
                    if (estirar) { scl_pull = true; estirando = estirar; }
                }
            } else if (f == TX) {
                if (bit < 8) {
                    sh = (uint8_t)(sh << 1);
                    sda_pull = (sh & 0x80) == 0;
                } else if (bit == 8) {
                    sda_pull = false;             // soltamos: contesta el maestro
                } else {
                    bit = 0;
                    if (sh != 0) { f = ESPERA; sda_pull = false; }  // nos dieron NACK
                    else {
                        sh = idx_env < a_enviar.size() ? a_enviar[idx_env++] : 0xFF;
                        sda_pull = (sh & 0x80) == 0;
                        if (estirar) { scl_pull = true; estirando = estirar; }
                    }
                }
            }
        }
        scl_ant = scl; sda_ant = sda;
    }
};
