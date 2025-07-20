# AxiomaCore-328: Trabajo Pendiente Priorizado
**Desarrollado en el Semillero de Robótica con asistencia de IA**

**Repositorio:** https://github.com/TadeoRoboticsGroup/AxiomaCore-328  
**Contacto:** ing.marioalvarezvallejo@gmail.com  

---

## 🎯 PLAN DE IMPLEMENTACIÓN DE LO FALTANTE

### **FASE 1: INSTRUCCIONES CRÍTICAS (En Progreso)**
Completar instruction set para compatibilidad Arduino básica.

#### **1.1 Multiplicación Hardware Real [CRÍTICO]**
- ❌ **Estado Actual**: Marcos declarados, ALU_MUL definido, pero sin lógica funcional
- ✅ **Acción**: Implementar lógica real en `axioma_alu_v2.v` líneas 121-180
- 🎯 **Objetivo**: MUL, MULS, MULSU, FMUL family funcionando con resultado en R1:R0

#### **1.2 Operaciones de Memoria 32-bit [CRÍTICO]**
- ⚠️ **Estado Actual**: LDS/STS parcialmente en decodificador, lógica incompleta
- ✅ **Acción**: Completar en `axioma_cpu_v5.v` para manejar `instruction_ext`
- 🎯 **Objetivo**: LDS Rd,k y STS k,Rr funcionando con direcciones de 16 bits

#### **1.3 Operaciones de Palabra [IMPORTANTE]**
- ⚠️ **Estado Actual**: ADIW/SBIW en decodificador, sin soporte ALU 16-bit completo
- ✅ **Acción**: Completar `alu_16bit_operation` en ALU v2
- 🎯 **Objetivo**: ADIW, SBIW, MOVW funcionando con registros de 16 bits

### **FASE 2: PERIFÉRICOS FUNCIONALES (Crítico para Arduino)**

#### **2.1 PWM Real 6 Canales [CRÍTICO]**
- ✅ **Estado Actual**: **PWM YA IMPLEMENTADO** en `peripherals/axioma_pwm/axioma_pwm.v`
- ❌ **Problema**: Falta copiarlo a `openlane/axioma_core_328/src/`
- ✅ **Acción Inmediata**: Copiar archivo y actualizar CPU v5 para conectarlo
- 🎯 **Objetivo**: analogWrite() Arduino funcionando en pines 3,5,6,9,10,11

#### **2.2 ADC Conversión Real [CRÍTICO]**
- ❌ **Estado Actual**: Solo simulación con valores fijos (líneas 222-235)
- ✅ **Acción**: Reemplazar simulación con lógica SAR ADC real
- 🎯 **Objetivo**: analogRead() Arduino con conversión real A/D

#### **2.3 Timer System Tick [CRÍTICO para Arduino]**
- ❌ **Estado Actual**: Sin system tick para millis()/delay()
- ✅ **Acción**: Implementar Timer0 overflow interrupt para millis counter
- 🎯 **Objetivo**: delay() y millis() Arduino funcionando

### **FASE 3: SISTEMA DE INTERRUPCIONES**

#### **3.1 Conexión 26 Vectores [IMPORTANTE]**
- ⚠️ **Estado Actual**: Solo 5/26 vectores conectados realmente
- ✅ **Acción**: Conectar todos los vectores en `axioma_interrupt_v2.v`
- 🎯 **Objetivo**: attachInterrupt() Arduino completo

### **FASE 4: COMUNICACIONES**

#### **4.1 SPI Funcional [IMPORTANTE]**
- ❌ **Estado Actual**: Solo skeleton, falta shift register funcional
- ✅ **Acción**: Implementar lógica completa en `axioma_spi.v`
- 🎯 **Objetivo**: SPI.h Arduino funcionando

#### **4.2 I2C/TWI Funcional [IMPORTANTE]**
- ❌ **Estado Actual**: Solo marcos básicos
- ✅ **Acción**: Implementar state machine TWI en `axioma_i2c.v`
- 🎯 **Objetivo**: Wire.h Arduino funcionando

---

## 📋 LISTA DE ACCIONES INMEDIATAS

### **ACCIÓN 1: Copiar PWM al OpenLane [5 minutos]**
```bash
cp peripherals/axioma_pwm/axioma_pwm.v openlane/axioma_core_328/src/
```

### **ACCIÓN 2: Implementar multiplicación real en ALU [2 horas]**
Archivo: `core/axioma_alu/axioma_alu_v2.v` líneas 121-180
- Completar casos MUL, MULS, MULSU, FMUL
- Implementar resultado en registros R1:R0
- Testing con valores conocidos

### **ACCIÓN 3: Completar LDS/STS 32-bit [3 horas]**
Archivo: `core/axioma_cpu/axioma_cpu_v5.v`
- Manejar `instruction_ext` para segunda palabra
- Implementar direccionamiento directo 16-bit
- Testing con direcciones de memoria reales

### **ACCIÓN 4: Implementar Timer System Tick [2 horas]**
Archivo: `peripherals/axioma_timers/axioma_timer0.v`
- Timer0 overflow cada 1ms
- Contador global millis
- Función delay() basada en millis

### **ACCIÓN 5: Reemplazar ADC simulado [4 horas]**
Archivo: `peripherals/axioma_adc/axioma_adc.v` líneas 222-235
- Implementar SAR ADC real
- Conversión basada en entrada analógica real
- Testing con voltajes conocidos

---

## 🔧 PLAN DE TRABAJO DETALLADO

### **SEMANA 1: Funcionalidad Arduino Básica**
- **Día 1-2**: Copiar PWM + conectar en CPU v5 + testing analogWrite()
- **Día 3-4**: Implementar multiplicación hardware real + testing
- **Día 5-6**: Completar LDS/STS 32-bit + testing
- **Día 7**: Sistema Timer tick para delay()/millis()

### **SEMANA 2: Periféricos Críticos**
- **Día 1-3**: ADC conversión real + testing analogRead()
- **Día 4-5**: Conectar interrupciones faltantes
- **Día 6-7**: Testing integrado Arduino IDE

### **SEMANA 3: Comunicaciones**
- **Día 1-3**: SPI funcional completo
- **Día 4-6**: I2C/TWI funcional completo
- **Día 7**: Testing comunicaciones Arduino

### **SEMANA 4: Integración y Testing**
- **Día 1-2**: OpenLane síntesis con todas las funcionalidades
- **Día 3-4**: Testing exhaustivo Arduino examples
- **Día 5-6**: Corrección documentación
- **Día 7**: Validación final

---

## 📊 MÉTRICAS DE ÉXITO

### **Compatibilidad Arduino Target**
- ✅ digitalWrite/digitalRead: YA FUNCIONAL
- 🎯 analogWrite (PWM): 0% → 100% (Semana 1)
- 🎯 analogRead (ADC): 10% → 100% (Semana 2) 
- 🎯 delay/millis: 0% → 100% (Semana 1)
- 🎯 Serial: 60% → 90% (Ya mayormente funcional)
- 🎯 SPI: 20% → 100% (Semana 3)
- 🎯 Wire (I2C): 15% → 100% (Semana 3)

### **Instruction Set Target**
- 🎯 Instrucciones: 46% → 85% (necesario para Arduino)
- 🎯 Multiplicación: 0% → 100% (Semana 1)
- 🎯 32-bit ops: 50% → 100% (Semana 1)

### **Testing Target**
- 🎯 Arduino examples: 30% → 95% funcionales
- 🎯 Compatibilidad sketches: 40% → 90%

---

## 💡 CONCLUSIÓN

**El proyecto está más avanzado de lo inicialmente evaluado**. El PWM ya está completamente implementado y muchas funcionalidades básicas funcionan. 

**Con 4 semanas de trabajo enfocado**, AxiomaCore-328 puede alcanzar **90% de compatibilidad Arduino real** y convertirse en el **primer microcontrolador AVR open source verdaderamente funcional**.

**Las bases están sólidas. Ahora es tiempo de completar lo que falta y hacer historia.**

---

*Análisis realizado con asistencia de IA en el Semillero de Robótica*  
*Contacto: ing.marioalvarezvallejo@gmail.com*  
*Repositorio: https://github.com/TadeoRoboticsGroup/AxiomaCore-328*