<p align="center">
  <img src="docs/images/icon-256.png" width="96" alt="icon">
</p>

<h1 align="center">BatteryRings</h1>

<p align="center">
  Shows the battery level of your wireless mice, keyboards, controllers and headsets on the Windows desktop, styled after the macOS Batteries widget.<br>
  <a href="README.md">中文</a> | English
</p>

<p align="center">
  <img src="docs/images/widget-en.png" alt="Widget screenshot">
</p>

## Features

- Bluetooth and 2.4 GHz receiver devices, including ones Windows itself cannot read
- No drivers, no admin rights, under 100 KB, about 25 MB of memory
- Read-only: never changes any device setting
- Charging detection, low-battery alerts, dark / light theme, autostart, automatic updates, English / Chinese UI

## Supported devices

| Brand / type | Devices |
|---|---|
| Bluetooth | headsets, mice, keyboards, controllers … (same value as Windows Settings) |
| ASUS ROG | mice and keyboards on the Omni receiver |
| Compx / Nordic mice | ATK, VXE, VGN, Scyrox, Dareu, G-Wolves … |
| 8BitDo | Ultimate 2 … |
| Xbox and compatible | XInput controllers |
| C-Media headsets | experimental |
| Logitech / Razer / Sony controllers | 🧪 untested, feedback welcome |

Device missing or not showing? See [CONTRIBUTING.md](docs/CONTRIBUTING.md).

## Install

1. Download `BatteryRings.zip` from [Releases](../../releases/latest) and extract it
2. Double-click **`Install.cmd`**
   - If "Windows protected your PC" appears, click **More info** → **Run anyway**

The widget appears in the top-right corner. Drag to move it, **right-click** for settings.

Uninstall: Start menu → **Uninstall BatteryRings**.

## FAQ

**Device shows "asleep"?** A sleeping 2.4 GHz device does not answer its receiver; the last known level is shown in grey. Move the device and it updates.

**Bluetooth device missing?** If Windows Settings → Bluetooth & devices shows no battery either, the device does not report it to Windows.

**Antivirus warning?** The program is plain-text PowerShell you can read. Add it as trusted.

## Credits

Protocol formats from [g-helper](https://github.com/seerge/g-helper), [Solaar](https://github.com/pwr-Solaar/Solaar), [OpenRazer](https://github.com/openrazer/openrazer), [Linux hid-playstation](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c), [mouse_tray](https://github.com/Fan4Metal/mouse_tray) and [8bitdo-ultimate2-linux](https://github.com/MiguelSanzBr/8bitdo-ultimate2-linux) (protocol facts only, no code copied).

## License

[GPL-3.0](LICENSE). Not affiliated with any brand mentioned here.
