# AxiomaCore-328 Examples
## Ejemplos y Demostraciones

Esta carpeta contiene ejemplos de código que demuestran las capacidades del microcontrolador AxiomaCore-328 y su compatibilidad 100% con Arduino.

## 📁 Ejemplos Disponibles

### 1. **basic_blink.ino** - LED Básico
**Nivel:** Principiante  
**Descripción:** Ejemplo básico de parpadeo de LED que demuestra compatibilidad Arduino.

**Características:**
- Control del LED integrado (pin 13)
- Comunicación serial para debugging
- Información del sistema
- Monitor de memoria libre

**Conexiones:** Ninguna (usa LED integrado)

**Uso:**
```arduino
// Cargar en Arduino IDE
// Seleccionar: Tools > Board > AxiomaCore-328
// Serial Monitor a 115200 bps
```

### 2. **pwm_demo.ino** - Demostración PWM
**Nivel:** Intermedio  
**Descripción:** Demostración completa de los 6 canales PWM del AxiomaCore-328.

**Características:**
- 6 canales PWM simultáneos (pins 3, 5, 6, 9, 10, 11)
- 6 patrones diferentes de demostración
- Efectos visuales: fade, chase, breathing, wave, random, binary
- Cambio automático de patrones cada 10 segundos

**Conexiones:**
```
Pin 3  -> LED + resistor 220Ω
Pin 5  -> LED + resistor 220Ω  
Pin 6  -> LED + resistor 220Ω
Pin 9  -> LED + resistor 220Ω
Pin 10 -> LED + resistor 220Ω
Pin 11 -> LED + resistor 220Ω
```

**Patrones incluidos:**
1. **Fade All** - Todos los canales fade juntos
2. **Chase Pattern** - Efecto de persecución
3. **Breathing** - Patrón de respiración desfasado
4. **Wave Pattern** - Onda sinusoidal propagándose
5. **Random Flash** - Destellos aleatorios
6. **Binary Counter** - Contador binario visual

### 3. **communication_test.ino** - Protocolos de Comunicación
**Nivel:** Avanzado  
**Descripción:** Test completo de UART, SPI e I2C del AxiomaCore-328.

**Características:**
- UART a múltiples velocidades (9600-115200 bps)
- SPI en modo maestro con test de loopback
- I2C scanning y comunicación
- Protocolos simultáneos
- Estadísticas en tiempo real

**Conexiones para prueba completa:**
```
SPI Loopback:
Pin 11 (MOSI) -> Pin 12 (MISO) con resistor 1kΩ
Pin 13 (SCK)  -> Disponible para osciloscopio
Pin 10 (SS)   -> Controlado por software

I2C:
Pin A4 (SDA) -> Pull-up 4.7kΩ a VCC
Pin A5 (SCL) -> Pull-up 4.7kΩ a VCC

UART:
Pin 0 (RX) -> Conexión USB automática
Pin 1 (TX) -> Conexión USB automática
```

**Secuencia de pruebas:**
1. **UART Speed Test** (30s) - Prueba de velocidades
2. **SPI Communication** (30s) - Test de loopback
3. **I2C Scanning** (30s) - Búsqueda y comunicación
4. **Simultaneous Test** (30s) - Protocolos simultáneos

## 🚀 Cómo Usar los Ejemplos

### Configuración de Arduino IDE

1. **Instalar Board Package:**
   ```
   File > Preferences > Additional Board Manager URLs
   Agregar: https://axioma-core.org/arduino/package_axioma_index.json
   ```

2. **Seleccionar Board:**
   ```
   Tools > Board > AxiomaCore-328
   Tools > Processor > AxiomaCore-328 (16MHz External Crystal)
   Tools > Port > [Puerto correspondiente]
   ```

3. **Configurar Serial Monitor:**
   ```
   Baudrate: 115200
   Line ending: Newline
   ```

### Orden Recomendado de Pruebas

1. **Comenzar con basic_blink.ino**
   - Verificar que el hardware funciona
   - Confirmar compatibilidad Arduino
   - Probar comunicación serial

2. **Continuar con pwm_demo.ino**  
   - Validar capacidades PWM
   - Observar patrones visuales
   - Probar sincronización de canales

3. **Finalizar con communication_test.ino**
   - Validar protocolos de comunicación
   - Probar configuraciones complejas
   - Verificar robustez del sistema

## 🔧 Troubleshooting

### Problemas Comunes

**"Board not found":**
- Verificar instalación del board package
- Reiniciar Arduino IDE
- Comprobar URLs del board manager

**"Upload failed":**
- Verificar conexión USB
- Comprobar selección de puerto
- Verificar bootloader (usar "Burn Bootloader" si es necesario)

**"Serial monitor no muestra nada":**
- Verificar baudrate (115200)
- Comprobar conexión serie
- Verificar que el sketch se esté ejecutando

**LEDs no encienden (PWM demo):**
- Verificar conexiones de LEDs
- Comprobar valor de resistores (220Ω recomendado)
- Verificar polaridad de LEDs

**Errores de comunicación (communication_test):**
- Verificar conexiones de loopback SPI
- Comprobar pull-ups I2C (4.7kΩ)
- Verificar integridad de conexiones

### Herramientas de Debug

**Monitor Serial:**
- Todos los ejemplos incluyen output serial detallado
- Usar baudrate 115200 para mejor compatibilidad
- Activar timestamps para debugging temporal

**Osciloscopio/Analizador Lógico:**
- Pins PWM: 3, 5, 6, 9, 10, 11
- SPI: MOSI(11), MISO(12), SCK(13), SS(10)
- I2C: SDA(A4), SCL(A5)

## 📚 Recursos Adicionales

### Documentación
- [AxiomaCore-328 Datasheet](../docs/AxiomaCore-328_TechnicalBrief.md)
- [Arduino Compatibility Guide](../docs/AxiomaCore-328_Fase7_PostSilicio.md)
- [Programming Guide](../tools/programmer/README.md)

### Herramientas
- [Characterization Tools](../tools/characterization/)
- [Production Testing](../tools/production/)
- [Programming Tools](../tools/programmer/)

### Soporte
- **Forum:** https://axioma-community.org
- **GitHub:** https://github.com/axioma-core/axioma328
- **Email:** support@axioma-core.org

## 🏆 Próximos Pasos

Después de completar estos ejemplos, puedes:

1. **Desarrollar aplicaciones complejas** usando la compatibilidad Arduino completa
2. **Integrar shields Arduino** existentes sin modificaciones
3. **Crear proyectos IoT** utilizando los protocolos de comunicación
4. **Optimizar performance** aprovechando las características específicas del AxiomaCore-328
5. **Contribuir al ecosistema** creando más ejemplos y librerías

---

## 📄 Licencia

Todos los ejemplos están bajo licencia Apache 2.0
© 2025 AxiomaCore Project

**AxiomaCore-328 - Primer microcontrolador AVR completamente open source**