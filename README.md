# Xiaomi RearScreen AppCard Preset

给国行小米手机（17 Pro / 17 Pro Max 等）的**背屏「应用卡中心」补上 ROM 缺失的预置卡片** ——
包括 **小米汽车**、米家摄像机、股票行情、精选台历、临近日程、隐身模式。

> 面向：小米 17 Pro / 17 Pro Max（`pandora` / `popsicle`），澎湃 OS 4
> 需要 root（APatch / Magisk / KernelSU）

---

## 问题

小米 18 Pro 系列（AI 百变背屏）发布时「首批上线 100+ 背屏应用卡」，
但 17 Pro 系列的应用卡中心只有寥寥几张：

```
影音娱乐: 音乐、指尖球场
天气日历: 倒数日
实用工具: 米家手动控制
```

官方已表示 **17 Pro 系列背屏 AI 功能将于 12 月底更新**（卢伟冰，2026-09-23 发布会）。
在此之前，本工具可先补上这批卡片。

## 根因

「应用卡中心」的清单是**两个来源合并**的：

| 来源 | 位置 | 17 Pro Max ROM |
|---|---|---|
| 云端 | `POST store.assistant.miui.com/component/store/backPage` | ✅ 只返回 7 张 |
| **本地预置** | **`/system/media/rearscreen/appcard/default/rearScreen.json`** | ❌ **目录不存在** |

智能助理 APK 里写死了这个路径，缺文件时日志会打：

```
parsePresetJson: file not found: /system/media/rearscreen/appcard/default/rearScreen.json
```

18 系 ROM 自带该预置目录，17 系没有 ⇒ 预置卡全部缺失。

**与机型代号、账号灰度、请求参数都无关**（已实测排除，见 [`docs/root-cause.md`](docs/root-cause.md)）。

## 安装

前置：电脑有 `adb`、`curl`、`unzip`；手机已 root 并开启 USB/无线调试。

```bash
git clone https://github.com/zilewang7/xiaomi-rearscreen-appcard-preset.git
cd xiaomi-rearscreen-appcard-preset
./scripts/install.sh            # 多设备时用 -s <serial>
```

脚本会：

1. 检查 adb / root / 目标路径
2. 下载上游预置包并**校验 SHA-256**（`df171240…262f7`）
3. 解包，连同设备原有 `template/` `wallpaper/` 一起组装成模块
4. 推送到 `/data/adb/modules/reareye_appcard_preset`
5. 尝试立即生效（免重启）

**然后重启手机。** 重启后打开「设置 → 应用卡中心」：

```
天气日历: 精选台历、临近日程
实用工具: 隐身模式、米家手动控制
智能车家: 米家摄像机、小米汽车      ← 
生活服务: 股票行情
影音娱乐: 音乐、指尖球场、坚果敲击、解压键帽、海豹鼓手
```

排查：`adb shell su -c cat /data/local/tmp/reareye_appcard_preset.log`

## 卸载

```bash
./scripts/uninstall.sh
# 或
adb shell su -c 'rm -rf /data/adb/modules/reareye_appcard_preset'
```

然后重启，卡片中心恢复 ROM 原始清单。

## 原理（为什么用模块脚本而不是模块文件挂载）

新版 APatch 把「模块文件挂载」委托给 metamodule（`/data/adb/metamodule`），
未安装时**不会挂载任何模块文件**；但 `apd` 仍会在 `post-fs-data` / `service` /
`boot-completed` 三个阶段执行各模块目录下的同名脚本。

因此本模块在脚本里自己完成 `mount --bind`，并做三件必要的事：

- **幂等**：目标已存在就退出（将来装了 metamodule 会自动让位）
- **等待路径就绪**：`post-fs-data` 阶段 `/product` 可能刚挂好
- **`chcon u:object_r:system_file:s0`**：否则智能助理（`untrusted_app`）读不到

细节与源码依据见 [`docs/apatch-notes.md`](docs/apatch-notes.md)。

## 依赖版本要求

预置清单自带 `bindApp` + `bindAppVersion` 校验，智能助理会再核对一次：

| 卡片 | 依赖应用 | 最低版本 |
|---|---|---|
| 精选台历 / 临近日程 | `com.android.calendar` | 180000040 |
| 隐身模式 | `com.miui.securitycenter` | — |
| 米家摄像机 / 米家手动控制 | `com.xiaomi.smarthome` | 11060500 |
| **小米汽车** | **`com.mi.car.mobile`** | **25102214** |
| 股票行情 | `com.miui.personalassistant` | — |

任一不满足，对应卡片不会出现。

## 仓库内容

```
.
├── module/inject.sh          # 注入脚本（模块三个阶段共用）
├── scripts/install.sh        # 一键安装（PC 端，adb + root）
├── scripts/uninstall.sh      # 一键卸载
└── docs/
    ├── root-cause.md         # 根因分析（含云端接口与预置清单格式）
    └── apatch-notes.md       # APatch 挂载机制考证
```

## 重要说明

- **本仓库不包含任何小米资源文件。** 卡片资源在安装时从上游
  [`NekoStash/REAREye-Preset-Resources`](https://github.com/NekoStash/REAREye-Preset-Resources)
  下载并校验 SHA-256，版权归小米所有。
- 本项目与小米公司无关，属于非官方的社区研究性质工具。
- 修改系统行为存在风险，请自行备份并承担后果；建议先在非主力设备验证。
- 若官方更新（预期 12 月底）已下放这批卡片，请优先使用官方方案并卸载本模块。

## 致谢

- 预置卡资源：[NekoStash/REAREye-Preset-Resources](https://github.com/NekoStash/REAREye-Preset-Resources)
- 背屏增强模块：[killerprojecte/REAREye](https://github.com/killerprojecte/REAREye)
- APatch 机制文档：[bmax121/APatch DeepWiki](https://deepwiki.com/bmax121/APatch/4.5-systemless-mounting)

## License

代码以 [MIT](LICENSE) 授权。卡片资源版权归小米科技有限责任公司所有，不在授权范围内。

---

## English

This tool restores the **preset app cards** missing from the rear-screen
*App Card Center* (`com.miui.personalassistant`) on Xiaomi 17 Pro / 17 Pro Max.

**Root cause:** the card list merges a cloud source
(`store.assistant.miui.com/component/store/backPage`) with a **local preset
catalog at `/system/media/rearscreen/appcard/default/rearScreen.json`**.
Xiaomi 18-series ROMs ship that directory; 17-series ROMs do not, so the parser
logs `parsePresetJson: file not found` and every preset card is missing.

**Fix:** inject the preset catalog into that path via a root module whose
lifecycle scripts (`post-fs-data.sh` / `service.sh` / `boot-completed.sh`)
perform the bind mount — required because recent APatch delegates module file
mounting to a *metamodule*, which is often absent.

```bash
./scripts/install.sh -s <serial>   # requires adb + root
# reboot, then open Settings → App Card Center
```

No Xiaomi assets are redistributed; they are downloaded from the upstream
community repository and verified by SHA-256 at install time.
