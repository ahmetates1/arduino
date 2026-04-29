#include <SoftwareSerial.h>

// LoRa Pinleri — SoftwareSerial(rxPin, txPin): Nano RX=D4 <- E220 TXD, Nano TX=D5 -> E220 RXD
// gateway_Atmega328P ve tanks/tanks.ino ile ayni: (4, 5)
SoftwareSerial lora(4, 5);

// Sensör pinleri (Fiziksel sensör yoksa rastgele doluluk üretecek)
const int LOW_PIN  = 6;
const int MID_PIN  = 7;
const int HIGH_PIN = 8;

const int NETWORK_ID = 77;
const int TANK_ID = 2; // Bu cihaz 2. depo

const long BASE_DELAY_MS = 1000; // 15 saniye bekleme
const long JITTER_MAX_MS = 5000;  // 5 saniyeye kadar rastgele kayma

void setup() {
  Serial.begin(9600);
  lora.begin(9600);

  pinMode(LOW_PIN, INPUT_PULLUP);
  pinMode(MID_PIN, INPUT_PULLUP);
  pinMode(HIGH_PIN, INPUT_PULLUP);

  randomSeed(analogRead(A0));

  Serial.println("--- Depo 2 (Dummy Mode) Basladi ---");
  Serial.println("M0 ve M1 pinlerinin GND'de oldugundan emin olun!");
}

void loop() {
  // Rastgele sensör verisi üret (Dummy Data)
  // 0: Boş, 1: Dolu
  bool low  = random(0, 2); 
  bool mid  = low ? random(0, 2) : 0;  // Alt katman boşsa üstü de boş yap
  bool high = mid ? random(0, 2) : 0;  // Orta boşsa üstü de boş yap

  // Paket oluşturma (Format: 77|5|1|0|0)
  String packet = "";
  packet += NETWORK_ID;
  packet += "|";
  packet += TANK_ID;
  packet += "|";
  packet += (low ? "1" : "0");
  packet += "|";
  packet += (mid ? "1" : "0");
  packet += "|";
  packet += (high ? "1" : "0");

  // LoRa üzerinden gönder
  lora.println(packet);

  // Seri Monitör Bilgilendirme
  Serial.print("Havaya Firlatildi -> ");
  Serial.println(packet);

  // Bekleme süresi hesapla
  long jitter = random(0, JITTER_MAX_MS);
  long totalDelay = BASE_DELAY_MS + jitter;

  Serial.print("Bir sonraki paket ");
  Serial.print(totalDelay / 1000);
  Serial.println(" saniye sonra gonderilecek...");
  Serial.println("---------------------------------------");

  delay(totalDelay);
}