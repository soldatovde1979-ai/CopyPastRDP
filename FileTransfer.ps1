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
    [string]$Config = "",
    # -DebugLevel 0 (по умолчанию) — только ошибки, предупреждения и конечные
    # статусы операций копирования; -DebugLevel 1 — полный лог
    # (каждый чанк, heartbeat, диагностика). Приоритет: аргумент -> INI -> 0.
    # (имя DebugLevel, а не Debug: -Debug — встроенный общий параметр PowerShell)
    [int]$DebugLevel = -1
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

function Read-TextFile {
    # Чтение текста файла: UTF-8 (с BOM или без); если декодирование дало
    # replacement-символы (файл сохранён в ANSI/cp1251, например Блокнотом) —
    # перечитываем в системной кодировке. Иначе русские маски в [Routes]
    # превращаются в мусор и не совпадают никогда.
    param([string]$Path)
    $bytes  = [System.IO.File]::ReadAllBytes($Path)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
    $text   = if ($hasBom) { [System.Text.Encoding]::UTF8.GetString($bytes, 3, $bytes.Length - 3) }
              else { [System.Text.Encoding]::UTF8.GetString($bytes) }
    if ($text.Contains([string][char]0xFFFD)) {
        $text = if ($hasBom) { [System.Text.Encoding]::Default.GetString($bytes, 3, $bytes.Length - 3) }
                else { [System.Text.Encoding]::Default.GetString($bytes) }
    }
    return $text
}

function Get-IniContent {
    param([string]$Path)
    $ini = @{}
    if (-not (Test-Path $Path -PathType Leaf)) { return $ini }

    $text = Read-TextFile -Path $Path

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
# Детект простоя пользователя (клава/мышь): фоновая синхронизация не должна
# отбирать буфер во время работы. GetLastInputInfo — время с последнего ввода.
Add-Type -TypeDefinition @"
using System; using System.Runtime.InteropServices;
public static class IdleDetector {
  [StructLayout(LayoutKind.Sequential)] public struct LASTINPUTINFO { public uint cbSize; public uint dwTime; }
  [DllImport("user32.dll")] public static extern bool GetLastInputInfo(ref LASTINPUTINFO plii);
  public static uint IdleSeconds() {
    LASTINPUTINFO li = new LASTINPUTINFO();
    li.cbSize = (uint)Marshal.SizeOf(li);
    if (!GetLastInputInfo(ref li)) return 0;
    return (uint)Environment.TickCount >= li.dwTime ? ((uint)Environment.TickCount - li.dwTime) / 1000u : 0u;
  }
}
"@ -ErrorAction SilentlyContinue
function Get-UserIdleSeconds {
    # Секунды с последнего ввода (клава/мышь). При ошибке — 9999 (fail-open:
    # синхронизация продолжает работать, если детект не взведён).
    try { return [int][IdleDetector]::IdleSeconds() } catch { return 9999 }
}

# Синхронизация папки между контурами и сохранение сеанса (работают в режиме Watch)
$script:DiskSyncEnabled   = Get-IniBool -Section "Settings" -Key "DiskSyncEnabled"   -Default $false
$script:SyncPollMs        = [int](Get-IniValue -Section "Settings" -Key "SyncPollMs"        -Default "1000")
$script:SyncAckTimeoutSec = [int](Get-IniValue -Section "Settings" -Key "SyncAckTimeoutSec" -Default "60")
# Backoff после неудачной отправки (слушатель другого контура выключен): пауза
# перед повтором растёт вдвое с каждой попыткой до SyncRetryMaxDelaySec.
# По умолчанию 10 мин -> 1 час: канал либо жив, либо дёргать его чаще незачем.
$script:SyncRetryDelaySec    = [int](Get-IniValue -Section "Settings" -Key "SyncRetryDelaySec"    -Default "600")
$script:SyncRetryMaxDelaySec = [int](Get-IniValue -Section "Settings" -Key "SyncRetryMaxDelaySec" -Default "3600")
# Сторож простоя: фоновая синхронизация не трогает буфер, пока пользователь
# работает (нет клавише/мыши меньше SyncIdleGuardSec секунд). 0 — выключить.
$script:SyncIdleGuardSec = [int](Get-IniValue -Section "Settings" -Key "SyncIdleGuardSec" -Default "4")
# Быстрый ACK фоновой синхронизации: живой приёмник забирает чанк за 1-3 сек.
# Не забрал — канал недоступен: буфер возвращается сразу, повтор по backoff.
$script:SyncAckFastSec = [int](Get-IniValue -Section "Settings" -Key "SyncAckFastSec" -Default "3")
# Пакетная отправка: если в очереди синхронизации столько НОВЫХ элементов (файлов
# + папок), они отправляются одним ZIP-архивом вместо тысяч отдельных пакетов.
$script:SyncBatchFiles = [int](Get-IniValue -Section "Settings" -Key "SyncBatchFiles" -Default "50")
$script:KeepAliveMinutes  = [int](Get-IniValue -Section "Settings" -Key "KeepAliveMinutes"  -Default "0")
# Самообновление через папку синхронизации: принятые в SyncDir файлы
# FileTransfer.ps1 / setcp.ini копируются в каталог скрипта и слушатель перезапускается.
$script:AutoUpdate = Get-IniBool -Section "Settings" -Key "AutoUpdate" -Default $true
# Диагностика слушателя: периодический heartbeat в журнал (0 — выключен)
# и подробный trace-режим с причинами каждого действия (0/1).
$script:WatchHeartbeatSec = [int](Get-IniValue -Section "Settings" -Key "WatchHeartbeatSec" -Default "60")
$script:WatchTrace        = Get-IniBool -Section "Settings" -Key "WatchTrace"        -Default $false

# Режим журналирования: DebugLevel=0 — подробные строки (прогресс, диагностика)
# не пишутся ни в журнал, ни в консоль; DebugLevel=1 — полный лог.
if ($DebugLevel -lt 0) { $DebugLevel = [int](Get-IniValue -Section "Settings" -Key "Debug" -Default "0") }
$script:DebugEnabled = ($DebugLevel -ne 0)
$script:ProgressActivity = "CopyPast"

# Рабочие каталоги и журнал
$IN_DIR   = Get-IniPath -Section "Paths" -Key "InDir"   -Default "C:\CHANGE\IN"
$OUT_DIR  = Get-IniPath -Section "Paths" -Key "OutDir"  -Default "C:\CHANGE\OUT"
$LOG_FILE = Get-IniPath -Section "Paths" -Key "LogFile" -Default "C:\CHANGE\FileTransfer.log"

# Папка синхронизации между контурами (на обоих контурах путь должен совпадать)
$script:SyncDir = Get-IniPath -Section "Paths" -Key "SyncDir" -Default "C:\CHANGE\disk"
if ($script:SyncDir.Length -gt 3) { $script:SyncDir = $script:SyncDir.TrimEnd('\', '/') }

# Маршрутизация приёма по маскам имён файлов (секция [Routes] файла setcp.ini)
function Update-Routes {
    # Перечитывает [Routes] из setcp.ini (+ setcp.local.ini) на лету: правки
    # маршрутов подхватываются приёмником БЕЗ перезапуска слушателя.
    # Нужна из-за кириллицы и пробелов в масках: одна и та же секция читается
    # каждый раз при приёме пакета, а не один раз при старте.
    $merged = Get-IniContent -Path $script:ConfigPath
    $local  = Get-IniContent -Path $script:LocalConfigPath
    foreach ($sec in $local.Keys) {
        if (-not $merged.ContainsKey($sec)) { $merged[$sec] = @{} }
        foreach ($key in $local[$sec].Keys) { $merged[$sec][$key] = $local[$sec][$key] }
    }
    $script:Routes = @()
    if ($merged.ContainsKey("Routes")) {
        foreach ($mask in $merged["Routes"].Keys) {
            $target = [Environment]::ExpandEnvironmentVariables([string]$merged["Routes"][$mask])
            if (-not [string]::IsNullOrWhiteSpace($target)) {
                $script:Routes += [pscustomobject]@{ Mask = $mask; Target = $target }
            }
        }
    }
}
Update-Routes

# Уникальный ID машины (MachineId из setcp.local.ini, создаётся Install.ps1):
# зашит в Origin всех пакетов. Защищает механизм «свой-чужой» от совпадения
# COMPUTERNAME на двух контурах (без ID пакеты молча игнорировались бы).
$script:MachineId = Get-IniValue -Section "Settings" -Key "MachineId" -Default ""
$script:OwnOrigin = if ($script:MachineId) { "$env:COMPUTERNAME@$script:MachineId" } else { $env:COMPUTERNAME }

$script:HasError = $false

# Флаг самообновления: устанавливается приёмником после применения FileTransfer.ps1/setcp.ini,
# по нему Watch перезапускает себя с новым кодом.
$script:RestartNeeded = $false

# Занятые файлы SyncDir (для логирования только перехода состояния, без спама каждую секунду)
$script:LastLocked = @{}

# Backoff отправки: relpath -> @{ Key; Failures; NextAttempt }. Ключ — sync-ключ
# объекта: изменился файл (новое содержимое) — счётчик неудач сбрасывается.
$script:SendFailures = @{}

# Блок фоновых отправок служебных карточек (status-*/progress-*): после первой
# же неудачи карточки не ретраятся вовсе. Разблокировка — при успешной реальной
# передаче (канал жив). Иначе карточка, переписываемая heartbeat'ом каждые 30 сек
$script:ServiceSendBlocked = $false

# Кэш панели «Другой ПК» командера: наполняется из status-*.json и живёт до
# нажатия «Обновить» (/refresh-remote) — панель не дёргается при каждом рендере.
$script:RemoteFilesCache = $null
$script:RemoteFilesMachine = ""
$script:RemoteFilesTime = ""

# Разговоживание строк «НЕ ПЕРЕДАНО»: один и тот же путь логируется не чаще
# раза в FailLogIntervalSec — иначе лежащая удалёнка заливает журнал каждый backoff.
$script:LastFailLog = @{}
$script:FailLogIntervalSec = 600

# Старты приёма файлов (FileId -> время первого чанка) — для строки «ПРИНЯТО за N сек»
$script:ReceiveStarts = @{}

# Единый фильтр «значимых» событий: и в status-файл, и в историю дашборда.
# Один источник — фильтры не разъезжаются (правка в одном месте).
$script:DashboardEventPattern = 'ОТПРАВКА|ОТПРАВЛЕНО|ПРИЁМ|ПРИНЯТО|НЕ ПЕРЕДАНО|FAIL|FATAL|ERROR|WARNING|CLEAR-DISK|DEL-MARKER|AUTOUPDATE|DROP|CMD:'

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
    # Debug=0: подробные строки (Gray/DarkGray/Cyan — прогресс, диагностика,
    # heartbeat) не пишутся ни в консоль, ни в журнал. Остаются ошибки (Red),
    # предупреждения (Yellow), конечные статусы (Green) и служебные (White/Magenta).
    # Маркеры START/END пишутся всегда — по ним виден итог сеанса.
    if (-not $script:DebugEnabled -and $Color -in @("Gray", "DarkGray", "Cyan") -and
        $Message -notmatch '^===== (START|END)') { return }
    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $label = if ($script:CurrentAction) { $script:CurrentAction } else { "SendFile" }
    try { Add-Content -Path $LOG_FILE -Value "[$timestamp] [$label] $Message" -Encoding UTF8 }
    catch { Write-Host "WARNING: журнал недоступен: $($_.Exception.Message)" -ForegroundColor Yellow }
    Write-Host $Message -ForegroundColor $Color
}

function Rotate-Log {
    try {
        if (Test-Path $LOG_FILE) {
            # Дешёвая проверка размера до чтения: heartbeat вызывает ротацию каждую минуту
            $sizeGuard = [math]::Max($script:MaxLogLines * 64, 256KB)
            if ((Get-Item $LOG_FILE -ErrorAction Stop).Length -lt $sizeGuard) { return }
            $lines = Get-Content $LOG_FILE -Encoding UTF8
            if ($lines.Count -gt $script:MaxLogLines) {
                $lines | Select-Object -Last $script:MaxLogLines | Set-Content $LOG_FILE -Encoding UTF8
            }
        }
    } catch {}
}

# ===== ПРОГРЕСС ПЕРЕДАЧ (для веб-дашборда) =====
# Watch/PackAuto пишет progress-<имя ПК>.json в корень SyncDir на каждый чанк;
# дашборд читает его и рисует полосу прогресса. Файл уезжает синхронизацией,
# поэтому «едет ко мне / от меня» видно на ОБОИХ контурах. По завершении или
# ошибке файл удаляется.
function Update-ProgressState {
    param(
        [string]$Name, [int]$Chunk, [int]$Total,
        [ValidateSet("send", "recv")][string]$Dir,
        [datetime]$Started
    )
    try {
        $st = @{
            Machine = $env:COMPUTERNAME
            File    = $Name
            Dir     = $Dir
            Chunk   = $Chunk
            Total   = $Total
            Started = $Started.ToString("yyyy-MM-dd HH:mm:ss")
        }
        $p = Join-Path $script:SyncDir ("progress-{0}.json" -f $env:COMPUTERNAME)
        $st | ConvertTo-Json -Compress | Set-Content -LiteralPath $p -Encoding UTF8
    } catch {}
}

function Clear-ProgressState {
    Remove-Item -LiteralPath (Join-Path $script:SyncDir ("progress-{0}.json" -f $env:COMPUTERNAME)) -Force -ErrorAction SilentlyContinue
}

# ===== ОБЩАЯ ЧАНКОВАЯ ОТПРАВКА (Pack и синхронизация) =====
function Send-FileInChunks {
    # Режет файл на чанки FILE_CHUNK_DATA и кладёт их в буфер, дожидаясь ACK
    # после каждого. Единая реализация для ручной отправки (Pack/PackAuto)
    # и синхронизации: правка протокола в одном месте.
    # SyncMode: ACK с таймаутом и возвратом пакета (Wait-SyncAck);
    # без SyncMode отправитель ждёт ACK бесконечно (как раньше в Pack).
    param(
        [System.IO.FileInfo]$File,
        [string]$RelPath = "",
        [switch]$SyncMode
    )

    $chunkSizeBytes = $ChunkSizeMB * 1MB
    $totalChunks = [math]::Ceiling($File.Length / $chunkSizeBytes)
    if ($totalChunks -eq 0) { $totalChunks = 1 }
    $fileGuid = [guid]::NewGuid().ToString("N")

    # MD5 всего файла: приёмник сверяет собранный файл и отбраковывает битое
    try { $fileHash = (Get-FileHash -LiteralPath $File.FullName -Algorithm MD5).Hash } catch { $fileHash = "" }

    $fileHash = ""
    try { $fileHash = (Get-FileHash -LiteralPath $File.FullName -Algorithm MD5).Hash } catch {}

    # Окно не показываем принудительно (не мешает работе): история доступна
    # командой History и в журнале
    $stage = if ($RelPath) { "ОТПРАВКА на другой ПК: $RelPath" } else { "ОТПРАВКА на другой ПК: $($File.Name)" }
    $script:ProgressActivity = "CopyPast — $stage"
    Write-Progress -Activity $script:ProgressActivity -Status "0 из $([math]::Ceiling($File.Length / 1MB)) МБ" -PercentComplete 0 -ErrorAction SilentlyContinue

    $savedClip = Save-ClipText
    $sendStart = Get-Date
    # Старт операции с параметрами (виден всегда; служебные status-файлы — нет):
    # файл, объём, число чанков — чтобы по журналу было ясно, ЧТО копируется
    if ($RelPath -notmatch '^(status|progress)-') {
        Write-Log "ОТПРАВКА: '$(if ($RelPath) { $RelPath } else { $File.Name })' ($([math]::Round($File.Length / 1MB, 2)) МБ, $totalChunks чанк(ов)) на другой ПК" "White"
        Update-ProgressState -Name $(if ($RelPath) { $RelPath } else { $File.Name }) -Chunk 0 -Total $totalChunks -Dir send -Started $sendStart
    }
    $stream = [System.IO.File]::OpenRead($File.FullName)
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
                ChunkIndex  = $chunkIndex
                TotalChunks = $totalChunks
                Hash        = $fileHash
                Content     = [Convert]::ToBase64String($actualBytes)
                Origin      = $script:OwnOrigin
            }
            if ($RelPath) { $payload.RelPath = $RelPath }

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
                Write-Progress -Activity $script:ProgressActivity -Completed -ErrorAction SilentlyContinue
                Clear-ProgressState
                Restore-ClipText $savedClip
                return $false
            }

            Write-Log "   -> Chunk $chunkIndex/$totalChunks sent. Waiting for ACK..." "Gray"

            if ($SyncMode) {
                # Пользователь вернулся к работе посреди отправки — снимаемся:
                # буфер важнее; недоотправленный файл уедет в следующее окно простоя
                if ($script:SyncIdleGuardSec -gt 0 -and (Get-UserIdleSeconds) -lt $script:SyncIdleGuardSec) {
                    Write-Log "SYNC: '$RelPath' отложено — пользователь вернулся к работе" "DarkGray"
                    Write-Progress -Activity $script:ProgressActivity -Completed -ErrorAction SilentlyContinue
                    Clear-ProgressState
                    try { [System.Windows.Forms.Clipboard]::Clear() } catch {}
                    Restore-ClipText $savedClip
                    return $false
                }
                if (-not (Wait-SyncAck -RelPath $RelPath -TimeoutSec $script:SyncAckFastSec)) {
                    Write-Progress -Activity $script:ProgressActivity -Completed -ErrorAction SilentlyContinue
                    Clear-ProgressState
                    Notify-WatchFailure
                    Restore-ClipText $savedClip
                    return $false
                }
            } else {
                # Ручная отправка: если приёмник не забрал чанк за SyncAckTimeoutSec —
                # обрываем передачу (иначе отправка висела бы вечно). Файл НЕ удаляется.
                $ackDeadline = (Get-Date).AddSeconds($script:SyncAckTimeoutSec)
                $acked = $false
                while ((Get-Date) -lt $ackDeadline) {
                    Start-Sleep -Milliseconds $script:PollIntervalMs
                    try {
                        if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { $acked = $true; break }
                    } catch { $acked = $true; break }
                }
                if (-not $acked) {
                    Write-Log "FATAL: receiver did not pick up chunk $chunkIndex/$totalChunks within $script:SyncAckTimeoutSec sec - transfer aborted, file kept. Is the listener running on the other side?" "Red"
                    $script:HasError = $true
                    Write-Progress -Activity $script:ProgressActivity -Completed -ErrorAction SilentlyContinue
                    Clear-ProgressState
                    Restore-ClipText $savedClip
                    return $false
                }
            }

            $chunkIndex++
            Write-Progress -Activity $script:ProgressActivity -Status "передано $([math]::Round(($chunkIndex-1) * $ChunkSizeMB, 0)) из $([math]::Ceiling($File.Length / 1MB)) МБ" -PercentComplete ([math]::Min(99, [int](100 * ($chunkIndex-1) / $totalChunks))) -ErrorAction SilentlyContinue
            Update-ProgressState -Name $(if ($RelPath) { $RelPath } else { $File.Name }) -Chunk ($chunkIndex - 1) -Total $totalChunks -Dir send -Started $sendStart
            if ($File.Length -eq 0) { break }
        }
    } finally {
        $stream.Close()
        $stream.Dispose()
    }

    Restore-ClipText $savedClip
    Write-Progress -Activity $script:ProgressActivity -Completed -ErrorAction SilentlyContinue
    # Итоговая строка (видна всегда): что, куда, объём, время.
    # Служебные статус-файлы дашборда не логируем — они едут каждые 30 сек.
    Clear-ProgressState
    if ($RelPath -notmatch '^(status|progress)-') {
        $durSec = [int]((Get-Date) - $sendStart).TotalSeconds
        $sizeMb = [math]::Round($File.Length / 1MB, 2)
        Write-Log "ОТПРАВЛЕНО: '$(if ($RelPath) { $RelPath } else { $File.Name })' ($sizeMb МБ, $totalChunks чанк(ов)) на другой ПК за $durSec сек" "White"
    }
    return $true
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
            Origin    = $script:OwnOrigin
        }

        $i = 0
        foreach ($f in $files) {
            $i++
            Write-Log "  [$i/$($files.Count)] $($f.Name) ($([math]::Round($f.Length/1KB,1)) KB)" "Gray"
            try {
                $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
                # MD5 файла: приёмник сверяет и отбраковывает битое
                $md5 = [System.Security.Cryptography.MD5]::Create()
                try { $hash = [BitConverter]::ToString($md5.ComputeHash($bytes)).Replace('-', '') } finally { $md5.Dispose() }
                $data.Files += @{ Name = $f.Name; Content = [Convert]::ToBase64String($bytes); Hash = $hash }
            } catch {
                Write-Log "  FAIL: $($f.Name) - $($_.Exception.Message)" "Red"
                $script:HasError = $true
            }
        }

        $json = $data | ConvertTo-Json -Compress -Depth 10

        $savedClip = Save-ClipText
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
                $ackDeadline = (Get-Date).AddSeconds($script:SyncAckTimeoutSec)
                while ($true) {
                    Start-Sleep -Milliseconds $script:PollIntervalMs
                    try {
                        if (-not [System.Windows.Forms.Clipboard]::ContainsText()) {
                            Write-Log "SUCCESS: Receiver confirmed pick up!" "Green"
                            # Пакет забран приёмником - возвращаем пользователю его текст буфера
                            Restore-ClipText $savedClip
                            break
                        }
                    } catch {}
                    if ((Get-Date) -gt $ackDeadline) {
                        Write-Log "WARNING: receiver did not pick up the packet within $script:SyncAckTimeoutSec sec - data stays in the clipboard" "Yellow"
                        break
                    }
                }
            }
        }

    # Почаночный режим для крупных файлов (> 10 МБ)
    } else {
        Write-Log "Chunk-mode: Packing $($files.Count) file(s) ($totalSizeMB MB) in $ChunkSizeMB MB chunks..." "Cyan"

        foreach ($file in $files) {
            if (Send-FileInChunks -File $file) {
                if ($file.Directory.FullName -ieq $OUT_DIR) { Remove-Item $file.FullName -Force }
                Write-Log "SUCCESS: '$($file.Name)' fully transferred!" "Green"
            }
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

    # Маршруты перечитываются на лету: правки [Routes] в setcp.ini
    # подхватываются приёмником без перезапуска слушателя.
    Update-Routes

    $clipData = $RawData
    if (-not $clipData) {
        try {
            Add-Type -AssemblyName System.Windows.Forms
            if ([System.Windows.Forms.Clipboard]::ContainsText()) {
                $clipData = [System.Windows.Forms.Clipboard]::GetText()
            }
        } catch {
            # Фолбэк без дублирования: Get-Clipboard -Raw возвращает текст целиком
            try { $clipData = Get-Clipboard -Raw } catch {}
        }
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

                $bytes = [Convert]::FromBase64String($item.Content)

                # Сверка MD5, если отправитель передал хеш: битый файл не сохраняется
                $itemHash = $null
                if ($item.PSObject.Properties['Hash']) { $itemHash = [string]$item.Hash }
                if ($itemHash) {
                    $md5 = [System.Security.Cryptography.MD5]::Create()
                    try { $gotHash = [BitConverter]::ToString($md5.ComputeHash($bytes)).Replace('-', '') } finally { $md5.Dispose() }
                    if ($gotHash -ne $itemHash) {
                        Write-Log "  FAIL: $safeName - MD5 mismatch ($gotHash <> $itemHash)" "Red"
                        $script:HasError = $true
                        continue
                    }
                }

                [System.IO.File]::WriteAllBytes($outPath, $bytes)
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
            # Маркер удаления .del маршрутизации не подлежит: он всегда
            # сохраняется в КОРЕНЬ SyncDir, иначе очистка на этом контуре не сработает.
            # .synczip (пакетный архив) — тоже строго в корень.
            if ($script:RoutesEnabled -and $syncRel -ne '.del' -and $syncRel -notmatch '\.synczip$') {
                if ($safeName -notmatch '^(status|progress)-') {
                    foreach ($route in $script:Routes) {
                        if ($safeName -like $route.Mask) {
                            $syncTarget = $route.Target
                            $routeMask  = $route.Mask
                            break
                        }
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
        if ($data.ChunkIndex -gt 1 -and -not (Test-Path $partPath)) {
            # Пропущен чанк 1 (не дошёл/не собран) - дописывать некуда,
            # передача начнётся заново со следующего скана/попытки
            Write-Log "FAIL: chunk $($data.ChunkIndex) for '$safeName' but '.part' is missing - transfer restarts" "Red"
            $script:HasError = $true
            Clear-ProgressState
            return $false
        }

        $bytes = [Convert]::FromBase64String($data.Content)
        if (-not $script:ReceiveStarts.ContainsKey($data.FileId)) { $script:ReceiveStarts[$data.FileId] = Get-Date }
        $outStream = New-Object System.IO.FileStream($partPath, [System.IO.FileMode]::Append, [System.IO.FileAccess]::Write, [System.IO.FileShare]::None)
        try {
            if ($bytes.Length -gt 0) { $outStream.Write($bytes, 0, $bytes.Length) }
        } finally {
            $outStream.Close()
            $outStream.Dispose()
        }

        Write-Log "Received chunk $($data.ChunkIndex)/$($data.TotalChunks) for '$safeName'" "Gray"
        # Старт приёма с параметрами (виден всегда; служебные статус-файлы — нет)
        if ($safeName -notmatch '^(status|progress)-') {
            if ($data.ChunkIndex -eq 1) {
                # ВНИМАНИЕ: только $() внутри строки — "$data.TotalChunks" развернёт
                # весь объект $data вместе с Content (base64-чанк) в строку лога
                Write-Log "ПРИЁМ: '$safeName' ($([math]::Round($data.TotalChunks * $ChunkSizeMB, 0)) МБ, $($data.TotalChunks) чанк(ов)) с другого ПК" "White"
            }
            $rStart0 = if ($script:ReceiveStarts.ContainsKey($data.FileId)) { $script:ReceiveStarts[$data.FileId] } else { Get-Date }
            Update-ProgressState -Name $safeName -Chunk $data.ChunkIndex -Total $data.TotalChunks -Dir recv -Started $rStart0
            Write-Progress -Activity "CopyPast — ПРИЁМ с другого ПК: $safeName" -Status "чанк $($data.ChunkIndex) из $($data.TotalChunks)" -PercentComplete ([math]::Min(99, [int](100 * $data.ChunkIndex / $data.TotalChunks))) -ErrorAction SilentlyContinue
        }

        if ($data.ChunkIndex -eq $data.TotalChunks) {
            if (Test-Path $finalPath) { Remove-Item $finalPath -Force }
            Move-Item $partPath $finalPath -Force

            # Контроль целостности: MD5 собранного файла против хеша из пакета.
            # Битая сборка удаляется - отправитель перешлёт файл целиком.
            $expectHash = $null
            if ($data.PSObject.Properties['Hash']) { $expectHash = [string]$data.Hash }
            if ($expectHash) {
                $gotHash = (Get-FileHash -LiteralPath $finalPath -Algorithm MD5 -ErrorAction SilentlyContinue).Hash
                if ($gotHash -and ($gotHash -ne $expectHash)) {
                    Write-Log "FAIL: MD5 mismatch for '$safeName' ($gotHash <> $expectHash) - file deleted, will be resent" "Red"
                    Remove-Item $finalPath -Force -ErrorAction SilentlyContinue
                    $script:HasError = $true
                    Clear-ProgressState
                    return $false
                }
            }

            if ($syncRel) {
                # Пакетный архив: распаковываем в SyncDir вместо обычного сохранения
                if ($syncRel -match '\.synczip$') {
                    Write-Log "SUCCESS: batch archive '$safeName' received" "Green"
                    [void](Expand-SyncBatch -ZipPath $finalPath)
                    [System.Media.SystemSounds]::Asterisk.Play()
                    return $true
                }
                # Помечаем принятый файл как обработанный, чтобы не отправить его обратно (петля)
                $item = Get-Item $finalPath -ErrorAction SilentlyContinue
                if ($item) { Add-ChangeEntry -Type "RECEIVED" -RelPath $syncRel -Item $item }
                # Служебные файлы дашборда не логируем — едут постоянно
                if ($safeName -notmatch '^(status|progress)-') {
                    Write-Log "SUCCESS: Sync file '$syncRel' completely assembled!" "Green"
                }
                $rStart = $script:ReceiveStarts[$data.FileId]
                $dur = if ($rStart) { [int]((Get-Date) - $rStart).TotalSeconds } else { 0 }
                $script:ReceiveStarts.Remove($data.FileId)
                if ($safeName -notmatch '^(status|progress)-') {
                    $sizeMbR = [math]::Round((Get-Item -LiteralPath $finalPath).Length / 1MB, 2)
                    Write-Log "ПРИНЯТО: '$safeName' ($sizeMbR МБ, $($data.TotalChunks) чанк(ов)) с другого ПК за $dur сек" "White"
                }
                Clear-ProgressState

                # Самообновление: файлы FileTransfer.ps1 / setcp.ini, пришедшие в корень SyncDir,
                # применяются в каталог запущенного скрипта, после чего слушатель перезапускается.
                if ($script:AutoUpdate -and $syncRel -notmatch '/' -and $safeName -in @('FileTransfer.ps1', 'setcp.ini', 'dashboard.html')) {
                    # .ps1 перед применением проверяется синтаксически: битое
                    # обновление (обрыв передачи) убил бы слушателя на обоих контурах
                    $apply = $true
                    if ($safeName -eq 'FileTransfer.ps1') {
                        $perrs = $null
                        [void][System.Management.Automation.Language.Parser]::ParseFile($finalPath, [ref]$null, [ref]$perrs)
                        if ($perrs -and $perrs.Count -gt 0) {
                            Write-Log "AUTOUPDATE: '$safeName' FAILED syntax check ($($perrs[0].Message)) - update rejected" "Red"
                            Remove-Item $finalPath -Force -ErrorAction SilentlyContinue
                            $apply = $false
                        }
                    }
                    if ($apply) {
                        $rootDir = Split-Path -Parent $PSCommandPath
                        try {
                            # Файл с тем же содержимым не применяем и не рестартуем —
                            # иначе два контура вечно перекидываются копиями (restart-петля)
                            $currentPath = Join-Path $rootDir $safeName
                            $same = $false
                            if (Test-Path $currentPath) {
                                $h1 = (Get-FileHash -LiteralPath $finalPath -Algorithm MD5).Hash
                                $h2 = (Get-FileHash -LiteralPath $currentPath -Algorithm MD5).Hash
                                $same = ($h1 -eq $h2)
                            }
                            if ($same) {
                                Write-Log "AUTOUPDATE: '$safeName' is identical - skipped" "DarkGray"
                            } else {
                                Copy-Item -Path $finalPath -Destination $currentPath -Force
                                Write-Log "AUTOUPDATE: '$safeName' applied to $rootDir - listener will restart" "Cyan"
                                $script:RestartNeeded = $true
                            }
                        } catch {
                            Write-Log "AUTOUPDATE: FAILED to apply '$safeName' - $($_.Exception.Message)" "Red"
                        }
                    }
                }
            } else {
                $rStart = $script:ReceiveStarts[$data.FileId]
                $dur = if ($rStart) { [int]((Get-Date) - $rStart).TotalSeconds } else { 0 }
                $script:ReceiveStarts.Remove($data.FileId)
                if ($safeName -notmatch '^(status|progress)-') {
                    $sizeMbR = [math]::Round((Get-Item -LiteralPath $finalPath).Length / 1MB, 2)
                    Write-Log "ПРИНЯТО: '$safeName' ($sizeMbR МБ, $($data.TotalChunks) чанк(ов)) с другого ПК за $dur сек" "White"
                }
                Clear-ProgressState
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
        Get-ChildItem -Path $script:SyncDir -Directory -Recurse -ErrorAction SilentlyContinue |
            ForEach-Object {
                Add-DirChangeEntry -Type "SNAPSHOT" -RelPath (Get-RelPath -FullName $_.FullName)
                $count++
            }
        Write-Log "SYNC: change.log created/rotated, $count file(s) marked as snapshot." "DarkGray"
    } elseif ($loaded -gt 0) {
        Write-Log "SYNC: change.log loaded ($loaded records)." "DarkGray"
    }
    # Файлы, которых нет в журнале, считаются новыми и будут отправлены
    # при первом же сканировании (даже если слушатель был выключен).
    $script:ChangeLogMtime = (Get-Item -LiteralPath $script:ChangeLogPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
}

function Test-ChangeLogExternal {
    # True, если change.log переписан извне (командер через Web-процесс):
    # слушатель перечитывает журнал сам, без перезапуска — никакие окна не мелькают.
    if (-not $script:ChangeLogPath) { return }
    $mt = (Get-Item -LiteralPath $script:ChangeLogPath -ErrorAction SilentlyContinue).LastWriteTimeUtc
    if ($mt -and $script:ChangeLogMtime -and $mt -ne $script:ChangeLogMtime) {
        $script:ChangeLog = @{}
        foreach ($line in @(Get-Content -LiteralPath $script:ChangeLogPath -Encoding UTF8)) {
            if ($line -match '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\|(SENT|RECEIVED|SNAPSHOT|LOCKED)\|(.+)\|(\d+)\|(\d+)$') {
                $script:ChangeLog["$($matches[2])|$($matches[3])|$($matches[4])"] = $matches[1]
            }
        }
        $script:ChangeLogMtime = $mt
        Write-Log "SYNC: change.log перечитан (внешнее изменение из командера)" "DarkGray"
    }
    if (-not $script:ChangeLogMtime -or $script:ChangeLogMtime -ne $mt) { $script:ChangeLogMtime = $mt }
}

function Wait-SyncAck {
    # Ждёт очистки буфера приёмником. При таймауте забирает свой пакет обратно,
    # чтобы Watch не завис навсегда (слушатель на другом конце может быть выключен).
    param([string]$RelPath, [int]$TimeoutSec = 0)
    # Ждём приёмника не дольше SyncAckFastSec: живой приёмник забирает чанк за
    # 1-3 сек; дольше ждать — держать буфер занятым JSON-пакетом без пользы.
    $ackTimeout = if ($TimeoutSec -gt 0) { $TimeoutSec } else { $script:SyncAckFastSec }
    $deadline = (Get-Date).AddSeconds($ackTimeout)
    while ($true) {
        Start-Sleep -Milliseconds $script:PollIntervalMs
        try {
            if (-not [System.Windows.Forms.Clipboard]::ContainsText()) { return $true }
        } catch {
            return $false
        }
        if ((Get-Date) -gt $deadline) {
            try { [System.Windows.Forms.Clipboard]::Clear() } catch {}
            # Лог и звук — не чаще раза в FailLogIntervalSec на путь: лежащая
            # удалёнка не должна заливать журнал и дёргать звуком каждый backoff
            $lastLog = $script:LastFailLog[$RelPath]
            if (-not $lastLog -or ((Get-Date) - $lastLog).TotalSeconds -gt $script:FailLogIntervalSec) {
                Write-Log "НЕ ПЕРЕДАНО: '$RelPath' — приёмник не отвечает (ждали $ackTimeout сек), повтор по расписанию backoff" "Yellow"
                $script:LastFailLog[$RelPath] = Get-Date
                Notify-WatchFailure
            }
            return $false
        }
    }
}

function Save-ClipText {
    # Текст и список файлов буфера перед отправкой пакета, чтобы вернуть их
    # после попытки: пользователь не должен находить в буфере JSON вместо
    # своего текста и терять скопированные в проводнике файлы.
    try {
        $saved = @{ Text = $null; Files = $null }
        if ([System.Windows.Forms.Clipboard]::ContainsText()) { $saved.Text = [System.Windows.Forms.Clipboard]::GetText() }
        if ([System.Windows.Forms.Clipboard]::ContainsFileDropList()) { $saved.Files = [System.Windows.Forms.Clipboard]::GetFileDropList() }
        if (-not $saved.Text -and -not $saved.Files) { return $null }
        return $saved
    } catch {}
    return $null
}

function Restore-ClipText {
    # Возврат содержимого буфера после отправки/неудачи: текст или файлы.
    param($Saved)
    if (-not $Saved) { return }
    try {
        if ($Saved.Text) { [void][System.Windows.Forms.Clipboard]::SetText($Saved.Text); return }
        if ($Saved.Files -and $Saved.Files.Count -gt 0) { [void][System.Windows.Forms.Clipboard]::SetFileDropList($Saved.Files) }
    } catch {}
}

function Test-SyncRetryReady {
    # True, если отправку можно повторять: неудач не было, изменился объект
    # (новый sync-ключ) или истёк срок backoff после прошлой неудачи.
    param([string]$RelPath, [string]$SyncKey)
    $rec = $script:SendFailures[$RelPath]
    if (-not $rec) { return $true }
    if ($rec.Key -ne $SyncKey) { return $true }
    return ((Get-Date) -ge $rec.NextAttempt)
}

function Register-SyncFailure {
    # Неудачная отправка: увеличиваем счётчик и откладываем повтор (backoff),
    # чтобы не забивать буфер обмена повторами каждое сканирование.
    param([string]$RelPath, [string]$SyncKey)
    $rec = $script:SendFailures[$RelPath]
    if (-not $rec -or $rec.Key -ne $SyncKey) { $rec = @{ Key = $SyncKey; Failures = 0 } }
    $rec.Failures++
    $delay = [math]::Min($script:SyncRetryDelaySec * [math]::Pow(2, $rec.Failures - 1), $script:SyncRetryMaxDelaySec)
    $rec.NextAttempt = (Get-Date).AddSeconds($delay)
    $script:SendFailures[$RelPath] = $rec
    Write-Log "SYNC: '$RelPath' next attempt in $([int]$delay) sec (failure #$($rec.Failures))" "DarkGray"
}

function Clear-SyncFailure {
    param([string]$RelPath)
    $script:SendFailures.Remove($RelPath) | Out-Null
}

function Get-DirKey {
    # Стабильный ключ папки для change.log: не зависит от времени изменения
    # папки (оно меняется при любом изменении содержимого).
    param([string]$RelPath)
    $relNorm = ($RelPath -replace '\\', '/').ToLowerInvariant()
    return "dir/$relNorm|0|0"
}

function Add-DirChangeEntry {
    # Запись о папке в change.log (тип SENT/RECEIVED/SNAPSHOT).
    param([string]$Type, [string]$RelPath)
    $key = Get-DirKey -RelPath $RelPath
    $script:ChangeLog[$key] = $Type
    if (-not $script:ChangeLogPath) { return }
    $relNorm = ($RelPath -replace '\\', '/').ToLowerInvariant()
    $line = "{0}|{1}|{2}|{3}|{4}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Type, "dir/$relNorm", 0, 0
    try { Add-Content -LiteralPath $script:ChangeLogPath -Value $line -Encoding UTF8 } catch {}
}

# ===== ОКНА: ПРОГРЕСС И ОПОВЕЩЕНИЯ =====
# Win32-обёртка для показа/свёртывания консоли длительных операций
Add-Type -Namespace CopyPast -Name Console -MemberDefinition '
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);' `
    -ErrorAction SilentlyContinue

function Show-ConsoleWindow {
    # Показывает окно консоли (ярлыки SendTo запускают свёрнуто, Watch — скрыто):
    # длительные операции должны быть видны. SW_SHOWNOACTIVATE=4 — не крадёт фокус.
    try {
        $h = [CopyPast.Console]::GetConsoleWindow()
        if ($h -and $h -ne [IntPtr]::Zero) { [void][CopyPast.Console]::ShowWindow($h, 4) }
    } catch {}
}

function Hide-ConsoleWindow {
    try {
        $h = [CopyPast.Console]::GetConsoleWindow()
        if ($h -and $h -ne [IntPtr]::Zero) { [void][CopyPast.Console]::ShowWindow($h, 6) }  # SW_MINIMIZE=6
    } catch {}
}

function Show-Alert {
    # Оповещение о проблеме: TimeoutSec=0 — окно ждёт OK (пользовательские
    # операции), >0 — закрывается само (фоновые события, чтобы не копить окна)
    param([string]$Text, [string]$Title = "CopyPast", [int]$TimeoutSec = 0)
    try {
        $sh = New-Object -ComObject WScript.Shell
        [void]$sh.Popup($Text, $TimeoutSec, $Title, 48)  # 48 = иконка "!"
    } catch {}
}

function Notify-WatchFailure {
    # Приёмник не отвечает: окно для пользователя. Не чаще раза в 10 минут,
    # иначе очередь из сотен файлов засыплет окнами
    if ($script:LastFailNotify -and (((Get-Date) - $script:LastFailNotify).TotalMinutes -lt 10)) { return }
    $script:LastFailNotify = Get-Date
    Show-Alert -Text "Синхронизация CopyPast: приёмник не отвечает (ACK timeout).`nОтправка будет повторена автоматически.`n`nПодробности: $LOG_FILE" `
        -Title "CopyPast: приёмник не отвечает" -TimeoutSec 15
}

function Send-SyncFile {
    # Отправка файла из SyncDir чанками на тот же относительный путь (RelPath)
    # в другом контуре. Общая чанковая логика - в Send-FileInChunks.
    param(
        [System.IO.FileInfo]$File,
        [string]$RelPath
    )

    Write-Log "SYNC: Sending '$RelPath' ($([math]::Round($File.Length/1MB,2)) MB)..." "Cyan"

    if (-not (Send-FileInChunks -File $File -RelPath $RelPath -SyncMode)) {
        return $false
    }

    # Служебные файлы дашборда не логируем — иначе они забивают историю
    if ($RelPath -notmatch '^(status|progress)-') {
        Write-Log "SYNC: '$RelPath' fully transferred!" "Green"
    }
    return $true
}

function Send-SyncDirectory {
    # Отправка пакета FILE_DISK_DIR: создание ПАПКИ по RelPath на другом контуре.
    # Файлы создают папки на приёме сами (по RelPath), пустые папки — никто.
    param([string]$RelPath)

    $payload = @{
        Marker  = "FILE_DISK_DIR"
        RelPath = $RelPath
        Origin  = $script:OwnOrigin
    }
    $json = $payload | ConvertTo-Json -Compress

    $savedClip = Save-ClipText
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
        Write-Log "SYNC: FATAL: cannot write folder packet '$RelPath' to clipboard!" "Red"
        return $false
    }
    if (-not (Wait-SyncAck -RelPath $RelPath)) { Restore-ClipText $savedClip; return $false }
    Restore-ClipText $savedClip
    Write-Log "SYNC: folder '$RelPath' transferred!" "Green"
    return $true
}

function New-SyncBatchZip {
    # Упаковывает очередь синхронизации в один архив: файлы с относительными
    # путями + манифест _syncdirs.txt со списком папок (Expand в PS 5.1 может
    # не создавать пустые папки — создаём их по манифесту). Возвращает путь.
    param([object[]]$Files, [string[]]$DirRelPaths)

    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zipPath = Join-Path $script:SyncDir ".syncbatch.synczip"
    Write-Progress -Activity "CopyPast — АРХИВИРОВАНИЕ очереди (этап 1 из 2: архив, далее отправка)" -Status "0 из $($Files.Count) файлов" -PercentComplete 0 -ErrorAction SilentlyContinue
    try {
        $fs = [System.IO.File]::Open($zipPath, 'Create')
        $zip = New-Object System.IO.Compression.ZipArchive($fs, 'Create', $false, [System.Text.Encoding]::UTF8)
        try {
            $n = 0
            foreach ($pf in $Files) {
                $n++
                $rel = Get-RelPath -FullName $pf.File.FullName
                $entry = $zip.CreateEntry($rel, [System.IO.Compression.CompressionLevel]::Optimal)
                $es = $entry.Open()
                try {
                    $src = [System.IO.File]::OpenRead($pf.File.FullName)
                    try { $src.CopyTo($es) } finally { $src.Close(); $src.Dispose() }
                } finally { $es.Close(); $es.Dispose() }
                if ($n % 20 -eq 0 -or $n -eq $Files.Count) {
                    Write-Progress -Activity "CopyPast — АРХИВИРОВАНИЕ очереди (этап 1 из 2: архив, далее отправка)" -Status "$n из $($Files.Count) файлов" -PercentComplete ([math]::Min(99, [int](100 * $n / $Files.Count))) -ErrorAction SilentlyContinue
                }
            }
            # Пустые папки — записями-каталогами и манифестом на всякий случай
            $dirsLine = ($DirRelPaths -join "`r`n")
            $entry = $zip.CreateEntry("_syncdirs.txt", [System.IO.Compression.CompressionLevel]::Optimal)
            $es = $entry.Open()
            $w = New-Object System.IO.StreamWriter($es)
            $w.Write($dirsLine)
            $w.Flush(); $w.Close()
        } finally { $zip.Dispose(); $fs.Close(); $fs.Dispose() }
        Write-Progress -Activity "CopyPast — АРХИВИРОВАНИЕ очереди (этап 1 из 2: архив, далее отправка)" -Completed -ErrorAction SilentlyContinue
    } catch {
        Write-Log "SYNC: cannot build batch zip - $($_.Exception.Message)" "Red"
        Write-Progress -Activity "CopyPast — АРХИВИРОВАНИЕ очереди (этап 1 из 2: архив, далее отправка)" -Completed -ErrorAction SilentlyContinue
        return $null
    }
    return $zipPath
}

function Expand-SyncBatch {
    # Приём пакетного архива: распаковка в SyncDir, пометка содержимого RECEIVED,
    # создание папок из манифеста, удаление архива.
    param([string]$ZipPath)
    Add-Type -AssemblyName System.IO.Compression
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    try {
        $zip = [System.IO.Compression.ZipFile]::Open($ZipPath, 'Read', [System.Text.Encoding]::UTF8)
        try {
            foreach ($entry in $zip.Entries) {
                $rel = ($entry.FullName -replace '\\', '/').TrimEnd('/')
                if (-not $rel -or $rel -eq '_syncdirs.txt') { continue }
                $target = Join-Path $script:SyncDir ($rel -replace '/', '\')
                if ($entry.FullName.EndsWith('/')) {
                    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                    Add-DirChangeEntry -Type "RECEIVED" -RelPath $rel
                    continue
                }
                $dirPart = Split-Path -Parent $target
                if ($dirPart -and -not (Test-Path -LiteralPath $dirPart)) { New-Item -ItemType Directory -Path $dirPart -Force | Out-Null }
                [System.IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $target, $true)
                $item = Get-Item -LiteralPath $target
                Add-ChangeEntry -Type "RECEIVED" -RelPath $rel -Item $item
            }
            # Манифест папок: создаём и помечаем RECEIVED всё перечисленное
            $dirsEntry = $zip.Entries | Where-Object { $_.FullName -eq '_syncdirs.txt' }
            if ($dirsEntry) {
                $sr = New-Object System.IO.StreamReader($dirsEntry.Open(), [System.Text.Encoding]::UTF8)
                $content = $sr.ReadToEnd()
                $sr.Close()
                foreach ($line in ($content -split "`r?`n")) {
                    $d = $line.Trim()
                    if (-not $d) { continue }
                    $target = Join-Path $script:SyncDir ($d -replace '/', '\')
                    if (-not (Test-Path -LiteralPath $target)) { New-Item -ItemType Directory -Path $target -Force | Out-Null }
                    Add-DirChangeEntry -Type "RECEIVED" -RelPath $d
                }
            }
        } finally { $zip.Dispose() }
        Remove-Item -LiteralPath $ZipPath -Force
        Write-Log "SYNC: batch archive expanded into SyncDir" "Green"
        return $true
    } catch {
        Write-Log "SYNC: FAILED to expand batch archive - $($_.Exception.Message)" "Red"
        $script:HasError = $true
        return $false
    }
}

function Scan-SyncDir {
    # Периодический просмотр SyncDir: новый свободный файл -> отправка чанками
    # на такой же относительный путь в другом контуре. Состояние "что уже
    # отправлено/принято" берётся из персистентного журнала change.log.
    if (-not (Test-Path $script:SyncDir)) {
        if ($script:WatchTrace) { Write-Log "TRACE: SyncDir '$($script:SyncDir)' not found" "DarkGray" }
        return
    }

    # Пауза фоновой синхронизации кнопкой дашборда (флаг-файл .syncpause)
    if (Test-Path -LiteralPath (Join-Path $script:SyncDir ".syncpause") -PathType Leaf) { return }

    # Сторож простоя: пока пользователь работает (клава/мышь), фоновая
    # синхронизация не пишет пакеты в буфер вообще. Ручные отправки
    # (Pack/PackAuto — SyncMode выключен) не затрагиваются.
    if ($script:SyncIdleGuardSec -gt 0 -and (Get-UserIdleSeconds) -lt $script:SyncIdleGuardSec) { return }

    # change.log переписан командером (Web-процесс)? Перечитываем без рестарта
    Test-ChangeLogExternal

    # Маркер удаления: файл .del в КОРНЕ SyncDir -> очистка ВСЕЙ папки на обоих контурах.
    # Маркер синхронизируется как обычный файл: сначала он отправляется на другой
    # контур (существующим чанковым механизмом), и только после подтверждения
    # этот контур очищает свою папку. Приёмник, получив маркер, увидит его при
    # следующем скане у себя и очистит свою папку. Очистка откладывается до
    # успешной отправки: если слушатель другого контура выключен, маркер будет
    # отправлен при следующем скане, и папки останутся нетронутыми.
    $delMarkerPath = Join-Path $script:SyncDir ".del"
    if (Test-Path -LiteralPath $delMarkerPath -PathType Leaf) {
        $markerItem = Get-Item -LiteralPath $delMarkerPath -Force -ErrorAction SilentlyContinue
        if ($markerItem) {
            $markerKey = Get-SyncKey -Item $markerItem -RelPath ".del"
            $markerHandled = $script:ChangeLog.ContainsKey($markerKey) -and $script:ChangeLog[$markerKey] -in @('SENT', 'RECEIVED')
            if (-not $markerHandled) {
                # Маркер ещё не ушёл на другой контур - отправляем его как обычный файл.
                # Backoff: после неудачи повтор откладывается, буфер не забивается повторами.
                $retryReady = Test-SyncRetryReady -RelPath ".del" -SyncKey $markerKey
                if ($retryReady -and (Test-FileFree -Path $delMarkerPath)) {
                    if (Send-SyncFile -File $markerItem -RelPath ".del") {
                        Clear-SyncFailure -RelPath ".del"
                        Add-ChangeEntry -Type "SENT" -RelPath ".del" -Item $markerItem
                        $markerHandled = $true
                    } else {
                        Register-SyncFailure -RelPath ".del" -SyncKey $markerKey
                        Write-Log "DEL-MARKER: '.del' not sent (remote listener is down?) - will retry later" "Yellow"
                    }
                } elseif ($retryReady) {
                    Write-Log "DEL-MARKER: '.del' is locked (still being written) - will retry" "DarkGray"
                }
            }
            if ($markerHandled) {
                Write-Log "DEL-MARKER: '.del' found in '$($script:SyncDir)' - clearing the whole folder" "Cyan"
                $removed = Clear-SyncDirLocal
                Write-Log "DEL-MARKER: '$($script:SyncDir)' cleared ($removed item(s) removed)" "Cyan"
                return
            }
            # Маркер ещё не отправлен: продолжаем обычный скан (маркер из
            # перечисления исключён) - попытка повторится при следующем скане.
        }
    }

    # Маркеры командера: .rm (удалить перечисленное на приёмнике) и .get
    # (запросить перечисленное у приёмника). Создаются дашбордом, уезжают
    # обычным порядком (стандартная отправка, пометка SENT); применяются
    # только на ПРИЁМЕ (RECEIVED) - свой маркер контур не исполняет.
    foreach ($mk in @('.rm', '.get')) {
        $mkPath = Join-Path $script:SyncDir $mk
        if (-not (Test-Path -LiteralPath $mkPath -PathType Leaf)) { continue }
        $mkItem = Get-Item -LiteralPath $mkPath -Force -ErrorAction SilentlyContinue
        if (-not $mkItem) { continue }
        $mkKey = Get-SyncKey -Item $mkItem -RelPath $mk
        $mkStatus = if ($script:ChangeLog.ContainsKey($mkKey)) { $script:ChangeLog[$mkKey] } else { "" }
        if ($mkStatus -eq 'RECEIVED') {
            Apply-SyncMarker -Path $mkPath -Mode $mk.TrimStart('.')
            Remove-Item -LiteralPath $mkPath -Force -ErrorAction SilentlyContinue
            [void](Remove-ChangeEntries -RelPaths @($mk))
        }
    }

    # Служебные файлы не отправляются: сам журнал change.log, маркер удаления .del,
    # незавершённые сборки .part и пакетные архивы .synczip (отправляются отдельно)
    $files       = @(Get-ChildItem -Path $script:SyncDir -File -Recurse -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -ine 'change.log' -and $_.Name -ine '.del' -and $_.Name -ine '.syncpause' -and $_.Extension -ne '.part' -and $_.Extension -ne '.synczip' })

    # Папки и файлы к отправке (сначала сбор_pending, затем решение: batch или по одному)
    $dirs = @(Get-ChildItem -Path $script:SyncDir -Directory -Recurse -ErrorAction SilentlyContinue)

    # === Пакетный режим: много нового — всё в один ZIP вместо сотен пакетов ===
    $pendingDirs  = @()
    foreach ($dir in $dirs) {
        $rel = Get-RelPath -FullName $dir.FullName
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $dirKey = Get-DirKey -RelPath $rel
        if ($script:ChangeLog.ContainsKey($dirKey)) { continue }
        $pendingDirs += $rel
    }
    $pendingFiles = @()
    foreach ($file in $files) {
        $rel = Get-RelPath -FullName $file.FullName
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $key = Get-SyncKey -Item $file -RelPath $rel
        if ($script:ChangeLog.ContainsKey($key) -and $script:ChangeLog[$key] -in @('SENT', 'RECEIVED', 'SNAPSHOT')) { continue }
        if ($script:ServiceSendBlocked -and $rel -match '^(status|progress)-') { continue }   # служебные — только после живого канала
        if (-not (Test-FileFree -Path $file.FullName)) { continue }   # занятые — в следующий скан
        $pendingFiles += [pscustomobject]@{ File = $file; Rel = $rel; Key = $key }
    }
    if (($pendingDirs.Count + $pendingFiles.Count) -ge $script:SyncBatchFiles) {
        Write-Log "SYNC: batch mode: $($pendingFiles.Count) file(s) + $($pendingDirs.Count) folder(s) -> single zip" "Cyan"
        $zipPath = New-SyncBatchZip -Files $pendingFiles -DirRelPaths $pendingDirs
        if ($zipPath) {
            $zipItem = Get-Item $zipPath
            if (Send-SyncFile -File $zipItem -RelPath (Split-Path $zipPath -Leaf)) {
                Clear-SyncFailure -RelPath ".syncbatch"
                $script:ServiceSendBlocked = $false   # канал жив — карточки снова можно слать
                # Содержимое помечаем SENT (архив доставлен), сам архив удаляем
                foreach ($d in $pendingDirs) { Add-DirChangeEntry -Type "SENT" -RelPath $d }
                foreach ($pf in $pendingFiles) { Add-ChangeEntry -Type "SENT" -RelPath $pf.Rel -Item $pf.File }
                Remove-Item -LiteralPath $zipPath -Force
                Write-Log "SYNC: batch sent - $($pendingFiles.Count) file(s), $($pendingDirs.Count) folder(s) in one archive" "Green"
            } else {
                # Фиксированный ключ backoff: при недоступности приёмника — одна попытка в окно
                Register-SyncFailure -RelPath ".syncbatch" -SyncKey "batch"
                Remove-Item -LiteralPath $zipPath -Force -ErrorAction SilentlyContinue
                Write-Log "SYNC: batch NOT sent - will retry later (single attempt per backoff window)" "Yellow"
                Notify-WatchFailure
            }
        }
        return   # пакетный скан обрабатывает всю очередь — персональные отправки не нужны
    }

    # Одиночный режим (очередь мала): как раньше — папки и файлы по одному
    foreach ($dir in $dirs) {
        $rel = Get-RelPath -FullName $dir.FullName
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        $dirKey = Get-DirKey -RelPath $rel
        if ($script:ChangeLog.ContainsKey($dirKey)) { continue }
        if (-not (Test-SyncRetryReady -RelPath "dir:$rel" -SyncKey $dirKey)) { continue }
        if (Send-SyncDirectory -RelPath $rel) {
            Clear-SyncFailure -RelPath "dir:$rel"
            $script:ServiceSendBlocked = $false
            Add-DirChangeEntry -Type "SENT" -RelPath $rel
        } else {
            Register-SyncFailure -RelPath "dir:$rel" -SyncKey $dirKey
        }
    }

    $newCount    = 0
    $handledCount = 0
    $lockedCount = 0
    $sentCount   = 0
    $failedCount = 0
    foreach ($file in $files) {
        $rel = Get-RelPath -FullName $file.FullName
        if ([string]::IsNullOrWhiteSpace($rel)) { continue }
        if ($script:ServiceSendBlocked -and $rel -match '^(status|progress)-') { continue }   # служебные — только после живого канала
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
        if (-not (Test-SyncRetryReady -RelPath $rel -SyncKey $key)) { continue }
        if (Send-SyncFile -File $file -RelPath $rel) {
            Clear-SyncFailure -RelPath $rel
            Add-ChangeEntry -Type "SENT" -RelPath $rel -Item $file
            if ($rel -notmatch '^(status|progress)-') { $script:ServiceSendBlocked = $false }   # реальная передача прошла — канал жив
            $sentCount++
        } else {
            $failedCount++
            if ($rel -match '^(status|progress)-') { $script:ServiceSendBlocked = $true }   # карточки не ретраим: уедут с реальной передачей
            Register-SyncFailure -RelPath $rel -SyncKey $key
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
    $old = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and
                       $_.CommandLine -like "*FileTransfer.ps1*" -and $_.CommandLine -match '\bWatch\b' })
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

    # Единое окно слушателя: скрыто (не мешает); статус — в браузере http://localhost:8123
    # или Ctrl+Alt+W (History)
    # Самогенерация MachineId: на контуре, где Install.ps1 не запускался,
    # иначе Origin без суффикса и статус-файл «status-.json»
    if ([string]::IsNullOrWhiteSpace($script:MachineId)) {
        try {
            $newId = [guid]::NewGuid().ToString("N").Substring(0, 8)
            $items = Read-IniItems -Path $script:LocalConfigPath
            if ($items.Count -eq 0) {
                $items.Add([pscustomobject]@{ Kind = "comment"; Text = "; setcp.local.ini - ЛОКАЛЬНЫЕ настройки ЭТОГО контура"; Section = ""; Key = "" })
                $items.Add([pscustomobject]@{ Kind = "section"; Text = "[Settings]"; Section = "Settings"; Key = "" })
            }
            Set-IniKeyItem -items $items -Section "Settings" -Key "MachineId" -Value $newId
            Save-IniItems -Path $script:LocalConfigPath -items $items
            $script:MachineId = $newId
            $script:OwnOrigin = "$env:COMPUTERNAME@$newId"
            Write-Log "MachineId generated: $newId (setcp.local.ini)" "Green"
        } catch {
            Write-Log "WARNING: cannot generate MachineId - $($_.Exception.Message)" "Yellow"
        }
    }
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
    $lastStatusWrite = (Get-Date).AddSeconds(-30)

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
                } elseif ($text -match '"Marker"\s*:\s*"(FILE_TRANSFER_DATA|FILE_CHUNK_DATA|FILE_DISK_CMD|FILE_DISK_DIR)"') {

                    # Свой-чужой: пакет с Origin = имя этого же ПК положен локально этим же скриптом.
                    # Он предназначен для Watch на ДРУГОМ конце RDP - не трогаем буфер, ждём его.
                    if ($text -match '"Origin"\s*:\s*"([^"]+)"' -and $matches[1] -eq $script:OwnOrigin) {
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
                        } elseif ($text -match '"Marker"\s*:\s*"FILE_DISK_DIR"') {
                            # Приём папки: создаём (если её ещё нет) и подтверждаем очисткой буфера.
                            if ($text -match '"RelPath"\s*:\s*"([^"]+)"') {
                                $dirRel = (($matches[1] -replace '\\', '/') -split '/' |
                                    Where-Object { $_ -notin @('', '.', '..') }) -join '/'
                                if ($dirRel) {
                                    $dirPath = Join-Path $script:SyncDir ($dirRel -replace '/', '\')
                                    if (-not (Test-Path -LiteralPath $dirPath)) {
                                        New-Item -ItemType Directory -Path $dirPath -Force | Out-Null
                                        Write-Log "SYNC: folder '$dirRel' created" "Cyan"
                                    }
                                    Add-DirChangeEntry -Type "RECEIVED" -RelPath $dirRel
                                }
                            }
                            [System.Windows.Forms.Clipboard]::Clear()
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
        # Раз в 30 сек — status-файл для дашборда другого контура (уедет синхронизацией).
        # Имя по COMPUTERNAME — читаемо на дашборде второй стороны.
        if ($script:DiskSyncEnabled -and ((Get-Date) - $lastStatusWrite).TotalSeconds -ge 30) {
            $lastStatusWrite = Get-Date
            try {
                $ev = @(Get-Content -LiteralPath $LOG_FILE -Encoding UTF8 -Tail 500 -ErrorAction SilentlyContinue |
                    Select-String $script:DashboardEventPattern | Select-Object -Last 15 |
                    ForEach-Object {
                        $l = $_.ToString()
                        if ($l -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[[^\]]+\] (.*)$') {
                            # Обрезаем: одна длинная строка лога не раздует status-файл
                            $m1 = $matches[2]; if ($m1.Length -gt 300) { $m1 = $m1.Substring(0, 300) + '...' }
                            @{ T = $matches[1]; M = $m1 }
                        }
                    })
                # Манифест содержимого disk для панели «Другой ПК» в командере:
                # строки "rel|размер|f|d" (файл/папка). Лимит 2000 - защита от
                # раздувания status-файла.
                $manifest = @(Get-ChildItem -Path $script:SyncDir -Recurse -Force -ErrorAction SilentlyContinue |
                    Select-Object -First 2000 | ForEach-Object {
                        $mRel = Get-RelPath -FullName $_.FullName
                        if (-not $mRel) { return }
                        if ($_.PSIsContainer) { "$mRel|0|d" }
                        elseif ($_.Name -in @('change.log', '.del', '.rm', '.get', '.syncpause') -or $_.Extension -in @('.part', '.synczip')) { return }
                        elseif ($_.Name -match '^(status|progress)-') { return }
                        else { "$mRel|$($_.Length)|f" }
                    })
                $st = @{ Machine = $env:COMPUTERNAME; Time = (Get-Date -Format "yyyy-MM-dd HH:mm:ss"); Events = $ev; Files = $manifest }
                $stPath = Join-Path $script:SyncDir ("status-{0}.json" -f $env:COMPUTERNAME)
                $st | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $stPath -Encoding UTF8
            } catch {}
        }
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
            # Ротация журнала и на долгом Watch: без неё журнал растёт бесконечно
            Rotate-Log
        }
    }
}

# ===== ЛОКАЛЬНЫЕ НАСТРОЙКИ КОНТУРА (setcp.local.ini) =====

function Read-IniItems {
    # Построчное чтение INI в список элементов с сохранением комментариев и порядка.
    param([string]$Path)
    $items = New-Object System.Collections.Generic.List[object]
    if (-not (Test-Path -LiteralPath $Path)) { return $items }
    $text = Read-TextFile -Path $Path
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
    return ,$items
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
    $running = @(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue |
        Where-Object { $_.ProcessId -ne $PID -and $_.CommandLine -and
                       $_.CommandLine -like "*FileTransfer.ps1*" -and $_.CommandLine -match '\bWatch\b' })
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

function Resolve-SyncPath {
    # Безопасное разрешение относительного пути внутри SyncDir: '..' и выход
    # за корень запрещены. Возвращает $null для подозрительных путей.
    param([string]$Rel)
    $norm = ($Rel -replace '\\', '/').Trim('/')
    if (-not $norm -or $norm -match '\.\.' -or $norm -match '^[A-Za-z]:') { return $null }
    $full = [System.IO.Path]::GetFullPath((Join-Path $script:SyncDir $norm))
    $root = [System.IO.Path]::GetFullPath($script:SyncDir)
    if (-not $full.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)) { return $null }
    return $full
}

function Remove-ChangeEntries {
    # Удалить записи change.log для перечисленных путей (файл, папка и всё
    # их содержимое). Записи пропадут - объекты считаются новыми и уедут при
    # следующем скане. Вызывается из Web-процесса: после правки change.log
    # слушателя нужно перезапустить (он держит журнал в памяти).
    param([string[]]$RelPaths)
    $logPath = Join-Path $script:SyncDir "change.log"
    if (-not (Test-Path -LiteralPath $logPath)) { return }
    $norm = @($RelPaths | ForEach-Object { ($_ -replace '\\', '/').Trim('/').ToLowerInvariant() } | Where-Object { $_ })
    if ($norm.Count -eq 0) { return }
    $kept = New-Object System.Collections.Generic.List[string]
    $removed = 0
    foreach ($line in @(Get-Content -LiteralPath $logPath -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $m = [regex]::Match($line, '^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\|(SENT|RECEIVED|SNAPSHOT|LOCKED)\|(.+)\|\d+\|\d+$')
        if (-not $m.Success) { continue }
        $key = $m.Groups[2].Value.ToLowerInvariant()
        $hit = $false
        foreach ($p in $norm) {
            if ($key -eq $p -or $key -eq "dir/$p" -or $key -like "$p/*" -or $key -like "dir/$p/*") { $hit = $true; break }
        }
        if ($hit) { $removed++ } else { [void]$kept.Add($line) }
    }
    Set-Content -LiteralPath $logPath -Value $kept -Encoding UTF8
    return $removed
}

function Backup-SyncItem {
    # Перенос элемента SyncDir в бэкап TEMP с сохранением относительного пути
    param([string]$Rel)
    $full = Resolve-SyncPath -Rel $Rel
    if (-not $full -or -not (Test-Path -LiteralPath $full)) { return }
    try {
        $bk = Join-Path (Join-Path $env:TEMP "CHANGE-backup") ("cmd-" + (Get-Date -Format "yyyyMMdd"))
        $dest = Join-Path $bk $Rel
        $destDir = Split-Path -Parent $dest
        if (-not (Test-Path $destDir)) { New-Item -ItemType Directory -Path $destDir -Force | Out-Null }
        Move-Item -LiteralPath $full -Destination $dest -Force
    } catch {
        Write-Log "CMD: backup failed for '$Rel' - $($_.Exception.Message)" "Yellow"
    }
}

function Apply-SyncMarker {
    # Применение полученного маркера .rm (удалить перечисленное локально) или
    # .get (перечисленное отправить заново - снимаются отметки change.log).
    # Применяется только на ПРИЁМЕ: свой маркер контур не исполняет.
    param([string]$Path, [string]$Mode)
    $paths = New-Object System.Collections.Generic.List[string]
    foreach ($l in @(Get-Content -LiteralPath $Path -Encoding UTF8 -ErrorAction SilentlyContinue)) {
        $rel = ($l.Trim() -replace '\\', '/').Trim('/')
        if (-not $rel -or $rel -match '\.\.' -or $rel -in @('change.log', '.del', '.rm', '.get', '.syncpause')) { continue }
        if (Resolve-SyncPath -Rel $rel) { $paths.Add($rel) }
    }
    if ($paths.Count -eq 0) { return }
    if ($Mode -eq 'rm') {
        foreach ($rel in $paths) { Backup-SyncItem -Rel $rel }
        [void](Remove-ChangeEntries -RelPaths $paths.ToArray())
        Write-Log "CMD: .rm применён - удалено $($paths.Count) эл. (бэкап в TEMP)" "White"
    } else {
        [void](Remove-ChangeEntries -RelPaths $paths.ToArray())
        Write-Log "CMD: .get применён - помечено к отправке $($paths.Count) эл." "White"
    }
}

function Get-SyncFileList {
    # Плоский список содержимого SyncDir для командера: "rel|размер|f|d",
    # служебные файлы исключены. Лимит 3000 записей (защита от гигантских JSON).
    $list = New-Object System.Collections.Generic.List[string]
    foreach ($item in @(Get-ChildItem -Path $script:SyncDir -Recurse -Force -ErrorAction SilentlyContinue)) {
        if ($list.Count -ge 3000) { break }
        $rel = Get-RelPath -FullName $item.FullName
        if (-not $rel) { continue }
        if ($item.PSIsContainer) { $list.Add("$rel|0|d"); continue }
        if ($item.Name -in @('change.log', '.del', '.rm', '.get', '.syncpause') -or $item.Extension -in @('.part', '.synczip')) { continue }
        if ($item.Name -match '^(status|progress)-') { continue }
        $list.Add("$rel|$($item.Length)|f")
    }
    return $list
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
    # не выполнился снапшот). Перед удалением содержимое архивируется в TEMP:
    # очистка необратима, случайный .del не должен стоить потери файлов.
    # Возвращает число удалённых элементов.
    $removed = 0
    if (Test-Path $script:SyncDir) {
        $items = @(Get-ChildItem -LiteralPath $script:SyncDir -Force -ErrorAction SilentlyContinue)
        if ($items.Count -gt 0) {
            # Резервная копия перед необратимой очисткой (сбой архивации очистку не блокирует)
            try {
                $stamp    = Get-Date -Format "yyyyMMdd-HHmmss"
                $backupZip = Join-Path (Join-Path $env:TEMP "CHANGE-backup") "CHANGE-$stamp.zip"
                if (-not (Test-Path (Split-Path -Parent $backupZip))) { New-Item -ItemType Directory -Path (Split-Path -Parent $backupZip) -Force | Out-Null }
                Compress-Archive -LiteralPath ($items.FullName) -DestinationPath $backupZip -Force
                Write-Log "CLEAR-DISK: backup saved to '$backupZip'" "DarkGray"
            } catch {
                Write-Log "CLEAR-DISK: backup failed - $($_.Exception.Message)" "Yellow"
            }
        }
        foreach ($item in $items) {
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
        Origin = $script:OwnOrigin
    }
    $json = $payload | ConvertTo-Json -Compress

    $savedClip = Save-ClipText
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
        Restore-ClipText $savedClip
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
    Restore-ClipText $savedClip
}

function Invoke-MarkDelete {
    # FileTransfer.ps1 MarkDelete - положить маркер-файл .del в корень SyncDir.
    # Слушатель (Watch) с DiskSyncEnabled=1 увидит маркер при сканировании,
    # отправит его на другой контур обычной синхронизацией и очистит свою папку;
    # слушатель другого контура, приняв маркер, очистит папку у себя.
    # Работает и при выключенном слушателе: маркер дождётся его запуска.
    if (-not $script:DiskSyncEnabled) {
        Write-Log "DEL-MARKER: disk sync is DISABLED (DiskSyncEnabled=0) - the marker will not work" "Yellow"
        return
    }
    if (-not (Test-Path $script:SyncDir)) {
        try { New-Item -ItemType Directory -Path $script:SyncDir -Force | Out-Null }
        catch {
            Write-Log "DEL-MARKER: cannot create SyncDir '$($script:SyncDir)' - $($_.Exception.Message)" "Red"
            $script:HasError = $true
            return
        }
    }
    $markerPath = Join-Path $script:SyncDir ".del"
    try {
        if (-not (Test-Path -LiteralPath $markerPath)) {
            [System.IO.File]::WriteAllText($markerPath, "")
            Write-Log "DEL-MARKER: '.del' placed into '$($script:SyncDir)' - both sides will clear their SyncDir when the listener sees it" "Green"
        } else {
            Write-Log "DEL-MARKER: '.del' already exists in '$($script:SyncDir)' - waiting for the listener" "Cyan"
        }
    } catch {
        Write-Log "DEL-MARKER: cannot create '.del' - $($_.Exception.Message)" "Red"
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
                $origin = $script:OwnOrigin
                if ($text -match '"Origin"\s*:\s*"([^"]+)"') { $origin = $matches[1] }
                if ($origin -ne $script:OwnOrigin) { $packet = $text }
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

function Invoke-History {
    # FileTransfer.ps1 History — история последних операций (отдельное окно,
    # его закрытие не влияет на слушателя)
    $entries = @(Get-Content -LiteralPath $LOG_FILE -Encoding UTF8 -ErrorAction SilentlyContinue |
        Select-String 'ОТПРАВЛЕНО|ПРИНЯТО|НЕ ПЕРЕДАНО|FAIL|FATAL|ERROR|WARNING' |
        Select-Object -Last 30)
    Write-Host "================ ИСТОРИЯ ПЕРЕДАЧ (последние $($entries.Count) событий) ================" -ForegroundColor Cyan
    if ($entries.Count -eq 0) { Write-Host "Пока нет событий." "Gray" }
    foreach ($e in $entries) {
        $line = $e.ToString()
        $c = "Gray"
        if ($line -match 'FAIL|FATAL|ERROR|НЕ ПЕРЕДАНО|WARNING') { $c = "Red" }
        elseif ($line -match 'ОТПРАВЛЕНО') { $c = "Green" }
        elseif ($line -match 'ПРИНЯТО') { $c = "Cyan" }
        # Компактный формат: время + событие
        $line -replace '^\[(\d{4}-\d{2}-\d{2} )?(\d{2}:\d{2}:\d{2})\] \[[^\]]+\] ', '$2  ' | ForEach-Object { Write-Host $_ -ForegroundColor $c }
    }
    Write-Host "================ журнал: $LOG_FILE ================" -ForegroundColor Cyan
}

function Update-IniSettings {
    # Точечная правка ключей [Settings] в setcp.ini с сохранением комментариев:
    # существующий ключ перезаписывается, нового — добавляется после [Settings].
    param([string]$Path, [hashtable]$Values)
    $lines = [System.Collections.Generic.List[string]]@(Get-Content -LiteralPath $Path -Encoding UTF8)
    foreach ($k in $Values.Keys) {
        $idx = -1
        for ($i = 0; $i -lt $lines.Count; $i++) {
            if ($lines[$i] -match '^\s*' + [regex]::Escape($k) + '\s*=') { $idx = $i; break }
        }
        if ($idx -ge 0) { $lines[$idx] = "$k=$($Values[$k])" }
        else {
            $sIdx = -1
            for ($i = 0; $i -lt $lines.Count; $i++) { if ($lines[$i] -match '^\s*\[Settings\]\s*$') { $sIdx = $i; break } }
            if ($sIdx -ge 0) { $lines.Insert($sIdx + 1, "$k=$($Values[$k])") } else { $lines.Add("$k=$($Values[$k])") }
        }
    }
    Set-Content -LiteralPath $Path -Value $lines -Encoding UTF8
}

function Get-WebStateHtml {
    # Динамические фрагменты дашборда (статусы, очередь, лог, прогресс):
    # общий источник для первого рендера страницы и для /state (живое
    # обновление лога/статусов без перезагрузки страницы).
    $dash = Get-DashboardState
    $rows = New-Object System.Text.StringBuilder
    foreach ($ev in $dash.Events) {
        $cls = "svc"
        if ($ev.M -match 'FAIL|FATAL|ERROR|НЕ ПЕРЕДАНО') { $cls = "bad" }
        elseif ($ev.M -match 'WARNING') { $cls = "warn" }
        [void]$rows.AppendLine("<tr class='$cls'><td>$($ev.T)</td><td>$([System.Net.WebUtility]::HtmlEncode($ev.M))</td></tr>")
    }

    # Прогресс передач: progress-*.json из SyncDir (свой + чужой)
    $progRows = New-Object System.Text.StringBuilder
    foreach ($pf in @(Get-ChildItem -LiteralPath $script:SyncDir -Filter "progress-*.json" -ErrorAction SilentlyContinue)) {
        try {
            $j = $pf | Get-Content -Encoding UTF8 -Raw | ConvertFrom-Json
            $pct = if ($j.Total -gt 0) { [math]::Min(100, [int](100 * $j.Chunk / $j.Total)) } else { 0 }
            $dirTxt = if ($j.Dir -eq "send") { "&rarr; на другой ПК" } else { "&larr; с другого ПК" }
            $age = [int]((Get-Date) - [datetime]::ParseExact([string]$j.Started, "yyyy-MM-dd HH:mm:ss", $null)).TotalSeconds
            $stale = if ($age -gt 120) { " <span class='sub'>&middot; нет обновлений $age сек</span>" } else { "" }
            [void]$progRows.AppendLine("<div class='prow'><div class='ptitle'>${dirTxt}: $([System.Net.WebUtility]::HtmlEncode([string]$j.File)) <span class='sub'>чанк $($j.Chunk)/$($j.Total)$stale</span></div><div class='pbar'><div class='pfill' style='width:$pct%'></div></div></div>")
        } catch {}
    }
    $progressHtml = if ($progRows.Length -gt 0) { $progRows.ToString() } else { "" }

    $running = @(Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.CommandLine -like "*-File*FileTransfer.ps1*Watch*" }).Count -gt 0
    # Очередь disk: файлы без отметки SENT/RECEIVED/SNAPSHOT в change.log
    $queueCount = 0
    $queueMB = 0.0
    try {
        $marked = @{}
        Get-Content -LiteralPath (Join-Path $script:SyncDir "change.log") -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            $p = $_ -split '\|', 3
            if ($p.Count -ge 3 -and $p[1] -in @('SENT', 'RECEIVED', 'SNAPSHOT')) { $marked[$p[2].ToLowerInvariant()] = $true }
        }
        foreach ($f in @(Get-ChildItem -Path $script:SyncDir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('change.log', '.del', '.syncpause') -and $_.Extension -notin @('.part', '.synczip') -and $_.Name -notmatch '^(status|progress)-' })) {
            $rel = (Get-RelPath -FullName $f.FullName).ToLowerInvariant()
            if (-not $marked[$rel]) { $queueCount++; $queueMB += $f.Length / 1MB }
        }
    } catch {}
    $queueTxt = if ($queueCount -gt 0) { "очередь: <b>$queueCount</b> файл(ов), $([math]::Round($queueMB, 1)) МБ" } else { "очередь пуста" }
    $paused = Test-Path (Join-Path $script:SyncDir ".syncpause")
    $pauseBtn = if ($paused) {
        "<button class='btn tool' onclick=`"post('/syncpause');`">Возобновить синхр.</button>"
    } else {
        "<button class='btn tool warn' onclick=`"post('/syncpause');`">Пауза синхр.</button>"
    }
    $listen = if ($running) {
        "<span class='st on'>&#9679;</span> <b>Слушатель</b> <form method='post' action='/stop' style='display:inline' onsubmit=`"return confirm('Остановить слушателя?')`"><button class='btn stop sm'>Стоп</button></form> $pauseBtn"
    } else {
        "<span class='st off'>&#9679;</span> <b>Слушатель</b> <form method='post' action='/start' style='display:inline'><button class='btn start sm'>Пуск</button></form> $pauseBtn"
    }
    $queueHtml = "$queueTxt$(if ($paused) { ' · <b style=''color:#e8c268''>на паузе</b>' })"
    # Очередь в виде списка файлов (для панели под логом)
    $qf = New-Object System.Text.StringBuilder
    try {
        $marked2 = @{}
        Get-Content -LiteralPath (Join-Path $script:SyncDir "change.log") -Encoding UTF8 -ErrorAction SilentlyContinue | ForEach-Object {
            $p = $_ -split '\|', 3
            if ($p.Count -ge 3 -and $p[1] -in @('SENT', 'RECEIVED', 'SNAPSHOT')) { $marked2[$p[2].ToLowerInvariant()] = $true }
        }
        $shown = 0
        foreach ($f in @(Get-ChildItem -Path $script:SyncDir -File -Recurse -ErrorAction SilentlyContinue |
            Where-Object { $_.Name -notin @('change.log', '.del', '.syncpause') -and $_.Extension -notin @('.part', '.synczip') -and $_.Name -notmatch '^(status|progress)-' })) {
            $rel = (Get-RelPath -FullName $f.FullName).ToLowerInvariant()
            if ($marked2[$rel]) { continue }
            $shown++
            if ($shown -le 200) { [void]$qf.AppendLine("<div class='row file'><span class='ic'>&#128196;</span><span class='nm' title='$([System.Net.WebUtility]::HtmlEncode($rel))'>$([System.Net.WebUtility]::HtmlEncode($rel))</span><span class='sz'>$([math]::Round($f.Length / 1KB, 1)) КБ</span></div>") }
        }
        if ($shown -gt 200) { [void]$qf.AppendLine("<div class='sub' style='padding:2px 6px'>... всего $shown</div>") }
    } catch {}
    if ($shown -eq 0) { [void]$qf.AppendLine("<div class='sub' style='padding:2px 6px'>пуста</div>") }
    $remoteHtml = if ($dash.RemoteName) {
        if ($dash.RemoteAge -lt 120) { "Другой ПК: <b>$($dash.RemoteName) <span class='on'>&#9679;</span> $($dash.RemoteAge) сек</b>" }
        else { "Другой ПК: <b>$($dash.RemoteName) <span class='off'>&#9679;</span> молчит $([int]($dash.RemoteAge/60)) мин</b>" }
    } else { "Другой ПК: <b>нет данных</b>" }
    return @{ Listen = $listen; Queue = $queueHtml; QueueFiles = $qf.ToString(); Remote = $remoteHtml; Rows = $rows.ToString(); Progress = $progressHtml; Running = $running }
}

function Get-NumField {
    # Поле формы параметров: текущее значение ключа из setcp.ini + подпись
    param([string]$Key, [string]$Label, [string]$Hint, [string]$Def)
    $cur = Get-IniValue -Section "Settings" -Key $Key -Default $Def
    return "<label><span class='pname'>$Label</span><input name='$Key' type='number' value='$cur'><span class='phint'>$Hint</span></label>"
}

function Get-DashboardState {
    # Общий срез для дашборда и кнопки «Скопировать»: события локального
    # журнала + события другого контура из status-*.json, свежие сверху.
    $state = @{ Events = @(); RemoteName = ""; RemoteAge = -1 }
    $events = New-Object System.Collections.Generic.List[object]
    $local = @(Get-Content -LiteralPath $LOG_FILE -Encoding UTF8 -Tail 2000 -ErrorAction SilentlyContinue |
        Select-String $script:DashboardEventPattern |
        Select-Object -Last 60)
    foreach ($e in $local) {
        $line = $e.ToString()
        if ($line -match '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\] \[[^\]]+\] (.*)$') { $t = $matches[1]; $m = $matches[2] } else { $t = ''; $m = $line }
        $events.Add([pscustomobject]@{ T = $t; M = $m })
    }
    $remoteFiles = @(Get-ChildItem -LiteralPath $script:SyncDir -Filter "status-*.json" -ErrorAction SilentlyContinue)
    foreach ($rf in $remoteFiles) {
        try {
            # Свой статус-файл пропускаем — его события и так в локальной истории
            if ($rf.Name -ieq "status-$env:COMPUTERNAME.json") { continue }
            $j = $rf | Get-Content -Encoding UTF8 -Raw | ConvertFrom-Json
            $state.RemoteName = $j.Machine
            $state.RemoteAge = [int]((Get-Date) - [datetime]::ParseExact($j.Time, "yyyy-MM-dd HH:mm:ss", $null)).TotalSeconds
            foreach ($ev in @($j.Events)) {
                $m0 = [string]$ev.M; if ($m0.Length -gt 300) { $m0 = $m0.Substring(0, 300) + '...' }
                $events.Add([pscustomobject]@{ T = $ev.T; M = "[$($j.Machine)] $m0" })
            }
        } catch {}
    }
    $state.Events = @($events | Sort-Object -Property T -Descending)
    return $state
}

function Invoke-WebStatus {
    # FileTransfer.ps1 Web — веб-дашборд на http://localhost:8123
    # Статус слушателя, кнопки старт/стоп, история передач ОБОИХ контуров:
    # каждый слушатель пишет status-<MachineId>.json в SyncDir, синхронизация
    # доставляет его на другой ПК, дашборд читает оба файла.
    Add-Type -AssemblyName System.Net
    $listener = [System.Net.HttpListener]::new()
    $listener.Prefixes.Add("http://localhost:8123/")
    try { $listener.Start() } catch {
        Write-Log "WEB: cannot start on 8123 (already running?) - $($_.Exception.Message)" "Yellow"
        return
    }
    Write-Log "WEB: dashboard started at http://localhost:8123/" "Green"
    while ($listener.IsListening) {
        try { $ctx = $listener.GetContext() } catch { break }
        $resp = $ctx.Response
        try {
            $path = $ctx.Request.Url.AbsolutePath
            if ($path -eq "/copylog") {
                # Текст последних N событий — удобно вставить в письмо или чат
                $n = 10
                $qs = [string]$ctx.Request.QueryString["n"]
                [void][int]::TryParse($qs, [ref]$n)
                if ($n -lt 1 -or $n -gt 200) { $n = 10 }
                $dash = Get-DashboardState
                $lines = @($dash.Events | Select-Object -First $n | ForEach-Object {
                    if ($_.T) { "[$($_.T)] $($_.M)" } else { $_.M }
                })
                [array]::Reverse($lines)  # хронологический порядок: старые сверху
                $textBytes = [System.Text.Encoding]::UTF8.GetBytes(($lines -join "`r`n"))
                $resp.ContentType = "text/plain; charset=utf-8"
                $resp.ContentLength64 = $textBytes.Length
                $resp.OutputStream.Write($textBytes, 0, $textBytes.Length)
                $resp.OutputStream.Close()
                continue
            }
            if ($path -eq "/files") {
                # Список файлов для панелей командера: panel=local (SyncDir) или
                # panel=remote (манифест из status-*.json, кэш до /refresh-remote)
                $panel = [string]$ctx.Request.QueryString["panel"]
                $resp.ContentType = "application/json; charset=utf-8"
                if ($panel -eq "local") {
                    $j = @{ ok = $true; files = @(Get-SyncFileList); root = $script:SyncDir }
                } else {
                    if (-not $script:RemoteFilesCache) {
                        try {
                            $rf = @(Get-ChildItem -LiteralPath $script:SyncDir -Filter "status-*.json" -ErrorAction SilentlyContinue |
                                Where-Object { $_.Name -ine "status-$env:COMPUTERNAME.json" } | Select-Object -First 1)
                            if ($rf) {
                                $j0 = $rf[0] | Get-Content -Encoding UTF8 -Raw | ConvertFrom-Json
                                $script:RemoteFilesCache = @($j.Files)
                                $script:RemoteFilesMachine = [string]$j.Machine
                                $script:RemoteFilesTime = [string]$j.Time
                            }
                        } catch {}
                    }
                    $j = @{ ok = $true; files = $script:RemoteFilesCache; machine = $script:RemoteFilesMachine; time = $script:RemoteFilesTime }
                }
                $json = $j | ConvertTo-Json -Compress -Depth 3
                $b = [System.Text.Encoding]::UTF8.GetBytes($json)
                $resp.ContentLength64 = $b.Length
                $resp.OutputStream.Write($b, 0, $b.Length)
                $resp.OutputStream.Close()
                continue
            }
            if ($path -eq "/state") {
                # Динамика для живого обновления: статусы, очередь, лог, прогресс.
                # Страница НЕ перезагружается — только эти фрагменты подменяются.
                $ws = Get-WebStateHtml
                $j = @{ listen = $ws.Listen; remote = $ws.Remote; rows = $ws.Rows; progress = $ws.Progress; queuefiles = $ws.QueueFiles }
                $js = $j | ConvertTo-Json -Compress
                $b = [System.Text.Encoding]::UTF8.GetBytes($js)
                $resp.ContentType = "application/json; charset=utf-8"
                $resp.ContentLength64 = $b.Length
                $resp.OutputStream.Write($b, 0, $b.Length)
                $resp.OutputStream.Close()
                continue
            }
            if ($path -eq "/clearlog") {
                # Очистить журнал разработчика/передач (файл обнуляется)
                try {
                    Set-Content -LiteralPath $LOG_FILE -Value "" -Encoding UTF8
                    Write-Log "Журнал очищен из дашборда" "White"
                } catch {}
                $resp.StatusCode = 302
                $resp.Headers["Location"] = "/"
                $resp.OutputStream.Close()
                continue
            }
            if ($path -eq "/refresh-remote") {
                # Сброс кэша панели «Другой ПК» — список обновится при следующей загрузке
                $script:RemoteFilesCache = $null
                $resp.StatusCode = 302
                $resp.Headers["Location"] = "/"
                $resp.OutputStream.Close()
                continue
            }
            if ($path -eq "/open") {
                # Открыть файл/папку из SyncDir по щелчку в командере (только внутри SyncDir)
                $rel = [string]$ctx.Request.QueryString["rel"]
                $full = Resolve-SyncPath -Rel $rel
                if ($full -and (Test-Path -LiteralPath $full)) {
                    if (Test-Path -LiteralPath $full -PathType Container) {
                        Start-Process -FilePath "explorer.exe" -ArgumentList "`"$full`""
                    } else {
                        Start-Process -FilePath "explorer.exe" -ArgumentList "/select,`"$full`""
                    }
                }
                $resp.StatusCode = 204
                $resp.OutputStream.Close()
                continue
            }
            if ($ctx.Request.HttpMethod -eq "POST") {
                if ($path -eq "/drop") {
                    # Drag&drop из браузера: JSON {name, data(base64)} → файл в SyncDir →
                    # синхронизация доставит на другой контур
                    try {
                        $ms = New-Object System.IO.MemoryStream
                        $ctx.Request.InputStream.CopyTo($ms)
                        if ($ms.Length -gt 128MB) {
                            # Защита: base64-тело в памяти, ограничим input (~96 МБ файла)
                            $ms.Close(); $ms.Dispose()
                            $resp.StatusCode = 413
                            $b = [System.Text.Encoding]::UTF8.GetBytes("файл слишком велик для drop-зоны (>96 МБ) — положите его в SyncDir через Проводник")
                            $resp.ContentType = "text/plain; charset=utf-8"
                            $resp.ContentLength64 = $b.Length
                            $resp.OutputStream.Write($b, 0, $b.Length)
                            $resp.OutputStream.Close()
                            continue
                        }
                        $body = [System.Text.Encoding]::UTF8.GetString($ms.ToArray())
                        $ms.Close(); $ms.Dispose()
                        $j = $body | ConvertFrom-Json
                        $safeName = [System.IO.Path]::GetFileName([string]$j.Name)
                        if ($safeName) {
                            # Относительный путь для файлов из папок (drop-зона с папками):
                            # '..' и абсолютные пути запрещены — пишем только внутрь SyncDir
                            $rel = ""
                            if ($j.Path) { $rel = ([string]$j.Path -replace '\\', '/').Trim('/') }
                            if ($rel -match '(\.\.|^[A-Za-z]:)') { $rel = "" }
                            $target = if ($rel) { Join-Path $script:SyncDir ($rel -replace '/', '\') } else { Join-Path $script:SyncDir $safeName }
                            $targetDir = Split-Path -Parent $target
                            if ($targetDir -and -not (Test-Path $targetDir)) { New-Item -ItemType Directory -Path $targetDir -Force | Out-Null }
                            $bytes = [Convert]::FromBase64String([string]$j.Data)
                            [System.IO.File]::WriteAllBytes($target, $bytes)
                            Write-Log "DROP: '$rel$safeName' ($([math]::Round($bytes.Length / 1MB, 2)) МБ) добавлен в SyncDir" "Green"
                        }
                        $resp.StatusCode = 200
                        $b = [System.Text.Encoding]::UTF8.GetBytes("ok")
                        $resp.OutputStream.Write($b, 0, $b.Length)
                    } catch {
                        try { $resp.StatusCode = 500 } catch {}
                    }
                    $resp.OutputStream.Close()
                    continue
                }
                if ($path -eq "/stop") {
                    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -like "*-File*FileTransfer.ps1*Watch*" } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                } elseif ($path -eq "/stopall") {
                    # Стоп всех фоновых заданий CopyPast: слушатель, ручные отправки,
                    # gw-proxy, хоткеи. Web-процесс (это сами мы) не трогаем.
                    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -match "FileTransfer\.ps1" -and $_.CommandLine -match "Watch|Pack" -and $_.CommandLine -notmatch "Web" } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -like "*gw-proxy.mjs*" } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                    Get-CimInstance Win32_Process -Filter "Name = 'AutoHotkey64.exe' OR Name = 'AutoHotkey.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -like "*Hotkeys.ahk*" } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                } elseif ($path -eq "/start") {
                    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" Watch" `
                        -WorkingDirectory (Split-Path -Parent $PSCommandPath)
                } elseif ($path -eq "/terminal") {
                    # Терминал рядом со скриптом: Windows Terminal, если есть, иначе PowerShell
                    $here = Split-Path -Parent $PSCommandPath
                    if (Get-Command wt.exe -ErrorAction SilentlyContinue) {
                        Start-Process -FilePath "wt.exe" -WorkingDirectory $here
                    } else {
                        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" -WorkingDirectory $here
                    }
                } elseif ($path -eq "/restart") {
                    # Перезапуск слушателя одним кликом: стоп всех + старт нового
                    Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -like "*-File*FileTransfer.ps1*Watch*" } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                    Start-Sleep -Milliseconds 500
                    Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" Watch" `
                        -WorkingDirectory (Split-Path -Parent $PSCommandPath)
                } elseif ($path -eq "/zoo") {
                    # Запуск gw-proxy из папки ZOO (настройка [Tools] ZooDir в setcp.ini)
                    $zooDir = Get-IniPath -Section "Tools" -Key "ZooDir" -Default ""
                    $zooCmd = if ($zooDir) { Join-Path $zooDir "gw-proxy.cmd" } else { "" }
                    if ($zooCmd -and (Test-Path $zooCmd -PathType Leaf)) {
                        Start-Process -FilePath "cmd.exe" -ArgumentList "/c `"$zooCmd`"" -WindowStyle Hidden -WorkingDirectory $zooDir
                    }
                } elseif ($path -eq "/zoo-stop") {
                    Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
                        Where-Object { $_.CommandLine -like "*gw-proxy.mjs*" } |
                        ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                } elseif ($path -eq "/opensync") {
                    Start-Process -FilePath "explorer.exe" -ArgumentList "`"$script:SyncDir`""
                } elseif ($path -eq "/clearqueue") {
                    # Очистить очередь: содержимое локального SyncDir (с бэкапом в TEMP).
                    # Другой контур не затрагивается — в отличие от ClearDisk.
                    [void](Clear-SyncDirLocal)
                } elseif ($path -eq "/openlog") {
                    # Просмотр журнала: LogTracker.ps1, если рядом, иначе блокнот
                    $ltPath = Join-Path (Split-Path -Parent $PSCommandPath) "LogTracker.ps1"
                    if (Test-Path $ltPath -PathType Leaf) {
                        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$ltPath`""
                    } else {
                        Start-Process -FilePath "notepad.exe" -ArgumentList "`"$LOG_FILE`""
                    }
                } elseif ($path -eq "/cmd") {
                    # Команды командера: panel=loc|rem, op=copy|del, paths=строки
                    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd(); $reader.Close()
                    $kv = @{}
                    foreach ($pair in ($body -split '&')) {
                        $p = $pair -split '=', 2
                        if ($p.Count -eq 2) { $kv[[System.Net.WebUtility]::UrlDecode($p[0])] = [System.Net.WebUtility]::UrlDecode($p[1]) }
                    }
                    $panel = [string]$kv['panel']; $op = [string]$kv['op']
                    $paths = @($kv['paths'] -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_ } |
                        ForEach-Object { ($_ -replace '\\', '/').Trim('/') } | Where-Object { $_ -and $_ -notmatch '\.\.' })
                    $paths = @($paths | Select-Object -Unique)
                    if (($paths.Count -gt 0 -or ($panel -eq 'loc' -and $op -eq 'sendall')) -and $panel -in @('loc', 'rem') -and $op -in @('copy', 'del', 'sendall')) {
                        if ($panel -eq 'loc' -and $op -eq 'sendall') {
                            # Отправить всё: change.log обнуляется - весь disk уедет заново
                            Set-Content -LiteralPath (Join-Path $script:SyncDir "change.log") -Value "" -Encoding UTF8
                            Write-Log "CMD: вся очередь помечена к отправке заново" "White"
                        } elseif ($panel -eq 'loc' -and $op -eq 'copy') {
                            # Локально: снять отметки change.log - уедет при следующем окне простоя.
                            # Слушатель сам перечитает change.log по mtime - без перезапуска.
                            $rm = Remove-ChangeEntries -RelPaths $paths
                            Write-Log "CMD: к отправке помечено $($paths.Count) эл. (записей снято: $rm)" "White"
                        } elseif ($panel -eq 'loc' -and $op -eq 'del') {
                            foreach ($rel in $paths) { Backup-SyncItem -Rel $rel }
                            [void](Remove-ChangeEntries -RelPaths $paths)
                            Write-Log "CMD: удалено локально $($paths.Count) эл. (бэкап в TEMP)" "White"
                        } elseif ($panel -eq 'rem' -and $op -eq 'copy') {
                            # Запросить файлы у другого ПК: маркер .get уедет синхронизацией,
                            # приёмник снимет у себя отметки и отправит перечисленное
                            Set-Content -LiteralPath (Join-Path $script:SyncDir ".get") -Value ($paths -join "`r`n") -Encoding UTF8
                            Write-Log "CMD: запрошено у другого ПК $($paths.Count) эл. (маркер .get)" "White"
                        } elseif ($panel -eq 'rem' -and $op -eq 'del') {
                            Set-Content -LiteralPath (Join-Path $script:SyncDir ".rm") -Value ($paths -join "`r`n") -Encoding UTF8
                            Write-Log "CMD: команда на удаление $($paths.Count) эл. у другого ПК (маркер .rm)" "White"
                        }
                    }
                } elseif ($path -eq "/syncpause") {
                    # Пауза фоновой синхронизации: флаг-файл .syncpause в SyncDir
                    # (Scan-SyncDir при виде флага сразу выходит, ничего не отправляя)
                    $flag = Join-Path $script:SyncDir ".syncpause"
                    if (Test-Path $flag) { Remove-Item $flag -Force } else { Set-Content -LiteralPath $flag -Value "" -Encoding ASCII }
                } elseif ($path -eq "/settings") {
                    # Сохранение параметров [Settings] в setcp.ini + перезапуск слушателя
                    $reader = New-Object System.IO.StreamReader($ctx.Request.InputStream, [System.Text.Encoding]::UTF8)
                    $body = $reader.ReadToEnd(); $reader.Close()
                    $vals = @{}
                    foreach ($pair in ($body -split '&')) {
                        $kv = $pair -split '=', 2
                        if ($kv.Count -ne 2) { continue }
                        $key = [System.Net.WebUtility]::UrlDecode($kv[0])
                        $val = [System.Net.WebUtility]::UrlDecode($kv[1])
                        if ($key -in @('SyncAckFastSec','SyncIdleGuardSec','SyncRetryDelaySec','SyncRetryMaxDelaySec','SyncPollMs','SyncBatchFiles','KeepAliveMinutes','SyncAckTimeoutSec','Debug')) {
                            $n = 0; if ([int]::TryParse($val, [ref]$n)) { $vals[$key] = $n }
                        } elseif ($key -in @('AutoUpdate','DiskSyncEnabled')) {
                            $vals[$key] = if ($val -in @('on','1','true')) { 1 } else { 0 }
                        }
                    }
                    if ($vals.Count -gt 0) {
                        $iniPath = Join-Path (Split-Path -Parent $PSCommandPath) "setcp.ini"
                        Update-IniSettings -Path $iniPath -Values $vals
                        # Слушатель перечитывает INI только при старте — рестартуем
                        Get-CimInstance Win32_Process -Filter "Name = 'powershell.exe' OR Name = 'pwsh.exe'" -ErrorAction SilentlyContinue |
                            Where-Object { $_.CommandLine -like "*-File*FileTransfer.ps1*Watch*" } |
                            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
                        Start-Sleep -Milliseconds 500
                        Start-Process -FilePath "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe" `
                            -ArgumentList "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$PSCommandPath`" Watch" `
                            -WorkingDirectory (Split-Path -Parent $PSCommandPath)
                        Write-Log "WEB: параметры сохранены ($($vals.Keys -join ', ')), слушатель перезапущен" "Cyan"
                    }
                }
                $resp.StatusCode = 302
                $resp.Headers["Location"] = "/"
                $resp.OutputStream.Close()
                continue
            }

            # Общая история: локальные события + другой контур (через status-*.json)
            $ws = Get-WebStateHtml
            $rows = [System.Text.StringBuilder]$ws.Rows
            $progressHtml = $ws.Progress

            # Компактная строка: статусы слушателя и другого контура + все кнопки.
            # Динамика (статусы, очередь, лог, прогресс) обновляется по /state
            # без перезагрузки страницы — командер не дёргается.
            $zooDir = Get-IniPath -Section "Tools" -Key "ZooDir" -Default ""
            $zooBtn = ""
            if ($zooDir -and (Test-Path (Join-Path $zooDir "gw-proxy.cmd") -PathType Leaf)) {
                $zooRunning = @(Get-CimInstance Win32_Process -Filter "Name = 'node.exe'" -ErrorAction SilentlyContinue |
                    Where-Object { $_.CommandLine -like "*gw-proxy.mjs*" }).Count -gt 0
                if ($zooRunning) {
                    $zooBtn = "<button class='btn tool warn' onclick=`"if(confirm('Остановить gw-proxy?')) post('/zoo-stop');`">gw-proxy: стоп</button>"
                } else {
                    $zooBtn = "<button class='btn tool' onclick=`"post('/zoo');`">gw-proxy</button>"
                }
            }
            $statusHtml = "<span id='stListen'>$($ws.Listen)</span><span class='sep'>|</span><span class='sub' id='stRemote'>$($ws.Remote)</span>" +
                "<button class='btn tool' onclick=`"location.href='/refresh-remote';`">Обновить</button>" +
                "<span class='sep'>|</span>" +
                "<button class='btn tool' onclick=`"post('/terminal');`">Терминал</button>" +
                "<span class='grp'><input id='copyn' type='number' value='10' min='1' max='200' class='num'>" +
                "<button class='btn tool' onclick=`"copyLog();`">Скоп. события</button></span>" +
                "<button class='btn tool warn' onclick=`"if(confirm('Перезапустить слушателя?')) post('/restart');`">Рестарт</button>" +
                "<button class='btn stop' onclick=`"if(confirm('Остановить ВСЕ задания: слушатель, отправки, gw-proxy, хоткеи?')) post('/stopall');`">Стоп все</button>" +
                $zooBtn +
                "<button class='btn tool' onclick=`"post('/opensync');`">SyncDir</button>" +
                "<button class='btn stop' onclick=`"if(confirm('Очистить очередь (локальный SyncDir)? Содержимое уедет в бэкап.')) post('/clearqueue');`">Очистить</button>" +
                "<button class='btn tool' onclick=`"post('/openlog');`">Журнал</button>" +
                "<button class='btn tool' onclick=`"if(confirm('Очистить журнал событий?')) post('/clearlog');`">Очистить лог</button>" +
                "<span id='note' class='sub'></span>"

            $machine = $env:COMPUTERNAME
            # Форма параметров справа от лога: правки [Settings] в setcp.ini
            # с перезапуском слушателя (INI перечитывается только при старте)
            $settingsHtml = "<div class='card' id='settings'><div class='st'>Параметры</div><form method='post' action='/settings'>" +
                (Get-NumField 'SyncAckFastSec' 'Ожидание ACK, сек' 'сколько буфер занят пакетом' 3) +
                (Get-NumField 'SyncIdleGuardSec' 'Покой перед отправкой, сек' 'фоновая синхр. ждёт простоя мыши/клавы' 4) +
                (Get-NumField 'SyncRetryDelaySec' 'Первый повтор, сек' 'растёт вдвое с каждой неудачей' 600) +
                (Get-NumField 'SyncRetryMaxDelaySec' 'Макс. повтор, сек' 'потолок backoff' 3600) +
                (Get-NumField 'SyncAckTimeoutSec' 'ACK ручной отправки, сек' 'только для SEND FILE' 60) +
                (Get-NumField 'SyncPollMs' 'Опрос, мс' 'частота скана очереди' 1000) +
                (Get-NumField 'SyncBatchFiles' 'Batch от N файлов' 'одним ZIP вместо пакетов' 50) +
                (Get-NumField 'KeepAliveMinutes' 'KeepAlive, мин' '0 — выключен' 0) +
                "<label><span class='pname'>Debug-лог</span><select name='Debug'><option value='0'$(if ((Get-IniValue -Section 'Settings' -Key 'Debug' -Default '0') -eq '0') { ' selected' })>только итоги</option><option value='1'$(if ((Get-IniValue -Section 'Settings' -Key 'Debug' -Default '0') -eq '1') { ' selected' })>полный</option></select></label>" +
                "<label><span class='pname'>AutoUpdate</span><input type='hidden' name='AutoUpdate' value='0'><input type='checkbox' name='AutoUpdate' value='on'$(if ((Get-IniBool -Section 'Settings' -Key 'AutoUpdate' -Default $true)) { ' checked' })></label>" +
                "<label><span class='pname'>Синхронизация disk</span><input type='hidden' name='DiskSyncEnabled' value='0'><input type='checkbox' name='DiskSyncEnabled' value='on'$(if ((Get-IniBool -Section 'Settings' -Key 'DiskSyncEnabled' -Default $false)) { ' checked' })></label>" +
                "<button class='btn start' style='margin-left:0;margin-top:8px'>Сохранить и перезапустить</button>" +
                "</form><div class='sub'>Пишется setcp.ini (C:\CHANGE) и уходит на другой контур</div></div>"

            # Макет — отдельный файл dashboard.html рядом со скриптом (правится
            # без трогания кода); подстановка — {PLACEHOLDER}-поля.
            $tplPath = Join-Path (Split-Path -Parent $PSCommandPath) "dashboard.html"
            $html = if (Test-Path $tplPath) { Read-TextFile -Path $tplPath } else { "<html><body><h3>dashboard.html не найден рядом с $PSCommandPath</h3></body></html>" }
            $html = $html.Replace("{MACHINE}", $machine).Replace("{STATUS}", $statusHtml).Replace("{PROGRESS}", $progressHtml).Replace("{SETTINGS}", $settingsHtml).Replace("{ROWS}", $rows.ToString()).Replace("{QUEUE}", $ws.QueueFiles)
            $bytes = [System.Text.Encoding]::UTF8.GetBytes($html)
            $resp.ContentType = "text/html; charset=utf-8"
            $resp.ContentLength64 = $bytes.Length
            $resp.OutputStream.Write($bytes, 0, $bytes.Length)
            $resp.OutputStream.Close()
        } catch {
            try { $resp.OutputStream.Close() } catch {}
        }
    }
}

# ===== РАЗБОР АРГУМЕНТОВ И ДИСПЕТЧЕР =====
$Action = $null
$Paths  = @()
foreach ($arg in $Targets) {
    if ($arg -in @("Pack", "PackAuto", "Unpack", "UnpackTo", "Watch", "SetLocal", "DelLocal", "LocalShow", "Resend", "ClearDisk", "MarkDelete", "History", "Web")) {
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
elseif ($Action -eq "MarkDelete") {
    Invoke-MarkDelete
}
elseif ($Action -eq "History") {
    Invoke-History
    if ($Host.Name -eq "ConsoleHost") { Read-Host "Enter — закрыть" | Out-Null }
}
elseif ($Action -eq "Web") {
    Invoke-WebStatus
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