# Instalación del entorno

Todo se instala bajo `$HOME/eda` **sin privilegios de root**. No hace falta `sudo` para nada.
Ocupa unos **3,5 GB**.

Verificado sobre Ubuntu 22.04.5 LTS, x86-64, con gcc 11.4 del sistema.

---

## Resumen

| Herramienta | Versión verificada | Para qué | Fase |
|-------------|--------------------|----------|------|
| OSS CAD Suite | `2026-09-08` | Contiene yosys, nextpnr, verilator, iverilog, gtkwave, openFPGALoader, sby | todas |
| avr-gcc | `7.3.0-atmel3.6.1-arduino7` | Compilar los programas de prueba; genera el mapa de registros | 1 |
| avr-objdump | binutils `2.26` (viene con avr-gcc) | **Oráculo del decodificador** | 1 |
| avrdude | `6.3.0-arduino18` | Programar por el bootloader | 4 |
| simavr | commit `66eca78` (2026-08-28) | **Oráculo de referencia del núcleo** | 1 |
| Python | 3.10+ con venv propio | numpy en el venv · pycairo para las figuras | 1 |
| LibreLane + ciel | 3.x | RTL a GDSII sobre Sky130 | 6 |
| KiCad | 8.x | PCB del módulo | 7 |

Las versiones están **fijadas a propósito**. El mapa de registros se genera desde avr-libc y
distintas versiones pueden producir salidas distintas: si cambias de toolchain, `make regmap-check`
fallará aunque el mapa esté bien. La CI usa exactamente estas mismas versiones.

---

## 1. OSS CAD Suite

Un solo paquete con casi todo. 2,5 GB, 153 binarios.

```bash
mkdir -p ~/eda && cd ~/eda
curl -LO https://github.com/YosysHQ/oss-cad-suite-build/releases/download/2026-09-08/oss-cad-suite-linux-x64-20260908.tgz
tar xzf oss-cad-suite-linux-x64-20260908.tgz
rm oss-cad-suite-linux-x64-20260908.tgz
```

Incluye, con las versiones comprobadas en esta máquina:

| Binario | Versión |
|---------|---------|
| `yosys` | 0.68+201 |
| `nextpnr-ecp5` / `nextpnr-ice40` / `nextpnr-himbaechel` | 0.1 |
| `verilator` | 5.053 |
| `iverilog` | 14.0 (devel) |
| `openFPGALoader` | 1.1.1 |
| `sby` (SymbiYosys) | 0.68 |
| `ecppack` (Project Trellis) | 1.4-82 |
| `gtkwave`, `icepack`, `gowin_pack`, `ghdl` | — |

Se publican compilaciones casi a diario. **Fija la fecha**: la CI apunta a la misma.

---

## 2. Toolchain AVR

Se usa el paquete que distribuye Arduino porque no requiere root y queda fijado a una versión
concreta.

```bash
mkdir -p ~/eda/avr && cd ~/eda/avr

# avr-gcc 7.3.0 + avr-libc + binutils (incluye avr-objdump)
curl -sL -o avr-gcc.tar.bz2 \
  https://downloads.arduino.cc/tools/avr-gcc-7.3.0-atmel3.6.1-arduino7-x86_64-pc-linux-gnu.tar.bz2
tar xjf avr-gcc.tar.bz2 && rm avr-gcc.tar.bz2
mv avr avr-gcc-7.3.0

# avrdude
curl -sL -o avrdude.tar.bz2 \
  https://downloads.arduino.cc/tools/avrdude-6.3.0-arduino18-x86_64-pc-linux-gnu.tar.bz2
tar xjf avrdude.tar.bz2 && rm avrdude.tar.bz2
```

**Alternativa con root**, si prefieres los paquetes del sistema:

```bash
sudo apt install gcc-avr avr-libc avrdude
```

Ojo: la versión de avr-libc de Ubuntu puede diferir de la de Arduino y hacer que
`make regmap-check` falle sin que el mapa esté mal. Si vas por esta vía, regenera con
`make regmap` y revisa el diff.

---

## 3. simavr — el oráculo de referencia

Es la pieza que hace posible la verificación diferencial. Se compila desde fuente.

```bash
sudo apt install libelf-dev        # única dependencia con root; comprueba antes si ya la tienes
cd ~/eda
git clone --depth 1 https://github.com/buserror/simavr.git simavr-src
cd simavr-src
make -j$(nproc) build-simavr
```

Produce `simavr/run_avr` y `simavr/obj-x86_64-linux-gnu/libsimavr.{a,so}`. El proyecto enlaza
contra la biblioteca, no contra el ejecutable.

Comprueba si ya tienes libelf antes de instalar nada:

```bash
ls /usr/include/libelf.h /usr/include/gelf.h
```

---

## 4. Entorno Python

**Hacen falta DOS intérpretes, y no es un descuido.** La OSS CAD Suite trae el suyo y lo antepone
al `PATH`: lleva **pycairo** pero **no lleva numpy**. El venv del proyecto lleva numpy pero no
pycairo. Por eso el Makefile tiene dos variables:

| Variable | Quién es | Quién lo usa |
|----------|----------|--------------|
| `PYTHON` | el venv (`AXIOMA_PYTHON`, que pone `env.sh`) | todo lo que necesita **numpy**: el mapa de registros, la tabla de ciclos, el generador aleatorio, la cobertura, la mutación |
| `DIAG_PYTHON` | `python3` tal cual | `make diagrams`, que necesita **pycairo**, y las puertas de documentación |

```bash
python3 -m venv ~/eda/venv
~/eda/venv/bin/pip install -q --upgrade pip
~/eda/venv/bin/pip install numpy
```

Verificado con Python 3.10.12 y numpy 2.2.6. Lo único que el proyecto importa de terceros es
**numpy** y **pycairo**; pycairo llega con la OSS CAD Suite, y si además quieres poder ejecutar
`make diagrams` sin el entorno cargado, el paquete del sistema es `python3-cairo`.

> **La trampa de `PYTHONHOME`.** El intérprete de la OSS CAD Suite se pone `PYTHONHOME` a sí mismo
> **en el entorno del proceso**, y lo hereda todo lo que lance. Un script del venv arrancado desde
> ahí muere con «No module named 'encodings'». `sim/mutation.py` limpia la variable antes de lanzar
> `make` justo por esto; si escribes una herramienta nueva que lance otra, haz lo mismo.

---

## 5. Cargar el entorno

Desde la raíz del repositorio:

```bash
source env.sh
```

Deja en el entorno la OSS CAD Suite, el toolchain AVR, simavr y `AXIOMA_PYTHON`.
Para no repetirlo en cada sesión:

```bash
echo "source ~/Documents/AxiomaCore-328/env.sh" >> ~/.bashrc
```

---

## 6. Comprobación

```bash
make check-tools
```

Debe listar **12 herramientas disponibles, 0 pendientes**. Y después, la regresión completa:

```bash
make check-all
```

**Los 43 objetivos deben pasar**, y tardan unos **veinte minutos** en total —la cobertura y la
co-simulación diferencial son casi todo—. **La lista de lo que tiene que pasar vive en el `Makefile`, en la variable `REGRESION`, y en
ningún otro sitio**: estaba copiada aquí, en el README y en el flujo de la CI, y tres copias de una
lista son tres cifras que se desincronizan.

`make check-all` **no se para en el primer fallo**: si algo se rompe interesa saber qué más se
rompió, y cada objetivo deja su registro en `build/check-<objetivo>.log`.

Si prefieres correrlos sueltos, `make help` los lista todos con una línea de qué hace cada uno.

La prueba de mutación va **aparte**, en un trabajo propio de la CI, porque tarda unos diez minutos
y **modifica el RTL mientras corre**:

```bash
make mutation      # inyecta 327 fallos y comprueba que la regresión los caza
```

`make mutation` **modifica el RTL en sitio** mientras corre: no lances nada en paralelo con él.

---

## 7. Hardware

**FPGA: ULX3S 25F** (Lattice ECP5 LFE5U-25F). Se compra en
[Crowd Supply](https://www.crowdsupply.com/radiona/ulx3s); la fabrica Radiona en Zagreb. No está en
MercadoLibre: hay que importarla.

Alternativas con la misma toolchain abierta, por si hiciera falta:
Tang Nano 20K (Gowin GW2AR-18) o Tang Nano 9K (GW1NR-9), ambas en MercadoLibre por unos 20 USD.
El SoC es el mismo; solo cambian el top y las constraints.

No hace falta ningún driver: `openFPGALoader` habla con el FTDI de la placa. En Linux puede que
necesites una regla de udev para usarla sin root.

---

## 8. Fases posteriores

**Fase 6 — silicio.** LibreLane 3.x, sucesor de OpenLane bajo la FOSSi Foundation:

```bash
nix-shell --pure github:librelane/librelane      # vía recomendada
docker pull ghcr.io/librelane/librelane:latest   # alternativa
```

El PDK Sky130A se gestiona con `ciel` (sustituye a `volare`), con raíz en `$HOME/.ciel`.
Magic, Netgen y KLayout vienen en la imagen.

**Fase 7 — PCB.** KiCad 8.x, desde los repositorios de la distribución.
