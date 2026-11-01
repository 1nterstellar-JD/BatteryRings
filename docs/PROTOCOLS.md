# Protocols / 协议说明

All protocols below are used **read-only**: they only query the battery, never change settings.
Byte offsets include the report ID at index 0.

以下协议都只用于**读取**电量，不会修改设备设置。字节偏移从报告 ID（第 0 字节）开始计算。

| Provider | Devices / 设备 | Reference / 参考 |
|---|---|---|
| `10-Bluetooth` | Bluetooth / BLE devices | Windows `DEVPKEY_Bluetooth_Battery`, GATT Battery Service |
| `20-RogOmni` | ASUS ROG Omni receiver | [seerge/g-helper](https://github.com/seerge/g-helper) |
| `25-Logitech` | Logitech receivers, wired and Bluetooth devices | [pwr-Solaar/Solaar](https://github.com/pwr-Solaar/Solaar) |
| `26-Razer` | Razer wireless mice / keyboards | [openrazer/openrazer](https://github.com/openrazer/openrazer) |
| `30-Compx` | ATK, VXE, VGN, Scyrox, Dareu, G-Wolves … | [Fan4Metal/mouse_tray](https://github.com/Fan4Metal/mouse_tray) |
| `40-8BitDo` | 8BitDo Ultimate 2 … | [MiguelSanzBr/8bitdo-ultimate2-linux](https://github.com/MiguelSanzBr/8bitdo-ultimate2-linux) |
| `45-PlayStation` | DualSense / DualShock 4 | Linux `drivers/hid/hid-playstation.c` |
| `50-CMedia` | C-Media based USB headsets | C-Media XearONE driver UI (.NET), analysed for interoperability |
| `60-XInput` | Xbox-compatible controllers | `XInputGetBatteryInformation` |
| `90-System` | Laptop battery | `Win32_Battery` |

Only protocol facts were taken from the references above. No code was copied.

只参考了上述项目的协议格式，没有复制代码。

---

## Bluetooth

1. PnP property `{104EA319-6EE2-4701-BD47-8DDBF425BBE5} 2` (DEVPKEY_Bluetooth_Battery) on
   `BTHENUM\…` / `BTHLE\…` / `BTHHFENUM\…` devices. This is the same value shown in Windows Settings.
2. For connected BLE devices without that property: GATT service `0x180F`, characteristic `0x2A19`
   (1 byte, 0–100). HID-over-GATT devices usually deny access; (1) covers them.

## ASUS ROG Omni receiver — VID `0B05` PID `1ACE`

Interface `MI_02`, three vendor collections, 64-byte reports.

| Step | Collection | Write | Reply |
|---|---|---|---|
| paired devices | COL01 | `01 A0 00 00` | from byte 5: one u16 PID per 4 bytes, `0000` ends the list |
| mouse battery | COL03 | `03 12 07` | `03 12 07 …`, **[5] = %**, [10] = charging |
| keyboard battery | COL02 | `02 12 01` | `02 12 01 …`, **[6] = %** ([11] on Falchion RX LP), [9] = 1 charging |

An error reply is `xx FF AA`. When the device sleeps the receiver does not answer.

## Logitech HID++ 2.0 — VID `046D`

Receivers (PID `C5xx`) expose a short (UsagePage `FF00` Usage `0001`, 7 bytes, report `0x10`) and a long
(`FF00`/`0002`, 20 bytes, report `0x11`) collection; Bluetooth LE devices use `FF43`/`0202` (long only).
Paired devices are addressed as index 1–6, wired / Bluetooth devices as `0xFF`.

```
request  11 <index> <feature index> <function<<4 | sw id> <params …>
reply    11 <index> <feature index> <function<<4 | sw id> <data …>      (or 10 … for short replies)
error    10 <index> 8F <feature index> <function|sw> <code>             (HID++ 1.0: device not connected …)
         11 <index> FF <feature index> <function|sw> <code>             (HID++ 2.0 feature error)
```

On Windows the short and long collections are separate handles, so both are read: replies may arrive on
either, and "device not connected" only arrives on the short one.

| Feature | Call | Data |
|---|---|---|
| `0x0000` root | function 0 getFeature(id hi, id lo) | [0] feature index (0 = not supported) |
| `0x1004` unified battery | function 1 get_status | [0] % (0 = use [1]), [1] level flags 8/4/2/1, [2] status |
| `0x1000` battery status | function 0 | [0] %, [1] next level, [2] status |
| `0x1001` battery voltage | function 0 | [0..1] mV (big endian), [2] flags (bit 7 charging) → % via Solaar's voltage table |
| `0x0005` device name | function 0 / 1(offset) / 2 | length / name chunk / kind (0 keyboard, 3 mouse, …) |

Status: 0 discharging, 1 recharging, 2 almost full, 3 full, 4 slow recharge.

## Razer — VID `1532`

The control interface is the HID collection whose feature report is 90 bytes (91 with report id 0 on Windows).

```
[1] status  [2] transaction id  [3..4] remaining packets  [5] protocol  [6] data size
[7] command class  [8] command id  [9..88] arguments  [89] CRC = XOR of [3..88]
```

| Command | Class / id | Reply |
|---|---|---|
| battery level | `07` / `80`, size 2 | arguments[1] = 0–255 → % |
| charging | `07` / `84`, size 2 | arguments[1] = 1 while charging |

Send with SetFeature, wait ~60 ms, read with GetFeature. Reply status: `02` ok, `01` busy (retry), `04` timeout
(device asleep), `05` not supported. The transaction id is model specific (`1F`, `3F`, `FF`, `9F`); they are
tried in turn and the working one is remembered.

## Sony DualSense / DualShock 4 — VID `054C`

Nothing is sent: the battery is part of the input reports the controller streams anyway.

| Controller | Report | Status byte | Meaning |
|---|---|---|---|
| DualSense (`0CE6`, Edge `0DF2`) | USB `01` (64 B) / BT `31` (78 B) | [53] / [54] | low nibble level 0–10 (×10 + 5 %), high nibble 0 discharging, 1 charging, 2 full |
| DualShock 4 (`05C4`, `09CC`, adaptor `0BA0`) | USB `01` (64 B) / BT `11` (78 B) | [30] / [32] | low nibble level, bit 4 cable; with cable: < 10 charging, 10 charging 100 %, 11 full |

Over Bluetooth both send a minimal report `01` until feature report `05` (calibration) has been read once.

## Compx / Nordic 2.4G mice

The receiver has several vendor collections; pick it by usage page.

**Nordic 52840** — UsagePage `FF02` Usage `0002`, 17-byte reports:

```
write 08 04 00 00 00 00 00 00 00 00 00 00 00 00 00 00 49     (all bytes sum to 0x55)
read  08 04 00 00 00 02 23 00 0e 94 ...                       [6] = % , [7] = 1 on cable, [8..9] = mV (BE)
```

**Nordic 54L15** — UsagePage `FF05` Usage `0001`, 64-byte reports:

```
write 08 7D 72 02 00 01 07 01      (wireless; wired uses 08 7C 72 02 00 00 07 01)
read  08 xx 72 .. .. 07 .. <%>     [1] = 72, [5] = 07, [7] = %
```

## 8BitDo — VID `2DC8`

Config channel: vendor collection UsagePage `FF7A` (controller) or `FFA0` (2.4G receiver),
output report `0x81`, input report `0x02`, 64 bytes.

```
write 81 04 21 01 00 00 06
read  02 04 04 00 21 01 06 00 … [18] = %   [19..20] = controller firmware ×100
```

No reply when the controller is off.

## C-Media headsets

Found in the C-Media XearONE driver UI (`DriverInstance.IsDeviceSupportedBatteryProtocol`, `HIDEventCallback`).

```
write (output report 0x55)  55 65 01 00 …
read  (input report 0x55)   55 65 <%> <state>     state: 3 charging, 2/4 not charging, 0x1A unknown
```

Only devices whose HID descriptor has input **and** output report `0x55` are probed, and only when
the VID is `0D8C`, the manufacturer string contains "C-Media", or the VID/PID is whitelisted
(`-ProbeCMedia` probes all of them).

## XInput

`XInputGetBatteryInformation(i, BATTERY_DEVTYPE_GAMEPAD)`: type 1 = wired (no level), level 0–3 is
mapped to 5 / 25 / 60 / 100 % and marked "approx.".

## Unsupported devices / 暂不支持

- [DaiLing G3 (`3654:4255`)](devices/dailing-g3.md): the PC side of the receiver does not expose the battery.
