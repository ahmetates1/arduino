/*
 * Arduino Nano v3.0 (ATmega328) + EBYTE E220-400T30D — verici
 * Eslesen alici: esp32/esp32_e220_listener (NETWORK_ID=7)
 *
 * Sizin kablo (LoRa -> Board, M0/M1 -> GND):
 *   LoRa RX  -> D4  (Nano TX — modüle yazar)
 *   LoRa TX  -> D2  (Nano RX — modülden gelen veri, dinleme)
 *   LoRa VCC -> 3.3V (23v = 3.3V guc, TX veri hatti degil)
 *   GND ortak; 5V Nano'da LoRa RX hattina voltaj bolucu
 *   AUX -> bos birakilabilir
 *
 * TX LED: kart uzerindeki L (D13). Harici LED: TX_LED_PIN degistirin.
 *
 * Paket formati (gateway / tanks ile uyumlu):
 *   NETWORK_ID|NODE_ID|low|mid|high
 *
 * Ornek: 7|1|3|42|0  (low=seq, mid=uptime sn)
 *
 * Role (ESP32): seri monitorden  on  /  off  /  toggle
 *   -> 7|2|0|0|1  ac   /  7|2|0|0|0  kapa
 */

#include <SoftwareSerial.h>

// SoftwareSerial(RX, TX) = (D2, D4)  LoRa TX->D2, LoRa RX->D4
SoftwareSerial loraSerial(4, 3);

const int NETWORK_ID = 7;
const int NODE_ID = 1;       // otomatik telemetri
const int RELAY_NODE_ID = 2; // ESP32 role komutu

uint32_t txSeq = 0;

const unsigned long SEND_INTERVAL_MS = 9000;
const unsigned long LORA_BAUD = 9600;
const unsigned long TX_LED_MS = 80;  // gonderimde kisa yanip sonme

#ifndef TX_LED_PIN
#define TX_LED_PIN LED_BUILTIN  // Nano: D13
#endif

unsigned long lastTx = 0;
unsigned long txLedOffMs = 0;
bool txLedOn = false;

void blinkTxLed() {
  digitalWrite(TX_LED_PIN, HIGH);
  txLedOn = true;
  txLedOffMs = millis() + TX_LED_MS;
}

void updateTxLed() {
  if (txLedOn && millis() >= txLedOffMs) {
    digitalWrite(TX_LED_PIN, LOW);
    txLedOn = false;
  }
}

void sendPacket() {
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

  blinkTxLed();
}

void setup() {
  pinMode(TX_LED_PIN, OUTPUT);
  digitalWrite(TX_LED_PIN, LOW);

  Serial.begin(9600);
  loraSerial.begin(LORA_BAUD);

  delay(200);
  while (loraSerial.available()) {
    loraSerial.read();
  }

  Serial.println(F("=== Nano v3.0 + E220-400T30D verici ==="));
  Serial.println(F("LoRa: LoRaTX->D2 LoRaRX->D4 (SW RX=2 TX=4), 9600"));
  Serial.print(F("NETWORK_ID="));
  Serial.print(NETWORK_ID);
  Serial.print(F(", NODE_ID="));
  Serial.println(NODE_ID);
  Serial.print(F("Gonderim araligi: "));
  Serial.print(SEND_INTERVAL_MS / 1000);
  Serial.println(F(" sn"));
  Serial.println(F("Manuel: satir + Enter (7|1|9|60|0)"));
  Serial.println(F("Role: on / off / toggle"));
  Serial.println(F("Seri monitör: 9600, satir sonu = Newline"));
  Serial.println(F("TX LED: gonderimde kisa yanar (D13)"));
}

void sendRelayCommand(int highVal) {
  loraSerial.print(NETWORK_ID);
  loraSerial.print('|');
  loraSerial.print(RELAY_NODE_ID);
  loraSerial.print(F("|0|0|"));
  loraSerial.println(highVal);
  loraSerial.flush();

  Serial.print(F("[LoRa TX role] 7|"));
  Serial.print(RELAY_NODE_ID);
  Serial.print(F("|0|0|"));
  Serial.println(highVal);

  blinkTxLed();
}

// USB seri monitörden gelen satiri LoRa modüle iletir
void handleSerialCommand() {
  if (!Serial.available()) {
    return;
  }

  String line = Serial.readStringUntil('\n');
  line.trim();
  if (line.length() == 0) {
    return;
  }

  if (line.equalsIgnoreCase(F("on"))) {
    sendRelayCommand(1);
    return;
  }
  if (line.equalsIgnoreCase(F("off"))) {
    sendRelayCommand(0);
    return;
  }
  if (line.equalsIgnoreCase(F("toggle"))) {
    sendRelayCommand(2);
    return;
  }

  loraSerial.println(line);
  loraSerial.flush();

  Serial.print(F("[LoRa TX manuel] "));
  Serial.println(line);

  blinkTxLed();
}

void loop() {
  updateTxLed();
  handleSerialCommand();

  unsigned long now = millis();
  if (now - lastTx < SEND_INTERVAL_MS) {
    return;
  }
  lastTx = now;

  sendPacket();
}
