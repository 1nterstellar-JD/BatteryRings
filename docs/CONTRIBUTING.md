# Contributing / 贡献指南

[中文](#中文) | [English](#english)

## 中文

### 我的设备不显示怎么办？

1. 先确认设备已经连接，并且没有休眠（动一下鼠标或按一下键盘）
2. 打开 PowerShell，运行下面的命令，生成诊断信息（只读，不会向设备发送任何命令）：

   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\BatteryRings\BatteryRings.ps1" -Diag > diag.txt
   ```

3. [新建 Issue](../../../issues/new)，写上设备型号，附上 `diag.txt`。如果官方软件能显示电量，也请写上软件名称

### 命令行

```powershell
cd "$env:LOCALAPPDATA\Programs\BatteryRings"
powershell -ExecutionPolicy Bypass -File .\BatteryRings.ps1           # 在终端里显示一次
powershell -ExecutionPolicy Bypass -File .\BatteryRings.ps1 -Watch    # 持续刷新
powershell -ExecutionPolicy Bypass -File .\BatteryRings.ps1 -Json     # 输出 JSON
powershell -ExecutionPolicy Bypass -File .\BatteryRings.ps1 -Diag     # 诊断信息
```

其他参数：`-Lang zh|en`、`-Interval <秒>`、`-NoGatt`（跳过 BLE GATT，更快）、`-ProbeCMedia`。

设置保存在 `%APPDATA%\BatteryRings\widget.json`。

### 添加一种新协议

每种协议是 `src/providers/` 下的一个文件，程序会按文件名顺序自动加载。新建一个文件，比如 `35-MyBrand.ps1`：

```powershell
# MyBrand 2.4G mice (VID 1234)
# Protocol: write [05 01] on UsagePage FF00 -> reply [05 01 <%>]

Register-BatteryProvider 'MyBrand' {
    param($ctx)                                   # $ctx.Hid = 所有 HID 设备
    foreach ($d in $ctx.Hid | Where-Object { $_.InstanceId -like 'HID\VID_1234*' }) {
        $path = Get-HidPath $d.InstanceId
        $caps = [HidIo]::Caps($path)              # [UsagePage, Usage, InLen, OutLen, FeatLen]
        if (-not $caps -or $caps[0] -ne 0xFF00) { continue }
        $r = [HidIo]::Transact($path, [byte[]](0x05, 0x01), $caps[3], $caps[2], 1500, 2)
        if ($r) {
            New-BatteryRow -Name (Get-UsbName $d.InstanceId) -Connection '24g' -Level $r[2] -Source 'MyBrand' -Kind 'mouse'
        } else {
            New-BatteryRow -Name (Get-UsbName $d.InstanceId) -Connection '24g' -Level $null -Status 'asleep' -Source 'MyBrand' -Kind 'mouse'
        }
    }
}
```

然后在 `docs/PROTOCOLS.md` 里补上协议说明，再提交 Pull Request。

### 规则

- **只发送已知的、只读的查询命令。** 不要对设备盲目试探未知命令，可能改掉设置甚至损坏固件
- **用 VID 和 Usage Page 精确匹配**，不要对无关设备发送命令
- 读取超时控制在 1.5 秒以内，设备休眠时返回 `-Level $null -Status 'asleep'`
- 请用 `[HidIo]::Transact` 收发数据：它自带退避机制，设备超时后 15 秒内直接返回 `$null`，高频刷新时不会反复等待
- 耗时的系统查询（`Get-PnpDeviceProperty` 等）结果不会变的话请缓存，参考 `Get-UsbName`
- 只写协议格式，**不要复制其他项目的代码**（许可证可能不兼容）
- `.ps1` 文件请保存为 **UTF-8 with BOM**（Windows PowerShell 5.1 需要靠 BOM 识别中文）

### 怎么找到协议

1. **找现成的开源项目**：搜索"品牌 + battery + linux / hid / github"
2. **看官方软件**：
   - .NET 程序可以用 [ILSpy](https://github.com/icsharpcode/ILSpy) 直接反编译，搜索 `Battery`
   - 软件目录里有 `hidapi.dll` 的，可以用 [`tools/hidapi_proxy`](../tools/hidapi_proxy) 记录它收发的数据
   - 其他情况可以用 [USBPcap](https://desowin.org/usbpcap/) + Wireshark 抓包
3. 对比官方软件显示的电量，找出返回包里对应的字节

### 发布新版本（维护者）

1. 修改 `src/version.json` 里的 `Version`，比如 `1.1.0`
   - 第一次发布前，要把 `Repo` 改成 `你的用户名/BatteryRings`，否则程序内更新不会生效
2. 提交，然后打标签并推送：`git tag v1.1.0 && git push origin v1.1.0`
3. GitHub Actions 会检查标签和 `version.json` 是否一致，然后打包 `BatteryRings.zip` 并发布到 Releases
4. 用户的小组件会在 24 小时内收到更新提醒

## English

### My device is not listed

1. Make sure it is connected and awake (move the mouse / press a key).
2. Create a diagnostics file (read-only, sends nothing to devices):

   ```powershell
   powershell -ExecutionPolicy Bypass -File "$env:LOCALAPPDATA\Programs\BatteryRings\BatteryRings.ps1" -Diag > diag.txt
   ```

3. [Open an issue](../../../issues/new) with the model name and `diag.txt`. Mention the vendor app if it shows the battery.

### Command line

```powershell
cd "$env:LOCALAPPDATA\Programs\BatteryRings"
powershell -ExecutionPolicy Bypass -File .\BatteryRings.ps1           # print once
powershell -ExecutionPolicy Bypass -File .\BatteryRings.ps1 -Watch    # keep refreshing
powershell -ExecutionPolicy Bypass -File .\BatteryRings.ps1 -Json     # JSON output
powershell -ExecutionPolicy Bypass -File .\BatteryRings.ps1 -Diag     # diagnostics
```

Other options: `-Lang zh|en`, `-Interval <seconds>`, `-NoGatt` (skip BLE GATT, faster), `-ProbeCMedia`.

Settings are stored in `%APPDATA%\BatteryRings\widget.json`.

### Adding a protocol

Each protocol is one file in `src/providers/`, loaded in file-name order. Copy the example above,
call `Register-BatteryProvider`, return rows with `New-BatteryRow`, document the protocol in
`docs/PROTOCOLS.md` and open a pull request.

Rules:

- **Only send known, read-only queries.** Never fuzz devices with unknown commands.
- Match devices precisely by VID and usage page.
- Keep timeouts ≤ 1.5 s; return `-Level $null -Status 'asleep'` when the device does not answer.
- Use `[HidIo]::Transact`: it backs off for 15 s after a timeout, so fast refresh intervals don't wait repeatedly.
- Cache slow system queries whose result does not change (`Get-PnpDeviceProperty` …), see `Get-UsbName`.
- Describe protocols, **do not copy code** from other projects (license compatibility).
- Save `.ps1` files as **UTF-8 with BOM** (required by Windows PowerShell 5.1 for non-ASCII text).

Finding a protocol: look for existing open-source projects, decompile .NET vendor apps with ILSpy,
log apps that ship `hidapi.dll` with [`tools/hidapi_proxy`](../tools/hidapi_proxy), or capture USB
traffic with USBPcap + Wireshark.

### Releasing (maintainers)

1. Bump `Version` in `src/version.json` (e.g. `1.1.0`). Before the first release set `Repo` to `<owner>/BatteryRings`, otherwise the in-app updater stays disabled.
2. Commit, then tag and push: `git tag v1.1.0 && git push origin v1.1.0`
3. GitHub Actions checks that the tag matches `version.json`, builds `BatteryRings.zip` and publishes the release.
4. Widgets pick up the update within 24 hours.
