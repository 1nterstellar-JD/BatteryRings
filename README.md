<p align="center">
  <img src="docs/images/icon-256.png" width="96" alt="icon">
</p>

<h1 align="center">BatteryRings</h1>

<p align="center">
  在 Windows 桌面上显示鼠标、键盘、手柄、耳机等无线设备的电量，风格参考 macOS 的"电池"小组件。<br>
  中文 | <a href="README.en.md">English</a>
</p>

<p align="center">
  <img src="docs/images/widget-themes.png" alt="小组件截图（深色 / 浅色）">
</p>

## 特点

- 蓝牙设备和 2.4G 接收器设备都能显示，包括 Windows 自己读不到电量的
- 不用装驱动，不用管理员权限，体积不到 100 KB，内存约 25 MB
- 只读取电量，不修改任何设备设置
- 充电识别、低电量提醒、深色 / 浅色外观、开机自启、自动更新、中英文界面

## 支持的设备

| 品牌 / 类型 | 设备 |
|---|---|
| 蓝牙 | 耳机、鼠标、键盘、手柄等（和 Windows 设置里显示的一致） |
| ASUS ROG | Omni 接收器连接的鼠标、键盘 |
| Compx / Nordic 方案鼠标 | ATK、VXE、VGN、Scyrox、Dareu、G-Wolves 等 |
| 8BitDo | Ultimate 2 等 |
| Xbox 及兼容手柄 | XInput 手柄 |
| C-Media 方案耳机 | 实验性 |
| 罗技 / 雷蛇 / 索尼手柄 | 🧪 待验证，欢迎反馈 |

设备不在列表里，或者显示不出来？请看 [CONTRIBUTING.md](docs/CONTRIBUTING.md)。

## 安装

1. 在 [Releases](../../releases/latest) 下载 `BatteryRings.zip` 并解压
2. 双击 **`Install.cmd`**
   - 如果弹出"Windows 已保护你的电脑"，点 **更多信息** → **仍要运行**

小组件会出现在屏幕右上角。拖动可以移动位置，**右键**打开设置。

卸载：开始菜单 → **Uninstall BatteryRings**。

## 常见问题

**设备显示"休眠"？** 2.4G 设备休眠时接收器不会回应，这时会用灰色显示上次的电量。动一下设备就会更新。

**蓝牙设备没有显示？** 如果 Windows 设置 → 蓝牙和其他设备里也没有电量，说明这个设备没有向 Windows 上报电量。

**杀毒软件报毒？** 程序是纯文本的 PowerShell 脚本，代码都可以直接查看。加入信任即可。

## 致谢

协议格式参考了 [g-helper](https://github.com/seerge/g-helper)、[Solaar](https://github.com/pwr-Solaar/Solaar)、[OpenRazer](https://github.com/openrazer/openrazer)、[Linux hid-playstation](https://github.com/torvalds/linux/blob/master/drivers/hid/hid-playstation.c)、[mouse_tray](https://github.com/Fan4Metal/mouse_tray)、[8bitdo-ultimate2-linux](https://github.com/MiguelSanzBr/8bitdo-ultimate2-linux)（只参考协议，没有复制代码）。

## 许可证

[GPL-3.0](LICENSE)。本项目与文中提到的任何品牌都没有关联。
