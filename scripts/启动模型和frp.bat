@echo off
chcp 936 >nul
setlocal enabledelayedexpansion
title 启动模型 + frp（含 V100 自检）

REM ============================================================
REM  一键启动：llama.cpp 模型服务 + frp 公网隧道
REM  位置：桌面，双击即用
REM
REM  带 V100 自检。原因：llama-server 在 CUDA 初始化失败时不报错，
REM  会静默回退 CPU（实测 0.745 tok/s，而 GPU 上是 110+），
REM  双击完根本看不出来。所以本脚本读显存占用来判断服务跑在哪，
REM  检测到「跑在 CPU 上的坏实例」时自动重启它。
REM
REM  注意：读显存走临时文件 + 纯数字校验。
REM  不能写成 for /f (... 2^>nul)，本机实测那个转义会坏掉，
REM  nvidia-smi 会把 "2>nul" 当参数并吐回 "ERROR:"，
REM  导致误判成「没上卡」→ 把正常服务杀掉重启。
REM
REM  编码：GBK + CRLF（cmd 在 936 代码页下解析）
REM ============================================================

set "ROOT=D:\llamacpp"
set "FRPDIR=D:\llamacpp\frp"
set "PORT=8080"
set "VRAMFILE=%TEMP%\_llama_vram.txt"

echo ==================================================
echo    启动  llama.cpp 模型服务  +  frp 公网隧道
echo    （含 V100 自检）
echo ==================================================
echo.

if not exist "%ROOT%\start-llama-server.bat" (
    echo [错误] 找不到 %ROOT%\start-llama-server.bat
    goto :end
)
if not exist "%FRPDIR%\frpc.exe" (
    echo [错误] 找不到 %FRPDIR%\frpc.exe
    goto :end
)

REM ==================== 1) 模型服务 ====================
set "UP=0"
for /f "tokens=*" %%A in ('netstat -ano ^| findstr ":!PORT! " ^| findstr "LISTENING"') do set "UP=1"

if "!UP!"=="1" goto :model_running

:start_model
echo [模型] 正在启动 llama-server ...
call "%ROOT%\start-llama-server.bat"
echo [模型] 等待加载到显存（最多 180 秒，一个点约 5 秒）
call :waitgpu
echo.
if "!GPUOK!"=="1" (
    echo [模型] OK - 已加载到 V100，显存占用 !VRAM! MiB
) else (
    echo [模型] 注意：180 秒内未检测到显存占用。
    echo         可能仍在加载，也可能回退到了 CPU。
    echo         请查看 %ROOT%\llama-server.log 确认。
)
goto :frp

:model_running
call :getvram
if "!VRAMOK!"=="0" (
    echo [模型] 端口 %PORT% 已被占用，但读不到显存（nvidia-smi 异常）。
    echo         跳过 GPU 自检，本次不做重启。
    goto :frp
)
set /a "ONG=VRAM/10000"
if !ONG! GEQ 1 (
    echo [模型] 已在运行，且确实在 V100 上（显存 !VRAM! MiB），跳过
    goto :frp
)
echo [模型] 8080 有服务，但显存只占 !VRAM! MiB
echo [模型] 说明它跑在 CPU 上（启动时 CUDA 初始化失败），正在重启 ...
taskkill /f /im llama-server.exe >nul 2>&1
call :waitport
goto :start_model

REM ==================== 2) frp 隧道 ====================
:frp
set "FRPUP=0"
tasklist /nh /fi "imagename eq frpc.exe" 2>nul | findstr /i /c:"frpc.exe" >nul
if not errorlevel 1 set "FRPUP=1"

if "!FRPUP!"=="1" (
    echo [frp ] frpc.exe 已在运行，跳过
) else (
    echo [frp ] 正在启动 frpc 隧道 ...
    start "frpc" /min /d "%FRPDIR%" cmd /c "frpc.exe -c frpc.toml"
    echo [frp ] frpc 已在后台启动
)

echo.
echo --------------------------------------------------
echo   本机 API : http://127.0.0.1:%PORT%/v1
echo   外网 API : http://47.119.167.86:%PORT%/v1
echo   模型日志 : %ROOT%\llama-server.log
echo   隧道日志 : %FRPDIR%\frpc.log
echo --------------------------------------------------

:end
echo.
echo 窗口 20 秒后自动关闭。
timeout /t 20 >nul 2>&1
exit /b 0

REM ==================== 子过程 ====================

REM 读显存。走临时文件，避免 for /f 内联重定向的转义问题。
REM 只有读到纯数字才置 VRAMOK=1；否则调用方必须跳过自检。
:getvram
set "VRAM=0"
set "VRAMOK=0"
nvidia-smi --query-gpu=memory.used --format=csv,noheader,nounits > "%VRAMFILE%" 2>nul
if exist "%VRAMFILE%" (
    for /f "usebackq tokens=1" %%M in ("%VRAMFILE%") do set "VRAM=%%M"
    del "%VRAMFILE%" >nul 2>&1
)
echo !VRAM!| findstr /r "^[0-9][0-9]*$" >nul
if not errorlevel 1 set "VRAMOK=1"
exit /b 0

:waitgpu
set "GPUOK=0"
set /a "N=0"
:waitgpu_loop
call :getvram
if "!VRAMOK!"=="1" (
    set /a "T=VRAM/10000"
    if !T! GEQ 1 (
        set "GPUOK=1"
        exit /b 0
    )
)
set /a "N+=1"
if !N! GEQ 36 exit /b 0
<nul set /p "=."
ping -n 6 127.0.0.1 >nul
goto :waitgpu_loop

:waitport
for /l %%I in (1,1,15) do (
    set "UP2=0"
    for /f "tokens=*" %%A in ('netstat -ano ^| findstr ":!PORT! " ^| findstr "LISTENING"') do set "UP2=1"
    if "!UP2!"=="0" exit /b 0
    ping -n 3 127.0.0.1 >nul
)
exit /b 0
