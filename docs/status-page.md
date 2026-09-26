# 状态面板是怎么做的

面向维护者。使用者只需要知道：管理器里点开模块卡片就是状态面板。

## 为什么要有它

社区反馈过两类问题，都很典型：

1. **「卡住，安装不上」** —— 模块安装时联网拉资源，镜像一卡，安装界面就跟着卡死。
2. **「安上了倒是不起用」** —— 模块明明启用了、资源也下全了，卡片还是不出现。

第 2 类尤其麻烦：**预设挂对了 ≠ 卡片会出现**。应用卡中心会自己过滤掉「依赖 App
没装或版本不够」的卡片。`小米汽车` 这张卡要求 `com.mi.car.mobile ≥ 25102214`，
用户没装小米汽车 App 就永远看不到 —— 这在没有面板时完全没法自查。

所以状态页要回答的核心问题是：**「我这台机器上，到底是哪一环没对上？」**

## 架构：一个引擎 + 两个前端

```
                    ┌─────────────────┐
                    │   status.sh     │  诊断引擎，只认行协议
                    │  （纯 shell）    │
                    └────────┬────────┘
                             │
              ┌──────────────┴──────────────┐
              │                             │
     ┌────────▼────────┐          ┌─────────▼─────────┐
     │  webroot/       │          │  action.sh        │
     │  WebUI 面板      │          │  管理器「操作」按钮 │
     │  绿/黄/红 + 按钮  │          │  纯文本 + 日志包    │
     └─────────────────┘          └───────────────────┘
```

为什么是这种拆法：

- **诊断逻辑只能有一份。** 两处各写一份必然漂移，最后「管理器里显示正常、面板里
  显示异常」，用户和开发者都懵。
- **WebUI 得能点。** 用户要的是「按一下就好了」，不是「看懂之后自己去终端敲」。
  面板上的「补齐资源 / 重启卡中心 / 导出日志」都是真动作。
- **但不能只有 WebUI。** 面板依赖管理器注入 `webroot` 的 WebView，而 Magisk 官方
  管理器不支持。没有宿主时得有个退路 —— 模块卡片的「操作」按钮跑 `action.sh`，
  APatch / KernelSU 都支持。

## 行协议

不用 JSON：设备上没有 jq / python，在 busybox ash 里拼 JSON 要处理转义，容易出错。
改成每行 `key=value`、记录之间用 `@@` 分隔：

```
@@
id=card.5
level=fail
title=小米汽车
detail=配套 App 未安装：com.mi.car.mobile
fix=装上它这张卡才会出现；资源缺失
pkg=com.mi.car.mobile
```

- `level` 取 `ok` / `warn` / `fail` / `info`，决定颜色。
- `pkg` 只在卡片记录里出现，WebUI 拿它去取应用图标（`ksu://icon/<pkg>`）。
- 值里的换行、制表符在 `emit()` 里压平成空格，保证一条记录一行。

`status.sh --text` 把同一份数据渲染成人能读的版本，`action.sh` 用这个。

## 检查了什么、为什么

| 检查项 | 为什么值得查 |
|---|---|
| `env.root` + metamodule | APatch 把「模块文件挂载」委托给 metamodule，很多机器没装。没装时模块的 `system/` 根本不会被挂载 —— 这正是本模块要自行 bind mount 的原因。把这条显示出来，用户才能理解发生了什么。 |
| `res.progress` | 逐文件跑 SHA-256。下载不全是最常见的失败，而且不会报错，只会表现为「卡片少了」。 |
| `inj.mount` | 比对模块内文件与 `/system/media/...` 的 `dev:ino`。相同才说明挂的是本模块的内容；不同就可能是 ROM 自带或别的模块抢了。 |
| `inj.context` | 上下文不是 `system_file` 时应用读不到 —— 表现是「挂上了但卡片不出现」。 |
| `inj.symlink` | 走 `/system/media` 这条软链再验一次。应用读的是这条路径，软链断了前面全白搭。 |
| `inj.stagelog` | 阶段脚本到底跑没跑过。跑挂了日志里会有痕迹。 |
| `card.N` | **全篇重点。** 每张卡片查它的 `bindApp` 装没装、版本够不够。不满足时 `fix` 直接写「装上它这张卡才会出现」。 |

卡片目录 `appcard.catalog` 是从上游 preset 的 `rearScreen.json` 生成的，格式：

```
分类|卡片名|依赖包名|最低版本号|资源路径
```

`build.sh --check` 会验证里面的资源路径都能在 `appcard.manifest` 里找到，
避免上游改了结构而状态页还在按老目录判断。

## 加一个新检查

在 `status.sh` 里调 `emit`：

```sh
emit <id> <level> <标题> <详情> <修复建议> [pkg]
```

`id` 的前缀决定它归到哪个分组，WebUI 的 `SECTIONS` 表里对应：

```
env → 运行环境    res → 资源      inj → 注入状态
pre → 预设内容    card → 卡片就绪度  app → 应用卡中心
result → 结论
```

加新前缀的话，`app.js` 的 `SECTIONS` 里也要加一条，否则记录会被丢掉。

## 两个设计取舍

**日志包是单个 txt，不是 zip。** 用户要的是「把文件发给你」，不是「打包」。
txt 不用装解压软件、能直接粘到论坛、手机上就能预览。诊断信息本来就几 KB。
（设备上也没有 `zip`，busybox 只带 `unzip`。）

**安装阶段有时间预算。** 100 秒下不完就收工，剩下的交给开机后台补。
装完之后状态页会显示「12/31，重启后会自动补齐」。宁可分两次做完，
也不要让用户的安装界面卡在那儿。

## 检查项自带的修复按钮

有些问题光靠文字说不清 —— 用户得知道去哪儿点、点什么，而这一步恰恰最容易卡住
（社区有人连导出的日志文件都找不到）。所以行协议多了一个可选字段：

```
action=<id>        # 可选，WebUI 据此在卡片里画一个修复按钮
```

`app.js` 里有一张 `ACTIONS` 表，把 id 映射到 `label / busy / hint / cmd`。
`status.sh` 只在真的需要修复时才带上这个字段：

```sh
emit conf.reareye fail "REAREye 冲突" "$detail" "$fix" "" "clear_reareye"
#                                                            ↑ 第 7 个参数
```

两个刻意的选择：

**不用 `window.confirm`。** 弹不弹得出来取决于管理器有没有实现 `onJsConfirm`，
没实现的会静默丢弃对话框 —— 按钮看起来就「点了没反应」。改成连点两次确认：
第一次把按钮变成描边的红色「再点一次确认」并弹提示，6–8 秒内不点第二次就自动取消。
只依赖 DOM，任何管理器行为一致。

**动作必须是独立脚本，不是内联命令。** `clear-reareye.sh` 能单独在终端里跑、
能自己 `sh -n` 检查、能自己输出人类可读的结果和一行给机器看的
`RESULT=ok|nothing|fail`。前端只负责转述，不负责拼命令。

## 「文件在不在」和「应用读不读得到」是两件事

这是本项目踩得最深的一个坑，值得单独说。

资源检查原本是这样的：

```sh
if [ -f "$dest/$path" ] && [ "$(_sha256 "$dest/$path")" = "$sha" ]; then
    ready=$((ready + 1))
fi
```

以 **root** 身份跑，逐文件比 SHA-256。看起来无懈可击 —— 直到有人的状态页显示
「23/31 就绪」，卡片却一张都不出现。

真机取证（KernelSU bugreport 里的 `ls -laZ`）发现，那 23 个「就绪」的文件里有 8 个是：

```
-rw------- 1 root root  ...  normal/01_weather/calendar/preview/preview_rearscreen_0.png
drwx------ 2 root root  ...  normal/04_lift/
```

**root 读得到，应用读不到。** 模块目录被 bind mount 到 `/product/media/rearscreen`，
背屏应用是以自己的 uid（`u0_a140`，SELinux `platform_app_36`）去读的。
DAC 权限 0600 root:root 对它就是 EACCES，跟 SELinux 无关，也不会有 AVC 日志。

来源是 umask：`curl -o` 写出 `0666 & ~umask`，`mkdir -p` 写出 `0777 & ~umask`。
**管理器的 WebUI exec 和部分开机脚本带 umask 077**，于是写出 0600 的文件和 0700 的目录。
同一批资源里，安装时（umask 022）下的那几个是 0644，后来二次补齐（umask 077）下的就是 0600 ——
时间戳一眼能看出来。

三处修正：

1. `lib.sh` 顶部显式 `umask 022`，不再指望环境。
2. 每个文件下完立刻 `chmod 0644`，并把上层目录一路 `chmod 0755` 回去
   （`mkdir -p` 建的中间目录也可能是 0700，只 chmod 文件本身不够）。
3. `fix_perms()` 把整棵树扫一遍摆正；`inject.sh` 每次开机都跑，历史装坏的用户自动痊愈。

以及**判据本身**要改。`assets_progress()` 用 root 读，永远回答不了「应用读不读得到」，
所以新增 `perm_issues()`：不读内容，只看权限位 —— 文件要有 o+r，
路径上每一层目录都要有 o+x（否则文件权限对也没用）。

状态页于是多一条：

```
✗ 资源权限
    8 个文件/目录应用读不到（root 读得到，背屏应用读不到）；
    如 appcard/normal/04_lift/stock/rearscreen（文件 600）
    → 点下面的按钮就地修好，不用重启
    [ 修好资源权限 ]
```

> 第 N 次同一个教训：**检查本身也可能悄悄降级成「通过」。**
> 这一次它降级的方式是「用了一个应用永远不会用的身份（root）去检查」。

## 挂载也要用应用的视角验

同一个思路还修了另一处：所有挂载检查都是 root 视角，但 **Android 给每个应用
unshare 了一份 mount namespace**。如果 bind mount 发生在 zygote 分叉之后，
应用那边看到的是 ROM 原文件 —— 状态页却全绿。

所以加了一条 `inj.appns`：拿 `pidof` 找到应用卡中心的 pid，
`nsenter -t <pid> -m -- stat` 进它的 namespace 里读一次，比对 inode。

```sh
APP_INO=$(nsenter -t "$PA_PID" -m -- stat -c '%d:%i' "$MARK")
```

这是唯一一条「以应用的视角」做的检查，也应该是所有模块检查的最终标准。
（副作用：它也顺带证明了 `nsenter -t <pid> -m` 这条路是通的。）

## 真机验证记录

开发机：小米 17 Pro Max（popsicle），OS4.0.0.44.XPBCNXM，
APatch（管理器包名为 `me.yuki.folk`，FolkPatch）。

- 面板由管理器的 `WebUIActivity` 加载，`addJavascriptInterface(..., "ksu")`
  注入的桥与 KernelSU 完全一致，所以一份前端两边通吃。
- `ksu://icon/<pkg>` 能拿到真实应用图标（米家、小米汽车、股票的图标都正常显示）。
- 五个按钮都验过：`导出日志` 生成 `/sdcard/Download/appcard-log-<时间>.txt`，
  `复制诊断` 在剪贴板不可用时落到 `/sdcard/Download/appcard-diagnose.txt`。
- 一个坑：`WebUIActivity` 是 **not exported** 的，adb shell（uid 2000）拉不起来，
  得用 root（`su -c am start ...`）才能手动打开面板做测试。
- **最大的坑**：WebUI 里 `exec` 跑在**隔离的 mount namespace** 里，
  `/data/data` 只剩 3 个条目（正常 937 个），别的应用数据目录一律看不见。
  后果是「冲突检测」静默返回「不冲突」，面板报绿 —— 用户看到的却还是没卡片。
  已由 `lib.sh` 的 `ns_reexec()` 修正。详见 `docs/reareye-conflict.md`。
  复现方法：在 WebUI 里 `ls /data/data | wc -l`，正常应该 ~937。
- 排查这个坑时用了一个小技巧：往 `status.sh` 里临时插一行
  `emit env.probe info ...` 把探针结果打到面板上。注意 id 必须以已注册的
  section 前缀开头（`env.` / `conf.` / …），否则 `render()` 会把它过滤掉，什么都不显示。
