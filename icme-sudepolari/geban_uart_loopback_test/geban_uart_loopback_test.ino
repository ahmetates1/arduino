/*
 * Nano + SoftwareSerial kablo testi (LoRa RF YOK — sadece D4/D5 dogrulama)
 *
 * 1) Yukle, Seri Monitor 9600 ac.
 * 2) GUC KAPALI iken Nano D4 ile D5'i bir jumper ile KISA DEVRE yap.
 * 3) Gucu ac. Her 2 saniyede "TEST\n" gonderilir; okunan byte'lar Seri Monitor'e yazilir.
 *
 * Beklenen: SoftwareSerial(rx=4, tx=5) dogruysa satirda "ECHO: TEST" benzeri gorursun.
 * Hicbir sey yoksa pin numarasi veya jumper yanlis.
 *
 * Test bitince jumper'i kaldir — yoksa gercek LoRa baglayinca kisa devre olur.
 */
#include <SoftwareSerial.h>

SoftwareSerial testPort(4, 5);

void setup() {
  Serial.begin(9600);
  testPort.begin(9600);
  delay(300);
  Serial.println(F("=== UART loopback: D4<->D5 jumper, SoftwareSerial(4,5) ==="));
}

void loop() {
  testPort.println(F("TEST"));
  delay(50);
  if (testPort.available()) {
    Serial.print(F("ECHO: "));
    while (testPort.available()) {
      Serial.write(testPort.read());
    }
  } else {
    Serial.println(F("ECHO yok (jumper yok / (4,5) yanlis / kablo kopuk)"));
  }
  delay(2000);
}
