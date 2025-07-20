/*
 * AxiomaCore-328 Basic Blink Example
 * ==================================
 * 
 * Ejemplo básico de parpadeo de LED para demostrar que
 * AxiomaCore-328 es 100% compatible con Arduino.
 * 
 * Este ejemplo utiliza el LED integrado conectado al pin 13
 * y demuestra las funciones básicas de Arduino.
 * 
 * Conexiones:
 * - LED integrado en pin 13 (ya conectado en la placa)
 * - No se requieren conexiones adicionales
 * 
 * Este programa es la primera prueba que debes ejecutar
 * para verificar que tu AxiomaCore-328 funciona correctamente.
 * 
 * Compatible con: Arduino IDE 1.8.x, 2.x
 * Board: AxiomaCore-328 (todas las variantes)
 * 
 * © 2025 AxiomaCore Project
 */

// Pin del LED integrado (compatible con Arduino Uno)
#define LED_BUILTIN 13

void setup() {
  // Inicializar comunicación serial para debugging
  Serial.begin(115200);
  
  // Configurar pin del LED como salida
  pinMode(LED_BUILTIN, OUTPUT);
  
  // Mensaje de bienvenida
  Serial.println("========================================");
  Serial.println("AxiomaCore-328 Basic Blink Example");
  Serial.println("Primer microcontrolador AVR Open Source");
  Serial.println("========================================");
  Serial.println();
  Serial.println("LED parpadea cada segundo en pin 13");
  Serial.println("Monitor serial a 115200 bps");
  Serial.println();
  
  // Test inicial de funcionamiento
  Serial.print("Frecuencia del CPU: ");
  Serial.print(F_CPU / 1000000);
  Serial.println(" MHz");
  
  Serial.print("Compilado: ");
  Serial.print(__DATE__);
  Serial.print(" ");
  Serial.println(__TIME__);
  
  Serial.println("Iniciando bucle principal...");
  Serial.println();
}

void loop() {
  // Encender LED
  digitalWrite(LED_BUILTIN, HIGH);
  Serial.println("LED: ON");
  delay(1000);  // Esperar 1 segundo
  
  // Apagar LED  
  digitalWrite(LED_BUILTIN, LOW);
  Serial.println("LED: OFF");
  delay(1000);  // Esperar 1 segundo
  
  // Mostrar información cada 10 ciclos
  static unsigned long cycle_count = 0;
  cycle_count++;
  
  if (cycle_count % 10 == 0) {
    Serial.println();
    Serial.print("Ciclos completados: ");
    Serial.println(cycle_count);
    Serial.print("Tiempo funcionando: ");
    Serial.print(millis() / 1000);
    Serial.println(" segundos");
    Serial.print("Memoria libre (aprox): ");
    Serial.print(getFreeRAM());
    Serial.println(" bytes");
    Serial.println();
  }
}

// Función para estimar memoria libre
int getFreeRAM() {
  extern int __heap_start, *__brkval;
  int v;
  return (int) &v - (__brkval == 0 ? (int) &__heap_start : (int) __brkval);
}