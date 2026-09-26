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
/data/data/<被 hook 的应用>/cache/reareye-preset-pack/<hash>/active.rpp
```

注意它在**被 hook 那个应用**的数据目录下（REAREye 用 `appInfo.dataDir` 作基准），
不是 REAREye 自己的目录。而且 `TARGET_PACKAGES` 有三个，**每个都要查**：

| 应用 | 角色 |
|---|---|
| `com.miui.personalassistant` | 背屏应用卡中心（我们要管的就是它）|
| `com.xiaomi.subscreencenter` | 背屏服务 |
| `com.android.thememanager` | 主题商店 |

只查应用卡中心会漏判 —— 早期版本就漏过：包提交在 `com.android.thememanager` 下，
检查却只看应用卡中心，于是报「不冲突」。

状态面板的「**冲突检测**」一栏就是查这个：

| 情况 | 面板显示 |
|---|---|
| 找到 `<hash>/active.rpp` | ✕ **REAREye 冲突** —— 已接管预置路径，本模块失效（附一键清除按钮）|
| 目录存在但没有 `active.rpp` | ! **REAREye 残留** —— 下载/校验没走完，还没接管，但随时会 |
| 装了 REAREye 但没这些目录 | ! **REAREye 已安装** —— 当前不冲突，但一旦启用预设包就会失效 |
| 没装 REAREye | ✓ 冲突检测 —— 未安装 REAREye，无冲突 |

## 为什么第一版检查会「全绿」——隔离的 mount namespace

这是比 REAREye 本身更隐蔽的一层。

管理器的 WebUI 里，`exec` 是**管理器的子进程**，因此继承了 Android 给应用准备的
隔离 mount namespace。在那个视图里，别的应用的数据目录**看起来根本不存在**。
真机实测（Xiaomi 17 Pro Max / APatch + FolkPatch 管理器）：

```
从 adb su 执行：  /data/data 有 937 个条目   → 查得到 reareye-preset-pack
从 WebUI exec 执行：/data/data 只有 3 个条目  → 查什么都「没有」
                     （com.google.android.gms、com.xiaomi.aiservice、管理器自己）
```

于是冲突检查在 WebUI 里**静默地永远返回「没有冲突」** —— 面板一本正经地报绿，
用户却看不到卡片。这正是社区反馈「每一项都是绿的，但没有卡片」的成因。

> 教训和上一节一样：**「查不到」和「不存在」是两回事，而检查脚本分不清。**
> 状态页最该防的不是「检查失败」，是「检查悄悄降级成通过」。

修正办法在 `lib.sh` 的 `ns_reexec()`：发现视图被隔离就带 init 的 mount
namespace 重跑自己。

```sh
ns_reexec() {
    [ -n "$APPCARD_NS_FIXED" ] && return 0          # 已经修过，别递归
    n=$(ls /data/data 2>/dev/null | wc -l)
    [ "${n:-0}" -ge 100 ] && return 0               # 视图正常，什么都不做
    command -v nsenter >/dev/null 2>&1 || return 0

    n2=$(nsenter -t 1 -m -- ls /data/data 2>/dev/null | wc -l)
    [ "${n2:-0}" -ge 100 ] || return 0              # nsenter 也救不了就放弃

    APPCARD_NS_FIXED=1; export APPCARD_NS_FIXED
    exec nsenter -t 1 -m -- "$0" "$@"               # 换正确的视图重跑整个脚本
}
```

要点：
* **先验证再 exec**。`nsenter -t 1 -m` 在个别内核/ROM 上未必可用，
  直接 `exec` 会把脚本跑死；先用它 `ls` 一次，确认能看见真实视图再换。
* **整脚本重跑**，不是在每个检查里打补丁。这样所有检查（现在和以后加的）
  都自动拿到正确视图，不会有人忘了加。
* 用环境变量防递归。

`status.sh` / `action.sh` / `logpack.sh` / `clear-reareye.sh` 都调了它。
`clear-reareye.sh` 尤其需要：在隔离视图里它会「什么都没找到」然后报
`RESULT=nothing`，看起来像成功，其实一个字节都没删。


## 怎么办

两者是同一个问题的两种解法，**二选一**：

**① 用 REAREye 的预设包**（推荐给已经装了 REAREye 的人）

REAREye 自带「背屏组件仓库 / 预设包」功能，装的就是同一套资源
（上游都是 `NekoStash/REAREye-Preset-Resources`）。既然它已经接管了读取路径，
就顺着它的方式装。此时本模块应该卸载，避免误导。

**② 用本模块，让 REAREye 别接管**

清除已提交的预设包，让它 `store.load()` 返回 `false`，钩子自然失效，
文件读取就回到真实文件系统 —— 本模块立刻生效。

状态页在检出冲突时**直接给一个按钮**：「清除 REAREye 预设包」。
点两次确认（第一次只是「上膛」，6–8 秒内不点第二次就自动取消），
然后 `clear-reareye.sh` 删掉三个应用下的快照缓存、重启应用卡中心。

> 为什么不用 `window.confirm`：弹不弹得出来取决于管理器有没有实现
> `onJsConfirm`。没实现的管理器会**静默丢弃**对话框，按钮看起来就「点了没反应」。
> 连点两次只依赖 DOM，任何管理器都一样。

## 这个坑值得记下来

三层检查全绿却不起作用，说明「文件正确」和「应用真的读了这个文件」是两件事。
状态页原来的检查都停在文件层，所以完全看不出问题。加一条**「有没有别人抢走了读取路径」**
的检查，比再加十条文件检查都有用。

但更狠的一课在后面：**这条检查自己也会骗人**。它跑在隔离 namespace 里，
看不见就是「不存在」，于是照样报绿。两次都是同一个错误 ——
**把「查不到」当成了「没有」**。

写诊断代码时，凡是「检查某种坏情况是否存在」的地方，都要再问一句：
*这次检查本身失败了吗？* 分辨不了「没坏」和「没查成」的检查，比没有检查更危险 ——
它会给你一个绿色的假象。

上游项目名 `NekoStash/REAREye-Preset-Resources` 其实早就提示了这层关系 ——
这套资源本来就是给 REAREye 用的。本模块只是把它做成了不依赖 REAREye 的形态。

