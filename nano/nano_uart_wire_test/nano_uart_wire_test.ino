/*
 * Wire test — LoRa TX hattindan (D2) veri gonderir
 *
 * LoRa -> Board: LoRa TX -> D2, LoRa RX -> D3
 * Baglanti: Nano D2 -> ESP32 GPIO17 + GND
 */

#include <SoftwareSerial.h>

// TX=D2 (LoRa TX hattina yaz)
SoftwareSerial wire(3, 2);

void setup() {
  Serial.begin(9600);
  wire.begin(9600);
  delay(300);
  Serial.println(F("=== Wire test: D2 (LoRa TX hatti) ==="));
}

void loop() {
  wire.println(F("TEST"));
  Serial.println(F("[TX] TEST -> D2"));
  delay(1000);
}
