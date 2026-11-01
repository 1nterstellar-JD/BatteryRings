# hidapi logging proxy

[中文](#中文) | English

A drop-in `hidapi.dll` replacement that logs every HID report a program sends and receives.
Many vendor apps (Flutter, Electron, Qt …) ship `hidapi.dll` next to their `.exe`, so you can see
their protocol **without installing USB capture drivers**.

## Build

Any C compiler works. With [TinyCC](https://download.savannah.gnu.org/releases/tinycc/) (≈ 500 KB, no install):

```
tcc -shared -o hidapi.dll hidapi_proxy.c
```

## Use

1. Copy (or extract) the vendor app to a separate folder. Don't modify the installed copy.
2. Rename its `hidapi.dll` to `hidapi_real.dll`.
3. Put the `hidapi.dll` you built into the same folder.
4. Start the app and open the page that shows the battery.
5. Read `hidlog.txt` in that folder:

```
  500 OPEN \\?\HID#VID_3654&PID_4255&MI_03&Col02#... -> 000002CB4BF6F3F0
  500 W   VID_3654&PID_4255&MI_03&Col02    len=64  CD 07 AA 5A CC 80 51 01 02
  520 R   VID_3654&PID_4255&MI_03&Col02    len=64  CD 07 AA 5A ...
```

`W` = write (host → device), `R` = read (device → host), `SF`/`GF` = send/get feature report.
Look for a request that is sent periodically and a reply byte that matches the battery % shown in the app.

### Optional: VID/PID spoofing

Create `hidproxy.cfg` next to the DLL to make the app see a different device (useful when the app only
supports a sibling model):

```
spoof 3654:5055=3654:4255
```

When the app enumerates `3654:5055` it gets `3654:4255` instead. **Be careful:** the app may send
commands meant for another model. Never accept firmware updates while spoofing.

## 中文

一个可以直接替换的 `hidapi.dll`，会把程序收发的每个 HID 报告记录下来。很多厂商软件（Flutter、Electron、Qt 等）
会把 `hidapi.dll` 放在 exe 旁边，用这个工具就能看到它们的通信协议，**不需要安装 USB 抓包驱动**。

1. 把厂商软件复制或解包到一个单独的文件夹，不要改动已安装的那份
2. 把里面的 `hidapi.dll` 改名为 `hidapi_real.dll`
3. 把编译好的 `hidapi.dll` 放进同一个文件夹
4. 启动软件，打开显示电量的页面
5. 查看同目录下的 `hidlog.txt`，找周期性发送的请求，以及和软件显示的电量一致的返回字节

`hidproxy.cfg` 可以替换 VID/PID（见上文）。**替换后绝对不要接受固件升级。**
