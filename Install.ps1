# ===============================================================================
#  Скрипт: Install.ps1
#  Назначение: Копирование FileTransfer.ps1 в C:\CHANGE (исходник в репозитории
#              остаётся), копирование setcp.ini, создание рабочих папок,
#              запуск CreateShortcuts.ps1 (если он лежит рядом) и ПЕРЕЗАПУСК
#              фонового СЛУШАТЕЛЯ (Watch), чтобы обновлённый код сразу заработал.
#
#  Запуск:     powershell -NoProfile -ExecutionPolicy Bypass -File Install.ps1
# ===============================================================================

param(
    [string]$Destination = "C:\CHANGE"
)

$ErrorActionPreference = "Stop"
$HasError = $false

function Write-Step([string]$Message, [string]$Color = "White") {
    Write-Host $Message -ForegroundColor $Color
}

# ===== 1. Поиск FileTransfer.ps1 рядом со скриптом установки =====
$sourceScript = Join-Path $PSScriptRoot "FileTransfer.ps1"

if (-not (Test-Path $sourceScript -PathType Leaf)) {
    Write-Step "ОШИБКА: FileTransfer.ps1 не найден рядом с Install.ps1 ($PSScriptRoot)!" "Red"
    Write-Step "Положите Install.ps1 в одну папку с FileTransfer.ps1 и запустите заново." "Yellow"
    pause
    exit 1
}

# ===== 2. Создание структуры C:\CHANGE =====
foreach ($dir in @($Destination, "$Destination\IN", "$Destination\OUT")) {
    if (-not (Test-Path $dir)) {
        try {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
            Write-Step "Создана папка: $dir" "Green"
        } catch {
            Write-Step "ОШИБКА: не удалось создать $dir - $($_.Exception.Message)" "Red"
            $HasError = $true
        }
    }
}

if ($HasError) {
    pause
    exit 1
}

# ===== 3. Копирование FileTransfer.ps1 в C:\CHANGE =====
# Копируем, а не перемещаем: исходник должен остаться в папке проекта/git-репозитория.
$targetScript = Join-Path $Destination "FileTransfer.ps1"
$srcFull  = [System.IO.Path]::GetFullPath($sourceScript)
$dstFull  = [System.IO.Path]::GetFullPath($targetScript)

if ($srcFull -ieq $dstFull) {
    Write-Step "FileTransfer.ps1 уже находится в $Destination - копирование не требуется." "Yellow"
} else {
    try {
        Copy-Item -Path $sourceScript -Destination $targetScript -Force
        Write-Step "FileTransfer.ps1 скопирован: $sourceScript -> $targetScript" "Green"
    } catch {
        Write-Step "ОШИБКА: не удалось скопировать FileTransfer.ps1 - $($_.Exception.Message)" "Red"
        pause
        exit 1
    }
}

# ===== 3.1 Копирование настроечного файла setcp.ini =====
$iniSource = Join-Path $PSScriptRoot "setcp.ini"
$iniTarget = Join-Path $Destination "setcp.ini"

if (-not (Test-Path $iniSource -PathType Leaf)) {
    Write-Step "ПРИМЕЧАНИЕ: setcp.ini не найден рядом - будут использованы настройки по умолчанию." "Yellow"
} elseif ([System.IO.Path]::GetFullPath($iniSource) -ieq [System.IO.Path]::GetFullPath($iniTarget)) {
    Write-Step "setcp.ini уже находится в $Destination - копирование не требуется." "Yellow"
} else {
    try {
        Copy-Item -Path $iniSource -Destination $iniTarget -Force
        Write-Step "setcp.ini скопирован: $iniSource -> $iniTarget" "Green"
    } catch {
        Write-Step "ПРЕДУПРЕЖДЕНИЕ: не удалось скопировать setcp.ini - $($_.Exception.Message)" "Yellow"
    }
}

# ===== 4. Запуск создания ярлыков (если CreateShortcuts.ps1 рядом) =====
$shortcutScript = Join-Path $PSScriptRoot "CreateShortcuts.ps1"
if (Test-Path $shortcutScript -PathType Leaf) {
    Write-Step "Запускаю CreateShortcuts.ps1..." "Cyan"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shortcutScript
} else {
    Write-Step "ПРИМЕЧАНИЕ: CreateShortcuts.ps1 не найден рядом - ярлыки не создавались." "Yellow"
}

# ===== 5. Перезапуск фонового СЛУШАТЕЛЯ (Watch) =====
# Уже работающий слушатель держит в памяти СТАРЫЙ код и старые настройки,
# поэтому останавливаем все его процессы и запускаем обновлённую версию.
$PowerShellExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
Write-Step "Проверяю работающие процессы СЛУШАТЕЛЯ..." "Cyan"
$watchProcesses = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -like "*FileTransfer.ps1*Watch*" })
foreach ($proc in $watchProcesses) {
    try {
        Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
        Write-Step "Остановлен старый СЛУШАТЕЛЬ (PID $($proc.ProcessId))" "Yellow"
    } catch {
        Write-Step "ПРЕДУПРЕЖДЕНИЕ: не удалось остановить процесс PID $($proc.ProcessId)" "Yellow"
    }
}
Start-Sleep -Milliseconds 500

try {
    $listenerProcess = Start-Process -FilePath $PowerShellExe `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$targetScript`" Watch" `
        -WorkingDirectory $Destination -PassThru
    Write-Step "СЛУШАТЕЛЬ запущен заново (PID $($listenerProcess.Id)) — приём файлов и синхронизация активны." "Green"
} catch {
    Write-Step "ПРЕДУПРЕЖДЕНИЕ: не удалось запустить СЛУШАТЕЛЯ - $($_.Exception.Message)" "Yellow"
}

Write-Step "`nУстановка завершена!" "Cyan"
pause
