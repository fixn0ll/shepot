module os_win;

import core.stdc.stdio : freopen, stderr, stdout;
import core.stdc.string : memcpy;
import core.sync.mutex : Mutex;
import core.sys.windows.commctrl;
import core.sys.windows.shellapi;
import core.sys.windows.winbase : CloseHandle, CreateMutexW, GetFileType, GetLastError,
    GetModuleHandleW, GetStdHandle, GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE,
    STD_OUTPUT_HANDLE;
import core.sys.windows.wincon : AllocConsole, ATTACH_PARENT_PROCESS, AttachConsole,
    FreeConsole, SetConsoleCP, SetConsoleOutputCP;
import core.sys.windows.windef : BYTE, COLORREF, DWORD, ERROR_SUCCESS, FALSE, HBITMAP, HBRUSH, HDC, HFONT,
    HGLOBAL, HHOOK, HICON, HKEY, HMENU, HRGN, HWND, LPARAM, LRESULT, POINT, RECT, TRUE, UINT, WORD, WPARAM;
import core.sys.windows.winerror : ERROR_ALREADY_EXISTS;
import core.sys.windows.wingdi;
import core.sys.windows.winnt : HANDLE, KEY_READ, KEY_WRITE;
import core.sys.windows.winreg : HKEY_CURRENT_USER, REG_SZ, RegCloseKey, RegDeleteValueW,
    RegOpenKeyExW, RegQueryValueExW, RegSetValueExW;
import core.sys.windows.winuser;
import core.thread : Thread;
import core.time : msecs;
import sound : playClickAsync;
import std.algorithm : max, min;
import std.file : thisExePath;
import std.format : format;
import std.math : fabs, sqrt;
import std.range : walkLength;
import std.utf : toUTF16, toUTF16z;

private enum uint WM_APP_TRAY = WM_APP + 1;
private enum uint WM_APP_SYNC = WM_APP + 2;

private enum int ID_BTN_HIDE = 101;
private enum int ID_BTN_MODEL = 102;
private enum int ID_PROGRESS = 103;
private enum int ID_COMBO_MIC = 104;
private enum int ID_COMBO_MODEL = 105;
private enum int ID_COMBO_LANG = 106;
private enum int ID_BTN_HOTKEY = 107;
private enum int ID_COMBO_TIMEOUT = 108;
private enum int ID_CHK_AUTOLOAD = 109;
private enum int ID_CHK_CPU_ONLY = 110;
private enum int ID_CHK_START_TRAY = 111;
private enum int ID_CHK_WIN_AUTO = 112;
private enum int ID_CHK_LIVE_PREVIEW = 113;
private enum int ID_CHK_OVERLAY = 114;
private enum int ID_EDIT_LOG = 115;
private enum int ID_COMBO_INPUT_MODE = 116;
private enum int ID_CHK_TOGGLE_MODE = 117;

private enum int ID_TRAY_TOGGLE = 201;
private enum int ID_TRAY_EXIT = 202;
private enum int ID_TRAY_MODEL_TOGGLE = 203;
private enum int ID_TRAY_HOTKEY = 204;
private enum int ID_TRAY_CPU_ONLY = 205;
private enum int ID_TRAY_BEEP = 206;
private enum int ID_TRAY_OVERLAY = 207;
private enum int ID_TRAY_WIN_AUTO = 208;
private enum int ID_TRAY_LIVE_PREVIEW = 209;
private enum int ID_TRAY_COPY_LAST = 210;
private enum int ID_TRAY_TOGGLE_MODE = 211;

private enum int ID_TRAY_MIC_BASE = 1000;
private enum int ID_TRAY_MODEL_BASE = 2000;
private enum int ID_TRAY_LANG_BASE = 3000;
private enum int ID_TRAY_TIMEOUT_BASE = 4000;
private enum int ID_TRAY_INPUT_MODE_BASE = 5000;

private enum size_t ID_TIMER_IDLE = 1;
private enum size_t ID_TIMER_CLICK = 2;
private enum size_t ID_TIMER_HUD_HIDE = 3;
private enum size_t ID_TIMER_PREVIEW = 4;

enum VisualState : int {
    idle = 0,
    recording = 1,
    processing = 2,
    pasted = 3,
}

private enum wstring RUN_REG_SUBKEY = "Software\\Microsoft\\Windows\\CurrentVersion\\Run"w;
private enum wstring RUN_REG_VALUE = "Shepot"w;

struct UiOption {
    string label;
    string value;
}

struct TimeoutOption {
    string label;
    int minutes;
}

static immutable TimeoutOption[] timeoutOptions = [
    TimeoutOption("1 мин", 1),
    TimeoutOption("3 мин", 3),
    TimeoutOption("5 мин", 5),
    TimeoutOption("10 мин", 10),
    TimeoutOption("15 мин", 15),
    TimeoutOption("30 мин", 30),
    TimeoutOption("Никогда", 0),
];

static immutable UiOption[] inputModeOptions = [
    UiOption("Посимвольно (игры / SendInput)", "sendinput"),
    UiOption("Буфер обмена (Ctrl+V)", "clipboard"),
    UiOption("Авто (<=80 симв. — посимвольно)", "auto"),
];

private struct AppUiState {
    HHOOK kbdHook;
    HHOOK mouseHook;
    uint hotkeyVk;
    string hotkeyName;
    bool blockHotkey = true;
    bool toggleMode;
    bool isDown;
    bool keyPhysicallyDown;
    bool waitRelease;
    bool capturingHotkey;
    string lastPhrase;

    bool modelLoaded;
    bool modelLoading;
    string[] micNames;
    int currentMic;
    UiOption[] modelOptions;
    string currentModel;
    UiOption[] langOptions;
    string currentLang;
    int currentTimeoutMin;
    string currentInputMode = "sendinput";
    bool cpuOnly;
    bool beepEnabled;
    bool livePreview;
    bool winAutostart;

    void delegate() onStart;
    void delegate() onStop;
    void delegate() onCancel;
    void delegate(int) onMicChange;
    void delegate(string) onModelSelect;
    void delegate(string) onLangChange;
    string delegate(uint) onHotkeyChange;
    void delegate() onModelToggle;
    void delegate(int) onTimeoutChange;
    void delegate(string) onInputModeChange;
    void delegate(bool) onToggleModeChange;
    void delegate(bool) onAutoLoadChange;
    void delegate(bool) onCpuOnlyChange;
    void delegate(bool) onBeepChange;
    void delegate(bool) onOverlayChange;
    void delegate(bool) onLivePreviewChange;
    void delegate(bool) onStartTrayChange;
    void delegate(bool) onWinAutoChange;
    void delegate() onIdleTick;
    void delegate() onPreviewTick;

    HWND hwnd;
    HWND lblStatus;
    HWND btnHide;
    HWND btnModel;
    HWND progressBar;
    HWND lblMic;
    HWND comboMic;
    HWND lblModel;
    HWND comboModel;
    HWND lblLang;
    HWND comboLang;
    HWND lblHotkey;
    HWND btnHotkey;
    HWND lblTimeout;
    HWND comboTimeout;
    HWND lblInputMode;
    HWND comboInputMode;
    HWND chkAutoLoad;
    HWND chkCpuOnly;
    HWND chkStartTray;
    HWND chkWinAuto;
    HWND chkLivePreview;
    HWND chkOverlay;
    HWND chkToggleMode;
    HWND lblLog;
    HWND editLog;

    HFONT fontTitle;
    HFONT fontBtnBold;
    HFONT fontUi;
    HFONT fontMono;
    HICON iconBig;
    HICON iconSmall;
    HICON iconRec;
    HICON iconProc;
    HICON iconPasted;
    NOTIFYICONDATAW nid;

    HWND hudWnd;
    bool showOverlay;
    VisualState hudState = VisualState.idle;
    string hudText;

    Mutex mtx;
    string pendingStatus;
    bool hasPendingStatus;
    int pendingVisualState = -1;
    string pendingHudText;
    bool hasPendingHudText;
    int pendingHudHideMs = -1;
    int pendingModelState = -1;
    int pendingLoadWait = -1;
    int pendingProgressMode = -1; // 0 reset, 1 marquee, 2 determinate
    int pendingProgressPct = 0;
    string pendingLastPhrase;
    bool hasPendingLastPhrase;
    string[] pendingLogs;
    bool clickTimerActive;
    bool marqueeActive;
}

private __gshared AppUiState g_ui;
private __gshared HANDLE g_singleInstanceMutex = null;

/// Гарантирует запуск единственного экземпляра приложения; при наличии уже запущенного — разворачивает его окно.
bool acquireSingleInstance() {
    if (g_singleInstanceMutex !is null) return true;
    HANDLE h = CreateMutexW(null, FALSE, "Local\\ShepotSingleInstanceMutex"w.ptr);
    if (h is null) return true;

    if (GetLastError() == ERROR_ALREADY_EXISTS) {
        CloseHandle(h);
        HWND existing = FindWindowW("ShepotWindowClass"w.ptr, null);
        if (existing !is null) {
            ShowWindow(existing, SW_RESTORE);
            SetForegroundWindow(existing);
        }
        return false;
    }

    g_singleInstanceMutex = h;
    return true;
}

void releaseSingleInstance() {
    if (g_singleInstanceMutex !is null) {
        CloseHandle(g_singleInstanceMutex);
        g_singleInstanceMutex = null;
    }
}

/// Подключает родительскую консоль (для CLI-режима --check / --setup), не ломая перенаправление в pipe/файл.
void attachParentConsoleIfAny() {
    if (GetFileType(GetStdHandle(STD_OUTPUT_HANDLE)) != 0) return;
    if (AttachConsole(ATTACH_PARENT_PROCESS)) {
        freopen("CONOUT$", "w", stdout);
        freopen("CONOUT$", "w", stderr);
    }
    enum uint CP_UTF8 = 65001;
    SetConsoleOutputCP(CP_UTF8);
    SetConsoleCP(CP_UTF8);
}

/// Открывает временную консоль для отображения прогресса curl при первом старте.
void openTempConsole() {
    if (AllocConsole()) {
        freopen("CONOUT$", "w", stdout);
        freopen("CONOUT$", "w", stderr);
        enum uint CP_UTF8 = 65001;
        SetConsoleOutputCP(CP_UTF8);
        SetConsoleCP(CP_UTF8);
    }
}

void closeTempConsole() {
    FreeConsole();
}

void showErrorBox(string msg) {
    MessageBoxW(null, msg.toUTF16z(), "Shepot — Ошибка"w.ptr, MB_OK | MB_ICONERROR);
}

/// Проверяет, добавлено ли приложение в автозапуск Windows (HKCU\...\Run).
bool isWindowsAutostartEnabled() {
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_REG_SUBKEY.ptr, 0, KEY_READ, &hKey) != ERROR_SUCCESS) {
        return false;
    }
    scope (exit) RegCloseKey(hKey);
    DWORD type = 0;
    DWORD size = 0;
    return RegQueryValueExW(hKey, RUN_REG_VALUE.ptr, null, &type, null, &size) == ERROR_SUCCESS;
}

/// Включает или отключает автозапуск текущего exe при входе в Windows.
bool setWindowsAutostart(bool enable) {
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER, RUN_REG_SUBKEY.ptr, 0, KEY_WRITE, &hKey) != ERROR_SUCCESS) {
        return false;
    }
    scope (exit) RegCloseKey(hKey);

    if (!enable) {
        auto rc = RegDeleteValueW(hKey, RUN_REG_VALUE.ptr);
        return rc == ERROR_SUCCESS || rc == 2; // ERROR_FILE_NOT_FOUND
    }

    auto val = ("\"" ~ thisExePath() ~ "\"").toUTF16();
    auto bytes = cast(DWORD)((val.length + 1) * wchar.sizeof);
    auto z = new wchar[val.length + 1];
    z[0 .. val.length] = val[];
    z[$ - 1] = 0;
    return RegSetValueExW(hKey, RUN_REG_VALUE.ptr, 0, REG_SZ, cast(const(ubyte)*) z.ptr, bytes) == ERROR_SUCCESS;
}

bool typeText(string text, string inputMode, int charDelayMs, int restoreDelayMs, out string methodUsed) {
    if (text.length == 0) {
        methodUsed = "empty";
        return false;
    }

    bool useClipboard = false;
    if (inputMode == "clipboard") {
        useClipboard = true;
    } else if (inputMode == "auto") {
        useClipboard = walkLength(text) > 80;
    }

    if (useClipboard) {
        if (pasteViaClipboard(text, restoreDelayMs)) {
            methodUsed = "clipboard+Ctrl+V";
            return true;
        }
        typeUnicodeDirect(text, charDelayMs);
        methodUsed = "SendInput(UNICODE, fallback)";
        return true;
    }

    typeUnicodeDirect(text, charDelayMs);
    methodUsed = "SendInput(UNICODE)";
    return true;
}

private bool openClipboardRetry() {
    foreach (_; 0 .. 4) {
        if (OpenClipboard(null) != 0) return true;
        Thread.sleep(msecs(15));
    }
    return false;
}

private bool pasteViaClipboard(string text, int restoreDelayMs) {
    wstring prevText;
    bool hadPrevText = false;

    if (!openClipboardRetry()) return false;

    bool hasText = IsClipboardFormatAvailable(CF_UNICODETEXT) != 0;
    if (!hasText && CountClipboardFormats() > 0) {
        // В буфере картинка, файлы или другие данные — не затираем буфер обмена.
        CloseClipboard();
        return false;
    }

    if (hasText) {
        auto hPrev = GetClipboardData(CF_UNICODETEXT);
        if (hPrev !is null) {
            auto pPrev = cast(const(wchar)*) GlobalLock(hPrev);
            if (pPrev !is null) {
                size_t len = 0;
                while (pPrev[len] != 0) ++len;
                prevText = pPrev[0 .. len].idup;
                hadPrevText = true;
                GlobalUnlock(hPrev);
            }
        }
    }

    bool written = setClipboardUtf16(toUTF16(text));
    CloseClipboard();
    if (!written) return false;

    sendCtrlV();

    if (hadPrevText) {
        if (restoreDelayMs > 0) Thread.sleep(msecs(restoreDelayMs));
        if (openClipboardRetry()) {
            setClipboardUtf16(prevText);
            CloseClipboard();
        }
    }
    return true;
}

private bool setClipboardUtf16(const(wchar)[] utf16) {
    EmptyClipboard();
    size_t bytes = (utf16.length + 1) * wchar.sizeof;
    HGLOBAL hMem = GlobalAlloc(GMEM_MOVEABLE, bytes);
    if (hMem is null) return false;

    auto dst = cast(wchar*) GlobalLock(hMem);
    if (dst is null) return false;
    if (utf16.length > 0) {
        memcpy(dst, utf16.ptr, utf16.length * wchar.sizeof);
    }
    dst[utf16.length] = 0;
    GlobalUnlock(hMem);

    return SetClipboardData(CF_UNICODETEXT, cast(HANDLE) hMem) !is null;
}

bool copyTextToClipboard(string text) {
    if (text.length == 0 || !openClipboardRetry()) return false;
    bool ok = setClipboardUtf16(toUTF16(text));
    CloseClipboard();
    return ok;
}

private void sendCtrlV() {
    WORD scCtrl = cast(WORD) MapVirtualKeyW(VK_CONTROL, 0);
    WORD scV = cast(WORD) MapVirtualKeyW('V', 0);

    INPUT[4] inputs;
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = VK_CONTROL;
    inputs[0].ki.wScan = scCtrl;

    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wVk = 'V';
    inputs[1].ki.wScan = scV;

    inputs[2].type = INPUT_KEYBOARD;
    inputs[2].ki.wVk = 'V';
    inputs[2].ki.wScan = scV;
    inputs[2].ki.dwFlags = KEYEVENTF_KEYUP;

    inputs[3].type = INPUT_KEYBOARD;
    inputs[3].ki.wVk = VK_CONTROL;
    inputs[3].ki.wScan = scCtrl;
    inputs[3].ki.dwFlags = KEYEVENTF_KEYUP;

    SendInput(4, inputs.ptr, INPUT.sizeof);
}

private void sendReturnKey() {
    WORD scRet = cast(WORD) MapVirtualKeyW(VK_RETURN, 0);
    INPUT[2] inputs;
    inputs[0].type = INPUT_KEYBOARD;
    inputs[0].ki.wVk = VK_RETURN;
    inputs[0].ki.wScan = scRet;

    inputs[1].type = INPUT_KEYBOARD;
    inputs[1].ki.wVk = VK_RETURN;
    inputs[1].ki.wScan = scRet;
    inputs[1].ki.dwFlags = KEYEVENTF_KEYUP;

    SendInput(2, inputs.ptr, INPUT.sizeof);
}

private void typeUnicodeDirect(string text, int charDelayMs) {
    auto utf16 = toUTF16(text);
    if (utf16.length == 0) return;

    int delay = charDelayMs < 0 ? 0 : charDelayMs;
    size_t i = 0;
    while (i < utf16.length) {
        wchar ch = utf16[i];
        if (ch == '\r') {
            if (i + 1 < utf16.length && utf16[i + 1] == '\n') {
                ++i;
            }
            sendReturnKey();
        } else if (ch == '\n') {
            sendReturnKey();
        } else {
            INPUT[2] inputs;
            inputs[0].type = INPUT_KEYBOARD;
            inputs[0].ki.wScan = ch;
            inputs[0].ki.dwFlags = KEYEVENTF_UNICODE;

            inputs[1].type = INPUT_KEYBOARD;
            inputs[1].ki.wScan = ch;
            inputs[1].ki.dwFlags = KEYEVENTF_UNICODE | KEYEVENTF_KEYUP;

            SendInput(2, inputs.ptr, INPUT.sizeof);
        }

        ++i;
        if (delay > 0 && i < utf16.length) {
            Thread.sleep(msecs(delay));
        }
    }
}

void uiSetStatus(string status) {
    if (g_ui.mtx is null || g_ui.hwnd is null) return;
    g_ui.mtx.lock();
    g_ui.pendingStatus = status;
    g_ui.hasPendingStatus = true;
    g_ui.mtx.unlock();
    PostMessageW(g_ui.hwnd, WM_APP_SYNC, 0, 0);
}

void uiSetIdleStatus(bool modelLoaded) {
    if (g_ui.mtx is null || g_ui.hwnd is null) return;
    g_ui.mtx.lock();
    g_ui.pendingStatus = modelLoaded
        ? ((g_ui.toggleMode ? "Готово — нажмите [" : "Готово — удерживайте [") ~ g_ui.hotkeyName ~ "]")
        : ("Модель выгружена — нажмите [" ~ g_ui.hotkeyName ~ "] или Загрузить");
    g_ui.hasPendingStatus = true;
    g_ui.mtx.unlock();
    PostMessageW(g_ui.hwnd, WM_APP_SYNC, 0, 0);
}

void uiSetLastPhrase(string phrase) {
    if (g_ui.mtx is null || g_ui.hwnd is null) return;
    g_ui.mtx.lock();
    g_ui.pendingLastPhrase = phrase;
    g_ui.hasPendingLastPhrase = true;
    g_ui.mtx.unlock();
    PostMessageW(g_ui.hwnd, WM_APP_SYNC, 0, 0);
}

void uiSetModelState(bool loaded, bool loading) {
    if (g_ui.mtx is null || g_ui.hwnd is null) return;
    g_ui.mtx.lock();
    g_ui.pendingModelState = loading ? 2 : (loaded ? 1 : 0);
    g_ui.mtx.unlock();
    PostMessageW(g_ui.hwnd, WM_APP_SYNC, 0, 0);
}

void uiSetLoadWaiting(bool waiting) {
    if (g_ui.mtx is null || g_ui.hwnd is null) return;
    g_ui.mtx.lock();
    g_ui.pendingLoadWait = waiting ? 1 : 0;
    g_ui.mtx.unlock();
    PostMessageW(g_ui.hwnd, WM_APP_SYNC, 0, 0);
}

/// Задаёт цвет иконки трея и текст плавающего HUD-индикатора.
void uiSetVisual(VisualState state, string hudText = null, int autoHideMs = 0) {
    if (g_ui.mtx is null || g_ui.hwnd is null) return;
    g_ui.mtx.lock();
    g_ui.pendingVisualState = cast(int) state;
    g_ui.pendingHudText = hudText;
    g_ui.hasPendingHudText = true;
    g_ui.pendingHudHideMs = autoHideMs;
    g_ui.mtx.unlock();
    PostMessageW(g_ui.hwnd, WM_APP_SYNC, 0, 0);
}

/// Управляет прогресс-баром: mode 0 = сброс, 1 = бегущая полоса, 2 = проценты (0..100).
void uiSetProgress(int mode, int pct = 0) nothrow {
    try {
        if (g_ui.mtx is null || g_ui.hwnd is null) return;
        g_ui.mtx.lock();
        g_ui.pendingProgressMode = mode;
        g_ui.pendingProgressPct = pct;
        g_ui.mtx.unlock();
        PostMessageW(g_ui.hwnd, WM_APP_SYNC, 0, 0);
    } catch (Throwable) {
    }
}

void uiLog(string line) {
    if (g_ui.mtx is null || g_ui.hwnd is null) return;
    g_ui.mtx.lock();
    g_ui.pendingLogs ~= line;
    g_ui.mtx.unlock();
    PostMessageW(g_ui.hwnd, WM_APP_SYNC, 0, 0);
}

bool runTrayApp(
    uint hotkeyVk,
    string hotkeyName,
    bool blockHotkey,
    bool toggleMode,
    string[] micNames,
    int initialMic,
    UiOption[] modelOptions,
    string initialModel,
    UiOption[] langOptions,
    string initialLang,
    string initialInputMode,
    bool startMinimized,
    bool autoLoad,
    bool cpuOnly,
    bool winAutostart,
    bool showOverlay,
    bool beepEnabled,
    bool livePreview,
    int initialTimeoutMin,
    bool initialLoaded,
    bool initialLoading,
    string[] initialLogs,
    void delegate() onStart,
    void delegate() onStop,
    void delegate() onCancel,
    void delegate(int) onMicChange,
    void delegate(string) onModelSelect,
    void delegate(string) onLangChange,
    string delegate(uint) onHotkeyChange,
    void delegate() onModelToggle,
    void delegate(int) onTimeoutChange,
    void delegate(string) onInputModeChange,
    void delegate(bool) onToggleModeChange,
    void delegate(bool) onAutoLoadChange,
    void delegate(bool) onCpuOnlyChange,
    void delegate(bool) onBeepChange,
    void delegate(bool) onOverlayChange,
    void delegate(bool) onLivePreviewChange,
    void delegate(bool) onStartTrayChange,
    void delegate(bool) onWinAutoChange,
    void delegate() onIdleTick,
    void delegate() onPreviewTick
) {
    INITCOMMONCONTROLSEX icc;
    icc.dwSize = INITCOMMONCONTROLSEX.sizeof;
    icc.dwICC = ICC_PROGRESS_CLASS | ICC_STANDARD_CLASSES;
    InitCommonControlsEx(&icc);

    g_ui.mtx = new Mutex();
    g_ui.hotkeyVk = hotkeyVk;
    g_ui.hotkeyName = hotkeyName;
    g_ui.blockHotkey = blockHotkey;
    g_ui.toggleMode = toggleMode;
    g_ui.isDown = false;
    g_ui.keyPhysicallyDown = false;
    g_ui.waitRelease = false;
    g_ui.capturingHotkey = false;
    g_ui.modelLoaded = initialLoaded;
    g_ui.modelLoading = initialLoading;
    g_ui.micNames = micNames;
    g_ui.currentMic = initialMic;
    g_ui.modelOptions = modelOptions;
    g_ui.currentModel = initialModel;
    g_ui.langOptions = langOptions;
    g_ui.currentLang = initialLang;
    g_ui.currentTimeoutMin = initialTimeoutMin;
    g_ui.currentInputMode = initialInputMode.length ? initialInputMode : "sendinput";
    g_ui.cpuOnly = cpuOnly;
    g_ui.beepEnabled = beepEnabled;
    g_ui.livePreview = livePreview;
    g_ui.winAutostart = winAutostart;
    g_ui.showOverlay = showOverlay;

    g_ui.onStart = onStart;
    g_ui.onStop = onStop;
    g_ui.onCancel = onCancel;
    g_ui.onMicChange = onMicChange;
    g_ui.onModelSelect = onModelSelect;
    g_ui.onLangChange = onLangChange;
    g_ui.onHotkeyChange = onHotkeyChange;
    g_ui.onModelToggle = onModelToggle;
    g_ui.onTimeoutChange = onTimeoutChange;
    g_ui.onInputModeChange = onInputModeChange;
    g_ui.onToggleModeChange = onToggleModeChange;
    g_ui.onAutoLoadChange = onAutoLoadChange;
    g_ui.onCpuOnlyChange = onCpuOnlyChange;
    g_ui.onBeepChange = onBeepChange;
    g_ui.onOverlayChange = onOverlayChange;
    g_ui.onLivePreviewChange = onLivePreviewChange;
    g_ui.onStartTrayChange = onStartTrayChange;
    g_ui.onWinAutoChange = onWinAutoChange;
    g_ui.onIdleTick = onIdleTick;
    g_ui.onPreviewTick = onPreviewTick;

    auto hInst = GetModuleHandleW(null);
    auto clsName = "ShepotWindowClass"w.ptr;

    g_ui.iconBig = cast(HICON) LoadImageW(hInst, cast(const(wchar)*) 1, IMAGE_ICON, 32, 32, 0);
    g_ui.iconSmall = cast(HICON) LoadImageW(hInst, cast(const(wchar)*) 1, IMAGE_ICON, 16, 16, 0);
    if (g_ui.iconBig is null) g_ui.iconBig = LoadIconW(null, IDI_APPLICATION);
    if (g_ui.iconSmall is null) g_ui.iconSmall = LoadIconW(null, IDI_APPLICATION);
    g_ui.iconRec = createMicIcon(16, 239, 68, 68, 194, 38, 38);
    g_ui.iconProc = createMicIcon(16, 245, 158, 11, 217, 119, 6);
    g_ui.iconPasted = createMicIcon(16, 16, 185, 129, 4, 120, 87);

    WNDCLASSEXW wc;
    wc.cbSize = WNDCLASSEXW.sizeof;
    wc.lpfnWndProc = &windowProc;
    wc.hInstance = hInst;
    wc.hIcon = g_ui.iconBig;
    wc.hIconSm = g_ui.iconSmall;
    wc.hCursor = LoadCursorW(null, IDC_ARROW);
    wc.hbrBackground = cast(HBRUSH)(COLOR_BTNFACE + 1);
    wc.lpszClassName = clsName;
    if (!RegisterClassExW(&wc)) return false;

    WNDCLASSEXW hudWc;
    hudWc.cbSize = WNDCLASSEXW.sizeof;
    hudWc.lpfnWndProc = &hudWindowProc;
    hudWc.hInstance = hInst;
    hudWc.hCursor = LoadCursorW(null, IDC_ARROW);
    hudWc.lpszClassName = "ShepotHudClass"w.ptr;
    RegisterClassExW(&hudWc);

    DWORD style = WS_OVERLAPPED | WS_CAPTION | WS_SYSMENU | WS_MINIMIZEBOX | WS_THICKFRAME | WS_CLIPCHILDREN;
    g_ui.hwnd = CreateWindowExW(
        0,
        clsName,
        "Shepot — Голосовой ввод"w.ptr,
        style,
        CW_USEDEFAULT, CW_USEDEFAULT, 600, 655,
        null, null, hInst, null
    );
    if (g_ui.hwnd is null) return false;

    SendMessageW(g_ui.hwnd, WM_SETICON, ICON_BIG, cast(LPARAM) g_ui.iconBig);
    SendMessageW(g_ui.hwnd, WM_SETICON, ICON_SMALL, cast(LPARAM) g_ui.iconSmall);

    createHudOverlay(hInst);

    populateMicCombo(micNames, initialMic);
    populateOptionCombo(g_ui.comboModel, modelOptions, initialModel);
    populateOptionCombo(g_ui.comboLang, langOptions, initialLang);
    populateTimeoutCombo(initialTimeoutMin);
    populateOptionCombo(g_ui.comboInputMode, cast(UiOption[]) inputModeOptions, g_ui.currentInputMode);

    SendMessageW(g_ui.chkAutoLoad, BM_SETCHECK, autoLoad ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkCpuOnly, BM_SETCHECK, cpuOnly ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkStartTray, BM_SETCHECK, startMinimized ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkWinAuto, BM_SETCHECK, winAutostart ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkLivePreview, BM_SETCHECK, livePreview ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkOverlay, BM_SETCHECK, showOverlay ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkToggleMode, BM_SETCHECK, toggleMode ? BST_CHECKED : BST_UNCHECKED, 0);
    SetWindowTextW(g_ui.btnHotkey, ("Назначить: [" ~ hotkeyName ~ "]").toUTF16z());
    applyModelButtonState(initialLoaded, initialLoading);

    foreach (line; initialLogs) uiLog(line);
    if (initialLoading) {
        uiSetStatus("Загрузка модели...");
        uiSetProgress(1, 0);
    } else {
        uiSetIdleStatus(initialLoaded);
    }

    if (!startMinimized) {
        ShowWindow(g_ui.hwnd, SW_SHOW);
        UpdateWindow(g_ui.hwnd);
    }

    g_ui.kbdHook = SetWindowsHookExW(WH_KEYBOARD_LL, &lowLevelKeyboardProc, hInst, 0);
    g_ui.mouseHook = SetWindowsHookExW(WH_MOUSE_LL, &lowLevelMouseProc, hInst, 0);
    if (g_ui.kbdHook is null || g_ui.mouseHook is null) {
        DestroyWindow(g_ui.hwnd);
        return false;
    }

    MSG msg;
    while (GetMessageW(&msg, null, 0, 0) > 0) {
        TranslateMessage(&msg);
        DispatchMessageW(&msg);
    }

    if (g_ui.kbdHook !is null) UnhookWindowsHookEx(g_ui.kbdHook);
    if (g_ui.mouseHook !is null) UnhookWindowsHookEx(g_ui.mouseHook);
    g_ui.kbdHook = null;
    g_ui.mouseHook = null;
    return true;
}

private HICON createMicIcon(int size, ubyte topR, ubyte topG, ubyte topB, ubyte botR, ubyte botG, ubyte botB) {
    BITMAPV5HEADER bi;
    bi.bV5Size = BITMAPV5HEADER.sizeof;
    bi.bV5Width = size;
    bi.bV5Height = -size;
    bi.bV5Planes = 1;
    bi.bV5BitCount = 32;
    bi.bV5Compression = BI_BITFIELDS;
    bi.bV5RedMask = 0x00FF0000;
    bi.bV5GreenMask = 0x0000FF00;
    bi.bV5BlueMask = 0x000000FF;
    bi.bV5AlphaMask = 0xFF000000;

    void* bits = null;
    HDC hdc = GetDC(null);
    HBITMAP hColor = CreateDIBSection(hdc, cast(const(BITMAPINFO)*) &bi, DIB_RGB_COLORS, &bits, null, 0);
    ReleaseDC(null, hdc);
    if (hColor is null || bits is null) return LoadIconW(null, IDI_APPLICATION);

    auto pixels = cast(uint*) bits;
    double half = size * 0.5, pad = size * 0.06, r = size * 0.24, boxHalf = half - pad - r;

    foreach (py; 0 .. size) {
        double ny = (py + 0.5) / size;
        double dy = (py + 0.5) - half;
        foreach (px; 0 .. size) {
            double nx = (px + 0.5) / size;
            double dx = (px + 0.5) - half;
            double qx = fabs(dx) - boxHalf, qy = fabs(dy) - boxHalf;
            double distBadge = sqrt(max(qx, 0.0) ^^ 2 + max(qy, 0.0) ^^ 2) + min(max(qx, qy), 0.0) - r;
            double badgeAlpha = clamp01(0.5 - distBadge);

            double bgR = topR + (cast(double) botR - topR) * ny;
            double bgG = topG + (cast(double) botG - topG) * ny;
            double bgB = topB + (cast(double) botB - topB) * ny;

            double cx = nx - 0.5;
            double capDist = sdCapsule(nx, ny, 0.5, 0.29, 0.5, 0.47, 0.115);
            double ringR = sqrt(cx * cx + (ny - 0.46) ^^ 2);
            double arcDist = (ny >= 0.44) ? fabs(ringR - 0.195) - 0.032 : 1.0;
            double stemDist = sdCapsule(nx, ny, 0.5, 0.655, 0.5, 0.77, 0.032);
            double baseDist = sdCapsule(nx, ny, 0.37, 0.77, 0.63, 0.77, 0.032);
            double micAlpha = clamp01(0.5 - min(min(capDist, arcDist), min(stemDist, baseDist)) * size);

            double outR = bgR * (1.0 - micAlpha) + 255.0 * micAlpha;
            double outG = bgG * (1.0 - micAlpha) + 255.0 * micAlpha;
            double outB = bgB * (1.0 - micAlpha) + 255.0 * micAlpha;

            uint a = cast(uint)(badgeAlpha * 255.0 + 0.5);
            uint cr = cast(uint)(outR * badgeAlpha + 0.5);
            uint cg = cast(uint)(outG * badgeAlpha + 0.5);
            uint cb = cast(uint)(outB * badgeAlpha + 0.5);
            pixels[py * size + px] = (a << 24) | (cr << 16) | (cg << 8) | cb;
        }
    }

    HBITMAP hMask = CreateBitmap(size, size, 1, 1, null);
    ICONINFO ii;
    ii.fIcon = TRUE;
    ii.hbmMask = hMask;
    ii.hbmColor = hColor;
    HICON icon = CreateIconIndirect(&ii);

    DeleteObject(hMask);
    DeleteObject(hColor);
    return icon !is null ? icon : LoadIconW(null, IDI_APPLICATION);
}

private double sdCapsule(double px, double py, double ax, double ay, double bx, double by, double radius) {
    double pax = px - ax, pay = py - ay;
    double bax = bx - ax, bay = by - ay;
    double denom = bax * bax + bay * bay;
    double h = denom > 0 ? clamp01((pax * bax + pay * bay) / denom) : 0.0;
    return sqrt((pax - bax * h) ^^ 2 + (pay - bay * h) ^^ 2) - radius;
}

private double clamp01(double v) {
    return v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);
}

private void populateMicCombo(string[] micNames, int initialMic) {
    SendMessageW(g_ui.comboMic, CB_ADDSTRING, 0, cast(LPARAM) "По умолчанию (Windows)".toUTF16z());
    foreach (name; micNames) {
        SendMessageW(g_ui.comboMic, CB_ADDSTRING, 0, cast(LPARAM) name.toUTF16z());
    }
    int sel = (initialMic >= 0 && initialMic < cast(int) micNames.length) ? (initialMic + 1) : 0;
    SendMessageW(g_ui.comboMic, CB_SETCURSEL, sel, 0);
}

private void populateOptionCombo(HWND combo, UiOption[] options, string currentVal) {
    int sel = 0;
    foreach (i, opt; options) {
        SendMessageW(combo, CB_ADDSTRING, 0, cast(LPARAM) opt.label.toUTF16z());
        if (opt.value == currentVal) sel = cast(int) i;
    }
    SendMessageW(combo, CB_SETCURSEL, sel, 0);
}

private void populateTimeoutCombo(int minutes) {
    int sel = 2;
    foreach (i, opt; timeoutOptions) {
        SendMessageW(g_ui.comboTimeout, CB_ADDSTRING, 0, cast(LPARAM) opt.label.toUTF16z());
        if (opt.minutes == minutes) sel = cast(int) i;
    }
    SendMessageW(g_ui.comboTimeout, CB_SETCURSEL, sel, 0);
}

private void applyModelButtonState(bool loaded, bool loading) {
    g_ui.modelLoaded = loaded;
    g_ui.modelLoading = loading;
    if (loading) {
        SetWindowTextW(g_ui.btnModel, "Загрузка модели..."w.ptr);
        EnableWindow(g_ui.btnModel, FALSE);
    } else if (loaded) {
        SetWindowTextW(g_ui.btnModel, "Выгрузить модель из памяти"w.ptr);
        EnableWindow(g_ui.btnModel, TRUE);
    } else {
        SetWindowTextW(g_ui.btnModel, "Загрузить модель"w.ptr);
        EnableWindow(g_ui.btnModel, TRUE);
    }
}

private void applyProgressState(int mode, int pct) {
    if (g_ui.progressBar is null) return;
    if (mode == 1) {
        if (!g_ui.marqueeActive) {
            auto st = GetWindowLongW(g_ui.progressBar, GWL_STYLE);
            SetWindowLongW(g_ui.progressBar, GWL_STYLE, st | PBS_MARQUEE);
            SendMessageW(g_ui.progressBar, PBM_SETMARQUEE, TRUE, 30);
            g_ui.marqueeActive = true;
        }
    } else {
        if (g_ui.marqueeActive) {
            SendMessageW(g_ui.progressBar, PBM_SETMARQUEE, FALSE, 0);
            auto st = GetWindowLongW(g_ui.progressBar, GWL_STYLE);
            SetWindowLongW(g_ui.progressBar, GWL_STYLE, st & ~PBS_MARQUEE);
            g_ui.marqueeActive = false;
        }
        int clamped = pct < 0 ? 0 : (pct > 100 ? 100 : pct);
        SendMessageW(g_ui.progressBar, PBM_SETPOS, mode == 2 ? clamped : 0, 0);
    }
}

private void layoutChildren(int w, int h) {
    if (g_ui.lblStatus is null) return;
    int pad = 14;
    int hideW = 128;
    int labelW = 152;
    int ctrlW = w - pad * 2 - labelW - 8;

    int y = pad;
    MoveWindow(g_ui.lblStatus, pad, y + 3, w - pad * 3 - hideW, 24, TRUE);
    MoveWindow(g_ui.btnHide, w - pad - hideW, y, hideW, 28, TRUE);

    y += 36;
    MoveWindow(g_ui.btnModel, pad, y, w - pad * 2, 36, TRUE);

    y += 40;
    MoveWindow(g_ui.progressBar, pad, y, w - pad * 2, 12, TRUE);

    y += 20;
    MoveWindow(g_ui.lblMic, pad, y + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboMic, pad + labelW + 8, y, ctrlW, 220, TRUE);

    y += 32;
    MoveWindow(g_ui.lblModel, pad, y + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboModel, pad + labelW + 8, y, ctrlW, 220, TRUE);

    y += 32;
    MoveWindow(g_ui.lblLang, pad, y + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboLang, pad + labelW + 8, y, ctrlW, 220, TRUE);

    y += 32;
    MoveWindow(g_ui.lblHotkey, pad, y + 5, labelW, 20, TRUE);
    MoveWindow(g_ui.btnHotkey, pad + labelW + 8, y, ctrlW, 28, TRUE);

    y += 34;
    MoveWindow(g_ui.lblTimeout, pad, y + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboTimeout, pad + labelW + 8, y, ctrlW, 220, TRUE);

    y += 32;
    MoveWindow(g_ui.lblInputMode, pad, y + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboInputMode, pad + labelW + 8, y, ctrlW, 220, TRUE);

    y += 32;
    int halfW = (w - pad * 3) / 2;
    MoveWindow(g_ui.chkAutoLoad, pad, y, halfW, 22, TRUE);
    MoveWindow(g_ui.chkCpuOnly, pad * 2 + halfW, y, halfW, 22, TRUE);

    y += 24;
    MoveWindow(g_ui.chkStartTray, pad, y, halfW, 22, TRUE);
    MoveWindow(g_ui.chkWinAuto, pad * 2 + halfW, y, halfW, 22, TRUE);

    y += 24;
    MoveWindow(g_ui.chkLivePreview, pad, y, halfW, 22, TRUE);
    MoveWindow(g_ui.chkOverlay, pad * 2 + halfW, y, halfW, 22, TRUE);

    y += 24;
    MoveWindow(g_ui.chkToggleMode, pad, y, halfW, 22, TRUE);

    y += 28;
    MoveWindow(g_ui.lblLog, pad, y, w - pad * 2, 18, TRUE);

    y += 22;
    int logH = h - y - pad;
    if (logH < 60) logH = 60;
    MoveWindow(g_ui.editLog, pad, y, w - pad * 2, logH, TRUE);
}

private void addTrayIcon(HWND hwnd) {
    g_ui.nid.cbSize = NOTIFYICONDATAW.sizeof;
    g_ui.nid.hWnd = hwnd;
    g_ui.nid.uID = 1;
    g_ui.nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_ui.nid.uCallbackMessage = WM_APP_TRAY;
    g_ui.nid.hIcon = g_ui.iconSmall;
    setTrayTip("Shepot");
    Shell_NotifyIconW(NIM_ADD, &g_ui.nid);
}

private void setTrayTip(string tip) {
    auto w = toUTF16(tip);
    size_t maxLen = g_ui.nid.szTip.length - 1;
    size_t n = w.length < maxLen ? w.length : maxLen;
    if (n > 0) memcpy(g_ui.nid.szTip.ptr, w.ptr, n * wchar.sizeof);
    g_ui.nid.szTip[n] = 0;
}

private void toggleWindowVisibility(HWND hwnd) {
    if (IsWindowVisible(hwnd)) {
        ShowWindow(hwnd, SW_HIDE);
    } else {
        ShowWindow(hwnd, SW_RESTORE);
        SetForegroundWindow(hwnd);
    }
}

private void showTrayMenu(HWND hwnd) {
    POINT pt;
    GetCursorPos(&pt);

    HMENU menu = CreatePopupMenu();
    auto toggleText = IsWindowVisible(hwnd) ? "Скрыть в трей"w.ptr : "Показать окно"w.ptr;
    AppendMenuW(menu, MF_STRING, ID_TRAY_TOGGLE, toggleText);
    UINT copyFlags = MF_STRING | (g_ui.lastPhrase.length > 0 ? 0 : MF_GRAYED);
    AppendMenuW(menu, copyFlags, ID_TRAY_COPY_LAST, "Скопировать последнюю фразу"w.ptr);
    AppendMenuW(menu, MF_SEPARATOR, 0, null);

    string modelBtnLabel = g_ui.modelLoading
        ? "Загрузка модели..."
        : (g_ui.modelLoaded ? "Выгрузить модель из памяти" : "Загрузить модель");
    UINT modelFlags = MF_STRING | (g_ui.modelLoading ? MF_GRAYED : 0);
    AppendMenuW(menu, modelFlags, ID_TRAY_MODEL_TOGGLE, modelBtnLabel.toUTF16z());

    // Подменю моделей
    HMENU subModel = CreatePopupMenu();
    foreach (i, opt; g_ui.modelOptions) {
        UINT fl = MF_STRING | (opt.value == g_ui.currentModel ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subModel, fl, ID_TRAY_MODEL_BASE + i, opt.label.toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subModel, "Модель"w.ptr);

    // Подменю языков
    HMENU subLang = CreatePopupMenu();
    foreach (i, opt; g_ui.langOptions) {
        UINT fl = MF_STRING | (opt.value == g_ui.currentLang ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subLang, fl, ID_TRAY_LANG_BASE + i, opt.label.toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subLang, "Язык речи"w.ptr);

    // Подменю микрофонов
    HMENU subMic = CreatePopupMenu();
    AppendMenuW(subMic, MF_STRING | (g_ui.currentMic < 0 ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_MIC_BASE, "По умолчанию (Windows)"w.ptr);
    foreach (i, name; g_ui.micNames) {
        UINT fl = MF_STRING | (g_ui.currentMic == cast(int) i ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subMic, fl, ID_TRAY_MIC_BASE + 1 + i, name.toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subMic, "Микрофон"w.ptr);

    // Подменю автовыгрузки
    HMENU subTimeout = CreatePopupMenu();
    foreach (i, opt; timeoutOptions) {
        UINT fl = MF_STRING | (opt.minutes == g_ui.currentTimeoutMin ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subTimeout, fl, ID_TRAY_TIMEOUT_BASE + i, opt.label.toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subTimeout, "Автовыгрузка (VRAM)"w.ptr);

    // Подменю режима ввода
    HMENU subInputMode = CreatePopupMenu();
    foreach (i, opt; inputModeOptions) {
        UINT fl = MF_STRING | (opt.value == g_ui.currentInputMode ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subInputMode, fl, ID_TRAY_INPUT_MODE_BASE + i, opt.label.toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subInputMode, "Режим ввода"w.ptr);

    AppendMenuW(menu, MF_STRING, ID_TRAY_HOTKEY,
        ("Назначить клавишу [" ~ g_ui.hotkeyName ~ "]").toUTF16z());
    AppendMenuW(menu, MF_STRING | (g_ui.toggleMode ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_TOGGLE_MODE, "Режим переключения (Toggle)"w.ptr);

    AppendMenuW(menu, MF_SEPARATOR, 0, null);
    AppendMenuW(menu, MF_STRING | (g_ui.cpuOnly ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_CPU_ONLY, "Только на процессоре (CPU)"w.ptr);
    AppendMenuW(menu, MF_STRING | (g_ui.beepEnabled ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_BEEP, "Звуковые сигналы"w.ptr);
    AppendMenuW(menu, MF_STRING | (g_ui.showOverlay ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_OVERLAY, "Плавающий индикатор (HUD)"w.ptr);
    AppendMenuW(menu, MF_STRING | (g_ui.livePreview ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_LIVE_PREVIEW, "Предпросмотр речи в HUD (Live)"w.ptr);
    AppendMenuW(menu, MF_STRING | (g_ui.winAutostart ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_WIN_AUTO, "Запускать с Windows"w.ptr);

    AppendMenuW(menu, MF_SEPARATOR, 0, null);
    AppendMenuW(menu, MF_STRING, ID_TRAY_EXIT, "Выход"w.ptr);

    SetForegroundWindow(hwnd);
    TrackPopupMenu(menu, TPM_BOTTOMALIGN | TPM_LEFTALIGN, pt.x, pt.y, 0, hwnd, null);
    DestroyMenu(menu);
}

private void createHudOverlay(HANDLE hInst) {
    enum int HudW = 440;
    enum int HudH = 38;
    RECT wa;
    SystemParametersInfoW(SPI_GETWORKAREA, 0, &wa, 0);
    int x = wa.left + (wa.right - wa.left - HudW) / 2;
    int y = wa.bottom - HudH - 14;

    DWORD exStyle = WS_EX_TOPMOST | WS_EX_TOOLWINDOW | WS_EX_NOACTIVATE | WS_EX_LAYERED | WS_EX_TRANSPARENT;
    g_ui.hudWnd = CreateWindowExW(
        exStyle,
        "ShepotHudClass"w.ptr,
        ""w.ptr,
        WS_POPUP,
        x, y, HudW, HudH,
        null, null, hInst, null
    );
    if (g_ui.hudWnd !is null) {
        SetLayeredWindowAttributes(g_ui.hudWnd, 0, 232, LWA_ALPHA);
        HRGN rgn = CreateRoundRectRgn(0, 0, HudW + 1, HudH + 1, 18, 18);
        SetWindowRgn(g_ui.hudWnd, rgn, TRUE);
    }
}

private extern (Windows) LRESULT hudWindowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow {
    if (msg == WM_PAINT) {
        try {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hwnd, &ps);
            RECT rc;
            GetClientRect(hwnd, &rc);

            HBRUSH bgBrush = CreateSolidBrush(RGB(24, 30, 44));
            FillRect(hdc, &rc, bgBrush);
            DeleteObject(bgBrush);

            COLORREF dotColor;
            final switch (g_ui.hudState) {
                case VisualState.idle:       dotColor = RGB(148, 163, 184); break;
                case VisualState.recording:  dotColor = RGB(239, 68, 68); break;
                case VisualState.processing: dotColor = RGB(245, 158, 11); break;
                case VisualState.pasted:     dotColor = RGB(16, 185, 129); break;
            }
            HBRUSH dotBrush = CreateSolidBrush(dotColor);
            auto oldBrush = SelectObject(hdc, dotBrush);
            auto nullPen = CreatePen(PS_NULL, 0, 0);
            auto oldPen = SelectObject(hdc, nullPen);
            Ellipse(hdc, 13, 13, 25, 25);
            SelectObject(hdc, oldPen);
            SelectObject(hdc, oldBrush);
            DeleteObject(nullPen);
            DeleteObject(dotBrush);

            SetBkMode(hdc, TRANSPARENT);
            SetTextColor(hdc, RGB(248, 250, 252));
            auto oldFont = SelectObject(hdc, g_ui.fontUi);
            RECT tr = RECT(34, 0, rc.right - 12, rc.bottom);
            auto wtxt = g_ui.hudText.toUTF16();
            DrawTextW(hdc, wtxt.ptr, cast(int) wtxt.length, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
            SelectObject(hdc, oldFont);

            EndPaint(hwnd, &ps);
            return 0;
        } catch (Throwable) {
        }
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

private void flushPendingUi(HWND hwnd) {
    string status;
    bool hasStatus;
    int visState;
    string hudText;
    bool hasHudText;
    int hudHideMs;
    int modelState;
    int loadWait;
    int progMode;
    int progPct;
    string lastPhrase;
    bool hasLastPhrase;
    string[] logs;

    g_ui.mtx.lock();
    if (g_ui.hasPendingStatus) {
        status = g_ui.pendingStatus;
        g_ui.hasPendingStatus = false;
        hasStatus = true;
    }
    visState = g_ui.pendingVisualState;
    g_ui.pendingVisualState = -1;
    hudText = g_ui.pendingHudText;
    hasHudText = g_ui.hasPendingHudText;
    g_ui.hasPendingHudText = false;
    hudHideMs = g_ui.pendingHudHideMs;
    g_ui.pendingHudHideMs = -1;
    modelState = g_ui.pendingModelState;
    g_ui.pendingModelState = -1;
    loadWait = g_ui.pendingLoadWait;
    g_ui.pendingLoadWait = -1;
    progMode = g_ui.pendingProgressMode;
    progPct = g_ui.pendingProgressPct;
    g_ui.pendingProgressMode = -1;
    if (g_ui.hasPendingLastPhrase) {
        lastPhrase = g_ui.pendingLastPhrase;
        g_ui.hasPendingLastPhrase = false;
        hasLastPhrase = true;
    }
    if (g_ui.pendingLogs.length > 0) {
        logs = g_ui.pendingLogs;
        g_ui.pendingLogs = null;
    }
    g_ui.mtx.unlock();

    if (hasLastPhrase) {
        g_ui.lastPhrase = lastPhrase;
    }

    if (modelState >= 0) {
        applyModelButtonState(modelState == 1, modelState == 2);
    }
    if (progMode >= 0) {
        applyProgressState(progMode, progPct);
        if (progMode == 2 && g_ui.hudState == VisualState.processing && g_ui.hudWnd !is null && g_ui.showOverlay) {
            g_ui.hudText = format("Обработка голоса... %s%%", progPct);
            InvalidateRect(g_ui.hudWnd, null, TRUE);
        }
    }

    if (loadWait == 1 && !g_ui.clickTimerActive) {
        g_ui.clickTimerActive = true;
        SetTimer(hwnd, ID_TIMER_CLICK, 1000, null);
    } else if (loadWait == 0 && g_ui.clickTimerActive) {
        g_ui.clickTimerActive = false;
        KillTimer(hwnd, ID_TIMER_CLICK);
    }

    bool modifyTray = false;
    if (hasStatus) {
        SetWindowTextW(g_ui.lblStatus, status.toUTF16z());
        setTrayTip("Shepot — " ~ status);
        modifyTray = true;
    }
    if (visState >= 0) {
        g_ui.hudState = cast(VisualState) visState;
        final switch (g_ui.hudState) {
            case VisualState.idle:       g_ui.nid.hIcon = g_ui.iconSmall; break;
            case VisualState.recording:  g_ui.nid.hIcon = g_ui.iconRec; break;
            case VisualState.processing: g_ui.nid.hIcon = g_ui.iconProc; break;
            case VisualState.pasted:     g_ui.nid.hIcon = g_ui.iconPasted; break;
        }
        modifyTray = true;

        KillTimer(hwnd, ID_TIMER_HUD_HIDE);
        if (hudHideMs > 0) {
            SetTimer(hwnd, ID_TIMER_HUD_HIDE, hudHideMs, null);
        }

        if (g_ui.hudWnd !is null && g_ui.showOverlay) {
            if (hasHudText) g_ui.hudText = hudText;
            if (g_ui.hudText.length > 0) {
                InvalidateRect(g_ui.hudWnd, null, TRUE);
                ShowWindow(g_ui.hudWnd, SW_SHOWNOACTIVATE);
            } else {
                ShowWindow(g_ui.hudWnd, SW_HIDE);
            }
        }
    }
    if (modifyTray) {
        Shell_NotifyIconW(NIM_MODIFY, &g_ui.nid);
    }

    foreach (line; logs) {
        auto wline = (line ~ "\r\n").toUTF16z();
        int len = GetWindowTextLengthW(g_ui.editLog);
        SendMessageW(g_ui.editLog, EM_SETSEL, len, len);
        SendMessageW(g_ui.editLog, EM_REPLACESEL, 0, cast(LPARAM) wline);
    }
}

private HFONT makeFont(string face, int height, int weight) {
    enum BYTE CLEARTYPE_QUALITY = 5;
    return CreateFontW(height, 0, 0, 0, weight, 0, 0, 0, DEFAULT_CHARSET,
        OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS, CLEARTYPE_QUALITY,
        DEFAULT_PITCH | FF_DONTCARE, face.toUTF16z());
}

private void applyMicSelection(int devId) {
    g_ui.currentMic = devId;
    int comboIdx = devId < 0 ? 0 : (devId + 1);
    SendMessageW(g_ui.comboMic, CB_SETCURSEL, comboIdx, 0);
    if (g_ui.onMicChange !is null) g_ui.onMicChange(devId);
}

private void applyModelSelection(int idx) {
    if (idx < 0 || idx >= cast(int) g_ui.modelOptions.length) return;
    g_ui.currentModel = g_ui.modelOptions[idx].value;
    SendMessageW(g_ui.comboModel, CB_SETCURSEL, idx, 0);
    if (g_ui.onModelSelect !is null) g_ui.onModelSelect(g_ui.currentModel);
}

private void applyLangSelection(int idx) {
    if (idx < 0 || idx >= cast(int) g_ui.langOptions.length) return;
    g_ui.currentLang = g_ui.langOptions[idx].value;
    SendMessageW(g_ui.comboLang, CB_SETCURSEL, idx, 0);
    if (g_ui.onLangChange !is null) g_ui.onLangChange(g_ui.currentLang);
}

private void applyTimeoutSelection(int idx) {
    if (idx < 0 || idx >= cast(int) timeoutOptions.length) return;
    g_ui.currentTimeoutMin = timeoutOptions[idx].minutes;
    SendMessageW(g_ui.comboTimeout, CB_SETCURSEL, idx, 0);
    if (g_ui.onTimeoutChange !is null) g_ui.onTimeoutChange(g_ui.currentTimeoutMin);
}

private void applyInputModeSelection(int idx) {
    if (idx < 0 || idx >= cast(int) inputModeOptions.length) return;
    g_ui.currentInputMode = inputModeOptions[idx].value;
    SendMessageW(g_ui.comboInputMode, CB_SETCURSEL, idx, 0);
    if (g_ui.onInputModeChange !is null) g_ui.onInputModeChange(g_ui.currentInputMode);
}

private void applyCpuOnly(bool checked) {
    g_ui.cpuOnly = checked;
    SendMessageW(g_ui.chkCpuOnly, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
    if (g_ui.onCpuOnlyChange !is null) g_ui.onCpuOnlyChange(checked);
}

private void applyWinAuto(bool checked) {
    g_ui.winAutostart = checked;
    SendMessageW(g_ui.chkWinAuto, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
    if (g_ui.onWinAutoChange !is null) g_ui.onWinAutoChange(checked);
}

private void applyLivePreview(bool checked) {
    g_ui.livePreview = checked;
    SendMessageW(g_ui.chkLivePreview, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
    if (g_ui.onLivePreviewChange !is null) g_ui.onLivePreviewChange(checked);
}

private void applyOverlay(bool checked) {
    g_ui.showOverlay = checked;
    SendMessageW(g_ui.chkOverlay, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
    if (!checked && g_ui.hudWnd !is null) ShowWindow(g_ui.hudWnd, SW_HIDE);
    if (g_ui.onOverlayChange !is null) g_ui.onOverlayChange(checked);
}

private void applyToggleMode(bool checked) {
    g_ui.toggleMode = checked;
    SendMessageW(g_ui.chkToggleMode, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
    if (g_ui.onToggleModeChange !is null) g_ui.onToggleModeChange(checked);
    if (!g_ui.isDown && !g_ui.modelLoading) uiSetIdleStatus(g_ui.modelLoaded);
}

private extern (Windows) LRESULT windowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow {
    try {
        switch (msg) {
            case WM_CREATE:
                auto hInst = GetModuleHandleW(null);
                g_ui.fontTitle = makeFont("Segoe UI", -17, FW_SEMIBOLD);
                g_ui.fontBtnBold = makeFont("Segoe UI", -15, FW_SEMIBOLD);
                g_ui.fontUi = makeFont("Segoe UI", -14, FW_NORMAL);
                g_ui.fontMono = makeFont("Consolas", -13, FW_NORMAL);

                g_ui.lblStatus = CreateWindowExW(0, "STATIC"w.ptr, "Инициализация..."w.ptr,
                    WS_CHILD | WS_VISIBLE | SS_ENDELLIPSIS, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.btnHide = CreateWindowExW(0, "BUTTON"w.ptr, "Скрыть в трей"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_HIDE, hInst, null);
                g_ui.btnModel = CreateWindowExW(0, "BUTTON"w.ptr, "Загрузить модель"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_MODEL, hInst, null);
                g_ui.progressBar = CreateWindowExW(0, PROGRESS_CLASS.toUTF16z(), ""w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_PROGRESS, hInst, null);
                SendMessageW(g_ui.progressBar, PBM_SETRANGE, 0, 100 << 16);

                g_ui.lblMic = CreateWindowExW(0, "STATIC"w.ptr, "Микрофон:"w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboMic = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_MIC, hInst, null);

                g_ui.lblModel = CreateWindowExW(0, "STATIC"w.ptr, "Модель:"w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboModel = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_MODEL, hInst, null);

                g_ui.lblLang = CreateWindowExW(0, "STATIC"w.ptr, "Язык речи:"w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboLang = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_LANG, hInst, null);

                g_ui.lblHotkey = CreateWindowExW(0, "STATIC"w.ptr, "Клавиша активации:"w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.btnHotkey = CreateWindowExW(0, "BUTTON"w.ptr, "Назначить: [F9]"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_HOTKEY, hInst, null);

                g_ui.lblTimeout = CreateWindowExW(0, "STATIC"w.ptr, "Автовыгрузка (VRAM):"w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboTimeout = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_TIMEOUT, hInst, null);

                g_ui.lblInputMode = CreateWindowExW(0, "STATIC"w.ptr, "Режим ввода:"w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboInputMode = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_INPUT_MODE, hInst, null);

                g_ui.chkAutoLoad = CreateWindowExW(0, "BUTTON"w.ptr, "Автозагрузка модели"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_AUTOLOAD, hInst, null);
                g_ui.chkCpuOnly = CreateWindowExW(0, "BUTTON"w.ptr, "Только на процессоре (CPU)"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_CPU_ONLY, hInst, null);
                g_ui.chkStartTray = CreateWindowExW(0, "BUTTON"w.ptr, "Запускать в трее сразу"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_START_TRAY, hInst, null);
                g_ui.chkWinAuto = CreateWindowExW(0, "BUTTON"w.ptr, "Запускать с Windows"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_WIN_AUTO, hInst, null);
                g_ui.chkLivePreview = CreateWindowExW(0, "BUTTON"w.ptr, "Предпросмотр в HUD (Live)"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_LIVE_PREVIEW, hInst, null);
                g_ui.chkOverlay = CreateWindowExW(0, "BUTTON"w.ptr, "Плавающий индикатор (HUD)"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_OVERLAY, hInst, null);
                g_ui.chkToggleMode = CreateWindowExW(0, "BUTTON"w.ptr, "Режим переключения (Toggle)"w.ptr,
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_TOGGLE_MODE, hInst, null);

                g_ui.lblLog = CreateWindowExW(0, "STATIC"w.ptr, "Журнал работы:"w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.editLog = CreateWindowExW(WS_EX_CLIENTEDGE, "EDIT"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY,
                    0, 0, 0, 0, hwnd, cast(HMENU) cast(size_t) ID_EDIT_LOG, hInst, null);

                SendMessageW(g_ui.lblStatus, WM_SETFONT, cast(WPARAM) g_ui.fontTitle, TRUE);
                SendMessageW(g_ui.btnModel, WM_SETFONT, cast(WPARAM) g_ui.fontBtnBold, TRUE);
                foreach (ctrl; [
                    g_ui.btnHide, g_ui.lblMic, g_ui.comboMic, g_ui.lblModel, g_ui.comboModel,
                    g_ui.lblLang, g_ui.comboLang, g_ui.lblHotkey, g_ui.btnHotkey,
                    g_ui.lblTimeout, g_ui.comboTimeout, g_ui.lblInputMode, g_ui.comboInputMode,
                    g_ui.chkAutoLoad, g_ui.chkCpuOnly,
                    g_ui.chkStartTray, g_ui.chkWinAuto, g_ui.chkLivePreview, g_ui.chkOverlay,
                    g_ui.chkToggleMode, g_ui.lblLog
                ]) {
                    SendMessageW(ctrl, WM_SETFONT, cast(WPARAM) g_ui.fontUi, TRUE);
                }
                SendMessageW(g_ui.editLog, WM_SETFONT, cast(WPARAM) g_ui.fontMono, TRUE);

                RECT rc;
                GetClientRect(hwnd, &rc);
                layoutChildren(rc.right - rc.left, rc.bottom - rc.top);
                addTrayIcon(hwnd);
                SetTimer(hwnd, ID_TIMER_IDLE, 5000, null);
                SetTimer(hwnd, ID_TIMER_PREVIEW, 1100, null);
                return 0;

            case WM_CTLCOLORSTATIC:
                auto hdc = cast(HDC) wParam;
                if (cast(HWND) lParam == g_ui.editLog) {
                    SetBkColor(hdc, RGB(255, 255, 255));
                    return cast(LRESULT) GetSysColorBrush(COLOR_WINDOW);
                }
                SetBkMode(hdc, TRANSPARENT);
                if (cast(HWND) lParam == g_ui.lblStatus) {
                    SetTextColor(hdc, RGB(24, 34, 56));
                }
                return cast(LRESULT) GetSysColorBrush(COLOR_BTNFACE);

            case WM_GETMINMAXINFO:
                auto mmi = cast(MINMAXINFO*) lParam;
                mmi.ptMinTrackSize.x = 520;
                mmi.ptMinTrackSize.y = 570;
                return 0;

            case WM_SIZE:
                if (wParam == SIZE_MINIMIZED) {
                    ShowWindow(hwnd, SW_HIDE);
                    return 0;
                }
                layoutChildren(cast(int)(lParam & 0xFFFF), cast(int)((lParam >> 16) & 0xFFFF));
                return 0;

            case WM_TIMER:
                if (wParam == ID_TIMER_IDLE) {
                    if (g_ui.onIdleTick !is null) g_ui.onIdleTick();
                } else if (wParam == ID_TIMER_CLICK) {
                    if (g_ui.clickTimerActive) playClickAsync();
                } else if (wParam == ID_TIMER_HUD_HIDE) {
                    KillTimer(hwnd, ID_TIMER_HUD_HIDE);
                    if (g_ui.hudWnd !is null) ShowWindow(g_ui.hudWnd, SW_HIDE);
                    g_ui.hudState = VisualState.idle;
                    g_ui.nid.hIcon = g_ui.iconSmall;
                    Shell_NotifyIconW(NIM_MODIFY, &g_ui.nid);
                } else if (wParam == ID_TIMER_PREVIEW) {
                    if (g_ui.isDown && g_ui.livePreview && g_ui.modelLoaded && !g_ui.modelLoading && g_ui.onPreviewTick !is null) {
                        g_ui.onPreviewTick();
                    }
                }
                return 0;

            case WM_COMMAND:
                int id = cast(int)(wParam & 0xFFFF);
                int code = cast(int)((wParam >> 16) & 0xFFFF);
                if (id == ID_BTN_HIDE || id == ID_TRAY_TOGGLE) {
                    toggleWindowVisibility(hwnd);
                } else if (id == ID_BTN_MODEL || id == ID_TRAY_MODEL_TOGGLE) {
                    if (g_ui.onModelToggle !is null) g_ui.onModelToggle();
                } else if (id == ID_BTN_HOTKEY || id == ID_TRAY_HOTKEY) {
                    g_ui.capturingHotkey = true;
                    SetWindowTextW(g_ui.btnHotkey, "Нажмите клавишу или кнопку мыши (Esc — отмена)..."w.ptr);
                } else if (id == ID_TRAY_EXIT) {
                    Shell_NotifyIconW(NIM_DELETE, &g_ui.nid);
                    DestroyWindow(hwnd);
                } else if (id == ID_TRAY_CPU_ONLY) {
                    applyCpuOnly(!g_ui.cpuOnly);
                } else if (id == ID_TRAY_BEEP) {
                    g_ui.beepEnabled = !g_ui.beepEnabled;
                    if (g_ui.onBeepChange !is null) g_ui.onBeepChange(g_ui.beepEnabled);
                } else if (id == ID_TRAY_OVERLAY) {
                    applyOverlay(!g_ui.showOverlay);
                } else if (id == ID_TRAY_LIVE_PREVIEW) {
                    applyLivePreview(!g_ui.livePreview);
                } else if (id == ID_TRAY_TOGGLE_MODE) {
                    applyToggleMode(!g_ui.toggleMode);
                } else if (id == ID_TRAY_COPY_LAST) {
                    if (copyTextToClipboard(g_ui.lastPhrase)) {
                        uiLog("[CLIP] Скопирована последняя фраза: " ~ g_ui.lastPhrase);
                        uiSetVisual(VisualState.pasted, "Скопировано в буфер", 900);
                    }
                } else if (id == ID_TRAY_WIN_AUTO) {
                    applyWinAuto(!g_ui.winAutostart);
                } else if (id >= ID_TRAY_MIC_BASE && id < ID_TRAY_MODEL_BASE) {
                    int idx = id - ID_TRAY_MIC_BASE;
                    applyMicSelection(idx <= 0 ? -1 : idx - 1);
                } else if (id >= ID_TRAY_MODEL_BASE && id < ID_TRAY_LANG_BASE) {
                    applyModelSelection(id - ID_TRAY_MODEL_BASE);
                } else if (id >= ID_TRAY_LANG_BASE && id < ID_TRAY_TIMEOUT_BASE) {
                    applyLangSelection(id - ID_TRAY_LANG_BASE);
                } else if (id >= ID_TRAY_TIMEOUT_BASE && id < ID_TRAY_INPUT_MODE_BASE) {
                    applyTimeoutSelection(id - ID_TRAY_TIMEOUT_BASE);
                } else if (id >= ID_TRAY_INPUT_MODE_BASE && id < ID_TRAY_INPUT_MODE_BASE + 100) {
                    applyInputModeSelection(id - ID_TRAY_INPUT_MODE_BASE);
                } else if (id == ID_COMBO_MIC && code == CBN_SELCHANGE) {
                    int sel = cast(int) SendMessageW(g_ui.comboMic, CB_GETCURSEL, 0, 0);
                    applyMicSelection(sel <= 0 ? -1 : sel - 1);
                } else if (id == ID_COMBO_MODEL && code == CBN_SELCHANGE) {
                    applyModelSelection(cast(int) SendMessageW(g_ui.comboModel, CB_GETCURSEL, 0, 0));
                } else if (id == ID_COMBO_LANG && code == CBN_SELCHANGE) {
                    applyLangSelection(cast(int) SendMessageW(g_ui.comboLang, CB_GETCURSEL, 0, 0));
                } else if (id == ID_COMBO_TIMEOUT && code == CBN_SELCHANGE) {
                    applyTimeoutSelection(cast(int) SendMessageW(g_ui.comboTimeout, CB_GETCURSEL, 0, 0));
                } else if (id == ID_COMBO_INPUT_MODE && code == CBN_SELCHANGE) {
                    applyInputModeSelection(cast(int) SendMessageW(g_ui.comboInputMode, CB_GETCURSEL, 0, 0));
                } else if (id == ID_CHK_AUTOLOAD) {
                    bool checked = SendMessageW(g_ui.chkAutoLoad, BM_GETCHECK, 0, 0) == BST_CHECKED;
                    if (g_ui.onAutoLoadChange !is null) g_ui.onAutoLoadChange(checked);
                } else if (id == ID_CHK_CPU_ONLY) {
                    applyCpuOnly(SendMessageW(g_ui.chkCpuOnly, BM_GETCHECK, 0, 0) == BST_CHECKED);
                } else if (id == ID_CHK_START_TRAY) {
                    bool checked = SendMessageW(g_ui.chkStartTray, BM_GETCHECK, 0, 0) == BST_CHECKED;
                    if (g_ui.onStartTrayChange !is null) g_ui.onStartTrayChange(checked);
                } else if (id == ID_CHK_WIN_AUTO) {
                    applyWinAuto(SendMessageW(g_ui.chkWinAuto, BM_GETCHECK, 0, 0) == BST_CHECKED);
                } else if (id == ID_CHK_LIVE_PREVIEW) {
                    applyLivePreview(SendMessageW(g_ui.chkLivePreview, BM_GETCHECK, 0, 0) == BST_CHECKED);
                } else if (id == ID_CHK_OVERLAY) {
                    applyOverlay(SendMessageW(g_ui.chkOverlay, BM_GETCHECK, 0, 0) == BST_CHECKED);
                } else if (id == ID_CHK_TOGGLE_MODE) {
                    applyToggleMode(SendMessageW(g_ui.chkToggleMode, BM_GETCHECK, 0, 0) == BST_CHECKED);
                }
                return 0;

            case WM_APP_TRAY:
                if (lParam == WM_LBUTTONUP || lParam == WM_LBUTTONDBLCLK) {
                    toggleWindowVisibility(hwnd);
                } else if (lParam == WM_RBUTTONUP) {
                    showTrayMenu(hwnd);
                }
                return 0;

            case WM_APP_SYNC:
                flushPendingUi(hwnd);
                return 0;

            case WM_CLOSE:
                ShowWindow(hwnd, SW_HIDE);
                return 0;

            case WM_DESTROY:
                KillTimer(hwnd, ID_TIMER_IDLE);
                KillTimer(hwnd, ID_TIMER_CLICK);
                KillTimer(hwnd, ID_TIMER_HUD_HIDE);
                KillTimer(hwnd, ID_TIMER_PREVIEW);
                if (g_ui.hudWnd !is null) {
                    DestroyWindow(g_ui.hudWnd);
                    g_ui.hudWnd = null;
                }
                Shell_NotifyIconW(NIM_DELETE, &g_ui.nid);
                foreach (f; [g_ui.fontTitle, g_ui.fontBtnBold, g_ui.fontUi, g_ui.fontMono]) {
                    if (f !is null) DeleteObject(f);
                }
                foreach (ic; [g_ui.iconBig, g_ui.iconSmall, g_ui.iconRec, g_ui.iconProc, g_ui.iconPasted]) {
                    if (ic !is null) DestroyIcon(ic);
                }
                PostQuitMessage(0);
                return 0;

            default:
                break;
        }
    } catch (Throwable) {
    }
    return DefWindowProcW(hwnd, msg, wParam, lParam);
}

private bool handleTriggerEvent(uint vk, bool isDownMsg, bool isUpMsg, bool isMouse) nothrow {
    try {
        if (g_ui.capturingHotkey) {
            if (isDownMsg) {
                g_ui.capturingHotkey = false;
                if (vk != VK_ESCAPE) {
                    g_ui.hotkeyVk = vk;
                    if (g_ui.onHotkeyChange !is null) {
                        g_ui.hotkeyName = g_ui.onHotkeyChange(vk);
                    }
                }
                SetWindowTextW(g_ui.btnHotkey, ("Назначить: [" ~ g_ui.hotkeyName ~ "]").toUTF16z());
                uiSetIdleStatus(g_ui.modelLoaded);
            }
            return true;
        }

        if (g_ui.isDown && !isMouse && vk == VK_ESCAPE && isDownMsg) {
            g_ui.isDown = false;
            if (!g_ui.toggleMode) g_ui.waitRelease = true;
            if (g_ui.onCancel !is null) g_ui.onCancel();
            return true;
        }

        if (vk == g_ui.hotkeyVk) {
            if (g_ui.toggleMode) {
                if (isDownMsg && !g_ui.keyPhysicallyDown) {
                    g_ui.keyPhysicallyDown = true;
                    if (!g_ui.isDown) {
                        g_ui.isDown = true;
                        if (g_ui.onStart !is null) g_ui.onStart();
                    } else {
                        g_ui.isDown = false;
                        if (g_ui.onStop !is null) g_ui.onStop();
                    }
                } else if (isUpMsg) {
                    g_ui.keyPhysicallyDown = false;
                }
                return isMouse || g_ui.blockHotkey;
            }

            if (g_ui.waitRelease) {
                if (isUpMsg) g_ui.waitRelease = false;
                return isMouse || g_ui.blockHotkey;
            }

            if (isDownMsg && !g_ui.isDown) {
                g_ui.isDown = true;
                if (g_ui.onStart !is null) g_ui.onStart();
            } else if (isUpMsg && g_ui.isDown) {
                g_ui.isDown = false;
                if (g_ui.onStop !is null) g_ui.onStop();
            }
            return isMouse || g_ui.blockHotkey;
        }
    } catch (Throwable) {
    }
    return false;
}

private extern (Windows) LRESULT lowLevelKeyboardProc(int nCode, WPARAM wParam, LPARAM lParam) nothrow {
    if (nCode == HC_ACTION && lParam != 0) {
        auto kb = cast(KBDLLHOOKSTRUCT*) lParam;
        if ((kb.flags & LLKHF_INJECTED) == 0) {
            bool down = (wParam == WM_KEYDOWN || wParam == WM_SYSKEYDOWN);
            bool up = (wParam == WM_KEYUP || wParam == WM_SYSKEYUP);
            if ((down || up) && handleTriggerEvent(kb.vkCode, down, up, false)) {
                return 1;
            }
        }
    }
    return CallNextHookEx(g_ui.kbdHook, nCode, wParam, lParam);
}

private extern (Windows) LRESULT lowLevelMouseProc(int nCode, WPARAM wParam, LPARAM lParam) nothrow {
    if (nCode == HC_ACTION && lParam != 0) {
        auto ms = cast(MSLLHOOKSTRUCT*) lParam;
        enum DWORD LLMHF_INJECTED = 1;
        if ((ms.flags & LLMHF_INJECTED) == 0) {
            uint vk = 0;
            bool down = false;
            bool up = false;

            if (wParam == WM_MBUTTONDOWN) { vk = VK_MBUTTON; down = true; }
            else if (wParam == WM_MBUTTONUP) { vk = VK_MBUTTON; up = true; }
            else if (wParam == WM_XBUTTONDOWN) {
                vk = ((ms.mouseData >> 16) == 1) ? VK_XBUTTON1 : VK_XBUTTON2;
                down = true;
            } else if (wParam == WM_XBUTTONUP) {
                vk = ((ms.mouseData >> 16) == 1) ? VK_XBUTTON1 : VK_XBUTTON2;
                up = true;
            }

            if (vk != 0 && handleTriggerEvent(vk, down, up, true)) {
                return 1;
            }
        }
    }
    return CallNextHookEx(g_ui.mouseHook, nCode, wParam, lParam);
}
