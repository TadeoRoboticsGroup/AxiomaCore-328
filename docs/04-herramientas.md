# Cadena de herramientas

**Versión 1.0** · 8 de septiembre de 2026

Cadena 100 % libre, de la especificación al GDSII. Ninguna herramienta propietaria en ninguna
etapa, ni ninguna licencia que caduque.

---

## 1. OSS CAD Suite

Casi todo lo necesario llega en un único paquete de YosysHQ. No requiere `sudo`.

```bash
mkdir -p ~/eda && cd ~/eda
curl -LO https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-09-08/oss-cad-suite-linux-x64-20260908.tgz
tar xzf oss-cad-suite-linux-x64-20260908.tgz
echo 'source ~/eda/oss-cad-suite/environment' >> ~/.bashrc
```

Ocupa unos 2,5 GB e instala 153 binarios. Se publican compilaciones nuevas prácticamente a diario;
conviene fijar una fecha concreta en el proyecto para que la CI sea reproducible.

**Contenido verificado en esta máquina:**

| Herramienta | Versión | Uso |
|-------------|---------|-----|
| `yosys` | 0.68 | Síntesis lógica |
| `nextpnr-ecp5` | 0.1 | Place & route en Lattice ECP5 |
| `nextpnr-ice40` | 0.1 | Place & route en Lattice iCE40 |
| `nextpnr-himbaechel` | 0.1 | Place & route en Gowin y otras |
| `verilator` | 5.053 | Simulación rápida, lint |
| `iverilog` | — | Simulación de referencia |
| `gtkwave` | — | Visor de ondas |
| `openFPGALoader` | 1.1.1 | Carga de bitstreams |
| `sby` | 0.68 | SymbiYosys, verificación formal |
| `ecppack` · `icepack` · `gowin_pack` | — | Generación de bitstream |
| `ghdl` | 7.0.0-dev | VHDL, por si hiciera falta |

---

## 2. Toolchain AVR

**Va con versión fijada, y sin `sudo`:** el toolchain que empaqueta Arduino, descargado de
`downloads.arduino.cc` y extraído en `~/eda/avr`; `simavr` compilado desde fuente en el directorio
del usuario. Los comandos exactos están en [`INSTALL.md`](../INSTALL.md), que es el documento que
se mantiene al día.

| Paquete | Versión fijada | Uso |
|---------|----------------|-----|
| `avr-gcc` | `7.3.0-atmel3.6.1-arduino7` | Compilar los programas de test y el firmware |
| `avr-libc` | la que trae ese paquete | Biblioteca C estándar. **Además es la fuente del mapa de registros** (`iom328p.h`, BSD-3-Clause) |
| `avr-objdump` | binutils 2.26, del mismo paquete | **Oráculo del decodificador** |
| `avrdude` | `6.3.0-arduino18` | Programar a través del bootloader |
| **`simavr`** | commit `66eca78` | **Oráculo de referencia para la co-simulación diferencial** |

**Por qué fijada y no `apt install gcc-avr avr-libc`.** El mapa de registros se **genera** desde
`iom328p.h` de avr-libc, y `make regmap-check` falla si la salida no coincide con la que hay
comiteada. Con otra versión de avr-libc puede no coincidir **sin que nada esté mal**, y el fallo
parece del proyecto. La CI usa exactamente estas versiones por el mismo motivo.

---

## 3. Entorno Python

```bash
python3 -m venv ~/eda/venv
~/eda/venv/bin/pip install numpy
```

**Dos intérpretes a propósito.** El del venv lleva numpy y no pycairo; el de la OSS CAD Suite lleva
pycairo y no numpy. El Makefile los distingue con `PYTHON` y `DIAG_PYTHON`.

| Paquete | Dónde | Uso |
|---------|-------|-----|
| `numpy` | venv (`PYTHON`) | mapa de registros, tabla de ciclos, generador aleatorio, cobertura y mutación |
| `pycairo` | OSS CAD Suite, o `python3-cairo` del sistema (`DIAG_PYTHON`) | `make diagrams`: las figuras del README |

No hay nada más. `cocotb` estuvo aquí listado desde el principio y **el proyecto no lo usa**:
`sim/cocotb` está vacío, y la Capa 6 —verificación formal con SymbiYosys— sigue sin empezar. La
regresión la ejecuta `make`, no `pytest`.

---

## 4. Flujo ASIC — fase 6

**LibreLane 3.x**, sucesor de OpenLane 2 bajo la administración de la FOSSi Foundation. El proyecto
se renombró y migró de `efabless/openlane2` a `librelane/librelane`; la serie 3.0 fue la primera con
la marca nueva.

```bash
# Vía Nix (camino de primera clase, con caché binaria de FOSSi)
nix-shell --pure github:librelane/librelane

# Vía Docker
docker pull ghcr.io/librelane/librelane:latest
```

El PDK se gestiona con **`ciel`** (que sustituye a `volare`), con raíz por defecto en
`$HOME/.ciel`. Magic, Netgen y KLayout vienen en la imagen.

| Herramienta | Uso |
|-------------|-----|
| LibreLane | Flujo RTL → GDSII |
| `ciel` | Gestión del PDK Sky130A |
| Magic | DRC y extracción |
| Netgen | LVS |
| KLayout | Visualización de GDSII, DRC secundario |

---

## 5. Verificación de la instalación

```bash
source ~/eda/oss-cad-suite/environment
yosys -V && nextpnr-ecp5 -V && verilator --version && avr-gcc --version && simavr --version
```

Prueba de humo de la síntesis:

```bash
cat > /tmp/blink.v <<'V'
module blink(input wire clk, output reg led);
  reg [23:0] c;
  always @(posedge clk) begin c <= c + 1; led <= c[23]; end
endmodule
V
yosys -p "read_verilog /tmp/blink.v; synth_ecp5 -top blink -json /tmp/blink.json"
```

---

## 6. Tabla resumen por fase

| Herramienta | Para qué | Fase |
|-------------|----------|------|
| iverilog · verilator | Simulación RTL | 1 |
| cocotb | Testbenches en Python | 1 |
| **simavr** | **Oráculo de referencia** | 1 |
| avr-gcc · avr-libc | Compilar programas de test | 1 |
| yosys | Síntesis | 2 |
| nextpnr + prjtrellis | Place & route en ECP5 | 2 |
| openFPGALoader | Cargar el bitstream | 2 |
| gtkwave | Depuración de ondas | Todas |
| sby (SymbiYosys) | Propiedades formales | 3 |
| avrdude | Programar vía bootloader | 4 |
| LibreLane + ciel | RTL → GDSII en Sky130 | 6 |
| Magic · Netgen · KLayout | DRC y LVS | 6 |
| KiCad | PCB del módulo | 7 |
