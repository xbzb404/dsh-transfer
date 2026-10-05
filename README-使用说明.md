# DSH 迁移工具（插件 + 个人设置）

把本机 DeepSeek Harness（DSH 桌面版）里**额外安装的插件**和**个人设置**完整搬到另一台
Windows 10/11 电脑上。全程不需要 Node / npm / pnpm / 任何账号；目标机只需要先装好
**同版本的 DeepSeek Harness**（本工具已按 0.2.0-rc.2 验证）。

| 脚本 | 负责什么 |
|---|---|
| `dsh-plugins-transfer.ps1` | **插件**：profile 清单、node_modules 里的插件包（应用自带的包自动跳过）、本地 `file:` bundle、插件的状态/配置目录（`storages`、`graph-memory`、`super-injector`、`hypercompact`、`llm-deepseek`、`redteam`、`.agent-presets`、`whale-*`） |
| `dsh-settings-transfer.ps1` | **个人设置**：`cordis.patch.yml`（模型/供应商/界面偏好等用户层）、`cordis.yml`、`hub-settings.json`、`storages\workspace.json`、`.credentials.yaml`（API key） |

两个脚本都是"一个脚本两个方向"：`-Mode Export`（在源机器打包）/ `-Mode Install`（在目标机还原）。
导出时会把脚本自己、`install-*.cmd` 双击入口、`manifest.json` 和一份中文 README 一起放进包里，
所以目标机不需要额外准备任何文件。

---

## 第 1 步：在**源机器**上打包

打开 PowerShell（`Win + R` → `powershell` → 回车），进到本目录，然后：

```powershell
# 插件（完整）
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-plugins-transfer.ps1 -Mode Export

# 个人设置
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-settings-transfer.ps1 -Mode Export
```

产物默认落在本目录的 `out\` 下：

```
out\dsh-plugins-full\        插件包目录（可直接拷贝）
out\dsh-plugins-full.zip     同一个包的压缩版
out\dsh-settings-full\
out\dsh-settings-full.zip
```

常用可选参数：

| 参数 | 作用 |
|---|---|
| `-OutDir <目录>` | 指定输出位置 |
| `-NoZip` | 只生成目录，不压缩（省时间） |
| `-IncludeOnly 'a,b'` | 只导出指定插件（小范围试跑用） |
| `-NoExclude` | 连"应用自带的包"也一起打进包（两台机器 DSH 版本不一致时可用） |
| `-WithRuntimes` | 额外打包 `dsh-runtimes`（Node/pnpm/Python，约 285 MB）；目标机完全离线时加上 |
| `-ExcludeCredentials` | 设置包里不含 `.credentials.yaml`（不想搬运 API key 时用） |
| `-WithSessions` / `-WithAttachments` | 设置包里额外带上会话记录 / 附件 |
| `-DshHome <目录>` | DSH 家目录不是 `%USERPROFILE%\.dsh` 时指定 |

## 第 2 步：拷到目标机器

把 `out\` 里的两个目录（或两个 zip）用 U 盘 / 局域网 / 网盘拷过去。**设置包里含明文 API key，
请走私有通道，装完删掉压缩包。**

## 第 3 步：在**目标机器**上安装

1. 装好同版本 DeepSeek Harness，并**至少启动过一次**（让它生成 `%USERPROFILE%\.dsh\profiles\desktop`）。
2. **完全退出 DeepSeek Harness —— 连托盘图标一起退出**（脚本会检查，没退干净会拒绝执行）。
3. 双击包里的 `install-plugins.cmd`，等它跑到 `=== 完成 ===`。
4. 双击 `install-settings.cmd`（同样等它跑完）。
5. 重新启动 DeepSeek Harness。

命令行等价写法（在解压出来的包目录里执行）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-plugins-transfer.ps1  -Mode Install -BundlePath .
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-settings-transfer.ps1 -Mode Install -BundlePath .
```

目标机工作区路径和源机不同（例如源机 `E:\DHSworkspace`，目标机想放 `D:\work`）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\dsh-settings-transfer.ps1 -Mode Install -BundlePath . -RemapWorkspace "E:\DHSworkspace=D:\work"
```

---

## 它到底做了什么（以及为什么这样做）

* **只搬"插件自己的"包**：DSH 应用自带的同名同版本包（`@deepseek-ai/dsh-tools`、`cordis`、
  `zod`、`js-yaml` 等）在导出阶段就被跳过，目标机用应用自带的那份。这是必须的——把宿主模块
  复制进 profile 会让插件 import 到"另一份"模块实例，Symbol 对不上就会报
  `Cannot read properties of undefined`。
* **本地开发中的插件会被实体化**：`file:E:\WBWorkspace\...` 这类依赖会被复制进包里的
  `payload\vendor\`，并把 `package.json` / `pnpm-workspace.yaml` / `pnpm-lock.yaml` 里的
  说明符改写成 `file:./vendor/<包名>`，所以目标机不需要源机的那套路径。
* **写入前先备份**：目标机的 `package.json`、`pnpm-workspace.yaml`、`cordis*.yml`、
  `hub-settings.json`、`.credentials.yaml`、`workspace.json` 都会先复制到
  `transfer-backup-<时间戳>\`，插件数据目录则整体改名为 `<目录>.bak-transfer-<时间戳>`。
  脚本结束时会打印回滚命令。
* **不碰应用本体**：所有写入都在 `%DSH_HOME%`（默认 `%USERPROFILE%\.dsh`）里。
* **中文与编码**：两个脚本都带 UTF-8 BOM，Windows PowerShell 5.1 显示中文正常；
  包内 JSON 一律用不带 BOM 的 UTF-8 写出。

## 常见问题

| 现象 | 处理 |
|---|---|
| `[X] DeepSeek Harness 正在运行` | 连托盘图标一起完全退出后重试。 |
| `[X] 目标机没有这个 Profile` | 先在目标机启动一次 DeepSeek Harness 生成 profile。 |
| `目标机缺少本包假定由应用提供的包` | 两台机器 DSH 版本不一致。升级到同版本，或在源机用 `-NoExclude` 重新导出。 |
| 安装后设置面板空白 / 插件不生效 | 确认安装时应用是关闭的；装完**重启**应用（Host 半边只在启动时加载）。 |
| 想撤销插件安装 | 用脚本打印的备份覆盖回 `package.json`，再删掉 `node_modules` 下包里带来的插件目录。 |
| 想撤销设置 | 把 `profiles\<profile>\transfer-backup-settings-<时间戳>\` 里的文件复制回原位。 |

## 已验证范围

在 Windows 11 + DeepSeek Harness 0.2.0-rc.2 上实测：导出 → 在**临时 DSH 家目录**里安装 →
文件哈希比对一致、`package.json` 合并与路径改写正确、10 个插件数据目录恢复、设置文件与
凭据按位恢复并完成路径改写，两个方向退出码均为 0。
