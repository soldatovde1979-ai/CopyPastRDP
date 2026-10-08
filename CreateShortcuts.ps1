# ===============================================================================
#  Скрипт: CreateShortcuts.ps1
#  Назначение: Создание ярлыков в shell:sendto (меню "Отправить") для передачи
#              файлов через FileTransfer.ps1, а также ярлыка "СЛУШАТЕЛЬ"
#              в Автозагрузке (shell:startup) для фонового приёма Watch.
#
#  Ярлыки (shell:sendto):
#   SEND FILE         -> powershell ... FileTransfer.ps1 Pack      (быстрая отправка)
#   RECEIVE FILE      -> powershell ... FileTransfer.ps1 UnpackTo  (приём в папку)
#   SEND FILE (auto)  -> powershell ... FileTransfer.ps1 PackAuto  (отправка с ACK)
#
#  Автозагрузка (shell:startup):
#   СЛУШАТЕЛЬ         -> powershell -WindowStyle Hidden ... Watch  (фоновый приём)
#
#  Для синхронизации папок между контурами (DiskSyncEnabled=1 в setcp.ini)
#  и для keep-alive RDP-сеанса (KeepAliveMinutes) слушатель должен быть запущен
#  на ОБОИХ контурах — выполните этот скрипт на каждом из них.
#
#  Существующие ярлыки перезаписываются молча (без запросов подтверждения).
#
#  Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File CreateShortcuts.ps1
# ===============================================================================

param(
    # Каталог установки (передаётся из Install.ps1). Если FileTransfer.ps1
    # здесь не найден, берётся копия рядом с этим скриптом.
    [string]$Destination = "C:\CHANGE"
)

$ErrorActionPreference = "Stop"

$SendTo     = [Environment]::GetFolderPath('SendTo')
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$ScriptPath = Join-Path $Destination "FileTransfer.ps1"

if (-not (Test-Path $PowerShell)) {
    Write-Host "ОШИБКА: не найден $PowerShell" -ForegroundColor Red
    pause
    exit 1
}

if (-not (Test-Path $ScriptPath)) {
    # Фолбэк: скрипт лежит рядом с CreateShortcuts.ps1
    $nearby = Join-Path $PSScriptRoot "FileTransfer.ps1"
    if (Test-Path $nearby) { $ScriptPath = $nearby }
}

if (-not (Test-Path $ScriptPath)) {
    Write-Host "ПРЕДУПРЕЖДЕНИЕ: $ScriptPath не найден." -ForegroundColor Yellow
    Write-Host "Сначала выполните Install.ps1, затем запустите этот скрипт повторно." -ForegroundColor Yellow
}

# ===== 1. Очистка старых ярлыков FileTransfer из SendTo =====
Get-ChildItem -Path $SendTo -Filter "*.lnk" | ForEach-Object {
    $lnkPath = $_.FullName
    try {
        $sh     = New-Object -ComObject WScript.Shell
        $target = $sh.CreateShortcut($lnkPath)
        if ($target.Arguments -like "*FileTransfer.ps1*") {
            Remove-Item $lnkPath -Force
            Write-Host "Удалён старый ярлык: $($_.Name)" -ForegroundColor DarkGray
        }
    } catch {}
}

# ===== 1.1 Очистка старых ярлыков FileTransfer из Автозагрузки =====
$Startup = [Environment]::GetFolderPath('Startup')
if (-not (Test-Path $Startup)) { New-Item -ItemType Directory -Path $Startup -Force | Out-Null }
Get-ChildItem -Path $Startup -Filter "*.lnk" | ForEach-Object {
    $lnkPath = $_.FullName
    try {
        $sh     = New-Object -ComObject WScript.Shell
        $target = $sh.CreateShortcut($lnkPath)
        if ($target.Arguments -like "*FileTransfer.ps1*") {
            Remove-Item $lnkPath -Force
            Write-Host "Удалён старый ярлык: $($_.Name)" -ForegroundColor DarkGray
        }
    } catch {}
}

# ===== 2. Создание ярлыков =====
$shortcuts = [ordered]@{
    "SEND FILE"        = "Pack"
    "RECEIVE FILE"     = "UnpackTo"
    "SEND FILE (auto)" = "PackAuto"
    # "SEND FILE (no chank)" = "PackNoChunk"   # <-- режим ещё НЕ реализован в FileTransfer.ps1
}

$shell = New-Object -ComObject WScript.Shell

foreach ($name in $shortcuts.Keys) {
    $mode = $shortcuts[$name]
    $path = Join-Path $SendTo "$name.lnk"

    $lnk = $shell.CreateShortcut($path)
    $lnk.TargetPath       = $PowerShell
    $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -File `"$ScriptPath`" $mode"
    $lnk.WorkingDirectory = "C:\CHANGE"
    $lnk.WindowStyle      = 7
    $lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,45"
    $lnk.Description      = "FileTransfer: $name ($mode)"
    $lnk.Save()

    Write-Host "Создан ярлык: $name -> FileTransfer.ps1 $mode" -ForegroundColor Green
}

# ===== 3. Ярлык «СЛУШАТЕЛЬ» в Автозагрузку (фоновый приём Watch) =====
$listenerPath = Join-Path $Startup "СЛУШАТЕЛЬ.lnk"
$listenerVerb = if (Test-Path $listenerPath) { "Перезаписан ярлык" } else { "Создан ярлык" }

$lnk = $shell.CreateShortcut($listenerPath)
$lnk.TargetPath       = $PowerShell
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" Watch"
$lnk.WorkingDirectory = "C:\CHANGE"
$lnk.WindowStyle      = 7
$lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,45"
$lnk.Description      = "FileTransfer: СЛУШАТЕЛЬ (фоновый приём, Watch)"
$lnk.Save()

Write-Host "$listenerVerb : СЛУШАТЕЛЬ -> FileTransfer.ps1 Watch (Автозагрузка)" -ForegroundColor Green

# ===== 4. Дашборд (веб-панель http://localhost:8123) в Автозагрузку =====
$dashPath  = Join-Path $Startup "CopyPast Дашборд.lnk"
$dashVerb  = if (Test-Path $dashPath) { "Перезаписан ярлык" } else { "Создан ярлык" }
$lnk = $shell.CreateShortcut($dashPath)
$lnk.TargetPath       = $PowerShell
$lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`" Web"
$lnk.WorkingDirectory = $Destination
$lnk.WindowStyle      = 7
$lnk.IconLocation     = "$env:SystemRoot\System32\shell32.dll,44"
$lnk.Description      = "CopyPast: веб-дашборд http://localhost:8123"
$lnk.Save()
Write-Host "$dashVerb : CopyPast Дашборд -> FileTransfer.ps1 Web (Автозагрузка)" -ForegroundColor Green

Write-Host "`nГотово! Ярлыки находятся в: $SendTo" -ForegroundColor Cyan
Write-Host "Слушатель в Автозагрузке: $listenerPath" -ForegroundColor Cyan
