# 为什么用脚本 bind mount，而不是模块文件挂载

## 现象

把文件放进模块的 `product/` 目录、重启后完全没生效。
进一步检查发现：**机器上所有模块的文件都没被挂载**，例如

```bash
$ su -c 'ls /system/etc/security/cacerts/39b6bf5a.0'
No such file or directory        # reqable-magisk 提供的文件
```

## 原因（源码级）

参考 [APatch DeepWiki](https://deepwiki.com/bmax121/APatch/4.5-systemless-mounting)，
源码 `apd/src/event.rs` / `apd/src/module.rs` / `apd/src/utils.rs`。

### 1. 文件挂载被委托给 metamodule

`on_post_data_fs()` 里没有自己挂载模块文件的代码，只有：

```rust
if let Err(e) = metamodule::exec_mount_script(module_dir) {
    warn!("execute metamodule mount failed: {e}");
}
```

即：**新版 APatch 把「模块文件挂载」交给 metamodule**（`/data/adb/metamodule/`，
如 [mountify](https://github.com/backslashxx/mountify)、meta-magic_mount-rs）。
没装 ⇒ 所有模块的文件都不会被挂载。

### 2. 两处会让 APatch 整段跳过

```rust
// on_post_data_fs() 开头
if utils::has_magisk() { warn!("Magisk detected, skip post-fs-data!"); return Ok(()); }

// run_stage()
if utils::has_magisk() { warn!("Magisk detected, skip {stage}"); return; }
```

```rust
pub fn has_magisk() -> bool { which::which("magisk").is_ok() }
```

**PATH 里只要有 `magisk` 可执行文件就全跳过。** 排查：

```bash
su -c 'command -v magisk; echo $PATH'
su -c 'getprop persist.sys.safemode; getprop ro.sys.safemode'   # safe mode 同样跳过
```

### 3. 但脚本通道一直是好的

```rust
pub fn exec_stage_script(stage: &str, block: bool) -> Result<()> {
    foreach_active_module(|module| {
        let script_path = module.join(format!("{stage}.sh"));
        if !script_path.exists() { return Ok(()); }
        exec_script(&script_path, block)
    })
}
```

阶段与文件名：`post-fs-data.sh` / `service.sh` / `boot-completed.sh`。
模块目录下**没有** `disable` / `remove` 即为启用（`skip_mount` 只影响挂载，脚本照跑）。

## 为什么「别人的模块都正常」

因为依赖 APatch 自动挂载模块文件的模块，此前一个都没有：

| 模块 | 实际生效通道 |
|---|---|
| Zygisk 类（LSPosed / HMA-OSS / Thanox） | Zygisk 注入（`zygisk/*.so`） |
| ZygiskNext | 脚本启动 `zygiskd` + companion 注入 |
| 脚本类（WorkSettingPro / tricky_store） | 模块脚本 + `system.prop` |
| reqable-magisk | **脚本里自己 tmpfs + bind mount**（其 `post-fs-data.sh` 注释写明 *"use non-Magisk way"*） |

## 本模块做法

与 reqable-magisk 处理 Android 14+ cacerts 同一模式：**脚本自己 bind mount**。

```
/data/adb/modules/rearscreen_appcard_preset/
├── module.prop
├── lib.sh                 # 下载/校验/镜像回退
├── appcard.manifest       # 31 个文件 + SHA-256
├── mirrors.txt            # 镜像列表（可远程更新）
├── post-fs-data.sh  ┐
├── service.sh       ├─ 同一份 inject.sh
├── boot-completed.sh┘
└── product/media/rearscreen/{appcard,template,wallpaper,.nomedia}
```

`inject.sh` 要点：

1. **幂等** —— 目标已存在就退出（装了 metamodule 时自动让位）
2. **等待路径就绪** —— `post-fs-data` 阶段 `/product` 可能刚挂好
3. **`chcon -R u:object_r:system_file:s0`** —— 否则 `untrusted_app`（智能助理）读不到，
   表现为「挂上了但卡片不出现」
4. **资源缺失时在 service 阶段联网补下载**（post-fs-data 无网络）
5. 日志 `/data/local/tmp/rearscreen_appcard_preset.log`

## 验证

```bash
su -c 'sh /data/adb/modules/rearscreen_appcard_preset/post-fs-data.sh'
su -c 'cat /data/local/tmp/rearscreen_appcard_preset.log'
```

开机后日志应包含：

```
[... 1970 ...] post-fs-data.sh: 挂载成功          # 时钟未同步 = boot 早期
[... 稍后 ...] service.sh: 已挂载，跳过            # 幂等
```
