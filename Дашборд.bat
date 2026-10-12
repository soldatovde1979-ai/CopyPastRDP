@echo off
rem =============================================================
rem  Zapusk web-dashborda CopyPast (http://localhost:8123).
rem  Esli skrytyy protsess Web eshe ne rabotaet - startuet ego,
rem  zatem otkryvaet dashbord v brauzere po umolchaniyu.
rem  Skript beretsya iz C:\CHANGE\FileTransfer.ps1 (Install.ps1).
rem  ============================================================
rem  VNIMANIE: kommentari tolko ASCII - cmd chitaet bat v OEM-866,
rem  UTF-8 kirillica v kommentariyakh lomaet parsing.
rem =============================================================
setlocal
set "PS=%SystemRoot%\System32\WindowsPowerShell\v1.0\powershell.exe"
set "SCRIPT=C:\CHANGE\FileTransfer.ps1"

if not exist "%SCRIPT%" (
    echo File %SCRIPT% not found - run Install.ps1 first
    pause
    exit /b 1
)

"%PS%" -NoProfile -ExecutionPolicy Bypass -Command "if (@(Get-CimInstance Win32_Process -Filter \"Name='powershell.exe' OR Name='pwsh.exe'\" | Where-Object { $PSItem.CommandLine -like '*-File*FileTransfer.ps1*Web*' }).Count -eq 0) { Start-Process -FilePath '%PS%' -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-WindowStyle','Hidden','-File','%SCRIPT%','Web' -WindowStyle Hidden; Start-Sleep -Milliseconds 800 }"

start "" http://localhost:8123/
