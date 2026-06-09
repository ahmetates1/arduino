/*
 * ESP32 DevKit V1 — çalışırlık testi (smoke test)
 *
 * Başarı kriterleri:
 * - Kart üzerindeki mavi LED yaklaşık 1 saniyede bir yanıp sönmeli.
 * - Arduino IDE Seri Monitör (115200 baud) "ESP32 OK" mesajını görmeli.
 *
 * Kart: Araçlar → Kart → "ESP32 Dev Module" veya "DOIT ESP32 DEVKIT V1"
 */

#define SERIAL_BAUD 115200
#define BLINK_MS    500

// Bazı ESP32 kart seçenekleri LED_BUILTIN tanımlamaz; DevKit V1 tipik olarak GPIO 2.
#ifndef LED_BUILTIN
#define LED_BUILTIN 2
#endif

void setup() {
  Serial.begin(SERIAL_BAUD);
  delay(500);

  pinMode(LED_BUILTIN, OUTPUT);

  Serial.println();
  Serial.println(F("=== ESP32 DevKit smoke test ==="));
  Serial.print(F("LED pin (LED_BUILTIN): "));
  Serial.println(LED_BUILTIN);
}

void loop() {
  static unsigned long lastToggle = 0;
  static bool ledOn = false;

  unsigned long now = millis();
  if (now - lastToggle >= BLINK_MS) {
    lastToggle = now;
    ledOn = !ledOn;
    digitalWrite(LED_BUILTIN, ledOn ? HIGH : LOW);

    Serial.print(F("tick "));
    Serial.print(now / 1000UL);
    Serial.println(ledOn ? F(" LED ON") : F(" LED OFF"));
  }
}
