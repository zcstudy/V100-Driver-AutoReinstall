@echo off
chcp 936 >nul
setlocal enabledelayedexpansion
title 查看/切换 llama.cpp 当前运行的模型

echo ==================================================
echo    llama.cpp - 当前实际在用哪个模型？
echo ==================================================
echo.

REM ---- 1) 读取 llama-server.exe 进程的真实命令行 ----
set "CL="
for /f "skip=1 delims=" %%L in ('wmic process where "name='llama-server.exe'" get commandline 2^>nul') do (
    if not defined CL set "CL=%%L"
)

if not defined CL goto :notrunning

echo [状态] llama-server.exe 正在运行。
echo.

REM ---- 2) 从命令行中提取模型文件和视觉文件 ----
set "NEXTM=0"
set "NEXTV=0"
set "MODEL=?"
set "MMPROJ=?"
for %%T in (!CL!) do (
    if "!NEXTM!"=="1" (
        set "MODEL=%%T"
        set "NEXTM=0"
    )
    if /i "%%T"=="-m" set "NEXTM=1"
    if "!NEXTV!"=="1" (
        set "MMPROJ=%%T"
        set "NEXTV=0"
    )
    if /i "%%T"=="--mmproj" set "NEXTV=1"
)

echo [模型文件] !MODEL!
echo [视觉文件] !MMPROJ!
echo.

REM ---- 3) 自动判定当前跑的是哪个版本 ----
set "VERDICT=未知模型，请人工核对上面的文件名。"
echo !MODEL! | findstr /i "uncensored-heretic" >nul && set "VERDICT=当前在跑 SC117 heretic 去审查版（startuncensored）"
echo !MODEL! | findstr /i "Claude-4.7" >nul && set "VERDICT=当前在跑 Claude-4.7-Opus 蒸馏版（startQwen3.6-35B-A3B-Claude-4.7）"
echo [结论] !VERDICT!
echo.

REM ---- 4) 查询对外别名（客户端看到的名称） ----
curl -s -H "Authorization: Bearer sk-v100-4c67fe384726108334d65b2281e85fdb" http://127.0.0.1:8080/v1/models > "%TEMP%\_llama_models.json" 2>nul
set "ALIAS="
for /f "usebackq tokens=5 delims=:," %%A in (`findstr /i "id" "%TEMP%\_llama_models.json" 2^>nul`) do (
    if not defined ALIAS set "ALIAS=%%A"
)
if defined ALIAS set ALIAS=!ALIAS:"=!
if defined ALIAS echo [对外别名] !ALIAS!  ——  客户端在 /v1/models 里看到的就是它
if not defined ALIAS echo [对外别名] 无法查询 127.0.0.1:8080，服务可能仍在加载中。
echo.

REM ---- 5) 询问是否切换模型 ----
echo --------------------------------------------------
echo    可切换的模型列表：
echo      [1] Claude-4.7-Opus 蒸馏版（现款，17GB）
echo      [2] SC117 heretic 去审查版（新，15.85GB）
echo      [0] 不切换，直接退出
echo --------------------------------------------------
choice /c 120 /n /m "请按键选择: "
if errorlevel 3 goto :no_switch
if errorlevel 2 goto :sw_uncensored
goto :sw_claude

:sw_claude
echo.
echo [切换] 正在停止当前 llama-server ...
taskkill /f /im llama-server.exe >nul 2>&1
echo [切换] 等待端口 8080 和显存释放 ...
set /a W=0
:waitloop_claude
timeout /t 2 /nobreak >nul
netstat -ano | findstr "LISTENING" | findstr ":8080 " >nul
if not errorlevel 1 (
    set /a W+=1
    if !W! lss 11 goto :waitloop_claude
)
timeout /t 5 /nobreak >nul
echo [切换] 正在启动 Claude-4.7 蒸馏版（新窗口，加载约 30-120 秒）...
start "" "D:\llamacpp\startQwen3.6-35B-A3B-Claude-4.7\start-claude47.bat"
echo [完成] 已发送启动指令。稍后可再次双击本脚本确认切换结果。
goto :endask

:sw_uncensored
echo.
echo [切换] 正在停止当前 llama-server ...
taskkill /f /im llama-server.exe >nul 2>&1
echo [切换] 等待端口 8080 和显存释放 ...
set /a W=0
:waitloop_un
timeout /t 2 /nobreak >nul
netstat -ano | findstr "LISTENING" | findstr ":8080 " >nul
if not errorlevel 1 (
    set /a W+=1
    if !W! lss 11 goto :waitloop_un
)
timeout /t 5 /nobreak >nul
echo [切换] 正在启动 SC117 heretic 去审查版（新窗口，加载约 30-120 秒）...
start "" "D:\llamacpp\startuncensored\start-uncensored.bat"
echo [完成] 已发送启动指令。稍后可再次双击本脚本确认切换结果。
goto :endask

:no_switch
echo.
echo [退出] 已取消，当前模型保持不变。

:endask
echo.
pause
exit /b 0

:notrunning
echo [结果] llama-server.exe 未在运行 —— 当前没有任何模型对外服务。
echo.
echo    可直接启动：
echo      [1] Claude-4.7-Opus 蒸馏版
echo      [2] SC117 heretic 去审查版
echo      [0] 退出
echo --------------------------------------------------
choice /c 120 /n /m "请按键选择: "
if errorlevel 3 goto :no_switch
if errorlevel 2 goto :sw_uncensored
goto :sw_claude
