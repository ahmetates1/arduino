#include <WiFi.h>
#include <HTTPClient.h>

// WiFi
const char* ssid = "İçme muhtarlık";
const char* password = "brtnhn23";

// Supabase
const char* supabaseUrl = "https://ngdozrhycaeiabubrywf.supabase.co/rest/v1/sensor_data";
const char* apiKey = "sb_publishable_DNrEyZFNk13VFNlfE2UhZg_FnVwiHcJ";

const int NETWORK_ID = 77;

const char* tankNames[5] = {
  "YICME",
  "GEBAN",
  "TEPETOKI",
  "TOKI",
  "AICME"
};

// E220-400T30D UART LoRa — Serial2
HardwareSerial loraSerial(2);
#define LORA_RX 27
#define LORA_TX 26

// E220 mod pinleri
#define LORA_M0  32
#define LORA_M1  33
#define LORA_AUX  4

bool loraReady = false;
bool wifiConnected = false;
bool wifiMsgShown = false;

// Gonderilemeyen verileri kuyrukta tut (WiFi yokken)
#define QUEUE_SIZE 20
struct PendingData {
  char name[12];
  int value;
  bool used;
};
PendingData sendQueue[QUEUE_SIZE];

void queueForSupabase(const char* name, int value) {
  for (int i = 0; i < QUEUE_SIZE; i++) {
    if (!sendQueue[i].used) {
      strncpy(sendQueue[i].name, name, 11);
      sendQueue[i].name[11] = '\0';
      sendQueue[i].value = value;
      sendQueue[i].used = true;
      Serial.print("[KUYRUK] ");
      Serial.print(name);
      Serial.print(" %");
      Serial.println(value);
      return;
    }
  }
  Serial.println("[KUYRUK] Dolu! Veri kayboldu.");
}

void sendToSupabase(const char* name, int value) {
  HTTPClient http;
  http.begin(supabaseUrl);
  http.addHeader("Content-Type", "application/json");
  http.addHeader("Accept", "application/json");
  http.addHeader("Prefer", "return=representation");
  http.addHeader("apikey", apiKey);
  http.addHeader("Authorization", String("Bearer ") + apiKey);

  String body = "{\"name\":\"" + String(name) + "\",\"value\":\"" + String(value) + "\"}";

  int httpResponseCode = http.POST(body);
  String responseBody = http.getString();

  Serial.print("HTTP ");
  Serial.print(httpResponseCode);
  Serial.print(" -> ");
  Serial.println(responseBody);

  http.end();
}

void flushQueue() {
  for (int i = 0; i < QUEUE_SIZE; i++) {
    if (sendQueue[i].used) {
      Serial.print("[KUYRUK GONDER] ");
      Serial.println(sendQueue[i].name);
      sendToSupabase(sendQueue[i].name, sendQueue[i].value);
      sendQueue[i].used = false;
    }
  }
}

// --- E220 Konfigurasyon ---

bool tryReadE220(uint8_t* resp, int& count) {
  while (loraSerial.available()) loraSerial.read();

  uint8_t readCmd[] = {0xC1, 0x00, 0x08};
  loraSerial.write(readCmd, 3);
  delay(500);

  count = 0;
  while (loraSerial.available() && count < 11) {
    resp[count++] = loraSerial.read();
  }
  return (count >= 11 && resp[0] == 0xC1);
}

void printE220Config(uint8_t* resp, int count) {
  Serial.print("Ham veri: ");
  for (int i = 0; i < count; i++) {
    if (resp[i] < 0x10) Serial.print("0");
    Serial.print(resp[i], HEX);
    Serial.print(" ");
  }
  Serial.println();

  uint16_t addr = (resp[3] << 8) | resp[4];
  Serial.print("Adres: 0x");
  Serial.println(addr, HEX);

  Serial.print("Net ID: ");
  Serial.println(resp[5]);

  uint8_t baudIdx = (resp[6] >> 3) & 0x07;
  uint8_t airRate = resp[6] & 0x07;

  const long baudRates[] = {1200, 2400, 4800, 9600, 19200, 38400, 57600, 115200};
  const char* airRates[] = {"0.3k", "1.2k", "2.4k", "4.8k", "9.6k", "19.2k", "38.4k", "62.5k"};

  Serial.print("UART Baud Rate: ");
  Serial.println(baudRates[baudIdx]);

  Serial.print("Hava Hizi (Air Rate): ");
  Serial.println(airRates[airRate]);

  uint8_t txPower = resp[7] & 0x03;
  const char* powerLevels[] = {"30dBm (1W)", "27dBm", "24dBm", "21dBm"};
  Serial.print("TX Gucu: ");
  Serial.println(powerLevels[txPower]);

  Serial.print("Kanal (CH): ");
  Serial.print(resp[8]);
  Serial.print(" -> Frekans: ");
  Serial.print(410.125 + resp[8] * 1.0);
  Serial.println(" MHz");

  Serial.print("RSSI Gurultu: ");
  Serial.println((resp[9] & 0x20) ? "Aktif" : "Pasif");

  uint8_t subPkt = (resp[9] >> 6) & 0x03;
  const int subSizes[] = {200, 128, 64, 32};
  Serial.print("Sub Paket: ");
  Serial.print(subSizes[subPkt]);
  Serial.println(" byte");
}

void writeE220DefaultConfig() {
  Serial.println("Varsayilan konfigurasyon yaziliyor...");

  uint8_t writeCmd[] = {
    0xC0, 0x00, 0x08,
    0x00, 0x00,  // ADDH=0, ADDL=0
    0x00,        // Net ID = 0
    0x62,        // UART: 8N1, Baud: 9600, Air Rate: 2.4k
    0x00,        // Sub paket: 200 byte, RSSI gurultu: pasif, TX gucu: 30dBm
    0x12,        // Kanal 18 -> 428.125 MHz
    0x03,        // RSSI byte: pasif, iletim modu: seffaf, WOR: 500ms
    0x00         // WOR periodu, anahtar: varsayilan
  };

  loraSerial.write(writeCmd, sizeof(writeCmd));
  delay(500);

  int respCount = 0;
  while (loraSerial.available()) {
    uint8_t b = loraSerial.read();
    if (respCount == 0) {
      Serial.print("Yazma cevabi: 0x");
      Serial.println(b, HEX);
    }
    respCount++;
  }

  if (respCount == 0) {
    Serial.println("Yazma cevabi alinamadi!");
  } else {
    Serial.print("Toplam cevap byte: ");
    Serial.println(respCount);
  }
}

void setupE220() {
  digitalWrite(LORA_M0, LOW);
  digitalWrite(LORA_M1, HIGH);
  delay(200);

  loraSerial.begin(9600, SERIAL_8N1, LORA_RX, LORA_TX);
  delay(100);

  Serial.println("\n=== E220 Konfigurasyon ===");

  uint8_t resp[11];
  int count = 0;

  if (tryReadE220(resp, count)) {
    Serial.println("[OKUMA BASARILI]");
    printE220Config(resp, count);
  } else {
    Serial.print("Okuma basarisiz (alinan byte: ");
    Serial.print(count);
    Serial.println("). Konfigurasyon yazilacak...");

    writeE220DefaultConfig();
    delay(200);

    if (tryReadE220(resp, count)) {
      Serial.println("[YAZMA SONRASI OKUMA BASARILI]");
      printE220Config(resp, count);
    } else {
      Serial.println("HATA: Yazma sonrasi da okunamadi!");
      Serial.println("Kontrol edin: M0->P32, M1->P33, TX->26, RX->27");
    }
  }

  Serial.println("=========================\n");
}

// --- Parse ---

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
  if (id < 1 || id > 5) return false;

  tankId = id;
  if (high) levelPct = 100;
  else if (mid) levelPct = 66;
  else if (low) levelPct = 33;
  else levelPct = 0;

  return true;
}

// --- Setup & Loop ---

void setup() {
  Serial.begin(115200);

  // WiFi'yi baslat ama bekleme (arka planda baglansin)
  WiFi.begin(ssid, password);
  Serial.println("WiFi arka planda baglaniyor...");

  // Kuyrugu sifirla
  for (int i = 0; i < QUEUE_SIZE; i++) sendQueue[i].used = false;

  pinMode(LORA_M0, OUTPUT);
  pinMode(LORA_M1, OUTPUT);
  pinMode(LORA_AUX, INPUT);

  setupE220();

  // Normal moda gec
  digitalWrite(LORA_M0, LOW);
  digitalWrite(LORA_M1, LOW);
  delay(200);

  while (loraSerial.available()) loraSerial.read();

  loraReady = true;
  Serial.println("LoRa E220 Normal mod aktif (RX=27 TX=26)");
  Serial.println("Veri bekleniyor...\n");
}

void loop() {
  // WiFi durumunu kontrol et
  if (WiFi.status() == WL_CONNECTED) {
    if (!wifiConnected) {
      wifiConnected = true;
      Serial.println("\n[WIFI] Baglandi!");
      flushQueue();
    }
  } else {
    if (wifiConnected) {
      wifiConnected = false;
      Serial.println("\n[WIFI] Baglanti kesildi, yeniden deneniyor...");
    }
  }

  if (!loraReady) {
    delay(50);
    return;
  }

  // LoRa'dan veri oku
  if (loraSerial.available()) {
    String incoming = loraSerial.readStringUntil('\n');
    incoming.trim();
    if (incoming.length() > 0 && incoming.indexOf('|') >= 0) {
      Serial.print("Gelen: ");
      Serial.println(incoming);

      int tankId, levelPct;
      if (parseTankPacket(incoming, tankId, levelPct)) {
        Serial.print(tankNames[tankId - 1]);
        Serial.print(" -> %");
        Serial.println(levelPct);

        if (wifiConnected) {
          sendToSupabase(tankNames[tankId - 1], levelPct);
        } else {
          queueForSupabase(tankNames[tankId - 1], levelPct);
        }
      }
    }
  }
}
