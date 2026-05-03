// Geban — E220-400T22D
//
// 1) Ebyte tablosundaki "Arduino Nano" sutunu = Arduino Nano 33 IoT (3.3V mantik, TX1/RX1).
//    Klasik Arduino Nano (ATmega328) bu sutunda DEGIL; o kart icin asagida GEBAN_NANO_33IOT=0.
//
// Nano 33 IoT + E220 (tablo):
//   M0 -> D4  veya GND     M1 -> D6  veya GND     AUX -> D2 (PullUP onerisi)
//   E220 TXD -> D0 (Serial1 RX / RX1)    E220 RXD -> D1 (Serial1 TX / TX1)  [capraz]
//   VCC / GND: modul etiketine gore, ortak GND
//
// 2) Klasik Nano (ATmega328): SoftwareSerial(4,5) — E220 TXD->D4, E220 RXD<-D5 (+5V icin RX tarafina voltaj bolucu

#define GEBAN_NANO_33IOT 1  // 1 = Nano 33 IoT (tablo), 0 = klasik Nano

#if GEBAN_NANO_33IOT && defined(__AVR__)
#error Bu tablo Arduino Nano 33 IoT icin. Klasik Nano kullaniyorsan ustte GEBAN_NANO_33IOT 0 yap.
#endif

#if !GEBAN_NANO_33IOT
#include <SoftwareSerial.h>
#endif

#if GEBAN_NANO_33IOT

// Tablo: M0=4, M1=6 (veya ikisini GND — GND kullaniyorsan asagidaki cikislari kaldir)
const int LORA_M0  = 4;
const int LORA_M1  = 6;
const int LORA_AUX = 2;
// M0/M1 D4/D6 uzerinden suruluyor; sensörler 7,8,9
const int LOW_PIN  = 7;
const int MID_PIN  = 8;
const int HIGH_PIN = 9;

#else

SoftwareSerial lora(4, 5);
const int LOW_PIN  = 6;
const int MID_PIN  = 7;
const int HIGH_PIN = 8;

#endif

const int NETWORK_ID = 77;
const int TANK_ID = 2; // 2. depo

const long BASE_DELAY_MS = 1000; // ms taban bekleme (sahada or. 15000)
const long JITTER_MAX_MS = 5000;

void setup() {
  Serial.begin(9600);
  delay(200);

#if GEBAN_NANO_33IOT
  pinMode(LORA_M0, OUTPUT);
  digitalWrite(LORA_M0, LOW);
  pinMode(LORA_M1, OUTPUT);
  digitalWrite(LORA_M1, LOW);
  pinMode(LORA_AUX, INPUT_PULLUP);
  // E220 TXD->0, RXD<-1
  Serial1.begin(9600);
#else
  lora.begin(9600);
#endif

  pinMode(LOW_PIN, INPUT_PULLUP);
  pinMode(MID_PIN, INPUT_PULLUP);
  pinMode(HIGH_PIN, INPUT_PULLUP);

  randomSeed(analogRead(A0));

  Serial.println(F("--- Depo 2 (Dummy Mode) Basladi ---"));
#if GEBAN_NANO_33IOT
  Serial.println(F("Nano 33 IoT: Serial1 D0/D1, M0=D4 M1=D6 AUX=D2; AUX'a 3V verme"));
#else
  Serial.println(F("Klasik Nano: SoftwareSerial D4/D5; M0 M1 GND; AUX'a 3V verme"));
#endif
}

void loop() {
  bool low  = random(0, 2);
  bool mid  = low ? random(0, 2) : 0;
  bool high = mid ? random(0, 2) : 0;

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

#if GEBAN_NANO_33IOT
  Serial1.println(packet);
#else
  lora.println(packet);
#endif

  Serial.print(F("Havaya Firlatildi -> "));
  Serial.println(packet);

  long jitter = random(0, JITTER_MAX_MS);
  long totalDelay = BASE_DELAY_MS + jitter;

  Serial.print(F("Bir sonraki paket "));
  Serial.print(totalDelay / 1000);
  Serial.println(F(" saniye sonra gonderilecek..."));
  Serial.println(F("---------------------------------------"));

  delay(totalDelay);
}
