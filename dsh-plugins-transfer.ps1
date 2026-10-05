<#
  dsh-plugins-transfer.ps1
  =========================
  把 DSH 桌面版（DeepSeek Harness）里"额外安装的插件"连同插件数据一起打包，
  并在另一台 Windows 10/11 上离线还原。不需要 Node / npm / pnpm / 任何账号。

  两个方向共用一个脚本：

    导出（在源机器上跑）:
      powershell -ExecutionPolicy Bypass -File dsh-plugins-transfer.ps1 -Mode Export
      powershell -ExecutionPolicy Bypass -File dsh-plugins-transfer.ps1 -Mode Export -WithRuntimes

    安装（在目标机器上跑，脚本已随包放在 bundle 根目录）:
      powershell -ExecutionPolicy Bypass -File dsh-plugins-transfer.ps1 -Mode Install -BundlePath "D:\dsh-plugins-20261005-120000"

  设计要点
  --------
  * 只拷贝"插件自己的"包：DSH 应用自带的同名同版本包会被跳过（它们在目标机上由应用提供），
    否则会把宿主模块复制成第二份实例，插件 import 到"另一份"模块后 Symbol 失配。
  * 外部 file:/绝对路径 依赖（例如本地开发中的插件）会被实体化进 payload\vendor\，
    并把 package.json / pnpm-workspace.yaml 里的说明符改写成目标机上的相对路径。
  * 应用运行期间会改写模块图 revision，因此安装前强制要求 Harness 已完全退出。
#>
[CmdletBinding()]
param(
  [ValidateSet('Export', 'Install')][string]$Mode = 'Export',
  [string]$Profile = 'desktop',
  [string]$DshHome,
  [string]$OutDir,
  [string]$BundlePath,
  [string[]]$IncludeOnly,
  [switch]$NoExclude,
  [switch]$WithRuntimes,
  [switch]$NoZip,
  [switch]$SkipAppCheck,
  [switch]$SkipRunningCheck,
  [string]$AppDir
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
if ($IncludeOnly) { $IncludeOnly = @($IncludeOnly | ForEach-Object { [string]$_ -split ',' } | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne '' }) }
$AppRel = 'resources\app\dsh\node_modules'
$DshPkgRel = 'resources\app\dsh'
$DesktopPkgRel = 'resources\app'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Die([string]$m) { Write-Host "`n[X] $m" -ForegroundColor Red; exit 1 }
function Norm([string]$p) { if (-not $p) { return $p }; $p = $p -replace '/', '\'; if ($p.EndsWith('\')) { $p = $p.Substring(0, $p.Length - 1) }; return $p }

function Resolve-DshHome([string]$explicit) {
  $h = if ($explicit) { $explicit } elseif ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
  $h = Norm $h
  if (-not (Test-Path $h)) { Die "找不到 DSH 家目录：$h`n    先启动一次 DeepSeek Harness 让它生成，或用 -DshHome 指定。" }
  return (Resolve-Path $h).Path
}

function Resolve-AppDir([string]$explicit) {
  $cands = New-Object System.Collections.Generic.List[string]
  if ($explicit) { $cands.Add($explicit) }
  if ($env:DSH_DESKTOP_DIR) { $cands.Add($env:DSH_DESKTOP_DIR) }
  try {
    Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue | ForEach-Object {
      if ($_.Path) { $cands.Add((Split-Path $_.Path -Parent)) }
    }
  } catch { }
  foreach ($p in @(
      (Join-Path $env:LOCALAPPDATA 'Programs\DeepSeek Harness'),
      'D:\deepseekHarness',
      (Join-Path $env:ProgramFiles 'DeepSeek Harness'),
      (Join-Path ${env:ProgramFiles(x86)} 'DeepSeek Harness')
    )) { if ($p) { $cands.Add($p) } }
  foreach ($c in $cands) {
    if ($c -and (Test-Path (Join-Path $c $AppRel))) { return (Resolve-Path $c).Path }
  }
  return $null
}

function Assert-HarnessClosed {
  if ($SkipRunningCheck) { Say '  ! 已用 -SkipRunningCheck 跳过「Harness 必须退出」检查（仅当目标是另一个 DSH_HOME 时使用）' 'Yellow'; return }
  $p = @(Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue)
  if ($p.Count -gt 0) {
    Die "DeepSeek Harness 正在运行（$($p.Count) 个进程）。`n    请完全退出（连托盘图标一起退出），再重新运行本脚本。"
  }
}

function Get-PkgVersion([string]$dir) {
  $pj = Join-Path $dir 'package.json'
  if (-not (Test-Path $pj)) { return $null }
  try { return (Get-Content $pj -Raw -Encoding UTF8 | ConvertFrom-Json).version } catch { return $null }
}

function Get-DirSize([string]$p) {
  if (-not (Test-Path $p)) { return 0 }
  $s = (Get-ChildItem $p -Recurse -File -Force -ErrorAction SilentlyContinue | Measure-Object -Property Length -Sum).Sum
  if (-not $s) { return 0 }
  return [int64]$s
}

function Copy-Tree([string]$src, [string]$dst) {
  if (-not (Test-Path $src)) { return }
  if (-not (Get-Item $src).PSIsContainer) {
    $parentOfFile = Split-Path $dst -Parent
    if ($parentOfFile -and -not (Test-Path $parentOfFile)) { $null = New-Item -ItemType Directory -Force -Path $parentOfFile }
    Copy-Item $src $dst -Force
    return
  }
  $parent = Split-Path $dst -Parent
  if ($parent -and -not (Test-Path $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
  $rc = Start-Process -FilePath (Join-Path $env:SystemRoot 'System32\robocopy.exe') `
    -ArgumentList @("`"$src`"", "`"$dst`"", '/E', '/NFL', '/NDL', '/NJH', '/NJS', '/NP', '/R:1', '/W:1') `
    -Wait -PassThru -WindowStyle Hidden
  if ($rc.ExitCode -ge 8) { Die "复制失败（robocopy 退出码 $($rc.ExitCode)）：$src -> $dst" }
}

function Write-Utf8Json($obj, [string]$path) {
  $json = $obj | ConvertTo-Json -Depth 24
  [System.IO.File]::WriteAllText($path, $json, (New-Object System.Text.UTF8Encoding($false)))
}

function Read-Json([string]$path) { return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) }

# ---------------------------------------------------------------------------
# 用户目录改写
#   迁移包里会带上源机器的绝对路径，最要命的是 pnpm 的 store：
#     .modules.yaml  "storeDir"        = C:\Users\<源用户>\AppData\Local\pnpm\store\v11
#                    "virtualStoreDir" = C:\Users\<源用户>\.dsh\profiles\<p>\node_modules\.pnpm
#   源机器与目标机的 Windows 用户名不同时这些路径全部失效，pnpm 会以
#   ERR_PNPM_UNEXPECTED_STORE（store 位置不匹配）拒绝一切写操作——表现就是「装任何插件都失败」。
#   所以安装时必须把「源用户目录」整体改写成目标机的用户目录。两种写法都要覆盖：
#     普通文本 C:\Users\x\...  ；以及 pnpm 写出来的转义形式 "C:\\Users\\x\\..."
# ---------------------------------------------------------------------------
function Get-SourceUserDirs($manifest) {
  $dirs = New-Object System.Collections.Generic.List[string]
  $add = { param($v) if ($v) { $v = ([string]$v -replace '/', '\').TrimEnd('\'); if ($v -and -not $dirs.Contains($v)) { $dirs.Add($v) } } }
  & $add ([string]$manifest.sourceUserProfile)
  if ($manifest.sourceLocalAppData) { & $add (Split-Path (Split-Path ([string]$manifest.sourceLocalAppData) -Parent) -Parent) }
  $h = [string]$manifest.sourceDshHome
  if ($h) { $h = ($h -replace '/', '\').TrimEnd('\'); if ((Split-Path $h -Leaf) -ieq '.dsh') { & $add (Split-Path $h -Parent) } }
  $names = New-Object System.Collections.Generic.List[string]
  foreach ($d in $dirs) { $n = Split-Path $d -Leaf; if ($n -and -not $names.Contains($n)) { $names.Add($n) } }
  # 旧包没有 sourceUserProfile 时，至少还有记录下来的用户名
  if ($manifest.sourceUser -and -not $names.Contains([string]$manifest.sourceUser)) { $names.Add([string]$manifest.sourceUser) }
  return [pscustomobject]@{ Dirs = $dirs; Names = $names }
}

function Rewrite-UserDirInText([string]$text, $srcNames, [string]$targetUserDir) {
  if (-not $text) { return $text }
  $tu = ([string]$targetUserDir).TrimEnd('\')
  if (-not $tu) { return $text }
  $leaf = Split-Path $tu -Leaf
  $repPlain = $tu.Replace('$', '$$')
  $repEsc = ($tu -replace '\\', '\\').Replace('$', '$$')
  foreach ($n in @($srcNames)) {
    $n = [string]$n
    if (-not $n -or ($n -ieq $leaf)) { continue }
    $esc = [regex]::Escape($n)
    # 先处理 pnpm 那种双反斜杠的转义写法（"C:\\Users\\x"），再处理普通单反斜杠写法
    $text = [regex]::Replace($text, '(?i)[A-Za-z]:[\\/]{2}Users[\\/]{2}' + $esc + '(?=[\\/]{1,2})', $repEsc)
    $text = [regex]::Replace($text, '(?i)[A-Za-z]:[\\/]Users[\\/]' + $esc + '(?=[\\/]{1,2})', $repPlain)
  }
  return $text
}

# 改写 .modules.yaml 里的一个路径字段（兼容 pnpm 的 "key": "C:\\a\\b" 与 key: C:\a\b 两种写法）
function Set-ConfigPath([string]$text, [string]$key, [string]$newPath) {
  $k = [regex]::Escape($key)
  $quotedPattern = '(?im)^([ \t]*"' + $k + '"[ \t]*:[ \t]*)"([^"\r\n]*)"([ \t]*,?[ \t]*)$'
  if ([regex]::IsMatch($text, $quotedPattern)) {
    return [regex]::Replace($text, $quotedPattern, ('${1}"' + ($newPath -replace '\\', '\\').Replace('$', '$$') + '"${3}'))
  }
  $plainPattern = '(?im)^([ \t]*' + $k + '[ \t]*:[ \t]*)([^"\r\n]*?)([ \t]*,?[ \t]*)$'
  return [regex]::Replace($text, $plainPattern, ('${1}' + $newPath.Replace('$', '$$') + '${3}'))
}

function Get-ProviderVersions([string]$appDir) {
  $map = @{}
  if (-not $appDir) { return $map }
  $nm = Join-Path $appDir $AppRel
  if (-not (Test-Path $nm)) { return $map }
  foreach ($e in Get-ChildItem $nm -Force -Directory) {
    if ($e.Name -like '@*') {
      foreach ($s in Get-ChildItem $e.FullName -Force -Directory) {
        $v = Get-PkgVersion $s.FullName
        if ($v) { $map["$($e.Name)/$($s.Name)"] = $v }
      }
    } else {
      $v = Get-PkgVersion $e.FullName
      if ($v) { $map[$e.Name] = $v }
    }
  }
  return $map
}

function Get-ProfilePackages([string]$nm) {
  $out = New-Object System.Collections.Generic.List[object]
  if (-not (Test-Path $nm)) { return $out }
  foreach ($e in Get-ChildItem $nm -Force -Directory) {
    if ($e.Name -like '@*') {
      foreach ($s in Get-ChildItem $e.FullName -Force -Directory) {
        $out.Add([pscustomobject]@{ Name = "$($e.Name)/$($s.Name)"; Path = $s.FullName; Version = (Get-PkgVersion $s.FullName) })
      }
    } elseif ($e.Name -notlike '.*') {
      $out.Add([pscustomobject]@{ Name = $e.Name; Path = $e.FullName; Version = (Get-PkgVersion $e.FullName) })
    }
  }
  return $out
}

function Expand-BundleZip([string]$zip) {
  $dir = Join-Path $env:TEMP ("dsh-bundle-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $null = New-Item -ItemType Directory -Force -Path $dir
  Say "  解压 $zip -> $dir"
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  if (Test-Path $tar) {
    & $tar -x -f $zip -C $dir
    if ($LASTEXITCODE -ne 0) { Die "解压失败：$zip" }
  } else {
    Expand-Archive -Path $zip -DestinationPath $dir -Force
  }
  return $dir
}

# ===========================================================================
#  EXPORT
# ===========================================================================
function Invoke-Export {
  $homeDir = Resolve-DshHome $DshHome
  $profDir = Join-Path $homeDir "profiles\$Profile"
  $profPkgPath = Join-Path $profDir 'package.json'
  if (-not (Test-Path $profPkgPath)) { Die "找不到 Profile 清单：$profPkgPath`n    先用一次 DeepSeek Harness 的 profile「$Profile」，或用 -Profile 指定。" }

  $appDir = Resolve-AppDir $AppDir
  if (-not $appDir) { Say "! 没找到 DSH 应用安装目录：将不做「应用自带包」排除（包会更大）。" Yellow }

  $root = if ($OutDir) { Norm $OutDir } else { Join-Path (Split-Path $PSCommandPath -Parent) "out\dsh-plugins-$($script:Stamp)" }
  if (Test-Path $root) { Remove-Item $root -Recurse -Force }
  $payload = Join-Path $root 'payload'
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $payload 'profile')

  Say "`n=== 导出 DSH 插件包 ===" Cyan
  Say "  DSH 家目录 : $homeDir"
  Say "  Profile    : $Profile"
  Say "  应用目录   : $(if ($appDir) { $appDir } else { '(未找到)' })"
  Say "  输出目录   : $root`n"

  # 1) profile 层的清单 / 包管理器配置
  foreach ($f in @('package.json', 'pnpm-workspace.yaml', '.npmrc', 'pnpm-lock.yaml')) {
    $src = Join-Path $profDir $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $payload "profile\$f") -Force }
  }
  $profPkg = Read-Json $profPkgPath
  if (-not $profPkg.PSObject.Properties['dependencies']) { $profPkg | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) }
  if (-not $profPkg.PSObject.Properties['dsh'] -or -not $profPkg.dsh.PSObject.Properties['profile']) {
    Die "Profile 清单里没有 dsh.profile 配置：$profPkgPath"
  }

  # 2) node_modules：只取"插件自己的"包
  $nm = Join-Path $profDir 'node_modules'
  $appMap = Get-ProviderVersions $appDir
  $all = Get-ProfilePackages $nm
  $included = New-Object System.Collections.Generic.List[object]
  $excluded = New-Object System.Collections.Generic.List[object]
  $filtered = New-Object System.Collections.Generic.List[object]
  foreach ($p in $all) {
    if ($IncludeOnly -and ($IncludeOnly -notcontains $p.Name)) { $filtered.Add($p); continue }
    $sameAsApp = (-not $NoExclude) -and $appMap.ContainsKey($p.Name) -and ($appMap[$p.Name] -eq $p.Version)
    if ($sameAsApp) { $excluded.Add($p) } else { $included.Add($p) }
  }
  Say "  待拷贝插件包 : $($included.Count) 个"
  Say "  跳过(应用自带): $($excluded.Count) 个"
  if ($filtered.Count -gt 0) { Say "  跳过(-IncludeOnly 过滤): $($filtered.Count) 个" }

  $i = 0
  foreach ($p in $included) {
    $i++
    Write-Progress -Activity '复制插件包' -Status "$i / $($included.Count)  $($p.Name)" -PercentComplete (100 * $i / [Math]::Max(1, $included.Count))
    Copy-Tree $p.Path (Join-Path $payload ("node_modules\" + ($p.Name -replace '/', '\')))
  }
  Write-Progress -Activity '复制插件包' -Completed
  $nmOut = Join-Path $payload 'node_modules'
  if (-not (Test-Path $nmOut)) { $null = New-Item -ItemType Directory -Force -Path $nmOut }
  foreach ($f in @('.modules.yaml', '.pnpm-workspace-state-v1.json')) {
    $src = Join-Path $nm $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $payload "node_modules\$f") -Force }
  }
  if (Test-Path (Join-Path $nm '.bin')) { Copy-Tree (Join-Path $nm '.bin') (Join-Path $payload 'node_modules\.bin') }

  # 3) profile 内的本地 bundle（file:./bundles/...）
  if (Test-Path (Join-Path $profDir 'bundles')) { Copy-Tree (Join-Path $profDir 'bundles') (Join-Path $payload 'bundles') }

  # 4) 外部 file:/绝对路径依赖 -> payload\vendor，并记录改写
  $rewrites = New-Object System.Collections.Generic.List[object]
  foreach ($dep in $profPkg.dependencies.PSObject.Properties) {
    $spec = [string]$dep.Value
    if ($spec -notmatch '^(file:|[A-Za-z]:[\\/]|\\\\|\.{1,2}[\\/])') { continue }
    $rel = $spec -replace '^file:', ''
    $srcAbs = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $profDir $rel }
    $srcAbs = [System.IO.Path]::GetFullPath($srcAbs)
    if ($srcAbs.StartsWith($profDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
    if (-not (Test-Path $srcAbs)) { Say "  ! 本地依赖无法解析，已跳过：$($dep.Name) -> $spec" Yellow; continue }
    $destRel = 'vendor/' + ($dep.Name -replace '/', '/')
    Copy-Tree $srcAbs (Join-Path $payload ($destRel -replace '/', '\'))
    $rewrites.Add([pscustomobject]@{ Kind = 'dependency'; Name = $dep.Name; From = $spec; To = "file:./$destRel" })
  }
  # pnpm-workspace.yaml 的 overrides 里指向绝对路径的条目
  $wsPath = Join-Path $profDir 'pnpm-workspace.yaml'
  if (Test-Path $wsPath) {
    $wsText = Get-Content $wsPath -Raw -Encoding UTF8
    $inOverrides = $false
    foreach ($line in ($wsText -split "`r?`n")) {
      if ($line -match '^overrides:\s*$') { $inOverrides = $true; continue }
      if ($inOverrides -and $line -match '^\S') { $inOverrides = $false }
      if (-not $inOverrides) { continue }
      if ($line -match '^\s+([^\s:]+):\s*(.+?)\s*$') {
        $name = $Matches[1]; $spec = $Matches[2].Trim("'`"")
        if ($spec -notmatch '^(file:|[A-Za-z]:[\\/]|\\\\)') { continue }
        $rel = $spec -replace '^file:', ''
        $srcAbs = if ([System.IO.Path]::IsPathRooted($rel)) { $rel } else { Join-Path $profDir $rel }
        $srcAbs = [System.IO.Path]::GetFullPath($srcAbs)
        if ($srcAbs.StartsWith($profDir, [StringComparison]::OrdinalIgnoreCase)) { continue }
        if (-not (Test-Path $srcAbs)) { continue }
        $destRel = 'vendor/' + $name
        if (-not (Test-Path (Join-Path $payload ($destRel -replace '/', '\')))) {
          Copy-Tree $srcAbs (Join-Path $payload ($destRel -replace '/', '\'))
        }
        $rewrites.Add([pscustomobject]@{ Kind = 'override'; Name = $name; From = $spec; To = "file:./$destRel" })
      }
    }
  }

  # 5) 插件数据目录（插件自己的状态与配置）
  $stateDirs = @('storages', 'graph-memory', 'super-injector', 'hypercompact', 'llm-deepseek', 'redteam', '.agent-presets', 'whale-audio', 'whale-bubble-imgs', 'whale-roles')
  if ($WithRuntimes) { $stateDirs += 'dsh-runtimes' }
  $copiedState = New-Object System.Collections.Generic.List[string]
  foreach ($d in $stateDirs) {
    $src = Join-Path $homeDir $d
    if (-not (Test-Path $src)) { continue }
    Write-Progress -Activity '复制插件数据' -Status $d
    Copy-Tree $src (Join-Path $payload "state\$d")
    $copiedState.Add($d)
  }
  Write-Progress -Activity '复制插件数据' -Completed

  # 6) manifest + 安装器 + 说明
  $manifest = [ordered]@{
    kind              = 'dsh-plugin-transfer'
    schema            = 1
    createdAt         = (Get-Date).ToString('o')
    sourceComputer    = $env:COMPUTERNAME
    sourceUser        = $env:USERNAME
    sourceUserProfile = $env:USERPROFILE
    sourceLocalAppData = $env:LOCALAPPDATA
    sourceDshHome     = $homeDir
    profile           = $Profile
    desktopVersion    = if ($appDir) { Get-PkgVersion (Join-Path $appDir $DesktopPkgRel) } else { $null }
    dshRuntimeVersion = if ($appDir) { Get-PkgVersion (Join-Path $appDir $DshPkgRel) } else { $null }
    bundles           = @($profPkg.dsh.profile.bundles)
    dependencies      = $profPkg.dependencies
    includedPackages  = @(foreach ($x in $included) { "$($x.Name)@$($x.Version)" })
    excludedPackages  = @(foreach ($x in $excluded) { "$($x.Name)@$($x.Version)" })
    appProvidedCheck  = @(foreach ($x in $excluded) { [ordered]@{ name = $x.Name; version = $x.Version } })
    filteredOut       = @(foreach ($x in $filtered) { $x.Name })
    pathRewrites      = $rewrites.ToArray()
    stateDirs         = $copiedState.ToArray()
    withRuntimes      = [bool]$WithRuntimes
    sizes             = [ordered]@{
      nodeModulesBytes = Get-DirSize (Join-Path $payload 'node_modules')
      payloadBytes     = Get-DirSize $payload
    }
  }
  Write-Utf8Json $manifest (Join-Path $root 'manifest.json')

  $selfName = Split-Path $PSCommandPath -Leaf
  if ($PSCommandPath -and (Test-Path $PSCommandPath)) { Copy-Item $PSCommandPath (Join-Path $root $selfName) -Force }
  $cmd = @"
@echo off
chcp 65001 >nul
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0$selfName" -Mode Install -BundlePath "%~dp0."
pause
"@
  [System.IO.File]::WriteAllText((Join-Path $root 'install-plugins.cmd'), $cmd, (New-Object System.Text.ASCIIEncoding))
  $readme = @"
# DSH 插件迁移包（$(Get-Date -Format 'yyyy-MM-dd HH:mm')）

来源机器：$env:COMPUTERNAME    来源 Profile：$Profile
插件包：$($included.Count) 个（跳过应用自带 $($excluded.Count) 个）
插件数据目录：$($copiedState -join '、')

## 在目标机器上安装

1. 先装好同版本的 DeepSeek Harness（本包来自 $($manifest.desktopVersion)），并至少启动过一次。
2. **完全退出 DeepSeek Harness（含托盘图标）**。
3. 双击 `install-plugins.cmd`，或在命令行执行：

   powershell -NoProfile -ExecutionPolicy Bypass -File dsh-plugins-transfer.ps1 -Mode Install -BundlePath .

4. 看到 `=== 完成 ===` 后重启应用。
5. 个人设置（模型、界面、API key 等）用 **设置转移包** 里的 `dsh-settings-transfer.ps1 -Mode Install` 恢复。

## 说明

* 脚本只往 `%USERPROFILE%\.dsh\profiles\<profile>` 与 `%USERPROFILE%\.dsh\<插件数据目录>` 里写文件，
  不调用 npm / pnpm，不联网，不需要任何账号。
* 目标机上 DSH 应用自带的包不会被覆盖（同名同版本已在导出时跳过）。
* 写入前会自动备份 `package.json` 等文件，脚本结尾会打印回滚命令。
"@
  [System.IO.File]::WriteAllText((Join-Path $root 'README-插件迁移.md'), $readme, (New-Object System.Text.UTF8Encoding($true)))

  # 7) 压缩
  $payloadBytes = Get-DirSize $payload
  Say ("`n  payload 体积：{0:N1} MB" -f ($payloadBytes / 1MB))
  if (-not $NoZip) {
    $zip = "$root.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Say "  正在打包 $zip ..."
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
      & $tar -a -c -f $zip -C $root '.'
      if ($LASTEXITCODE -ne 0) { Die "打包失败：$zip" }
    } else {
      Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -CompressionLevel Optimal -Force
    }
    Say ("  压缩包：{0}  ({1:N1} MB)" -f $zip, ((Get-Item $zip).Length / 1MB)) Green
  }
  Say "`n=== 导出完成 ===" Green
  Say "  目录：$root"
  Say "  把这个目录（或它的 .zip）拷到目标机器，运行其中的 install-plugins.cmd`n"
}

# ===========================================================================
#  INSTALL
# ===========================================================================
function Invoke-Install {
  $bundleRoot = if ($BundlePath) { Norm $BundlePath } else { Split-Path $PSCommandPath -Parent }
  if (-not (Test-Path $bundleRoot)) { Die "找不到 bundle：$bundleRoot" }
  if ((Get-Item $bundleRoot).PSIsContainer -eq $false -and $bundleRoot -match '\.zip$') {
    $bundleRoot = Expand-BundleZip $bundleRoot
  }
  $manifestPath = Join-Path $bundleRoot 'manifest.json'
  if (-not (Test-Path $manifestPath)) {
    # 允许从 zip 解压出来的单层子目录里运行
    $inner = Get-ChildItem $bundleRoot -Directory -Force | Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } | Select-Object -First 1
    if ($inner) { $bundleRoot = $inner.FullName } else { Die "这个目录里没有 manifest.json，不是本脚本导出的包：$bundleRoot" }
  }
  $manifest = Read-Json $manifestPath
  if ($manifest.kind -ne 'dsh-plugin-transfer') { Die "manifest.json 不是插件迁移包（kind=$($manifest.kind)）。" }
  $payload = Join-Path $bundleRoot 'payload'
  if (-not (Test-Path $payload)) { Die "包内缺少 payload 目录：$payload" }

  $homeDir = Resolve-DshHome $DshHome
  $targetProfile = if ($PSBoundParameters.ContainsKey('Profile')) { $Profile } else { [string]$manifest.profile }
  $profDir = Join-Path $homeDir "profiles\$targetProfile"

  Say "`n=== 安装 DSH 插件包 ===" Cyan
  Say "  来源机器 : $($manifest.sourceComputer)  ($($manifest.createdAt))"
  Say "  来源版本 : $($manifest.desktopVersion)"
  Say "  DSH 家目录: $homeDir"
  Say "  目标 Profile: $targetProfile`n"

  Assert-HarnessClosed
  if (-not (Test-Path $profDir)) { Die "目标机没有这个 Profile：$profDir`n    先启动一次 DeepSeek Harness（它会创建 Profile），退出后再运行本脚本。" }

  # 版本与"应用自带包"校验
  $appDir = Resolve-AppDir $AppDir
  $localDesktop = if ($appDir) { Get-PkgVersion (Join-Path $appDir $DesktopPkgRel) } else { $null }
  if ($manifest.desktopVersion -and $localDesktop -and ($manifest.desktopVersion -ne $localDesktop)) {
    Say "! 版本不一致：本包来自 $($manifest.desktopVersion)，目标机是 $localDesktop" Yellow
    Say "  应用自带的包以目标机为准；若下面检查报缺失，请把两台机器的 DeepSeek Harness 升到同一版本后再试。" Yellow
  }
  if (-not $SkipAppCheck -and $manifest.appProvidedCheck) {
    $appMap = Get-ProviderVersions $appDir
    $missing = New-Object System.Collections.Generic.List[string]
    foreach ($e in $manifest.appProvidedCheck) {
      if (-not $appMap.ContainsKey($e.name)) { $missing.Add("$($e.name)（目标机应用里没有）") }
      elseif ($appMap[$e.name] -ne $e.version) { $missing.Add("$($e.name)（期望 $($e.version)，目标机是 $($appMap[$e.name])）") }
    }
    if ($missing.Count -gt 0) {
      Die ("目标机缺少本包假定由应用提供的包：`n      " + ($missing -join "`n      ") + "`n    请在源机器上用 -NoExclude 重新导出（会把应用自带的包也打进包里），或把两台机器升到同一版本。")
    }
    Say "  [ok] 应用自带包检查通过（$($manifest.appProvidedCheck.Count) 项）"
  }

  # 备份
  $bakDir = Join-Path $profDir "transfer-backup-$($script:Stamp)"
  $null = New-Item -ItemType Directory -Force -Path $bakDir
  foreach ($f in @('package.json', 'pnpm-workspace.yaml', '.npmrc', 'pnpm-lock.yaml')) {
    $src = Join-Path $profDir $f
    if (Test-Path $src) { Copy-Item $src (Join-Path $bakDir $f) -Force }
  }
  Say "  已备份到 : $bakDir"

  # 复制 payload
  $copied = 0
  $srcNm = Join-Path $payload 'node_modules'
  if (Test-Path $srcNm) {
    $tops = @(Get-ChildItem $srcNm -Force)
    $i = 0
    foreach ($t in $tops) {
      $i++
      Write-Progress -Activity '复制插件包' -Status "$i / $($tops.Count)  $($t.Name)" -PercentComplete (100 * $i / [Math]::Max(1, $tops.Count))
      Copy-Tree $t.FullName (Join-Path $profDir "node_modules\$($t.Name)")
      if ($t.Name -notlike '.*') { $copied++ }
    }
    Write-Progress -Activity '复制插件包' -Completed
  }
  foreach ($d in @('bundles', 'vendor')) {
    $src = Join-Path $payload $d
    if (Test-Path $src) { Copy-Tree $src (Join-Path $profDir $d) }
  }

  # package.json 合并（来源优先）
  $srcPkg = Read-Json (Join-Path $payload 'profile\package.json')
  if (-not $srcPkg.PSObject.Properties['dependencies']) { $srcPkg | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) }
  $dstPath = Join-Path $profDir 'package.json'
  $dstPkg = Read-Json $dstPath
  if (-not $dstPkg.PSObject.Properties['dependencies']) { $dstPkg | Add-Member -NotePropertyName dependencies -NotePropertyValue ([pscustomobject]@{}) }
  if (-not $dstPkg.PSObject.Properties['dsh']) { $dstPkg | Add-Member -NotePropertyName dsh -NotePropertyValue ([pscustomobject]@{}) }
  if (-not $dstPkg.dsh.PSObject.Properties['profile']) { $dstPkg.dsh | Add-Member -NotePropertyName profile -NotePropertyValue ([pscustomobject]@{}) }
  $rewriteMap = @{}
  foreach ($r in @($manifest.pathRewrites)) { $rewriteMap[$r.Name] = $r.To }
  foreach ($dep in $srcPkg.dependencies.PSObject.Properties) {
    $val = [string]$dep.Value
    if ($rewriteMap.ContainsKey($dep.Name)) { $val = $rewriteMap[$dep.Name] }
    $dstPkg.dependencies | Add-Member -NotePropertyName $dep.Name -NotePropertyValue $val -Force
  }
  $bundleList = New-Object System.Collections.Generic.List[string]
  foreach ($b in @($srcPkg.dsh.profile.bundles)) { if ($b -and -not $bundleList.Contains($b)) { $bundleList.Add($b) } }
  foreach ($b in @($dstPkg.dsh.profile.bundles)) { if ($b -and -not $bundleList.Contains($b)) { $bundleList.Add("$b") } }
  $dstPkg.dsh.profile | Add-Member -NotePropertyName bundles -NotePropertyValue $bundleList.ToArray() -Force
  Write-Utf8Json $dstPkg $dstPath
  Say "  [ok] package.json 已合并（依赖 $($srcPkg.dependencies.PSObject.Properties.Name.Count) 项，bundles $($bundleList.Count) 项）"

  # profile 层其余文件
  foreach ($f in @('pnpm-workspace.yaml', '.npmrc', 'pnpm-lock.yaml')) {
    $src = Join-Path $payload "profile\$f"
    if (Test-Path $src) { Copy-Item $src (Join-Path $profDir $f) -Force }
  }
  # 路径改写（源机器绝对路径 -> 目标机相对/本地路径）
  if (@($manifest.pathRewrites).Count -gt 0) {
    foreach ($name in @('pnpm-workspace.yaml', 'pnpm-lock.yaml')) {
      $p = Join-Path $profDir $name
      if (-not (Test-Path $p)) { continue }
      $text = Get-Content $p -Raw -Encoding UTF8
      $orig = $text
      foreach ($r in @($manifest.pathRewrites)) {
        $from = [string]$r.From
        if (-not $from) { continue }
        $toSpec = [string]$r.To
        $toBare = $toSpec -replace '^file:', ''
        if ($name -ieq 'pnpm-lock.yaml') {
          # 锁文件 resolution.directory 里存的是「不带 file: 前缀」的目录名；
          # 只替换带前缀的写法会漏掉它，把源机器的死路径留在锁文件里。
          foreach ($v in @($from, ($from -replace '^file:', ''))) {
            if (-not $v) { continue }
            $text = $text.Replace($v, $toBare)
            if ($v -match '\\') { $text = $text.Replace(($v -replace '\\', '/'), ($toBare -replace '\\', '/')) }
          }
        } else {
          $text = $text.Replace($from, $toSpec)
        }
      }
      if ($text -ne $orig) {
        [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))
        Say "  [ok] $name 中的本机绝对路径已改写"
      }
    }
  }

  # 用户目录改写：源机器 C:\Users\<源用户>\... -> 目标机用户目录
  $srcUser = Get-SourceUserDirs $manifest
  $rewritten = New-Object System.Collections.Generic.List[string]
  foreach ($rel in @('node_modules\.modules.yaml', 'pnpm-lock.yaml', 'pnpm-workspace.yaml', '.npmrc')) {
    $p = Join-Path $profDir $rel
    if (-not (Test-Path $p)) { continue }
    $text = Get-Content $p -Raw -Encoding UTF8
    $orig = $text
    foreach ($d in @($srcUser.Dirs)) {
      if (-not $d -or ($d -ieq $env:USERPROFILE)) { continue }
      foreach ($form in @($d, ($d -replace '\\', '\\'))) { $text = $text.Replace($form, $env:USERPROFILE) }
      $text = $text.Replace(($d -replace '\\', '/'), ($env:USERPROFILE -replace '\\', '/'))
    }
    if ($manifest.sourceDshHome -and ([string]$manifest.sourceDshHome -ne $homeDir)) {
      foreach ($form in @([string]$manifest.sourceDshHome, ([string]$manifest.sourceDshHome -replace '\\', '\\'))) { $text = $text.Replace($form, $homeDir) }
    }
    if ($manifest.sourceLocalAppData -and ([string]$manifest.sourceLocalAppData -ine $env:LOCALAPPDATA)) {
      foreach ($form in @([string]$manifest.sourceLocalAppData, ([string]$manifest.sourceLocalAppData -replace '\\', '\\'))) { $text = $text.Replace($form, $env:LOCALAPPDATA) }
    }
    $text = Rewrite-UserDirInText $text $srcUser.Names $env:USERPROFILE
    if ($text -ne $orig) {
      [System.IO.File]::WriteAllText($p, $text, (New-Object System.Text.UTF8Encoding($false)))
      $rewritten.Add($rel)
    }
  }
  if ($rewritten.Count -gt 0) { Say "  [ok] 已按目标机用户名改写本机绝对路径：$($rewritten -join '、')" }

  # .modules.yaml 的 storeDir / virtualStoreDir 必须落在目标机的真实位置，
  # 否则 pnpm 报 ERR_PNPM_UNEXPECTED_STORE 并拒绝后续任何插件安装。
  $modPath = Join-Path $profDir 'node_modules\.modules.yaml'
  if (Test-Path $modPath) {
    $t = Get-Content $modPath -Raw -Encoding UTF8
    $before = $t
    $store = $null
    $m = [regex]::Match($t, '(?im)^[ \t]*"?storeDir"?[ \t]*:[ \t]*"?([^"\r\n,]+)"?')
    if ($m.Success) {
      $ver = if ($m.Groups[1].Value -match '(?i)store[\\/]{1,2}(v\d+)') { $Matches[1] } else { 'v11' }
      $store = Join-Path $env:LOCALAPPDATA "pnpm\store\$ver"
    }
    $npmrcPath = Join-Path $profDir '.npmrc'
    if (Test-Path $npmrcPath) {
      $sm = [regex]::Match((Get-Content $npmrcPath -Raw -Encoding UTF8), '(?im)^[ \t]*store-dir[ \t]*=[ \t]*"?([^"\r\n]+)"?')
      if ($sm.Success -and $sm.Groups[1].Value.Trim()) { $store = $sm.Groups[1].Value.Trim().TrimEnd('\') }
    }
    if ($store) {
      $t = Set-ConfigPath $t 'storeDir' $store
      $t = Set-ConfigPath $t 'virtualStoreDir' (Join-Path $profDir 'node_modules\.pnpm')
    }
    if ($t -ne $before) {
      [System.IO.File]::WriteAllText($modPath, $t, (New-Object System.Text.UTF8Encoding($false)))
      Say "  [ok] .modules.yaml 的 storeDir / virtualStoreDir 已按目标机重算"
    }
  }

  # 插件数据目录
  $stateRoot = Join-Path $payload 'state'
  $restoredState = New-Object System.Collections.Generic.List[string]
  if (Test-Path $stateRoot) {
    foreach ($d in Get-ChildItem $stateRoot -Force -Directory) {
      $dst = Join-Path $homeDir $d.Name
      if (Test-Path $dst) {
        $aside = "$dst.bak-transfer-$($script:Stamp)"
        Move-Item $dst $aside -Force
        Say "  ~ 目标机已有 $($d.Name)，已改名为 $(Split-Path $aside -Leaf)"
      }
      Copy-Tree $d.FullName $dst
      $restoredState.Add($d.Name)
    }
    Say "  [ok] 插件数据目录已恢复：$($restoredState -join '、')"
  }

  # 校验 bundles 可解析
  $appMap2 = Get-ProviderVersions $appDir
  $notFound = New-Object System.Collections.Generic.List[string]
  foreach ($b in $bundleList) {
    $rel = $b -replace '/', '\'
    $inProfile = Test-Path (Join-Path $profDir "node_modules\$rel\package.json")
    $inApp = $appMap2.ContainsKey($b)
    if (-not $inProfile -and -not $inApp) { $notFound.Add($b) }
  }
  if ($notFound.Count -gt 0) {
    Say "`n! 以下 bundle 在目标机既不在 profile 也不在应用里：" Yellow
    $notFound | Select-Object -First 12 | ForEach-Object { Say "      $_" Yellow }
    if ($notFound.Count -gt 12) { Say "      …（共 $($notFound.Count) 项）" Yellow }
    if ($manifest.filteredOut -and @($manifest.filteredOut).Count -gt 0) {
      Say "  提示：本包是用 -IncludeOnly 过滤导出的（过滤掉 $($manifest.filteredOut.Count) 个包），正式迁移请不加该参数。" Yellow
    }
  } else {
    Say "  [ok] 所有 bundle（$($bundleList.Count) 个）均可解析"
  }

  Say "`n=== 完成 ===" Green
  Say "  恢复的插件包 : $copied 个   插件数据目录 : $($restoredState.Count) 个"
  Say '  下一步       : 重启 DeepSeek Harness；个人设置请用「设置迁移包」恢复'
  Say "  回滚         : copy /Y `"$bakDir\package.json`" `"$profDir\package.json`""
  Say "                 然后删除 node_modules 下本包带来的插件目录`n"
}

try {
  if ($Mode -eq 'Export') { Invoke-Export } else { Invoke-Install }
} catch {
  Write-Host "`n[X] 执行失败：$($_.Exception.Message)" -ForegroundColor Red
  Write-Host "    位置：$($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
  Write-Host "    调用栈：$($_.ScriptStackTrace)" -ForegroundColor DarkGray
  exit 1
}
