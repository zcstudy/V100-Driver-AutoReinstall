@echo off
chcp 65001 >nul
setlocal EnableExtensions
title V100 驱动自动重装工具

net session >nul 2>&1
if errorlevel 1 (
    echo 正在申请管理员权限，请在弹窗中点“是”...
    powershell -NoProfile -Command "Start-Process -FilePath '%~f0' -Verb RunAs"
    exit /b
)

set "SRC=%~dp0_v100_auto_core.ps1"
set "RUN=%TEMP%\_v100_auto_core.ps1"

if not exist "%SRC%" (
    echo [错误] 桌面上缺少 _v100_auto_core.ps1
    echo 这个 bat 和 ps1 必须放在同一个目录。
    pause
    exit /b 1
)

rem 把 UTF-8 源转成 UTF-16，否则 Windows PowerShell 5.1 读中文是乱码
powershell -NoProfile -Command "$t = Get-Content -LiteralPath '%SRC%' -Raw -Encoding UTF8; [IO.File]::WriteAllText('%RUN%', $t, [Text.Encoding]::Unicode)"

powershell -NoProfile -ExecutionPolicy Bypass -File "%RUN%"

pause
