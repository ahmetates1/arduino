/*
 * ESP32-S3 N16R8 — Seri monitör / USB testi
 *
 * Arduino IDE -> Tools:
 *   Board: ESP32S3 Dev Module
 *   USB CDC On Boot: Enabled
 *   USB Mode: Hardware CDC and JTAG
 *   Flash 16MB, PSRAM OPI
 *
 * Kablo: USB-C -> karttaki USB portu (UART koprusu degilse tek port)
 * Seri monitör: 115200, sonra RESET
 *
 * Calisiyorsa: LED yanip soner + "*** S3 SERIAL OK ***" yazisi
 */

#if CONFIG_IDF_TARGET_ESP32S3
#include "USB.h"
#endif

#ifdef LED_BUILTIN
#define LED_PIN LED_BUILTIN
#else
#define LED_PIN 2
#endif

void setup() {
  pinMode(LED_PIN, OUTPUT);

#if CONFIG_IDF_TARGET_ESP32S3 && ARDUINO_USB_CDC_ON_BOOT
  USB.begin();
#endif

  Serial.begin(115200);
  delay(2500);

  Serial.println();
  Serial.println(F("*** S3 SERIAL OK ***"));
  Serial.print(F("Chip: "));
  Serial.println(ESP.getChipModel());
  Serial.print(F("ARDUINO_USB_CDC_ON_BOOT="));
#if ARDUINO_USB_CDC_ON_BOOT
  Serial.println(F("1 (dogru)"));
#else
  Serial.println(F("0 — Tools icinde Enabled yapip tekrar yukleyin!"));
#endif

  Serial0.begin(115200, SERIAL_8N1, 44, 43);
  Serial0.println(F("UART0 mirror: GPIO44=RX 43=TX (harici USB-UART ile de dinlenebilir)"));
}

void loop() {
  static uint32_t n = 0;

  Serial.print(F("[USB Serial] tick "));
  Serial.println(n);
  Serial.flush();

  Serial0.print(F("[UART0 43/44] tick "));
  Serial0.println(n);

  digitalWrite(LED_PIN, (n % 2) ? HIGH : LOW);
  n++;
  delay(1000);
}
