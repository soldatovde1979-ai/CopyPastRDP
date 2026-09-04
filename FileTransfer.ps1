<#
===============================================================================
 Скрипт: FileTransfer.ps1
 Назначение: Передача файлов через RDP-буфер обмена.

 Аргументы/Режимы:
 - Pack [Пути]: Упаковка файлов/папок и запись в буфер обмена.
 - PackAuto [Пути]: Упаковка и ожидание, пока приемник заберет данные.
 - Unpack: Распаковка из буфера обмена (маршрут по маске из setcp.ini или в IN-каталог).
 - UnpackTo [Путь]: Распаковка в каталог выделенного файла/папки.
 - Watch: Фоновый режим ожидания и автоматического приема данных.
===============================================================================
#>

param(
    [Parameter(Position=0, ValueFromRemainingArguments=$true)]
    [string[]]$Targets,
    [int]$ChunkThresholdMB = 10,
    [int]$ChunkSizeMB = 5,
    [string]$Config = ""
)

# ===== ЗАГРУЗКА НАСТРОЕК ИЗ setcp.ini =====
# По умолчанию INI ищется рядом со скриптом (C:\CHANGE\setcp.ini).
# Другой файл можно указать параметром: -Config "путь\к\файлу.ini"
$script:ConfigPath = if ($Config) { $Config } else { Join-Path $PSScriptRoot "setcp.ini" }

# Локальные настройки ЭТОГО контура: setcp.local.ini (или <имя>.local.<расширение>)
# рядом с основным INI. Значения из него имеют ПРИОРИТЕТ над общим setcp.ini.
# Файл НЕ копируется в SyncDir при установке и НЕ перезаписывается самообновлением,
# поэтому отличия контуров (например, keep-alive на внутреннем) не затираются.
# Управление: FileTransfer.ps1 SetLocal / DelLocal / LocalShow.
$script:LocalConfigPath = Join-Path (Split-Path -Parent $script:ConfigPath) `
    ([System.IO.Path]::GetFileNameWithoutExtension($script:ConfigPath) + ".local" + [System.IO.Path]::GetExtension($script:ConfigPath))

function Get-IniContent {
    param([string]$Path)
    $ini = @{}
    if (-not (Test-Path $Path -PathType Leaf)) { return $ini }

    # Чтение в UTF-8 независимо от наличия BOM (для корректных русских путей)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text  = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } else {
        [System.Text.Encoding]::UTF8.GetString($bytes)
    }

    $section = ""
    foreach ($raw in ($text -split "`r?`n")) {
        $line = $raw.Trim()
        if ($line -eq "" -or $line.StartsWith(";") -or $line.StartsWith("#")) { continue }
        if ($line -match '^\[(.+)\]$') {
            $section = $matches[1].Trim()
            if (-not $ini.ContainsKey($section)) { $ini[$section] = @{} }
            continue
        }
        if ($section -ne "" -and $line -match '^([^=]+)=(.*)$') {
            $ini[$section][$matches[1].Trim()] = $matches[2].Trim()
        }
    }
    return $ini
}

$script:Ini = Get-IniContent -Path $script:ConfigPath
$script:LocalIni = Get-IniContent -Path $script:LocalConfigPath
foreach ($sec in $script:LocalIni.Keys) {
    if (-not $script:Ini.ContainsKey($sec)) { $script:Ini[$sec] = @{} }
    foreach ($key in $script:LocalIni[$sec].Keys) { $script:Ini[$sec][$key] = $script:LocalIni[$sec][$key] }
}

function Get-IniValue {
    param([string]$Section, [string]$Key, [string]$Default = "")
    if ($script:Ini.ContainsKey($Section) -and $script:Ini[$Section].ContainsKey($Key)) {
        return [string]$script:Ini[$Section][$Key]
    }
    return $Default
}

function Get-IniPath {
    # Путь из INI; поддержка переменных окружения (%USERPROFILE% и т.п.)
    param([string]$Section, [string]$Key, [string]$Default)
    $v = Get-IniValue -Section $Section -Key $Key -Default $Default
    if ([string]::IsNullOrWhiteSpace($v)) { $v = $Default }
    return [Environment]::ExpandEnvironmentVariables($v)
}

function Get-IniBool {
    param([string]$Section, [string]$Key, [bool]$Default)
    $v = Get-IniValue -Section $Section -Key $Key -Default ""
    if ($v -eq "") { return $Default }
    # Числовые значения: 0 — false, любое ненулевое (в т.ч. 1000) — true.
    # Защищает от опечаток вида "DiskSyncEnabled=1000" вместо "1".
    if ($v -match '^\s*[+-]?\d+\s*$') { return ([long]$v -ne 0) }
    return ($v.ToLowerInvariant() -in @("true", "yes", "on", "y", "1"))
}

# Приоритет чисел: аргумент командной строки -> INI -> значение по умолчанию
if (-not $PSBoundParameters.ContainsKey('ChunkThresholdMB')) {
    $ChunkThresholdMB = [int](Get-IniValue -Section "Settings" -Key "ChunkThresholdMB" -Default "10")
}
if (-not $PSBoundParameters.ContainsKey('ChunkSizeMB')) {
    $ChunkSizeMB = [int](Get-IniValue -Section "Settings" -Key "ChunkSizeMB" -Default "5")
}

# Остальные настройки
$script:WarningSizeMB          = [double](Get-IniValue -Section "Settings" -Key "WarningSizeMB"     -Default "15")
$script:MaxLogLines            = [int](Get-IniValue    -Section "Settings" -Key "MaxLogLines"       -Default "500")
$script:PollIntervalMs         = [int](Get-IniValue    -Section "Settings" -Key "PollIntervalMs"    -Default "400")
# Окно «свежести» файлов в InDir для ручного приёма (UnpackTo): файлы, записанные
# не позже N секунд назад, переносятся в выбранную папку (порядок: сначала Send, потом Receive).
$script:ManualReceiveWindowSec = [int](Get-IniValue -Section "Settings" -Key "ManualReceiveWindowSec" -Default "300")
$script:ClipRetryAttempts      = [int](Get-IniValue    -Section "Settings" -Key "ClipRetryAttempts" -Default "10")
$script:ClipRetryDelayMs       = [int](Get-IniValue    -Section "Settings" -Key "ClipRetryDelayMs"  -Default "300")
$script:RoutesEnabled          = Get-IniBool -Section "Settings" -Key "RoutesEnabled"          -Default $true
$script:RoutesOverrideUnpackTo = Get-IniBool -Section "Settings" -Key "RoutesOverrideUnpackTo" -Default $true

# Синхронизация папки между контурами и сохранение сеанса (работают в режиме Watch)
$script:DiskSyncEnabled   = Get-IniBool -Section "Settings" -Key "DiskSyncEnabled"   -Default $false
$script:SyncPollMs        = [int](Get-IniValue -Section "Settings" -Key "SyncPollMs"        -Default "1000")
$script:SyncAckTimeoutSec = [int](Get-IniValue -Section "Settings" -Key "SyncAckTimeoutSec" -Default "60")
$script:KeepAliveMinutes  = [int](Get-IniValue -Section "Settings" -Key "KeepAliveMinutes"  -Default "0")
# Самообновление через папку синхронизации: принятые в SyncDir файлы
# FileTransfer.ps1 / setcp.ini копируются в каталог скрипта и слушатель перезапускается.
$script:AutoUpdate = Get-IniBool -Section "Settings" -Key "AutoUpdate" -Default $true
# Диагностика слушателя: периодический heartbeat в журнал (0 — выключен)
# и подробный trace-режим с причинами каждого действия (0/1).
$script:WatchHeartbeatSec = [int](Get-IniValue -Section "Settings" -Key "WatchHeartbeatSec" -Default "60")
$script:WatchTrace        = Get-IniBool -Section "Settings" -Key "WatchTrace"        -Default $false

# Рабочие каталоги и журнал
$IN_DIR   = Get-IniPath -Section "Paths" -Key "InDir"   -Default "C:\CHANGE\IN"
$OUT_DIR  = Get-IniPath -Section "Paths" -Key "OutDir"  -Default "C:\CHANGE\OUT"
$LOG_FILE = Get-IniPath -Section "Paths" -Key "LogFile" -Default "C:\CHANGE\FileTransfer.log"

# Папка синхронизации между контурами (на обоих контурах путь должен совпадать)
$script:SyncDir = Get-IniPath -Section "Paths" -Key "SyncDir" -Default "C:\CHANGE\disk"
if ($script:SyncDir.Length -gt 3) { $script:SyncDir = $script:SyncDir.TrimEnd('\', '/') }

# Маршрутизация приёма по маскам имён файлов (секция [Routes] файла setcp.ini)
$script:Routes = @()
if ($script:Ini.ContainsKey("Routes")) {
    foreach ($mask in $script:Ini["Routes"].Keys) {
        $target = [Environment]::ExpandEnvironmentVariables([string]$script:Ini["Routes"][$mask])
        if (-not [string]::IsNullOrWhiteSpace($target)) {
            $script:Routes += [pscustomobject]@{ Mask = $mask; Target = $target }
        }
    }
}

$script:HasError = $false

# Флаг самообновления: устанавливается приёмником после применения FileTransfer.ps1/setcp.ini,
# по нему Watch перезапускает себя с новым кодом.
$script:RestartNeeded = $false

# Занятые файлы SyncDir (для логирования только перехода состояния, без спама каждую секунду)
$script:LastLocked = @{}

# Персистентный журнал диска change.log (внутри SyncDir): ключ "relpath|длина|LastWriteTimeUtc"
# -> тип записи (SNAPSHOT/SENT/RECEIVED/LOCKED). Заменяет in-memory-память: что отправлено
# или принято, переживает перезапуск слушателя и защищает от петель.
$script:ChangeLog     = @{}
$script:ChangeLogPath = $null

if (-not (Test-Path $IN_DIR))  { New-Item -ItemType Directory -Path $IN_DIR  -Force | Out-Null }
if (-not (Test-Path $OUT_DIR)) { New-Item -ItemType Directory -Path $OUT_DIR -Force | Out-Null }
if ($script:DiskSyncEnabled -and -not (Test-Path $script:SyncDir)) {
    New-Item -ItemType Directory -Path $script:SyncDir -Force | Out-Null
}

# ===== ЛОГИРОВАНИЕ =====
function Write-Log {
    param([string]$Message, [string]$Color = "White")
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $label = if ($script:CurrentAction) { $script:CurrentAction } else { "SendFile" }
    try { Add-Content -Path $LOG_FILE -Value "[$timestamp] [$label] $Message" -Encoding UTF8 } catch {}
    Write-Host $Message -ForegroundColor $Color
}

function Rotate-Log {
    try {
        if (Test-Path $LOG_FILE) {
            $lines = Get-Content $LOG_FILE -Encoding UTF8
            if ($lines.Count -gt $script:MaxLogLines) {
                $lines | Select-Object -Last $script:MaxLogLines | Set-Content $LOG_FILE -Encoding UTF8
            }
        }
    } catch {}
}

# ===== УПАКОВКА И ОТПРАВКА =====
function Pack-Files {
    param(
        [string[]]$Paths,
        [switch]$AutoWait
    )

    $files = @()
    if ($Paths -and $Paths.Count -gt 0) {
        foreach ($path in $Paths) {
            if (Test-Path $path -PathType Leaf) {
                $files += Get-Item $path
            } elseif (Test-Path $path -PathType Container) {
                $files += Get-ChildItem -Path $path -File -Recurse
            }
        }
    } else {
        $files = @(Get-ChildItem -Path $OUT_DIR -File)
    }

    if ($files.Count -eq 0) {
        Write-Log "No files to send!" "Yellow"
        $script:HasError = $true
        return
    }

    $totalSize = 0
    foreach ($f in $files) { $totalSize += $f.Length }
    $totalSizeMB = [math]::Round($totalSize / 1MB, 2)

    Add-Type -AssemblyName System.Windows.Forms

    # Быстрый режим для небольших файлов (<= 10 МБ)
    if ($totalSizeMB -le $ChunkThresholdMB) {
        Write-Log "Packing $($files.Count) files ($totalSizeMB MB)..." "Cyan"

        if ($totalSizeMB -gt $script:WarningSizeMB) {
            Write-Log "WARNING: Size $totalSizeMB MB. May be slow or fail in RDP!" "Red"
        }

        $data = @{
            Files     = @()
            Timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
            Marker    = "FILE_TRANSFER_DATA"
            Origin    = $env:COMPUTERNAME
        }

        $i = 0
        foreach ($f in $files) {
            $i++
            Write-Log "  [$i/$($files.Count)] $($f.Name) ($([math]::Round($f.Length/1KB,1)) KB)" "Gray"
            try {
                $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
                $data.Files += @{ Name = $f.Name; Content = [Convert]::ToBase64String($bytes) }
            } catch {
                Write-Log "  FAIL: $($f.Name) - $($_.Exception.Message)" "Red"
                $script:HasError = $true
            }
        }

        $json = $data | ConvertTo-Json -Compress -Depth 10

        $clipOk = $false
        try {
            [System.Windows.Forms.Clipboard]::SetText($json)
            $clipOk = $true
        } catch {
            try {
                $json | Set-Clipboard -ErrorAction Stop
                $clipOk = $true
            } catch {
                Write-Log "FATAL: Clipboard failed! Files NOT deleted." "Red"
                $script:HasError = $true
            }
        }

        if ($clipOk) {
            foreach ($f in $files) {
                if ($f.Directory.FullName -ieq $OUT_DIR) { Remove-Item $f.FullName -Force }
            }
            Write-Log "OK: Sent $($files.Count) files to clipboard! ($totalSizeMB MB)" "Green"
            [System.Media.SystemSounds]::Asterisk.Play()

            # Ожидание для режима PackAuto (SEND FILE auto)
            if ($AutoWait) {
                Write-Log "Waiting for receiver (WAITING FILE) to pick up the data..." "Cyan"
                while ($true) {
                    Start-Sleep -Milliseconds $script:PollIntervalMs
                    try {
                        if (-not [System.Windows.Forms.Clipboard]::ContainsText()) {
                            Write-Log "SUCCESS: Receiver confirmed pick up!" "Green"
                            break
                        }
                    } catch {}
                }
            }
        }

    # Почаночный режим для крупных файлов (> 10 МБ)
    } else {
        Write-Log "Chunk-mode: Packing $($files.Count) file(s) ($totalSizeMB MB) in $ChunkSizeMB MB chunks..." "Cyan"

        foreach ($file in $files) {
            $chunkSizeBytes = $ChunkSizeMB * 1MB
            $totalChunks = [math]::Ceiling($file.Length / $chunkSizeBytes)
            if ($totalChunks -eq 0) { $totalChunks = 1 }
            $fileGuid = [guid]::NewGuid().ToString("N")

            Write-Log "  Processing '$($file.Name)' ($([math]::Round($file.Length/1MB,2)) MB) in $totalChunks chunk(s)..." "Gray"

            $stream = [System.IO.File]::OpenRead($file.FullName)
            try {
                $buffer = New-Object byte[] $chunkSizeBytes
                $chunkIndex = 1

                while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0 -or ($file.Length -eq 0 -and $chunkIndex -eq 1)) {
                    $actualBytes = if ($bytesRead -eq $chunkSizeBytes) { $buffer } else {
                        $slice = New-Object byte[] $bytesRead
                        [Array]::Copy($buffer, $slice, $bytesRead)
                        $slice
                    }

                    $payload = @{
                        Marker      = "FILE_CHUNK_DATA"
                        FileId      = $fileGuid
                        Name        = $file.Name
                        ChunkIndex  = $chunkIndex
                        TotalChunks = $totalChunks
                        Content     = [Convert]::ToBase64String($actualBytes)
                        Origin      = $env:COMPUTERNAME
                    }

                    $json = $payload | ConvertTo-Json -Compress

                    $clipOk = $false
                    $attempts = $script:ClipRetryAttempts
                    while ($attempts -gt 0 -and -not $clipOk) {
                        try {
                            [System.Windows.Forms.Clipboard]::SetText($json)
                            $clipOk = $true
                        } catch {
                            $attempts--
                            Start-Sleep -Milliseconds $script:ClipRetryDelayMs
                        }
                    }

                    if (-not $clipOk) {
                        Write-Log "FATAL: Cannot write chunk $chunkIndex/$totalChunks to clipboard!" "Red"
                        $script:HasError = $true
                        return
                    }

                    Write-Log "   -> Chunk $chunkIndex/$totalChunks sent. Waiting for ACK..." "Gray"

                    while ($true) {
                        Start-Sleep -Milliseconds $script:PollIntervalMs
                        try {
                            if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { break }
                        } catch {}
                    }

                    $chunkIndex++
                    if ($file.Length -eq 0) { break }
                }
            } finally {
                $stream.Close()
                $stream.Dispose()
            }

            if ($file.Directory.FullName -ieq $OUT_DIR) { Remove-Item $file.FullName -Force }
            Write-Log "SUCCESS: '$($file.Name)' fully transferred!" "Green"
        }
        [System.Media.SystemSounds]::Asterisk.Play()
    }
}

# ===== МАРШРУТИЗАЦИЯ ПРИЁМА ПО МАСКАМ =====
function Resolve-Destination {
    # Возвращает каталог назначения для файла: маршрут по маске из [Routes]
    # либо TargetDir. Каталог назначения создаётся автоматически.
    param([string]$FileName, [string]$TargetDir, [switch]$NoRoutes)

    $result = [pscustomobject]@{ Dir = $TargetDir; Mask = $null }
    if ($script:RoutesEnabled -and -not $NoRoutes) {
        foreach ($route in $script:Routes) {
            if ($FileName -like $route.Mask) {
                $result.Dir  = $route.Target
                $result.Mask = $route.Mask
                break
            }
        }
    }
    if (-not (Test-Path $result.Dir)) {
        try {
            New-Item -ItemType Directory -Path $result.Dir -Force | Out-Null
        } catch {
            Write-Log "WARNING: Cannot create directory '$($result.Dir)' - using '$TargetDir'" "Yellow"
            $result.Dir  = $TargetDir
            $result.Mask = $null
        }
    }
    return $result
}

# ===== РАСПАКОВКА И СБОРКА =====
function Unpack-Files {
    param(
        [string]$TargetDir = $IN_DIR,
        [string]$RawData = $null,
        [switch]$NoRoutes
    )

    $clipData = $RawData
    if (-not $clipData) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                $clipData = [System.Windows.Forms.Clipboard]::GetText()
            }
        } catch {
            $clipData = Get-Clipboard -Raw
        }
        if (-not $clipData) { $clipData = Get-Clipboard }
    }

    if (-not $clipData) {
        Write-Log "Clipboard is empty!" "Yellow"
        $script:HasError = $true
        return $false
    }

    $data = $null
    try { $data = $clipData | ConvertFrom-Json } catch {}

    if (-not $data) {
        Write-Log "ERROR: Clipboard data does not match JSON structure!" "Red"
        $script:HasError = $true
        return $false
    }

    # Вариант 1: Единый пакет (FILE_TRANSFER_DATA)
    if ($data.Marker -eq "FILE_TRANSFER_DATA") {
        $filesArray = @($data.Files)
        Write-Log "Target: $TargetDir" "Cyan"
        Write-Log "Receiving $($filesArray.Count) files..." "Cyan"

        foreach ($item in $filesArray) {
            try {
                $safeName = [System.IO.Path]::GetFileName($item.Name)
                if ([string]::IsNullOrWhiteSpace($safeName)) {
                    Write-Log "  SKIP: Invalid filename '$($item.Name)'" "Yellow"
                    continue
                }

                $dest = Resolve-Destination -FileName $safeName -TargetDir $TargetDir -NoRoutes:$NoRoutes
                if ($dest.Mask) { Write-Log "  ROUTE: '$safeName' matches '$($dest.Mask)' -> $($dest.Dir)" "Cyan" }

                $outPath = Join-Path $dest.Dir $safeName

                if (Test-Path $outPath) { Write-Log "  OVERWRITE: $safeName" "Yellow" }

                [System.IO.File]::WriteAllBytes($outPath, [Convert]::FromBase64String($item.Content))
                Write-Log "  OK: $safeName" "Gray"
            } catch {
                Write-Log "  FAIL: $($item.Name) - $($_.Exception.Message)" "Red"
                $script:HasError = $true
            }
        }

        if (-not $script:HasError) {
            Write-Log "OK: Success!" "Green"
            [System.Media.SystemSounds]::Asterisk.Play()
        }
        return $true
    }

    # Вариант 2: Чанк (FILE_CHUNK_DATA)
    if ($data.Marker -eq "FILE_CHUNK_DATA") {
        # Дисковая синхронизация: если у пакета есть RelPath и режим включён,
        # файл сохраняется по тому же относительному пути в SyncDir другого контура.
        $syncRel = $null
        if ($script:DiskSyncEnabled -and $data.PSObject.Properties['RelPath'] -and -not [string]::IsNullOrWhiteSpace([string]$data.RelPath)) {
            $syncRel = ([string]$data.RelPath) -replace '\\', '/'
            $syncRel = (($syncRel -split '/') | Where-Object { $_ -notin @('', '.', '..') }) -join '/'
        }

        $safeName = [System.IO.Path]::GetFileName($data.Name)
        if ($syncRel) { $safeName = [System.IO.Path]::GetFileName($syncRel) }

        if ($syncRel) {
            # Диск (SyncDir) — место по умолчанию. Маски из [Routes] приоритетнее:
            # если имя файла совпало с маской, файл сохраняется в каталог, указанный
            # в маске (вместо SyncDir).
            $syncTarget = $null
            $routeMask  = $null
            if ($script:RoutesEnabled) {
                foreach ($route in $script:Routes) {
                    if ($safeName -like $route.Mask) {
                        $syncTarget = $route.Target
                        $routeMask  = $route.Mask
                        break
                    }
                }
            }
            if (-not $syncTarget) {
                $relDir = Split-Path -Parent $syncRel
                $syncTarget = if ($relDir) { Join-Path $script:SyncDir $relDir } else { $script:SyncDir }
            }
            if (-not (Test-Path $syncTarget)) { New-Item -ItemType Directory -Path $syncTarget -Force | Out-Null }
            $dest = [pscustomobject]@{ Dir = $syncTarget; Mask = $null }
            if ($routeMask) {
                Write-Log "  SYNC-ROUTE: '$safeName' matches '$routeMask' -> $($dest.Dir)" "Cyan"
            } else {
                Write-Log "  SYNC: '$safeName' -> $($dest.Dir)" "Cyan"
            }
        } else {
            $dest = Resolve-Destination -FileName $safeName -TargetDir $TargetDir -NoRoutes:$NoRoutes
            if ($dest.Mask) { Write-Log "  ROUTE: '$safeName' matches '$($dest.Mask)' -> $($dest.Dir)" "Cyan" }
        }
        $partPath  = Join-Path $dest.Dir "$safeName.part"
        $finalPath = Join-Path $dest.Dir $safeName

        if ($data.ChunkIndex -eq 1 -and (Test-Path $partPath)) {
            Remove-Item $partPath -Force
        }

        $bytes = [Convert]::FromBase64String($data.Content)
        $outStream = New-Object System.IO.FileStream($partPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            if ($bytes.Length -gt 0) { $outStream.Write($bytes, 0, $bytes.Length) }
        } finally {
            $outStream.Close()
            $outStream.Dispose()
        }

        Write-Log "Received chunk $($data.ChunkIndex)/$($data.TotalChunks) for '$safeName'" "Gray"

        if ($data.ChunkIndex -eq $data.TotalChunks) {
            if (Test-Path $finalPath) { Remove-Item $finalPath -Force }
            Move-Item $partPath $finalPath -Force
            if ($syncRel) {
                # Помечаем принятый файл как обработанный, чтобы не отправить его обратно (петля)
                $item = Get-Item $finalPath -ErrorAction SilentlyContinue
                if ($item) { Add-ChangeEntry -Type "RECEIVED" -RelPath $syncRel -Item $item }
                Write-Log "SUCCESS: Sync file '$syncRel' completely assembled!" "Green"

                # Самообновление: файлы FileTransfer.ps1 / setcp.ini, пришедшие в корень SyncDir,
                # применяются в каталог запущенного скрипта, после чего слушатель перезапускается.
                if ($script:AutoUpdate -and $syncRel -notmatch '/' -and $safeName -in @('FileTransfer.ps1', 'setcp.ini')) {
                    $rootDir = Split-Path -Parent $PSCommandPath
                    try {
                        Copy-Item -Path $finalPath -Destination (Join-Path $rootDir $safeName) -Force
                        Write-Log "AUTOUPDATE: '$safeName' applied to $rootDir - listener will restart" "Cyan"
                        $script:RestartNeeded = $true
                    } catch {
                        Write-Log "AUTOUPDATE: FAILED to apply '$safeName' - $($_.Exception.Message)" "Red"
                    }
                }
            } else {
                Write-Log "SUCCESS: File '$safeName' completely assembled!" "Green"
            }
            [System.Media.SystemSounds]::Asterisk.Play()
        }
        return $true
    }

    Write-Log "ERROR: Clipboard data does not match the marker!" "Red"
    $script:HasError = $true
    return $false
}

# ===== СИНХРОНИЗАЦИЯ ПАПКИ МЕЖДУ КОНТУРАМИ (РЕЖИМ WATCH) =====

function Get-RelPath {
    # Относительный путь файла от SyncDir (с прямыми слэшами)
    param([string]$FullName)
    $base = $script:SyncDir.TrimEnd('\', '/')
    $rel = $FullName.Substring($base.Length).TrimStart('\', '/')
    return ($rel -replace '\\', '/')
}

function Get-SyncKey {
    # Ключ обработки файла: путь + размер + время записи (изменённый файл — новый ключ)
    param([System.IO.FileInfo]$Item, [string]$RelPath)
    return ("{0}|{1}|{2}" -f ($RelPath.ToLowerInvariant() -replace '\\', '/'), $Item.Length, $Item.LastWriteTimeUtc.Ticks)
}

function Add-ChangeEntry {
    # Дописывает строку в персистентный журнал change.log (внутри SyncDir)
    # и обновляет in-memory журнал $script:ChangeLog.
    param([string]$Type, [string]$RelPath, [System.IO.FileInfo]$Item)
    $key = Get-SyncKey -Item $Item -RelPath $RelPath
    $script:ChangeLog[$key] = $Type
    if (-not $script:ChangeLogPath) { return }
    $line = "{0}|{1}|{2}|{3}|{4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Type, ($RelPath -replace '\\', '/'), $Item.Length, $Item.LastWriteTimeUtc.Ticks
    try { Add-Content -LiteralPath $script:ChangeLogPath -Value $line -Encoding UTF8 } catch {}
}

function Test-FileFree {
    # True, если файл можно открыть монопольно (никто не пишет в него прямо сейчас)
    param([string]$Path)
    try {
        $fs = [System.IO.File]::Open($Path, 'Open', 'Read', 'None')
        $fs.Close()
        $fs.Dispose()
        return $true
    } catch {
        return $false
    }
}

function Initialize-ChangeLog {
    # Загрузка/создание персистентного журнала change.log внутри SyncDir.
    # Журнал хранит, что уже отправлено/принято, и переживает перезапуск слушателя.
    if (-not $script:DiskSyncEnabled) { return }
    if (-not (Test-Path $script:SyncDir)) { return }
    $script:ChangeLogPath = Join-Path $script:SyncDir "change.log"
    $script:ChangeLog     = @{}

    $loaded = 0
    if (Test-Path -LiteralPath $script:ChangeLogPath) {
        foreach ($line in @(Get-Content -LiteralPath $script:ChangeLogPath -Encoding UTF8)) {
            if ($line -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\|(SENT|RECEIVED|SNAPSHOT|LOCKED)\|(.+)\|(\d+)\|(\d+)$') {
                $script:ChangeLog["$($matches[2])|$($matches[3])|$($matches[4])"] = $matches[1]
                $loaded++
            }
        }
    }

    # Первый запуск (журнала нет) или журнал разросся: пересоздаём из актуальных файлов папки —
    # всё, что лежит на диске, помечается SNAPSHOT (считается синхронизированным).
    $rebuild = -not (Test-Path -LiteralPath $script:ChangeLogPath)
    if (-not $rebuild) {
        $lineCount = @(Get-Content -LiteralPath $script:ChangeLogPath -Encoding UTF8).Count
        if ($lineCount -gt 2000) { $rebuild = $true }
    }

    if ($rebuild) {
        Set-Content -LiteralPath $script:ChangeLogPath -Value "" -Encoding UTF8
        $script:ChangeLog = @{}
        $count = 0
        Get-ChildItem -Path $script:SyncDir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -ine 'change.log' -and $_.Extension -ne '.part' } |
            ForEach-Object {
                Add-ChangeEntry -Type "SNAPSHOT" -RelPath (Get-RelPath -FullName $_.FullName) -Item $_
                $count++
            }
        Write-Log "SYNC: change.log created/rotated, $count file(s) marked as snapshot." "DarkGray"
    } elseif ($loaded -gt 0) {
        Write-Log "SYNC: change.log loaded ($loaded records)." "DarkGray"
    }
    # Файлы, которых нет в журнале, считаются новыми и будут отправлены
    # при первом же сканировании (даже если слушатель был выключен).
}

function Wait-SyncAck {
    # Ждёт очистки буфера приёмником. При таймауте забирает свой пакет обратно,
    # чтобы Watch не завис навсегда (слушатель на другом конце может быть выключен).
    param([string]$RelPath)
    $deadline = (Get-Date).AddSeconds($script:SyncAckTimeoutSec)
    while ($true) {
        Start-Sleep -Milliseconds $script:PollIntervalMs
        try {
            if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return $true }
        } catch {
            return $false
        }
        if ((Get-Date) -gt $deadline) {
            try { [System.Windows.Forms.Clipboard]::Clear() } catch {}
            Write-Log "SYNC: ACK timeout for '$RelPath' - packet pulled back. Is the listener running on the other side?" "Yellow"
            return $false
        }
    }
}

function Send-SyncFile {
    # Отправка файла из SyncDir ЧАНКАМИ (существующим механизмом FILE_CHUNK_DATA)
    # на такой же относительный путь (RelPath) в другом контуре.
    param(
        [System.IO.FileInfo]$File,
        [string]$RelPath
    )

    $chunkSizeBytes = $ChunkSizeMB * 1MB
    $totalChunks = [math]::Ceiling($File.Length / $chunkSizeBytes)
    if ($totalChunks -eq 0) { $totalChunks = 1 }
    $fileGuid = [guid]::NewGuid().ToString("N")

    Write-Log "SYNC: Sending '$RelPath' ($([math]::Round($File.Length/1MB,2)) MB) in $totalChunks chunk(s)..." "Cyan"

    $stream = [System.IO.File]::Open($File.FullName, 'Open', 'Read', 'ReadWrite')
    try {
        $buffer = New-Object byte[] $chunkSizeBytes
        $chunkIndex = 1

        while (($bytesRead = $stream.Read($buffer, 0, $buffer.Length)) -gt 0 -or ($File.Length -eq 0 -and $chunkIndex -eq 1)) {
            $actualBytes = if ($bytesRead -eq $chunkSizeBytes) { $buffer } else {
                $slice = New-Object byte[] $bytesRead
                [Array]::Copy($buffer, $slice, $bytesRead)
                $slice
            }

            $payload = @{
                Marker      = "FILE_CHUNK_DATA"
                FileId      = $fileGuid
                Name        = $File.Name
                RelPath     = $RelPath
                ChunkIndex  = $chunkIndex
                TotalChunks = $totalChunks
                Content     = [Convert]::ToBase64String($actualBytes)
                Origin      = $env:COMPUTERNAME
            }

            $json = $payload | ConvertTo-Json -Compress

            $clipOk = $false
            $attempts = $script:ClipRetryAttempts
            while ($attempts -gt 0 -and -not $clipOk) {
                try {
                    [System.Windows.Forms.Clipboard]::SetText($json)
                    $clipOk = $true
                } catch {
                    $attempts--
                    Start-Sleep -Milliseconds $script:ClipRetryDelayMs
                }
            }

            if (-not $clipOk) {
                Write-Log "SYNC: FATAL: cannot write chunk $chunkIndex/$totalChunks of '$RelPath' to clipboard!" "Red"
                $script:HasError = $true
                return $false
            }

            Write-Log "SYNC:   chunk $chunkIndex/$totalChunks sent. Waiting for ACK..." "Gray"

            if (-not (Wait-SyncAck -RelPath $RelPath)) { return $false }

            $chunkIndex++
            if ($File.Length -eq 0) { break }
        }
    } finally {
        $stream.Close()
        $stream.Dispose()
    }

    Write-Log "SYNC: '$RelPath' fully transferred!" "Green"
    return $true
}

function Scan-SyncDir {
    # Периодический просмотр SyncDir: новый свободный файл -> отправка чанками
    # на такой же относительный путь в другом контуре. Состояние "что уже
    # отправлено/принято" берётся из персистентного журнала change.log.
    if (-not (Test-Path $script:SyncDir)) {
        if ($script:WatchTrace) { Write-Log "TRACE: SyncDir '$($script:SyncDir)' not found" "DarkGray" }
        return
    }

    # Служебные файлы не отправляются: сам журнал change.log и незавершённые сборки .part
    $files       = @(Get-ChildItem -Path $script:SyncDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ine 'change.log' -and $_.Extension -ne '.part' })
    $newCount    = 0
    $handledCount = 0
    $lockedCount = 0
    $sentCount   = 0
    $failedCount = 0
    foreach ($file in $files) {
        $rel = Get-RelPath -FullName $file.FullName
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $key = Get-SyncKey -Item $file -RelPath $rel
        if ($script:ChangeLog.ContainsKey($key) -and $script:ChangeLog[$key] -in @('SENT', 'RECEIVED', 'SNAPSHOT')) {
            $handledCount++
            if ($script:WatchTrace) { Write-Log "TRACE: skip '$rel' - already processed ($($script:ChangeLog[$key]))" "DarkGray" }
            continue
        }
        $newCount++
        if (-not (Test-FileFree -Path $file.FullName)) {
            $lockedCount++
            # Занятый файл логируем только при переходе состояния, чтобы не спамить каждую секунду
            if (-not $script:LastLocked.ContainsKey($key)) {
                Write-Log "SYNC: '$rel' is locked (still being written) - will retry when free" "DarkGray"
                Add-ChangeEntry -Type "LOCKED" -RelPath $rel -Item $file
                $script:LastLocked[$key] = $true
            }
            continue
        }
        $script:LastLocked.Remove($key)
        if (Send-SyncFile -File $file -RelPath $rel) {
            Add-ChangeEntry -Type "SENT" -RelPath $rel -Item $file
            $sentCount++
        } else {
            $failedCount++
            Write-Log "SYNC: '$rel' NOT sent - will retry on next scan" "Yellow"
        }
    }
    if ($script:WatchTrace -and $files.Count -gt 0) {
        Write-Log "TRACE: scan result: total=$($files.Count), new=$newCount, already-processed=$handledCount, locked=$lockedCount, sent=$sentCount, failed=$failedCount" "DarkGray"
    }
}

# ===== СОХРАНЕНИЕ RDP-СЕАНСА (РЕЖИМ WATCH) =====

function Send-KeepAlive {
    # Лёгкая эмуляция активности (сдвиг курсора на 1 px и обратно), чтобы
    # RDP-сессия не закрылась по таймауту бездействия. Включайте на ВНУТРЕННЕМ контуре.
    Add-Type -AssemblyName System.Windows.Forms
    $pos = [System.Windows.Forms.Cursor]::Position
    try {
        [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point(($pos.X + 1), $pos.Y)
        [System.Windows.Forms.Cursor]::Position = New-Object System.Drawing.Point($pos.X, $pos.Y)
        Write-Log "KeepAlive: activity emulated (RDP session kept alive)" "DarkGray"
    } catch {
        Write-Log "KeepAlive: cannot move cursor - $($_.Exception.Message)" "Yellow"
    }
}

# ===== САМООБНОВЛЕНИЕ (РЕЖИМ WATCH) =====

function Restart-Listener {
    # Перезапуск Watch с обновлённым кодом/настройками после самообновления.
    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    Write-Log "AUTOUPDATE: restarting listener with updated code..." "Cyan"
    try {
        Start-Process -FilePath $psExe `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" Watch" `
            -WorkingDirectory (Split-Path -Parent $PSCommandPath) | Out-Null
    } catch {
        Write-Log "AUTOUPDATE: failed to start new listener - $($_.Exception.Message)" "Red"
    }
    Start-Sleep -Milliseconds 300
    exit 0
}

# ===== ЗАЩИТА ОТ ПОВТОРНОГО ЗАПУСКА СЛУШАТЕЛЯ =====

function Stop-OldListeners {
    # При старте Watch завершаем другие работающие экземпляры слушателя (кроме себя),
    # чтобы несколько процессов не конкурировали за буфер обмена.
    $old = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*FileTransfer.ps1*Watch*" })
    foreach ($proc in $old) {
        try {
            Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop
            Write-Log "Watch: stopped previous listener instance (PID $($proc.ProcessId))" "Yellow"
        } catch {
            Write-Log "Watch: WARNING: cannot stop previous listener PID $($proc.ProcessId) - $($_.Exception.Message)" "Yellow"
        }
    }
    if ($old.Count -gt 0) { Start-Sleep -Milliseconds 500 }
}

# ===== СЛУШАТЕЛЬ (WATCHER) =====
function Watch-Clipboard {
    param([string]$TargetDir = $IN_DIR)

    # Защита от двойного запуска: завершаем старый экземпляр слушателя, если он есть.
    Stop-OldListeners

    Write-Log "Started WATCH mode. Listening..." "Magenta"
    if ($script:DiskSyncEnabled) {
        Write-Log "SYNC: disk sync ENABLED, watching '$($script:SyncDir)'..." "Magenta"
    } else {
        Write-Log "SYNC: disk sync DISABLED (DiskSyncEnabled=0) - files in '$($script:SyncDir)' will NOT be sent" "DarkGray"
    }
    if ($script:KeepAliveMinutes -gt 0) { Write-Log "KeepAlive: enabled, every $($script:KeepAliveMinutes) min" "Magenta" }
    if ($script:WatchTrace) { Write-Log "TRACE: verbose logging enabled (each poll cycle)" "DarkGray" }
    if ($script:WatchHeartbeatSec -gt 0) { Write-Log "Heartbeat: every $($script:WatchHeartbeatSec) sec" "DarkGray" }
    Add-Type -AssemblyName System.Windows.Forms

    Initialize-ChangeLog
    $lastSyncScan  = Get-Date
    $lastKeepAlive = Get-Date
    $lastHeartbeat = Get-Date

    while ($true) {
        Start-Sleep -Milliseconds $script:PollIntervalMs

        # ===== Приём из буфера обмена =====
        $clipState = "empty"
        $skipScan  = $false
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                $text = [System.Windows.Forms.Clipboard]::GetText()
                if ([string]::IsNullOrWhiteSpace($text)) {
                    $clipState = "empty"
                } elseif ($text -match '"Marker"\s*:\s*"(FILE_TRANSFER_DATA|FILE_CHUNK_DATA|FILE_DISK_CMD)"') {

                    # Свой-чужой: пакет с Origin = имя этого же ПК положен локально этим же скриптом.
                    # Он предназначен для Watch на ДРУГОМ конце RDP - не трогаем буфер, ждём его.
                    if ($text -match '"Origin"\s*:\s*"([^"]+)"' -and $matches[1] -eq $env:COMPUTERNAME) {
                        $clipState = "own-packet"
                        $skipScan  = $true
                    } else {
                        $clipState = "foreign-packet"
                        $script:HasError = $false
                        $script:RestartNeeded = $false

                        # Команда управления (не файл): FILE_DISK_CMD - очистить SyncDir на этом контуре.
                        # Подтверждение (ACK) - очистка буфера, её ждёт отправитель команды.
                        if ($text -match '"Marker"\s*:\s*"FILE_DISK_CMD"') {
                            if ($text -match '"Action"\s*:\s*"ClearDisk"') {
                                $removedHere = Clear-SyncDirLocal
                                Write-Log "CLEAR-DISK: remote command received - '$($script:SyncDir)' cleared ($removedHere item(s) removed)" "Cyan"
                                [System.Windows.Forms.Clipboard]::Clear()
                            }
                        } else {
                            $processed = Unpack-Files -TargetDir $TargetDir -RawData $text

                            if ($processed) {
                                [System.Windows.Forms.Clipboard]::Clear()
                            }

                            # Самообновление: принятый FileTransfer.ps1/setcp.ini применён - перезапускаемся
                            if ($script:RestartNeeded) { Restart-Listener }
                        }
                    }
                } else {
                    $clipState = "other-text"
                }
            }
        } catch { $clipState = "clip-error" }

        # ===== Синхронизация папки между контурами =====
        # Скан пропускаем, пока в буфере лежит наш собственный пакет (ждём ACK другого контура).
        $scanDone = $false
        if (-not $skipScan -and $script:DiskSyncEnabled -and (((Get-Date) - $lastSyncScan).TotalMilliseconds -ge $script:SyncPollMs)) {
            $lastSyncScan = Get-Date
            $scanDone = $true
            try {
                Scan-SyncDir
            } catch {
                Write-Log "SYNC: scan error - $($_.Exception.Message)" "Yellow"
            }
        }

        # ===== Сохранение RDP-сеанса (keep-alive) =====
        if ($script:KeepAliveMinutes -gt 0 -and (((Get-Date) - $lastKeepAlive).TotalMinutes -ge $script:KeepAliveMinutes)) {
            $lastKeepAlive = Get-Date
            try { Send-KeepAlive } catch {}
        }

        # ===== Диагностика: heartbeat / trace =====
        $nextScanMs = if ($script:DiskSyncEnabled) {
            [math]::Max(0, [int]($script:SyncPollMs - ((Get-Date) - $lastSyncScan).TotalMilliseconds))
        } else { -1 }

        if ($script:WatchTrace) {
            $scanInfo = if ($script:DiskSyncEnabled) { "scan=$scanDone, nextScanIn=$nextScanMs ms" } else { "disk sync DISABLED" }
            Write-Log "TRACE: clip=$clipState, $scanInfo, keepAliveEvery=$($script:KeepAliveMinutes) min" "DarkGray"
        } elseif ($script:WatchHeartbeatSec -gt 0 -and (((Get-Date) - $lastHeartbeat).TotalSeconds -ge $script:WatchHeartbeatSec)) {
            $lastHeartbeat = Get-Date
            $scanInfo = if ($script:DiskSyncEnabled) { "next disk scan in $nextScanMs ms" } else { "disk sync DISABLED" }
            Write-Log "Watch alive: clip=$clipState, $scanInfo, change.log records: $($script:ChangeLog.Count)" "DarkGray"
        }
    }
}

# ===== ЛОКАЛЬНЫЕ НАСТРОЙКИ КОНТУРА (setcp.local.ini) =====

function Read-IniItems {
    # Построчное чтение INI в список элементов с сохранением комментариев и порядка.
    param([string]$Path)
    $items = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path)) { return $items }
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    $text  = if ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF) {
        [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3)
    } else {
        [System.Text.Encoding]::UTF8.GetString($bytes)
    }
    $section = ""
    foreach ($raw in ($text -split "`r?`n")) {
        $line  = $raw.TrimEnd("`r")
        $trim  = $line.Trim()
        if ($trim -eq "") {
            $items.Add([pscustomobject]@{ Kind = "blank"; Text = $line; Section = $section; Key = "" })
            continue
        }
        if ($trim.StartsWith(";") -or $trim.StartsWith("#")) {
            $items.Add([pscustomobject]@{ Kind = "comment"; Text = $line; Section = $section; Key = "" })
            continue
        }
        if ($trim -match '^\[(.+)\]$') {
            $section = $matches[1].Trim()
            $items.Add([pscustomobject]@{ Kind = "section"; Text = $line; Section = $section; Key = "" })
            continue
        }
        if ($trim -match '^([^=]+?)\s*=\s*(.*)$') {
            $items.Add([pscustomobject]@{ Kind = "key"; Text = $line; Section = $section; Key = $matches[1].Trim(); Value = $matches[2].Trim() })
        } else {
            $items.Add([pscustomobject]@{ Kind = "comment"; Text = $line; Section = $section; Key = "" })
        }
    }
    return $items
}

function Save-IniItems {
    param([string]$Path, $items)
    $lines = @($items | ForEach-Object { $_.Text })
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Set-IniKeyItem {
    # Обновляет ключ в секции (если секции/ключа нет - добавляет), сохраняя порядок и комментарии.
    param($items, [string]$Section, [string]$Key, [string]$Value)
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Kind -eq "key" -and $items[$i].Section -ieq $Section -and $items[$i].Key -ieq $Key) {
            $items[$i] = [pscustomobject]@{ Kind = "key"; Text = "$Key=$Value"; Section = $Section; Key = $Key; Value = $Value }
            return
        }
    }
    $newItem = [pscustomobject]@{ Kind = "key"; Text = "$Key=$Value"; Section = $Section; Key = $Key; Value = $Value }
    $lastKeyIdx = -1
    $sectIdx    = -1
    for ($i = 0; $i -lt $items.Count; $i++) {
        if ($items[$i].Kind -eq "section" -and $items[$i].Section -ieq $Section) { $sectIdx = $i }
        elseif ($items[$i].Kind -eq "key" -and $items[$i].Section -ieq $Section) { $lastKeyIdx = $i }
    }
    if ($lastKeyIdx -ge 0) { $items.Insert($lastKeyIdx + 1, $newItem) }
    elseif ($sectIdx -ge 0) { $items.Insert($sectIdx + 1, $newItem) }
    else {
        $items.Add([pscustomobject]@{ Kind = "section"; Text = "[$Section]"; Section = $Section; Key = "" })
        $items.Add($newItem)
    }
}

function Remove-IniKeyItem {
    # Удаляет ключ из секции; если Key пустой - удаляет всю секцию. Возвращает число удалённых ключей.
    param($items, [string]$Section, [string]$Key)
    $removed = 0
    for ($i = $items.Count - 1; $i -ge 0; $i--) {
        if ($items[$i].Kind -eq "key" -and $items[$i].Section -ieq $Section -and $items[$i].Key -ieq $Key) {
            $items.RemoveAt($i)
            $removed++
        }
    }
    if ($Key -eq "") {
        for ($i = $items.Count - 1; $i -ge 0; $i--) {
            if ($items[$i].Kind -eq "section" -and $items[$i].Section -ieq $Section) { $items.RemoveAt($i) }
        }
    }
    return $removed
}

function Restart-WatchIfRunning {
    # Если фоновый слушатель работает - перезапускаем его, чтобы изменения настроек
    # или журнала change.log вступили в силу немедленно.
    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -like "*FileTransfer.ps1*Watch*" })
    if ($running.Count -eq 0) { return }
    foreach ($proc in $running) {
        try { Stop-Process -Id $proc.ProcessId -Force -ErrorAction Stop } catch {}
    }
    Start-Sleep -Milliseconds 500
    $psExe = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
    try {
        Start-Process -FilePath $psExe `
            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" Watch" `
            -WorkingDirectory (Split-Path -Parent $PSCommandPath) | Out-Null
        Write-Log "Watch: listener restarted to apply settings" "Cyan"
    } catch {
        Write-Log "Watch: failed to restart listener - $($_.Exception.Message)" "Red"
    }
}

function Invoke-LocalShow {
    Write-Log "LOCAL: common config : $($script:ConfigPath)" "Cyan"
    if (Test-Path -LiteralPath $script:LocalConfigPath) {
        Write-Log "LOCAL: per-host file : $($script:LocalConfigPath) (overrides common values)" "Cyan"
    } else {
        Write-Log "LOCAL: per-host file does not exist - all values come from the common config" "DarkGray"
    }
    foreach ($sec in ($script:Ini.Keys | Sort-Object)) {
        Write-Log "LOCAL: [$sec]" "Cyan"
        foreach ($key in ($script:Ini[$sec].Keys | Sort-Object)) {
            $src = if ($script:LocalIni.ContainsKey($sec) -and $script:LocalIni[$sec].ContainsKey($key)) { " (local)" } else { "" }
            Write-Log ("LOCAL:   {0}={1}{2}" -f $key, $script:Ini[$sec][$key], $src) "Gray"
        }
    }
}

function Invoke-SetLocal {
    # FileTransfer.ps1 SetLocal <Section> <Key> <Value> - записать локальную настройку контура.
    param([string]$Section, [string]$Key, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Section) -or [string]::IsNullOrWhiteSpace($Key) -or $null -eq $Value) {
        Write-Log "ERROR: SetLocal: usage: FileTransfer.ps1 SetLocal <Section> <Key> <Value>" "Red"
        $script:HasError = $true
        return
    }
    $items = Read-IniItems -Path $script:LocalConfigPath
    if ($items.Count -eq 0) {
        $items.Add([pscustomobject]@{ Kind = "comment"; Text = "; setcp.local.ini - ЛОКАЛЬНЫЕ настройки ЭТОГО контура (создан командой SetLocal)"; Section = ""; Key = "" })
        $items.Add([pscustomobject]@{ Kind = "comment"; Text = "; Значения приоритетнее setcp.ini. Файл НЕ синхронизируется через SyncDir и не перезаписывается самообновлением."; Section = ""; Key = "" })
        $items.Add([pscustomobject]@{ Kind = "blank"; Text = ""; Section = ""; Key = "" })
    }
    Set-IniKeyItem -items $items -Section $Section -Key $Key -Value $Value
    Save-IniItems -Path $script:LocalConfigPath -items $items
    Write-Log "LOCAL: $($script:LocalConfigPath): [$Section] $Key=$Value" "Green"
    Restart-WatchIfRunning
}

function Invoke-DelLocal {
    # FileTransfer.ps1 DelLocal <Section> [Key] - удалить ключ (или всю секцию без Key).
    param([string]$Section, [string]$Key)
    if ([string]::IsNullOrWhiteSpace($Section)) {
        Write-Log "ERROR: DelLocal: usage: FileTransfer.ps1 DelLocal <Section> [Key]" "Red"
        $script:HasError = $true
        return
    }
    if (-not (Test-Path -LiteralPath $script:LocalConfigPath)) {
        Write-Log "LOCAL: nothing to delete - $($script:LocalConfigPath) does not exist" "Yellow"
        return
    }
    $items   = Read-IniItems -Path $script:LocalConfigPath
    $removed = Remove-IniKeyItem -items $items -Section $Section -Key $Key
    Save-IniItems -Path $script:LocalConfigPath -items $items
    $what = if ($Key) { "[$Section] $Key" } else { "section [$Section]" }
    Write-Log "LOCAL: removed $what ($removed key(s))" "Green"
    Restart-WatchIfRunning
}

function Invoke-Resend {
    # FileTransfer.ps1 Resend [маска1 маска2 ...] - стереть записи change.log,
    # чтобы файлы (все или по маскам) были отправлены заново при следующем скане.
    # Пустой change.log при перезапуске слушателя НЕ приводит к снапшоту: файлы,
    # лежащие в SyncDir, считаются новыми и отправляются.
    param([string[]]$Masks)
    if (-not $script:DiskSyncEnabled) {
        Write-Log "RESEND: disk sync is DISABLED (DiskSyncEnabled=0) - nothing to resend" "Yellow"
        return
    }
    if (-not (Test-Path $script:SyncDir)) {
        Write-Log "RESEND: SyncDir '$($script:SyncDir)' not found" "Yellow"
        return
    }
    $logPath = Join-Path $script:SyncDir "change.log"
    if (-not (Test-Path -LiteralPath $logPath)) {
        Set-Content -LiteralPath $logPath -Value "" -Encoding UTF8
        Write-Log "RESEND: change.log created empty - all files in SyncDir will be sent on next listener start" "Cyan"
    } else {
        $kept = New-Object System.Collections.Generic.List[string]
        $removed = 0
        foreach ($line in @(Get-Content -LiteralPath $logPath -Encoding UTF8)) {
            $m = [regex]::Match($line, '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\|(SENT|RECEIVED|SNAPSHOT|LOCKED)\|(.+)\|\d+\|\d+$')
            if (-not $m.Success) { continue }
            $hit = ($Masks.Count -eq 0)
            if (-not $hit) {
                foreach ($mask in $Masks) { if ($m.Groups[2].Value -like $mask) { $hit = $true; break } }
            }
            if ($hit) { $removed++ } else { $kept.Add($line) }
        }
        Set-Content -LiteralPath $logPath -Value $kept -Encoding UTF8
        if ($removed -eq 0) {
            Write-Log "RESEND: no records match - change.log untouched" "Yellow"
        } else {
            Write-Log "RESEND: $removed record(s) removed from change.log - affected files will be sent on next scan" "Cyan"
        }
    }
    Restart-WatchIfRunning
}

function Clear-SyncDirLocal {
    # Удаляет ВСЁ содержимое SyncDir (файлы и подпапки), включая change.log,
    # и создаёт пустой change.log заново (чтобы при перезапуске слушателя
    # не выполнился снапшот). Возвращает число удалённых элементов.
    $removed = 0
    if (Test-Path $script:SyncDir) {
        foreach ($item in @(Get-ChildItem -LiteralPath $script:SyncDir -Force -ErrorAction SilentlyContinue)) {
            try {
                Remove-Item -LiteralPath $item.FullName -Recurse -Force -ErrorAction Stop
                $removed++
            } catch {
                Write-Log "CLEAR-DISK: cannot remove '$($item.FullName)' - $($_.Exception.Message)" "Yellow"
            }
        }
    }
    $script:ChangeLog   = @{}
    $script:LastLocked  = @{}
    if (-not (Test-Path $script:SyncDir)) { New-Item -ItemType Directory -Path $script:SyncDir -Force | Out-Null }
    $script:ChangeLogPath = Join-Path $script:SyncDir "change.log"
    try { Set-Content -LiteralPath $script:ChangeLogPath -Value "" -Encoding UTF8 } catch {}
    return $removed
}

function Invoke-ClearDisk {
    # FileTransfer.ps1 ClearDisk - очистить папку SyncDir на ОБОИХ контурах одной командой.
    # Локально содержимое удаляется сразу; на другой контур уходит пакет FILE_DISK_CMD,
    # который его слушатель выполняет и подтверждает очисткой буфера (ACK).
    # Если слушатель на другом конце выключен - пакет забирается обратно по таймауту.
    if (-not (Test-Path $script:SyncDir)) {
        Write-Log "CLEAR-DISK: SyncDir '$($script:SyncDir)' not found - nothing to clear" "Yellow"
        return
    }
    Add-Type -AssemblyName System.Windows.Forms

    $removedLocal = Clear-SyncDirLocal
    Write-Log "CLEAR-DISK: local '$($script:SyncDir)' cleared ($removedLocal item(s) removed)" "Cyan"

    # Перезапускаем локального слушателя, чтобы его in-memory журнал не ссылался на удалённые файлы.
    Restart-WatchIfRunning

    $payload = @{
        Marker = "FILE_DISK_CMD"
        Action = "ClearDisk"
        Origin = $env:COMPUTERNAME
    }
    $json = $payload | ConvertTo-Json -Compress

    $clipOk = $false
    $attempts = $script:ClipRetryAttempts
    while ($attempts -gt 0 -and -not $clipOk) {
        try {
            [System.Windows.Forms.Clipboard]::SetText($json)
            $clipOk = $true
        } catch {
            $attempts--
            Start-Sleep -Milliseconds $script:ClipRetryDelayMs
        }
    }
    if (-not $clipOk) {
        Write-Log "CLEAR-DISK: cannot write command to clipboard! Remote side was NOT cleared." "Red"
        $script:HasError = $true
        return
    }
    Write-Log "CLEAR-DISK: command sent - waiting for remote listener to clear its SyncDir..." "Cyan"

    $deadline = (Get-Date).AddSeconds($script:SyncAckTimeoutSec)
    $acked = $false
    while ($true) {
        Start-Sleep -Milliseconds $script:PollIntervalMs
        try {
            if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { $acked = $true; break }
        } catch { break }
        if ((Get-Date) -gt $deadline) {
            try { [System.Windows.Forms.Clipboard]::Clear() } catch {}
            break
        }
    }

    if ($acked) {
        Write-Log "CLEAR-DISK: remote listener confirmed - SyncDir is empty on BOTH sides" "Green"
        [System.Media.SystemSounds]::Asterisk.Play()
    } else {
        Write-Log "CLEAR-DISK: no ACK from remote listener (is it running?). Local SyncDir is cleared; run ClearDisk again when the remote listener is up." "Yellow"
        $script:HasError = $true
    }
}

# ===== РУЧНОЙ ПРИЁМ (UnpackTo): «СНАЧАЛА SEND, ПОТОМ RECEIVE» =====
function Invoke-ManualReceive {
    # Порядок работы «как раньше»: сначала Send на источнике, затем Receive File здесь.
    # 1) Если чужой пакет ещё лежит в буфере (слушатель выключен или не успел обработать) -
    #    принимаем его напрямую в выбранную папку.
    # 2) Иначе слушатель уже принял файлы в InDir - переносим свежепринятые
    #    (не старше ManualReceiveWindowSec секунд) из InDir в выбранную папку.
    param(
        [string]$TargetDir = $IN_DIR,
        [switch]$NoRoutes
    )

    Add-Type -AssemblyName System.Windows.Forms

    if (-not (Test-Path -LiteralPath $TargetDir)) {
        New-Item -ItemType Directory -Path $TargetDir -Force | Out-Null
    }

    # --- Шаг 1: чужой пакет прямо в буфере ---
    $packet = $null
    try {
        if ([System.Windows.Forms.Clipboard]::ContainsText()) {
            $text = [System.Windows.Forms.Clipboard]::GetText()
            if ($text -match '"Marker"\s*:\s*"(FILE_TRANSFER_DATA|FILE_CHUNK_DATA)"') {
                $origin = $env:COMPUTERNAME
                if ($text -match '"Origin"\s*:\s*"([^"]+)"') { $origin = $matches[1] }
                if ($origin -ne $env:COMPUTERNAME) { $packet = $text }
            }
        }
    } catch {}

    if ($packet) {
        try { [System.Windows.Forms.Clipboard]::Clear() } catch {}
        Write-Log "Manual receive: incoming packet found in clipboard - receiving directly to '$TargetDir'" "Cyan"
        return [bool](Unpack-Files -TargetDir $TargetDir -RawData $packet -NoRoutes:$NoRoutes)
    }

    # --- Шаг 2: слушатель уже принял файлы в InDir - переносим свежие ---
    $cutoff = (Get-Date).AddSeconds(-$script:ManualReceiveWindowSec)
    $recent = @(Get-ChildItem -Path $IN_DIR -File -ErrorAction SilentlyContinue |
        Where-Object { $_.Extension -ne '.part' -and $_.LastWriteTime -ge $cutoff })

    if ($recent.Count -eq 0) {
        Write-Log "Manual receive: clipboard has no incoming packet and no recent files in '$IN_DIR' (window $($script:ManualReceiveWindowSec) sec)" "Yellow"
        $script:HasError = $true
        return $false
    }

    # Целевая папка и есть InDir - файлы уже на месте.
    if ([System.IO.Path]::GetFullPath($TargetDir) -ieq [System.IO.Path]::GetFullPath($IN_DIR)) {
        Write-Log "Manual receive: $($recent.Count) recent file(s) already in '$IN_DIR' (target folder is InDir)" "Cyan"
        return $true
    }

    Write-Log "Manual receive: moving $($recent.Count) recent file(s) from '$IN_DIR' to '$TargetDir'..." "Cyan"
    $moved = 0
    foreach ($f in $recent) {
        $destPath = Join-Path $TargetDir $f.Name
        try {
            if (Test-Path -LiteralPath $destPath) { Remove-Item -LiteralPath $destPath -Force }
            Move-Item -LiteralPath $f.FullName -Destination $destPath -Force
            $moved++
            Write-Log "  MOVED: $($f.Name)" "Gray"
        } catch {
            Write-Log "  FAIL: cannot move '$($f.Name)' - $($_.Exception.Message)" "Red"
            $script:HasError = $true
        }
    }

    if ($moved -gt 0) {
        Write-Log "Manual receive: OK - $moved file(s) moved to '$TargetDir'" "Green"
        [System.Media.SystemSounds]::Asterisk.Play()
    }
    return ($moved -gt 0)
}

# ===== РАЗБОР АРГУМЕНТОВ И ДИСПЕТЧЕР =====
$Action = $null
$Paths  = @()
foreach ($arg in $Targets) {
    if ($arg -in @("Pack", "PackAuto", "Unpack", "UnpackTo", "Watch", "SetLocal", "DelLocal", "LocalShow", "Resend", "ClearDisk")) {
        $Action = $arg
    } else {
        $Paths += $arg
    }
}

$script:CurrentAction = if ($Action) { $Action } else { "SendFile" }

Rotate-Log
Write-Log "===== START: $($script:CurrentAction) =====" "DarkGray"

if ($Action -eq "Watch") {
    Watch-Clipboard
}
elseif ($Action -eq "Pack") {
    Pack-Files -Paths $Paths
}
elseif ($Action -eq "PackAuto") {
    # Передача флага AutoWait
    Pack-Files -Paths $Paths -AutoWait
}
elseif ($Action -eq "Unpack") {
    [void](Unpack-Files -TargetDir $IN_DIR)
}
elseif ($Action -eq "UnpackTo") {
    if ($Paths.Count -gt 0) {
        $selectedPath = $Paths[0]
        $destination = if (Test-Path $selectedPath -PathType Leaf) {
            (Get-Item $selectedPath).Directory.FullName
        } else {
            $selectedPath
        }
        [void](Invoke-ManualReceive -TargetDir $destination -NoRoutes:(-not $script:RoutesOverrideUnpackTo))
    } else {
        Write-Log "ERROR: No target path given for UnpackTo!" "Red"
        $script:HasError = $true
    }
}
elseif ($Action -eq "LocalShow") {
    Invoke-LocalShow
}
elseif ($Action -eq "SetLocal") {
    $val = if ($Paths.Count -ge 3) { ($Paths | Select-Object -Skip 2) -join " " } else { $null }
    Invoke-SetLocal -Section $Paths[0] -Key $Paths[1] -Value $val
}
elseif ($Action -eq "DelLocal") {
    Invoke-DelLocal -Section $Paths[0] -Key $Paths[1]
}
elseif ($Action -eq "Resend") {
    Invoke-Resend -Masks $Paths
}
elseif ($Action -eq "ClearDisk") {
    Invoke-ClearDisk
}
elseif ($Paths.Count -gt 0) {
    Pack-Files -Paths $Paths
}
else {
    Write-Log "No arguments. Drop files/folders on this script to pack them." "Yellow"
    $script:HasError = $true
}

$exitCode = if ($script:HasError) { 1 } else { 0 }
if ($Action -ne "Watch") {
    Write-Log "===== END: exit $exitCode =====" "DarkGray"
    exit $exitCode
}