# AxiomaCore-328 - entorno de desarrollo
# Uso:  source env.sh
#
# Todo se instala bajo $HOME/eda sin privilegios de root.
# Instrucciones de instalación: docs/04-herramientas.md

export AXIOMA_ROOT="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
export EDA_ROOT="${EDA_ROOT:-$HOME/eda}"

# --- OSS CAD Suite: yosys, nextpnr, verilator, iverilog, gtkwave, sby ---
if [ -f "$EDA_ROOT/oss-cad-suite/environment" ]; then
    source "$EDA_ROOT/oss-cad-suite/environment"
else
    echo "aviso: no se encuentra OSS CAD Suite en $EDA_ROOT/oss-cad-suite" >&2
fi

# --- Toolchain AVR (paquetes de Arduino, sin sudo) ---
export AVR_GCC_ROOT="$EDA_ROOT/avr/avr-gcc-7.3.0"
export AVR_INCLUDE="$AVR_GCC_ROOT/avr/include"
[ -d "$AVR_GCC_ROOT/bin" ]        && export PATH="$AVR_GCC_ROOT/bin:$PATH"
[ -d "$EDA_ROOT/avr/avrdude/bin" ] && export PATH="$EDA_ROOT/avr/avrdude/bin:$PATH"
export AVRDUDE_CONF="$EDA_ROOT/avr/avrdude/etc/avrdude.conf"

# --- simavr: oráculo de la co-simulación diferencial ---
export SIMAVR_ROOT="$EDA_ROOT/simavr-src"
export SIMAVR_LIB="$SIMAVR_ROOT/simavr/obj-x86_64-linux-gnu"
export SIMAVR_INCLUDE="$SIMAVR_ROOT/simavr/sim"
[ -d "$SIMAVR_ROOT/simavr" ] && export PATH="$SIMAVR_ROOT/simavr:$PATH"
export LD_LIBRARY_PATH="$SIMAVR_LIB:$LD_LIBRARY_PATH"

# --- Python del proyecto ---
# La OSS CAD Suite trae su propio intérprete y lo antepone al PATH; no tiene
# numpy. Los scripts del proyecto usan explícitamente este otro.
if [ -x "$EDA_ROOT/venv/bin/python" ]; then
    export AXIOMA_PYTHON="$EDA_ROOT/venv/bin/python"
else
    export AXIOMA_PYTHON="$(command -v /usr/bin/python3 || command -v python3)"
fi

export PATH="$AXIOMA_ROOT/tools:$PATH"
