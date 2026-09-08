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

## Presupuesto de recursos

| Recurso | Estimado | Disponible en 25F | Margen |
|---------|----------|-------------------|--------|
| LUT4 | 3 000 – 5 000 | 24 288 | Muy holgado |
| EBR (memoria) | ~280 Kbit | 1008 Kbit | Holgado |
| Fmax objetivo | ≥ 32 MHz | — | A verificar en la fase 5 |
