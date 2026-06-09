/*
 * ESP32 DevKit V1 + EBYTE E220-400T — verici (UART seffaf mod)
 *
 * Kablo esp32_e220_listener ile AYNI:
 *   E220 TXD -> GPIO27, E220 RXD <- GPIO26, 9600 8N1
 *   M0, M1 -> GND (normal mod)
 *
 * Karsi tarafta: USB-serial + E220 ve scripts/e220_usb_listener.py
 */

HardwareSerial loraSerial(2);

#define LORA_RX           27
#define LORA_TX           26
#define LORA_BAUD         9600

#define USE_SOFTWARE_MODE_PINS 0
#if USE_SOFTWARE_MODE_PINS
#define LORA_M0 32
#define LORA_M1 33
#endif

#define GREEN_LED         25

#define SEND_INTERVAL_MS  4000

// tanks projesi formatina uygun (NETWORK_ID|id|low|mid|high)
// esp32/esp32_e220_listener: nano verici icin EXPECTED_NETWORK_ID=7, bu kart icin 77
#define NETWORK_ID        77
#define NODE_ID           1

uint32_t txSeq = 0;

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

  Serial.println(F("=== E220 verici (Serial2 RX=27 TX=26, 9600) ==="));
}

void loop() {
  static unsigned long lastTx = 0;

  if (millis() - lastTx < SEND_INTERVAL_MS) {
    return;
  }
  lastTx = millis();

  digitalWrite(GREEN_LED, HIGH);

  txSeq++;

  loraSerial.print(NETWORK_ID);
  loraSerial.print('|');
  loraSerial.print(NODE_ID);
  loraSerial.print('|');
  loraSerial.print(txSeq);
  loraSerial.print('|');
  loraSerial.print(millis() / 1000UL);
  loraSerial.print('|');
  loraSerial.println(0);

  loraSerial.flush();

  Serial.print(F("[LoRa TX] "));
  Serial.print(NETWORK_ID);
  Serial.print('|');
  Serial.print(NODE_ID);
  Serial.print('|');
  Serial.print(txSeq);
  Serial.print('|');
  Serial.print(millis() / 1000UL);
  Serial.println(F("|0"));
  delay(500);
  digitalWrite(GREEN_LED, LOW);
}
