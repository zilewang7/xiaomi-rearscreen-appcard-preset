# 小米背屏「应用卡中心」预置卡补全

[![Release](https://img.shields.io/github/v/release/zilewang7/xiaomi-rearscreen-appcard-preset)](https://github.com/zilewang7/xiaomi-rearscreen-appcard-preset/releases/latest)

给小米 17 Pro / 17 Pro Max 的背屏「**应用卡中心**」补上 ROM 缺失的预置卡片：

| 分类 | 卡片 |
|---|---|
| 天气日历 | **精选台历**、**临近日程** |
| 实用工具 | **隐身模式** |
| 智能车家 | **米家摄像机**、**小米汽车** |
| 生活服务 | **股票行情** |

> 装完后和 18 Pro 系列演示机上的效果一致。

![应用卡中心](docs/screenshot.png)


---

## 安装

### 1. 下载

到 [**Releases**](https://github.com/zilewang7/xiaomi-rearscreen-appcard-preset/releases/latest)
下载 `xiaomi-rearscreen-appcard-preset-v*.zip`。

### 2. 刷入

在 **APatch / Magisk / KernelSU** 的模块管理里选择「从本地安装」，选中刚下载的 zip。

安装过程中模块会联网拉取卡片资源（约 7 MB，31 个文件），并逐个校验 SHA-256。
控制台会打印进度。

> 装的时候没网也没关系 —— 模块会在开机联网后自动补齐。

### 3. 重启

重启后打开 **设置 → 应用卡中心**，即可看到上表里的卡片。

---

## 前提

- 机型：小米 **17 Pro / 17 Pro Max**（其它带背屏的机型可自行尝试）
- 已 root：APatch / Magisk / KernelSU 任一
- 依赖的应用版本（ROM 自带，一般已满足，卡不出现时可对照）：

  | 卡片 | 依赖 | 最低版本 |
  |---|---|---|
  | 精选台历 / 临近日程 | 日历 `com.android.calendar` | 180000040 |
  | 隐身模式 | 安全中心 `com.miui.securitycenter` | — |
  | 米家摄像机 | 米家 `com.xiaomi.smarthome` | 11060500 |
  | 小米汽车 | 小米汽车 `com.mi.car.mobile` | 25102214 |
  | 股票行情 | 智能助理 `com.miui.personalassistant` | — |

  任何一项不满足，对应卡片就不会显示。
  **小米汽车卡还需要在小米汽车 App 里登录并绑定车辆。**

---

## 卸载

在模块管理器里删除 `RearScreen AppCard Preset` 后重启即可，系统文件未被改动。

---

## 常见问题

**卡片不出现？**
1. 确认重启过设备（挂载发生在开机阶段）
2. 看日志：`adb shell su -c cat /data/local/tmp/rearscreen_appcard_preset.log`
3. 打开「应用卡中心」页面会重新拉取一次清单

**下载失败？**
模块直连 GitHub 优先，失败会依次尝试 `mirrors.txt` 里的加速镜像。
镜像列表**可远程更新** —— 维护者改一次 `mirrors.txt`，所有已装模块下次联网自动生效，无需重新发版。
你也可以在当地网络下自行编辑 `/data/adb/modules/rearscreen_appcard_preset/mirrors.txt`。

**官方更新后还需要它吗？**
小米已表示 17 Pro 系列背屏 AI 功能将于 **12 月底**更新。官方推送后建议卸载本模块，用官方方案。

---

## 原理（简述）

「应用卡中心」的清单来自两处：

1. **云端** `store.assistant.miui.com/component/store/backPage`
2. **本地预置** `/system/media/rearscreen/appcard/default/rearScreen.json`

18 系 ROM 自带第 2 项，17 系没有 —— 智能助理解析时报
`parsePresetJson: file not found`，于是所有预置卡都不显示。
（与机型代号、账号灰度、请求参数无关，已实测排除。）

本模块把预置卡注入该路径。由于 APatch 把「模块文件挂载」委托给常未安装的
metamodule，模块改用**生命周期脚本自行 bind mount**，兼容性最好。

细节：

- [根因分析](docs/root-cause.md)
- [为什么用脚本挂载 / APatch 行为考证](docs/apatch-notes.md)

---

## 说明

- 本仓库**不包含任何小米资源文件**。卡片资源在安装时从上游
  [NekoStash/REAREye-Preset-Resources](https://github.com/NekoStash/REAREye-Preset-Resources)
  拉取并逐个校验 SHA-256，版权归小米所有。
- 非官方项目，与小米公司无关；修改系统行为有风险，请自行承担。
- 代码以 [MIT](LICENSE) 授权（不含卡片资源）。

## 致谢

- [NekoStash/REAREye-Preset-Resources](https://github.com/NekoStash/REAREye-Preset-Resources) —— 预置卡资源
- [killerprojecte/REAREye](https://github.com/killerprojecte/REAREye) —— 背屏增强模块
- [bmax121/APatch](https://github.com/bmax121/APatch) —— 挂载机制文档
