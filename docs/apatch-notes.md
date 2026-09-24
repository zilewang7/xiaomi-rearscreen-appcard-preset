# 为什么用「模块脚本 + bind mount」而不是模块文件挂载

本文记录在 APatch 上让模块文件生效的正确做法，以及踩过的坑。
结论同样适用于 Magisk / KernelSU（它们原生支持模块文件挂载，但脚本通道也都在）。

## 1. 现象

把预置卡放在模块的 `product/media/rearscreen/appcard/` 下、重启后**完全没生效**。
而且检查发现：**机器上所有模块的文件都没被挂载**，例如

```bash
$ su -c 'ls /system/etc/security/cacerts/39b6bf5a.0'
No such file or directory        # reqable-magisk 模块提供的文件
```

## 2. 原因（源码级）

参考：

- [APatch Systemless Mounting](https://deepwiki.com/bmax121/APatch/4.5-systemless-mounting)
- [APatch Module Lifecycle](https://deepwiki.com/bmax121/APatch/7.3-module-lifecycle)
- 源码 `apd/src/event.rs`、`apd/src/module.rs`、`apd/src/utils.rs`

### 2.1 模块文件挂载被委托给 metamodule

`apd/src/event.rs::on_post_data_fs()` 里**没有**自己挂载模块文件的代码，只有：

```rust
if let Err(e) = metamodule::exec_mount_script(module_dir) {
    warn!("execute metamodule mount failed: {e}");
}
```

即：**新版 APatch 把「模块文件挂载」交给 metamodule**（`/data/adb/metamodule/`，
常见实现如 [mountify](https://github.com/backslashxx/mountify)、meta-magic_mount-rs）。

本机 `/data/adb/metamodule` 不存在 ⇒ 所有模块的文件都不会被挂载。

### 2.2 两处会让 APatch 整段跳过（本机均不满足，但值得排查）

```rust
// on_post_data_fs() 开头
if utils::has_magisk() { warn!("Magisk detected, skip post-fs-data!"); return Ok(()); }

// run_stage()
if utils::has_magisk() { warn!("Magisk detected, skip {stage}"); return; }
```

`has_magisk()` 的实现极简：

```rust
pub fn has_magisk() -> bool { which::which("magisk").is_ok() }
```

即 **PATH 里只要能找到 `magisk` 可执行文件，APatch 就跳过挂载与全部脚本**。
排查命令：

```bash
su -c 'command -v magisk; echo $PATH'
su -c 'getprop persist.sys.safemode; getprop ro.sys.safemode'   # safe mode 也要排除
```

## 3. 但脚本通道一直是好的

`apd/src/module.rs`：

```rust
pub fn exec_stage_script(stage: &str, block: bool) -> Result<()> {
    foreach_active_module(|module| {
        let script_path = module.join(format!("{stage}.sh"));
        if !script_path.exists() { return Ok(()); }
        exec_script(&script_path, block)
    })
}
```

三个可挂钩阶段：`post-fs-data` / `service` / `boot-completed`，
文件名分别是 `<模块目录>/post-fs-data.sh`、`service.sh`、`boot-completed.sh`。

模块状态判定（`foreach_module`）：目录下**没有** `disable` / `remove` 文件即为启用。
`skip_mount` 只影响挂载，脚本照跑。

## 4. 为什么「别人的模块都正常」

因为在本机**依赖 APatch 自动挂载模块文件的模块，此前一个都没有**：

| 模块 | 实际生效通道 |
|---|---|
| `zygisk_lsposed` / `hma_oss_zygisk` / `zygisk_thanox` | Zygisk 注入（`zygisk/*.so`） |
| `zygisksu` | 脚本启动 `zygiskd` + companion 注入（`zn_modules.txt` 把 `.so` 注入 `hyos_spawner` / `artd`） |
| `WorkSettingPro` / `tricky_store` | 模块脚本 + `system.prop` |
| `reqable-magisk` | **脚本里自己 tmpfs + bind mount**（其 `post-fs-data.sh` 注释写明 *"Since Magisk ignore /apex for module file injections, use non-Magisk way"*） |

所以「模块都正常」的直觉是对的 —— 只是它们都绕开了文件挂载这条通道。

## 5. 本项目的做法

模块结构与 [reqable-magisk](https://github.com/Howard20181/Magisk-Cert) 处理 Android 14+
cacerts 的思路一致：**脚本自己完成 bind mount**。

```
/data/adb/modules/reareye_appcard_preset/
├── module.prop
├── post-fs-data.sh      ← 同一份 inject.sh（最早，主路径）
├── service.sh           ← 同一份（兜底）
├── boot-completed.sh    ← 同一份（再兜底）
└── product/media/rearscreen/
    ├── appcard/         ← 预置卡（上游下载）
    ├── template/        ← ROM 原有，一并带上以防 overlay 不合并
    ├── wallpaper/       ← 同上
    └── .nomedia
```

脚本要点（`module/inject.sh`）：

1. **幂等**：目标文件已存在就退出 —— 将来装了 metamodule 由它挂载时，脚本自动让位。
2. **等等路径就绪**：post-fs-data 阶段 `/product` 可能刚挂好，最多等 120s。
3. **`chcon -R u:object_r:system_file:s0`**：不做的话 `untrusted_app`（智能助理）读不到，
   表现为「挂上了但卡片仍不出现」。
4. **日志**：`/data/local/tmp/reareye_appcard_preset.log`。

## 6. 验证

```bash
# 手工执行（免重启验证）
su -c 'sh /data/adb/modules/reareye_appcard_preset/post-fs-data.sh'
su -c 'cat /data/local/tmp/reareye_appcard_preset.log'
```

开机后的日志应包含（时间戳为 1970 表示时钟尚未同步，即 boot 早期）：

```
[... 1970 ...] stage=post-fs-data.sh start uid=0
[... 1970 ...] MOUNT OK (rc=0)
[... 之后 ...] already present, skip      ← service / boot-completed 幂等跳过
```

## 7. 副作用与回滚

- 挂载点在 `/system/media/rearscreen`（软链指向 `/product/media/rearscreen`），
  只增加 `appcard/` 子目录，`template/` `wallpaper/` 已一并打包，不会丢。
- 卸载：`rm -rf /data/adb/modules/reareye_appcard_preset` 后重启。

## 8. 可选：改用 metamodule

若希望走 APatch 原生挂载，可安装 metamodule（如 mountify），此时本模块的脚本
会因为幂等检查自动跳过，两者不冲突。
