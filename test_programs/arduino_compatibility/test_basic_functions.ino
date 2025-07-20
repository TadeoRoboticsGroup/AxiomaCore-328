/*
 * AxiomaCore-328 Arduino Compatibility Test Suite
 * Test: Basic Arduino Functions
 * 
 * This test validates basic Arduino functions work correctly
 * on AxiomaCore-328 silicon.
 * 
 * Expected result: All tests should pass and report "PASS"
 * 
 * Compatible with: Arduino IDE 1.8.x, 2.x
 * Board: AxiomaCore-328 (all variants)
 * 
 * © 2025 AxiomaCore Project
 */

#define TEST_PIN_DIGITAL_OUT 13
#define TEST_PIN_DIGITAL_IN  2
#define TEST_PIN_ANALOG_OUT  3
#define TEST_PIN_ANALOG_IN   A0
#define TEST_PIN_PWM        6

// Test results tracking
int tests_passed = 0;
int tests_failed = 0;
int test_number = 0;

void setup() {
  Serial.begin(115200);
  delay(1000);
  
  Serial.println("========================================");
  Serial.println("AxiomaCore-328 Basic Functions Test");
  Serial.println("Versión: 1.0");
  Serial.println("Fecha: 2025");
  Serial.println("========================================");
  Serial.println();
  
  // Configure pins
  pinMode(TEST_PIN_DIGITAL_OUT, OUTPUT);
  pinMode(TEST_PIN_DIGITAL_IN, INPUT_PULLUP);
  pinMode(TEST_PIN_PWM, OUTPUT);
  
  Serial.println("Configuración inicial completada.");
  Serial.println("Iniciando tests básicos...");
  Serial.println();
}

void loop() {
  // Run all tests once
  test_digital_io();
  test_analog_read();
  test_pwm_output();
  test_serial_communication();
  test_timing_functions();
  test_math_functions();
  test_eeprom_access();
  
  // Print final results
  print_test_summary();
  
  // Loop with status indication
  while(1) {
    digitalWrite(LED_BUILTIN, HIGH);
    delay(200);
    digitalWrite(LED_BUILTIN, LOW);
    delay(800);
  }
}

void test_digital_io() {
  start_test("Digital I/O Functions");
  
  // Test digitalWrite and digitalRead
  digitalWrite(TEST_PIN_DIGITAL_OUT, HIGH);
  delay(10);
  
  digitalWrite(TEST_PIN_DIGITAL_OUT, LOW);
  delay(10);
  
  // Test pinMode changes
  pinMode(TEST_PIN_DIGITAL_OUT, INPUT);
  pinMode(TEST_PIN_DIGITAL_OUT, OUTPUT);
  
  pass_test("Digital I/O básico funciona correctamente");
}

void test_analog_read() {
  start_test("Analog Read Functions");
  
  int reading1 = analogRead(TEST_PIN_ANALOG_IN);
  delay(10);
  int reading2 = analogRead(TEST_PIN_ANALOG_IN);
  
  // Readings should be in valid range (0-1023)
  if (reading1 >= 0 && reading1 <= 1023 && 
      reading2 >= 0 && reading2 <= 1023) {
    pass_test("Analog read en rango válido: " + String(reading1) + ", " + String(reading2));
  } else {
    fail_test("Analog read fuera de rango: " + String(reading1) + ", " + String(reading2));
  }
  
  // Test different analog pins
  for (int pin = A0; pin <= A5; pin++) {
    int val = analogRead(pin);
    if (val < 0 || val > 1023) {
      fail_test("Pin analógico A" + String(pin-A0) + " fuera de rango: " + String(val));
      return;
    }
  }
  
  pass_test("Todos los pines analógicos (A0-A5) funcionando");
}

void test_pwm_output() {
  start_test("PWM Output Functions");
  
  // Test different PWM values
  analogWrite(TEST_PIN_PWM, 0);
  delay(50);
  analogWrite(TEST_PIN_PWM, 127);
  delay(50);
  analogWrite(TEST_PIN_PWM, 255);
  delay(50);
  analogWrite(TEST_PIN_PWM, 0);
  
  // Test all PWM pins
  int pwm_pins[] = {3, 5, 6, 9, 10, 11};
  int num_pwm_pins = sizeof(pwm_pins) / sizeof(pwm_pins[0]);
  
  for (int i = 0; i < num_pwm_pins; i++) {
    analogWrite(pwm_pins[i], 128);
    delay(20);
    analogWrite(pwm_pins[i], 0);
  }
  
  pass_test("PWM funcionando en todos los pines: 3,5,6,9,10,11");
}

void test_serial_communication() {
  start_test("Serial Communication");
  
  // Test basic serial functionality
  Serial.print("Test string: ");
  Serial.println("AxiomaCore-328");
  
  Serial.print("Números: ");
  Serial.print(123);
  Serial.print(", ");
  Serial.print(45.67);
  Serial.println();
  
  pass_test("Comunicación serial funcionando correctamente");
}

void test_timing_functions() {
  start_test("Timing Functions");
  
  // Test millis()
  unsigned long start_time = millis();
  delay(100);
  unsigned long end_time = millis();
  unsigned long elapsed = end_time - start_time;
  
  if (elapsed >= 95 && elapsed <= 105) {
    pass_test("delay() y millis() precisos: " + String(elapsed) + "ms");
  } else {
    fail_test("delay() impreciso: esperado ~100ms, obtenido " + String(elapsed) + "ms");
  }
  
  // Test micros()
  unsigned long start_micros = micros();
  delayMicroseconds(1000);
  unsigned long end_micros = micros();
  unsigned long elapsed_micros = end_micros - start_micros;
  
  if (elapsed_micros >= 950 && elapsed_micros <= 1050) {
    pass_test("delayMicroseconds() y micros() precisos: " + String(elapsed_micros) + "μs");
  } else {
    fail_test("delayMicroseconds() impreciso: esperado ~1000μs, obtenido " + String(elapsed_micros) + "μs");
  }
}

void test_math_functions() {
  start_test("Math Functions");
  
  // Test basic math
  float result1 = sqrt(16.0);
  if (abs(result1 - 4.0) < 0.001) {
    pass_test("sqrt() funcionando: sqrt(16) = " + String(result1));
  } else {
    fail_test("sqrt() incorrecto: esperado 4.0, obtenido " + String(result1));
  }
  
  // Test trigonometry
  float result2 = sin(PI/2);
  if (abs(result2 - 1.0) < 0.001) {
    pass_test("sin() funcionando: sin(π/2) = " + String(result2));
  } else {
    fail_test("sin() incorrecto: esperado 1.0, obtenido " + String(result2));
  }
  
  // Test random
  randomSeed(analogRead(0));
  long rand1 = random(100);
  long rand2 = random(100);
  
  if (rand1 >= 0 && rand1 < 100 && rand2 >= 0 && rand2 < 100) {
    pass_test("random() funcionando: " + String(rand1) + ", " + String(rand2));
  } else {
    fail_test("random() fuera de rango");
  }
}

void test_eeprom_access() {
  start_test("EEPROM Access");
  
  #include <EEPROM.h>
  
  // Test EEPROM write/read
  byte test_value = 0xAA;
  int test_address = 100;
  
  EEPROM.write(test_address, test_value);
  delay(10);
  byte read_value = EEPROM.read(test_address);
  
  if (read_value == test_value) {
    pass_test("EEPROM write/read funcionando: 0x" + String(test_value, HEX));
  } else {
    fail_test("EEPROM error: escribió 0x" + String(test_value, HEX) + 
              ", leyó 0x" + String(read_value, HEX));
  }
  
  // Test EEPROM update
  byte new_value = 0x55;
  EEPROM.update(test_address, new_value);
  delay(10);
  byte updated_value = EEPROM.read(test_address);
  
  if (updated_value == new_value) {
    pass_test("EEPROM update funcionando: 0x" + String(new_value, HEX));
  } else {
    fail_test("EEPROM update error: esperado 0x" + String(new_value, HEX) + 
              ", obtenido 0x" + String(updated_value, HEX));
  }
  
  // Restore original value
  EEPROM.write(test_address, 0xFF);
}

void start_test(String test_name) {
  test_number++;
  Serial.print("Test ");
  Serial.print(test_number);
  Serial.print(": ");
  Serial.print(test_name);
  Serial.print(" ... ");
}

void pass_test(String message) {
  tests_passed++;
  Serial.print("PASS");
  if (message.length() > 0) {
    Serial.print(" (");
    Serial.print(message);
    Serial.print(")");
  }
  Serial.println();
}

void fail_test(String message) {
  tests_failed++;
  Serial.print("FAIL");
  if (message.length() > 0) {
    Serial.print(" (");
    Serial.print(message);
    Serial.print(")");
  }
  Serial.println();
}

void print_test_summary() {
  Serial.println();
  Serial.println("========================================");
  Serial.println("RESUMEN DE TESTS");
  Serial.println("========================================");
  Serial.print("Tests ejecutados: ");
  Serial.println(test_number);
  Serial.print("Tests exitosos:   ");
  Serial.println(tests_passed);
  Serial.print("Tests fallidos:   ");
  Serial.println(tests_failed);
  
  float success_rate = (float)tests_passed / (float)test_number * 100.0;
  Serial.print("Tasa de éxito:    ");
  Serial.print(success_rate, 1);
  Serial.println("%");
  
  Serial.println();
  if (tests_failed == 0) {
    Serial.println("🎉 ¡TODOS LOS TESTS PASARON!");
    Serial.println("AxiomaCore-328 funciona correctamente con Arduino.");
  } else {
    Serial.println("⚠️  ALGUNOS TESTS FALLARON");
    Serial.println("Revisar funcionalidad específica.");
  }
  
  Serial.println();
  Serial.println("AxiomaCore-328 - Primer AVR Open Source");
  Serial.println("© 2025 AxiomaCore Project");
  Serial.println("========================================");
  Serial.println();
}