# dsh-transfer

DSH（DeepSeek Harness）配置跨机迁移脚本：把一台机器上的插件与设置打包，在另一台机器上还原。

## 文件

| 文件 | 作用 |
| --- | --- |
| `dsh-plugins-transfer.ps1` | 导出 / 安装插件依赖（profile 的 `package.json`、`pnpm-lock.yaml`、`node_modules`，含 `file:` 本地包） |
| `dsh-settings-transfer.ps1` | 导出 / 还原 DSH 设置 |
| `README-使用说明.md` | 完整用法与参数说明 |

## 修复：两台机器 Windows 用户名不同时迁移失败

迁移包在两台机器 **Windows 账户名不同**（例如 `C:\Users\<A>` → `C:\Users\<B>`）时会失败：
pnpm 的 `node_modules/.modules.yaml` 记着源机器的 `storeDir` / `virtualStoreDir`，而旧脚本只改写了
`.dsh` 家目录那一段字符串，**用户目录下的绝对路径原样残留**。于是 pnpm 在目标机上直接报
`ERR_PNPM_UNEXPECTED_STORE`，此后安装任何插件都失败。同一原因还会漏掉 `.npmrc`，以及锁文件里
不带 `file:` 前缀的 `resolution.directory` 死路径（表现为 `ENOENT`）。

现已修复：

- 导出时记录源用户目录（`sourceUserProfile` / `sourceLocalAppData`）；
- 安装时把 `X:\Users\<源用户>` 统一改写为目标用户目录，普通文本与 pnpm/JSON 的双反斜杠转义写法都覆盖；
- `.modules.yaml` 的 `storeDir` 重算为 `%LOCALAPPDATA%\pnpm\store\v11`（目标 `.npmrc` 里显式 `store-dir` 优先），
  `virtualStoreDir` 重算为 `<profile>\node_modules\.pnpm`；
- 锁文件里不带 `file:` 前缀的裸路径形式一并改写；
- `.npmrc` 纳入改写范围。

兼容旧迁移包：包里没有新增字段时，会从 `<用户目录>\.dsh` 反推源用户目录。
