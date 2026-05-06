# ESP32 Setup Instructions

This guide explains how to use the ESP32 firmware with SmartPowerSwitch.

## What the firmware does

- Connects the ESP32 to WiFi
- Reads PZEM-004T values
- Controls the SSR output
- Reads relay state from Firebase
- Sends telemetry to Firebase
- Uses a device ID only, no per-device key

## Required parts

- ESP32 board
- PZEM-004T module
- SSR module
- Jumper wires
- Common GND between ESP32, PZEM, and SSR

## Required Arduino libraries

Install these in Arduino IDE:

- ArduinoJson by Benoit Blanchon
- PZEM004Tv30 by Mandulaj

Use Library Manager: Sketch -> Include Library -> Manage Libraries, then search for each package name above.

## Wiring

Default pins used in the sketch:

- SSR IN -> GPIO 26
- PZEM TX -> ESP32 RX2 (GPIO 16)
- PZEM RX -> ESP32 TX2 (GPIO 17)
- GND -> Common ground

## Important settings in the sketch

Open [SmartPowerSwitch_ESP32.ino](SmartPowerSwitch_ESP32.ino) and edit these values:

- `WIFI_SSID`
- `WIFI_PASSWORD`
- `DEVICE_ID`
- `SSR_PIN` if needed
- `PZEM_RX_PIN` and `PZEM_TX_PIN` if you use different pins
- `PZEM_MODBUS_ADDR` if your module address is not `0xF8`
- `SSR_ACTIVE_HIGH` depending on your SSR board

The Firebase database URL is already set for this project.

This sketch uses Modbus-RTU over UART through the PZEM004Tv30 library.
Factory default address is `0xF8` for a single module.
Custom per-device addresses are `0x01` to `0xF7`.

## PZEM Modbus register addresses (PZEM-004T-100A-D-P V1.0)

Read input registers with function code `0x04` starting at `0x0000` for `0x000A` registers:

- `0x0000` Voltage (`0.1 V` units)
- `0x0001` Current low word
- `0x0002` Current high word (`0x0002:0x0001` as 32-bit, `0.001 A` units)
- `0x0003` Power low word
- `0x0004` Power high word (`0x0004:0x0003` as 32-bit, `0.1 W` units)
- `0x0005` Energy low word
- `0x0006` Energy high word (`0x0006:0x0005` as 32-bit, `1 Wh` units)
- `0x0007` Frequency (`0.1 Hz` units)
- `0x0008` Power factor (`0.01` units)
- `0x0009` Alarm status

Other key registers/commands:

- Holding register `0x0001`: Alarm threshold (read `0x03`, write `0x06`)
- Holding register `0x0002`: Slave address (read `0x03`, write `0x06`)
- Command `0x42`: Reset energy counter

## Device ID setup in the app

Before flashing the ESP32:

1. Open the SmartPowerSwitch app
2. Go to Settings
3. Open IoT Device Inventory
4. Enter the same `DEVICE_ID` used in the ESP32 sketch
5. Register it
6. Add the device to a room/floor in the app if needed

The ESP32 will use that ID to read and write under:

- `/devices/<DEVICE_ID>`

## How the firmware talks to Firebase

The ESP32:

- Reads relay state from `/devices/<DEVICE_ID>/relay`
- Writes readings to `/devices/<DEVICE_ID>`
- Uses `status`, `relay`, `voltage`, `current`, `power`, `kwh`, `powerFactor`, and `last_seen`

## Flash steps

1. Open the sketch in Arduino IDE
2. Select board: `ESP32 Dev Module`
3. Select the correct COM port
4. Install the required libraries
5. Set your WiFi name, password, and device ID
6. Upload the sketch
7. Open Serial Monitor at `115200`
8. Check that WiFi connects and PZEM values appear

## Normal startup behavior

- Relay starts OFF for safety
- ESP32 connects to WiFi
- ESP32 syncs time from NTP
- ESP32 polls Firebase every second for relay state
- ESP32 pushes telemetry every 3 seconds

## Example Firebase device data

```json
{
  "building": "IC",
  "floor": "1",
  "room": "Room 101",
  "utility": "Lights",
  "relay": false,
  "status": "online",
  "voltage": 229.4,
  "current": 1.21,
  "power": 242.7,
  "powerFactor": 0.95,
  "kwh": 13.492,
  "last_seen": 1776942000000
}
```

## Troubleshooting

### WiFi does not connect

- Check `WIFI_SSID` and `WIFI_PASSWORD`
- Check the ESP32 has signal
- Open Serial Monitor to see the connection log

### SSR does not switch

- Check the SSR wiring
- Confirm the correct GPIO is used
- Try changing `SSR_ACTIVE_HIGH` to `false`

### PZEM shows NaN or zero

- Check TX and RX wiring
- Make sure the PZEM is powered correctly
- Confirm baud rate and Serial2 pins
- Confirm `PZEM_MODBUS_ADDR` matches the module slave address (factory default `0xF8`)
- If PZEM TX is 5V TTL, add a level shifter or resistor divider before ESP32 RX

### Firebase reads or writes fail

- Make sure the device ID was registered in the app
- Make sure the Firebase rules are deployed
- Confirm the ESP32 is using the same `DEVICE_ID`

## Quick checklist

- [ ] WiFi credentials updated
- [ ] Device ID updated
- [ ] Device registered in app
- [ ] PZEM wired correctly
- [ ] SSR wired correctly
- [ ] Libraries installed
- [ ] Sketch uploaded
- [ ] Serial Monitor shows readings
