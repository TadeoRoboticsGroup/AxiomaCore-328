#!/usr/bin/env python3
"""
AxiomaCore-328 Silicon Characterization Tool
===========================================

This tool performs comprehensive characterization of AxiomaCore-328 silicon
including frequency testing, power measurement, and functionality validation.

Features:
- Automated frequency characterization
- Power consumption measurement  
- Temperature coefficient analysis
- Yield binning classification
- Compliance testing
- Report generation

Requirements:
- Python 3.7+
- pyserial for UART communication
- matplotlib for plotting
- numpy for analysis

Usage:
    python3 silicon_characterization.py --port /dev/ttyUSB0 --chip A328-001

© 2025 AxiomaCore Project
Licensed under Apache 2.0
"""

import argparse
import serial
import time
import json
import csv
import matplotlib.pyplot as plt
import numpy as np
from datetime import datetime, timezone
import os
import sys

class AxiomaCoreCharacterizer:
    """Main characterization class for AxiomaCore-328"""
    
    def __init__(self, port, baudrate=115200, timeout=10):
        """Initialize characterizer with serial connection"""
        self.port = port
        self.baudrate = baudrate
        self.timeout = timeout
        self.serial_conn = None
        self.results = {}
        self.chip_id = "UNKNOWN"
        
        # Characterization parameters
        self.frequency_points = [8, 12, 16, 20, 25, 28, 30, 32]  # MHz
        self.voltage_points = [1.6, 1.7, 1.8, 1.9, 2.0]          # Volts
        self.temperature_points = [-40, -25, 0, 25, 50, 85]       # Celsius
        
        # Specification limits
        self.spec_limits = {
            'min_frequency': 16.0,  # MHz
            'max_current_16mhz': 4.0,  # mA at 16MHz
            'max_current_25mhz': 6.0,  # mA at 25MHz
            'min_voltage': 1.62,    # V
            'max_voltage': 1.98,    # V
            'min_temp': -40,        # C
            'max_temp': 85          # C
        }
        
    def connect(self):
        """Establish serial connection to AxiomaCore-328"""
        try:
            self.serial_conn = serial.Serial(
                self.port, 
                self.baudrate, 
                timeout=self.timeout
            )
            time.sleep(2)  # Wait for reset
            
            # Send identification command
            response = self.send_command("*IDN?")
            if "AxiomaCore-328" in response:
                print(f"✓ Conectado a AxiomaCore-328 en {self.port}")
                return True
            else:
                print(f"✗ Dispositivo no reconocido: {response}")
                return False
                
        except serial.SerialException as e:
            print(f"✗ Error de conexión: {e}")
            return False
    
    def disconnect(self):
        """Close serial connection"""
        if self.serial_conn and self.serial_conn.is_open:
            self.serial_conn.close()
            print("✓ Conexión cerrada")
    
    def send_command(self, command):
        """Send command and get response"""
        if not self.serial_conn or not self.serial_conn.is_open:
            raise Exception("Conexión serial no disponible")
        
        self.serial_conn.write((command + '\n').encode())
        response = self.serial_conn.readline().decode().strip()
        return response
    
    def characterize_frequency_response(self):
        """Characterize frequency response across voltage and temperature"""
        print("\n=== CARACTERIZACIÓN DE FRECUENCIA ===")
        
        freq_results = {}
        
        for voltage in self.voltage_points:
            freq_results[voltage] = {}
            
            for temp in self.temperature_points:
                print(f"Testing @ {voltage}V, {temp}°C...")
                
                # Set test conditions
                self.send_command(f"SET:VOLTAGE {voltage}")
                self.send_command(f"SET:TEMPERATURE {temp}")
                time.sleep(5)  # Allow stabilization
                
                # Test frequency points
                freq_results[voltage][temp] = {}
                
                for freq in self.frequency_points:
                    self.send_command(f"SET:FREQUENCY {freq}")
                    time.sleep(1)
                    
                    # Check if frequency is stable
                    stable = self.send_command("FREQ:STABLE?")
                    current = float(self.send_command("MEAS:CURRENT?"))
                    
                    freq_results[voltage][temp][freq] = {
                        'stable': stable == "TRUE",
                        'current_ma': current
                    }
                    
                    status = "✓" if stable == "TRUE" else "✗"
                    print(f"  {freq}MHz: {status} ({current:.2f}mA)")
        
        self.results['frequency_characterization'] = freq_results
        return freq_results
    
    def characterize_power_consumption(self):
        """Measure power consumption at different operating points"""
        print("\n=== CARACTERIZACIÓN DE POTENCIA ===")
        
        # Standard conditions: 25°C, 1.8V
        self.send_command("SET:TEMPERATURE 25")
        self.send_command("SET:VOLTAGE 1.8")
        time.sleep(5)
        
        power_results = {}
        
        test_frequencies = [8, 16, 20, 25]
        
        for freq in test_frequencies:
            self.send_command(f"SET:FREQUENCY {freq}")
            time.sleep(2)
            
            # Measure in different power modes
            modes = ['active', 'idle', 'sleep']
            power_results[freq] = {}
            
            for mode in modes:
                self.send_command(f"SET:POWERMODE {mode}")
                time.sleep(1)
                
                current = float(self.send_command("MEAS:CURRENT?"))
                voltage = float(self.send_command("MEAS:VOLTAGE?"))
                power = current * voltage
                
                power_results[freq][mode] = {
                    'current_ma': current,
                    'voltage_v': voltage,
                    'power_mw': power
                }
                
                print(f"  {freq}MHz {mode}: {current:.2f}mA, {power:.2f}mW")
        
        self.results['power_characterization'] = power_results
        return power_results
    
    def functional_validation(self):
        """Validate all functional blocks"""
        print("\n=== VALIDACIÓN FUNCIONAL ===")
        
        functional_results = {}
        
        # Test peripheral blocks
        peripherals = [
            'GPIO', 'UART', 'SPI', 'I2C', 'ADC', 
            'Timer0', 'Timer1', 'PWM', 'EEPROM'
        ]
        
        for peripheral in peripherals:
            print(f"Testing {peripheral}...")
            
            test_result = self.send_command(f"TEST:{peripheral}")
            passed = test_result == "PASS"
            
            functional_results[peripheral] = {
                'status': 'PASS' if passed else 'FAIL',
                'details': test_result
            }
            
            status = "✓" if passed else "✗"
            print(f"  {peripheral}: {status}")
        
        # Test instruction set
        print("Testing instruction set...")
        instruction_tests = int(self.send_command("TEST:INSTRUCTIONS"))
        instruction_passed = int(self.send_command("TEST:INSTRUCTIONS:PASSED"))
        
        functional_results['instruction_set'] = {
            'total_tests': instruction_tests,
            'passed_tests': instruction_passed,
            'pass_rate': (instruction_passed / instruction_tests) * 100
        }
        
        print(f"  Instructions: {instruction_passed}/{instruction_tests} passed "
              f"({functional_results['instruction_set']['pass_rate']:.1f}%)")
        
        self.results['functional_validation'] = functional_results
        return functional_results
    
    def determine_speed_grade(self):
        """Determine speed grade based on characterization results"""
        print("\n=== DETERMINACIÓN DE GRADO ===")
        
        freq_data = self.results.get('frequency_characterization', {})
        
        # Test at nominal conditions (1.8V, 25°C)
        if 1.8 in freq_data and 25 in freq_data[1.8]:
            nominal_data = freq_data[1.8][25]
            
            max_stable_freq = 0
            for freq, data in nominal_data.items():
                if data['stable']:
                    max_stable_freq = max(max_stable_freq, freq)
        else:
            print("✗ No hay datos de condiciones nominales")
            return "UNKNOWN"
        
        # Determine grade based on maximum stable frequency
        if max_stable_freq >= 32:
            grade = "A328-32P"
        elif max_stable_freq >= 25:
            grade = "A328-25P"
        elif max_stable_freq >= 20:
            grade = "A328-20P"
        elif max_stable_freq >= 16:
            grade = "A328-16P"
        elif max_stable_freq >= 8:
            grade = "A328-8I"
        else:
            grade = "FAIL"
        
        self.results['speed_grade'] = {
            'grade': grade,
            'max_frequency': max_stable_freq,
            'test_conditions': '1.8V, 25°C'
        }
        
        print(f"Grado determinado: {grade} (Max: {max_stable_freq}MHz)")
        return grade
    
    def generate_report(self, output_dir="reports"):
        """Generate comprehensive characterization report"""
        print("\n=== GENERANDO REPORTE ===")
        
        # Create output directory
        os.makedirs(output_dir, exist_ok=True)
        
        timestamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S")
        base_filename = f"axioma328_characterization_{self.chip_id}_{timestamp}"
        
        # Generate JSON report
        json_file = os.path.join(output_dir, f"{base_filename}.json")
        with open(json_file, 'w') as f:
            json.dump(self.results, f, indent=2)
        print(f"✓ Reporte JSON: {json_file}")
        
        # Generate CSV summary
        csv_file = os.path.join(output_dir, f"{base_filename}_summary.csv")
        self.generate_csv_summary(csv_file)
        print(f"✓ Resumen CSV: {csv_file}")
        
        # Generate plots
        plot_file = os.path.join(output_dir, f"{base_filename}_plots.png")
        self.generate_plots(plot_file)
        print(f"✓ Gráficos: {plot_file}")
        
        # Generate text report
        txt_file = os.path.join(output_dir, f"{base_filename}_report.txt")
        self.generate_text_report(txt_file)
        print(f"✓ Reporte texto: {txt_file}")
        
        return {
            'json': json_file,
            'csv': csv_file,
            'plots': plot_file,
            'text': txt_file
        }
    
    def generate_csv_summary(self, filename):
        """Generate CSV summary of key results"""
        with open(filename, 'w', newline='') as f:
            writer = csv.writer(f)
            
            # Header
            writer.writerow([
                'Parameter', 'Value', 'Units', 'Specification', 'Status'
            ])
            
            # Speed grade
            grade = self.results.get('speed_grade', {})
            writer.writerow([
                'Speed Grade', 
                grade.get('grade', 'UNKNOWN'), 
                '', 
                'A328-16P or better', 
                'PASS' if 'FAIL' not in grade.get('grade', '') else 'FAIL'
            ])
            
            # Power consumption at 16MHz
            power_data = self.results.get('power_characterization', {})
            if 16 in power_data and 'active' in power_data[16]:
                current_16mhz = power_data[16]['active']['current_ma']
                writer.writerow([
                    'Current @ 16MHz', 
                    f"{current_16mhz:.2f}", 
                    'mA', 
                    f"<{self.spec_limits['max_current_16mhz']}", 
                    'PASS' if current_16mhz < self.spec_limits['max_current_16mhz'] else 'FAIL'
                ])
            
            # Functional validation summary
            func_data = self.results.get('functional_validation', {})
            if func_data:
                peripheral_count = len([k for k, v in func_data.items() 
                                      if isinstance(v, dict) and v.get('status') == 'PASS'])
                total_peripherals = len([k for k, v in func_data.items() 
                                       if isinstance(v, dict) and 'status' in v])
                
                writer.writerow([
                    'Functional Peripherals', 
                    f"{peripheral_count}/{total_peripherals}", 
                    '', 
                    f"{total_peripherals}/{total_peripherals}", 
                    'PASS' if peripheral_count == total_peripherals else 'FAIL'
                ])
    
    def generate_plots(self, filename):
        """Generate characterization plots"""
        fig, ((ax1, ax2), (ax3, ax4)) = plt.subplots(2, 2, figsize=(12, 10))
        
        # Plot 1: Frequency vs Voltage
        freq_data = self.results.get('frequency_characterization', {})
        if freq_data:
            voltages = []
            max_freqs = []
            
            for voltage in sorted(freq_data.keys()):
                if 25 in freq_data[voltage]:  # At 25°C
                    voltages.append(voltage)
                    max_freq = max([f for f, data in freq_data[voltage][25].items() 
                                  if data['stable']], default=0)
                    max_freqs.append(max_freq)
            
            ax1.plot(voltages, max_freqs, 'bo-')
            ax1.set_xlabel('Voltage (V)')
            ax1.set_ylabel('Max Frequency (MHz)')
            ax1.set_title('Frequency vs Voltage @ 25°C')
            ax1.grid(True)
        
        # Plot 2: Power vs Frequency
        power_data = self.results.get('power_characterization', {})
        if power_data:
            freqs = []
            powers = []
            
            for freq in sorted(power_data.keys()):
                if 'active' in power_data[freq]:
                    freqs.append(freq)
                    powers.append(power_data[freq]['active']['power_mw'])
            
            ax2.plot(freqs, powers, 'ro-')
            ax2.set_xlabel('Frequency (MHz)')
            ax2.set_ylabel('Power (mW)')
            ax2.set_title('Power Consumption vs Frequency')
            ax2.grid(True)
        
        # Plot 3: Functional validation
        func_data = self.results.get('functional_validation', {})
        if func_data:
            peripherals = []
            statuses = []
            
            for peripheral, data in func_data.items():
                if isinstance(data, dict) and 'status' in data:
                    peripherals.append(peripheral)
                    statuses.append(1 if data['status'] == 'PASS' else 0)
            
            colors = ['green' if s else 'red' for s in statuses]
            ax3.bar(range(len(peripherals)), statuses, color=colors)
            ax3.set_xticks(range(len(peripherals)))
            ax3.set_xticklabels(peripherals, rotation=45)
            ax3.set_ylabel('Pass (1) / Fail (0)')
            ax3.set_title('Functional Validation Results')
        
        # Plot 4: Temperature coefficient
        if freq_data:
            temps = []
            freq_25mhz = []
            
            voltage = 1.8  # Nominal voltage
            if voltage in freq_data:
                for temp in sorted(freq_data[voltage].keys()):
                    temps.append(temp)
                    # Check if 25MHz is stable at this temperature
                    stable_25 = freq_data[voltage][temp].get(25, {}).get('stable', False)
                    freq_25mhz.append(25 if stable_25 else 0)
                
                ax4.plot(temps, freq_25mhz, 'go-')
                ax4.set_xlabel('Temperature (°C)')
                ax4.set_ylabel('25MHz Stable (MHz)')
                ax4.set_title('25MHz Stability vs Temperature')
                ax4.grid(True)
        
        plt.tight_layout()
        plt.savefig(filename, dpi=300, bbox_inches='tight')
        plt.close()
    
    def generate_text_report(self, filename):
        """Generate human-readable text report"""
        with open(filename, 'w') as f:
            f.write("AxiomaCore-328 Silicon Characterization Report\n")
            f.write("=" * 50 + "\n\n")
            
            f.write(f"Chip ID: {self.chip_id}\n")
            f.write(f"Test Date: {datetime.now().strftime('%Y-%m-%d %H:%M:%S')}\n")
            f.write(f"Characterization Tool Version: 1.0\n\n")
            
            # Speed grade
            grade_data = self.results.get('speed_grade', {})
            f.write(f"SPEED GRADE: {grade_data.get('grade', 'UNKNOWN')}\n")
            f.write(f"Maximum Frequency: {grade_data.get('max_frequency', 'N/A')} MHz\n\n")
            
            # Functional validation
            f.write("FUNCTIONAL VALIDATION:\n")
            func_data = self.results.get('functional_validation', {})
            for peripheral, data in func_data.items():
                if isinstance(data, dict) and 'status' in data:
                    f.write(f"  {peripheral}: {data['status']}\n")
            
            f.write("\nINSTRUCTION SET:\n")
            if 'instruction_set' in func_data:
                inst_data = func_data['instruction_set']
                f.write(f"  Tests Passed: {inst_data['passed_tests']}/{inst_data['total_tests']}\n")
                f.write(f"  Pass Rate: {inst_data['pass_rate']:.1f}%\n")
            
            # Power consumption
            f.write("\nPOWER CONSUMPTION:\n")
            power_data = self.results.get('power_characterization', {})
            for freq, modes in power_data.items():
                f.write(f"  {freq} MHz:\n")
                for mode, values in modes.items():
                    f.write(f"    {mode}: {values['current_ma']:.2f}mA, {values['power_mw']:.2f}mW\n")
            
            f.write("\n" + "=" * 50 + "\n")
            f.write("End of Report\n")
    
    def run_full_characterization(self):
        """Run complete characterization sequence"""
        print("🚀 INICIANDO CARACTERIZACIÓN COMPLETA DE AxiomaCore-328")
        print("=" * 60)
        
        if not self.connect():
            return False
        
        try:
            # Get chip identification
            self.chip_id = self.send_command("GET:CHIPID")
            print(f"Chip ID: {self.chip_id}")
            
            # Run characterization steps
            self.characterize_frequency_response()
            self.characterize_power_consumption() 
            self.functional_validation()
            self.determine_speed_grade()
            
            # Generate reports
            reports = self.generate_report()
            
            print("\n🎉 ¡CARACTERIZACIÓN COMPLETADA!")
            print("Archivos generados:")
            for report_type, filename in reports.items():
                print(f"  {report_type}: {filename}")
            
            return True
            
        except Exception as e:
            print(f"✗ Error durante caracterización: {e}")
            return False
            
        finally:
            self.disconnect()

def main():
    """Main function"""
    parser = argparse.ArgumentParser(
        description='AxiomaCore-328 Silicon Characterization Tool'
    )
    parser.add_argument(
        '--port', 
        required=True, 
        help='Serial port (e.g., /dev/ttyUSB0, COM3)'
    )
    parser.add_argument(
        '--chip', 
        default='UNKNOWN', 
        help='Chip identifier for reporting'
    )
    parser.add_argument(
        '--output', 
        default='reports', 
        help='Output directory for reports'
    )
    parser.add_argument(
        '--baudrate', 
        type=int, 
        default=115200, 
        help='Serial baud rate'
    )
    
    args = parser.parse_args()
    
    # Create characterizer
    characterizer = AxiomaCoreCharacterizer(args.port, args.baudrate)
    characterizer.chip_id = args.chip
    
    # Run characterization
    success = characterizer.run_full_characterization()
    
    if success:
        print("\n✅ Caracterización exitosa")
        sys.exit(0)
    else:
        print("\n❌ Caracterización falló")
        sys.exit(1)

if __name__ == "__main__":
    main()