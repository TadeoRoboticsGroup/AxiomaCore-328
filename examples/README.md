# AxiomaCore-328 Example Programs

This directory contains example programs demonstrating AxiomaCore-328 functionality and Arduino IDE compatibility.

## Available Examples

### basic_blink.ino
**Description**: Basic LED blinking example demonstrating Arduino compatibility.
**Features**: 
- Built-in LED control (pin 13)
- Serial debugging output
- System information display

**Usage**:
```bash
# Load in Arduino IDE with AxiomaCore-328 board selected
# Serial Monitor: 115200 bps
```

### pwm_demo.ino
**Description**: Comprehensive demonstration of 6 PWM channels.
**Features**:
- 6 simultaneous PWM channels (pins 3, 5, 6, 9, 10, 11)
- Multiple visual patterns (fade, chase, wave, random)
- Automatic pattern switching

**Hardware Setup**:
```
Pins 3, 5, 6, 9, 10, 11 → LEDs with 220Ω resistors
```

### communication_test.ino
**Description**: Complete test of UART, SPI, and I2C protocols.
**Features**:
- UART speed testing (9600-115200 bps)
- SPI loopback testing
- I2C device scanning
- Simultaneous protocol operation

**Hardware Setup**:
```
SPI Loopback: Pin 11 (MOSI) → Pin 12 (MISO) via 1kΩ resistor
I2C Pull-ups: 4.7kΩ resistors on A4 (SDA) and A5 (SCL)
```

## Quick Start

1. Install AxiomaCore-328 board package in Arduino IDE
2. Select **Tools > Board > AxiomaCore-328**
3. Choose appropriate example and upload
4. Open Serial Monitor at 115200 bps

## Testing Sequence

1. **basic_blink.ino** - Verify hardware and Arduino compatibility
2. **pwm_demo.ino** - Test PWM functionality and visual patterns
3. **communication_test.ino** - Validate communication protocols

For detailed technical documentation, see the main project README.md.

---

**License**: MIT  
**Compatibility**: Arduino IDE 2.x with AxiomaCore-328 board package