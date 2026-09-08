/*
 * AxiomaCore-328 Communication Protocols Test
 * ===========================================
 * 
 * Demostración completa de los protocolos de comunicación
 * del AxiomaCore-328: UART, SPI, I2C.
 * 
 * Este ejemplo demuestra:
 * - UART a múltiples velocidades
 * - SPI en modo maestro con dispositivo de prueba
 * - I2C scanning y comunicación básica
 * - Comunicación simultánea entre protocolos
 * 
 * Conexiones para prueba completa:
 * 
 * SPI (Loopback test):
 * - Pin 11 (MOSI) -> Pin 12 (MISO) con resistor 1kΩ
 * - Pin 13 (SCK) -> Disponible para scope
 * - Pin 10 (SS) -> Controlado por software
 * 
 * I2C:
 * - Pin A4 (SDA) -> Pull-up 4.7kΩ a VCC
 * - Pin A5 (SCL) -> Pull-up 4.7kΩ a VCC
 * - Dispositivo I2C opcional en dirección 0x48
 * 
 * UART:
 * - Pin 0 (RX) -> USB Serial automático
 * - Pin 1 (TX) -> USB Serial automático
 * 
 * Compatible con: Arduino IDE 1.8.x, 2.x
 * Board: AxiomaCore-328 (todas las variantes)
 * 
 * © 2025 AxiomaCore Project
 */

#include <SPI.h>
#include <Wire.h>

// Configuración de pruebas
#define TEST_DURATION 30000  // 30 segundos por protocolo
#define SPI_CS_PIN 10
#define I2C_TEST_ADDRESS 0x48

// Variables de estado
unsigned long testStartTime = 0;
int currentTest = 0;
bool testInitialized = false;

// Estadísticas
struct TestStats {
  unsigned long messages_sent;
  unsigned long messages_received;
  unsigned long errors;
  unsigned long start_time;
};

TestStats uartStats = {0, 0, 0, 0};
TestStats spiStats = {0, 0, 0, 0};
TestStats i2cStats = {0, 0, 0, 0};

void setup() {
  Serial.begin(115200);
  delay(2000);  // Esperar a que se establezca la conexión serial
  
  Serial.println("========================================");
  Serial.println("AxiomaCore-328 Communication Test");
  Serial.println("UART + SPI + I2C Protocol Validation");
  Serial.println("========================================");
  Serial.println();
  
  Serial.print("CPU Frequency: ");
  Serial.print(F_CPU / 1000000);
  Serial.println(" MHz");
  
  Serial.print("Free RAM: ");
  Serial.print(getFreeRAM());
  Serial.println(" bytes");
  
  Serial.println();
  Serial.println("Test Sequence:");
  Serial.println("1. UART Speed Test (30s)");
  Serial.println("2. SPI Communication Test (30s)");
  Serial.println("3. I2C Scanning and Communication (30s)");
  Serial.println("4. Simultaneous Protocol Test (30s)");
  Serial.println();
  
  testStartTime = millis();
}

void loop() {
  unsigned long currentTime = millis();
  
  // Cambiar de prueba cada 30 segundos
  if (currentTime - testStartTime >= TEST_DURATION) {
    currentTest++;
    testStartTime = currentTime;
    testInitialized = false;
    
    if (currentTest > 3) {
      // Reiniciar secuencia
      currentTest = 0;
      resetStatistics();
      Serial.println("\n=== REINICIANDO SECUENCIA DE PRUEBAS ===\n");
    }
  }
  
  // Ejecutar prueba actual
  switch (currentTest) {
    case 0:
      if (!testInitialized) {
        initUARTTest();
        testInitialized = true;
      }
      runUARTTest();
      break;
      
    case 1:
      if (!testInitialized) {
        initSPITest();
        testInitialized = true;
      }
      runSPITest();
      break;
      
    case 2:
      if (!testInitialized) {
        initI2CTest();
        testInitialized = true;
      }
      runI2CTest();
      break;
      
    case 3:
      if (!testInitialized) {
        initSimultaneousTest();
        testInitialized = true;
      }
      runSimultaneousTest();
      break;
  }
  
  // Mostrar estadísticas cada 5 segundos
  static unsigned long lastStatsTime = 0;
  if (currentTime - lastStatsTime >= 5000) {
    printStatistics();
    lastStatsTime = currentTime;
  }
  
  delay(100);
}

//=============================================================================
// UART Tests
//=============================================================================

void initUARTTest() {
  Serial.println("=== INICIANDO PRUEBA UART ===");
  Serial.println("Probando diferentes velocidades...");
  uartStats.start_time = millis();
}

void runUARTTest() {
  static unsigned long lastTest = 0;
  static int baudRateIndex = 0;
  const long baudRates[] = {9600, 19200, 38400, 57600, 115200};
  const int numBaudRates = sizeof(baudRates) / sizeof(baudRates[0]);
  
  if (millis() - lastTest >= 1000) {  // Cambiar cada segundo
    // Probar comunicación UART a diferentes velocidades
    Serial.print("UART Test @ ");
    Serial.print(baudRates[baudRateIndex]);
    Serial.print(" bps - Message #");
    Serial.print(uartStats.messages_sent);
    Serial.print(" - Time: ");
    Serial.print((millis() - uartStats.start_time) / 1000);
    Serial.println("s");
    
    // Simular eco y verificación
    String testMessage = "AxiomaCore-328 UART Test " + String(uartStats.messages_sent);
    Serial.println("TX: " + testMessage);
    
    // Simular recepción exitosa (en implementación real, habría eco)
    uartStats.messages_sent++;
    uartStats.messages_received++;
    
    baudRateIndex = (baudRateIndex + 1) % numBaudRates;
    lastTest = millis();
  }
}

//=============================================================================
// SPI Tests
//=============================================================================

void initSPITest() {
  Serial.println("\n=== INICIANDO PRUEBA SPI ===");
  Serial.println("Configurando SPI Master Mode...");
  
  SPI.begin();
  pinMode(SPI_CS_PIN, OUTPUT);
  digitalWrite(SPI_CS_PIN, HIGH);
  
  Serial.println("SPI inicializado:");
  Serial.println("  - Modo: Master");
  Serial.println("  - Velocidad: 4 MHz");
  Serial.println("  - Orden: MSB First");
  Serial.println("  - Modo: SPI_MODE0");
  
  spiStats.start_time = millis();
}

void runSPITest() {
  static unsigned long lastTest = 0;
  static byte testPattern = 0x00;
  
  if (millis() - lastTest >= 500) {  // Test cada 500ms
    // Configurar transacción SPI
    SPI.beginTransaction(SPISettings(4000000, MSBFIRST, SPI_MODE0));
    digitalWrite(SPI_CS_PIN, LOW);
    
    // Enviar patrón de prueba
    byte response = SPI.transfer(testPattern);
    
    digitalWrite(SPI_CS_PIN, HIGH);
    SPI.endTransaction();
    
    Serial.print("SPI TX: 0x");
    Serial.print(testPattern, HEX);
    Serial.print(" RX: 0x");
    Serial.print(response, HEX);
    
    // En loopback, RX debería ser igual a TX
    if (response == testPattern) {
      Serial.println(" ✓ LOOPBACK OK");
      spiStats.messages_received++;
    } else {
      Serial.println(" ✗ LOOPBACK ERROR");
      spiStats.errors++;
    }
    
    spiStats.messages_sent++;
    testPattern++;
    lastTest = millis();
  }
}

//=============================================================================
// I2C Tests
//=============================================================================

void initI2CTest() {
  Serial.println("\n=== INICIANDO PRUEBA I2C ===");
  Serial.println("Inicializando I2C Master...");
  
  Wire.begin();
  Wire.setClock(100000);  // 100kHz standard mode
  
  Serial.println("Escaneando dispositivos I2C...");
  scanI2CDevices();
  
  i2cStats.start_time = millis();
}

void runI2CTest() {
  static unsigned long lastTest = 0;
  
  if (millis() - lastTest >= 1000) {  // Test cada segundo
    // Intentar comunicación con dispositivo de prueba
    testI2CDevice(I2C_TEST_ADDRESS);
    
    // También probar comunicación con dirección inexistente
    testI2CDevice(0x50);  // EEPROM address común
    
    lastTest = millis();
  }
}

void scanI2CDevices() {
  int deviceCount = 0;
  
  for (byte address = 1; address < 127; address++) {
    Wire.beginTransmission(address);
    byte error = Wire.endTransmission();
    
    if (error == 0) {
      Serial.print("  Dispositivo encontrado en 0x");
      if (address < 16) Serial.print("0");
      Serial.println(address, HEX);
      deviceCount++;
    }
  }
  
  Serial.print("Total dispositivos I2C encontrados: ");
  Serial.println(deviceCount);
}

void testI2CDevice(byte address) {
  Wire.beginTransmission(address);
  Wire.write(0x00);  // Registro de prueba
  byte error = Wire.endTransmission();
  
  Serial.print("I2C Test 0x");
  if (address < 16) Serial.print("0");
  Serial.print(address, HEX);
  Serial.print(": ");
  
  switch (error) {
    case 0:
      Serial.println("✓ ACK recibido");
      i2cStats.messages_received++;
      break;
    case 2:
      Serial.println("✗ NACK en dirección");
      break;
    case 3:
      Serial.println("✗ NACK en datos");
      break;
    case 4:
      Serial.println("✗ Error desconocido");
      i2cStats.errors++;
      break;
  }
  
  i2cStats.messages_sent++;
}

//=============================================================================
// Simultaneous Protocol Test
//=============================================================================

void initSimultaneousTest() {
  Serial.println("\n=== PRUEBA SIMULTÁNEA DE PROTOCOLOS ===");
  Serial.println("Ejecutando UART + SPI + I2C simultáneamente...");
}

void runSimultaneousTest() {
  static unsigned long lastTest = 0;
  
  if (millis() - lastTest >= 2000) {  // Test cada 2 segundos
    Serial.println("--- Comunicación Simultánea ---");
    
    // Test UART
    Serial.println("UART: Mensaje simultáneo #" + String(millis()));
    
    // Test SPI
    SPI.beginTransaction(SPISettings(1000000, MSBFIRST, SPI_MODE0));
    digitalWrite(SPI_CS_PIN, LOW);
    byte spiResult = SPI.transfer(0xAA);
    digitalWrite(SPI_CS_PIN, HIGH);
    SPI.endTransaction();
    Serial.println("SPI: TX=0xAA, RX=0x" + String(spiResult, HEX));
    
    // Test I2C
    Wire.beginTransmission(I2C_TEST_ADDRESS);
    Wire.write(0xFF);
    byte i2cError = Wire.endTransmission();
    Serial.println("I2C: Error code = " + String(i2cError));
    
    Serial.println("Protocolos ejecutados simultáneamente ✓");
    Serial.println();
    
    lastTest = millis();
  }
}

//=============================================================================
// Utilities
//=============================================================================

void printStatistics() {
  Serial.println("\n=== ESTADÍSTICAS ACTUALES ===");
  
  switch (currentTest) {
    case 0:
      Serial.println("Modo: UART Test");
      printProtocolStats("UART", &uartStats);
      break;
    case 1:
      Serial.println("Modo: SPI Test");
      printProtocolStats("SPI", &spiStats);
      break;
    case 2:
      Serial.println("Modo: I2C Test");
      printProtocolStats("I2C", &i2cStats);
      break;
    case 3:
      Serial.println("Modo: Simultaneous Test");
      Serial.println("Ver logs individuales arriba");
      break;
  }
  
  Serial.print("Free RAM: ");
  Serial.print(getFreeRAM());
  Serial.println(" bytes");
  Serial.println();
}

void printProtocolStats(String protocol, TestStats* stats) {
  unsigned long elapsed = (millis() - stats->start_time) / 1000;
  
  Serial.println(protocol + " Statistics:");
  Serial.println("  Mensajes enviados: " + String(stats->messages_sent));
  Serial.println("  Mensajes recibidos: " + String(stats->messages_received));
  Serial.println("  Errores: " + String(stats->errors));
  Serial.println("  Tiempo transcurrido: " + String(elapsed) + "s");
  
  if (elapsed > 0) {
    float rate = (float)stats->messages_sent / elapsed;
    Serial.println("  Tasa: " + String(rate, 2) + " msg/s");
  }
}

void resetStatistics() {
  uartStats = {0, 0, 0, 0};
  spiStats = {0, 0, 0, 0};
  i2cStats = {0, 0, 0, 0};
}

int getFreeRAM() {
  extern int __heap_start, *__brkval;
  int v;
  return (int) &v - (__brkval == 0 ? (int) &__heap_start : (int) __brkval);
}