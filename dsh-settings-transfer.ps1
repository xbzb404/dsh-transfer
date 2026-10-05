<#
  dsh-settings-transfer.ps1
  ==========================
  把 DSH 桌面版（DeepSeek Harness）的"个人设置"打包并在另一台 Windows 10/11 上还原：
  模型 / 供应商 / 界面偏好（cordis.patch.yml 用户层）、应用偏好（hub-settings.json）、
  凭据（.credentials.yaml，含 API key）、工作区列表（storages\workspace.json）。

  导出（源机器）:
    powershell -ExecutionPolicy Bypass -File dsh-settings-transfer.ps1 -Mode Export
    powershell -ExecutionPolicy Bypass -File dsh-settings-transfer.ps1 -Mode Export -ExcludeCredentials
    powershell -ExecutionPolicy Bypass -File dsh-settings-transfer.ps1 -Mode Export -WithSessions -WithAttachments

  安装（目标机器，脚本随包放在 bundle 根目录）:
    powershell -ExecutionPolicy Bypass -File dsh-settings-transfer.ps1 -Mode Install -BundlePath "D:\dsh-settings-20261005-120000"
    powershell -ExecutionPolicy Bypass -File dsh-settings-transfer.ps1 -Mode Install -RemapWorkspace "E:\DHSworkspace=D:\work"

  安全提醒：默认包含 .credentials.yaml（内含明文 API key）。请用 U 盘 / 私有通道搬运，
  安装完成后删除压缩包。
#>
[CmdletBinding()]
param(
  [ValidateSet('Export', 'Install')][string]$Mode = 'Export',
  [string]$Profile = 'desktop',
  [string]$DshHome,
  [string]$OutDir,
  [string]$BundlePath,
  [switch]$ExcludeCredentials,
  [switch]$WithSessions,
  [switch]$WithAttachments,
  [string[]]$RemapWorkspace,
  [switch]$KeepTargetCordis,
  [switch]$SkipRunningCheck,
  [switch]$NoZip
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$script:Stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

function Say([string]$m, [string]$c = 'Gray') { Write-Host $m -ForegroundColor $c }
function Die([string]$m) { Write-Host "`n[X] $m" -ForegroundColor Red; exit 1 }
function Norm([string]$p) { if (-not $p) { return $p }; $p = $p -replace '/', '\'; if ($p.EndsWith('\')) { $p = $p.Substring(0, $p.Length - 1) }; return $p }

function Resolve-DshHome([string]$explicit) {
  $h = if ($explicit) { $explicit } elseif ($env:DSH_HOME) { $env:DSH_HOME } else { Join-Path $env:USERPROFILE '.dsh' }
  $h = Norm $h
  if (-not (Test-Path $h)) { Die "找不到 DSH 家目录：$h`n    先启动一次 DeepSeek Harness，或用 -DshHome 指定。" }
  return (Resolve-Path $h).Path
}

function Assert-HarnessClosed {
  if ($SkipRunningCheck) { Say '  ! 已用 -SkipRunningCheck 跳过「Harness 必须退出」检查（仅当目标是另一个 DSH_HOME 时使用）' 'Yellow'; return }
  $p = @(Get-Process 'DeepSeek Harness' -ErrorAction SilentlyContinue)
  if ($p.Count -gt 0) { Die "DeepSeek Harness 正在运行（$($p.Count) 个进程）。`n    请完全退出（含托盘图标）后再运行本脚本。" }
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
  [System.IO.File]::WriteAllText($path, ($obj | ConvertTo-Json -Depth 24), (New-Object System.Text.UTF8Encoding($false)))
}
function Read-Json([string]$path) { return (Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json) }

# ---------------------------------------------------------------------------
# 用户目录改写
#   设置文件里存的是源机器的绝对路径（cordis.patch.yml / hub-settings.json 里的
#   运行时目录、工作区目录、便携 node/python 目录等）。源机器与目标机的 Windows
#   用户名不同时（C:\Users\<源用户名> -> C:\Users\<目标用户名>）这些路径全部失效。
#   原来只改写 DSH 家目录，用户目录本身及其 AppData 下的路径会漏掉，这里补上，
#   两种写法都覆盖：普通文本 C:\Users\x\... ；以及转义形式 "C:\\Users\\x\\..."
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
    # 先处理 JSON / pnpm 那种双反斜杠的转义写法（"C:\\Users\\x"），再处理普通单反斜杠写法
    $text = [regex]::Replace($text, '(?i)[A-Za-z]:[\\/]{2}Users[\\/]{2}' + $esc + '(?=[\\/]{1,2})', $repEsc)
    $text = [regex]::Replace($text, '(?i)[A-Za-z]:[\\/]Users[\\/]' + $esc + '(?=[\\/]{1,2})', $repPlain)
  }
  return $text
}
function Copy-FileSafe([string]$src, [string]$dst) {
  if (-not (Test-Path $src)) { return $false }
  $parent = Split-Path $dst -Parent
  if ($parent -and -not (Test-Path $parent)) { $null = New-Item -ItemType Directory -Force -Path $parent }
  Copy-Item $src $dst -Force
  return $true
}

function Expand-BundleZip([string]$zip) {
  $dir = Join-Path $env:TEMP ("dsh-settings-" + [guid]::NewGuid().ToString('N').Substring(0, 8))
  $null = New-Item -ItemType Directory -Force -Path $dir
  Say "  解压 $zip -> $dir"
  $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
  if (Test-Path $tar) {
    & $tar -x -f $zip -C $dir
    if ($LASTEXITCODE -ne 0) { Die "解压失败：$zip" }
  } else { Expand-Archive -Path $zip -DestinationPath $dir -Force }
  return $dir
}

# 需要迁移的"设置类"文件（相对 DSH 家目录或 profile 目录）
$SettingFiles = @(
  @{ Rel = "profiles\$Profile\cordis.patch.yml"; Kind = 'profile' },
  @{ Rel = "profiles\$Profile\cordis.yml"; Kind = 'profile' },
  @{ Rel = "profiles\$Profile\hub-settings.json"; Kind = 'profile' },
  @{ Rel = 'storages\workspace.json'; Kind = 'home' }
)

function Invoke-Export {
  $homeDir = Resolve-DshHome $DshHome
  $profDir = Join-Path $homeDir "profiles\$Profile"
  if (-not (Test-Path $profDir)) { Die "找不到 Profile 目录：$profDir" }
  $root = if ($OutDir) { Norm $OutDir } else { Join-Path (Split-Path $PSCommandPath -Parent) "out\dsh-settings-$($script:Stamp)" }
  if (Test-Path $root) { Remove-Item $root -Recurse -Force }
  $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'payload\settings'), (Join-Path $root 'payload\profile')

  Say "`n=== 导出 DSH 个人设置 ===" Cyan
  Say "  DSH 家目录 : $homeDir"
  Say "  Profile    : $Profile"
  Say "  输出目录   : $root`n"

  $copied = New-Object System.Collections.Generic.List[string]
  foreach ($f in $SettingFiles) {
    $src = Join-Path $homeDir $f.Rel
    $name = Split-Path $f.Rel -Leaf
    if ($f.Kind -eq 'profile') {
      if (Copy-FileSafe $src (Join-Path $root "payload\profile\$name")) { $copied.Add($f.Rel) }
    } else {
      if (Copy-FileSafe $src (Join-Path $root ("payload\settings\" + ($f.Rel -replace '/', '\'))) ) { $copied.Add($f.Rel) }
    }
  }

  # 凭据（API key 等）
  $credIncluded = $false
  if (-not $ExcludeCredentials) {
    $cred = Join-Path $homeDir '.credentials.yaml'
    if (Copy-FileSafe $cred (Join-Path $root 'payload\settings\.credentials.yaml')) { $copied.Add('.credentials.yaml'); $credIncluded = $true }
  }

  # 可选：会话记录 / 附件
  if ($WithSessions) {
    $s = Join-Path $homeDir 'sessions'
    if (Test-Path $s) { Copy-Tree $s (Join-Path $root 'payload\data\sessions'); $copied.Add('sessions\ (会话记录)') }
  }
  if ($WithAttachments) {
    $a = Join-Path $homeDir 'attachments'
    if (Test-Path $a) { Copy-Tree $a (Join-Path $root 'payload\data\attachments'); $copied.Add('attachments\ (附件)') }
  }

  # 工作区绝对路径（便于目标机改写）
  $workspacePaths = New-Object System.Collections.Generic.List[string]
  $wsFile = Join-Path $homeDir 'storages\workspace.json'
  if (Test-Path $wsFile) {
    try {
      $ws = Read-Json $wsFile
      foreach ($t in $ws.tables.workspaces.PSObject.Properties) {
        if ($t.Value.path) { $workspacePaths.Add([string]$t.Value.path) }
      }
    } catch { }
  }

  $manifest = [ordered]@{
    kind             = 'dsh-settings-transfer'
    schema           = 1
    createdAt        = (Get-Date).ToString('o')
    sourceComputer   = $env:COMPUTERNAME
    sourceUser       = $env:USERNAME
    sourceUserProfile = $env:USERPROFILE
    sourceLocalAppData = $env:LOCALAPPDATA
    sourceDshHome    = $homeDir
    profile          = $Profile
    files            = $copied.ToArray()
    credentialsIncluded = $credIncluded
    withSessions     = [bool]$WithSessions
    withAttachments  = [bool]$WithAttachments
    sourceWorkspacePaths = $workspacePaths.ToArray()
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
  [System.IO.File]::WriteAllText((Join-Path $root 'install-settings.cmd'), $cmd, (New-Object System.Text.ASCIIEncoding))

  $credLine = if ($credIncluded) { '- 凭据：**已包含** `.credentials.yaml`（含明文 API key），请用私有通道搬运，装完删除压缩包。' } else { '- 凭据：未包含（-ExcludeCredentials）。' }
  $readme = @"
# DSH 个人设置迁移包（$(Get-Date -Format 'yyyy-MM-dd HH:mm')）

来源机器：$env:COMPUTERNAME    来源 Profile：$Profile
包含：$($copied -join '、')

$credLine

## 在目标机器上安装

1. **完全退出 DeepSeek Harness（含托盘图标）**。
2. 双击 `install-settings.cmd`，或执行：

   powershell -NoProfile -ExecutionPolicy Bypass -File dsh-settings-transfer.ps1 -Mode Install -BundlePath .

3. 如果目标机的工作区路径不同（例如源机是 E:\DHSworkspace，目标机想放到 D:\work）：

   powershell -NoProfile -ExecutionPolicy Bypass -File dsh-settings-transfer.ps1 -Mode Install -BundlePath . -RemapWorkspace "E:\DHSworkspace=D:\work"

4. 重启 DeepSeek Harness。

## 说明

* 覆盖前会把目标机原文件备份到 `profiles\<profile>\transfer-backup-settings-<时间戳>\`。
* 默认整体替换 `cordis.patch.yml`（这就是你的设置层）。若只想保留目标机现有设置，加 `-KeepTargetCordis`。
* 本脚本只写设置文件，不动插件包；插件请用插件迁移包恢复。
"@
  [System.IO.File]::WriteAllText((Join-Path $root 'README-设置迁移.md'), $readme, (New-Object System.Text.UTF8Encoding($true)))

  if (-not $NoZip) {
    $zip = "$root.zip"
    if (Test-Path $zip) { Remove-Item $zip -Force }
    Say "  正在打包 $zip ..."
    $tar = Join-Path $env:SystemRoot 'System32\tar.exe'
    if (Test-Path $tar) {
      & $tar -a -c -f $zip -C $root '.'
      if ($LASTEXITCODE -ne 0) { Die "打包失败：$zip" }
    } else { Compress-Archive -Path (Join-Path $root '*') -DestinationPath $zip -CompressionLevel Optimal -Force }
    Say ("  压缩包：{0}  ({1:N1} KB)" -f $zip, ((Get-Item $zip).Length / 1KB)) Green
  }
  Say "`n=== 导出完成 ===" Green
  Say "  目录：$root"
  if ($credIncluded) { Say "  ! 包含明文凭据，注意保管，装完请删除压缩包。" Yellow }
  Say ""
}

function Invoke-Install {
  $bundleRoot = if ($BundlePath) { Norm $BundlePath } else { Split-Path $PSCommandPath -Parent }
  if (-not (Test-Path $bundleRoot)) { Die "找不到 bundle：$bundleRoot" }
  if (-not (Get-Item $bundleRoot).PSIsContainer) { $bundleRoot = Expand-BundleZip $bundleRoot }
  $manifestPath = Join-Path $bundleRoot 'manifest.json'
  if (-not (Test-Path $manifestPath)) {
    $inner = Get-ChildItem $bundleRoot -Directory -Force | Where-Object { Test-Path (Join-Path $_.FullName 'manifest.json') } | Select-Object -First 1
    if ($inner) { $bundleRoot = $inner.FullName } else { Die "这个目录里没有 manifest.json，不是本脚本导出的包：$bundleRoot" }
  }
  $manifest = Read-Json $manifestPath
  if ($manifest.kind -ne 'dsh-settings-transfer') { Die "manifest.json 不是设置迁移包（kind=$($manifest.kind)）。" }

  $homeDir = Resolve-DshHome $DshHome
  $targetProfile = if ($PSBoundParameters.ContainsKey('Profile')) { $Profile } else { [string]$manifest.profile }
  $profDir = Join-Path $homeDir "profiles\$targetProfile"
  $payload = Join-Path $bundleRoot 'payload'

  Say "`n=== 安装 DSH 个人设置 ===" Cyan
  Say "  来源机器   : $($manifest.sourceComputer)  ($($manifest.createdAt))"
  Say "  DSH 家目录 : $homeDir"
  Say "  目标 Profile: $targetProfile"
  if ($manifest.credentialsIncluded) { Say "  本包含凭据   : 是（含明文 API key）" Yellow }
  Say ""

  Assert-HarnessClosed
  if (-not (Test-Path $profDir)) { Die "目标机没有这个 Profile：$profDir`n    先启动一次 DeepSeek Harness 创建它，退出后再运行。" }

  # 路径改写表（含源机器用户目录：C:\Users\<源用户> -> 目标机用户目录）
  $srcUser = Get-SourceUserDirs $manifest
  $map = New-Object System.Collections.Generic.List[object]
  $map.Add([pscustomobject]@{ From = [string]$manifest.sourceDshHome; To = $homeDir })
  foreach ($d in @($srcUser.Dirs)) {
    if (-not $d -or ($d -ieq $env:USERPROFILE)) { continue }
    $map.Add([pscustomobject]@{ From = $d; To = $env:USERPROFILE })
    $map.Add([pscustomobject]@{ From = ($d -replace '\\', '\\'); To = ($env:USERPROFILE -replace '\\', '\\') })
  }
  if ($manifest.sourceLocalAppData -and ([string]$manifest.sourceLocalAppData -ine $env:LOCALAPPDATA)) {
    $map.Add([pscustomobject]@{ From = [string]$manifest.sourceLocalAppData; To = $env:LOCALAPPDATA })
    $map.Add([pscustomobject]@{ From = ([string]$manifest.sourceLocalAppData -replace '\\', '\\'); To = ($env:LOCALAPPDATA -replace '\\', '\\') })
  }
  foreach ($r in @($RemapWorkspace)) {
    if ($r -match '^(.+?)=(.+)$') { $map.Add([pscustomobject]@{ From = $Matches[1].Trim(); To = $Matches[2].Trim() }) }
  }

  $bakDir = Join-Path $profDir "transfer-backup-settings-$($script:Stamp)"
  $null = New-Item -ItemType Directory -Force -Path $bakDir
  $restored = New-Object System.Collections.Generic.List[string]

  # profile 层设置
  foreach ($f in @('cordis.patch.yml', 'cordis.yml', 'hub-settings.json')) {
    $src = Join-Path $payload "profile\$f"
    if (-not (Test-Path $src)) { continue }
    if ($KeepTargetCordis -and $f -like 'cordis*') { Say "  ~ 跳过 $f （-KeepTargetCordis）"; continue }
    $dst = Join-Path $profDir $f
    if (Test-Path $dst) { Copy-Item $dst (Join-Path $bakDir $f) -Force }
    Copy-Tree $src $dst
    $restored.Add("profiles\$targetProfile\$f")
  }

  # 家目录设置
  foreach ($rel in @('storages\workspace.json')) {
    $src = Join-Path $payload "settings\$rel"
    if (-not (Test-Path $src)) { continue }
    $dst = Join-Path $homeDir $rel
    if (Test-Path $dst) {
      $parent = Split-Path $rel -Parent
      $null = New-Item -ItemType Directory -Force -Path (Join-Path $bakDir $parent)
      Copy-Item $dst (Join-Path $bakDir $rel) -Force
    }
    Copy-Tree $src $dst
    $restored.Add($rel)
  }

  # 凭据
  $credSrc = Join-Path $payload 'settings\.credentials.yaml'
  if (Test-Path $credSrc) {
    $dst = Join-Path $homeDir '.credentials.yaml'
    if (Test-Path $dst) { Copy-Item $dst (Join-Path $bakDir '.credentials.yaml') -Force }
    Copy-Tree $credSrc $dst
    $restored.Add('.credentials.yaml（含 API key）')
  }

  # 可选数据
  foreach ($pair in @(@('sessions', 'payload\data\sessions'), @('attachments', 'payload\data\attachments'))) {
    $src = Join-Path $bundleRoot $pair[1]
    if (Test-Path $src) {
      $dst = Join-Path $homeDir $pair[0]
      Copy-Tree $src $dst
      $restored.Add("$($pair[0])\ (数据)")
    }
  }

  # 文本里的绝对路径改写
  $textFiles = @()
  $textFiles += Get-ChildItem $profDir -Filter 'cordis*.yml' -File -ErrorAction SilentlyContinue
  $textFiles += Get-ChildItem $profDir -Filter 'hub-settings.json' -File -ErrorAction SilentlyContinue
  $textFiles += Get-ChildItem (Join-Path $homeDir 'storages') -Filter 'workspace.json' -File -ErrorAction SilentlyContinue
  $changed = 0
  foreach ($tf in $textFiles) {
    $text = Get-Content $tf.FullName -Raw -Encoding UTF8
    $orig = $text
    foreach ($m in $map) { if ($m.From) { $text = $text.Replace([string]$m.From, [string]$m.To) } }
    $text = Rewrite-UserDirInText $text $srcUser.Names $env:USERPROFILE
    if ($text -ne $orig) {
      [System.IO.File]::WriteAllText($tf.FullName, $text, (New-Object System.Text.UTF8Encoding($false)))
      $changed++
    }
  }
  if ($changed -gt 0) { Say "  [ok] 已在 $changed 个设置文件里改写本机绝对路径" }

  Say "`n=== 完成 ===" Green
  Say "  已恢复：$($restored -join '、')"
  Say "  备份  ：$bakDir"
  Say "  下一步：重启 DeepSeek Harness；插件请用插件迁移包恢复"
  Say "  回滚  ：把 $bakDir 里的文件复制回原位`n"
}

try {
  if ($Mode -eq 'Export') { Invoke-Export } else { Invoke-Install }
} catch {
  Write-Host "`n[X] 执行失败：$($_.Exception.Message)" -ForegroundColor Red
  Write-Host "    位置：$($_.InvocationInfo.PositionMessage)" -ForegroundColor DarkGray
  Write-Host "    调用栈：$($_.ScriptStackTrace)" -ForegroundColor DarkGray
  exit 1
}
