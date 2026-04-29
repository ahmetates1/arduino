/*
 * Tank vericisi — ESP32 + EBYTE E220 (UART seffaf), gateway ile ayni kablo.
 *
 * ASR6601CB / Ra-08 modulu icin BU DOSYA UYGUN DEGIL (M0/M1 yok, protokol farkli).
 *
 * KABLO (yalnizca E220): gateway_ESP-WROOM-32.ino ust yorumu ile ayni.
 * UART 9600 8N1, seffaf mod (M0=LOW, M1=LOW).
 */

HardwareSerial loraSerial(2);

#define LORA_RX  27
#define LORA_TX  26
#define LORA_M0  32
#define LORA_M1  33
#define LORA_AUX  4

// Seviye girisleri (ESP32'de 6-11 cogu kartta flash; Nano D6/7/8 yerine)
const int LOW_PIN  = 18;
const int MID_PIN  = 19;
const int HIGH_PIN = 21;

const int NETWORK_ID = 77;
const int TANK_ID = 4;

const long BASE_DELAY_MS = 15000;
const long JITTER_MAX_MS = 5000;

void setup() {
  Serial.begin(115200);
  delay(200);

  pinMode(LORA_M0, OUTPUT);
  pinMode(LORA_M1, OUTPUT);
  pinMode(LORA_AUX, INPUT);
  digitalWrite(LORA_M0, LOW);
  digitalWrite(LORA_M1, LOW);
  delay(200);

  loraSerial.begin(9600, SERIAL_8N1, LORA_RX, LORA_TX);
  while (loraSerial.available()) loraSerial.read();

  pinMode(LOW_PIN, INPUT_PULLUP);
  pinMode(MID_PIN, INPUT_PULLUP);
  pinMode(HIGH_PIN, INPUT_PULLUP);

  randomSeed(esp_random());

  Serial.println("Tank ESP32 + E220 hazir (Serial2, seffaf mod)");
}

void loop() {
  bool low  = digitalRead(LOW_PIN)  == LOW;
  bool mid  = digitalRead(MID_PIN)  == LOW;
  bool high = digitalRead(HIGH_PIN) == LOW;

  String packet;
  packet.reserve(32);
  packet += NETWORK_ID;
  packet += "|";
  packet += TANK_ID;
  packet += "|";
  packet += low;
  packet += "|";
  packet += mid;
  packet += "|";
  packet += high;

  loraSerial.println(packet);

  Serial.print("Gonderildi -> ");
  Serial.println(packet);

  long jitter = random(0, JITTER_MAX_MS);
  long totalDelay = BASE_DELAY_MS + jitter;

  Serial.print("Sonraki gonderim: ");
  Serial.print(totalDelay / 1000);
  Serial.println(" sn");

  delay(totalDelay);
}
