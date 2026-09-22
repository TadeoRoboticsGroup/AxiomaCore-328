# Objetivo FPGA: Lattice ECP5

Placa principal del proyecto: **ULX3S 25F** (LFE5U-25F, 24 k LUT4, 1008 Kbit de EBR).

| Fichero | Contenido |
|---------|-----------|
| `axioma_ulx3s.lpf` | Constraints del proyecto. Define el contrato de pines del top. |
| `ulx3s_v20_reference.lpf` | Constraints oficiales completas de la placa, como referencia. Del proyecto ULX3S de emard. |
| `axioma_ulx3s_top.v` | Top de la placa. **Fase 2.** |

## Mapa de pines

| Señal del SoC | ULX3S | Nota |
|---------------|-------|------|
| Reloj de entrada | `clk_25mhz` (G2) | El PLL del top deriva F_CPU |
| Reset | `btn_reset` — FIRE1 (R1) | Activo alto en la placa; el top lo invierte |
| UART TX (PD1) | `ftdi_rxd` (L4) | La FPGA transmite |
| UART RX (PD0) | `ftdi_txd` (M1) | La FPGA recibe |
| PORTB[7:0] | `gp[7:0]` + espejo en `led[7:0]` | PB5 = pin 13 de Arduino = `led[5]` |
| PORTC[6:0] | `gp[14:8]` | A0–A5 + RESET |
| PORTD[7:0] | `gn[7:0]` | D0–D7 |
| — | `wifi_gpio0` (L2) | Debe conducirse a 1 o el ESP32 reinicia la placa |

Los pines de la ULX3S son bidireccionales: el top instancia `TRELLIS_IO` en modo `BIDIR` para
reproducir la semántica `PINx` / `DDRx` / `PORTx` del AVR, incluido el *toggle* por escritura a
`PINx`.

## Flujo

```bash
make bitstream-ulx3s     # yosys -> nextpnr-ecp5 -> ecppack
make prog-ulx3s          # openFPGALoader, carga volátil en SRAM
make flash-ulx3s         # openFPGALoader, escritura permanente en la flash SPI
```

## Recursos, ya medidos

La tabla de abajo era un **presupuesto** —3 000 a 5 000 LUT4— hasta que hubo bitstream. Ahora son
medidas de `nextpnr` tras el rutado, y la estimación se quedó corta por casi el doble: el precio de
los diez periféricos y del contrato de ciclos.

| Recurso | Medido (21-sep-2026) | Disponible en 25F | Ocupación |
|---------|----------------------|-------------------|-----------|
| LUT4 | **8 886** | 24 288 | 36,6 % |
| Biestables | **1 396** | 24 288 | 5,7 % |
| EBR (memoria) | **34 bloques** — 32 KB de programa, 2 KB de SRAM y 1 KB de EEPROM | 56 | 60,7 % |
| Bitstream | **301 KiB** | — | — |
| Fmax medida | **18,88 MHz**, y se corre a 12,5 (margen 1,51×) | — | — |
| Fmax objetivo | ≥ 32 MHz | — | Fase 5 |

**El Fmax baja con cada periférico** —era 20,23 MHz antes del ADC— y eso está en el README al lado
del número. Subirlo es trabajo de la fase 5: lo que manda hoy no es la profundidad lógica sino el
**rutado**, y el siguiente paso identificado es sacar el dato de escritura de la SRAM del camino
combinacional, lo que obliga a separar los buses de datos de SRAM y de I/O.
