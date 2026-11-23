module os_win;

import core.stdc.stdio : freopen, stderr, stdout;
import core.stdc.string : memcpy;
import core.sync.mutex : Mutex;
import core.sys.windows.commdlg : GetOpenFileNameW, OFN_FILEMUSTEXIST, OFN_NOCHANGEDIR,
    OFN_PATHMUSTEXIST, OPENFILENAMEW;
import core.sys.windows.commctrl;
import core.sys.windows.shellapi;
import core.sys.windows.winbase : CloseHandle, CreateMutexW, FreeLibrary, GetFileType, GetLastError,
    GetModuleHandleW, GetProcAddress, GetStdHandle, GlobalAlloc, GlobalLock, GlobalUnlock,
    GMEM_MOVEABLE, LoadLibraryW, STD_OUTPUT_HANDLE;
import core.sys.windows.wincon : ATTACH_PARENT_PROCESS, AttachConsole,
    SetConsoleCP, SetConsoleOutputCP;
import core.sys.windows.basetsd : LONG_PTR, UINT_PTR;
import core.sys.windows.windef : BOOL, BYTE, COLORREF, DWORD, ERROR_SUCCESS, FALSE, HBITMAP, HBRUSH,
    HDC, HFONT, HGLOBAL, HHOOK, HICON, HKEY, HMENU, HMODULE, HPEN, HRGN, HRESULT, HWND, LPARAM,
    LRESULT, POINT, RECT, SIZE, TRUE, UINT, WORD, WPARAM;
import core.sys.windows.winerror : ERROR_ALREADY_EXISTS;
import core.sys.windows.wingdi;
import core.sys.windows.winnt : HANDLE, KEY_READ, KEY_WRITE;
import core.sys.windows.winreg : HKEY_CURRENT_USER, REG_DWORD, REG_SZ, RegCloseKey, RegDeleteValueW,
    RegOpenKeyExW, RegQueryValueExW, RegSetValueExW;
import core.sys.windows.winuser;
import core.thread : Thread;
import core.time : msecs;
import i18n : getUiLanguage, tr;
import sound : playClickAsync;
import std.algorithm : max, min;
import std.file : exists, mkdirRecurse, thisExePath, write;
import std.format : format;
import std.math : fabs, sqrt;
import std.path : buildPath, dirName;
import std.range : walkLength;
import std.utf : toUTF16, toUTF16z, toUTF8;

private enum uint WM_APP_TRAY = WM_APP + 1;
private enum uint WM_APP_SYNC = WM_APP + 2;
private enum uint WM_APP_HOOK_START = WM_APP + 3;
private enum uint WM_APP_HOOK_STOP = WM_APP + 4;
private enum uint WM_APP_HOOK_CANCEL = WM_APP + 5;

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
private enum int ID_BTN_BROWSE_MODEL = 118;
private enum int ID_CHK_OVERWRITE_CLIP = 119;
private enum int ID_NAV_MAIN = 120;
private enum int ID_NAV_SETTINGS = 121;
private enum int ID_BTN_COPY_LAST = 122;
private enum int ID_BTN_CLEAR_LOG = 123;
private enum int ID_COMBO_THEME = 124;
private enum int ID_BTN_OPEN_REPL = 125;
private enum int ID_BTN_OPEN_MODELS = 126;
private enum int ID_COMBO_UI_LANG = 127;

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
private enum int ID_TRAY_BROWSE_MODEL = 212;
private enum int ID_TRAY_OVERWRITE_CLIP = 213;

private enum int ID_TRAY_MIC_BASE = 1000;
private enum int ID_TRAY_MODEL_BASE = 2000;
private enum int ID_TRAY_LANG_BASE = 3000;
private enum int ID_TRAY_TIMEOUT_BASE = 4000;
private enum int ID_TRAY_INPUT_MODE_BASE = 5000;
private enum int ID_TRAY_THEME_BASE = 6000;
private enum int ID_TRAY_UI_LANG_BASE = 6100;

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
    string hint = "";
}

struct TimeoutOption {
    string labelEn;
    string labelRu;
    int minutes;
}

static immutable TimeoutOption[] timeoutOptions = [
    TimeoutOption("1 min", "1 мин", 1),
    TimeoutOption("3 min", "3 мин", 3),
    TimeoutOption("5 min", "5 мин", 5),
    TimeoutOption("10 min", "10 мин", 10),
    TimeoutOption("15 min", "15 мин", 15),
    TimeoutOption("30 min", "30 мин", 30),
    TimeoutOption("Never", "Никогда", 0),
];

struct LocalizedOption {
    string labelEn;
    string labelRu;
    string value;
}

static immutable LocalizedOption[] inputModeOptions = [
    LocalizedOption("Per-character (games / SendInput)", "Посимвольно (игры / SendInput)", "sendinput"),
    LocalizedOption("Clipboard (Ctrl+V)", "Буфер обмена (Ctrl+V)", "clipboard"),
    LocalizedOption("Auto (<=80 chars per-character)", "Авто (<=80 симв. — посимвольно)", "auto"),
];

static immutable LocalizedOption[] themeOptions = [
    LocalizedOption("Auto (follow Windows)", "Авто (как в Windows)", "auto"),
    LocalizedOption("Light", "Светлая", "light"),
    LocalizedOption("Dark", "Тёмная", "dark"),
];

static immutable UiOption[] uiLangOptions = [
    UiOption("English", "en"),
    UiOption("Русский", "ru"),
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
    string currentTheme = "auto";
    bool darkActive;
    int activePage = 0; // 0 = Главная, 1 = Настройки
    bool cpuOnly;
    bool gpuAvailable = true;
    bool overwriteNonTextClip;
    bool beepEnabled;
    bool livePreview;
    bool winAutostart;

    void delegate() onStart;
    void delegate() onStop;
    void delegate() onCancel;
    void delegate(int) onMicChange;
    void delegate(string) onModelSelect;
    void delegate(string) onCustomModelPick;
    void delegate(string) onLangChange;
    string delegate(uint) onHotkeyChange;
    void delegate() onModelToggle;
    void delegate(int) onTimeoutChange;
    void delegate(string) onInputModeChange;
    void delegate(string) onThemeChange;
    void delegate(string) onUiLangChange;
    void delegate(bool) onOverwriteClipChange;
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
    HWND btnNavMain;
    HWND btnNavSettings;
    HWND lblStatus;
    HWND btnHide;
    HWND btnModel;
    HWND progressBar;
    HWND lblMic;
    HWND comboMic;
    HWND lblModel;
    HWND comboModel;
    HWND btnBrowseModel;
    HWND lblModelHint;
    HWND hwndTip;
    HWND comboModelList;
    int lastHoveredModelIdx = -1;
    HWND lblLang;
    HWND comboLang;
    HWND lblHotkey;
    HWND btnHotkey;
    HWND lblTimeout;
    HWND comboTimeout;
    HWND lblInputMode;
    HWND comboInputMode;
    HWND lblTheme;
    HWND comboTheme;
    HWND lblUiLang;
    HWND comboUiLang;
    HWND chkAutoLoad;
    HWND chkCpuOnly;
    HWND chkStartTray;
    HWND chkWinAuto;
    HWND chkLivePreview;
    HWND chkOverlay;
    HWND chkToggleMode;
    HWND chkOverwriteClip;
    HWND btnOpenReplacements;
    HWND btnOpenModelsDir;
    HWND lblLog;
    HWND btnCopyLast;
    HWND btnClearLog;
    HWND editLog;

    HBRUSH darkBgBrush;
    HBRUSH darkEditBrush;
    HBRUSH darkSurfaceBrush;

    HFONT fontTitle;
    HFONT fontBtnBold;
    HFONT fontUi;
    HFONT fontHint;
    HFONT fontMono;
    HICON iconBig;
    HICON iconSmall;
    HICON iconUnloaded;
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
    int pendingGpuAvailable = -1;
    int pendingLoadWait = -1;
    int pendingProgressMode = -1; // 0 reset, 1 marquee, 2 determinate
    int pendingProgressPct = 0;
    string pendingLastPhrase;
    bool hasPendingLastPhrase;
    string[] pendingLogs;
    bool clickTimerActive;
    bool marqueeActive;
    bool statusIsIdle = true;
}

private __gshared AppUiState g_ui;
private __gshared HANDLE g_singleInstanceMutex = null;
private __gshared WNDPROC g_origBtnProc = null;
private __gshared WNDPROC g_origListProc = null;

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

void showErrorBox(string msg) {
    MessageBoxW(null, msg.toUTF16z(), tr("Shepot — Error", "Shepot — Ошибка").toUTF16z(), MB_OK | MB_ICONERROR);
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

bool typeText(string text, string inputMode, int charDelayMs, int restoreDelayMs, out string methodUsed, bool overwriteNonText = false) {
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
        if (pasteViaClipboard(text, restoreDelayMs, overwriteNonText)) {
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

private bool pasteViaClipboard(string text, int restoreDelayMs, bool overwriteNonText) {
    wstring prevText;
    bool hadPrevText = false;

    if (!openClipboardRetry()) return false;

    bool hasText = IsClipboardFormatAvailable(CF_UNICODETEXT) != 0;
    if (!hasText && CountClipboardFormats() > 0 && !overwriteNonText) {
        // В буфере картинка, файлы или другие данные — не затираем буфер обмена.
        CloseClipboard();
        uiLog(tr(
            "[CLIP] Clipboard contains image/files — typing per-character without overwriting (\"Overwrite non-text clipboard\" is off).",
            "[CLIP] В буфере картинка/файлы — вставка посимвольно без затирания (опция «Заменять нетекстовый буфер» выключена)."
        ));
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
    g_ui.statusIsIdle = false;
    g_ui.pendingStatus = status;
    g_ui.hasPendingStatus = true;
    g_ui.mtx.unlock();
    PostMessageW(g_ui.hwnd, WM_APP_SYNC, 0, 0);
}

void uiSetIdleStatus(bool modelLoaded) {
    if (g_ui.mtx is null || g_ui.hwnd is null) return;
    g_ui.mtx.lock();
    g_ui.statusIsIdle = true;
    g_ui.pendingStatus = modelLoaded
        ? ((g_ui.toggleMode
            ? tr("Ready — press [", "Готово — нажмите [")
            : tr("Ready — hold [", "Готово — удерживайте [")) ~ g_ui.hotkeyName ~ "]")
        : (tr("Model unloaded — press [", "Модель выгружена — нажмите [")
            ~ g_ui.hotkeyName ~ tr("] or Load", "] или Загрузить"));
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

void uiSetGpuAvailable(bool available) {
    if (g_ui.mtx is null || g_ui.hwnd is null) return;
    g_ui.mtx.lock();
    g_ui.pendingGpuAvailable = available ? 1 : 0;
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
    string initialTheme,
    bool overwriteNonTextClip,
    bool startMinimized,
    bool autoLoad,
    bool cpuOnly,
    bool gpuAvailable,
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
    void delegate(string) onCustomModelPick,
    void delegate(string) onLangChange,
    string delegate(uint) onHotkeyChange,
    void delegate() onModelToggle,
    void delegate(int) onTimeoutChange,
    void delegate(string) onInputModeChange,
    void delegate(string) onThemeChange,
    void delegate(string) onUiLangChange,
    void delegate(bool) onOverwriteClipChange,
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
    g_ui.currentTheme = initialTheme.length ? initialTheme : "auto";
    g_ui.activePage = 0;
    g_ui.overwriteNonTextClip = overwriteNonTextClip;
    g_ui.cpuOnly = cpuOnly;
    g_ui.gpuAvailable = gpuAvailable;
    g_ui.beepEnabled = beepEnabled;
    g_ui.livePreview = livePreview;
    g_ui.winAutostart = winAutostart;
    g_ui.showOverlay = showOverlay;

    g_ui.onStart = onStart;
    g_ui.onStop = onStop;
    g_ui.onCancel = onCancel;
    g_ui.onMicChange = onMicChange;
    g_ui.onModelSelect = onModelSelect;
    g_ui.onCustomModelPick = onCustomModelPick;
    g_ui.onLangChange = onLangChange;
    g_ui.onHotkeyChange = onHotkeyChange;
    g_ui.onModelToggle = onModelToggle;
    g_ui.onTimeoutChange = onTimeoutChange;
    g_ui.onInputModeChange = onInputModeChange;
    g_ui.onThemeChange = onThemeChange;
    g_ui.onUiLangChange = onUiLangChange;
    g_ui.onOverwriteClipChange = onOverwriteClipChange;
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
    g_ui.iconUnloaded = createMicIcon(16, 100, 116, 139, 71, 85, 105);
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
        tr("Shepot — Voice Dictation", "Shepot — Голосовой ввод").toUTF16z(),
        style,
        CW_USEDEFAULT, CW_USEDEFAULT, 580, 540,
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
    populateLocalizedCombo(g_ui.comboInputMode, inputModeOptions, g_ui.currentInputMode);
    populateLocalizedCombo(g_ui.comboTheme, themeOptions, g_ui.currentTheme);
    populateOptionCombo(g_ui.comboUiLang, cast(UiOption[]) uiLangOptions, getUiLanguage());

    SendMessageW(g_ui.chkAutoLoad, BM_SETCHECK, autoLoad ? BST_CHECKED : BST_UNCHECKED, 0);
    syncCpuOnlyControl();
    SendMessageW(g_ui.chkStartTray, BM_SETCHECK, startMinimized ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkWinAuto, BM_SETCHECK, winAutostart ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkLivePreview, BM_SETCHECK, livePreview ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkOverlay, BM_SETCHECK, showOverlay ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkToggleMode, BM_SETCHECK, toggleMode ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.chkOverwriteClip, BM_SETCHECK, overwriteNonTextClip ? BST_CHECKED : BST_UNCHECKED, 0);
    SetWindowTextW(g_ui.btnHotkey, (tr("Assign: [", "Назначить: [") ~ hotkeyName ~ "]").toUTF16z());
    applyModelButtonState(initialLoaded, initialLoading);
    refreshModelHint();
    setActivePage(0);
    applyWindowTheme(g_ui.hwnd);

    foreach (line; initialLogs) uiLog(line);
    if (initialLoading) {
        uiSetStatus(tr("Loading model...", "Загрузка модели..."));
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
    SendMessageW(g_ui.comboMic, CB_RESETCONTENT, 0, 0);
    SendMessageW(g_ui.comboMic, CB_ADDSTRING, 0,
        cast(LPARAM) tr("Default (Windows)", "По умолчанию (Windows)").toUTF16z());
    foreach (name; micNames) {
        SendMessageW(g_ui.comboMic, CB_ADDSTRING, 0, cast(LPARAM) name.toUTF16z());
    }
    int sel = (initialMic >= 0 && initialMic < cast(int) micNames.length) ? (initialMic + 1) : 0;
    SendMessageW(g_ui.comboMic, CB_SETCURSEL, sel, 0);
}

void uiSetModelOptions(UiOption[] options, string currentVal) {
    g_ui.modelOptions = options;
    g_ui.currentModel = currentVal;
    if (g_ui.comboModel !is null) {
        populateOptionCombo(g_ui.comboModel, options, currentVal);
    }
    refreshModelHint();
}

void uiSetLangOptions(UiOption[] options, string currentVal) {
    g_ui.langOptions = options;
    g_ui.currentLang = currentVal;
    if (g_ui.comboLang !is null) {
        populateOptionCombo(g_ui.comboLang, options, currentVal);
    }
}

private void openCustomModelDialog(HWND hwnd) {
    if (g_ui.onCustomModelPick is null) return;
    wchar[1024] buf = 0;
    OPENFILENAMEW ofn;
    ofn.lStructSize = OPENFILENAMEW.sizeof;
    ofn.hwndOwner = hwnd;
    ofn.lpstrFilter = tr(
        "Models (*.bin;*.onnx;tokens.txt)\0*.bin;*.onnx;tokens.txt\0Whisper GGML (*.bin)\0*.bin\0Sherpa ONNX (*.onnx)\0*.onnx\0All files (*.*)\0*.*\0\0",
        "Модели (*.bin;*.onnx;tokens.txt)\0*.bin;*.onnx;tokens.txt\0Whisper GGML (*.bin)\0*.bin\0Sherpa ONNX (*.onnx)\0*.onnx\0Все файлы (*.*)\0*.*\0\0"
    ).toUTF16z();
    ofn.lpstrFile = buf.ptr;
    ofn.nMaxFile = cast(DWORD) buf.length;
    ofn.lpstrTitle = tr(
        "Select model file (.bin or .onnx / tokens.txt)",
        "Выберите файл модели (.bin или .onnx / tokens.txt)"
    ).toUTF16z();
    ofn.Flags = OFN_FILEMUSTEXIST | OFN_PATHMUSTEXIST | OFN_NOCHANGEDIR;
    if (!GetOpenFileNameW(&ofn)) return;

    size_t len = 0;
    while (len < buf.length && buf[len] != 0) ++len;
    if (len > 0) {
        g_ui.onCustomModelPick(buf[0 .. len].toUTF8());
    }
}

private void populateOptionCombo(HWND combo, UiOption[] options, string currentVal) {
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    int sel = 0;
    foreach (i, opt; options) {
        SendMessageW(combo, CB_ADDSTRING, 0, cast(LPARAM) opt.label.toUTF16z());
        if (opt.value == currentVal) sel = cast(int) i;
    }
    SendMessageW(combo, CB_SETCURSEL, sel, 0);
}

private void populateLocalizedCombo(HWND combo, immutable(LocalizedOption)[] options, string currentVal) {
    SendMessageW(combo, CB_RESETCONTENT, 0, 0);
    int sel = 0;
    foreach (i, opt; options) {
        SendMessageW(combo, CB_ADDSTRING, 0, cast(LPARAM) tr(opt.labelEn, opt.labelRu).toUTF16z());
        if (opt.value == currentVal) sel = cast(int) i;
    }
    SendMessageW(combo, CB_SETCURSEL, sel, 0);
}

private void populateTimeoutCombo(int minutes) {
    SendMessageW(g_ui.comboTimeout, CB_RESETCONTENT, 0, 0);
    int sel = 2;
    foreach (i, opt; timeoutOptions) {
        SendMessageW(g_ui.comboTimeout, CB_ADDSTRING, 0, cast(LPARAM) tr(opt.labelEn, opt.labelRu).toUTF16z());
        if (opt.minutes == minutes) sel = cast(int) i;
    }
    SendMessageW(g_ui.comboTimeout, CB_SETCURSEL, sel, 0);
}

private void applyModelButtonState(bool loaded, bool loading) {
    g_ui.modelLoaded = loaded;
    g_ui.modelLoading = loading;
    if (loading) {
        SetWindowTextW(g_ui.btnModel, tr("Loading model...", "Загрузка модели...").toUTF16z());
        EnableWindow(g_ui.btnModel, FALSE);
    } else if (loaded) {
        SetWindowTextW(g_ui.btnModel, tr("Unload model from memory", "Выгрузить модель из памяти").toUTF16z());
        EnableWindow(g_ui.btnModel, TRUE);
    } else {
        SetWindowTextW(g_ui.btnModel, tr("Load model", "Загрузить модель").toUTF16z());
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
    int hideW = 124;
    int navW = 104;
    int y = pad;
    MoveWindow(g_ui.btnNavMain, pad, y, navW, 28, TRUE);
    MoveWindow(g_ui.btnNavSettings, pad + navW + 6, y, navW + 8, 28, TRUE);
    MoveWindow(g_ui.btnHide, w - pad - hideW, y, hideW, 28, TRUE);

    // Страница 0: Главная
    int my = y + 38;
    MoveWindow(g_ui.lblStatus, pad, my, w - pad * 2, 24, TRUE);

    my += 30;
    MoveWindow(g_ui.btnModel, pad, my, w - pad * 2, 36, TRUE);

    my += 42;
    MoveWindow(g_ui.progressBar, pad, my, w - pad * 2, 10, TRUE);

    my += 20;
    int mLabelW = 72;
    int browseW = 84;
    int mComboW = w - pad * 2 - mLabelW - browseW - 14;
    MoveWindow(g_ui.lblModel, pad, my + 4, mLabelW, 20, TRUE);
    MoveWindow(g_ui.comboModel, pad + mLabelW + 6, my, mComboW, 220, TRUE);
    MoveWindow(g_ui.btnBrowseModel, w - pad - browseW, my - 1, browseW, 25, TRUE);

    my += 29;
    MoveWindow(g_ui.lblModelHint, pad + mLabelW + 6, my, w - pad * 2 - mLabelW - 6, 32, TRUE);

    my += 36;
    int clearW = 80;
    int copyW = 140;
    MoveWindow(g_ui.lblLog, pad, my + 4, w - pad * 2 - copyW - clearW - 14, 18, TRUE);
    MoveWindow(g_ui.btnCopyLast, w - pad - clearW - copyW - 6, my, copyW, 24, TRUE);
    MoveWindow(g_ui.btnClearLog, w - pad - clearW, my, clearW, 24, TRUE);

    my += 30;
    int logH = h - my - pad;
    if (logH < 80) logH = 80;
    MoveWindow(g_ui.editLog, pad, my, w - pad * 2, logH, TRUE);

    // Страница 1: Настройки
    int labelW = 166;
    int ctrlW = w - pad * 2 - labelW - 8;
    int sy = y + 40;
    MoveWindow(g_ui.lblMic, pad, sy + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboMic, pad + labelW + 8, sy, ctrlW, 220, TRUE);

    sy += 34;
    MoveWindow(g_ui.lblLang, pad, sy + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboLang, pad + labelW + 8, sy, ctrlW, 220, TRUE);

    sy += 34;
    MoveWindow(g_ui.lblHotkey, pad, sy + 5, labelW, 20, TRUE);
    MoveWindow(g_ui.btnHotkey, pad + labelW + 8, sy, ctrlW, 28, TRUE);

    sy += 36;
    MoveWindow(g_ui.lblTimeout, pad, sy + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboTimeout, pad + labelW + 8, sy, ctrlW, 220, TRUE);

    sy += 34;
    MoveWindow(g_ui.lblInputMode, pad, sy + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboInputMode, pad + labelW + 8, sy, ctrlW, 220, TRUE);

    sy += 34;
    MoveWindow(g_ui.lblTheme, pad, sy + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboTheme, pad + labelW + 8, sy, ctrlW, 220, TRUE);

    sy += 34;
    MoveWindow(g_ui.lblUiLang, pad, sy + 4, labelW, 20, TRUE);
    MoveWindow(g_ui.comboUiLang, pad + labelW + 8, sy, ctrlW, 220, TRUE);

    sy += 38;
    int halfW = (w - pad * 3) / 2;
    MoveWindow(g_ui.chkAutoLoad, pad, sy, halfW, 22, TRUE);
    MoveWindow(g_ui.chkCpuOnly, pad * 2 + halfW, sy, halfW, 22, TRUE);

    sy += 26;
    MoveWindow(g_ui.chkStartTray, pad, sy, halfW, 22, TRUE);
    MoveWindow(g_ui.chkWinAuto, pad * 2 + halfW, sy, halfW, 22, TRUE);

    sy += 26;
    MoveWindow(g_ui.chkLivePreview, pad, sy, halfW, 22, TRUE);
    MoveWindow(g_ui.chkOverlay, pad * 2 + halfW, sy, halfW, 22, TRUE);

    sy += 26;
    MoveWindow(g_ui.chkToggleMode, pad, sy, halfW, 22, TRUE);
    MoveWindow(g_ui.chkOverwriteClip, pad * 2 + halfW, sy, halfW, 22, TRUE);

    sy += 34;
    MoveWindow(g_ui.btnOpenReplacements, pad, sy, halfW, 28, TRUE);
    MoveWindow(g_ui.btnOpenModelsDir, pad * 2 + halfW, sy, halfW, 28, TRUE);
}

private HICON idleTrayIcon() {
    return g_ui.modelLoaded ? g_ui.iconSmall : g_ui.iconUnloaded;
}

private void addTrayIcon(HWND hwnd) {
    g_ui.nid.cbSize = NOTIFYICONDATAW.sizeof;
    g_ui.nid.hWnd = hwnd;
    g_ui.nid.uID = 1;
    g_ui.nid.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
    g_ui.nid.uCallbackMessage = WM_APP_TRAY;
    g_ui.nid.hIcon = idleTrayIcon();
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
    auto toggleText = (IsWindowVisible(hwnd) ? tr("Hide to Tray", "Скрыть в трей") : tr("Show Window", "Показать окно")).toUTF16z();
    AppendMenuW(menu, MF_STRING, ID_TRAY_TOGGLE, toggleText);
    UINT copyFlags = MF_STRING | (g_ui.lastPhrase.length > 0 ? 0 : MF_GRAYED);
    AppendMenuW(menu, copyFlags, ID_TRAY_COPY_LAST, tr("Copy Last Phrase", "Скопировать последнюю фразу").toUTF16z());
    AppendMenuW(menu, MF_SEPARATOR, 0, null);

    string modelBtnLabel = g_ui.modelLoading
        ? tr("Loading model...", "Загрузка модели...")
        : (g_ui.modelLoaded ? tr("Unload model from memory", "Выгрузить модель из памяти") : tr("Load model", "Загрузить модель"));
    UINT modelFlags = MF_STRING | (g_ui.modelLoading ? MF_GRAYED : 0);
    AppendMenuW(menu, modelFlags, ID_TRAY_MODEL_TOGGLE, modelBtnLabel.toUTF16z());

    HMENU subModel = CreatePopupMenu();
    foreach (i, opt; g_ui.modelOptions) {
        UINT fl = MF_STRING | (opt.value == g_ui.currentModel ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subModel, fl, ID_TRAY_MODEL_BASE + i, opt.label.toUTF16z());
    }
    AppendMenuW(subModel, MF_SEPARATOR, 0, null);
    AppendMenuW(subModel, MF_STRING, ID_TRAY_BROWSE_MODEL, tr("Browse custom model...", "Выбрать свою модель...").toUTF16z());
    AppendMenuW(menu, MF_POPUP, cast(size_t) subModel, tr("Model", "Модель").toUTF16z());

    HMENU subLang = CreatePopupMenu();
    foreach (i, opt; g_ui.langOptions) {
        UINT fl = MF_STRING | (opt.value == g_ui.currentLang ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subLang, fl, ID_TRAY_LANG_BASE + i, opt.label.toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subLang, tr("Speech Language", "Язык речи").toUTF16z());

    HMENU subMic = CreatePopupMenu();
    AppendMenuW(subMic, MF_STRING | (g_ui.currentMic < 0 ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_MIC_BASE, tr("Default (Windows)", "По умолчанию (Windows)").toUTF16z());
    foreach (i, name; g_ui.micNames) {
        UINT fl = MF_STRING | (g_ui.currentMic == cast(int) i ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subMic, fl, ID_TRAY_MIC_BASE + 1 + i, name.toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subMic, tr("Microphone", "Микрофон").toUTF16z());

    HMENU subTimeout = CreatePopupMenu();
    foreach (i, opt; timeoutOptions) {
        UINT fl = MF_STRING | (opt.minutes == g_ui.currentTimeoutMin ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subTimeout, fl, ID_TRAY_TIMEOUT_BASE + i, tr(opt.labelEn, opt.labelRu).toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subTimeout, tr("Auto-unload (VRAM)", "Автовыгрузка (VRAM)").toUTF16z());

    HMENU subInputMode = CreatePopupMenu();
    foreach (i, opt; inputModeOptions) {
        UINT fl = MF_STRING | (opt.value == g_ui.currentInputMode ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subInputMode, fl, ID_TRAY_INPUT_MODE_BASE + i, tr(opt.labelEn, opt.labelRu).toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subInputMode, tr("Input Mode", "Режим ввода").toUTF16z());

    HMENU subTheme = CreatePopupMenu();
    foreach (i, opt; themeOptions) {
        UINT fl = MF_STRING | (opt.value == g_ui.currentTheme ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subTheme, fl, ID_TRAY_THEME_BASE + i, tr(opt.labelEn, opt.labelRu).toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subTheme, tr("Theme", "Тема оформления").toUTF16z());

    HMENU subUiLang = CreatePopupMenu();
    auto curUiLang = getUiLanguage();
    foreach (i, opt; uiLangOptions) {
        UINT fl = MF_STRING | (opt.value == curUiLang ? MF_CHECKED : MF_UNCHECKED);
        AppendMenuW(subUiLang, fl, ID_TRAY_UI_LANG_BASE + i, opt.label.toUTF16z());
    }
    AppendMenuW(menu, MF_POPUP, cast(size_t) subUiLang, tr("UI Language", "Язык интерфейса").toUTF16z());

    AppendMenuW(menu, MF_STRING, ID_TRAY_HOTKEY,
        (tr("Assign Hotkey [", "Назначить клавишу [") ~ g_ui.hotkeyName ~ "]").toUTF16z());
    AppendMenuW(menu, MF_STRING | (g_ui.toggleMode ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_TOGGLE_MODE, tr("Toggle Mode", "Режим переключения (Toggle)").toUTF16z());
    AppendMenuW(menu, MF_STRING | (g_ui.overwriteNonTextClip ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_OVERWRITE_CLIP, tr("Overwrite non-text clipboard", "Заменять нетекстовый буфер").toUTF16z());

    AppendMenuW(menu, MF_SEPARATOR, 0, null);
    bool cpuDisplay = !g_ui.gpuAvailable || g_ui.cpuOnly;
    UINT cpuFlags = MF_STRING | (cpuDisplay ? MF_CHECKED : MF_UNCHECKED) | (g_ui.gpuAvailable ? 0 : MF_GRAYED);
    AppendMenuW(menu, cpuFlags, ID_TRAY_CPU_ONLY, tr("CPU only", "Только на процессоре (CPU)").toUTF16z());
    AppendMenuW(menu, MF_STRING | (g_ui.beepEnabled ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_BEEP, tr("Sound cues", "Звуковые сигналы").toUTF16z());
    AppendMenuW(menu, MF_STRING | (g_ui.showOverlay ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_OVERLAY, tr("Floating indicator (HUD)", "Плавающий индикатор (HUD)").toUTF16z());
    AppendMenuW(menu, MF_STRING | (g_ui.livePreview ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_LIVE_PREVIEW, tr("Live speech preview (HUD)", "Предпросмотр речи в HUD (Live)").toUTF16z());
    AppendMenuW(menu, MF_STRING | (g_ui.winAutostart ? MF_CHECKED : MF_UNCHECKED),
        ID_TRAY_WIN_AUTO, tr("Run with Windows", "Запускать с Windows").toUTF16z());

    AppendMenuW(menu, MF_SEPARATOR, 0, null);
    AppendMenuW(menu, MF_STRING, ID_TRAY_EXIT, tr("Exit", "Выход").toUTF16z());

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
    int gpuAvail;
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
    gpuAvail = g_ui.pendingGpuAvailable;
    g_ui.pendingGpuAvailable = -1;
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
        if (g_ui.btnCopyLast !is null) {
            EnableWindow(g_ui.btnCopyLast, g_ui.lastPhrase.length > 0 ? TRUE : FALSE);
        }
    }

    bool modifyTray = false;
    if (modelState >= 0) {
        applyModelButtonState(modelState == 1, modelState == 2);
        if (g_ui.hudState == VisualState.idle) {
            g_ui.nid.hIcon = idleTrayIcon();
            modifyTray = true;
        }
    }
    if (gpuAvail >= 0) {
        g_ui.gpuAvailable = (gpuAvail == 1);
        syncCpuOnlyControl();
    }
    if (progMode >= 0) {
        applyProgressState(progMode, progPct);
        if (progMode == 2 && g_ui.hudState == VisualState.processing && g_ui.hudWnd !is null && g_ui.showOverlay) {
            g_ui.hudText = format(tr("Processing voice... %s%%", "Обработка голоса... %s%%"), progPct);
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

    if (hasStatus) {
        SetWindowTextW(g_ui.lblStatus, status.toUTF16z());
        setTrayTip("Shepot — " ~ status);
        modifyTray = true;
    }
    if (visState >= 0) {
        g_ui.hudState = cast(VisualState) visState;
        final switch (g_ui.hudState) {
            case VisualState.idle:       g_ui.nid.hIcon = idleTrayIcon(); break;
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
    refreshModelHint();
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

private void syncCpuOnlyControl() {
    if (g_ui.chkCpuOnly is null) return;
    bool displayChecked = !g_ui.gpuAvailable || g_ui.cpuOnly;
    SendMessageW(g_ui.chkCpuOnly, BM_SETCHECK, displayChecked ? BST_CHECKED : BST_UNCHECKED, 0);
    EnableWindow(g_ui.chkCpuOnly, g_ui.gpuAvailable ? TRUE : FALSE);
}

private void applyCpuOnly(bool checked) {
    if (!g_ui.gpuAvailable) return;
    g_ui.cpuOnly = checked;
    syncCpuOnlyControl();
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

private void applyOverwriteClip(bool checked) {
    g_ui.overwriteNonTextClip = checked;
    SendMessageW(g_ui.chkOverwriteClip, BM_SETCHECK, checked ? BST_CHECKED : BST_UNCHECKED, 0);
    if (g_ui.onOverwriteClipChange !is null) g_ui.onOverwriteClipChange(checked);
}

private void applyThemeSelection(int idx) {
    if (idx < 0 || idx >= cast(int) themeOptions.length) return;
    g_ui.currentTheme = themeOptions[idx].value;
    SendMessageW(g_ui.comboTheme, CB_SETCURSEL, idx, 0);
    applyWindowTheme(g_ui.hwnd);
    if (g_ui.onThemeChange !is null) g_ui.onThemeChange(g_ui.currentTheme);
}

private void applyUiLangSelection(int idx) {
    if (idx < 0 || idx >= cast(int) uiLangOptions.length) return;
    auto langVal = uiLangOptions[idx].value;
    SendMessageW(g_ui.comboUiLang, CB_SETCURSEL, idx, 0);
    if (g_ui.onUiLangChange !is null) g_ui.onUiLangChange(langVal);
}

private bool isWindowsDarkTheme() {
    HKEY hKey;
    if (RegOpenKeyExW(HKEY_CURRENT_USER,
            "Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize"w.ptr,
            0, KEY_READ, &hKey) != ERROR_SUCCESS)
    {
        return false;
    }
    scope (exit) RegCloseKey(hKey);

    DWORD val = 1;
    DWORD sz = DWORD.sizeof;
    DWORD typ = 0;
    if (RegQueryValueExW(hKey, "AppsUseLightTheme"w.ptr, null, &typ, cast(ubyte*) &val, &sz) == ERROR_SUCCESS
        && typ == REG_DWORD)
    {
        return val == 0;
    }
    return false;
}

private void applyWindowTheme(HWND hwnd) {
    if (hwnd is null) return;
    bool dark = (g_ui.currentTheme == "dark") || (g_ui.currentTheme == "auto" && isWindowsDarkTheme());
    g_ui.darkActive = dark;

    if (auto hDwm = LoadLibraryW("dwmapi.dll"w.ptr)) {
        scope (exit) FreeLibrary(hDwm);
        alias FnDwmSet = extern (Windows) HRESULT function(HWND, DWORD, const(void)*, DWORD);
        if (auto pSet = cast(FnDwmSet) GetProcAddress(hDwm, "DwmSetWindowAttribute")) {
            BOOL useDark = dark ? TRUE : FALSE;
            if (pSet(hwnd, 20, &useDark, BOOL.sizeof) != 0) {
                pSet(hwnd, 19, &useDark, BOOL.sizeof);
            }
        }
    }

    if (auto hUx = LoadLibraryW("uxtheme.dll"w.ptr)) {
        scope (exit) FreeLibrary(hUx);
        alias FnSetTheme = extern (Windows) HRESULT function(HWND, const(wchar)*, const(wchar)*);
        if (auto pTheme = cast(FnSetTheme) GetProcAddress(hUx, "SetWindowTheme")) {
            auto expName = dark ? "DarkMode_Explorer"w.ptr : null;
            auto cfdName = dark ? "DarkMode_CFD"w.ptr : null;
            auto emptyOrNull = dark ? ""w.ptr : null;

            foreach (c; [
                g_ui.btnNavMain, g_ui.btnNavSettings, g_ui.btnHide, g_ui.btnModel,
                g_ui.btnBrowseModel, g_ui.btnCopyLast, g_ui.btnClearLog,
                g_ui.btnHotkey, g_ui.btnOpenReplacements, g_ui.btnOpenModelsDir,
                g_ui.editLog, g_ui.hwndTip,
            ]) {
                if (c !is null) pTheme(c, expName, null);
            }
            foreach (c; [
                g_ui.comboMic, g_ui.comboModel, g_ui.comboLang,
                g_ui.comboTimeout, g_ui.comboInputMode, g_ui.comboTheme, g_ui.comboUiLang,
            ]) {
                if (c !is null) pTheme(c, cfdName, null);
            }
            foreach (c; [
                g_ui.lblStatus, g_ui.lblModel, g_ui.lblModelHint, g_ui.lblLog, g_ui.lblMic,
                g_ui.lblLang, g_ui.lblHotkey, g_ui.lblTimeout, g_ui.lblInputMode, g_ui.lblTheme,
                g_ui.lblUiLang,
            ]) {
                if (c !is null) pTheme(c, dark ? ""w.ptr : null, dark ? ""w.ptr : null);
            }
            foreach (c; [
                g_ui.chkAutoLoad, g_ui.chkCpuOnly, g_ui.chkStartTray, g_ui.chkWinAuto,
                g_ui.chkLivePreview, g_ui.chkOverlay, g_ui.chkToggleMode, g_ui.chkOverwriteClip,
            ]) {
                if (c !is null) pTheme(c, null, null);
            }
        }
    }

    SetWindowPos(hwnd, null, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOZORDER | SWP_FRAMECHANGED);
    RedrawWindow(hwnd, null, null, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
}

private void setActivePage(int page) {
    g_ui.activePage = page;
    SendMessageW(g_ui.btnNavMain, BM_SETCHECK, page == 0 ? BST_CHECKED : BST_UNCHECKED, 0);
    SendMessageW(g_ui.btnNavSettings, BM_SETCHECK, page == 1 ? BST_CHECKED : BST_UNCHECKED, 0);

    int swMain = (page == 0) ? SW_SHOW : SW_HIDE;
    int swSet = (page == 1) ? SW_SHOW : SW_HIDE;
    foreach (c; [
        g_ui.lblStatus, g_ui.btnModel, g_ui.progressBar,
        g_ui.lblModel, g_ui.comboModel, g_ui.btnBrowseModel, g_ui.lblModelHint,
        g_ui.lblLog, g_ui.btnCopyLast, g_ui.btnClearLog, g_ui.editLog,
    ]) {
        if (c !is null) ShowWindow(c, swMain);
    }
    foreach (c; [
        g_ui.lblMic, g_ui.comboMic, g_ui.lblLang, g_ui.comboLang,
        g_ui.lblHotkey, g_ui.btnHotkey, g_ui.lblTimeout, g_ui.comboTimeout,
        g_ui.lblInputMode, g_ui.comboInputMode, g_ui.lblTheme, g_ui.comboTheme,
        g_ui.lblUiLang, g_ui.comboUiLang,
        g_ui.chkAutoLoad, g_ui.chkCpuOnly, g_ui.chkStartTray, g_ui.chkWinAuto,
        g_ui.chkLivePreview, g_ui.chkOverlay, g_ui.chkToggleMode, g_ui.chkOverwriteClip,
        g_ui.btnOpenReplacements, g_ui.btnOpenModelsDir,
    ]) {
        if (c !is null) ShowWindow(c, swSet);
    }
    InvalidateRect(g_ui.hwnd, null, TRUE);
}

private void openReplacementsFile(HWND hwnd) {
    auto path = buildPath(dirName(thisExePath()), "replacements.json");
    if (!exists(path)) {
        try {
            write(path, tr("{\n  \"teh\": \"the\"\n}\n", "{\n  \"вишпер\": \"Whisper\"\n}\n"));
        } catch (Exception) {
        }
    }
    ShellExecuteW(hwnd, "open"w.ptr, path.toUTF16z(), null, null, SW_SHOWNORMAL);
}

private void openModelsDir(HWND hwnd) {
    auto path = buildPath(dirName(thisExePath()), "models");
    try {
        mkdirRecurse(path);
    } catch (Exception) {
    }
    ShellExecuteW(hwnd, "open"w.ptr, path.toUTF16z(), null, null, SW_SHOWNORMAL);
}

private void drawNativeCheckBox(HWND hwnd, HDC hdc, const ref RECT boxRc, bool checked, bool enabled) nothrow {
    alias FnOpenTheme = extern (Windows) HANDLE function(HWND, const(wchar)*) nothrow;
    alias FnCloseTheme = extern (Windows) HRESULT function(HANDLE) nothrow;
    alias FnDrawThemeBg = extern (Windows) HRESULT function(HANDLE, HDC, int, int, const(RECT)*, const(RECT)*) nothrow;
    alias FnPartSize = extern (Windows) HRESULT function(HANDLE, HDC, int, int, const(RECT)*, int, SIZE*) nothrow;

    static HMODULE hUx = null;
    static FnOpenTheme pOpen = null;
    static FnCloseTheme pClose = null;
    static FnDrawThemeBg pDraw = null;
    static FnPartSize pSize = null;
    static bool loaded = false;

    if (!loaded) {
        loaded = true;
        hUx = LoadLibraryW("uxtheme.dll"w.ptr);
        if (hUx !is null) {
            pOpen = cast(FnOpenTheme) GetProcAddress(hUx, "OpenThemeData");
            pClose = cast(FnCloseTheme) GetProcAddress(hUx, "CloseThemeData");
            pDraw = cast(FnDrawThemeBg) GetProcAddress(hUx, "DrawThemeBackground");
            pSize = cast(FnPartSize) GetProcAddress(hUx, "GetThemePartSize");
        }
    }

    RECT r = boxRc;
    HANDLE hTheme = (pOpen !is null) ? pOpen(hwnd, "Button"w.ptr) : null;
    scope (exit) {
        if (hTheme !is null && pClose !is null) pClose(hTheme);
    }

    if (hTheme !is null && pSize !is null) {
        SIZE sz;
        if (pSize(hTheme, hdc, 3, 5, null, 1, &sz) == 0 && sz.cx > 0 && sz.cy > 0) {
            int midY = (boxRc.top + boxRc.bottom) / 2;
            r = RECT(boxRc.left, midY - sz.cy / 2, boxRc.left + sz.cx, midY - sz.cy / 2 + sz.cy);
        }
    }

    if (checked && hTheme !is null && pDraw !is null) {
        // BP_CHECKBOX = 3; CBS_CHECKEDNORMAL = 5, CBS_CHECKEDDISABLED = 8
        pDraw(hTheme, hdc, 3, enabled ? 5 : 8, &r, null);
        return;
    }

    COLORREF boxFill = checked
        ? (enabled ? RGB(0, 120, 212) : RGB(68, 68, 76))
        : RGB(30, 30, 36);
    COLORREF boxBorder = checked
        ? boxFill
        : (enabled ? RGB(138, 138, 150) : RGB(78, 78, 86));
    HBRUSH br = CreateSolidBrush(boxFill);
    HPEN pen = CreatePen(PS_SOLID, 1, boxBorder);
    auto oldBr = SelectObject(hdc, br);
    auto oldPen = SelectObject(hdc, pen);
    RoundRect(hdc, r.left, r.top, r.right, r.bottom, 4, 4);
    SelectObject(hdc, oldPen);
    SelectObject(hdc, oldBr);
    DeleteObject(pen);
    DeleteObject(br);
}

private extern (Windows) LRESULT darkButtonProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow {
    if (g_ui.darkActive && (msg == WM_PAINT || msg == WM_ERASEBKGND)) {
        int btnId = GetDlgCtrlID(hwnd);
        bool isNav = (btnId == ID_NAV_MAIN || btnId == ID_NAV_SETTINGS);
        bool checked = CallWindowProcW(g_origBtnProc, hwnd, BM_GETCHECK, 0, 0) == BST_CHECKED;

        // Невыбранную кнопку навигации рисует сама Windows — 1-в-1 как «Скрыть в трей».
        if (isNav && !checked) {
            return CallWindowProcW(g_origBtnProc, hwnd, msg, wParam, lParam);
        }

        if (msg == WM_ERASEBKGND) return 1;
        try {
            PAINTSTRUCT ps;
            HDC hdc = BeginPaint(hwnd, &ps);
            RECT rc;
            GetClientRect(hwnd, &rc);
            FillRect(hdc, &rc, g_ui.darkBgBrush);

            bool enabled = IsWindowEnabled(hwnd) != 0;
            wchar[128] txt = 0;
            int tlen = GetWindowTextW(hwnd, txt.ptr, cast(int) txt.length);
            auto oldFont = SelectObject(hdc, g_ui.fontUi);
            SetBkMode(hdc, TRANSPARENT);

            if (isNav) {
                HBRUSH br = CreateSolidBrush(RGB(34, 62, 100));
                HPEN pen = CreatePen(PS_SOLID, 1, RGB(66, 135, 245));
                auto oldBr = SelectObject(hdc, br);
                auto oldPen = SelectObject(hdc, pen);
                RoundRect(hdc, 0, 0, rc.right, rc.bottom, 6, 6);
                SelectObject(hdc, oldPen);
                SelectObject(hdc, oldBr);
                DeleteObject(pen);
                DeleteObject(br);

                SetTextColor(hdc, RGB(255, 255, 255));
                DrawTextW(hdc, txt.ptr, tlen, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
            } else {
                int box = 14;
                int by = ((rc.bottom - rc.top) - box) / 2;
                RECT boxRc = RECT(0, by, box, by + box);
                drawNativeCheckBox(hwnd, hdc, boxRc, checked, enabled);

                RECT tr = RECT(20, rc.top, rc.right, rc.bottom);
                SetTextColor(hdc, enabled ? RGB(244, 244, 245) : RGB(118, 118, 128));
                DrawTextW(hdc, txt.ptr, tlen, &tr, DT_LEFT | DT_VCENTER | DT_SINGLELINE);
            }

            SelectObject(hdc, oldFont);
            EndPaint(hwnd, &ps);
            return 0;
        } catch (Throwable) {
        }
    }
    return CallWindowProcW(g_origBtnProc, hwnd, msg, wParam, lParam);
}

private void setTooltipText(HWND parent, HWND tip, HWND ctrl, string text, bool add) nothrow {
    if (tip is null || ctrl is null) return;
    try {
        TOOLINFOW ti;
        ti.cbSize = TOOLINFOW.sizeof;
        ti.uFlags = TTF_IDISHWND | TTF_SUBCLASS;
        ti.hwnd = parent;
        ti.uId = cast(UINT_PTR) ctrl;
        ti.lpszText = cast(wchar*) text.toUTF16z();
        SendMessageW(tip, add ? TTM_ADDTOOLW : TTM_UPDATETIPTEXTW, 0, cast(LPARAM) &ti);
    } catch (Throwable) {
    }
}

private void refreshModelHint(int idxOverride = -1) nothrow {
    try {
        UiOption opt;
        bool found = false;
        if (idxOverride >= 0 && idxOverride < cast(int) g_ui.modelOptions.length) {
            opt = g_ui.modelOptions[idxOverride];
            found = true;
        } else {
            foreach (o; g_ui.modelOptions) {
                if (o.value == g_ui.currentModel) {
                    opt = o;
                    found = true;
                    break;
                }
            }
        }
        string hint = (found && opt.hint.length > 0)
            ? opt.hint
            : tr("Custom model (selected from local file).", "Пользовательская модель (выбрана из локального файла).");
        if (g_ui.lblModelHint !is null) {
            SetWindowTextW(g_ui.lblModelHint, (tr("Recommendation: ", "Рекомендация: ") ~ hint).toUTF16z());
        }
        if (g_ui.hwndTip !is null && g_ui.comboModel !is null) {
            string tip = found ? (opt.label ~ "\r\n" ~ hint) : hint;
            setTooltipText(g_ui.hwnd, g_ui.hwndTip, g_ui.comboModel, tip, false);
        }
    } catch (Throwable) {
    }
}

private extern (Windows) LRESULT comboListHoverProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow {
    LRESULT res = CallWindowProcW(g_origListProc, hwnd, msg, wParam, lParam);
    if (msg == WM_MOUSEMOVE) {
        int hovered = cast(int) CallWindowProcW(g_origListProc, hwnd, LB_GETCURSEL, 0, 0);
        if (hovered >= 0 && hovered < cast(int) g_ui.modelOptions.length && hovered != g_ui.lastHoveredModelIdx) {
            g_ui.lastHoveredModelIdx = hovered;
            refreshModelHint(hovered);
        }
    }
    return res;
}

private void installAllTooltips(HWND hwnd, bool add = true) {
    if (add && g_ui.hwndTip is null) {
        g_ui.hwndTip = CreateWindowExW(
            WS_EX_TOPMOST, TOOLTIPS_CLASS.toUTF16z(), null,
            WS_POPUP | TTS_ALWAYSTIP | TTS_NOPREFIX,
            CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT, CW_USEDEFAULT,
            hwnd, null, GetModuleHandleW(null), null
        );
        if (g_ui.hwndTip is null) return;
        SendMessageW(g_ui.hwndTip, TTM_SETMAXTIPWIDTH, 0, 360);
        SendMessageW(g_ui.hwndTip, TTM_SETDELAYTIME, TTDT_INITIAL, 350);
        SendMessageW(g_ui.hwndTip, TTM_SETDELAYTIME, TTDT_AUTOPOP, 15000);
    }
    if (g_ui.hwndTip is null) return;

    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnNavMain, tr(
        "Main page: status, model selection, and recognition log.",
        "Главная страница: статус, модель и журнал распознавания."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnNavSettings, tr(
        "Settings: microphone, language, hotkey, input mode, and theme.",
        "Настройки микрофона, языка, клавиши, ввода и темы."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnHide, tr(
        "Minimize window to the system tray (app keeps running).",
        "Свернуть окно в системный трей (программа продолжит работать)."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnModel, tr(
        "Load the selected model into RAM/VRAM or unload it to free memory.",
        "Загрузить выбранную модель в память (RAM/VRAM) или выгрузить её для освобождения памяти."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.comboModel, tr(
        "Select speech recognition model. Hover an item in the list to preview its recommendation below.",
        "Выбор нейросети распознавания. При наведении на пункт списка ниже показывается рекомендация."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnBrowseModel, tr(
        "Pick a local model: Whisper (.bin) or sherpa-onnx (.onnx / tokens.txt).",
        "Указать свою локальную модель: файл Whisper (.bin) или файл/папку sherpa-onnx (.onnx / tokens.txt)."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnCopyLast, tr(
        "Copy the last recognized phrase to the clipboard.",
        "Скопировать последнюю распознанную фразу в буфер обмена."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnClearLog, tr(
        "Clear the log text in this window.",
        "Очистить текстовый журнал работы в этом окне."
    ), add);

    setTooltipText(hwnd, g_ui.hwndTip, g_ui.comboMic, tr(
        "Choose recording microphone (Windows default device is used by default).",
        "Выбор микрофона для записи (по умолчанию используется устройство записи Windows)."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.comboLang, tr(
        "Expected speech language (for Whisper and some ONNX models; 'auto' detects automatically).",
        "Ожидаемый язык речи (для Whisper и части ONNX-моделей; «auto» определяет язык автоматически)."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnHotkey, tr(
        "Click and press any key or mouse button (MOUSE4/MOUSE5, etc.) to bind recording trigger.",
        "Нажмите и затем нажмите нужную клавишу или кнопку мыши (MOUSE4/MOUSE5 и др.) для записи."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.comboTimeout, tr(
        "Automatically unload model after idle minutes to save VRAM/RAM.",
        "Через сколько минут бездействия выгружать модель из памяти для экономии VRAM/RAM."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.comboInputMode, tr(
        "Per-character — for games/windows blocking Ctrl+V;\r\nClipboard — instant paste;\r\nAuto — <=80 chars per-character, longer via clipboard.",
        "Посимвольно — для игр и окон без Ctrl+V;\r\nБуфер обмена — мгновенная вставка;\r\nАвто — до 80 симв. посимвольно, длиннее через буфер."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.comboTheme, tr(
        "Window color theme: Auto (follow Windows), Light, or Dark.",
        "Выбор оформления окна: Авто (следует теме Windows), Светлая или Тёмная."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.comboUiLang, tr(
        "Select interface language (English or Russian).",
        "Выбор языка интерфейса программы (английский или русский)."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.chkAutoLoad, tr(
        "Automatically load the model when Shepot starts.",
        "Автоматически загружать модель при запуске Shepot."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.chkCpuOnly, tr(
        "Run Whisper on CPU instead of GPU (always disabled/checked for CPU-only engines).",
        "Запускать Whisper на процессоре вместо видеокарты (недоступно для движков без GPU)."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.chkStartTray, tr(
        "Start minimized to the system tray.",
        "Запускать программу сразу свёрнутой в системный трей."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.chkWinAuto, tr(
        "Launch Shepot automatically when signing in to Windows.",
        "Автоматически запускать Shepot при входе в Windows."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.chkLivePreview, tr(
        "Show live partial transcription inside the floating HUD while speaking.",
        "Показывать промежуточный текст в плавающем HUD-индикаторе прямо во время диктовки."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.chkOverlay, tr(
        "Small floating recording status indicator at the bottom of the screen.",
        "Небольшой плавающий индикатор статуса записи внизу экрана."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.chkToggleMode, tr(
        "Press once to start recording, press again to stop (instead of holding).",
        "Нажал — идёт запись, нажал повторно — остановка (вместо удержания кнопки)."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.chkOverwriteClip, tr(
        "When off: if clipboard has an image/files, text is typed per-character without losing clipboard.\r\nWhen on: always paste via Ctrl+V.",
        "Если выкл.: при наличии картинки/файлов в буфере обмена текст введётся посимвольно без потери картинки.\r\nЕсли вкл.: всегда вставлять через Ctrl+V."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnOpenReplacements, tr(
        "Open auto-replacements file bin/replacements.json (creates a template if missing).",
        "Открыть файл автозамен bin/replacements.json (создаёт шаблон при первом открытии)."
    ), add);
    setTooltipText(hwnd, g_ui.hwndTip, g_ui.btnOpenModelsDir, tr(
        "Open bin/models/ folder in File Explorer to add custom models.",
        "Открыть папку bin/models/ в Проводнике для добавления своих моделей."
    ), add);
}

void uiRefreshLanguage() {
    if (g_ui.hwnd is null) return;
    SetWindowTextW(g_ui.hwnd, tr("Shepot — Voice Dictation", "Shepot — Голосовой ввод").toUTF16z());
    SetWindowTextW(g_ui.btnNavMain, tr("Main", "Главная").toUTF16z());
    SetWindowTextW(g_ui.btnNavSettings, tr("Settings", "Настройки").toUTF16z());
    SetWindowTextW(g_ui.btnHide, tr("Hide to Tray", "Скрыть в трей").toUTF16z());
    applyModelButtonState(g_ui.modelLoaded, g_ui.modelLoading);
    SetWindowTextW(g_ui.lblModel, tr("Model:", "Модель:").toUTF16z());
    SetWindowTextW(g_ui.btnBrowseModel, tr("Browse...", "Обзор...").toUTF16z());
    SetWindowTextW(g_ui.lblLog, tr("Activity Log:", "Журнал работы:").toUTF16z());
    SetWindowTextW(g_ui.btnCopyLast, tr("Copy Last Phrase", "Копировать фразу").toUTF16z());
    SetWindowTextW(g_ui.btnClearLog, tr("Clear", "Очистить").toUTF16z());

    SetWindowTextW(g_ui.lblMic, tr("Microphone:", "Микрофон:").toUTF16z());
    SetWindowTextW(g_ui.lblLang, tr("Speech Language:", "Язык речи:").toUTF16z());
    SetWindowTextW(g_ui.lblHotkey, tr("Activation Hotkey:", "Клавиша активации:").toUTF16z());
    if (!g_ui.capturingHotkey) {
        SetWindowTextW(g_ui.btnHotkey, (tr("Assign: [", "Назначить: [") ~ g_ui.hotkeyName ~ "]").toUTF16z());
    }
    SetWindowTextW(g_ui.lblTimeout, tr("Auto-unload (memory):", "Автовыгрузка (память):").toUTF16z());
    SetWindowTextW(g_ui.lblInputMode, tr("Input Mode:", "Режим ввода:").toUTF16z());
    SetWindowTextW(g_ui.lblTheme, tr("Theme:", "Тема оформления:").toUTF16z());
    SetWindowTextW(g_ui.lblUiLang, tr("UI Language:", "Язык интерфейса:").toUTF16z());

    SetWindowTextW(g_ui.chkAutoLoad, tr("Auto-load model", "Автозагрузка модели").toUTF16z());
    SetWindowTextW(g_ui.chkCpuOnly, tr("CPU only", "Только на процессоре (CPU)").toUTF16z());
    SetWindowTextW(g_ui.chkStartTray, tr("Start minimized to tray", "Запускать в трее сразу").toUTF16z());
    SetWindowTextW(g_ui.chkWinAuto, tr("Run with Windows", "Запускать с Windows").toUTF16z());
    SetWindowTextW(g_ui.chkLivePreview, tr("Live preview in HUD", "Предпросмотр в HUD (Live)").toUTF16z());
    SetWindowTextW(g_ui.chkOverlay, tr("Floating indicator (HUD)", "Плавающий индикатор (HUD)").toUTF16z());
    SetWindowTextW(g_ui.chkToggleMode, tr("Toggle mode", "Режим переключения (Toggle)").toUTF16z());
    SetWindowTextW(g_ui.chkOverwriteClip, tr("Overwrite non-text clipboard", "Заменять нетекстовый буфер").toUTF16z());
    SetWindowTextW(g_ui.btnOpenReplacements, tr("Replacements (replacements.json)", "Словарь замен (replacements.json)").toUTF16z());
    SetWindowTextW(g_ui.btnOpenModelsDir, tr("Open models folder", "Открыть папку моделей").toUTF16z());

    populateMicCombo(g_ui.micNames, g_ui.currentMic);
    populateTimeoutCombo(g_ui.currentTimeoutMin);
    populateLocalizedCombo(g_ui.comboInputMode, inputModeOptions, g_ui.currentInputMode);
    populateLocalizedCombo(g_ui.comboTheme, themeOptions, g_ui.currentTheme);
    populateOptionCombo(g_ui.comboUiLang, cast(UiOption[]) uiLangOptions, getUiLanguage());
    refreshModelHint();
    installAllTooltips(g_ui.hwnd, false);

    if (g_ui.statusIsIdle && !g_ui.isDown && !g_ui.modelLoading) {
        uiSetIdleStatus(g_ui.modelLoaded);
    }
    RedrawWindow(g_ui.hwnd, null, null, RDW_INVALIDATE | RDW_ERASE | RDW_ALLCHILDREN);
}

private void installDarkButtonSubclass(HWND ctrl) {
    if (ctrl is null) return;
    auto prev = cast(WNDPROC) SetWindowLongPtrW(ctrl, GWLP_WNDPROC, cast(LONG_PTR) &darkButtonProc);
    if (g_origBtnProc is null) g_origBtnProc = prev;
}

private extern (Windows) LRESULT windowProc(HWND hwnd, UINT msg, WPARAM wParam, LPARAM lParam) nothrow {
    try {
        switch (msg) {
            case WM_CREATE:
                auto hInst = GetModuleHandleW(null);
                g_ui.fontTitle = makeFont("Segoe UI", -17, FW_SEMIBOLD);
                g_ui.fontBtnBold = makeFont("Segoe UI", -15, FW_SEMIBOLD);
                g_ui.fontUi = makeFont("Segoe UI", -14, FW_NORMAL);
                g_ui.fontHint = makeFont("Segoe UI", -12, FW_NORMAL);
                g_ui.fontMono = makeFont("Consolas", -13, FW_NORMAL);
                g_ui.darkBgBrush = CreateSolidBrush(RGB(24, 24, 27));
                g_ui.darkEditBrush = CreateSolidBrush(RGB(15, 15, 18));
                g_ui.darkSurfaceBrush = CreateSolidBrush(RGB(32, 32, 37));

                g_ui.btnNavMain = CreateWindowExW(0, "BUTTON"w.ptr, tr("Main", "Главная").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON | BS_PUSHLIKE | WS_GROUP,
                    0, 0, 0, 0, hwnd, cast(HMENU) cast(size_t) ID_NAV_MAIN, hInst, null);
                g_ui.btnNavSettings = CreateWindowExW(0, "BUTTON"w.ptr, tr("Settings", "Настройки").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTORADIOBUTTON | BS_PUSHLIKE,
                    0, 0, 0, 0, hwnd, cast(HMENU) cast(size_t) ID_NAV_SETTINGS, hInst, null);
                g_ui.lblStatus = CreateWindowExW(0, "STATIC"w.ptr, tr("Initializing...", "Инициализация...").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | SS_ENDELLIPSIS, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.btnHide = CreateWindowExW(0, "BUTTON"w.ptr, tr("Hide to Tray", "Скрыть в трей").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_HIDE, hInst, null);
                g_ui.btnModel = CreateWindowExW(0, "BUTTON"w.ptr, tr("Load model", "Загрузить модель").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_MODEL, hInst, null);
                g_ui.progressBar = CreateWindowExW(0, PROGRESS_CLASS.toUTF16z(), ""w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_PROGRESS, hInst, null);
                SendMessageW(g_ui.progressBar, PBM_SETRANGE, 0, 100 << 16);

                g_ui.lblMic = CreateWindowExW(0, "STATIC"w.ptr, tr("Microphone:", "Микрофон:").toUTF16z(),
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboMic = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_MIC, hInst, null);

                g_ui.lblModel = CreateWindowExW(0, "STATIC"w.ptr, tr("Model:", "Модель:").toUTF16z(),
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboModel = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_MODEL, hInst, null);
                g_ui.btnBrowseModel = CreateWindowExW(0, "BUTTON"w.ptr, tr("Browse...", "Обзор...").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_BROWSE_MODEL, hInst, null);
                g_ui.lblModelHint = CreateWindowExW(0, "STATIC"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);

                g_ui.lblLang = CreateWindowExW(0, "STATIC"w.ptr, tr("Speech Language:", "Язык речи:").toUTF16z(),
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboLang = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_LANG, hInst, null);

                g_ui.lblHotkey = CreateWindowExW(0, "STATIC"w.ptr, tr("Activation Hotkey:", "Клавиша активации:").toUTF16z(),
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.btnHotkey = CreateWindowExW(0, "BUTTON"w.ptr, tr("Assign: [F9]", "Назначить: [F9]").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_HOTKEY, hInst, null);

                g_ui.lblTimeout = CreateWindowExW(0, "STATIC"w.ptr, tr("Auto-unload (memory):", "Автовыгрузка (память):").toUTF16z(),
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboTimeout = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_TIMEOUT, hInst, null);

                g_ui.lblInputMode = CreateWindowExW(0, "STATIC"w.ptr, tr("Input Mode:", "Режим ввода:").toUTF16z(),
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboInputMode = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_INPUT_MODE, hInst, null);

                g_ui.lblTheme = CreateWindowExW(0, "STATIC"w.ptr, tr("Theme:", "Тема оформления:").toUTF16z(),
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboTheme = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_THEME, hInst, null);

                g_ui.lblUiLang = CreateWindowExW(0, "STATIC"w.ptr, tr("UI Language:", "Язык интерфейса:").toUTF16z(),
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.comboUiLang = CreateWindowExW(0, "COMBOBOX"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | CBS_DROPDOWNLIST | WS_VSCROLL, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_COMBO_UI_LANG, hInst, null);

                g_ui.chkAutoLoad = CreateWindowExW(0, "BUTTON"w.ptr, tr("Auto-load model", "Автозагрузка модели").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_AUTOLOAD, hInst, null);
                g_ui.chkCpuOnly = CreateWindowExW(0, "BUTTON"w.ptr, tr("CPU only", "Только на процессоре (CPU)").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_CPU_ONLY, hInst, null);
                g_ui.chkStartTray = CreateWindowExW(0, "BUTTON"w.ptr, tr("Start minimized to tray", "Запускать в трее сразу").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_START_TRAY, hInst, null);
                g_ui.chkWinAuto = CreateWindowExW(0, "BUTTON"w.ptr, tr("Run with Windows", "Запускать с Windows").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_WIN_AUTO, hInst, null);
                g_ui.chkLivePreview = CreateWindowExW(0, "BUTTON"w.ptr, tr("Live preview in HUD", "Предпросмотр в HUD (Live)").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_LIVE_PREVIEW, hInst, null);
                g_ui.chkOverlay = CreateWindowExW(0, "BUTTON"w.ptr, tr("Floating indicator (HUD)", "Плавающий индикатор (HUD)").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_OVERLAY, hInst, null);
                g_ui.chkToggleMode = CreateWindowExW(0, "BUTTON"w.ptr, tr("Toggle mode", "Режим переключения (Toggle)").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_TOGGLE_MODE, hInst, null);
                g_ui.chkOverwriteClip = CreateWindowExW(0, "BUTTON"w.ptr, tr("Overwrite non-text clipboard", "Заменять нетекстовый буфер").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_AUTOCHECKBOX, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_CHK_OVERWRITE_CLIP, hInst, null);

                g_ui.btnOpenReplacements = CreateWindowExW(0, "BUTTON"w.ptr, tr("Replacements (replacements.json)", "Словарь замен (replacements.json)").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_OPEN_REPL, hInst, null);
                g_ui.btnOpenModelsDir = CreateWindowExW(0, "BUTTON"w.ptr, tr("Open models folder", "Открыть папку моделей").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_OPEN_MODELS, hInst, null);

                g_ui.lblLog = CreateWindowExW(0, "STATIC"w.ptr, tr("Activity Log:", "Журнал работы:").toUTF16z(),
                    WS_CHILD | WS_VISIBLE, 0, 0, 0, 0, hwnd, null, hInst, null);
                g_ui.btnCopyLast = CreateWindowExW(0, "BUTTON"w.ptr, tr("Copy Last Phrase", "Копировать фразу").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_COPY_LAST, hInst, null);
                EnableWindow(g_ui.btnCopyLast, FALSE);
                g_ui.btnClearLog = CreateWindowExW(0, "BUTTON"w.ptr, tr("Clear", "Очистить").toUTF16z(),
                    WS_CHILD | WS_VISIBLE | BS_PUSHBUTTON, 0, 0, 0, 0,
                    hwnd, cast(HMENU) cast(size_t) ID_BTN_CLEAR_LOG, hInst, null);
                g_ui.editLog = CreateWindowExW(WS_EX_CLIENTEDGE, "EDIT"w.ptr, ""w.ptr,
                    WS_CHILD | WS_VISIBLE | WS_VSCROLL | ES_MULTILINE | ES_AUTOVSCROLL | ES_READONLY,
                    0, 0, 0, 0, hwnd, cast(HMENU) cast(size_t) ID_EDIT_LOG, hInst, null);

                SendMessageW(g_ui.lblStatus, WM_SETFONT, cast(WPARAM) g_ui.fontTitle, TRUE);
                SendMessageW(g_ui.btnModel, WM_SETFONT, cast(WPARAM) g_ui.fontBtnBold, TRUE);
                foreach (ctrl; [
                    g_ui.btnNavMain, g_ui.btnNavSettings,
                    g_ui.btnHide, g_ui.lblMic, g_ui.comboMic, g_ui.lblModel, g_ui.comboModel,
                    g_ui.btnBrowseModel, g_ui.lblLang, g_ui.comboLang, g_ui.lblHotkey, g_ui.btnHotkey,
                    g_ui.lblTimeout, g_ui.comboTimeout, g_ui.lblInputMode, g_ui.comboInputMode,
                    g_ui.lblTheme, g_ui.comboTheme, g_ui.lblUiLang, g_ui.comboUiLang,
                    g_ui.chkAutoLoad, g_ui.chkCpuOnly,
                    g_ui.chkStartTray, g_ui.chkWinAuto, g_ui.chkLivePreview, g_ui.chkOverlay,
                    g_ui.chkToggleMode, g_ui.chkOverwriteClip,
                    g_ui.btnOpenReplacements, g_ui.btnOpenModelsDir,
                    g_ui.lblLog, g_ui.btnCopyLast, g_ui.btnClearLog
                ]) {
                    SendMessageW(ctrl, WM_SETFONT, cast(WPARAM) g_ui.fontUi, TRUE);
                }
                SendMessageW(g_ui.lblModelHint, WM_SETFONT, cast(WPARAM) g_ui.fontHint, TRUE);
                SendMessageW(g_ui.editLog, WM_SETFONT, cast(WPARAM) g_ui.fontMono, TRUE);

                COMBOBOXINFO cbi;
                cbi.cbSize = COMBOBOXINFO.sizeof;
                if (GetComboBoxInfo(g_ui.comboModel, &cbi) && cbi.hwndList !is null) {
                    g_ui.comboModelList = cbi.hwndList;
                    g_origListProc = cast(WNDPROC) SetWindowLongPtrW(cbi.hwndList, GWLP_WNDPROC, cast(LONG_PTR) &comboListHoverProc);
                }
                installAllTooltips(hwnd);
                foreach (c; [
                    g_ui.btnNavMain, g_ui.btnNavSettings,
                    g_ui.chkAutoLoad, g_ui.chkCpuOnly, g_ui.chkStartTray, g_ui.chkWinAuto,
                    g_ui.chkLivePreview, g_ui.chkOverlay, g_ui.chkToggleMode, g_ui.chkOverwriteClip,
                ]) {
                    installDarkButtonSubclass(c);
                }

                RECT rc;
                GetClientRect(hwnd, &rc);
                layoutChildren(rc.right - rc.left, rc.bottom - rc.top);
                addTrayIcon(hwnd);
                SetTimer(hwnd, ID_TIMER_IDLE, 5000, null);
                SetTimer(hwnd, ID_TIMER_PREVIEW, 1100, null);
                return 0;

            case WM_ERASEBKGND:
                if (g_ui.darkActive && g_ui.darkBgBrush !is null) {
                    RECT bgRc;
                    GetClientRect(hwnd, &bgRc);
                    FillRect(cast(HDC) wParam, &bgRc, g_ui.darkBgBrush);
                    return 1;
                }
                break;

            case WM_CTLCOLORSTATIC:
                auto hdc = cast(HDC) wParam;
                if (cast(HWND) lParam == g_ui.editLog) {
                    if (g_ui.darkActive && g_ui.darkEditBrush !is null) {
                        SetTextColor(hdc, RGB(236, 236, 240));
                        SetBkColor(hdc, RGB(15, 15, 18));
                        return cast(LRESULT) g_ui.darkEditBrush;
                    }
                    SetTextColor(hdc, RGB(24, 28, 36));
                    SetBkColor(hdc, RGB(255, 255, 255));
                    return cast(LRESULT) GetSysColorBrush(COLOR_WINDOW);
                }
                SetBkMode(hdc, TRANSPARENT);
                if (g_ui.darkActive && g_ui.darkBgBrush !is null) {
                    COLORREF fg = RGB(228, 228, 234);
                    if (cast(HWND) lParam == g_ui.lblStatus) fg = RGB(250, 250, 252);
                    else if (cast(HWND) lParam == g_ui.lblModelHint) fg = RGB(162, 168, 180);
                    SetTextColor(hdc, fg);
                    return cast(LRESULT) g_ui.darkBgBrush;
                }
                if (cast(HWND) lParam == g_ui.lblStatus) {
                    SetTextColor(hdc, RGB(24, 34, 56));
                } else if (cast(HWND) lParam == g_ui.lblModelHint) {
                    SetTextColor(hdc, RGB(82, 92, 108));
                }
                return cast(LRESULT) GetSysColorBrush(COLOR_BTNFACE);

            case WM_CTLCOLOREDIT:
            case WM_CTLCOLORLISTBOX:
                if (g_ui.darkActive && g_ui.darkSurfaceBrush !is null) {
                    auto hdc = cast(HDC) wParam;
                    SetTextColor(hdc, RGB(240, 240, 244));
                    SetBkColor(hdc, RGB(32, 32, 37));
                    return cast(LRESULT) g_ui.darkSurfaceBrush;
                }
                break;

            case WM_CTLCOLORBTN:
                if (g_ui.darkActive && g_ui.darkBgBrush !is null) {
                    return cast(LRESULT) g_ui.darkBgBrush;
                }
                break;

            case WM_WININICHANGE:
                if (g_ui.currentTheme == "auto") {
                    applyWindowTheme(hwnd);
                }
                return 0;

            case WM_GETMINMAXINFO:
                auto mmi = cast(MINMAXINFO*) lParam;
                mmi.ptMinTrackSize.x = 500;
                mmi.ptMinTrackSize.y = 500;
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
                    g_ui.nid.hIcon = idleTrayIcon();
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
                if (id == ID_NAV_MAIN) {
                    setActivePage(0);
                } else if (id == ID_NAV_SETTINGS) {
                    setActivePage(1);
                } else if (id == ID_BTN_HIDE || id == ID_TRAY_TOGGLE) {
                    toggleWindowVisibility(hwnd);
                } else if (id == ID_BTN_MODEL || id == ID_TRAY_MODEL_TOGGLE) {
                    if (g_ui.onModelToggle !is null) g_ui.onModelToggle();
                } else if (id == ID_BTN_BROWSE_MODEL || id == ID_TRAY_BROWSE_MODEL) {
                    openCustomModelDialog(hwnd);
                } else if (id == ID_BTN_CLEAR_LOG) {
                    SetWindowTextW(g_ui.editLog, ""w.ptr);
                } else if (id == ID_BTN_OPEN_REPL) {
                    openReplacementsFile(hwnd);
                } else if (id == ID_BTN_OPEN_MODELS) {
                    openModelsDir(hwnd);
                } else if (id == ID_BTN_HOTKEY || id == ID_TRAY_HOTKEY) {
                    g_ui.capturingHotkey = true;
                    SetWindowTextW(g_ui.btnHotkey, tr(
                        "Press any key or mouse button (Esc to cancel)...",
                        "Нажмите клавишу или кнопку мыши (Esc — отмена)..."
                    ).toUTF16z());
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
                } else if (id == ID_TRAY_OVERWRITE_CLIP) {
                    applyOverwriteClip(!g_ui.overwriteNonTextClip);
                } else if (id == ID_TRAY_COPY_LAST || id == ID_BTN_COPY_LAST) {
                    if (copyTextToClipboard(g_ui.lastPhrase)) {
                        uiLog(tr("[CLIP] Copied last phrase: ", "[CLIP] Скопирована последняя фраза: ") ~ g_ui.lastPhrase);
                        uiSetVisual(VisualState.pasted, tr("Copied to clipboard", "Скопировано в буфер"), 900);
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
                } else if (id >= ID_TRAY_INPUT_MODE_BASE && id < ID_TRAY_THEME_BASE) {
                    applyInputModeSelection(id - ID_TRAY_INPUT_MODE_BASE);
                } else if (id >= ID_TRAY_THEME_BASE && id < ID_TRAY_THEME_BASE + 100) {
                    applyThemeSelection(id - ID_TRAY_THEME_BASE);
                } else if (id >= ID_TRAY_UI_LANG_BASE && id < ID_TRAY_UI_LANG_BASE + 100) {
                    applyUiLangSelection(id - ID_TRAY_UI_LANG_BASE);
                } else if (id == ID_COMBO_MIC && code == CBN_SELCHANGE) {
                    int sel = cast(int) SendMessageW(g_ui.comboMic, CB_GETCURSEL, 0, 0);
                    applyMicSelection(sel <= 0 ? -1 : sel - 1);
                } else if (id == ID_COMBO_MODEL && code == CBN_SELCHANGE) {
                    g_ui.lastHoveredModelIdx = -1;
                    applyModelSelection(cast(int) SendMessageW(g_ui.comboModel, CB_GETCURSEL, 0, 0));
                } else if (id == ID_COMBO_MODEL && code == CBN_CLOSEUP) {
                    g_ui.lastHoveredModelIdx = -1;
                    refreshModelHint();
                } else if (id == ID_COMBO_LANG && code == CBN_SELCHANGE) {
                    applyLangSelection(cast(int) SendMessageW(g_ui.comboLang, CB_GETCURSEL, 0, 0));
                } else if (id == ID_COMBO_TIMEOUT && code == CBN_SELCHANGE) {
                    applyTimeoutSelection(cast(int) SendMessageW(g_ui.comboTimeout, CB_GETCURSEL, 0, 0));
                } else if (id == ID_COMBO_INPUT_MODE && code == CBN_SELCHANGE) {
                    applyInputModeSelection(cast(int) SendMessageW(g_ui.comboInputMode, CB_GETCURSEL, 0, 0));
                } else if (id == ID_COMBO_THEME && code == CBN_SELCHANGE) {
                    applyThemeSelection(cast(int) SendMessageW(g_ui.comboTheme, CB_GETCURSEL, 0, 0));
                } else if (id == ID_COMBO_UI_LANG && code == CBN_SELCHANGE) {
                    applyUiLangSelection(cast(int) SendMessageW(g_ui.comboUiLang, CB_GETCURSEL, 0, 0));
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
                } else if (id == ID_CHK_OVERWRITE_CLIP) {
                    applyOverwriteClip(SendMessageW(g_ui.chkOverwriteClip, BM_GETCHECK, 0, 0) == BST_CHECKED);
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

            case WM_APP_HOOK_START:
                if (g_ui.onStart !is null) g_ui.onStart();
                return 0;

            case WM_APP_HOOK_STOP:
                if (g_ui.onStop !is null) g_ui.onStop();
                return 0;

            case WM_APP_HOOK_CANCEL:
                if (g_ui.onCancel !is null) g_ui.onCancel();
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
                foreach (f; [g_ui.fontTitle, g_ui.fontBtnBold, g_ui.fontUi, g_ui.fontHint, g_ui.fontMono]) {
                    if (f !is null) DeleteObject(f);
                }
                foreach (br; [g_ui.darkBgBrush, g_ui.darkEditBrush, g_ui.darkSurfaceBrush]) {
                    if (br !is null) DeleteObject(br);
                }
                foreach (ic; [g_ui.iconBig, g_ui.iconSmall, g_ui.iconUnloaded, g_ui.iconRec, g_ui.iconProc, g_ui.iconPasted]) {
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
                SetWindowTextW(g_ui.btnHotkey, (tr("Assign: [", "Назначить: [") ~ g_ui.hotkeyName ~ "]").toUTF16z());
                uiSetIdleStatus(g_ui.modelLoaded);
            }
            return true;
        }

        if (g_ui.isDown && !isMouse && vk == VK_ESCAPE && isDownMsg) {
            g_ui.isDown = false;
            if (!g_ui.toggleMode) g_ui.waitRelease = true;
            if (g_ui.hwnd !is null) PostMessageW(g_ui.hwnd, WM_APP_HOOK_CANCEL, 0, 0);
            return true;
        }

        if (vk == g_ui.hotkeyVk) {
            if (g_ui.toggleMode) {
                if (isDownMsg && !g_ui.keyPhysicallyDown) {
                    g_ui.keyPhysicallyDown = true;
                    if (!g_ui.isDown) {
                        g_ui.isDown = true;
                        if (g_ui.hwnd !is null) PostMessageW(g_ui.hwnd, WM_APP_HOOK_START, 0, 0);
                    } else {
                        g_ui.isDown = false;
                        if (g_ui.hwnd !is null) PostMessageW(g_ui.hwnd, WM_APP_HOOK_STOP, 0, 0);
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
                if (g_ui.hwnd !is null) PostMessageW(g_ui.hwnd, WM_APP_HOOK_START, 0, 0);
            } else if (isUpMsg && g_ui.isDown) {
                g_ui.isDown = false;
                if (g_ui.hwnd !is null) PostMessageW(g_ui.hwnd, WM_APP_HOOK_STOP, 0, 0);
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
