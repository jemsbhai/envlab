// nano_rc522_node.ino
// Arduino Nano 33 IoT + RC522 RFID reader: card-tap events and onboard IMU telemetry as JSON lines over USB serial.
//
// Wiring (RC522 -> Nano 33 IoT). Both sides are 3.3 V logic; never feed the RC522 5 V.
//   3.3V -> 3.3V | GND -> GND | SDA(SS) -> D10 | SCK -> D13 | MOSI -> D11 | MISO -> D12 | RST -> D9 | IRQ -> not connected
//
// Board:     Arduino Nano 33 IoT   (core "Arduino SAMD Boards", fqbn arduino:samd:nano_33_iot)
// Libraries: "MFRC522" by GithubCommunity, "Arduino_LSM6DS3" by Arduino
//
// Output, one JSON object per line at 115200 baud:
//   {"type":"hello", ...}   at boot and in reply to {"cmd":"ping"}; rc522_version 0x91/0x92 means the reader answers,
//                           0x0 or 0xFF means it does not (wiring)
//   {"type":"card", "uid":"04A1B2C3", "sak":8, "picc":"MIFARE 1KB", ...}   on each tap (same card debounced 2 s)
//   {"type":"imu", ...}     once per second: accelerometer (g), gyroscope (deg/s), deviation from boot baseline
//   {"type":"tamper", ...}  once, when the node moves more than MOVE_THRESHOLD_G from its baseline
// Commands in: {"cmd":"ping"}  {"cmd":"rebase"} (re-take the IMU baseline after repositioning the node)
//
// Note: on the Nano 33 IoT, D13 is both SCK and the orange LED, so this sketch does not drive the LED.

#include <SPI.h>
#include <MFRC522.h>
#include <Arduino_LSM6DS3.h>

#define NODE_ID "nano33iot-1"

const uint8_t PIN_SS = 10;
const uint8_t PIN_RST = 9;
const unsigned long IMU_PERIOD_MS = 1000;
const unsigned long CARD_DEBOUNCE_MS = 2000;
const float MOVE_THRESHOLD_G = 0.12;

MFRC522 rfid(PIN_SS, PIN_RST);

bool imuOk = false;
byte rcVersion = 0;
unsigned long lastImuMs = 0;
unsigned long lastCardMs = 0;
String lastUid = "";
float ax0 = 0, ay0 = 0, az0 = 0;
bool baselineSet = false;
bool movedState = false;
char cmdBuf[64];
uint8_t cmdLen = 0;

void printHello() {
  Serial.print("{\"type\":\"hello\",\"node\":\"" NODE_ID "\",\"rc522_version\":\"0x");
  Serial.print(rcVersion, HEX);
  Serial.print("\",\"imu\":");
  Serial.print(imuOk ? "true" : "false");
  Serial.print(",\"uptime_ms\":");
  Serial.print(millis());
  Serial.println("}");
}

String uidToHex(const MFRC522::Uid &uid) {
  String s;
  for (byte i = 0; i < uid.size; i++) {
    if (uid.uidByte[i] < 0x10) s += "0";
    s += String(uid.uidByte[i], HEX);
  }
  s.toUpperCase();
  return s;
}

void setup() {
  Serial.begin(115200);
  unsigned long t0 = millis();
  while (!Serial && millis() - t0 < 3000) {}   // wait briefly for a host, but run without one

  SPI.begin();
  rfid.PCD_Init();
  delay(50);
  rcVersion = rfid.PCD_ReadRegister(MFRC522::VersionReg);

  imuOk = IMU.begin();
  printHello();
}

void pollCard() {
  if (!rfid.PICC_IsNewCardPresent()) return;
  if (!rfid.PICC_ReadCardSerial()) return;

  String uid = uidToHex(rfid.uid);
  unsigned long now = millis();
  if (uid == lastUid && now - lastCardMs < CARD_DEBOUNCE_MS) {
    rfid.PICC_HaltA();
    return;
  }
  lastUid = uid;
  lastCardMs = now;

  MFRC522::PICC_Type piccType = rfid.PICC_GetType(rfid.uid.sak);
  Serial.print("{\"type\":\"card\",\"node\":\"" NODE_ID "\",\"t\":");
  Serial.print(now);
  Serial.print(",\"uid\":\"");
  Serial.print(uid);
  Serial.print("\",\"sak\":");
  Serial.print(rfid.uid.sak);
  Serial.print(",\"picc\":\"");
  Serial.print(rfid.PICC_GetTypeName(piccType));
  Serial.println("\"}");

  rfid.PICC_HaltA();
  rfid.PCD_StopCrypto1();
}

void pollImu() {
  unsigned long now = millis();
  if (!imuOk || now - lastImuMs < IMU_PERIOD_MS) return;
  lastImuMs = now;

  float ax, ay, az, gx = 0, gy = 0, gz = 0;
  if (!IMU.accelerationAvailable() || !IMU.readAcceleration(ax, ay, az)) return;
  if (IMU.gyroscopeAvailable()) IMU.readGyroscope(gx, gy, gz);

  if (!baselineSet) {
    ax0 = ax; ay0 = ay; az0 = az;
    baselineSet = true;
  }
  float dev = sqrt(sq(ax - ax0) + sq(ay - ay0) + sq(az - az0));
  bool moved = dev > MOVE_THRESHOLD_G;
  if (moved && !movedState) {
    Serial.print("{\"type\":\"tamper\",\"node\":\"" NODE_ID "\",\"t\":");
    Serial.print(now);
    Serial.print(",\"dev_g\":");
    Serial.print(dev, 3);
    Serial.println("}");
  }
  movedState = moved;

  Serial.print("{\"type\":\"imu\",\"node\":\"" NODE_ID "\",\"t\":");
  Serial.print(now);
  Serial.print(",\"ax\":"); Serial.print(ax, 3);
  Serial.print(",\"ay\":"); Serial.print(ay, 3);
  Serial.print(",\"az\":"); Serial.print(az, 3);
  Serial.print(",\"gx\":"); Serial.print(gx, 2);
  Serial.print(",\"gy\":"); Serial.print(gy, 2);
  Serial.print(",\"gz\":"); Serial.print(gz, 2);
  Serial.print(",\"dev_g\":"); Serial.print(dev, 3);
  Serial.print(",\"moved\":"); Serial.print(moved ? "true" : "false");
  Serial.println("}");
}

void handleCommand(const char *cmd) {
  if (strstr(cmd, "ping")) {
    printHello();
  } else if (strstr(cmd, "rebase")) {
    baselineSet = false;
    movedState = false;
    Serial.println("{\"type\":\"ack\",\"cmd\":\"rebase\"}");
  } else {
    Serial.println("{\"type\":\"error\",\"msg\":\"unknown command\"}");
  }
}

void pollCommands() {
  while (Serial.available()) {
    char c = Serial.read();
    if (c == '\n' || c == '\r') {
      cmdBuf[cmdLen] = 0;
      if (cmdLen > 0) handleCommand(cmdBuf);
      cmdLen = 0;
    } else if (cmdLen < sizeof(cmdBuf) - 1) {
      cmdBuf[cmdLen++] = c;
    }
  }
}

void loop() {
  pollCard();
  pollImu();
  pollCommands();
}
