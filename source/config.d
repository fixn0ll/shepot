module config;

import std.conv : to;
import std.file : exists, readText, thisExePath, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : buildPath, dirName, isAbsolute;
import std.string : strip, toUpper;

struct AppConfig {
    string whisperDll = "whisper.dll";
    string modelPath = "models/ggml-large-v3-turbo-q5_0.bin";
    string language = "ru";
    int threads = 4;
    bool useGpu = true;
    bool autoLoadModel = true;
    int unloadTimeoutMin = 5;
    string hotkey = "F9";
    bool blockHotkey = true;
    bool toggleMode = false;
    string initialPrompt = "";
    int micDevice = -1;
    double minDurationSec = 0.3;
    double rmsThreshold = 0.0015;
    string inputMode = "sendinput";
    int charDelayMs = 3;
    int clipboardRestoreDelayMs = 120;
    bool beep = true;
    bool showOverlay = true;
    bool livePreview = true;
    bool startMinimized = false;
}

string normalizeInputMode(string mode) {
    import std.string : toLower;
    auto m = mode.strip().toLower();
    if (m == "clipboard" || m == "auto" || m == "sendinput") return m;
    return "sendinput";
}

private struct HotkeyEntry {
    string name;
    uint vk;
}

private static immutable HotkeyEntry[] hotkeyTable = [
    HotkeyEntry("MOUSE3", 0x04),
    HotkeyEntry("MOUSE4", 0x05),
    HotkeyEntry("MOUSE5", 0x06),
    HotkeyEntry("MBUTTON", 0x04),
    HotkeyEntry("XBUTTON1", 0x05),
    HotkeyEntry("XBUTTON2", 0x06),
    HotkeyEntry("F1", 0x70),
    HotkeyEntry("F2", 0x71),
    HotkeyEntry("F3", 0x72),
    HotkeyEntry("F4", 0x73),
    HotkeyEntry("F5", 0x74),
    HotkeyEntry("F6", 0x75),
    HotkeyEntry("F7", 0x76),
    HotkeyEntry("F8", 0x77),
    HotkeyEntry("F9", 0x78),
    HotkeyEntry("F10", 0x79),
    HotkeyEntry("F11", 0x7A),
    HotkeyEntry("F12", 0x7B),
    HotkeyEntry("PAUSE", 0x13),
    HotkeyEntry("CAPSLOCK", 0x14),
    HotkeyEntry("CAPS", 0x14),
    HotkeyEntry("SPACE", 0x20),
    HotkeyEntry("INSERT", 0x2D),
    HotkeyEntry("DELETE", 0x2E),
    HotkeyEntry("HOME", 0x24),
    HotkeyEntry("END", 0x23),
    HotkeyEntry("PGUP", 0x21),
    HotkeyEntry("PGDN", 0x22),
    HotkeyEntry("TAB", 0x09),
    HotkeyEntry("SCROLLLOCK", 0x91),
    HotkeyEntry("SCROLL", 0x91),
    HotkeyEntry("LSHIFT", 0xA0),
    HotkeyEntry("RSHIFT", 0xA1),
    HotkeyEntry("LCTRL", 0xA2),
    HotkeyEntry("RCTRL", 0xA3),
    HotkeyEntry("LALT", 0xA4),
    HotkeyEntry("RALT", 0xA5),
    HotkeyEntry("TILDE", 0xC0),
];

string exeDir() {
    return dirName(thisExePath());
}

string resolvePath(string p) {
    if (p.length == 0 || isAbsolute(p)) return p;
    auto nearExe = buildPath(exeDir(), p);
    if (exists(nearExe)) return nearExe;
    if (exists(p)) return p;
    return nearExe;
}

AppConfig loadConfig() {
    auto path = resolvePath("config.json");
    if (!exists(path)) return AppConfig.init;
    return parseConfigJson(readText(path));
}

bool saveConfig(const ref AppConfig cfg) {
    auto path = resolvePath("config.json");
    try {
        write(path, serializeConfigJson(cfg) ~ "\n");
        return true;
    } catch (Exception) {
        return false;
    }
}

string serializeConfigJson(const ref AppConfig cfg) {
    JSONValue root = JSONValue.emptyObject;
    root["whisperDll"] = cfg.whisperDll;
    root["modelPath"] = cfg.modelPath;
    root["language"] = cfg.language;
    root["threads"] = cfg.threads;
    root["useGpu"] = cfg.useGpu;
    root["autoLoadModel"] = cfg.autoLoadModel;
    root["unloadTimeoutMin"] = cfg.unloadTimeoutMin;
    root["hotkey"] = cfg.hotkey;
    root["blockHotkey"] = cfg.blockHotkey;
    root["toggleMode"] = cfg.toggleMode;
    root["initialPrompt"] = cfg.initialPrompt;
    root["micDevice"] = cfg.micDevice;
    root["minDurationSec"] = cfg.minDurationSec;
    root["rmsThreshold"] = cfg.rmsThreshold;
    root["inputMode"] = normalizeInputMode(cfg.inputMode);
    root["charDelayMs"] = cfg.charDelayMs;
    root["clipboardRestoreDelayMs"] = cfg.clipboardRestoreDelayMs;
    root["beep"] = cfg.beep;
    root["showOverlay"] = cfg.showOverlay;
    root["livePreview"] = cfg.livePreview;
    root["startMinimized"] = cfg.startMinimized;
    return root.toPrettyString();
}

AppConfig parseConfigJson(string content) {
    AppConfig cfg;
    auto root = parseJSON(content);
    if (root.type != JSONType.object) return cfg;

    void str(string key, ref string dst) {
        if (auto p = key in root) {
            if (p.type == JSONType.string) dst = p.str;
        }
    }
    void integer(string key, ref int dst) {
        if (auto p = key in root) {
            if (p.type == JSONType.integer) dst = cast(int) p.integer;
        }
    }
    void floating(string key, ref double dst) {
        if (auto p = key in root) {
            if (p.type == JSONType.float_) dst = p.floating;
            else if (p.type == JSONType.integer) dst = cast(double) p.integer;
        }
    }
    void boolean(string key, ref bool dst) {
        if (auto p = key in root) {
            if (p.type == JSONType.true_) dst = true;
            else if (p.type == JSONType.false_) dst = false;
        }
    }

    str("whisperDll", cfg.whisperDll);
    str("modelPath", cfg.modelPath);
    str("language", cfg.language);
    integer("threads", cfg.threads);
    boolean("useGpu", cfg.useGpu);
    boolean("autoLoadModel", cfg.autoLoadModel);
    integer("unloadTimeoutMin", cfg.unloadTimeoutMin);
    str("hotkey", cfg.hotkey);
    boolean("blockHotkey", cfg.blockHotkey);
    boolean("toggleMode", cfg.toggleMode);
    str("initialPrompt", cfg.initialPrompt);
    integer("micDevice", cfg.micDevice);
    floating("minDurationSec", cfg.minDurationSec);
    floating("rmsThreshold", cfg.rmsThreshold);

    if (auto pMode = "inputMode" in root) {
        if (pMode.type == JSONType.string) cfg.inputMode = normalizeInputMode(pMode.str);
    } else {
        bool legacyPaste = false;
        if (auto pLegacy = "pasteViaClipboard" in root) {
            if (pLegacy.type == JSONType.true_) cfg.inputMode = "clipboard";
            else if (pLegacy.type == JSONType.false_) cfg.inputMode = "sendinput";
            else if (legacyPaste) cfg.inputMode = "clipboard";
        }
    }

    integer("charDelayMs", cfg.charDelayMs);
    if (cfg.charDelayMs < 0) cfg.charDelayMs = 0;
    integer("clipboardRestoreDelayMs", cfg.clipboardRestoreDelayMs);
    boolean("beep", cfg.beep);
    boolean("showOverlay", cfg.showOverlay);
    boolean("livePreview", cfg.livePreview);
    boolean("startMinimized", cfg.startMinimized);
    return cfg;
}

/// Преобразует имя клавиши или кнопки мыши (например "F9", "MOUSE4", "0x78") в Windows VK-код.
uint parseHotkeyVk(string name) {
    auto k = name.strip().toUpper();
    if (k.length == 0) return 0x78; // VK_F9

    if (k.length > 2 && k[0 .. 2] == "0X") {
        return to!uint(k[2 .. $], 16);
    }

    if (k.length == 1) {
        char c = k[0];
        if ((c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
            return cast(uint) c;
        }
    }

    foreach (entry; hotkeyTable) {
        if (entry.name == k) return entry.vk;
    }
    return 0x78;
}

/// Преобразует Windows VK-код в читаемое имя клавиши/кнопки мыши.
string vkToKeyName(uint vk) {
    foreach (entry; hotkeyTable) {
        if (entry.vk == vk) return entry.name;
    }
    if ((vk >= 'A' && vk <= 'Z') || (vk >= '0' && vk <= '9')) {
        char[1] buf = [cast(char) vk];
        return buf[].idup;
    }
    return format("0x%02X", vk);
}

unittest {
    auto cfg = parseConfigJson(`{"language":"en","threads":8,"useGpu":false,"autoLoadModel":false,"unloadTimeoutMin":15,"hotkey":"MOUSE4","blockHotkey":false,"toggleMode":true,"initialPrompt":"Термины: D, Whisper","inputMode":"auto","charDelayMs":5,"minDurationSec":0.5}`);
    assert(cfg.language == "en");
    assert(cfg.threads == 8);
    assert(!cfg.useGpu);
    assert(!cfg.autoLoadModel);
    assert(cfg.unloadTimeoutMin == 15);
    assert(cfg.hotkey == "MOUSE4");
    assert(!cfg.blockHotkey);
    assert(cfg.toggleMode);
    assert(cfg.initialPrompt == "Термины: D, Whisper");
    assert(cfg.inputMode == "auto");
    assert(cfg.charDelayMs == 5);

    auto legacy = parseConfigJson(`{"pasteViaClipboard":true,"charDelayMs":-2}`);
    assert(legacy.inputMode == "clipboard");
    assert(legacy.charDelayMs == 0);
    assert(legacy.blockHotkey);
    assert(!legacy.toggleMode);

    auto rt = parseConfigJson(serializeConfigJson(cfg));
    assert(!rt.autoLoadModel && rt.unloadTimeoutMin == 15 && rt.hotkey == "MOUSE4");
    assert(!rt.blockHotkey && rt.toggleMode && rt.initialPrompt == "Термины: D, Whisper");
    assert(rt.inputMode == "auto" && rt.charDelayMs == 5);

    assert(parseHotkeyVk("F9") == 0x78);
    assert(parseHotkeyVk("mouse4") == 0x05);
    assert(parseHotkeyVk("xbutton2") == 0x06);
    assert(parseHotkeyVk("rctrl") == 0xA3);
    assert(vkToKeyName(0x04) == "MOUSE3");
    assert(vkToKeyName(0x05) == "MOUSE4");
    assert(vkToKeyName(0x78) == "F9");
    assert(parseHotkeyVk(vkToKeyName(0xDC)) == 0xDC);
}
