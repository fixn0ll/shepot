module app;

import audio : AudioCapture, listInputDevices;
import bootstrap : downloadModel, downloadSherpaModel, downloadSherpaRuntime,
    downloadVulkanRuntime, ensureAssets, hasAllStartupAssets, hasRuntimeDll, isSherpaModelReady;
import config : AppConfig, applyModelPreset, builtinModelPresets, detectCustomModelFromFile,
    loadConfig, modelOptionId, modelRecommendation, normalizeEngine, normalizeInputMode,
    normalizeTheme, parseHotkeyVk, resolvePath, saveConfig, vkToKeyName;
import core.atomic : atomicLoad, atomicStore;
import core.time : MonoTime;
import i18n : normalizeUiLanguage, setUiLanguage, tr;
import os_win : acquireSingleInstance, attachParentConsoleIfAny, closeTempConsole,
    isWindowsAutostartEnabled, openTempConsole, releaseSingleInstance, runTrayApp,
    setWindowsAutostart, showErrorBox, typeText, uiLog, uiRefreshLanguage, uiSetGpuAvailable,
    uiSetIdleStatus, uiSetLangOptions, uiSetLastPhrase, uiSetLoadWaiting, uiSetModelOptions,
    uiSetModelState, uiSetProgress, uiSetStatus, uiSetVisual, UiOption, VisualState;
import postprocess : ReplacementStore;
import sound : playActivationCueAsync, playClickAsync, playCueAsync;
import std.algorithm.searching : any, canFind;
import std.concurrency : OwnerTerminated, receive, send, spawn, Tid;
import std.file : exists;
import std.format : format;
import std.path : baseName, dirName;
import std.stdio : stdout, writeln, writefln;
import stt : WhisperRecognizer;
import stt_engine : calcRms, isSpeechValid, SAMPLE_RATE, SttEngine, tailPreview;
import stt_sherpa : SherpaRecognizer;

SttEngine createSttEngine(const ref AppConfig cfg) {
    if (normalizeEngine(cfg.engine) == "sherpa") {
        return new SherpaRecognizer();
    }
    return new WhisperRecognizer();
}

private enum WorkerCmd {
    loadModel,
    loadModelFromHotkey,
    unloadModel,
    idleCheck,
    preview,
    transcribe,
    shutdown,
}

private struct SwitchModelMsg {
    AppConfig cfg;
    bool reloadNow;
}

private struct SetUseGpuMsg {
    bool useGpu;
}

private struct SetLangMsg {
    string language;
}

private struct SharedState {
    bool modelLoaded;
    bool modelLoading;
    bool recording;
    bool autoLoadModel;
    bool beepEnabled;
    bool livePreview;
    bool previewBusy;
    bool workerExited;
    int unloadTimeoutMin;
    int inputModeCode; // 0 = sendinput, 1 = clipboard, 2 = auto
    bool overwriteNonTextClipboard;
    ulong lastActivityMs;
}

private int encodeInputMode(string mode) nothrow {
    if (mode == "clipboard") return 1;
    if (mode == "auto") return 2;
    return 0;
}

private string decodeInputMode(int code) nothrow {
    if (code == 1) return "clipboard";
    if (code == 2) return "auto";
    return "sendinput";
}

private bool shouldAbortPreview() nothrow {
    return !atomicLoad(g_state.recording);
}

private shared SharedState g_state;
private immutable MonoTime g_baseTime;

shared static this() {
    g_baseTime = MonoTime.currTime;
}

private ulong nowMs() {
    return cast(ulong)(MonoTime.currTime - g_baseTime).total!"msecs";
}

private UiOption[] buildModelOptions(const ref AppConfig cfg) {
    UiOption[] opts;
    opts.reserve(builtinModelPresets.length + 1);
    foreach (p; builtinModelPresets) {
        opts ~= UiOption(tr(p.label, p.labelRu), p.id, tr(p.hint, p.hintRu));
    }
    auto curId = modelOptionId(cfg);
    if (!opts.any!(o => o.value == curId)) {
        auto label = normalizeEngine(cfg.engine) == "sherpa"
            ? (tr("Sherpa (custom): ", "Sherpa (пользовательская): ")
                ~ baseName(cfg.sherpaEncoder.length ? cfg.sherpaEncoder : cfg.sherpaCtcModel))
            : (baseName(cfg.modelPath) ~ tr(" (custom)", " (пользовательская)"));
        opts ~= UiOption(label, curId, modelRecommendation(curId));
    }
    return opts;
}

private UiOption[] buildLangOptions(string currentLang) {
    UiOption[] opts = [
        UiOption(tr("English (en)", "Английский (en)"), "en"),
        UiOption(tr("Russian (ru)", "Русский (ru)"), "ru"),
        UiOption(tr("Auto-detect (auto)", "Автоопределение (auto)"), "auto"),
        UiOption(tr("Ukrainian (uk)", "Украинский (uk)"), "uk"),
        UiOption(tr("German (de)", "Немецкий (de)"), "de"),
        UiOption(tr("French (fr)", "Французский (fr)"), "fr"),
        UiOption(tr("Spanish (es)", "Испанский (es)"), "es"),
        UiOption(tr("Polish (pl)", "Польский (pl)"), "pl"),
        UiOption(tr("Chinese (zh)", "Китайский (zh)"), "zh"),
        UiOption(tr("Japanese (ja)", "Японский (ja)"), "ja"),
    ];
    if (currentLang.length > 0 && !opts.any!(o => o.value == currentLang)) {
        opts ~= UiOption(currentLang, currentLang);
    }
    return opts;
}

private void onWhisperProgress(int pct) nothrow {
    uiSetProgress(2, pct);
}

private bool ensureRuntimeUi(const ref AppConfig curCfg) {
    bool isSherpa = normalizeEngine(curCfg.engine) == "sherpa";
    auto dllPath = resolvePath(isSherpa ? curCfg.sherpaDll : curCfg.whisperDll);
    if (exists(dllPath)) return true;

    auto label = isSherpa ? "sherpa-onnx DLL" : "Whisper Vulkan DLL";
    uiSetModelState(false, true);
    uiSetStatus(format(tr("Downloading %s: 0%%...", "Скачивание %s: 0%%..."), label));
    uiSetProgress(2, 0);
    uiLog(format(tr("[DL] Starting download of %s...", "[DL] Начато скачивание %s..."), label));

    auto cb = (int pct) {
        uiSetProgress(2, pct);
        uiSetStatus(format(tr("Downloading %s: %s%%...", "Скачивание %s: %s%%..."), label, pct));
    };
    bool ok = isSherpa
        ? downloadSherpaRuntime(dirName(dllPath), cb)
        : downloadVulkanRuntime(dirName(dllPath), cb);

    uiSetProgress(0, 0);
    if (!ok) {
        uiLog(format(tr("[DL ERROR] Failed to download %s", "[DL ОШИБКА] Не удалось скачать %s"), label));
        uiSetModelState(false, false);
        uiSetIdleStatus(false);
        return false;
    }
    uiLog(format(tr("[DL] Installed %s", "[DL] Установлены библиотеки %s"), label));
    return true;
}

private bool ensureModelDownloadedUi(const ref AppConfig curCfg) {
    bool isSherpa = normalizeEngine(curCfg.engine) == "sherpa";
    if (isSherpa ? isSherpaModelReady(curCfg) : exists(resolvePath(curCfg.modelPath))) {
        return true;
    }

    auto name = isSherpa ? modelOptionId(curCfg) : baseName(curCfg.modelPath);
    uiSetModelState(false, true);
    uiSetStatus(format(tr("Downloading %s: 0%%...", "Скачивание %s: 0%%..."), name));
    uiSetProgress(2, 0);
    uiLog(format(tr("[DL] Starting download of model %s...", "[DL] Начато скачивание модели %s..."), name));

    auto cb = (int pct) {
        uiSetProgress(2, pct);
        uiSetStatus(format(tr("Downloading %s: %s%%...", "Скачивание %s: %s%%..."), name, pct));
    };
    bool ok = isSherpa
        ? downloadSherpaModel(curCfg, cb)
        : downloadModel(resolvePath(curCfg.modelPath), cb);

    uiSetProgress(0, 0);
    if (!ok) {
        uiLog(format(tr("[DL ERROR] Failed to download model %s", "[DL ОШИБКА] Не удалось скачать модель %s"), name));
        uiSetModelState(false, false);
        uiSetIdleStatus(false);
        return false;
    }
    uiLog(format(tr("[DL] Model %s downloaded.", "[DL] Модель %s скачана."), name));
    return true;
}

private bool ensureModelLoaded(SttEngine recognizer, const ref AppConfig curCfg, bool notifyCue) {
    if (recognizer.isLoaded()) {
        atomicStore(g_state.modelLoaded, true);
        atomicStore(g_state.modelLoading, false);
        uiSetLoadWaiting(false);
        uiSetProgress(0, 0);
        return true;
    }

    atomicStore(g_state.modelLoading, true);
    uiSetModelState(false, true);

    if (!ensureRuntimeUi(curCfg) || !ensureModelDownloadedUi(curCfg)) {
        atomicStore(g_state.modelLoading, false);
        uiSetLoadWaiting(false);
        return false;
    }

    uiSetStatus(format(tr("Loading model (%s)...", "Загрузка модели (%s)..."), recognizer.useGpu() ? "GPU" : "CPU"));
    uiSetProgress(1, 0);

    string err;
    bool ok = recognizer.loadModel(err);
    atomicStore(g_state.modelLoading, false);
    uiSetLoadWaiting(false);
    uiSetProgress(0, 0);

    if (!ok) {
        atomicStore(g_state.modelLoaded, false);
        uiSetModelState(false, false);
        uiLog(tr("[ERROR] ", "[ОШИБКА] ") ~ err);
        uiSetIdleStatus(false);
        return false;
    }

    atomicStore(g_state.modelLoaded, true);
    atomicStore(g_state.lastActivityMs, nowMs());
    uiSetModelState(true, false);
    auto mName = recognizer.modelPath().length ? baseName(recognizer.modelPath()) : recognizer.engineVersion();
    uiLog(format(tr("[MDL] Model %s loaded (%s).", "[MDL] Модель %s загружена (%s)."),
        mName, recognizer.useGpu() ? "GPU" : "CPU"));
    if (notifyCue && atomicLoad(g_state.beepEnabled)) {
        playActivationCueAsync();
    }
    return true;
}

private void unloadModelNow(SttEngine recognizer, string reason) {
    if (!recognizer.isLoaded()) return;
    recognizer.unloadModel();
    atomicStore(g_state.modelLoaded, false);
    uiSetModelState(false, false);
    uiSetProgress(0, 0);
    uiLog("[MDL] " ~ reason);
    uiSetIdleStatus(false);
}

private void workerLoop(shared(AudioCapture)* audioPtr, shared(SttEngine)* sttPtr, immutable AppConfig cfg) {
    auto audio = cast(AudioCapture*) audioPtr;
    SttEngine recognizer = *cast(SttEngine*) sttPtr;
    AppConfig curCfg = cfg;
    scope (exit) {
        if (recognizer !is null) recognizer.close();
        atomicStore(g_state.workerExited, true);
    }
    ReplacementStore replacements;

    if (cfg.autoLoadModel) {
        if (ensureModelLoaded(recognizer, curCfg, false)) {
            uiSetIdleStatus(true);
        }
    }

    bool running = true;
    while (running) {
        try {
            receive(
                (SwitchModelMsg msg) {
                    bool needReload = (recognizer !is null && recognizer.isLoaded()) || msg.reloadNow;
                    if (recognizer !is null) {
                        if (recognizer.isLoaded()) unloadModelNow(recognizer, tr("Switching model...", "Смена модели..."));
                        recognizer.close();
                        recognizer = null;
                    }
                    atomicStore(g_state.modelLoaded, false);
                    uiSetModelState(false, false);

                    curCfg = msg.cfg;
                    if (!ensureRuntimeUi(curCfg)) {
                        uiSetIdleStatus(false);
                        return;
                    }

                    auto nextRec = createSttEngine(curCfg);
                    string initErr;
                    if (!nextRec.initApi(curCfg, initErr)) {
                        uiLog(tr("[ERROR] ", "[ОШИБКА] ") ~ initErr);
                        uiSetIdleStatus(false);
                        return;
                    }
                    recognizer = nextRec;
                    uiSetGpuAvailable(recognizer.supportsGpu());

                    if (needReload) {
                        if (ensureModelLoaded(recognizer, curCfg, true)) {
                            uiSetIdleStatus(true);
                        }
                    } else {
                        auto mName = recognizer.modelPath().length ? baseName(recognizer.modelPath()) : curCfg.sherpaModelType;
                        uiLog(tr("[CFG] Selected model: ", "[CFG] Выбрана модель: ") ~ mName);
                        uiSetIdleStatus(false);
                    }
                },
                (SetUseGpuMsg msg) {
                    if (recognizer is null) return;
                    bool wasLoaded = recognizer.isLoaded();
                    curCfg.useGpu = msg.useGpu;
                    recognizer.setUseGpu(msg.useGpu);
                    if (wasLoaded) {
                        unloadModelNow(recognizer, format(tr("Switching compute mode to %s...", "Переключение режима на %s..."), msg.useGpu ? "GPU" : "CPU"));
                        if (ensureModelLoaded(recognizer, curCfg, true)) {
                            uiSetIdleStatus(true);
                        }
                    } else {
                        uiLog(format(tr("[CFG] Compute mode: %s", "[CFG] Режим вычислений: %s"),
                            msg.useGpu ? "GPU" : tr("CPU only", "Только процессор (CPU)")));
                    }
                },
                (SetLangMsg msg) {
                    if (recognizer is null) return;
                    curCfg.language = msg.language;
                    recognizer.setLanguage(msg.language);
                    uiLog(tr("[CFG] Speech language: ", "[CFG] Язык распознавания: ") ~ msg.language);
                },
                (WorkerCmd cmd) {
                    if (cmd != WorkerCmd.shutdown && recognizer is null) return;
                    final switch (cmd) {
                        case WorkerCmd.shutdown:
                            running = false;
                            return;

                        case WorkerCmd.loadModel:
                            if (ensureModelLoaded(recognizer, curCfg, true)) {
                                if (!atomicLoad(g_state.recording)) uiSetIdleStatus(true);
                            }
                            return;

                        case WorkerCmd.loadModelFromHotkey:
                            if (ensureModelLoaded(recognizer, curCfg, true)) {
                                if (atomicLoad(g_state.recording)) {
                                    uiSetStatus(tr("Recording...", "Идёт запись..."));
                                    uiSetVisual(VisualState.recording, tr("Recording...", "Идёт запись..."));
                                } else {
                                    uiSetIdleStatus(true);
                                    uiSetVisual(VisualState.idle, "");
                                }
                            }
                            return;

                        case WorkerCmd.unloadModel:
                            unloadModelNow(recognizer, tr("Model unloaded manually.", "Модель выгружена вручную."));
                            return;

                        case WorkerCmd.idleCheck:
                            int mins = atomicLoad(g_state.unloadTimeoutMin);
                            if (mins <= 0 || !recognizer.isLoaded() || atomicLoad(g_state.recording)) {
                                return;
                            }
                            ulong idleMs = nowMs() - atomicLoad(g_state.lastActivityMs);
                            if (idleMs >= cast(ulong) mins * 60_000UL) {
                                unloadModelNow(recognizer, format(
                                    tr("Model unloaded on idle timeout (%s min).", "Модель выгружена по таймауту (%s мин бездействия)."),
                                    mins
                                ));
                            }
                            return;

                        case WorkerCmd.preview:
                            scope (exit) atomicStore(g_state.previewBusy, false);
                            if (!atomicLoad(g_state.recording) || !recognizer.isLoaded()) return;

                            auto previewSamples = audio.peekBuffer(SAMPLE_RATE * 15);
                            if (!isSpeechValid(previewSamples, 0.4, cfg.rmsThreshold)) return;

                            auto draft = recognizer.transcribe(previewSamples, null, null, &shouldAbortPreview);
                            if (atomicLoad(g_state.recording) && draft.length > 0) {
                                uiSetVisual(VisualState.recording, tailPreview(draft));
                            }
                            return;

                        case WorkerCmd.transcribe:
                            auto samples = audio.stopAndTakeBuffer();
                            double dur = cast(double) samples.length / SAMPLE_RATE;
                            double rms = calcRms(samples);

                            if (!recognizer.isLoaded()) {
                                if (!ensureModelLoaded(recognizer, curCfg, true)) {
                                    return;
                                }
                            }

                            atomicStore(g_state.lastActivityMs, nowMs());

                            if (!isSpeechValid(samples, cfg.minDurationSec, cfg.rmsThreshold)) {
                                uiLog(format(tr("[SKIP] %.2fs, RMS=%.5f (threshold: %.2fs / %.5f)", "[ПРОПУСК] %.2f сек, RMS=%.5f (порог: %.2f сек / %.5f)"),
                                    dur, rms, cfg.minDurationSec, cfg.rmsThreshold));
                                uiSetIdleStatus(true);
                                uiSetVisual(VisualState.idle, tr("Silence / too short", "Тишина / слишком коротко"), 800);
                                return;
                            }

                            uiSetStatus(tr("Transcribing...", "Распознавание..."));
                            uiSetVisual(VisualState.processing, tr("Processing voice...", "Обработка голоса..."));
                            uiSetProgress(2, 0);
                            int rc = 0;
                            auto text = recognizer.transcribe(samples, &rc, &onWhisperProgress);
                            uiSetProgress(0, 0);
                            atomicStore(g_state.lastActivityMs, nowMs());

                            if (rc != 0) {
                                uiLog(format(tr("[ERROR] Recognizer returned code %s", "[ОШИБКА] Распознаватель вернул код %s"), rc));
                                uiSetIdleStatus(true);
                                uiSetVisual(VisualState.idle, tr("Recognition error", "Ошибка распознавания"), 1200);
                                return;
                            }
                            if (text.length == 0) {
                                uiLog(format(tr("[EMPTY] %.2fs, RMS=%.5f — speech not recognized / filtered", "[ПУСТО] %.2f сек, RMS=%.5f — речь не распознана / отфильтрована"), dur, rms));
                                uiSetIdleStatus(true);
                                uiSetVisual(VisualState.idle, tr("No speech detected", "Речь не распознана"), 900);
                                return;
                            }

                            text = replacements.apply(text);
                            if (text.length == 0) {
                                uiSetIdleStatus(true);
                                uiSetVisual(VisualState.idle, tr("No speech detected", "Речь не распознана"), 900);
                                return;
                            }

                            string method;
                            auto mode = decodeInputMode(atomicLoad(g_state.inputModeCode));
                            bool overwriteClip = atomicLoad(g_state.overwriteNonTextClipboard);
                            typeText(text, mode, cfg.charDelayMs, cfg.clipboardRestoreDelayMs, method, overwriteClip);
                            uiSetLastPhrase(text);
                            uiLog(format(tr("[STT] (%.2fs, RMS=%.4f, %s): %s", "[STT] (%.2fс, RMS=%.4f, %s): %s"), dur, rms, method, text));
                            uiSetIdleStatus(true);
                            uiSetVisual(VisualState.pasted, tr("Typed: ", "Вставлено: ") ~ text, 1100);
                            return;
                    }
                },
                (OwnerTerminated _) {
                    running = false;
                }
            );
        } catch (Throwable e) {
            uiSetProgress(0, 0);
            uiLog(tr("[WORKER ERROR] ", "[ОШИБКА воркера] ") ~ e.msg);
            uiSetIdleStatus(recognizer !is null && recognizer.isLoaded());
        }
    }
}

private float[] loadWav16kPcm(string path) {
    import std.file : read;
    auto raw = cast(const(ubyte)[]) read(path);
    size_t pos = 12;
    while (pos + 8 <= raw.length) {
        auto id = cast(const(char)[]) raw[pos .. pos + 4];
        uint chunkSize = *cast(const(uint)*) (raw.ptr + pos + 4);
        pos += 8;
        if (id == "data" && pos + chunkSize <= raw.length) {
            size_t n = chunkSize / 2;
            auto pcm = cast(const(short)*) (raw.ptr + pos);
            auto samples = new float[n];
            foreach (i; 0 .. n) samples[i] = pcm[i] / 32768.0f;
            return samples;
        }
        pos += chunkSize + (chunkSize & 1);
    }
    return null;
}

version (unittest) {
    // Точка входа отключена при запуске dub test
} else {
    int main(string[] args) {
        bool checkOnly = args.canFind("--check");
        bool setupOnly = args.canFind("--setup");
        bool allowDownload = !args.canFind("--no-download");
        string wavTestPath;
        foreach (a; args) {
            if (a.length > 6 && a[0 .. 6] == "--wav=") {
                wavTestPath = a[6 .. $];
                checkOnly = true;
            }
        }

        if (checkOnly || setupOnly) {
            attachParentConsoleIfAny();
        } else {
            if (!acquireSingleInstance()) return 0;
        }
        scope (exit) {
            if (!checkOnly && !setupOnly) releaseSingleInstance();
        }

        auto cfg = loadConfig();
        setUiLanguage(cfg.uiLanguage);
        bool isWhisper = normalizeEngine(cfg.engine) == "whisper";
        bool cliMode = checkOnly || setupOnly;
        bool needTempConsole = !cliMode && allowDownload && !hasRuntimeDll(cfg);
        if (needTempConsole) openTempConsole();

        bool assetsOk = ensureAssets(cfg, allowDownload, cliMode || !allowDownload);
        if (needTempConsole) closeTempConsole();

        if (!assetsOk) {
            auto msg = isWhisper
                ? tr(
                    "Missing dependencies. Run with --setup or place whisper.dll and a model in bin/.",
                    "Не хватает зависимостей. Запустите с --setup или положите whisper.dll и модель в bin/."
                )
                : tr(
                    "Missing sherpa-onnx / GigaAM dependencies. Check internet connection or paths in config.json.",
                    "Не хватает зависимостей sherpa-onnx / GigaAM. Проверьте интернет или пути в config.json."
                );
            if (checkOnly || setupOnly) { writeln(msg); stdout.flush(); }
            else showErrorBox(msg);
            return 1;
        }
        if (setupOnly) {
            writeln(tr("Dependencies are ready.", "Зависимости готовы."));
            stdout.flush();
            return 0;
        }

        string err;
        SttEngine recognizer = createSttEngine(cfg);
        if (!recognizer.initApi(cfg, err)) {
            if (checkOnly) { writeln(tr("Error: ", "Ошибка: "), err); stdout.flush(); }
            else showErrorBox(err);
            return 1;
        }
        bool startedWorker = false;
        scope (exit) {
            if (!startedWorker && recognizer !is null) recognizer.close();
        }

        if (checkOnly) {
            writefln(tr("Initializing %s (%s)...", "Инициализация %s (%s)..."), normalizeEngine(cfg.engine), recognizer.modelPath());
            writeln(tr("Loading model...", "Загрузка модели..."));
            stdout.flush();
            auto t0 = nowMs();
            if (!recognizer.loadModel(err)) {
                writeln(tr("Error: ", "Ошибка: "), err);
                stdout.flush();
                return 1;
            }
            writefln(tr("Model loaded in %s ms | Engine=%s", "Модель загружена за %s мс | Engine=%s"), nowMs() - t0, recognizer.engineVersion());
            stdout.flush();

            if (wavTestPath.length > 0) {
                auto samples = loadWav16kPcm(resolvePath(wavTestPath));
                auto t1 = nowMs();
                int rc = 0;
                auto text = recognizer.transcribe(samples, &rc);
                writefln(tr("WAV %s (%.2fs) | rc=%s | %s ms | Text: %s", "WAV %s (%.2fс) | rc=%s | %s мс | Текст: %s"),
                    wavTestPath, cast(double) samples.length / SAMPLE_RATE, rc, nowMs() - t1, text);
                stdout.flush();
                return rc == 0 ? 0 : 1;
            }
        }

        AudioCapture capture;
        if (!capture.init(cfg.micDevice, err)) {
            if (checkOnly) writeln(tr("Error: ", "Ошибка: "), err);
            else showErrorBox(err);
            return 1;
        }
        scope (exit) capture.close();

        if (checkOnly) {
            import core.thread : Thread;
            import core.time : msecs;
            writefln("Engine=%s", recognizer.engineVersion());
            string chkMicErr;
            if (!capture.startRecording(chkMicErr)) {
                writeln(tr("Microphone error: ", "Ошибка микрофона: "), chkMicErr);
                stdout.flush();
                return 1;
            }
            Thread.sleep(500.msecs);
            auto testBuf = capture.stopAndTakeBuffer();
            writefln(tr("Microphone: %s samples in 500ms, RMS=%.5f", "Микрофон: %s сэмплов за 500мс, RMS=%.5f"),
                testBuf.length, calcRms(testBuf));
            writeln(tr("Check passed: STT engine, model, and microphone initialized.",
                "Проверка пройдена: движок STT, модель и микрофон инициализированы."));
            stdout.flush();
            return 0;
        }

        atomicStore(g_state.modelLoaded, false);
        atomicStore(g_state.modelLoading, cfg.autoLoadModel);
        atomicStore(g_state.recording, false);
        atomicStore(g_state.autoLoadModel, cfg.autoLoadModel);
        atomicStore(g_state.beepEnabled, cfg.beep);
        atomicStore(g_state.livePreview, cfg.livePreview);
        atomicStore(g_state.previewBusy, false);
        atomicStore(g_state.workerExited, false);
        atomicStore(g_state.unloadTimeoutMin, cfg.unloadTimeoutMin);
        atomicStore(g_state.inputModeCode, encodeInputMode(normalizeInputMode(cfg.inputMode)));
        atomicStore(g_state.overwriteNonTextClipboard, cfg.overwriteNonTextClipboard);
        atomicStore(g_state.lastActivityMs, nowMs());

        auto hotkeyVk = parseHotkeyVk(cfg.hotkey);
        auto hotkeyName = vkToKeyName(hotkeyVk);
        auto mics = listInputDevices();
        auto currentModelId = modelOptionId(cfg);
        auto modelOpts = buildModelOptions(cfg);
        auto langOpts = buildLangOptions(cfg.language);
        bool winAuto = isWindowsAutostartEnabled();

        immutable AppConfig immCfg = cfg;
        Tid worker = spawn(&workerLoop, cast(shared(AudioCapture)*) &capture, cast(shared(SttEngine)*) &recognizer, immCfg);
        startedWorker = true;
        scope (exit) {
            worker.send(WorkerCmd.shutdown);
            import core.thread : Thread;
            import core.time : msecs;
            foreach (_; 0 .. 300) {
                if (atomicLoad(g_state.workerExited)) break;
                Thread.sleep(10.msecs);
            }
        }

        auto activeModelName = recognizer.modelPath().length ? baseName(recognizer.modelPath()) : cfg.sherpaModelType;
        string[] initLogs = [
            format(tr("%s ready (%s, mode: %s)", "%s готов (%s, режим: %s)"),
                recognizer.engineVersion(), activeModelName, recognizer.useGpu() ? "GPU" : "CPU"),
            format(tr("Activation: [%s], speech lang: %s, auto-unload: %s", "Активация: [%s], язык: %s, автовыгрузка: %s"),
                hotkeyName, cfg.language,
                cfg.unloadTimeoutMin > 0
                    ? format(tr("%s min", "%s мин"), cfg.unloadTimeoutMin)
                    : tr("Never", "Никогда")),
            format(tr("Microphones detected: %s", "Найдено микрофонов: %s"), mics.length),
            tr("Closing [X] minimizes to system tray. Use the tray menu to exit.",
               "Закрытие окна [X] сворачивает программу в трей. Выход — через меню иконки в трее."),
        ];

        bool ok = runTrayApp(
            hotkeyVk,
            hotkeyName,
            cfg.blockHotkey,
            cfg.toggleMode,
            mics,
            cfg.micDevice,
            modelOpts,
            currentModelId,
            langOpts,
            cfg.language,
            normalizeInputMode(cfg.inputMode),
            normalizeTheme(cfg.theme),
            cfg.overwriteNonTextClipboard,
            cfg.startMinimized,
            cfg.autoLoadModel,
            !cfg.useGpu,
            recognizer.supportsGpu(),
            winAuto,
            cfg.showOverlay,
            cfg.beep,
            cfg.livePreview,
            cfg.unloadTimeoutMin,
            false,
            cfg.autoLoadModel,
            initLogs,
            () {
                string micErr;
                if (!capture.startRecording(micErr)) {
                    atomicStore(g_state.recording, false);
                    uiLog(tr("[MIC ERROR] ", "[MIC ОШИБКА] ") ~ micErr);
                    uiSetIdleStatus(atomicLoad(g_state.modelLoaded));
                    uiSetVisual(VisualState.idle, tr("Microphone error", "Ошибка микрофона"), 1200);
                    return;
                }
                atomicStore(g_state.recording, true);
                atomicStore(g_state.lastActivityMs, nowMs());
                bool beepOn = atomicLoad(g_state.beepEnabled);

                if (!atomicLoad(g_state.modelLoaded)) {
                    uiSetStatus(tr("Loading model (recording)...", "Загрузка модели (идёт запись)..."));
                    uiSetVisual(VisualState.recording, tr("Loading model & recording...", "Загрузка модели и запись..."));
                    if (beepOn) {
                        playClickAsync();
                        uiSetLoadWaiting(true);
                    }
                    if (!atomicLoad(g_state.modelLoading)) {
                        atomicStore(g_state.modelLoading, true);
                        uiSetModelState(false, true);
                        worker.send(WorkerCmd.loadModelFromHotkey);
                    }
                } else {
                    uiSetStatus(tr("Recording...", "Идёт запись..."));
                    uiSetVisual(VisualState.recording, tr("Recording...", "Идёт запись..."));
                    if (beepOn) playCueAsync(true);
                }
            },
            () {
                atomicStore(g_state.recording, false);
                atomicStore(g_state.lastActivityMs, nowMs());
                capture.stopStream();
                uiSetVisual(VisualState.processing, tr("Processing voice...", "Обработка голоса..."));
                if (atomicLoad(g_state.modelLoaded) && atomicLoad(g_state.beepEnabled)) {
                    playCueAsync(false);
                }
                worker.send(WorkerCmd.transcribe);
            },
            () {
                atomicStore(g_state.recording, false);
                atomicStore(g_state.lastActivityMs, nowMs());
                capture.stopAndTakeBuffer();
                if (atomicLoad(g_state.beepEnabled)) playCueAsync(false);
                uiSetIdleStatus(atomicLoad(g_state.modelLoaded));
                uiSetVisual(VisualState.idle, tr("Recording cancelled", "Запись отменена"), 1000);
                uiLog(tr("[REC] Recording cancelled (Esc)", "[REC] Запись отменена (Esc)"));
            },
            (int newDeviceId) {
                string micErr;
                if (capture.reopen(newDeviceId, micErr)) {
                    cfg.micDevice = newDeviceId;
                    saveConfig(cfg);
                    uiLog(format(tr("[MIC] Switched microphone (deviceId=%s)", "[MIC] Переключён микрофон (deviceId=%s)"), newDeviceId));
                } else {
                    uiLog(tr("[MIC ERROR] ", "[MIC ОШИБКА] ") ~ micErr);
                }
            },
            (string newOptId) {
                applyModelPreset(cfg, newOptId);
                saveConfig(cfg);
                immutable AppConfig nextCfg = cfg;
                worker.send(SwitchModelMsg(nextCfg, atomicLoad(g_state.autoLoadModel)));
            },
            (string pickedPath) {
                AppConfig nextCfgMut = cfg;
                string detErr;
                if (!detectCustomModelFromFile(pickedPath, nextCfgMut, detErr)) {
                    uiLog(tr("[ERROR] ", "[ОШИБКА] ") ~ detErr);
                    showErrorBox(detErr);
                    return;
                }
                cfg = nextCfgMut;
                saveConfig(cfg);
                uiSetModelOptions(buildModelOptions(cfg), modelOptionId(cfg));
                uiLog(format(tr("[CFG] Custom model (%s/%s): %s", "[CFG] Пользовательская модель (%s/%s): %s"),
                    cfg.engine, cfg.engine == "sherpa" ? cfg.sherpaModelType : "ggml", baseName(pickedPath)));
                immutable AppConfig nextCfg = cfg;
                worker.send(SwitchModelMsg(nextCfg, atomicLoad(g_state.autoLoadModel)));
            },
            (string newLang) {
                cfg.language = newLang;
                saveConfig(cfg);
                worker.send(SetLangMsg(newLang));
            },
            (uint newVk) {
                auto newName = vkToKeyName(newVk);
                cfg.hotkey = newName;
                saveConfig(cfg);
                uiLog(format(tr("[CFG] New activation key: [%s]", "[CFG] Новая кнопка активации: [%s]"), newName));
                return newName;
            },
            () {
                if (atomicLoad(g_state.modelLoading)) return;
                if (atomicLoad(g_state.modelLoaded)) {
                    worker.send(WorkerCmd.unloadModel);
                } else {
                    atomicStore(g_state.modelLoading, true);
                    uiSetModelState(false, true);
                    worker.send(WorkerCmd.loadModel);
                }
            },
            (int mins) {
                cfg.unloadTimeoutMin = mins;
                atomicStore(g_state.unloadTimeoutMin, mins);
                atomicStore(g_state.lastActivityMs, nowMs());
                saveConfig(cfg);
                uiLog(format(tr("[CFG] Auto-unload model: %s", "[CFG] Автовыгрузка модели: %s"),
                    mins > 0 ? format(tr("%s min", "%s мин"), mins) : tr("Never", "Никогда")));
            },
            (string mode) {
                auto norm = normalizeInputMode(mode);
                cfg.inputMode = norm;
                atomicStore(g_state.inputModeCode, encodeInputMode(norm));
                saveConfig(cfg);
                uiLog(tr("[CFG] Input mode: ", "[CFG] Режим ввода: ") ~ norm);
            },
            (string newTheme) {
                auto norm = normalizeTheme(newTheme);
                cfg.theme = norm;
                saveConfig(cfg);
                uiLog(tr("[CFG] Theme: ", "[CFG] Тема оформления: ") ~ norm);
            },
            (string newUiLang) {
                auto norm = normalizeUiLanguage(newUiLang);
                cfg.uiLanguage = norm;
                setUiLanguage(norm);
                saveConfig(cfg);
                uiSetModelOptions(buildModelOptions(cfg), modelOptionId(cfg));
                uiSetLangOptions(buildLangOptions(cfg.language), cfg.language);
                uiRefreshLanguage();
                uiLog(tr("[CFG] UI language: ", "[CFG] Язык интерфейса: ") ~ norm);
            },
            (bool overwriteOn) {
                cfg.overwriteNonTextClipboard = overwriteOn;
                atomicStore(g_state.overwriteNonTextClipboard, overwriteOn);
                saveConfig(cfg);
                uiLog(format(tr("[CFG] Overwrite non-text clipboard: %s", "[CFG] Заменять нетекстовый буфер: %s"),
                    overwriteOn ? tr("on", "вкл") : tr("off", "выкл")));
            },
            (bool toggleOn) {
                cfg.toggleMode = toggleOn;
                saveConfig(cfg);
                uiLog(format(tr("[CFG] Toggle mode: %s", "[CFG] Режим переключения (Toggle): %s"),
                    toggleOn ? tr("on", "вкл") : tr("off", "выкл")));
            },
            (bool checked) {
                cfg.autoLoadModel = checked;
                atomicStore(g_state.autoLoadModel, checked);
                saveConfig(cfg);
                uiLog(format(tr("[CFG] Auto-load model: %s", "[CFG] Автозагрузка модели: %s"),
                    checked ? tr("on", "вкл") : tr("off", "выкл")));
            },
            (bool cpuOnly) {
                cfg.useGpu = !cpuOnly;
                saveConfig(cfg);
                worker.send(SetUseGpuMsg(!cpuOnly));
            },
            (bool beepOn) {
                cfg.beep = beepOn;
                atomicStore(g_state.beepEnabled, beepOn);
                saveConfig(cfg);
                uiLog(format(tr("[CFG] Sound cues: %s", "[CFG] Звуковые сигналы: %s"),
                    beepOn ? tr("on", "вкл") : tr("off", "выкл")));
            },
            (bool overlayOn) {
                cfg.showOverlay = overlayOn;
                saveConfig(cfg);
                uiLog(format(tr("[CFG] Floating indicator (HUD): %s", "[CFG] Плавающий индикатор (HUD): %s"),
                    overlayOn ? tr("on", "вкл") : tr("off", "выкл")));
            },
            (bool previewOn) {
                cfg.livePreview = previewOn;
                atomicStore(g_state.livePreview, previewOn);
                saveConfig(cfg);
                uiLog(format(tr("[CFG] Live speech preview: %s", "[CFG] Предпросмотр речи (Live): %s"),
                    previewOn ? tr("on", "вкл") : tr("off", "выкл")));
            },
            (bool checked) {
                cfg.startMinimized = checked;
                saveConfig(cfg);
                uiLog(format(tr("[CFG] Start minimized to tray: %s", "[CFG] Запускать в трее сразу: %s"),
                    checked ? tr("on", "вкл") : tr("off", "выкл")));
            },
            (bool checked) {
                if (setWindowsAutostart(checked)) {
                    uiLog(format(tr("[CFG] Run with Windows: %s", "[CFG] Автозапуск с Windows: %s"),
                        checked ? tr("on", "вкл") : tr("off", "выкл")));
                } else {
                    uiLog(tr("[ERROR] Failed to update Windows autostart registry entry.",
                             "[ОШИБКА] Не удалось изменить запись автозапуска в реестре."));
                }
            },
            () {
                if (atomicLoad(g_state.unloadTimeoutMin) > 0 &&
                    atomicLoad(g_state.modelLoaded) &&
                    !atomicLoad(g_state.recording)) {
                    worker.send(WorkerCmd.idleCheck);
                }
            },
            () {
                if (atomicLoad(g_state.recording) &&
                    atomicLoad(g_state.livePreview) &&
                    atomicLoad(g_state.modelLoaded) &&
                    !atomicLoad(g_state.previewBusy)) {
                    atomicStore(g_state.previewBusy, true);
                    worker.send(WorkerCmd.preview);
                }
            }
        );
        return ok ? 0 : 1;
    }
}
