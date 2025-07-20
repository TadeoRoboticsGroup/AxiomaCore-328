#!/usr/bin/env python3
"""
AxiomaCore-328 Programming Tool
===============================

Herramienta de programación avanzada para microcontroladores AxiomaCore-328.
Soporta programación de Flash, EEPROM, fuses y lectura de información del chip.

Características:
- Programación de Flash (32KB)
- Programación de EEPROM (1KB) 
- Configuración de fuses
- Lectura de signature bytes
- Verificación de programación
- Soporte para múltiples programadores (AVRISP, USBasp, Arduino as ISP)
- Interfaz de línea de comandos intuitiva
- Modo batch para producción

Uso:
    python3 axioma_programmer.py --programmer usbasp --flash firmware.hex
    python3 axioma_programmer.py --programmer arduino --port /dev/ttyUSB0 --eeprom data.eep
    python3 axioma_programmer.py --info --programmer usbasp

© 2025 AxiomaCore Project
Licensed under Apache 2.0
"""

import argparse
import subprocess
import sys
import os
import time
import json
import serial
from datetime import datetime
from pathlib import Path

class AxiomaProgrammer:
    """Programador principal para AxiomaCore-328"""
    
    def __init__(self):
        self.chip_name = "atmega328p"  # Compatible signature
        self.programmer_type = None
        self.port = None
        self.baudrate = 19200
        self.verbose = False
        self.verify = True
        
        # Configuraciones de fuses para AxiomaCore-328
        self.fuse_configs = {
            "default": {
                "lfuse": "0xE2",  # External crystal 8-16MHz, slowly rising power
                "hfuse": "0xD9",  # EEPROM preserved, Boot size 512 words, SPI enabled  
                "efuse": "0xFF"   # Brown-out detection at 2.7V
            },
            "external_16mhz": {
                "lfuse": "0xF7",  # External crystal 16MHz, fast rising power
                "hfuse": "0xD9",
                "efuse": "0xFF"
            },
            "external_20mhz": {
                "lfuse": "0xF7",  # External crystal >16MHz
                "hfuse": "0xD9", 
                "efuse": "0xFF"
            },
            "external_25mhz": {
                "lfuse": "0xF7",  # External crystal >16MHz, optimized for AxiomaCore
                "hfuse": "0xD9",
                "efuse": "0xFF"
            },
            "internal_8mhz": {
                "lfuse": "0xE2",  # Internal 8MHz oscillator
                "hfuse": "0xD9",
                "efuse": "0xFF"
            },
            "bootloader": {
                "lfuse": "0xF7",  # External 16MHz crystal
                "hfuse": "0xDE",  # Boot section enabled, 512 words
                "efuse": "0xFF"
            }
        }
        
    def log(self, message, level="INFO"):
        """Log con timestamp"""
        timestamp = datetime.now().strftime("%H:%M:%S")
        print(f"[{timestamp}] {level}: {message}")
    
    def error(self, message):
        """Log de error"""
        self.log(message, "ERROR")
    
    def warning(self, message):
        """Log de warning"""
        self.log(message, "WARNING")
    
    def verbose_log(self, message):
        """Log verbose"""
        if self.verbose:
            self.log(message, "DEBUG")
    
    def run_avrdude_command(self, command_args):
        """Ejecutar comando avrdude con manejo de errores"""
        
        # Comando base avrdude
        cmd = ["avrdude"]
        
        # Agregar configuración del programador
        if self.programmer_type == "arduino":
            cmd.extend(["-c", "arduino"])
            if self.port:
                cmd.extend(["-P", self.port])
                cmd.extend(["-b", str(self.baudrate)])
        elif self.programmer_type == "usbasp":
            cmd.extend(["-c", "usbasp"])
        elif self.programmer_type == "avrisp":
            cmd.extend(["-c", "avrisp"])
            if self.port:
                cmd.extend(["-P", self.port])
        elif self.programmer_type == "avrisp2":
            cmd.extend(["-c", "avrisp2"])
        else:
            self.error(f"Programador no soportado: {self.programmer_type}")
            return False
        
        # Especificar chip
        cmd.extend(["-p", self.chip_name])
        
        # Agregar argumentos específicos del comando
        cmd.extend(command_args)
        
        # Modo verbose si está habilitado
        if self.verbose:
            cmd.append("-v")
        
        self.verbose_log(f"Ejecutando: {' '.join(cmd)}")
        
        try:
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=120)
            
            if result.returncode == 0:
                if self.verbose:
                    self.log("AVRDUDE output:")
                    print(result.stdout)
                return True
            else:
                self.error("AVRDUDE falló:")
                print(result.stderr)
                return False
                
        except subprocess.TimeoutExpired:
            self.error("Timeout ejecutando AVRDUDE")
            return False
        except FileNotFoundError:
            self.error("AVRDUDE no encontrado. Instalar con: sudo apt install avrdude")
            return False
        except Exception as e:
            self.error(f"Error ejecutando AVRDUDE: {e}")
            return False
    
    def check_connection(self):
        """Verificar conexión con el chip"""
        self.log("Verificando conexión con AxiomaCore-328...")
        
        # Leer signature bytes
        return self.run_avrdude_command(["-U", "signature:r:-:h"])
    
    def read_chip_info(self):
        """Leer información del chip"""
        self.log("Leyendo información del chip...")
        
        info = {
            "timestamp": datetime.now().isoformat(),
            "chip": "AxiomaCore-328",
            "programmer": self.programmer_type
        }
        
        # Leer fuses
        self.log("Leyendo fuses...")
        if self.run_avrdude_command(["-U", "lfuse:r:-:h"]):
            self.log("✓ Low fuse leído")
        
        if self.run_avrdude_command(["-U", "hfuse:r:-:h"]):
            self.log("✓ High fuse leído")
            
        if self.run_avrdude_command(["-U", "efuse:r:-:h"]):
            self.log("✓ Extended fuse leído")
        
        # Leer signature
        self.log("Leyendo signature...")
        if self.run_avrdude_command(["-U", "signature:r:-:h"]):
            self.log("✓ Signature leído")
        
        return info
    
    def program_flash(self, hex_file):
        """Programar memoria Flash"""
        if not os.path.exists(hex_file):
            self.error(f"Archivo hex no encontrado: {hex_file}")
            return False
        
        self.log(f"Programando Flash: {hex_file}")
        
        # Borrar chip primero
        self.log("Borrando chip...")
        if not self.run_avrdude_command(["-e"]):
            return False
        
        # Programar Flash
        self.log("Escribiendo Flash...")
        cmd_args = ["-U", f"flash:w:{hex_file}:i"]
        
        if not self.run_avrdude_command(cmd_args):
            return False
        
        # Verificar si está habilitado
        if self.verify:
            self.log("Verificando Flash...")
            if not self.run_avrdude_command(["-U", f"flash:v:{hex_file}:i"]):
                self.warning("Verificación de Flash falló")
                return False
        
        self.log("✓ Flash programado exitosamente")
        return True
    
    def program_eeprom(self, eep_file):
        """Programar memoria EEPROM"""
        if not os.path.exists(eep_file):
            self.error(f"Archivo EEPROM no encontrado: {eep_file}")
            return False
        
        self.log(f"Programando EEPROM: {eep_file}")
        
        cmd_args = ["-U", f"eeprom:w:{eep_file}:i"]
        
        if not self.run_avrdude_command(cmd_args):
            return False
        
        # Verificar si está habilitado
        if self.verify:
            self.log("Verificando EEPROM...")
            if not self.run_avrdude_command(["-U", f"eeprom:v:{eep_file}:i"]):
                self.warning("Verificación de EEPROM falló")
                return False
        
        self.log("✓ EEPROM programado exitosamente")
        return True
    
    def program_fuses(self, config_name="default"):
        """Programar fuses con configuración predefinida"""
        if config_name not in self.fuse_configs:
            self.error(f"Configuración de fuses no encontrada: {config_name}")
            self.log(f"Configuraciones disponibles: {list(self.fuse_configs.keys())}")
            return False
        
        config = self.fuse_configs[config_name]
        self.log(f"Programando fuses (configuración: {config_name})...")
        
        # Programar cada fuse
        for fuse_type, value in config.items():
            self.log(f"Programando {fuse_type}: {value}")
            
            if not self.run_avrdude_command(["-U", f"{fuse_type}:w:{value}:m"]):
                self.error(f"Error programando {fuse_type}")
                return False
        
        self.log("✓ Fuses programados exitosamente")
        return True
    
    def read_memory(self, memory_type, output_file, format_type="hex"):
        """Leer memoria del chip"""
        self.log(f"Leyendo {memory_type} a {output_file}")
        
        format_char = "i" if format_type == "hex" else "r"
        cmd_args = ["-U", f"{memory_type}:r:{output_file}:{format_char}"]
        
        if self.run_avrdude_command(cmd_args):
            self.log(f"✓ {memory_type} leído exitosamente")
            return True
        else:
            return False
    
    def erase_chip(self):
        """Borrar completamente el chip"""
        self.log("Borrando chip completo...")
        
        if self.run_avrdude_command(["-e"]):
            self.log("✓ Chip borrado exitosamente")
            return True
        else:
            return False
    
    def batch_program(self, batch_file):
        """Programación en lote desde archivo JSON"""
        if not os.path.exists(batch_file):
            self.error(f"Archivo batch no encontrado: {batch_file}")
            return False
        
        try:
            with open(batch_file, 'r') as f:
                batch_config = json.load(f)
        except json.JSONDecodeError as e:
            self.error(f"Error parseando archivo batch: {e}")
            return False
        
        self.log(f"Ejecutando programación batch: {batch_file}")
        
        success_count = 0
        total_count = 0
        
        for item in batch_config.get("program_sequence", []):
            total_count += 1
            action = item.get("action")
            
            self.log(f"Ejecutando acción {total_count}: {action}")
            
            if action == "check_connection":
                if self.check_connection():
                    success_count += 1
                    
            elif action == "program_flash":
                hex_file = item.get("file")
                if hex_file and self.program_flash(hex_file):
                    success_count += 1
                    
            elif action == "program_eeprom":
                eep_file = item.get("file")
                if eep_file and self.program_eeprom(eep_file):
                    success_count += 1
                    
            elif action == "program_fuses":
                config_name = item.get("config", "default")
                if self.program_fuses(config_name):
                    success_count += 1
                    
            elif action == "erase":
                if self.erase_chip():
                    success_count += 1
                    
            else:
                self.warning(f"Acción desconocida: {action}")
        
        self.log(f"Batch completado: {success_count}/{total_count} acciones exitosas")
        return success_count == total_count
    
    def generate_batch_template(self, output_file):
        """Generar template de archivo batch"""
        template = {
            "description": "AxiomaCore-328 Batch Programming Template",
            "programmer": "usbasp",
            "chip": "AxiomaCore-328",
            "verify": True,
            "program_sequence": [
                {
                    "action": "check_connection",
                    "description": "Verificar conexión con el chip"
                },
                {
                    "action": "erase",
                    "description": "Borrar chip completo"
                },
                {
                    "action": "program_fuses",
                    "config": "external_16mhz",
                    "description": "Configurar fuses para cristal externo 16MHz"
                },
                {
                    "action": "program_flash",
                    "file": "firmware.hex",
                    "description": "Programar firmware principal"
                },
                {
                    "action": "program_eeprom",
                    "file": "data.eep",
                    "description": "Programar datos EEPROM (opcional)"
                }
            ]
        }
        
        with open(output_file, 'w') as f:
            json.dump(template, f, indent=2)
        
        self.log(f"Template batch generado: {output_file}")

def main():
    """Función principal"""
    parser = argparse.ArgumentParser(
        description="AxiomaCore-328 Programming Tool",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Ejemplos de uso:

  # Programar Flash con USBasp
  %(prog)s --programmer usbasp --flash firmware.hex

  # Programar con Arduino as ISP
  %(prog)s --programmer arduino --port /dev/ttyUSB0 --flash firmware.hex

  # Configurar fuses para cristal 16MHz
  %(prog)s --programmer usbasp --fuses external_16mhz

  # Leer información del chip
  %(prog)s --programmer usbasp --info

  # Programación batch
  %(prog)s --programmer usbasp --batch program_sequence.json

  # Generar template batch
  %(prog)s --generate-batch template.json

Programadores soportados: usbasp, arduino, avrisp, avrisp2
        """
    )
    
    # Configuración del programador
    parser.add_argument("--programmer", "-p", 
                       choices=["usbasp", "arduino", "avrisp", "avrisp2"],
                       help="Tipo de programador")
    parser.add_argument("--port", "-P",
                       help="Puerto serial (para programadores que lo requieren)")
    parser.add_argument("--baudrate", "-b", type=int, default=19200,
                       help="Baudrate para programadores seriales")
    
    # Operaciones
    parser.add_argument("--flash", "-f",
                       help="Programar archivo hex a Flash")
    parser.add_argument("--eeprom", "-e",
                       help="Programar archivo eep a EEPROM")
    parser.add_argument("--fuses",
                       help="Programar fuses (config: default, external_16mhz, external_20mhz, external_25mhz, internal_8mhz, bootloader)")
    parser.add_argument("--read-flash",
                       help="Leer Flash a archivo")
    parser.add_argument("--read-eeprom", 
                       help="Leer EEPROM a archivo")
    parser.add_argument("--erase", action="store_true",
                       help="Borrar chip completo")
    parser.add_argument("--info", action="store_true",
                       help="Leer información del chip")
    
    # Operaciones batch
    parser.add_argument("--batch",
                       help="Ejecutar programación batch desde archivo JSON")
    parser.add_argument("--generate-batch",
                       help="Generar template de archivo batch")
    
    # Opciones
    parser.add_argument("--no-verify", action="store_true",
                       help="Desactivar verificación después de programar")
    parser.add_argument("--verbose", "-v", action="store_true",
                       help="Salida verbose")
    
    args = parser.parse_args()
    
    # Validar argumentos
    if args.generate_batch:
        programmer = AxiomaProgrammer()
        programmer.generate_batch_template(args.generate_batch)
        return 0
    
    if not args.programmer and not args.generate_batch:
        parser.error("Se requiere especificar --programmer")
    
    # Crear instancia del programador
    programmer = AxiomaProgrammer()
    programmer.programmer_type = args.programmer
    programmer.port = args.port
    programmer.baudrate = args.baudrate
    programmer.verbose = args.verbose
    programmer.verify = not args.no_verify
    
    # Verificar conexión inicial
    if not programmer.check_connection():
        programmer.error("No se pudo conectar con AxiomaCore-328")
        return 1
    
    success = True
    
    # Ejecutar operaciones
    try:
        if args.batch:
            success = programmer.batch_program(args.batch)
            
        else:
            if args.erase:
                success &= programmer.erase_chip()
            
            if args.fuses:
                success &= programmer.program_fuses(args.fuses)
            
            if args.flash:
                success &= programmer.program_flash(args.flash)
            
            if args.eeprom:
                success &= programmer.program_eeprom(args.eeprom)
            
            if args.read_flash:
                success &= programmer.read_memory("flash", args.read_flash)
            
            if args.read_eeprom:
                success &= programmer.read_memory("eeprom", args.read_eeprom)
            
            if args.info:
                programmer.read_chip_info()
        
        if success:
            programmer.log("✅ Operación completada exitosamente")
            return 0
        else:
            programmer.error("❌ Operación falló")
            return 1
            
    except KeyboardInterrupt:
        programmer.warning("Operación cancelada por el usuario")
        return 1
    except Exception as e:
        programmer.error(f"Error inesperado: {e}")
        return 1

if __name__ == "__main__":
    sys.exit(main())