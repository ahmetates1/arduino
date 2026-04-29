#include <SoftwareSerial.h>

// LoRa
// RX: D4
// TX: D5
SoftwareSerial lora(4,5);

// sensör pinleri
const int LOW_PIN  = 6;
const int MID_PIN  = 7;
const int HIGH_PIN = 8;

const int NETWORK_ID = 77;
const int TANK_ID = 5;

const long BASE_DELAY_MS = 15000;
const long JITTER_MAX_MS = 5000;

void setup() {

  Serial.begin(9600);
  lora.begin(9600);

  pinMode(LOW_PIN, INPUT_PULLUP);
  pinMode(MID_PIN, INPUT_PULLUP);
  pinMode(HIGH_PIN, INPUT_PULLUP);

  randomSeed(analogRead(A0));

  Serial.println("Depo 4 node basladi");
}

void loop() {

  bool low  = digitalRead(LOW_PIN)  == LOW;
  bool mid  = digitalRead(MID_PIN)  == LOW;
  bool high = digitalRead(HIGH_PIN) == LOW;

  String packet = "";
  packet += NETWORK_ID;
  packet += "|";
  packet += TANK_ID;
  packet += "|";
  packet += low;
  packet += "|";
  packet += mid;
  packet += "|";
  packet += high;

  lora.println(packet);

  Serial.print("Gonderildi -> ");
  Serial.println(packet);

  long jitter = random(0, JITTER_MAX_MS);
  long totalDelay = BASE_DELAY_MS + jitter;

  Serial.print("Sonraki gonderim: ");
  Serial.print(totalDelay / 1000);
  Serial.println(" sn");

  delay(totalDelay);
}