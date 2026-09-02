# ===============================================================================
#  Скрипт: CreateShortcuts.ps1
#  Назначение: Создание ярлыков в shell:sendto (меню "Отправить") для передачи
#              файлов через FileTransfer.ps1.
#
#  Ярлыки:
#   SEND FILE         -> powershell ... FileTransfer.ps1 Pack      (быстрая отправка)
#   RECEIVE FILE      -> powershell ... FileTransfer.ps1 UnpackTo  (приём в папку)
#   SEND FILE (auto)  -> powershell ... FileTransfer.ps1 PackAuto  (отправка с ACK)
#
#  Запуск: powershell -NoProfile -ExecutionPolicy Bypass -File CreateShortcuts.ps1
# ===============================================================================

$ErrorActionPreference = "Stop"

$SendTo     = [Environment]::GetFolderPath('SendTo')
$PowerShell = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
$ScriptPath = "C:\CHANGE\FileTransfer.ps1"

if (-not (Test-Path $PowerShell)) {
    Write-Host "ОШИБКА: не найден $PowerShell" -ForegroundColor Red
    pause
    exit 1
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

Write-Host "`nГотово! Ярлыки находятся в: $SendTo" -ForegroundColor Cyan
pause
