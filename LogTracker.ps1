<#
    LogTracker.ps1 — трекер журнала FileTransfer (CopyPast)

    Назначение: просмотр, живое отслеживание, фильтрация, поиск и статистика
    по журналу передачи файлов (по умолчанию C:\CHANGE\FileTransfer.log).

    Использование:
        powershell -File LogTracker.ps1                — интерактивное меню
        powershell -File LogTracker.ps1 -Tail 30       — последние 30 строк
        powershell -File LogTracker.ps1 -Follow        — живой режим (Ctrl+C — выход)
        powershell -File LogTracker.ps1 -Stats         — сводка по журналу
        powershell -File LogTracker.ps1 -Errors        — только ошибки и предупреждения
        powershell -File LogTracker.ps1 -Filter "chunk" — только строки с текстом
        powershell -File LogTracker.ps1 -Search "msi"   — поиск с номерами строк
        powershell -File LogTracker.ps1 -Clear         — очистить журнал (с подтверждением)
        powershell -File LogTracker.ps1 -Log "путь\к\лог.log" — свой файл журнала

    Путь к журналу определяется так же, как в FileTransfer.ps1:
        1) аргумент -Log;
        2) ключ LogFile из setcp.ini рядом с этим скриптом;
        3) ключ LogFile из C:\CHANGE\setcp.ini;
        4) значение по умолчанию C:\CHANGE\FileTransfer.log.
#>
param(
    [string]$Log    = "",
    [int]   $Tail   = 50,
    [switch]$Follow,
    [switch]$Stats,
    [switch]$Errors,
    [switch]$Clear,
    [string]$Filter = "",
    [string]$Search = ""
)

$ErrorActionPreference = "SilentlyContinue"
try { [Console]::OutputEncoding = [System.Text.Encoding]::UTF8 } catch {}

# ===== ПУТЬ К ЖУРНАЛУ =====

function Get-IniValue {
    param([string]$Path, [string]$Key)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    foreach ($line in Get-Content -LiteralPath $Path -Encoding UTF8) {
        $m = [regex]::Match($line, '^\s*' + [regex]::Escape($Key) + '\s*=\s*(.+?)\s*(?:;.*)?$')
        if ($m.Success) { return $m.Groups[1].Value.Trim() }
    }
    return $null
}

function Resolve-LogPath {
    if ($Log.Trim() -ne "") { return $Log.Trim() }
    $scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
    $iniCandidates = @(
        (Join-Path $scriptDir "setcp.ini"),
        "C:\CHANGE\setcp.ini"
    )
    foreach ($ini in $iniCandidates) {
        $v = Get-IniValue -Path $ini -Key "LogFile"
        if ($v) { return $v }
    }
    return "C:\CHANGE\FileTransfer.log"
}

function Read-LogLines {
    param([string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { return $null }
    return @(Get-Content -LiteralPath $Path -Encoding UTF8)
}

# ===== ВЫВОД С ПОДСВЕТКОЙ =====

function Write-LogLine {
    param([string]$Line)
    $c = "Gray"
    if     ($Line -match "FATAL|ERROR|FAIL")    { $c = "Red" }
    elseif ($Line -match "WARNING|WARN")         { $c = "Yellow" }
    elseif ($Line -match "SUCCESS|OK:")          { $c = "Green" }
    elseif ($Line -match "ROUTE|OVERWRITE")      { $c = "Cyan" }
    elseif ($Line -match "===== START|===== END") { $c = "DarkGray" }
    Write-Host $Line -ForegroundColor $c
}

function Show-Header {
    param([string]$Text)
    Write-Host "=== $Text ===" -ForegroundColor Magenta
}

# ===== РЕЖИМЫ ПРОСМОТРА =====

function Show-Tail {
    param([string[]]$Lines, [int]$Count)
    if ($Count -lt 1) { $Count = 50 }
    Show-Header "ПОСЛЕДНИЕ $Count СТРОК"
    $Lines | Select-Object -Last $Count | ForEach-Object { Write-LogLine $_ }
}

function Show-Follow {
    param([string]$Path)
    Show-Header "ЖИВОЙ РЕЖИМ (Ctrl+C — выход)"
    Get-Content -LiteralPath $Path -Tail 10 -Wait -Encoding UTF8 | ForEach-Object { Write-LogLine $_ }
}

function Show-Errors {
    param([string[]]$Lines)
    $err = @($Lines | Where-Object { $_ -match "FATAL|ERROR|FAIL|WARNING" })
    if ($err.Count -eq 0) {
        Write-Host "Ошибок и предупреждений не найдено." -ForegroundColor Green
        return
    }
    Show-Header "ОШИБКИ И ПРЕДУПРЕЖДЕНИЯ ($($err.Count))"
    $err | ForEach-Object { Write-LogLine $_ }
}

function Show-Filter {
    param([string[]]$Lines, [string]$Pattern)
    $res = @($Lines | Where-Object { $_ -like "*$Pattern*" })
    if ($res.Count -eq 0) {
        Write-Host "Ничего не найдено по фильтру '$Pattern'." -ForegroundColor Yellow
        return
    }
    Show-Header "ФИЛЬТР '$Pattern' ($($res.Count))"
    $res | ForEach-Object { Write-LogLine $_ }
}

function Show-Search {
    param([string[]]$Lines, [string]$Pattern)
    Show-Header "ПОИСК '$Pattern'"
    $found = 0
    for ($i = 0; $i -lt $Lines.Count; $i++) {
        if ($Lines[$i] -like "*$Pattern*") {
            $found++
            Write-Host ("[{0}] " -f ($i + 1)) -NoNewline -ForegroundColor DarkGray
            Write-LogLine $Lines[$i]
        }
    }
    if ($found -eq 0) { Write-Host "Ничего не найдено." -ForegroundColor Yellow }
}

# ===== СТАТИСТИКА =====

function Show-Stats {
    param([string[]]$Lines, [string]$Path)

    Show-Header "СТАТИСТИКА ЖУРНАЛА"
    Write-Host ("Файл: " + $Path)
    Write-Host ("Строк: " + $Lines.Count)

    $dates = @()
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^\[(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2})\]')
        if ($m.Success) { $dates += [datetime]::ParseExact($m.Groups[1].Value, "yyyy-MM-dd HH:mm:ss", $null) }
    }
    if ($dates.Count -gt 0) {
        Write-Host ("Период: " + $dates[0] + "  —  " + $dates[-1])
    }

    Write-Host "--- Записи по режимам ---"
    $labels = @()
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '^\[[\d: \-]+\]\s*\[([^\]]+)\]')
        if ($m.Success) { $labels += $m.Groups[1].Value }
    }
    $labels | Group-Object | Sort-Object Count -Descending | ForEach-Object {
        Write-Host ("  " + $_.Name + ": " + $_.Count)
    }

    Write-Host "--- События ---"
    $events = @(
        @{ Name = "Файлов собрано (SUCCESS assembled)";    Pattern = "completely assembled" },
        @{ Name = "Отправлено пакетов (Sent ... files)";   Pattern = "Sent .* files to clipboard" },
        @{ Name = "Подтверждений приёма (confirmed)";      Pattern = "Receiver confirmed" },
        @{ Name = "Принято файлов (OK: имя)";              Pattern = "  OK: " },
        @{ Name = "Получено чанков";                       Pattern = "Received chunk" },
        @{ Name = "Перезаписей (OVERWRITE)";               Pattern = "OVERWRITE" },
        @{ Name = "Сработавших маршрутов (ROUTE)";         Pattern = "ROUTE:" },
        @{ Name = "Ошибок (FAIL/FATAL/ERROR)";             Pattern = "FATAL|ERROR|FAIL" },
        @{ Name = "Предупреждений (WARNING)";              Pattern = "WARNING" }
    )
    foreach ($e in $events) {
        $cnt = @($Lines | Where-Object { $_ -match $e.Pattern }).Count
        Write-Host ("  " + $e.Name + ": " + $cnt)
    }

    $mb = 0.0
    foreach ($line in $Lines) {
        $m = [regex]::Match($line, '\(([\d.]+) MB\)')
        if ($m.Success) { $mb += [double]$m.Groups[1].Value }
    }
    if ($mb -gt 0) { Write-Host ("  Передано данных (сумма по записям): " + [math]::Round($mb, 1) + " MB") }

    $err = @($Lines | Where-Object { $_ -match "FATAL|ERROR|FAIL|WARNING" } | Select-Object -Last 5)
    if ($err.Count -gt 0) {
        Write-Host "--- Последние проблемы ---"
        $err | ForEach-Object { Write-LogLine $_ }
    }
}

# ===== ОЧИСТКА =====

function Clear-Log {
    param([string]$Path)
    Write-Host ("Будет очищен: " + $Path) -ForegroundColor Yellow
    $ans = Read-Host "Точно очистить журнал? (yes/no)"
    if ($ans -match '^(y|yes|д|да)$') {
        Set-Content -LiteralPath $Path -Value "" -Encoding UTF8
        Write-Host "Журнал очищен." -ForegroundColor Green
    } else {
        Write-Host "Отменено." -ForegroundColor Gray
    }
}

# ===== МЕНЮ =====

function Show-Menu {
    param([string]$Path)

    while ($true) {
        Write-Host ""
        Write-Host "==============================================" -ForegroundColor Cyan
        Write-Host "  LOG TRACKER  |  $Path" -ForegroundColor Cyan
        Write-Host "==============================================" -ForegroundColor Cyan
        Write-Host "  1. Последние 50 строк"
        Write-Host "  2. Последние N строк (задать N)"
        Write-Host "  3. Живой режим (Ctrl+C — выход)"
        Write-Host "  4. Ошибки и предупреждения"
        Write-Host "  5. Фильтр по тексту"
        Write-Host "  6. Поиск (с номерами строк)"
        Write-Host "  7. Статистика"
        Write-Host "  8. Очистить журнал"
        Write-Host "  0. Выход"
        $choice = Read-Host "Выбор"

        if ($choice -eq "0") { return }

        if ($choice -ne "8") {
            $lines = Read-LogLines -Path $Path
            if ($null -eq $lines) {
                Write-Host ("Журнал не найден: " + $Path) -ForegroundColor Red
                $null = Read-Host "Нажмите Enter..."
                continue
            }
        }

        switch ($choice) {
            "1" { Show-Tail -Lines $lines -Count 50 }
            "2" {
                $n = Read-Host "Сколько строк (50)"
                if ($n -eq "") { $n = 50 }
                Show-Tail -Lines $lines -Count ([int]$n)
            }
            "3" { Show-Follow -Path $Path }
            "4" { Show-Errors -Lines $lines }
            "5" {
                $f = Read-Host "Текст фильтра"
                if ($f -ne "") { Show-Filter -Lines $lines -Pattern $f }
            }
            "6" {
                $s = Read-Host "Что ищем"
                if ($s -ne "") { Show-Search -Lines $lines -Pattern $s }
            }
            "7" { Show-Stats -Lines $lines -Path $Path }
            "8" { Clear-Log -Path $Path }
            default { Write-Host "Неизвестный пункт меню." -ForegroundColor Yellow }
        }
    }
}

# ===== ТОЧКА ВХОДА =====

$logPath = Resolve-LogPath

if ($Clear) {
    Clear-Log -Path $logPath
    exit 0
}

$lines = Read-LogLines -Path $logPath
if ($null -eq $lines) {
    Write-Host ("Журнал не найден: " + $logPath) -ForegroundColor Red
    Write-Host "Укажите файл параметром -Log или проверьте ключ LogFile в setcp.ini"
    exit 1
}

if ($Follow) { Show-Follow -Path $logPath; exit 0 }
if ($Stats)  { Show-Stats -Lines $lines -Path $logPath; exit 0 }
if ($Errors) { Show-Errors -Lines $lines; exit 0 }
if ($Filter -ne "") { Show-Filter -Lines $lines -Pattern $Filter; exit 0 }
if ($Search -ne "") { Show-Search -Lines $lines -Pattern $Search; exit 0 }
if ($MyInvocation.BoundParameters.ContainsKey("Tail")) { Show-Tail -Lines $lines -Count $Tail; exit 0 }

Show-Menu -Path $logPath
