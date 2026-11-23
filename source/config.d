module config;

import std.algorithm.searching : canFind, endsWith;
import std.conv : to;
import std.file : dirEntries, exists, isDir, readText, SpanMode, thisExePath, write;
import std.format : format;
import std.json : JSONType, JSONValue, parseJSON;
import std.path : baseName, buildNormalizedPath, buildPath, dirName, isAbsolute;
import std.array : replace;
import std.string : strip, toLower, toUpper;

struct AppConfig {
    string engine = "whisper";
    string whisperDll = "whisper.dll";
    string modelPath = "models/ggml-large-v3-turbo-q5_0.bin";
    string sherpaDll = "sherpa-onnx-c-api.dll";
    string sherpaModelType = "nemo_transducer";
    string sherpaEncoder = "";
    string sherpaDecoder = "";
    string sherpaJoiner = "";
    string sherpaCtcModel = "";
    string sherpaTokens = "";
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
    bool overwriteNonTextClipboard = false;
    string theme = "auto";
    bool beep = true;
    bool showOverlay = true;
    bool livePreview = true;
    bool startMinimized = false;
}

string normalizeEngine(string engine) {
    import std.string : toLower;
    auto e = engine.strip().toLower();
    if (e == "sherpa" || e == "sherpa-onnx" || e == "gigaam") return "sherpa";
    return "whisper";
}

struct ModelPresetInfo {
    string id;
    string label;
    string hint;
}

static immutable ModelPresetInfo[] builtinModelPresets = [
    ModelPresetInfo(
        "sherpa:gigaam-v3-punct",
        "GigaAM v3 RNN-T Punct (RU + пунктуация, CPU)",
        "Лучший выбор для русского языка на CPU: быстрая, точная, сама расставляет знаки препинания. Видеокарту не использует."
    ),
    ModelPresetInfo(
        "sherpa:gigaam-multilingual",
        "GigaAM Multilingual CTC (RU + EN, CPU)",
        "Для смешанной речи (русский + английские термины) на CPU без пунктуации. Хороша для программирования и заметок."
    ),
    ModelPresetInfo(
        "whisper:models/ggml-tiny.bin",
        "Whisper tiny (~75 МБ, сверхбыстрая)",
        "Сверхлёгкая модель для слабых ПК и тестов без видеокарты: минимальная точность, но мгновенная работа на CPU."
    ),
    ModelPresetInfo(
        "whisper:models/ggml-base.bin",
        "Whisper base (~142 МБ, быстрая)",
        "Базовая лёгкая модель для простых фраз на ноутбуках и CPU; сложные термины распознаёт хуже старших версий."
    ),
    ModelPresetInfo(
        "whisper:models/ggml-small-q5_1.bin",
        "Whisper small-q5_1 (~182 МБ, лёгкая для CPU)",
        "Хороший вариант для слабого GPU или CPU: заметно точнее tiny/base при умеренном расходе памяти."
    ),
    ModelPresetInfo(
        "whisper:models/ggml-medium-q5_0.bin",
        "Whisper medium-q5_0 (~515 МБ, баланс)",
        "Универсальный баланс для разных языков (RU/EN и др.): подходит для видеокарты от 2 ГБ VRAM или мощного CPU."
    ),
    ModelPresetInfo(
        "whisper:models/ggml-large-v3-turbo-q5_0.bin",
        "Whisper large-v3-turbo-q5_0 (~547 МБ, GPU)",
        "Рекомендуется для видеокарты (Vulkan GPU): высокая скорость и отличное качество на русском, английском и смешанной речи."
    ),
    ModelPresetInfo(
        "whisper:models/ggml-large-v3-turbo-q8_0.bin",
        "Whisper large-v3-turbo-q8_0 (~834 МБ, макс.)",
        "Максимальная точность Whisper: для сложной диктовки, акцентов и редких терминов при наличии видеокарты от 4 ГБ VRAM."
    ),
];

/// Возвращает рекомендацию и описание назначения модели по её идентификатору.
string modelRecommendation(string optId) {
    foreach (p; builtinModelPresets) {
        if (p.id == optId) return p.hint;
    }
    return "Пользовательская локальная модель (выбрана через «Обзор...» или config.json).";
}

private enum string GigaV3Dir = "models/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16";
private enum string GigaMultiDir = "models/gigaam-multilingual-ctc-int8";

/// Возвращает идентификатор выбранного пресета модели для UI.
string modelOptionId(const ref AppConfig cfg) {
    if (normalizeEngine(cfg.engine) == "sherpa") {
        if (cfg.sherpaEncoder == GigaV3Dir ~ "/encoder.int8.onnx") return "sherpa:gigaam-v3-punct";
        if (cfg.sherpaCtcModel == GigaMultiDir ~ "/model.int8.onnx") return "sherpa:gigaam-multilingual";
        return "sherpa:custom";
    }
    return "whisper:" ~ cfg.modelPath;
}

/// Применяет пресет модели из UI к AppConfig (обновляет engine и пути к файлам).
void applyModelPreset(ref AppConfig cfg, string optId) {
    if (optId == "sherpa:gigaam-v3-punct") {
        cfg.engine = "sherpa";
        if (cfg.sherpaDll.length == 0) cfg.sherpaDll = "sherpa-onnx-c-api.dll";
        cfg.sherpaModelType = "nemo_transducer";
        cfg.sherpaEncoder = GigaV3Dir ~ "/encoder.int8.onnx";
        cfg.sherpaDecoder = GigaV3Dir ~ "/decoder.onnx";
        cfg.sherpaJoiner = GigaV3Dir ~ "/joiner.onnx";
        cfg.sherpaCtcModel = "";
        cfg.sherpaTokens = GigaV3Dir ~ "/tokens.txt";
        return;
    }
    if (optId == "sherpa:gigaam-multilingual") {
        cfg.engine = "sherpa";
        if (cfg.sherpaDll.length == 0) cfg.sherpaDll = "sherpa-onnx-c-api.dll";
        cfg.sherpaModelType = "nemo_ctc";
        cfg.sherpaEncoder = "";
        cfg.sherpaDecoder = "";
        cfg.sherpaJoiner = "";
        cfg.sherpaCtcModel = GigaMultiDir ~ "/model.int8.onnx";
        cfg.sherpaTokens = GigaMultiDir ~ "/tokens.txt";
        return;
    }
    if (optId == "sherpa:custom") {
        cfg.engine = "sherpa";
        return;
    }
    if (optId.length > 8 && optId[0 .. 8] == "whisper:") {
        cfg.engine = "whisper";
        cfg.modelPath = optId[8 .. $];
        return;
    }
    cfg.engine = "whisper";
    cfg.modelPath = optId;
}

/// Преобразует путь в относительный относительно exeDir(), если файл находится внутри папки приложения.
string toConfigPath(string p) {
    auto base = buildNormalizedPath(exeDir());
    auto norm = buildNormalizedPath(p);
    version (Windows) {
        auto baseL = base.toLower();
        auto normL = norm.toLower();
        if (normL.length > baseL.length && normL[0 .. baseL.length] == baseL
            && (normL[baseL.length] == '\\' || normL[baseL.length] == '/'))
        {
            return norm[baseL.length + 1 .. $].replace("\\", "/");
        }
    }
    return norm;
}

private string pickSherpaPart(string[] onnxFiles, string token, string pickedPath, bool preferInt8) {
    if (pickedPath.length > 0 && baseName(pickedPath).toLower().canFind(token)) {
        return pickedPath;
    }
    string fallback;
    foreach (f; onnxFiles) {
        auto bn = baseName(f).toLower();
        if (!bn.canFind(token)) continue;
        bool isInt8 = bn.canFind(".int8.");
        if (isInt8 == preferInt8) return f;
        if (fallback.length == 0) fallback = f;
    }
    return fallback;
}

/// Автоматически определяет движок и пути к файлам модели по выбранному .bin / .onnx / tokens.txt.
bool detectCustomModelFromFile(string selectedPath, ref AppConfig cfg, out string err) {
    if (selectedPath.length == 0 || !exists(selectedPath)) {
        err = "Файл не найден: " ~ selectedPath;
        return false;
    }

    auto bn = baseName(selectedPath).toLower();
    if (bn.endsWith(".bin")) {
        cfg.engine = "whisper";
        cfg.modelPath = toConfigPath(selectedPath);
        return true;
    }

    if (!bn.endsWith(".onnx") && !bn.endsWith("tokens.txt")) {
        err = "Выберите файл .bin (Whisper) или .onnx / tokens.txt (sherpa-onnx).";
        return false;
    }

    auto dir = isDir(selectedPath) ? selectedPath : dirName(selectedPath);
    string[] onnxFiles;
    string tokensFile;
    foreach (entry; dirEntries(dir, SpanMode.shallow)) {
        if (!entry.isFile) continue;
        auto name = entry.name;
        auto nameL = baseName(name).toLower();
        if (nameL.endsWith(".onnx")) {
            onnxFiles ~= name;
        } else if (nameL == "tokens.txt" || (tokensFile.length == 0 && nameL.endsWith("-tokens.txt"))) {
            tokensFile = name;
        }
    }

    if (tokensFile.length == 0) {
        err = "В папке модели не найден файл tokens.txt: " ~ dir;
        return false;
    }
    if (onnxFiles.length == 0) {
        err = "В папке не найдены файлы *.onnx: " ~ dir;
        return false;
    }

    bool preferInt8 = bn.canFind(".int8.");
    string pickedOnnx = bn.endsWith(".onnx") ? selectedPath : "";
    auto enc = pickSherpaPart(onnxFiles, "encoder", pickedOnnx, preferInt8);
    auto dec = pickSherpaPart(onnxFiles, "decoder", pickedOnnx, preferInt8);
    auto join = pickSherpaPart(onnxFiles, "joiner", pickedOnnx, preferInt8);

    auto hint = (dir ~ "/" ~ bn).toLower();
    cfg.engine = "sherpa";
    if (cfg.sherpaDll.length == 0) cfg.sherpaDll = "sherpa-onnx-c-api.dll";
    cfg.sherpaTokens = toConfigPath(tokensFile);

    if (enc.length > 0 && dec.length > 0 && join.length > 0) {
        cfg.sherpaModelType = (hint.canFind("giga") || hint.canFind("nemo") || hint.canFind("parakeet"))
            ? "nemo_transducer"
            : "transducer";
        cfg.sherpaEncoder = toConfigPath(enc);
        cfg.sherpaDecoder = toConfigPath(dec);
        cfg.sherpaJoiner = toConfigPath(join);
        cfg.sherpaCtcModel = "";
        return true;
    }

    if (enc.length > 0 && dec.length > 0) {
        if (hint.canFind("firered")) cfg.sherpaModelType = "fire_red_asr";
        else if (hint.canFind("canary")) cfg.sherpaModelType = "canary";
        else cfg.sherpaModelType = "whisper";
        cfg.sherpaEncoder = toConfigPath(enc);
        cfg.sherpaDecoder = toConfigPath(dec);
        cfg.sherpaJoiner = "";
        cfg.sherpaCtcModel = "";
        return true;
    }

    string single = pickedOnnx.length > 0 ? pickedOnnx : onnxFiles[0];
    if (hint.canFind("sense-voice") || hint.canFind("sensevoice")) cfg.sherpaModelType = "sense_voice";
    else if (hint.canFind("paraformer")) cfg.sherpaModelType = "paraformer";
    else if (hint.canFind("dolphin")) cfg.sherpaModelType = "dolphin";
    else if (hint.canFind("zipformer")) cfg.sherpaModelType = "zipformer_ctc";
    else if (hint.canFind("wenet")) cfg.sherpaModelType = "wenet_ctc";
    else if (hint.canFind("telespeech")) cfg.sherpaModelType = "telespeech_ctc";
    else cfg.sherpaModelType = "nemo_ctc";

    cfg.sherpaEncoder = "";
    cfg.sherpaDecoder = "";
    cfg.sherpaJoiner = "";
    cfg.sherpaCtcModel = toConfigPath(single);
    return true;
}

string normalizeInputMode(string mode) {
    import std.string : toLower;
    auto m = mode.strip().toLower();
    if (m == "clipboard" || m == "auto" || m == "sendinput") return m;
    return "sendinput";
}

string normalizeTheme(string theme) {
    auto t = theme.strip().toLower();
    if (t == "light" || t == "dark" || t == "auto") return t;
    return "auto";
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
    root["engine"] = normalizeEngine(cfg.engine);
    root["whisperDll"] = cfg.whisperDll;
    root["modelPath"] = cfg.modelPath;
    root["sherpaDll"] = cfg.sherpaDll;
    root["sherpaModelType"] = cfg.sherpaModelType;
    root["sherpaEncoder"] = cfg.sherpaEncoder;
    root["sherpaDecoder"] = cfg.sherpaDecoder;
    root["sherpaJoiner"] = cfg.sherpaJoiner;
    root["sherpaCtcModel"] = cfg.sherpaCtcModel;
    root["sherpaTokens"] = cfg.sherpaTokens;
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
    root["overwriteNonTextClipboard"] = cfg.overwriteNonTextClipboard;
    root["theme"] = normalizeTheme(cfg.theme);
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

    str("engine", cfg.engine);
    cfg.engine = normalizeEngine(cfg.engine);
    str("whisperDll", cfg.whisperDll);
    str("modelPath", cfg.modelPath);
    str("sherpaDll", cfg.sherpaDll);
    str("sherpaModelType", cfg.sherpaModelType);
    str("sherpaEncoder", cfg.sherpaEncoder);
    str("sherpaDecoder", cfg.sherpaDecoder);
    str("sherpaJoiner", cfg.sherpaJoiner);
    str("sherpaCtcModel", cfg.sherpaCtcModel);
    str("sherpaTokens", cfg.sherpaTokens);
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
    boolean("overwriteNonTextClipboard", cfg.overwriteNonTextClipboard);
    str("theme", cfg.theme);
    cfg.theme = normalizeTheme(cfg.theme);
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
    assert(!cfg.overwriteNonTextClipboard);

    auto ov = parseConfigJson(`{"overwriteNonTextClipboard":true,"theme":"DARK"}`);
    assert(ov.overwriteNonTextClipboard);
    assert(ov.theme == "dark");
    auto ovRt = parseConfigJson(serializeConfigJson(ov));
    assert(ovRt.overwriteNonTextClipboard && ovRt.theme == "dark");
    assert(normalizeTheme("unknown") == "auto");

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

    auto sh = parseConfigJson(`{"engine":"sherpa","sherpaDll":"sherpa-onnx-c-api.dll","sherpaModelType":"nemo_ctc","sherpaCtcModel":"models/gigaam.onnx","sherpaTokens":"models/tokens.txt"}`);
    assert(sh.engine == "sherpa");
    assert(sh.sherpaModelType == "nemo_ctc");
    assert(sh.sherpaCtcModel == "models/gigaam.onnx");
    assert(sh.sherpaTokens == "models/tokens.txt");
    auto shRt = parseConfigJson(serializeConfigJson(sh));
    assert(shRt.engine == "sherpa" && shRt.sherpaModelType == "nemo_ctc");
    assert(shRt.sherpaCtcModel == "models/gigaam.onnx");
    assert(modelOptionId(shRt) == "sherpa:custom");

    AppConfig sw;
    applyModelPreset(sw, "sherpa:gigaam-v3-punct");
    assert(sw.engine == "sherpa" && sw.sherpaModelType == "nemo_transducer");
    assert(modelOptionId(sw) == "sherpa:gigaam-v3-punct");

    applyModelPreset(sw, "sherpa:gigaam-multilingual");
    assert(sw.engine == "sherpa" && sw.sherpaModelType == "nemo_ctc");
    assert(modelOptionId(sw) == "sherpa:gigaam-multilingual");

    applyModelPreset(sw, "whisper:models/ggml-base.bin");
    assert(sw.engine == "whisper" && sw.modelPath == "models/ggml-base.bin");
    assert(modelOptionId(sw) == "whisper:models/ggml-base.bin");

    // Автоопределение пользовательских моделей
    import std.file : mkdirRecurse, rmdirRecurse, tempDir;
    auto tmpRoot = buildPath(tempDir(), "shepot_cfg_test");
    if (exists(tmpRoot)) rmdirRecurse(tmpRoot);
    scope (exit) if (exists(tmpRoot)) rmdirRecurse(tmpRoot);

    auto gigaDir = buildPath(tmpRoot, "custom-giga-v3");
    auto senseDir = buildPath(tmpRoot, "sense-voice-int8");
    auto whOnnxDir = buildPath(tmpRoot, "whisper-tiny-onnx");
    mkdirRecurse(gigaDir);
    mkdirRecurse(senseDir);
    mkdirRecurse(whOnnxDir);

    auto ggmlFile = buildPath(tmpRoot, "my-custom.bin");
    write(ggmlFile, "stub");
    write(buildPath(gigaDir, "encoder.int8.onnx"), "stub");
    write(buildPath(gigaDir, "decoder.onnx"), "stub");
    write(buildPath(gigaDir, "joiner.onnx"), "stub");
    write(buildPath(gigaDir, "tokens.txt"), "stub");
    write(buildPath(senseDir, "model.int8.onnx"), "stub");
    write(buildPath(senseDir, "tokens.txt"), "stub");
    write(buildPath(whOnnxDir, "tiny-encoder.int8.onnx"), "stub");
    write(buildPath(whOnnxDir, "tiny-decoder.int8.onnx"), "stub");
    write(buildPath(whOnnxDir, "tiny-tokens.txt"), "stub");

    AppConfig det;
    string derr;
    assert(detectCustomModelFromFile(ggmlFile, det, derr));
    assert(det.engine == "whisper" && det.modelPath.endsWith("my-custom.bin"));

    assert(detectCustomModelFromFile(buildPath(gigaDir, "tokens.txt"), det, derr));
    assert(det.engine == "sherpa" && det.sherpaModelType == "nemo_transducer");
    assert(det.sherpaEncoder.endsWith("encoder.int8.onnx"));

    assert(detectCustomModelFromFile(buildPath(senseDir, "model.int8.onnx"), det, derr));
    assert(det.engine == "sherpa" && det.sherpaModelType == "sense_voice");
    assert(det.sherpaCtcModel.endsWith("model.int8.onnx"));

    assert(detectCustomModelFromFile(buildPath(whOnnxDir, "tiny-encoder.int8.onnx"), det, derr));
    assert(det.engine == "sherpa" && det.sherpaModelType == "whisper");
    assert(det.sherpaJoiner.length == 0 && det.sherpaTokens.endsWith("tiny-tokens.txt"));
}
