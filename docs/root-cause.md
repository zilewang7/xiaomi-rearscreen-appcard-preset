# 背屏「应用卡中心」缺卡 —— 根因分析

> 设备：Xiaomi 17 Pro Max（`popsicle` / 2509FPN0BC / OS4.0.0.43.XPBCNXM）
> 页面：`com.miui.personalassistant/.backscreen.store.view.BackScreenStoreActivity`
> 智能助理版本：25.41.82.00-09162057
> 日期：2026-09-24

## 1. 现象

小米 17 Pro Max 的「应用卡中心」只有 3 个分类：

```
影音娱乐: 音乐、指尖球场、坚果敲击、解压键帽、海豹鼓手
天气日历: 倒数日
实用工具: 米家手动控制
```

而小米 18 Pro 系列（AI 百变背屏）同页面还有：

```
天气日历: 精选台历、临近日程
实用工具: 隐身模式
智能车家: 米家摄像机、小米汽车
生活服务: 股票行情
```

## 2. 结论先行

应用卡中心的清单是**两个来源合并**的：

| 来源 | 位置 | 17 Pro Max ROM |
|---|---|---|
| 云端 | `POST store.assistant.miui.com/component/store/backPage` | ✅ 只返回 7 张 |
| **本地预置** | **`/system/media/rearscreen/appcard/default/rearScreen.json`** | ❌ **目录不存在** |

18 系 ROM 自带本地预置目录，17 系没有 ⇒ 智能助理解析预置清单时直接 file not found，
所有「预置卡」全部缺失。**与机型代号、账号、请求参数都无关**（已实测排除）。

## 3. 证据链

### 3.1 APK 字符串（决定性）

```
/system/media/rearscreen/appcard/default/rearScreen.json
parsePresetJson: file not found: /system/media/rearscreen/appcard/default/rearScreen.json
```

相关类：

```
com.miui.personalassistant.backscreen.store.data.repository.BackScreenStoreRepository$getPresetStoreData$1
com.miui.personalassistant.backscreen.store.data.repository.BackScreenStoreRepository$getCloudStoreData$1
com.miui.personalassistant.backscreen.store.viewmodel.BackScreenStoreViewModel$loadStoreData$1$presetDeferred$1
com.miui.personalassistant.backscreen.store.viewmodel.BackScreenStoreViewModel$loadStoreData$1$cloudDeferred$1
com.miui.personalassistant.backscreen.store.view.BackScreenStorePresetParser
```

`loadStoreData` 里同时有 `presetDeferred` 与 `cloudDeferred` —— 两路并行加载后合并，与结论一致。

### 3.2 设备实测

```bash
$ su -c 'ls /system/media/rearscreen/'
.nomedia  template  wallpaper          # ← 没有 appcard/

$ ls -ld /system/media
lrw-r--r-- 1 root root 14 /system/media -> /product/media   # 软链！
```

因此真实落点是 **`/product/media/rearscreen/`**。

### 3.3 被排除的假设

| 假设 | 实测 | 结论 |
|---|---|---|
| 机型代号问题 | 用 frida 改请求体 `phoneDevice` → `madrid` / `hongkong` | ❌ 服务端确实返回了该机型专属资源（预览图/MTZ 哈希全变），但分类数量不变 |
| 服务端灰度/账号 | 完整抓包：请求只带 `apiversion:2` + 605 个已安装应用版本 | ❌ 服务端返回 7 张，与本地预置无关 |
| 车 App 未登录/未绑车 | 已登录，绑定 YU7（`carModel=MX11`） | ❌ 排除 |
| 车 App 版本过低 | 预置清单要求 `com.mi.car.mobile >= 25102214`，本机 `26090722` | ❌ 满足 |
| 系统属性伪装 | `resetprop ro.product.device → madrid/hongkong` + 重启 App | ❌ 清单不变 |

## 4. 云端接口（仅供研究记录）

```
POST https://store.assistant.miui.com/component/store/backPage
```

请求体（字段已脱敏）：

```json
{
  "userSignal": { "oaid": "", "vaid": "<REDACTED>", "userId": "<REDACTED>" },
  "environmentSignal": {
    "terminal": "phone", "assistantVersion": "<ver>", "launchVersion": "<ver>",
    "androidVersion": "17", "androidSdkVersion": 37, "miuiType": "stable",
    "phoneModel": "<model>", "phoneDevice": "<codename>",
    "os": "<rom>", "backScreenVersion": <n>, "language": "zh", "country": "CN"
  },
  "eventSignal": {
    "apiversion": 2,
    "info": {
      "appInfosCompressedStr": "<gzip+base64 的 605 个已安装应用 {packageName,versionCode}>",
      "isCompressed": true, "pageType": 18,
      "pageUuid": "back_screen_app_list_page",
      "supportCardStyles": [1,2,3,4,5,6,7,8,100,101,102,103,104],
      "supportCardtypes": [18]
    }
  }
}
```

响应：`{"pageUuid":"back_screen_app_list_page","pageType":18,"hasNext":false,"cardList":[...]}`

每张卡带 `backScreenImplInfo.minAppVersionCode`（客户端会再校验一次）。

> ⚠️ 抓包中出现的 `userId` / `vaid` / 内网 IP 等均已脱敏，请勿提交未脱敏的抓包文件。

## 5. 预置清单格式

`rearScreen.json` 结构（节选）：

```json
{
  "version": 1,
  "count": 4,
  "products": [
    {
      "categoryName": "智能车家",
      "type": "smart_car_home",
      "priority": "100",
      "items": [
        {
          "resId": "62d7c4e8-91a3-…",
          "resType": "smart_car_home",
          "bindApp": "com.mi.car.mobile",
          "bindAppVersion": "25102214",
          "isPreset": true,
          "mtzPath": "/system/media/rearscreen/appcard/normal/03_smart/car/rearscreen",
          "appIconPath": "/system/media/rearscreen/appcard/normal/03_smart/car/app/app_icon.png",
          "previewLightPath": "/system/media/rearscreen/appcard/normal/03_smart/car/preview/preview_rearscreen_0.png"
        }
      ]
    }
  ]
}
```

即：清单声明卡片路径 → 路径必须真实存在 → 智能助理据此渲染卡片。

## 6. 修复

把 6 张预置卡（`appcard/normal/…`）连同 `appcard/default/rearScreen.json`
放到 `/system/media/rearscreen/appcard/`（真实路径 `/product/media/rearscreen/appcard/`）。

由于 `/system` 只读，采用 **root 模块 + 生命周期脚本 bind mount** —— 见
[`apatch-notes.md`](apatch-notes.md)。

## 7. 依赖版本对照（本机全部满足）

| 分类 | 卡片 | bindApp | 最低版本 | 本机 |
|---|---|---|---|---|
| 天气日历 | 精选台历 / 临近日程 | `com.android.calendar` | 180000040 | 180001290 ✅ |
| 实用工具 | 隐身模式 | `com.miui.securitycenter` | 0 | ✅ |
| 智能车家 | 米家 | `com.xiaomi.smarthome` | 11060500 | 110817031 ✅ |
| 智能车家 | 小米汽车 | `com.mi.car.mobile` | 25102214 | 26090722 ✅ |
| 生活服务 | 股票行情 | `com.miui.personalassistant` | 0 | ✅ |

## 8. 修复效果

```
天气日历: 精选台历、临近日程
实用工具: 隐身模式、米家手动控制
智能车家: 米家摄像机、小米汽车
生活服务: 股票行情
影音娱乐: 音乐、指尖球场、坚果敲击、解压键帽、海豹鼓手
```

界面与 18 系演示机一致。
