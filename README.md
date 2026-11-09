# Tasmota firmware for ZB-GW03

Custom Tasmota builds for the ZB-GW03 Zigbee gateway (ESP32 + EFR32MG21 Zigbee bridge + LAN8720 Ethernet).

## Features

- Module template `ZB-GW03` and GPIO layout preset at compile time (`USER_TEMPLATE`)
- Zigbee bridge over EZSP with external EEPROM (T24C512A), channel 11
- Ethernet via LAN8720 (PHY address 1, clock output on GPIO17)
- mDNS enabled, MQTT host discovery disabled
- Time zone UTC+8, light and Domoticz support removed
- 27 language variants

## Files

| File | Purpose |
| --- | --- |
| `tasmota32-ZB-GW03-XX.bin` | Firmware for OTA update or esptool |
| `tasmota32-ZB-GW03-XX.factory.bin` | Merged full-flash image for the first serial flash (write at 0x0) |
| `tasmota32-ZB-GW03-XX.bin.gz` | Gzipped firmware, only present when produced by the Tasmota build scripts |
| `SHA256SUMS.txt` | SHA-256 checksums |

`XX` is the language code: `EN` English, `CN` Simplified Chinese, `TW` Traditional Chinese, `DE` German, `FR` French, and so on.

## Flashing

**OTA** — Tasmota Web UI → *Firmware Upgrade* → select `tasmota32-ZB-GW03-XX.bin` (the matching `.bin.gz` works too when present).

**Serial**

```
esptool.py --chip esp32 --baud 460800 write_flash 0x0 tasmota32-ZB-GW03-XX.factory.bin
```

The module template, GPIO layout, Zigbee and Ethernet settings are applied at compile time, so no manual template configuration is needed after flashing.

## License

Based on [Tasmota](https://github.com/arendst/Tasmota), licensed under GPL-3.0.
