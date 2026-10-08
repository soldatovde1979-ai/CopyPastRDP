# ===============================================================================
#  Скрипт: Install.ps1
#  Назначение: Копирование FileTransfer.ps1 в C:\CHANGE (исходник в репозитории
#              остаётся), копирование setcp.ini, создание рабочих папок,
#              запуск CreateShortcuts.ps1 (если он лежит рядом), ПЕРЕЗАПУСК
#              фонового СЛУШАТЕЛЯ (Watch) и РАСПРОСТРАНЕНИЕ обновлений на
#              другой контур через папку синхронизации SyncDir.
#
#  Запуск:     powershell -NoProfile -ExecutionPolicy Bypass -File Install.ps1
# ===============================================================================

param(
    [string]$Destination = "C:\CHANGE",
    # Локальные настройки ЭТОГО контура: "Key=Value;Key2=Value2" (секция [Settings]).
    # Пишутся в C:\CHANGE\setcp.local.ini, который НЕ копируется в SyncDir и
    # не перезаписывается самообновлением. Пример: -LocalSettings "KeepAliveMinutes=1"
    [string]$LocalSettings = ""
)

$ErrorActionPreference = "Stop"
$HasError = $false

function Write-Step([string]$Message, [string]$Color = "White") {
    Write-Host $Message -ForegroundColor $Color
}

function Get-IniKey {
    # Чтение значения ключа из INI-файла. Если задан $Section, совпадение
    # ищется только внутри этой секции (по всему файлу ключи дублируются)
    param([string]$Path, [string]$Key, [string]$Section = "", [string]$Default = "")
    if (-not (Test-Path -LiteralPath $Path)) { return $Default }
    $current = ""
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') { $current = $matches[1].Trim(); continue }
        if ($t -eq "" -or $t.StartsWith(";") -or $t.StartsWith("#")) { continue }
        if ($Section -and $current -ine $Section) { continue }
        if ($t -match '^\s*' + [regex]::Escape($Key) + '\s*=\s*(.+?)\s*(?:;.*)?$') {
            return $matches[1].Trim()
        }
    }
    return $Default
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

# ===== 3.2 Локальные настройки контура (setcp.local.ini) =====
# setcp.local.ini приоритетнее общего setcp.ini и НЕ попадает в SyncDir,
# поэтому отличия контуров не уходят на другой контур и не затираются обновлением.
if ($LocalSettings.Trim() -ne "") {
    $localFile = Join-Path $Destination "setcp.local.ini"
    if (-not (Test-Path -LiteralPath $localFile)) {
        Set-Content -LiteralPath $localFile -Encoding UTF8 -Value @(
            "; setcp.local.ini - ЛОКАЛЬНЫЕ настройки ЭТОГО контура (создан Install.ps1)",
            "; Значения приоритетнее setcp.ini. Файл НЕ синхронизируется через SyncDir",
            "; и не перезаписывается самообновлением.",
            "; Управление: FileTransfer.ps1 SetLocal / DelLocal / LocalShow",
            "[Settings]"
        )
    }
    $localLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $localFile -Encoding UTF8)) { $localLines.Add($line) }
    foreach ($pair in ($LocalSettings -split ';')) {
        $pair = $pair.Trim()
        if ($pair -eq "") { continue }
        if ($pair -notmatch '^([^=]+)=(.*)$') {
            Write-Step "ПРЕДУПРЕЖДЕНИЕ: неверный формат -LocalSettings '$pair' (нужно Key=Value)" "Yellow"
            continue
        }
        $key   = $matches[1].Trim()
        $value = $matches[2].Trim()
        $idx   = -1
        for ($i = 0; $i -lt $localLines.Count; $i++) {
            if ($localLines[$i] -match '^\s*' + [regex]::Escape($key) + '\s*=') { $idx = $i; break }
        }
        if ($idx -ge 0) { $localLines[$idx] = "$key=$value" }
        else            { $localLines.Add("$key=$value") }
    }
    Set-Content -LiteralPath $localFile -Value $localLines -Encoding UTF8
    Write-Step "Локальные настройки контура записаны в $localFile (в SyncDir не попадают)" "Green"
}

# ===== 3.3 Уникальный ID машины (MachineId) =====
# Зашит в Origin пакетов и защищает механизм «свой-чужой» от совпадения
# COMPUTERNAME на двух контурах. Хранится в setcp.local.ini (не синхронизируется).
$localFile = Join-Path $Destination "setcp.local.ini"
if (-not (Test-Path -LiteralPath $localFile)) {
    Set-Content -LiteralPath $localFile -Encoding UTF8 -Value @(
        "; setcp.local.ini - ЛОКАЛЬНЫЕ настройки ЭТОГО контура",
        "[Settings]"
    )
}
$machineId = Get-IniKey -Path $localFile -Key "MachineId" -Section "Settings"
if (-not $machineId) {
    $machineId = [guid]::NewGuid().ToString("N").Substring(0, 8)
    $localLines = New-Object System.Collections.Generic.List[string]
    foreach ($line in @(Get-Content -LiteralPath $localFile -Encoding UTF8)) { $localLines.Add($line) }
    $idx = -1
    for ($i = 0; $i -lt $localLines.Count; $i++) {
        if ($localLines[$i] -match '^\s*MachineId\s*=') { $idx = $i; break }
    }
    if ($idx -ge 0) { $localLines[$idx] = "MachineId=$machineId" }
    else {
        $sIdx = -1
        for ($i = 0; $i -lt $localLines.Count; $i++) {
            if ($localLines[$i] -match '^\s*\[Settings\]\s*$') { $sIdx = $i; break }
        }
        if ($sIdx -ge 0) { $localLines.Insert($sIdx + 1, "MachineId=$machineId") }
        else { $localLines.Add("[Settings]"); $localLines.Add("MachineId=$machineId") }
    }
    Set-Content -LiteralPath $localFile -Value $localLines -Encoding UTF8
    Write-Step "Присвоен MachineId=$machineId (setcp.local.ini)" "Green"
}

# ===== 4. Запуск создания ярлыков (если CreateShortcuts.ps1 рядом) =====
$shortcutScript = Join-Path $PSScriptRoot "CreateShortcuts.ps1"
if (Test-Path $shortcutScript -PathType Leaf) {
    Write-Step "Запускаю CreateShortcuts.ps1..." "Cyan"
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $shortcutScript -Destination $Destination
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

# ===== 6. Распространение обновлений на другой контур через SyncDir =====
# В SyncDir уходят ТОЛЬКО общие файлы FileTransfer.ps1 и setcp.ini.
# setcp.local.ini НЕ копируется: локальные настройки контура (например, keep-alive)
# остаются на месте и не затираются на другом контуре.
# Копируем обновлённые FileTransfer.ps1 и setcp.ini в папку синхронизации:
# слушатель на ЭТОМ контуре отправит их чанками на тот же путь в другом контуре,
# а слушатель-приёмник с AutoUpdate=1 применит их и перезапустится.
# Пауза нужна, чтобы новый слушатель успел сделать стартовый снапшот SyncDir
# (иначе он посчитает только что скопированные файлы синхронизированными).
Start-Sleep -Seconds 2

$syncDir = Get-IniKey -Path $iniTarget -Key "SyncDir" -Section "Paths" -Default "C:\CHANGE\disk"
$syncDir = [Environment]::ExpandEnvironmentVariables($syncDir)
if ($syncDir.Length -gt 3) { $syncDir = $syncDir.TrimEnd('\', '/') }

if (-not (Test-Path $syncDir)) {
    New-Item -ItemType Directory -Path $syncDir -Force | Out-Null
    Write-Step "Создана папка синхронизации: $syncDir" "Green"
}

try {
    Copy-Item -Path $targetScript -Destination (Join-Path $syncDir "FileTransfer.ps1") -Force
    Copy-Item -Path $iniTarget -Destination (Join-Path $syncDir "setcp.ini") -Force
    # Макет веб-дашборда (читается Invoke-WebStatus рядом со скриптом).
    # В SyncDir тоже: слушатель доставит его на другой контур, AutoUpdate применит.
    $tplSource = Join-Path $PSScriptRoot "dashboard.html"
    if (Test-Path $tplSource) {
        Copy-Item -Path $tplSource -Destination (Join-Path $Destination "dashboard.html") -Force
        Copy-Item -Path $tplSource -Destination (Join-Path $syncDir "dashboard.html") -Force
    }
    Write-Step "Обновления скопированы в $syncDir - слушатель отправит их на другой контур автоматически." "Green"
} catch {
    Write-Step "ПРЕДУПРЕЖДЕНИЕ: не удалось скопировать обновления в $syncDir - $($_.Exception.Message)" "Yellow"
}

Write-Step "`nУстановка завершена!" "Cyan"

