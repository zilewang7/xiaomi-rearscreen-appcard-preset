# 根因分析

> 设备：Xiaomi 17 Pro Max（`popsicle` / 2509FPN0BC / OS4.0.0.43.XPBCNXM）
> 页面：`com.miui.personalassistant/.backscreen.store.view.BackScreenStoreActivity`
> 智能助理：25.41.82.00-09162057

## 结论

应用卡中心的清单由**两个来源合并**：

| 来源 | 位置 | 17 Pro Max ROM |
|---|---|---|
| 云端 | `POST store.assistant.miui.com/component/store/backPage` | ✅ 只返回 7 张 |
| **本地预置** | **`/system/media/rearscreen/appcard/default/rearScreen.json`** | ❌ **目录不存在** |

18 系 ROM 自带本地预置目录，17 系没有，于是智能助理解析预置清单时失败，
**所有预置卡（小米汽车 / 米家摄像机 / 股票行情 / 精选台历 / 临近日程 / 隐身模式）全部缺失**。

## 证据

### APK 字符串

```
/system/media/rearscreen/appcard/default/rearScreen.json
parsePresetJson: file not found: /system/media/rearscreen/appcard/default/rearScreen.json
```

相关类：

```
...backscreen.store.data.repository.BackScreenStoreRepository$getPresetStoreData$1
...backscreen.store.data.repository.BackScreenStoreRepository$getCloudStoreData$1
...backscreen.store.viewmodel.BackScreenStoreViewModel$loadStoreData$1$presetDeferred$1
...backscreen.store.viewmodel.BackScreenStoreViewModel$loadStoreData$1$cloudDeferred$1
...backscreen.store.view.BackScreenStorePresetParser
```

`loadStoreData` 里 preset / cloud 两路并行加载后合并，与结论一致。

### 设备实测

```bash
$ su -c 'ls /system/media/rearscreen/'
.nomedia  template  wallpaper        # 没有 appcard/

$ ls -ld /system/media
lrw-r--r-- 1 root root 14 /system/media -> /product/media    # 软链
```

真实落点是 **`/product/media/rearscreen/`**。

## 排除的假设

| 假设 | 实测手段 | 结果 |
|---|---|---|
| 机型代号不对 | frida 改请求体 `phoneDevice` → `madrid`/`hongkong` | ❌ 服务端确实换成了该机型专属资源（预览图 / MTZ 哈希全变），但分类数量不变 |
| 服务端灰度/账号 | 完整抓包请求体 | ❌ 请求只带 `apiversion:2` + 已安装应用版本，与本地预置无关 |
| 车 App 未登录/未绑车 | 查 App 数据 | ❌ 已登录，已绑定 YU7（`carModel=MX11`） |
| 车 App 版本过低 | 对照预置清单 `bindAppVersion` | ❌ 要求 ≥25102214，本机 26090722 |
| 改系统属性伪装机型 | `resetprop ro.product.device` + 重启 App | ❌ 清单不变 |

## 预置清单格式

```json
{
  "version": 1,
  "count": 4,
  "products": [
    {
      "categoryName": "智能车家",
      "type": "smart_car_home",
      "items": [
        {
          "resId": "62d7c4e8-91a3-…",
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

清单只声明路径，文件必须真实存在，智能助理再按 `bindApp` / `bindAppVersion` 二次校验。

## 云端接口（研究记录，已脱敏）

```
POST https://store.assistant.miui.com/component/store/backPage
```

```json
{
  "userSignal": { "oaid": "", "vaid": "<REDACTED>", "userId": "<REDACTED>" },
  "environmentSignal": {
    "phoneModel": "<model>", "phoneDevice": "<codename>",
    "assistantVersion": "<ver>", "backScreenVersion": <n>,
    "os": "<rom>", "language": "zh", "country": "CN"
  },
  "eventSignal": {
    "apiversion": 2,
    "info": {
      "appInfosCompressedStr": "<gzip+base64 的已安装应用 {packageName,versionCode}>",
      "pageType": 18,
      "pageUuid": "back_screen_app_list_page",
      "supportCardStyles": [1,2,3,4,5,6,7,8,100,101,102,103,104],
      "supportCardtypes": [18]
    }
  }
}
```

响应 `cardList` 中每张卡带 `backScreenImplInfo.minAppVersionCode`，客户端会再校验一次。

> ⚠️ 抓包含 `userId` / `vaid` / 内网 IP，分享前务必脱敏。
