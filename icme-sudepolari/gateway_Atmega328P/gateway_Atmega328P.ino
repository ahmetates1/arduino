#include <SoftwareSerial.h>
#include <Wire.h>
#include <Adafruit_GFX.h>
#include <Adafruit_SSD1306.h>

// E220-400T30D UART LoRa — SoftwareSerial
// LoRa TX -> D5, LoRa RX -> D4, VCC -> 3.7V, AUX -> bos
SoftwareSerial loraSerial(4, 5);

// OLED SSD1306 128x32 (SDA=A4, SCL=A5)
#define SCREEN_WIDTH  128
#define SCREEN_HEIGHT  32
Adafruit_SSD1306 display(SCREEN_WIDTH, SCREEN_HEIGHT, &Wire, -1);

const int NETWORK_ID = 77;
const int TANK_COUNT = 5;

const char* tankNames[TANK_COUNT] = {
  "YICME",
  "GEBAN",
  "TTOKI",
  "YTOKI",
  "AICME"
};

int tankLevels[TANK_COUNT] = {-1, -1, -1, -1, -1};
unsigned long tankLastSeen[TANK_COUNT] = {0, 0, 0, 0, 0};

unsigned long lastPageSwitch = 0;
const unsigned long PAGE_INTERVAL = 3000;
int currentPage = 0;

bool parseTankPacket(const String& raw, int& tankId, int& levelPct) {
  String packet = raw;
  packet.trim();

  int p1 = packet.indexOf('|');
  int p2 = packet.indexOf('|', p1 + 1);
  int p3 = packet.indexOf('|', p2 + 1);
  int p4 = packet.indexOf('|', p3 + 1);

  if (p1 < 0 || p2 < 0 || p3 < 0 || p4 < 0) return false;

  int net  = packet.substring(0, p1).toInt();
  int id   = packet.substring(p1 + 1, p2).toInt();
  int low  = packet.substring(p2 + 1, p3).toInt();
  int mid  = packet.substring(p3 + 1, p4).toInt();
  int high = packet.substring(p4 + 1).toInt();

  if (net != NETWORK_ID) return false;
  if (id < 1 || id > TANK_COUNT) return false;

  tankId = id;
  if (high) levelPct = 100;
  else if (mid) levelPct = 66;
  else if (low) levelPct = 33;
  else levelPct = 0;

  return true;
}

void updateDisplay() {
  display.clearDisplay();
  display.setTextColor(SSD1306_WHITE);

  int i = currentPage;

  // Satir 1: Tank adi (buyuk) + dakika (kucuk, sag)
  display.setTextSize(2);
  display.setCursor(0, 0);
  display.print(tankNames[i]);

  if (tankLevels[i] >= 0) {
    unsigned long dk = (millis() - tankLastSeen[i]) / 60000;
    if (dk > 999) dk = 999;
    display.setTextSize(2);
    int dx = (dk < 10) ? 104 : 80;
    display.setCursor(dx, 0);
    display.print(dk);
    display.setTextSize(1);
    display.print(F("dk"));
  }

  // Satir 2: Gauge bar (tam genislik)
  int barX = 0;
  int barY = 18;
  int barW = 128;
  int barH = 14;

  display.drawRect(barX, barY, barW, barH, SSD1306_WHITE);
  if (tankLevels[i] > 0) {
    int fillW = (long)(barW - 4) * tankLevels[i] / 100;
    display.fillRect(barX + 2, barY + 2, fillW, barH - 4, SSD1306_WHITE);
  }

  display.display();
}

void setup() {
  Serial.begin(9600);
  loraSerial.begin(9600);

  if (!display.begin(SSD1306_SWITCHCAPVCC, 0x3C)) {
    Serial.println(F("OLED bulunamadi!"));
    while (true);
  }

  display.clearDisplay();
  display.setTextSize(2);
  display.setTextColor(SSD1306_WHITE);
  display.setCursor(0, 0);
  display.print(F("Basladi"));
  display.setCursor(0, 16);
  display.print(F("Bekliyor.."));
  display.display();

  delay(200);
  while (loraSerial.available()) loraSerial.read();

  Serial.println(F("Gateway Atmega328P baslatildi"));
  Serial.println(F("LoRa RX=D4, TX=D5, VCC=3.7V"));
  Serial.println(F("Tank verisi bekleniyor...\n"));
  lastPageSwitch = millis();
}

void loop() {
  if (loraSerial.available()) {
    String incoming = loraSerial.readStringUntil('\n');
    incoming.trim();
    if (incoming.length() > 0 && incoming.indexOf('|') >= 0) {
      Serial.print(F("Gelen: "));
      Serial.println(incoming);

      int tankId, levelPct;
      if (parseTankPacket(incoming, tankId, levelPct)) {
        tankLevels[tankId - 1] = levelPct;
        tankLastSeen[tankId - 1] = millis();

        Serial.print(tankNames[tankId - 1]);
        Serial.print(F(" -> %"));
        Serial.println(levelPct);

        updateDisplay();
      }
    }
  }

  if (millis() - lastPageSwitch >= PAGE_INTERVAL) {
    lastPageSwitch = millis();
    currentPage = (currentPage + 1) % TANK_COUNT;

    updateDisplay();
  }
}
