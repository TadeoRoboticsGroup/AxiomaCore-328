#!/usr/bin/env python3
"""
AxiomaCore-328 Production Test Suite
===================================

Automated production testing for AxiomaCore-328 microcontrollers.
Designed for manufacturing line integration.

Features:
- Go/No-Go testing for production
- Parametric measurements
- Functional verification
- Data logging for quality control
- Integration with ATE systems

Usage:
    python3 production_test.py --config production_config.json

© 2025 AxiomaCore Project
Licensed under Apache 2.0
"""

import argparse
import json
import time
import serial
import csv
import os
from datetime import datetime, timezone
import logging

class ProductionTester:
    """Production test controller for AxiomaCore-328"""
    
    def __init__(self, config_file):
        """Initialize with configuration file"""
        self.config = self.load_config(config_file)
        self.setup_logging()
        
        self.serial_conn = None
        self.test_results = {}
        self.overall_result = "UNKNOWN"
        
        # Test statistics
        self.tests_run = 0
        self.tests_passed = 0
        self.tests_failed = 0
        
    def load_config(self, config_file):
        """Load test configuration"""
        try:
            with open(config_file, 'r') as f:
                config = json.load(f)
            return config
        except FileNotFoundError:
            # Create default configuration
            default_config = {
                "serial_port": "/dev/ttyUSB0",
                "baudrate": 115200,
                "timeout": 10,
                "test_voltage": 1.8,
                "test_frequency": 16,
                "test_temperature": 25,
                "limits": {
                    "min_frequency": 16.0,
                    "max_current": 4.0,
                    "min_voltage": 1.6,
                    "max_voltage": 2.0
                },
                "tests_enabled": {
                    "power_on": True,
                    "digital_io": True,
                    "analog": True,
                    "communication": True,
                    "timers": True,
                    "memory": True,
                    "parametric": True
                },
                "output": {
                    "log_directory": "production_logs",
                    "csv_file": "production_results.csv",
                    "detailed_logs": True
                }
            }
            
            with open(config_file, 'w') as f:
                json.dump(default_config, f, indent=2)
            
            print(f"Created default config: {config_file}")
            return default_config
    
    def setup_logging(self):
        """Setup logging system"""
        log_dir = self.config["output"]["log_directory"]
        os.makedirs(log_dir, exist_ok=True)
        
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        log_file = os.path.join(log_dir, f"production_test_{timestamp}.log")
        
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s - %(levelname)s - %(message)s',
            handlers=[
                logging.FileHandler(log_file),
                logging.StreamHandler()
            ]
        )
        
        self.logger = logging.getLogger(__name__)
        self.logger.info("Production test system initialized")
    
    def connect_device(self):
        """Connect to device under test"""
        try:
            self.serial_conn = serial.Serial(
                self.config["serial_port"],
                self.config["baudrate"],
                timeout=self.config["timeout"]
            )
            time.sleep(2)  # Allow reset
            
            # Verify communication
            response = self.send_command("*IDN?")
            if "AxiomaCore-328" in response:
                self.logger.info(f"Connected to device: {response}")
                return True
            else:
                self.logger.error(f"Device not recognized: {response}")
                return False
                
        except Exception as e:
            self.logger.error(f"Connection failed: {e}")
            return False
    
    def disconnect_device(self):
        """Disconnect from device"""
        if self.serial_conn and self.serial_conn.is_open:
            self.serial_conn.close()
            self.logger.info("Device disconnected")
    
    def send_command(self, command):
        """Send command to device"""
        if not self.serial_conn:
            raise Exception("No device connection")
        
        self.serial_conn.write((command + '\n').encode())
        response = self.serial_conn.readline().decode().strip()
        return response
    
    def test_power_on_reset(self):
        """Test power-on reset functionality"""
        self.logger.info("Testing power-on reset...")
        
        try:
            # Send reset command
            self.send_command("RESET")
            time.sleep(1)
            
            # Check if device responds after reset
            response = self.send_command("*IDN?")
            
            if "AxiomaCore-328" in response:
                self.test_results["power_on_reset"] = {
                    "status": "PASS",
                    "response_time": "< 1s",
                    "details": "Reset successful"
                }
                return True
            else:
                self.test_results["power_on_reset"] = {
                    "status": "FAIL",
                    "details": f"No response after reset: {response}"
                }
                return False
                
        except Exception as e:
            self.test_results["power_on_reset"] = {
                "status": "FAIL",
                "details": f"Reset test failed: {e}"
            }
            return False
    
    def test_digital_io(self):
        """Test digital I/O functionality"""
        self.logger.info("Testing digital I/O...")
        
        io_results = {}
        all_passed = True
        
        # Test GPIO ports
        ports = ['B', 'C', 'D']
        
        for port in ports:
            try:
                # Test output functionality
                self.send_command(f"GPIO:{port}:DIR OUTPUT")
                self.send_command(f"GPIO:{port}:OUT 0xFF")
                result_high = self.send_command(f"GPIO:{port}:IN?")
                
                self.send_command(f"GPIO:{port}:OUT 0x00")
                result_low = self.send_command(f"GPIO:{port}:IN?")
                
                # Basic functionality check
                if "0xFF" in result_high and "0x00" in result_low:
                    io_results[f"PORT{port}"] = {
                        "status": "PASS",
                        "high_value": result_high,
                        "low_value": result_low
                    }
                else:
                    io_results[f"PORT{port}"] = {
                        "status": "FAIL",
                        "high_value": result_high,
                        "low_value": result_low
                    }
                    all_passed = False
                    
            except Exception as e:
                io_results[f"PORT{port}"] = {
                    "status": "FAIL",
                    "details": str(e)
                }
                all_passed = False
        
        self.test_results["digital_io"] = {
            "overall": "PASS" if all_passed else "FAIL",
            "ports": io_results
        }
        
        return all_passed
    
    def test_analog_functions(self):
        """Test analog functions (ADC)"""
        self.logger.info("Testing analog functions...")
        
        adc_results = {}
        all_passed = True
        
        # Test ADC channels
        for channel in range(6):  # A0-A5
            try:
                reading = self.send_command(f"ADC:READ {channel}")
                value = int(reading)
                
                # Check if reading is in valid range (0-1023)
                if 0 <= value <= 1023:
                    adc_results[f"ADC{channel}"] = {
                        "status": "PASS",
                        "value": value
                    }
                else:
                    adc_results[f"ADC{channel}"] = {
                        "status": "FAIL",
                        "value": value,
                        "details": "Out of range"
                    }
                    all_passed = False
                    
            except Exception as e:
                adc_results[f"ADC{channel}"] = {
                    "status": "FAIL",
                    "details": str(e)
                }
                all_passed = False
        
        # Test internal voltage reference
        try:
            vref_reading = self.send_command("ADC:VREF?")
            vref_value = float(vref_reading)
            
            if 1.0 < vref_value < 1.2:  # Expect ~1.1V internal reference
                adc_results["VREF"] = {
                    "status": "PASS",
                    "voltage": vref_value
                }
            else:
                adc_results["VREF"] = {
                    "status": "FAIL",
                    "voltage": vref_value,
                    "details": "VREF out of spec"
                }
                all_passed = False
                
        except Exception as e:
            adc_results["VREF"] = {
                "status": "FAIL",
                "details": str(e)
            }
            all_passed = False
        
        self.test_results["analog"] = {
            "overall": "PASS" if all_passed else "FAIL",
            "channels": adc_results
        }
        
        return all_passed
    
    def test_communication(self):
        """Test communication peripherals"""
        self.logger.info("Testing communication...")
        
        comm_results = {}
        all_passed = True
        
        # Test UART
        try:
            uart_test = self.send_command("TEST:UART")
            comm_results["UART"] = {
                "status": "PASS" if uart_test == "PASS" else "FAIL",
                "details": uart_test
            }
            if uart_test != "PASS":
                all_passed = False
        except Exception as e:
            comm_results["UART"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        # Test SPI
        try:
            spi_test = self.send_command("TEST:SPI")
            comm_results["SPI"] = {
                "status": "PASS" if spi_test == "PASS" else "FAIL",
                "details": spi_test
            }
            if spi_test != "PASS":
                all_passed = False
        except Exception as e:
            comm_results["SPI"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        # Test I2C
        try:
            i2c_test = self.send_command("TEST:I2C")
            comm_results["I2C"] = {
                "status": "PASS" if i2c_test == "PASS" else "FAIL",
                "details": i2c_test
            }
            if i2c_test != "PASS":
                all_passed = False
        except Exception as e:
            comm_results["I2C"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        self.test_results["communication"] = {
            "overall": "PASS" if all_passed else "FAIL",
            "protocols": comm_results
        }
        
        return all_passed
    
    def test_timers_pwm(self):
        """Test timer and PWM functionality"""
        self.logger.info("Testing timers and PWM...")
        
        timer_results = {}
        all_passed = True
        
        # Test Timer0
        try:
            timer0_test = self.send_command("TEST:TIMER0")
            timer_results["Timer0"] = {
                "status": "PASS" if timer0_test == "PASS" else "FAIL",
                "details": timer0_test
            }
            if timer0_test != "PASS":
                all_passed = False
        except Exception as e:
            timer_results["Timer0"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        # Test Timer1
        try:
            timer1_test = self.send_command("TEST:TIMER1")
            timer_results["Timer1"] = {
                "status": "PASS" if timer1_test == "PASS" else "FAIL",
                "details": timer1_test
            }
            if timer1_test != "PASS":
                all_passed = False
        except Exception as e:
            timer_results["Timer1"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        # Test PWM channels
        pwm_channels = [3, 5, 6, 9, 10, 11]
        for channel in pwm_channels:
            try:
                pwm_test = self.send_command(f"TEST:PWM {channel}")
                timer_results[f"PWM{channel}"] = {
                    "status": "PASS" if pwm_test == "PASS" else "FAIL",
                    "details": pwm_test
                }
                if pwm_test != "PASS":
                    all_passed = False
            except Exception as e:
                timer_results[f"PWM{channel}"] = {"status": "FAIL", "details": str(e)}
                all_passed = False
        
        self.test_results["timers"] = {
            "overall": "PASS" if all_passed else "FAIL",
            "components": timer_results
        }
        
        return all_passed
    
    def test_memory(self):
        """Test memory functionality"""
        self.logger.info("Testing memory...")
        
        memory_results = {}
        all_passed = True
        
        # Test SRAM
        try:
            sram_test = self.send_command("TEST:SRAM")
            memory_results["SRAM"] = {
                "status": "PASS" if sram_test == "PASS" else "FAIL",
                "details": sram_test
            }
            if sram_test != "PASS":
                all_passed = False
        except Exception as e:
            memory_results["SRAM"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        # Test EEPROM
        try:
            eeprom_test = self.send_command("TEST:EEPROM")
            memory_results["EEPROM"] = {
                "status": "PASS" if eeprom_test == "PASS" else "FAIL",
                "details": eeprom_test
            }
            if eeprom_test != "PASS":
                all_passed = False
        except Exception as e:
            memory_results["EEPROM"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        # Test Flash (read-only in production)
        try:
            flash_test = self.send_command("TEST:FLASH")
            memory_results["FLASH"] = {
                "status": "PASS" if flash_test == "PASS" else "FAIL",
                "details": flash_test
            }
            if flash_test != "PASS":
                all_passed = False
        except Exception as e:
            memory_results["FLASH"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        self.test_results["memory"] = {
            "overall": "PASS" if all_passed else "FAIL",
            "types": memory_results
        }
        
        return all_passed
    
    def test_parametric(self):
        """Test parametric specifications"""
        self.logger.info("Testing parametric specifications...")
        
        param_results = {}
        all_passed = True
        limits = self.config["limits"]
        
        # Test supply current
        try:
            current = float(self.send_command("MEAS:CURRENT?"))
            if current <= limits["max_current"]:
                param_results["supply_current"] = {
                    "status": "PASS",
                    "value": current,
                    "limit": limits["max_current"],
                    "unit": "mA"
                }
            else:
                param_results["supply_current"] = {
                    "status": "FAIL",
                    "value": current,
                    "limit": limits["max_current"],
                    "unit": "mA"
                }
                all_passed = False
        except Exception as e:
            param_results["supply_current"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        # Test operating voltage
        try:
            voltage = float(self.send_command("MEAS:VOLTAGE?"))
            if limits["min_voltage"] <= voltage <= limits["max_voltage"]:
                param_results["supply_voltage"] = {
                    "status": "PASS",
                    "value": voltage,
                    "min_limit": limits["min_voltage"],
                    "max_limit": limits["max_voltage"],
                    "unit": "V"
                }
            else:
                param_results["supply_voltage"] = {
                    "status": "FAIL",
                    "value": voltage,
                    "min_limit": limits["min_voltage"],
                    "max_limit": limits["max_voltage"],
                    "unit": "V"
                }
                all_passed = False
        except Exception as e:
            param_results["supply_voltage"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        # Test frequency
        try:
            frequency = float(self.send_command("MEAS:FREQUENCY?"))
            if frequency >= limits["min_frequency"]:
                param_results["frequency"] = {
                    "status": "PASS",
                    "value": frequency,
                    "limit": limits["min_frequency"],
                    "unit": "MHz"
                }
            else:
                param_results["frequency"] = {
                    "status": "FAIL",
                    "value": frequency,
                    "limit": limits["min_frequency"],
                    "unit": "MHz"
                }
                all_passed = False
        except Exception as e:
            param_results["frequency"] = {"status": "FAIL", "details": str(e)}
            all_passed = False
        
        self.test_results["parametric"] = {
            "overall": "PASS" if all_passed else "FAIL",
            "measurements": param_results
        }
        
        return all_passed
    
    def run_production_test(self, serial_number=None):
        """Run complete production test sequence"""
        test_start_time = datetime.now(timezone.utc)
        
        self.logger.info("=" * 60)
        self.logger.info("STARTING PRODUCTION TEST")
        self.logger.info(f"Serial Number: {serial_number or 'UNKNOWN'}")
        self.logger.info(f"Start Time: {test_start_time}")
        self.logger.info("=" * 60)
        
        # Initialize test results
        self.test_results = {
            "serial_number": serial_number or "UNKNOWN",
            "start_time": test_start_time.isoformat(),
            "config": self.config,
            "tests": {}
        }
        
        # Connect to device
        if not self.connect_device():
            self.overall_result = "FAIL"
            self.logger.error("Failed to connect to device")
            return False
        
        try:
            # Run enabled tests
            test_functions = [
                ("power_on", self.test_power_on_reset),
                ("digital_io", self.test_digital_io),
                ("analog", self.test_analog_functions),
                ("communication", self.test_communication),
                ("timers", self.test_timers_pwm),
                ("memory", self.test_memory),
                ("parametric", self.test_parametric)
            ]
            
            overall_pass = True
            
            for test_name, test_function in test_functions:
                if self.config["tests_enabled"].get(test_name, True):
                    self.tests_run += 1
                    
                    try:
                        result = test_function()
                        if result:
                            self.tests_passed += 1
                            self.logger.info(f"✓ {test_name}: PASS")
                        else:
                            self.tests_failed += 1
                            overall_pass = False
                            self.logger.error(f"✗ {test_name}: FAIL")
                    except Exception as e:
                        self.tests_failed += 1
                        overall_pass = False
                        self.logger.error(f"✗ {test_name}: ERROR - {e}")
                        
                        self.test_results[test_name] = {
                            "status": "ERROR",
                            "details": str(e)
                        }
                else:
                    self.logger.info(f"○ {test_name}: SKIPPED")
            
            # Determine overall result
            self.overall_result = "PASS" if overall_pass else "FAIL"
            
        except Exception as e:
            self.overall_result = "ERROR"
            self.logger.error(f"Production test error: {e}")
            
        finally:
            self.disconnect_device()
        
        # Finalize test results
        test_end_time = datetime.now(timezone.utc)
        test_duration = (test_end_time - test_start_time).total_seconds()
        
        self.test_results.update({
            "end_time": test_end_time.isoformat(),
            "duration_seconds": test_duration,
            "overall_result": self.overall_result,
            "tests_run": self.tests_run,
            "tests_passed": self.tests_passed,
            "tests_failed": self.tests_failed
        })
        
        # Log results
        self.logger.info("=" * 60)
        self.logger.info("PRODUCTION TEST COMPLETE")
        self.logger.info(f"Overall Result: {self.overall_result}")
        self.logger.info(f"Tests Run: {self.tests_run}")
        self.logger.info(f"Tests Passed: {self.tests_passed}")
        self.logger.info(f"Tests Failed: {self.tests_failed}")
        self.logger.info(f"Duration: {test_duration:.2f} seconds")
        self.logger.info("=" * 60)
        
        # Save results
        self.save_results()
        
        return self.overall_result == "PASS"
    
    def save_results(self):
        """Save test results to files"""
        output_dir = self.config["output"]["log_directory"]
        
        # Save detailed JSON results
        timestamp = datetime.now().strftime("%Y%m%d_%H%M%S")
        json_file = os.path.join(output_dir, f"test_results_{timestamp}.json")
        
        with open(json_file, 'w') as f:
            json.dump(self.test_results, f, indent=2)
        
        self.logger.info(f"Detailed results saved: {json_file}")
        
        # Append to CSV summary
        csv_file = os.path.join(output_dir, self.config["output"]["csv_file"])
        
        file_exists = os.path.exists(csv_file)
        
        with open(csv_file, 'a', newline='') as f:
            writer = csv.writer(f)
            
            # Write header if new file
            if not file_exists:
                writer.writerow([
                    'Timestamp', 'Serial_Number', 'Overall_Result',
                    'Tests_Run', 'Tests_Passed', 'Tests_Failed',
                    'Duration_Seconds', 'Details_File'
                ])
            
            # Write test summary
            writer.writerow([
                self.test_results["start_time"],
                self.test_results["serial_number"],
                self.test_results["overall_result"],
                self.test_results["tests_run"],
                self.test_results["tests_passed"],
                self.test_results["tests_failed"],
                self.test_results["duration_seconds"],
                json_file
            ])
        
        self.logger.info(f"Summary appended to: {csv_file}")

def main():
    """Main function for production testing"""
    parser = argparse.ArgumentParser(
        description='AxiomaCore-328 Production Test Suite'
    )
    parser.add_argument(
        '--config',
        default='production_config.json',
        help='Configuration file'
    )
    parser.add_argument(
        '--serial',
        help='Device serial number'
    )
    parser.add_argument(
        '--continuous',
        action='store_true',
        help='Run in continuous mode'
    )
    
    args = parser.parse_args()
    
    # Create production tester
    tester = ProductionTester(args.config)
    
    if args.continuous:
        # Continuous testing mode
        print("Continuous testing mode - Press Ctrl+C to stop")
        test_count = 0
        pass_count = 0
        
        try:
            while True:
                test_count += 1
                serial_number = f"AUTO_{test_count:06d}"
                
                print(f"\n--- Test #{test_count} ---")
                result = tester.run_production_test(serial_number)
                
                if result:
                    pass_count += 1
                    print(f"✓ PASS - Running yield: {pass_count}/{test_count} ({(pass_count/test_count)*100:.1f}%)")
                else:
                    print(f"✗ FAIL - Running yield: {pass_count}/{test_count} ({(pass_count/test_count)*100:.1f}%)")
                
                print("Insert next device and press Enter...")
                input()
                
        except KeyboardInterrupt:
            print(f"\nTesting stopped. Final yield: {pass_count}/{test_count} ({(pass_count/test_count)*100:.1f}%)")
    
    else:
        # Single test mode
        result = tester.run_production_test(args.serial)
        
        if result:
            print("\n✅ PRODUCTION TEST PASSED")
            exit(0)
        else:
            print("\n❌ PRODUCTION TEST FAILED")
            exit(1)

if __name__ == "__main__":
    main()