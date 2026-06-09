/*
 * ESP32 DevKit V1 + EBYTE E220-400T — sadece dinleme (UART seffaf mod)
 *
 * Kablo (proje ile uyumlu):
 *   E220 VCC -> 3.3V, GND -> GND
 *   E220 TXD -> GPIO27, E220 RXD <- GPIO26
 *   M0, M1 -> GND (normal mod) VEYA asagidaki GPIO'lara baglayip yazilim LOW tutar.
 *
 * Yesil LED: kartta genelde yok; GPIO25'e LED + direnc (ornekle 330Ω) baglanir.
 *   GPIO25 ----[330Ω]---- LED (+) ---- LED (-) ---- GND
 */

HardwareSerial loraSerial(2);

#define LORA_RX     27
#define LORA_TX     26
#define LORA_BAUD   9600

// Donanimda M0/M1 GND ise bu pinleri kullanmayin — pinMode yapmayin veya ayni GPIO'lara baglamayin.
#define USE_SOFTWARE_MODE_PINS 0
#if USE_SOFTWARE_MODE_PINS
#define LORA_M0 32
#define LORA_M1 33
#endif

#define GREEN_LED   25

// UART paketi: son bayttan bu kadar ms sessizlik = paket bitti sayilir
#define PACKET_IDLE_MS 80

void setup() {
  Serial.begin(115200);
  delay(300);

  pinMode(GREEN_LED, OUTPUT);
  digitalWrite(GREEN_LED, LOW);

#if USE_SOFTWARE_MODE_PINS
  pinMode(LORA_M0, OUTPUT);
  pinMode(LORA_M1, OUTPUT);
  digitalWrite(LORA_M0, LOW);
  digitalWrite(LORA_M1, LOW);
  delay(50);
#endif

  loraSerial.begin(LORA_BAUD, SERIAL_8N1, LORA_RX, LORA_TX);
  while (loraSerial.available()) {
    (void)loraSerial.read();
  }

  Serial.println(F("=== E220 dinleyici (Serial2: RX=27 TX=26, 9600 8N1) ==="));
}

void loop() {
  if (!loraSerial.available()) {
    return;
  }

  digitalWrite(GREEN_LED, HIGH);

  Serial.print(F("[LoRa] "));
  unsigned long lastRx = millis();

  while (true) {
    while (loraSerial.available()) {
      Serial.write(static_cast<uint8_t>(loraSerial.read()));
      lastRx = millis();
    }

    if (millis() - lastRx >= PACKET_IDLE_MS) {
      break;
    }
    yield();
  }

  Serial.println();
  digitalWrite(GREEN_LED, LOW);
}
