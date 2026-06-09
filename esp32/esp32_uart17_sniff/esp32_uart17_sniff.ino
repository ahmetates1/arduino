/*
 * ESP32-S3 — LoRa TX hattini dinler (GPIO17)
 *
 * Sizin kablo (LoRa -> Board):
 *   LoRa TX -> GPIO17 (ESP RX)
 *   LoRa RX -> GPIO18 (ESP TX)
 *
 * Wire test: Nano D2 -> ESP32 GPIO17 + GND
 */

#if CONFIG_IDF_TARGET_ESP32S3
#include "USB.h"
#endif

HardwareSerial uart(2);

#define PIN_RX  17   // LoRa TX -> buraya bagli
#define PIN_TX  18   // LoRa RX <- buradan cikar

void setup() {
#if CONFIG_IDF_TARGET_ESP32S3 && ARDUINO_USB_CDC_ON_BOOT
  USB.begin();
#endif

  Serial.begin(115200);
  delay(2000);

  uart.begin(9600, SERIAL_8N1, PIN_RX, PIN_TX);

  Serial.println(F("=== LoRaTX->GPIO17 sniff ==="));
  Serial.println(F("LoRa TX->17, LoRa RX->18"));
  Serial.println(F("Wire: Nano D2 -> GPIO17"));
  Serial.println();
}

void loop() {
  while (uart.available()) {
    uint8_t b = uart.read();
    Serial.print(F("[RX] 0x"));
    if (b < 0x10) {
      Serial.print('0');
    }
    Serial.print(b, HEX);
    if (b >= 32 && b < 127) {
      Serial.print(F(" '"));
      Serial.write(b);
      Serial.print('\'');
    }
    Serial.println();
  }

  static unsigned long t;
  if (millis() - t > 2000) {
    t = millis();
    Serial.println(F("[alive] GPIO17..."));
  }
}
