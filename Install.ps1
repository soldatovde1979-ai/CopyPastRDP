# ===============================================================================
#  Скрипт: Install.ps1
#  Назначение: Перемещение FileTransfer.ps1 в C:\CHANGE, копирование setcp.ini,
#              создание рабочих папок и запуск CreateShortcuts.ps1 (если он лежит рядом).
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

# ===== 3. Перемещение FileTransfer.ps1 в C:\CHANGE =====
$targetScript = Join-Path $Destination "FileTransfer.ps1"
$srcFull  = [System.IO.Path]::GetFullPath($sourceScript)
$dstFull  = [System.IO.Path]::GetFullPath($targetScript)

if ($srcFull -ieq $dstFull) {
    Write-Step "FileTransfer.ps1 уже находится в $Destination - перенос не требуется." "Yellow"
} else {
    try {
        Move-Item -Path $sourceScript -Destination $targetScript -Force
        Write-Step "FileTransfer.ps1 перемещён: $sourceScript -> $targetScript" "Green"
    } catch {
        Write-Step "ОШИБКА: не удалось переместить FileTransfer.ps1 - $($_.Exception.Message)" "Red"
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

Write-Step "`nУстановка завершена!" "Cyan"
pause
