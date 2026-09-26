# REAREye 冲突：为什么「全绿但卡片不出现」

这份文档解释一个很隐蔽的失效模式，以及状态面板是怎么把它揪出来的。

## 现象

用户装了本模块，状态面板**每一项都是绿的**：

```
✓ 模块版本      v0.2.0
✓ 资源完整性    31/31 个文件全部校验通过
✓ 预设挂载      已挂载，inode 65086:876762 与模块内文件一致
✓ SELinux 上下文 u:object_r:system_file:s0
✓ 预设可读性    75855 字节，可读
✓ 应用读取路径   /system/media/rearscreen 可访问
✓ 预设内容      4 个分类 / 6 张卡片
✓ 小米汽车      com.mi.car.mobile 26090722 ≥ 25102214 ✓
✓ 结论          全部检查通过（15 项正常）
```

**但背屏上就是没有卡片。**

文件明明挂对了、读得到、校验通过 —— 那问题一定不在文件层。

## 根因：REAREye 把文件读取整个接管了

[REAREye](https://github.com/killerprojecte/REAREye) 是另一个背屏增强模块（LSPosed）。
它的 `PresetPackFilesHook` 有这么一段：

```kotlin
/** 把目标应用访问的系统预置路径重定向到当前已提交 RPP 快照。 */
class PresetPackFilesHook : YukiBaseHooker() {
    override fun onHook() {
        if (packageName !in TARGET_PACKAGES || !isRearDevice) return
        val store = PresetPackRuntimeStore(prefs, appInfo)
        if (!store.load()) return          // 没提交过预设包 → 钩子不生效

        runCatching {
            hookFileState(store)           // File.exists / isFile / isDirectory / length / list
            hookFileInputStream(store)     // FileInputStream 的两个构造
            hookOsOpen(store)              // android.system.Os.open
            hookZipFile(store)             // ZipFile 的所有构造
        }
    }

    companion object {
        private val TARGET_PACKAGES = setOf(
            "com.xiaomi.subscreencenter",
            "com.android.thememanager",
            "com.miui.personalassistant",   // ← 就是背屏应用卡中心
        )
    }
}
```

`PresetPackRuntimeStore.redirect()` 把预置路径映射到它自己的 payload：

```kotlin
fun redirect(path: String?): File? {
    if (path.isNullOrBlank() || installing.get() == true ||
        path.contains("reareye-preset-pack")) return null
    val root = packRoot ?: return null
    if (isCatalog(normalized)) return mergedCatalog(normalized)
    val relative = dataRelative(normalized)   // /system/media/... → payload/data/...
    if (relative != null) return File(root, "data/$relative").takeIf { it.isFile == true }
    val card = appCardRelative(normalized)    // appcard/...
    if (card != null) return File(root, "appcard/$card").takeIf { it.isFile == true }
    return null
}
```

而快照本身来自一个 RPP 包：

```kotlin
fun load(): Boolean {
    val slot = prefs.getString(ConfigKeys.PRESET_REMOTE_SLOT, "")
    val expectedHash = prefs.getString(ConfigKeys.PRESET_REMOTE_HASH, "")
    if (slot.isBlank() || expectedHash.length != 64) return false
    val packDir = File(appInfo.dataDir, "cache/reareye-preset-pack/$expectedHash")
    val archive = File(packDir, "active.rpp")
    // …校验 + 解出 payload/
}
```

**结论：只要 REAREye 提交过预设包，`com.miui.personalassistant` 就再也不会真的去读
`/system/media/rearscreen/...`。** 我们的 bind mount 从始至终没被读过一次 —— 文件在不在、
权限对不对，都不重要了。

## 怎么判断

看这个目录存不存在：

```sh
/data/data/com.miui.personalassistant/cache/reareye-preset-pack/
```

注意它在**被 hook 那个应用**的数据目录下（REAREye 用 `appInfo.dataDir` 作基准），
不是 REAREye 自己的目录。

状态面板的「**冲突检测**」一栏就是查这个：

| 情况 | 面板显示 |
|---|---|
| 目录存在 | ✕ **REAREye 冲突** —— 已接管预置路径，本模块失效 |
| 装了 REAREye 但没这个目录 | ! REAREye 已安装 —— 当前不冲突，但一旦启用预设包就会失效 |
| 没装 REAREye | ✓ 冲突检测 —— 未安装 REAREye，无冲突 |

## 怎么办

两者是同一个问题的两种解法，**二选一**：

**① 用 REAREye 的预设包**（推荐给已经装了 REAREye 的人）

REAREye 自带「背屏组件仓库 / 预设包」功能，装的就是同一套资源
（上游都是 `NekoStash/REAREye-Preset-Resources`）。既然它已经接管了读取路径，
就顺着它的方式装。此时本模块应该卸载，避免误导。

**② 用本模块，让 REAREye 别接管**

在 REAREye 里清除已提交的预设包，让它 `store.load()` 返回 `false`，
钩子自然失效，文件读取就回到真实文件系统 —— 本模块立刻生效。然后重启应用卡中心。

## 这个坑值得记下来

三层检查全绿却不起作用，说明「文件正确」和「应用真的读了这个文件」是两件事。
状态页原来的检查都停在文件层，所以完全看不出问题。加一条**「有没有别人抢走了读取路径」**
的检查，比再加十条文件检查都有用。

上游项目名 `NekoStash/REAREye-Preset-Resources` 其实早就提示了这层关系 ——
这套资源本来就是给 REAREye 用的。本模块只是把它做成了不依赖 REAREye 的形态。
