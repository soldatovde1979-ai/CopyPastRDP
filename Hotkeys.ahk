#Requires AutoHotkey v2.0

; ============================================================================
; ВАЖНО (контуры):
;   Этот скрипт и ВСЕ хоткеи работают ТОЛЬКО на внешнем контуре — машине,
;   с которой открыт RDP-клиент («Подключение к удаленному рабочему столу»).
;   Внутри RDP-сессии (на внутреннем контуре) хоткеи НЕ срабатывают:
;   AutoHotkey перехватывает клавиши на внешнем контуре ещё до передачи в сессию.
;
;   Слушатель FileTransfer (Watch) сейчас работает на внутреннем контуре,
;   но запустить его на внешнем — не проблема (CreateShortcuts.ps1 или
;   ярлык «СЛУШАТЕЛЬ» в Автозагрузке). Для синхронизации папок
;   (DiskSyncEnabled=1) слушатель нужен на ОБОИХ контурах.
; ============================================================================

; ==================== БЛОК УВЕДОМЛЕНИЯ ПРИ ЗАПУСКЕ ====================
MsgBox(
    "Скрипт автоматизации запущен и готов к работе!`n`n" .
    "Ctrl + Alt + A  —  Перезапуск скрипта (Reload)`n" .
    "Ctrl + Alt + R  —  Исправить раскладку выделенного текста`n" .
    "Pause           —  Исправить раскладку слова слева от курсора`n" .
    "Ctrl + Alt + T  —  Вставить быструю ссылку КТалк`n" .
    "Глобальные хоткеи для передачи файлов:`n" .
    "Ctrl + Alt + C  —  Отправить все файлы из OUT`n" .
    "Ctrl + Alt + V  —  Получить файлы в папку IN`n",
    "AutoHotkey Домашний", 
    "Iconi T5"
)

; ==================== ТАБЛИЦА И ЛОГИКА РАСКЛАДКИ ====================
global ENG := "qwertyuiop[]asdfghjkl;'zxcvbnm,./``" . 'QWERTYUIOP{}ASDFGHJKL:"ZXCVBNM<>?~'
global RUS := "йцукенгшщзхъфывапролджэячсмитьбю.ё" . 'ЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЭЯЧСМИТЬБЮ,Ё'

global ENG_LETTERS := "qwertyuiopasdfghjklzxcvbnmQWERTYUIOPASDFGHJKLZXCVBNM"
global RUS_LETTERS := "йцукенгшщзхъфывапролджячсмитьбюЙЦУКЕНГШЩЗХЪФЫВАПРОЛДЖЯЧСМИТЬБЮ"

global ENG2RUS := Map()
global RUS2ENG := Map()

InitMaps() {
    global ENG, RUS, ENG2RUS, RUS2ENG
    Loop Parse ENG {
        ENG2RUS[A_LoopField] := SubStr(RUS, A_Index, 1)
    }
    Loop Parse RUS {
        RUS2ENG[A_LoopField] := SubStr(ENG, A_Index, 1)
    }
}
InitMaps()

DetectDirection(text) {
    global ENG_LETTERS, RUS_LETTERS
    engHits := 0, rusHits := 0
    Loop Parse text {
        if InStr(ENG_LETTERS, A_LoopField, true)
            engHits++
        else if InStr(RUS_LETTERS, A_LoopField, true)
            rusHits++
    }
    if (engHits = 0 && rusHits = 0)
        return "none"
    return (engHits >= rusHits) ? "eng2rus" : "rus2eng"
}

SwitchLayout(text) {
    global ENG2RUS, RUS2ENG
    dir := DetectDirection(text)
    if (dir = "none")
        return text
    map := (dir = "eng2rus") ? ENG2RUS : RUS2ENG
    out := ""
    Loop Parse text {
        out .= map.Has(A_LoopField) ? map[A_LoopField] : A_LoopField
    }
    return { text: out, direction: dir }
}

SetKeyboardLayout(langId) {
    hkl := DllCall("LoadKeyboardLayout", "Str", Format("{:08x}", langId), "UInt", 0x1, "Ptr")
    hwnd := WinExist("A")
    if hwnd
        PostMessage(0x0050, 0, hkl, , "ahk_id " hwnd)
}

; ==================== ГОРЯЧИЕ КЛАВИШИ СИСТЕМЫ ====================

; Ctrl + Alt + A (физическая sc01E) — Перезапустить скрипт
^!sc01E::
{
    Reload
}

; Ctrl + Alt + T (физическая sc014) — Вставить ссылку КТалк
^!sc014::
{
    A_Clipboard := "https://svo-airport.ktalk.ru/sirsb1vpb6fa"
    Send("^v")
}


; ==================== КОНВЕРТАЦИЯ РАСКЛАДКИ ====================

; Ctrl + Alt + R (физическая sc013) — Исправить выделенный/скопированный текст
^!sc013::
{
    clipSaved := ClipboardAll()
    A_Clipboard := ""
    Send("^c")
    if ClipWait(0.6) {
        result := SwitchLayout(A_Clipboard)
        if (result != A_Clipboard && IsObject(result)) {
            A_Clipboard := result.text
            Send("^v")
            Sleep(50)
            SetKeyboardLayout(result.direction = "eng2rus" ? 0x0419 : 0x0409)
        }
    }
    A_Clipboard := clipSaved
}

; Pause — Конвертировать последнее слово слева от курсора
Pause::
{
    global ENG2RUS, RUS2ENG

    Send("+{Home}")
    Sleep(30)
    clipSaved := ClipboardAll()
    A_Clipboard := ""
    Send("^c")
    if !ClipWait(0.6) {
        Send("{Right}")
        A_Clipboard := clipSaved
        return
    }
    lineBefore := A_Clipboard
    Send("{Right}")

    wordChars := ""
    len := StrLen(lineBefore)
    Loop len {
        idx := len - A_Index + 1
        ch := SubStr(lineBefore, idx, 1)
        if (ch = " " || ch = "`t" || ch = "`n" || ch = "`r")
            break
        wordChars := ch . wordChars
    }

    if (wordChars = "") {
        A_Clipboard := clipSaved
        return
    }

    wordLen := StrLen(wordChars)
    Send("+{Left " wordLen "}")
    Sleep(20)

    A_Clipboard := ""
    Send("^c")
    if ClipWait(0.6) {
        result := SwitchLayout(A_Clipboard)
        if IsObject(result) {
            A_Clipboard := result.text
            Send("^v")
            Sleep(50)
            SetKeyboardLayout(result.direction = "eng2rus" ? 0x0419 : 0x0409)
        } else {
            Send("{Right}")
        }
    }
    A_Clipboard := clipSaved
}

; ==================== ГЛОБАЛЬНЫЕ ХОТКЕИ ДЛЯ ПЕРЕДАЧИ ФАЙЛОВ ====================

; Ctrl + Alt + C — Send File
^!sc02E::
{
    Run(A_AppData . '\Microsoft\Windows\SendTo\Send File.lnk')
}

; Ctrl + Alt + V — Receive File
^!sc02F::
{
    Run(A_AppData . '\Microsoft\Windows\SendTo\Receive File.lnk')
}