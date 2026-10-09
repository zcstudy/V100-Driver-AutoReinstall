param(
    [ValidateSet('menu', 'cycle', 'register', 'unregister', 'status', 'dryrun')]
    [string]$Action = 'menu'
)

$ErrorActionPreference = 'Stop'
try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch {}
$script:Interactive = ($Action -eq 'menu')

# ======================= 可调参数 =======================
$Cfg = @{
    DduExe      = 'C:\Program Files\Display Driver Uninstaller\Display Driver Uninstaller.exe'
    DriverExe   = 'D:\qudong\qudong.exe'
    WorkDir     = 'C:\ProgramData\V100Auto'
    BootWaitSec = 120
    MaxCleanTry = 2
    DduArgs     = @('-CleanNvidia', '-Silent', '-NoSafeModeMsg', '-NoRestorePoint', '-PreventWinUpdate')
    InstallArgSets = @(
        @('-s', '-noreboot'),
        @('/silent', '/noreboot'),
        @('-s', '-noreboot', '-clean'),
        @('/silent', '/noreboot', '/express')
    )
    TaskBoot = 'V100DriverBoot'
    TaskLogon = 'V100DriverLogon'
    # 允许计划任务在检测到掉驱动时自己重启一次（DDU 之后必须重启才能装成功）
    # 设为 $false 则不自动重启，改为提示你双击 bat 手动推进流程
    AutoReboot = $true
}
$LogFile   = Join-Path $Cfg.WorkDir 'v100auto.log'
$StateFile = Join-Path $Cfg.WorkDir 'state.json'
$LockFile  = Join-Path $Cfg.WorkDir 'running.lock'

function Log($msg, $color = 'Gray') {
    if (-not (Test-Path $Cfg.WorkDir)) { New-Item -ItemType Directory -Path $Cfg.WorkDir -Force | Out-Null }
    $line = '{0:yyyy-MM-dd HH:mm:ss}  {1}' -f (Get-Date), $msg
    [IO.File]::AppendAllText($LogFile, $line + [Environment]::NewLine, [Text.Encoding]::UTF8)
    Write-Host $line -ForegroundColor $color
}
function Confirm([string]$q) { (Read-Host "$q (Y/N)") -match '^[Yy]' }

function Get-State {
    if (Test-Path $StateFile) {
        try { return (Get-Content $StateFile -Raw -Encoding UTF8 | ConvertFrom-Json) } catch {}
    }
    return [pscustomobject]@{ Phase = 'none'; CleanCount = 0; LastOk = ''; LastResult = '' }
}
function Set-State($s) {
    if (-not (Test-Path $Cfg.WorkDir)) { New-Item -ItemType Directory -Path $Cfg.WorkDir -Force | Out-Null }
    $s | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $StateFile -Encoding UTF8
}

# ======================= 状态判定 =======================
function Test-DriverInstalled {
    $svc = Get-Service -Name 'nvlddmkm' -ErrorAction SilentlyContinue
    if ($svc) { return $true }
    $enum = & pnputil.exe /enum-drivers 2>$null | Out-String
    return ($enum -match '(?m)^Class\s*:\s*Display' -and $enum -match '(?i)nv_disp|NVIDIA')
}
function Test-DriverUsable {
    try {
        $out = & nvidia-smi.exe --query-gpu=name --format=csv,noheader 2>$null
        return ($LASTEXITCODE -eq 0 -and $out)
    } catch { return $false }
}
function Get-GpuView {
    $dev = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue |
        Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' -and $_.FriendlyName -match 'V100|Tesla' }
    if (-not $dev) { $dev = Get-PnpDevice -Class Display -ErrorAction SilentlyContinue | Where-Object { $_.InstanceId -like 'PCI\VEN_10DE*' } }
    $found = [bool]$dev
    $status = 'NoDevice'; $code = $null; $name = ''
    if ($found) {
        $d = @($dev)[0]
        $name = $d.FriendlyName; $status = $d.Status
        $code = (Get-PnpDeviceProperty -InstanceId $d.InstanceId -KeyName 'DEVPKEY_Device_ProblemCode' -ErrorAction SilentlyContinue).Data
    }
    [pscustomobject]@{
        GpuFound      = $found
        GpuName       = $name
        GpuStatus     = $status
        ProblemCode   = $code
        DriverPresent = Test-DriverInstalled
        Usable        = Test-DriverUsable
    }
}
function Describe($g) {
    '设备={0} 状态={1} Code={2} 驱动已安装={3} nvidia-smi可用={4}' -f $g.GpuName, $g.GpuStatus, $g.ProblemCode, $g.DriverPresent, $g.Usable
}

# ======================= 阶段一：DDU 清理 =======================
function Invoke-DduClean {
    if (-not (Test-Path $Cfg.DduExe)) { Log "找不到 DDU：$($Cfg.DduExe)" 'Red'; return $false }
    Log ('DDU 参数: ' + ($Cfg.DduArgs -join ' ')) 'DarkGray'
    Log '开始 DDU 静默清理 ...' 'Yellow'
    $p = Start-Process -FilePath $Cfg.DduExe -ArgumentList $Cfg.DduArgs -PassThru -WindowStyle Minimized
    if (-not $p.WaitForExit(1000 * 60 * 15)) {
        Log 'DDU 15 分钟未退出，强制结束（很可能是无人值守会话里被弹窗卡住）' 'Red'
        Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue
    }
    Start-Sleep -Seconds 12
    if (-not (Test-DriverInstalled)) { Log 'DDU 成功：nvlddmkm 与驱动包已彻底移除' 'Green'; return $true }
    Log 'DDU 之后驱动仍然存在 -> 清理未生效，本次不重启，避免白等一轮' 'Red'
    return $false
}

# ======================= 阶段二：安装驱动（绝不重启） =======================
function Invoke-DriverInstall {
    if (-not (Test-Path $Cfg.DriverExe)) { Log "找不到驱动包：$($Cfg.DriverExe)" 'Red'; return $false }
    foreach ($set in $Cfg.InstallArgSets) {
        $argLine = $set -join ' '
        Log "尝试：qudong.exe $argLine" 'Yellow'
        $p = Start-Process -FilePath $Cfg.DriverExe -ArgumentList $argLine -PassThru -WindowStyle Minimized
        if (-not $p.WaitForExit(1000 * 60 * 25)) {
            Log '安装器 25 分钟未返回，再等 5 分钟' 'DarkGray'
            if (-not $p.WaitForExit(1000 * 60 * 5)) { Log '仍未退出，强制结束' 'Red'; Stop-Process -Id $p.Id -Force -ErrorAction SilentlyContinue }
        }
        Log "安装器退出码 = $($p.ExitCode)" 'Gray'
        for ($i = 0; $i -lt 8; $i++) {
            Start-Sleep -Seconds 20
            $g = Get-GpuView
            if ($g.DriverPresent -and ($g.GpuStatus -eq 'OK' -or $g.Usable)) {
                Log ('安装成功（参数：' + $argLine + '）  ' + (Describe $g)) 'Green'
                return $true
            }
        }
        Log ('参数 [' + $argLine + '] 之后仍未可用：' + (Describe (Get-GpuView))) 'Red'
    }
    Log '全部静默参数都试过，未达到可用状态。' 'Red'
    return $false
}

function Request-RebootForNextPhase {
    Log '你的 ritual 要求：DDU 之后必须重启一次再装驱动。' 'Magenta'
    Log '（这是全流程中唯一一次重启；装完驱动绝不会重启）' 'DarkGray'
    if (-not $Cfg.AutoReboot) {
        Log 'AutoReboot=$false：不自动重启。请在方便时双击桌面的 bat，用菜单 [1] 推进到装驱动阶段。' 'Yellow'
        return
    }
    if ($script:Interactive) {
        if (-not (Confirm '现在要重启吗？')) { Log '你取消了重启。状态保持 awaiting-install，下次开机/登录会自动继续装驱动。' 'Yellow'; return }
        $sec = 60
    } else { $sec = 15 }
    Log ("$sec 秒后重启 ...") 'Yellow'
    shutdown.exe /r /t $sec /c 'V100自动流程：DDU清理后重启准备装驱动' /f
}

# ======================= 状态机 =======================
function Invoke-Cycle {
    if (Test-Path $LockFile) {
        $age = ((Get-Date) - (Get-Item $LockFile).LastWriteTime).TotalMinutes
        if ($age -lt 45) { Log ('已有实例在运行（' + [math]::Round($age, 1) + ' 分钟前上锁），本次跳过') 'DarkGray'; return }
        Log '发现残留锁（上次可能被打断），清除后继续' 'DarkGray'
    }
    Set-Content -LiteralPath $LockFile -Value (Get-Date).ToString('o') -Encoding ASCII
    try {
        Log '============= 一轮检测开始 =============' 'Cyan'
        $st = Get-State
        $g = Get-GpuView
        Log (Describe $g) 'White'

        if (-not $g.GpuFound) {
            Log 'PCIe 上枚举不到 V100，脚本无能为力（查插槽/供电/Above 4G Decoding）。不做任何卸载或安装。' 'Red'
            $st.LastResult = 'gpu-missing'; Set-State $st; return
        }

        if ($g.DriverPresent -and $g.GpuStatus -eq 'OK' -and $g.Usable) {
            Log 'V100 正常，什么都不做。' 'Green'
            $st.Phase = 'ok'; $st.CleanCount = 0; $st.LastOk = (Get-Date).ToString('g'); $st.LastResult = 'healthy'
            Set-State $st; return
        }

        if (-not $g.DriverPresent) {
            Log '当前无 NVIDIA 驱动 -> 进入安装阶段（不重启）' 'Yellow'
            $st.Phase = 'installing'; Set-State $st
            $ok = Invoke-DriverInstall
            $st.Phase = 'idle'
            if ($ok) { $st.CleanCount = 0; $st.LastOk = (Get-Date).ToString('g'); $st.LastResult = 'installed-ok' }
            else { $st.LastResult = 'install-failed' }
            Set-State $st
            Log $(if ($ok) { '驱动安装完成，未执行任何重启。' } else { '安装失败，已停止自动动作，等待人工处理。' }) $(if ($ok) { 'Green' } else { 'Red' })
            return
        }

        # 驱动在 + 不正常 -> 清理 + 重启
        if ($st.CleanCount -ge $Cfg.MaxCleanTry) {
            Log ('已达到最大自动清理+重启次数（' + $Cfg.MaxCleanTry + '），拦截本次重启，防止无限重启。') 'Red'
            Log '菜单里用 [8] 复位计数，或 [1] 手动跑一轮。' 'DarkGray'
            $st.LastResult = 'loop-guard'; Set-State $st; return
        }
        Log '驱动存在但 V100 未被识别 -> 进入清理阶段' 'Yellow'
        $st.CleanCount = $st.CleanCount + 1
        $st.Phase = 'cleaning'; Set-State $st
        if (Invoke-DduClean) {
            $st.Phase = 'awaiting-install'; $st.LastResult = 'cleaned-await-install'; Set-State $st
            Request-RebootForNextPhase
        } else {
            $st.Phase = 'idle'; $st.LastResult = 'clean-failed'; Set-State $st
        }
    } finally {
        Remove-Item -LiteralPath $LockFile -Force -ErrorAction SilentlyContinue
    }
}

# ======================= 计划任务 =======================
function Get-PersistedPs1 {
    $dir = Join-Path $Cfg.WorkDir 'bin'
    if (-not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $dst = Join-Path $dir '_v100_auto_core.ps1'
    Copy-Item -LiteralPath $PSCommandPath -Destination $dst -Force
    return $dst
}
function Install-Tasks {
    $ps1 = Get-PersistedPs1
    $cmd = 'powershell.exe'
    $arg = '-NoProfile -ExecutionPolicy Bypass -File "{0}" -Action cycle' -f $ps1
    Log "任务将执行: $cmd $arg" 'Gray'

    $setting = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -ExecutionTimeLimit (New-TimeSpan -Hours 2) -Priority 6
    try { $setting.Hidden = $true } catch {}

    $bt = New-CimInstance -CimClass (Get-CimClass -Namespace 'Root/Microsoft/Windows/TaskScheduler' -ClassName 'MSFT_TaskBootTrigger') -ClientOnly
    $bt.Delay = 'PT{0}M' -f [math]::Ceiling($Cfg.BootWaitSec / 60)

    Unregister-ScheduledTask -TaskName $Cfg.TaskBoot -Confirm:$false -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $Cfg.TaskLogon -Confirm:$false -ErrorAction SilentlyContinue

    Register-ScheduledTask -TaskName $Cfg.TaskBoot -TaskPath '\V100Auto\' `
        -Action (New-ScheduledTaskAction -Execute $cmd -Argument $arg) `
        -Trigger $bt -Settings $setting -User 'SYSTEM' -RunLevel Highest | Out-Null
    Log "已注册 $($Cfg.TaskBoot)：开机延迟 $($Cfg.BootWaitSec)s，SYSTEM 身份" 'Green'

    $lt = New-ScheduledTaskTrigger -AtLogOn
    Register-ScheduledTask -TaskName $Cfg.TaskLogon -TaskPath '\V100Auto\' `
        -Action (New-ScheduledTaskAction -Execute $cmd -Argument $arg) `
        -Trigger $lt -Settings $setting -User $env:USERNAME -RunLevel Highest | Out-Null
    Log "已注册 $($Cfg.TaskLogon)：你登录时补跑一次，用于 DDU 在纯 SYSTEM 会话下可能被弹窗卡住的情况" 'Green'
    Log '以后修改本工具，必须重新点 [3] 更新持久副本。' 'DarkYellow'
}
function Remove-Tasks {
    foreach ($n in @($Cfg.TaskBoot, $Cfg.TaskLogon)) {
        Unregister-ScheduledTask -TaskName $n -Confirm:$false -ErrorAction SilentlyContinue
        Log "已删除任务 $n" 'Green'
    }
}

# ======================= 状态 / 干跑 =======================
function Show-Status {
    Log '================ 当前状态 ================' 'Cyan'
    Log (Describe (Get-GpuView)) 'White'
    $st = Get-State
    Log ('state.json: Phase={0} CleanCount={1} LastOk={2} LastResult={3}' -f $st.Phase, $st.CleanCount, $st.LastOk, $st.LastResult) 'White'
    Log '---- 计划任务 ----' 'Cyan'
    foreach ($n in @($Cfg.TaskBoot, $Cfg.TaskLogon)) {
        $t = Get-ScheduledTask -TaskName $n -ErrorAction SilentlyContinue
        if ($t) { Log ("{0}  状态={1}" -f $n, $t.State) 'Green' } else { Log "$n 未注册" 'DarkGray' }
    }
    Log '---- 最近 30 行日志 ----' 'Cyan'
    if (Test-Path $LogFile) { Get-Content $LogFile -Encoding UTF8 -Tail 30 | ForEach-Object { Write-Host $_ } } else { Log '暂无日志' 'DarkGray' }
}
function Show-DryRun {
    Log '=========== 干跑：只判断，不动系统 ===========' 'Cyan'
    $st = Get-State; $g = Get-GpuView
    Log (Describe $g) 'White'
    $plan = if (-not $g.GpuFound) { '不动：找不到 V100 设备' }
    elseif ($g.DriverPresent -and $g.GpuStatus -eq 'OK' -and $g.Usable) { '不动：当前健康' }
    elseif (-not $g.DriverPresent) { '将安装 D:\qudong\qudong.exe（静默、绝不重启）' }
    elseif ($st.CleanCount -ge $Cfg.MaxCleanTry) { '本应 DDU+重启，但被最大次数拦截（需菜单 8 复位）' }
    else { '将执行 DDU 静默清理 -> 重启一次 -> 下次开机自动装驱动' }
    Log "决定: $plan" 'Green'
}

# ======================= 菜单 =======================
function Show-Menu {
    Write-Host ''
    Write-Host '  [1] 立即跑一轮状态机（先手动验证整个流程，推荐）'
    Write-Host '  [2] 干跑：只看它会做什么'
    Write-Host '  [3] 注册/更新计划任务（开机 + 登录）'
    Write-Host '  [4] 删除计划任务'
    Write-Host '  [5] 查看状态 + 任务 + 日志'
    Write-Host '  [6] 单独测试 DDU 静默清理（真的会卸掉驱动）'
    Write-Host '  [7] 单独测试静默安装驱动'
    Write-Host '  [8] 复位清理/重启计数'
    Write-Host '  [Q] 退出'
    $c = (Read-Host '  选择').Trim().ToUpper()
    switch ($c) {
        '1' { Invoke-Cycle }
        '2' { Show-DryRun }
        '3' { Install-Tasks }
        '4' { Remove-Tasks }
        '5' { Show-Status }
        '6' { if (Confirm '确认用 DDU 卸载 V100 驱动?') { Invoke-DduClean | Out-Null } }
        '7' { if (Confirm '确认运行静默安装?') { Invoke-DriverInstall | Out-Null } }
        '8' { $s = Get-State; $s.CleanCount = 0; $s.Phase = 'idle'; Set-State $s; Log '计数已复位' 'Green' }
        'Q' { Write-Host '退出。'; return }
        default { Write-Host '无效输入' -ForegroundColor DarkGray }
    }
    Show-Menu
}

# ======================= 入口 =======================
if (-not (Test-Path $Cfg.WorkDir)) { New-Item -ItemType Directory -Path $Cfg.WorkDir -Force | Out-Null }
switch ($Action) {
    'cycle'      { Invoke-Cycle }
    'register'   { Install-Tasks }
    'unregister' { Remove-Tasks }
    'status'     { Show-Status }
    'dryrun'     { Show-DryRun }
    default      {
        Write-Host 'V100 驱动自动重装工具' -ForegroundColor Magenta
        Write-Host ('流程：检测到掉驱动 -> DDU 静默清理 -> 重启 -> 静默装 D:\qudong\qudong.exe -> 不重启') -ForegroundColor DarkYellow
        Write-Host ('日志: ' + $LogFile)
        Show-Menu
    }
}
