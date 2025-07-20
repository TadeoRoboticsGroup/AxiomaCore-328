/*
 * AxiomaCore-328 PWM Demonstration
 * =================================
 * 
 * Demostración completa de las capacidades PWM del AxiomaCore-328.
 * Muestra los 6 canales PWM funcionando simultáneamente con diferentes
 * patrones y frecuencias.
 * 
 * Este ejemplo demuestra:
 * - 6 canales PWM independientes
 * - Control de duty cycle variable
 * - Patrones de fade y pulse
 * - Sincronización entre canales
 * 
 * Conexiones recomendadas:
 * - Pin 3  -> LED + resistor 220Ω (PWM Timer2B)
 * - Pin 5  -> LED + resistor 220Ω (PWM Timer0B)
 * - Pin 6  -> LED + resistor 220Ω (PWM Timer0A)
 * - Pin 9  -> LED + resistor 220Ω (PWM Timer1A)
 * - Pin 10 -> LED + resistor 220Ω (PWM Timer1B)
 * - Pin 11 -> LED + resistor 220Ω (PWM Timer2A)
 * 
 * Compatible con: Arduino IDE 1.8.x, 2.x
 * Board: AxiomaCore-328 (todas las variantes)
 * 
 * © 2025 AxiomaCore Project
 */

// Definir pines PWM
const int PWM_PINS[] = {3, 5, 6, 9, 10, 11};
const int NUM_PWM_PINS = sizeof(PWM_PINS) / sizeof(PWM_PINS[0]);

// Variables para patrones
unsigned long lastUpdate = 0;
const unsigned long UPDATE_INTERVAL = 20; // 20ms para smooth animation
int currentStep = 0;

// Patrones de demostración
enum DemoMode {
  FADE_ALL,
  CHASE_PATTERN,
  BREATHING,
  WAVE_PATTERN,
  RANDOM_FLASH,
  BINARY_COUNTER
};

DemoMode currentMode = FADE_ALL;
unsigned long modeStartTime = 0;
const unsigned long MODE_DURATION = 10000; // 10 segundos por modo

void setup() {
  Serial.begin(115200);
  
  Serial.println("========================================");
  Serial.println("AxiomaCore-328 PWM Demonstration");
  Serial.println("6-Channel PWM Capability Test");
  Serial.println("========================================");
  Serial.println();
  
  // Configurar todos los pines PWM
  for (int i = 0; i < NUM_PWM_PINS; i++) {
    pinMode(PWM_PINS[i], OUTPUT);
    Serial.print("PWM Channel ");
    Serial.print(i + 1);
    Serial.print(" configured on pin ");
    Serial.println(PWM_PINS[i]);
  }
  
  Serial.println();
  Serial.println("Demostrando patrones PWM cada 10 segundos:");
  Serial.println("1. Fade All - Todos los canales fade juntos");
  Serial.println("2. Chase Pattern - Efecto de persecución");
  Serial.println("3. Breathing - Patrón de respiración");
  Serial.println("4. Wave Pattern - Onda sinusoidal");
  Serial.println("5. Random Flash - Destellos aleatorios");
  Serial.println("6. Binary Counter - Contador binario");
  Serial.println();
  
  modeStartTime = millis();
}

void loop() {
  unsigned long currentTime = millis();
  
  // Cambiar modo cada 10 segundos
  if (currentTime - modeStartTime >= MODE_DURATION) {
    currentMode = (DemoMode)((currentMode + 1) % 6);
    modeStartTime = currentTime;
    currentStep = 0;
    
    Serial.print("Cambiando a modo: ");
    Serial.println(getModeDescription(currentMode));
  }
  
  // Actualizar PWM cada 20ms
  if (currentTime - lastUpdate >= UPDATE_INTERVAL) {
    updatePWMPattern();
    lastUpdate = currentTime;
    currentStep++;
  }
}

void updatePWMPattern() {
  switch (currentMode) {
    case FADE_ALL:
      fadeAllPattern();
      break;
    case CHASE_PATTERN:
      chasePattern();
      break;
    case BREATHING:
      breathingPattern();
      break;
    case WAVE_PATTERN:
      wavePattern();
      break;
    case RANDOM_FLASH:
      randomFlashPattern();
      break;
    case BINARY_COUNTER:
      binaryCounterPattern();
      break;
  }
}

void fadeAllPattern() {
  // Todos los canales hacen fade al mismo tiempo
  int brightness = (sin(currentStep * 0.1) + 1) * 127.5;
  
  for (int i = 0; i < NUM_PWM_PINS; i++) {
    analogWrite(PWM_PINS[i], brightness);
  }
}

void chasePattern() {
  // Efecto de persecución - un LED se mueve a través de todos los canales
  int activeChannel = (currentStep / 10) % NUM_PWM_PINS;
  
  for (int i = 0; i < NUM_PWM_PINS; i++) {
    if (i == activeChannel) {
      analogWrite(PWM_PINS[i], 255);
    } else {
      // Fade out gradualmente
      int currentValue = map(analogRead(PWM_PINS[i]), 0, 1023, 0, 255);
      analogWrite(PWM_PINS[i], max(0, currentValue - 20));
    }
  }
}

void breathingPattern() {
  // Patrón de respiración con desfase entre canales
  for (int i = 0; i < NUM_PWM_PINS; i++) {
    float phase = (currentStep + i * 20) * 0.05;
    int brightness = (sin(phase) + 1) * 127.5;
    analogWrite(PWM_PINS[i], brightness);
  }
}

void wavePattern() {
  // Onda sinusoidal que se propaga a través de los canales
  for (int i = 0; i < NUM_PWM_PINS; i++) {
    float phase = (currentStep * 0.1) - (i * 0.5);
    int brightness = (sin(phase) + 1) * 127.5;
    analogWrite(PWM_PINS[i], brightness);
  }
}

void randomFlashPattern() {
  // Destellos aleatorios en diferentes canales
  if (currentStep % 5 == 0) { // Update every 100ms
    for (int i = 0; i < NUM_PWM_PINS; i++) {
      if (random(100) < 20) { // 20% probabilidad de destello
        analogWrite(PWM_PINS[i], random(100, 255));
      } else {
        // Fade out gradualmente
        int currentValue = analogRead(PWM_PINS[i]);
        analogWrite(PWM_PINS[i], max(0, currentValue - 30));
      }
    }
  }
}

void binaryCounterPattern() {
  // Contador binario usando los LEDs
  int counter = (currentStep / 20) % 64; // 6 bits = 64 combinaciones
  
  for (int i = 0; i < NUM_PWM_PINS; i++) {
    if (counter & (1 << i)) {
      analogWrite(PWM_PINS[i], 255);
    } else {
      analogWrite(PWM_PINS[i], 0);
    }
  }
}

String getModeDescription(DemoMode mode) {
  switch (mode) {
    case FADE_ALL: return "Fade All";
    case CHASE_PATTERN: return "Chase Pattern";
    case BREATHING: return "Breathing";
    case WAVE_PATTERN: return "Wave Pattern";
    case RANDOM_FLASH: return "Random Flash";
    case BINARY_COUNTER: return "Binary Counter";
    default: return "Unknown";
  }
}

// Función para mostrar estadísticas cada cierto tiempo
void showStatistics() {
  static unsigned long lastStats = 0;
  
  if (millis() - lastStats > 5000) { // Cada 5 segundos
    Serial.println();
    Serial.println("=== PWM Statistics ===");
    Serial.print("Current Mode: ");
    Serial.println(getModeDescription(currentMode));
    Serial.print("Pattern Step: ");
    Serial.println(currentStep);
    Serial.print("Free RAM: ");
    Serial.print(getFreeRAM());
    Serial.println(" bytes");
    
    // Mostrar valores actuales de PWM
    Serial.println("Current PWM values:");
    for (int i = 0; i < NUM_PWM_PINS; i++) {
      Serial.print("  Pin ");
      Serial.print(PWM_PINS[i]);
      Serial.print(": ");
      // Note: analogRead on PWM pins won't give accurate values
      // This is just for demonstration
      Serial.println("Active");
    }
    Serial.println();
    
    lastStats = millis();
  }
}

int getFreeRAM() {
  extern int __heap_start, *__brkval;
  int v;
  return (int) &v - (__brkval == 0 ? (int) &__heap_start : (int) __brkval);
}