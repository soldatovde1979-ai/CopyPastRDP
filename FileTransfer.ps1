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
    return ($v -in @("1", "true", "yes", "on"))
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
$script:ClipRetryAttempts      = [int](Get-IniValue    -Section "Settings" -Key "ClipRetryAttempts" -Default "10")
$script:ClipRetryDelayMs       = [int](Get-IniValue    -Section "Settings" -Key "ClipRetryDelayMs"  -Default "300")
$script:RoutesEnabled          = Get-IniBool -Section "Settings" -Key "RoutesEnabled"          -Default $true
$script:RoutesOverrideUnpackTo = Get-IniBool -Section "Settings" -Key "RoutesOverrideUnpackTo" -Default $true

# Рабочие каталоги и журнал
$IN_DIR   = Get-IniPath -Section "Paths" -Key "InDir"   -Default "C:\CHANGE\IN"
$OUT_DIR  = Get-IniPath -Section "Paths" -Key "OutDir"  -Default "C:\CHANGE\OUT"
$LOG_FILE = Get-IniPath -Section "Paths" -Key "LogFile" -Default "C:\CHANGE\FileTransfer.log"

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

if (-not (Test-Path $IN_DIR))  { New-Item -ItemType Directory -Path $IN_DIR  -Force | Out-Null }
if (-not (Test-Path $OUT_DIR)) { New-Item -ItemType Directory -Path $OUT_DIR -Force | Out-Null }

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
        $safeName  = [System.IO.Path]::GetFileName($data.Name)
        $dest = Resolve-Destination -FileName $safeName -TargetDir $TargetDir -NoRoutes:$NoRoutes
        if ($dest.Mask) { Write-Log "  ROUTE: '$safeName' matches '$($dest.Mask)' -> $($dest.Dir)" "Cyan" }
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
            Write-Log "SUCCESS: File '$safeName' completely assembled!" "Green"
            [System.Media.SystemSounds]::Asterisk.Play()
        }
        return $true
    }

    Write-Log "ERROR: Clipboard data does not match the marker!" "Red"
    $script:HasError = $true
    return $false
}

# ===== СЛУШАТЕЛЬ (WATCHER) =====
function Watch-Clipboard {
    param([string]$TargetDir = $IN_DIR)

    Write-Log "Started WATCH mode. Listening..." "Magenta"
    Add-Type -AssemblyName System.Windows.Forms

    while ($true) {
        Start-Sleep -Milliseconds $script:PollIntervalMs
        try {
            if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                $text = [System.Windows.Forms.Clipboard]::GetText()
                if (-not [string]::IsNullOrWhiteSpace($text) -and ($text -match '"Marker"\s*:\s*"(FILE_TRANSFER_DATA|FILE_CHUNK_DATA)"')) {

                    # Свой-чужой: пакет с Origin = имя этого же ПК положен локально этим же скриптом.
                    # Он предназначен для Watch на ДРУГОМ конце RDP - не трогаем буфер, ждём его.
                    if ($text -match '"Origin"\s*:\s*"([^"]+)"' -and $matches[1] -eq $env:COMPUTERNAME) {
                        continue
                    }

                    $script:HasError = $false
                    $processed = Unpack-Files -TargetDir $TargetDir -RawData $text

                    if ($processed) {
                        [System.Windows.Forms.Clipboard]::Clear()
                    }
                }
            }
        } catch {}
    }
}

# ===== РАЗБОР АРГУМЕНТОВ И ДИСПЕТЧЕР =====
$Action = $null
$Paths  = @()
foreach ($arg in $Targets) {
    # Добавлен PackAuto
    if ($arg -in @("Pack", "PackAuto", "Unpack", "UnpackTo", "Watch")) { $Action = $arg }
    else { $Paths += $arg }
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
        [void](Unpack-Files -TargetDir $destination -NoRoutes:(-not $script:RoutesOverrideUnpackTo))
    } else {
        Write-Log "ERROR: No target path given for UnpackTo!" "Red"
        $script:HasError = $true
    }
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