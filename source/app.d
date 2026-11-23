module app;

import audio : AudioCapture, listInputDevices;
import bootstrap : downloadModel, downloadSherpaModel, downloadSherpaRuntime,
    downloadVulkanRuntime, ensureAssets, hasAllStartupAssets, hasRuntimeDll, isSherpaModelReady;
import config : AppConfig, applyModelPreset, builtinModelPresets, detectCustomModelFromFile,
    loadConfig, modelOptionId, modelRecommendation, normalizeEngine, normalizeInputMode,
    normalizeTheme, parseHotkeyVk, resolvePath, saveConfig, vkToKeyName;
import core.atomic : atomicLoad, atomicStore;
import core.time : MonoTime;
import os_win : acquireSingleInstance, attachParentConsoleIfAny, closeTempConsole,
    isWindowsAutostartEnabled, openTempConsole, releaseSingleInstance, runTrayApp,
    setWindowsAutostart, showErrorBox, typeText, uiLog, uiSetGpuAvailable, uiSetIdleStatus,
    uiSetLastPhrase, uiSetLoadWaiting, uiSetModelOptions, uiSetModelState, uiSetProgress,
    uiSetStatus, uiSetVisual, UiOption, VisualState;
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
        opts ~= UiOption(p.label, p.id, p.hint);
    }
    auto curId = modelOptionId(cfg);
    if (!opts.any!(o => o.value == curId)) {
        auto label = normalizeEngine(cfg.engine) == "sherpa"
            ? ("Sherpa (пользовательская): " ~ baseName(cfg.sherpaEncoder.length ? cfg.sherpaEncoder : cfg.sherpaCtcModel))
            : (baseName(cfg.modelPath) ~ " (пользовательская)");
        opts ~= UiOption(label, curId, modelRecommendation(curId));
    }
    return opts;
}

private UiOption[] buildLangOptions(string currentLang) {
    UiOption[] opts = [
        UiOption("Русский (ru)", "ru"),
        UiOption("Английский (en)", "en"),
        UiOption("Автоопределение (auto)", "auto"),
        UiOption("Украинский (uk)", "uk"),
        UiOption("Немецкий (de)", "de"),
        UiOption("Французский (fr)", "fr"),
        UiOption("Испанский (es)", "es"),
        UiOption("Польский (pl)", "pl"),
        UiOption("Китайский (zh)", "zh"),
        UiOption("Японский (ja)", "ja"),
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
    uiSetStatus(format("Скачивание %s: 0%%...", label));
    uiSetProgress(2, 0);
    uiLog("[DL] Начато скачивание " ~ label ~ "...");

    auto cb = (int pct) {
        uiSetProgress(2, pct);
        uiSetStatus(format("Скачивание %s: %s%%...", label, pct));
    };
    bool ok = isSherpa
        ? downloadSherpaRuntime(dirName(dllPath), cb)
        : downloadVulkanRuntime(dirName(dllPath), cb);

    uiSetProgress(0, 0);
    if (!ok) {
        uiLog("[DL ОШИБКА] Не удалось скачать " ~ label);
        uiSetModelState(false, false);
        uiSetIdleStatus(false);
        return false;
    }
    uiLog("[DL] Установлены библиотеки " ~ label);
    return true;
}

private bool ensureModelDownloadedUi(const ref AppConfig curCfg) {
    bool isSherpa = normalizeEngine(curCfg.engine) == "sherpa";
    if (isSherpa ? isSherpaModelReady(curCfg) : exists(resolvePath(curCfg.modelPath))) {
        return true;
    }

    auto name = isSherpa ? modelOptionId(curCfg) : baseName(curCfg.modelPath);
    uiSetModelState(false, true);
    uiSetStatus(format("Скачивание %s: 0%%...", name));
    uiSetProgress(2, 0);
    uiLog(format("[DL] Начато скачивание модели %s...", name));

    auto cb = (int pct) {
        uiSetProgress(2, pct);
        uiSetStatus(format("Скачивание %s: %s%%...", name, pct));
    };
    bool ok = isSherpa
        ? downloadSherpaModel(curCfg, cb)
        : downloadModel(resolvePath(curCfg.modelPath), cb);

    uiSetProgress(0, 0);
    if (!ok) {
        uiLog("[DL ОШИБКА] Не удалось скачать модель " ~ name);
        uiSetModelState(false, false);
        uiSetIdleStatus(false);
        return false;
    }
    uiLog("[DL] Модель " ~ name ~ " скачана.");
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

    uiSetStatus(format("Загрузка модели (%s)...", recognizer.useGpu() ? "GPU" : "CPU"));
    uiSetProgress(1, 0);

    string err;
    bool ok = recognizer.loadModel(err);
    atomicStore(g_state.modelLoading, false);
    uiSetLoadWaiting(false);
    uiSetProgress(0, 0);

    if (!ok) {
        atomicStore(g_state.modelLoaded, false);
        uiSetModelState(false, false);
        uiLog("[ОШИБКА] " ~ err);
        uiSetIdleStatus(false);
        return false;
    }

    atomicStore(g_state.modelLoaded, true);
    atomicStore(g_state.lastActivityMs, nowMs());
    uiSetModelState(true, false);
    auto mName = recognizer.modelPath().length ? baseName(recognizer.modelPath()) : recognizer.engineVersion();
    uiLog(format("[MDL] Модель %s загружена (%s).", mName, recognizer.useGpu() ? "GPU" : "CPU"));
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
                        if (recognizer.isLoaded()) unloadModelNow(recognizer, "Смена модели...");
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
                        uiLog("[ОШИБКА] " ~ initErr);
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
                        uiLog("[CFG] Выбрана модель: " ~ mName);
                        uiSetIdleStatus(false);
                    }
                },
                (SetUseGpuMsg msg) {
                    if (recognizer is null) return;
                    bool wasLoaded = recognizer.isLoaded();
                    curCfg.useGpu = msg.useGpu;
                    recognizer.setUseGpu(msg.useGpu);
                    if (wasLoaded) {
                        unloadModelNow(recognizer, format("Переключение режима на %s...", msg.useGpu ? "GPU" : "CPU"));
                        if (ensureModelLoaded(recognizer, curCfg, true)) {
                            uiSetIdleStatus(true);
                        }
                    } else {
                        uiLog(format("[CFG] Режим вычислений: %s", msg.useGpu ? "GPU" : "Только процессор (CPU)"));
                    }
                },
                (SetLangMsg msg) {
                    if (recognizer is null) return;
                    curCfg.language = msg.language;
                    recognizer.setLanguage(msg.language);
                    uiLog("[CFG] Язык распознавания: " ~ msg.language);
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
                                    uiSetStatus("Идёт запись...");
                                    uiSetVisual(VisualState.recording, "Идёт запись...");
                                } else {
                                    uiSetIdleStatus(true);
                                    uiSetVisual(VisualState.idle, "");
                                }
                            }
                            return;

                        case WorkerCmd.unloadModel:
                            unloadModelNow(recognizer, "Модель выгружена вручную.");
                            return;

                        case WorkerCmd.idleCheck:
                            int mins = atomicLoad(g_state.unloadTimeoutMin);
                            if (mins <= 0 || !recognizer.isLoaded() || atomicLoad(g_state.recording)) {
                                return;
                            }
                            ulong idleMs = nowMs() - atomicLoad(g_state.lastActivityMs);
                            if (idleMs >= cast(ulong) mins * 60_000UL) {
                                unloadModelNow(recognizer, format("Модель выгружена по таймауту (%s мин бездействия).", mins));
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
                                uiLog(format("[ПРОПУСК] %.2f сек, RMS=%.5f (порог: %.2f сек / %.5f)",
                                    dur, rms, cfg.minDurationSec, cfg.rmsThreshold));
                                uiSetIdleStatus(true);
                                uiSetVisual(VisualState.idle, "Тишина / слишком коротко", 800);
                                return;
                            }

                            uiSetStatus("Распознавание...");
                            uiSetVisual(VisualState.processing, "Обработка голоса...");
                            uiSetProgress(2, 0);
                            int rc = 0;
                            auto text = recognizer.transcribe(samples, &rc, &onWhisperProgress);
                            uiSetProgress(0, 0);
                            atomicStore(g_state.lastActivityMs, nowMs());

                            if (rc != 0) {
                                uiLog(format("[ОШИБКА] Распознаватель вернул код %s", rc));
                                uiSetIdleStatus(true);
                                uiSetVisual(VisualState.idle, "Ошибка распознавания", 1200);
                                return;
                            }
                            if (text.length == 0) {
                                uiLog(format("[ПУСТО] %.2f сек, RMS=%.5f — речь не распознана / отфильтрована", dur, rms));
                                uiSetIdleStatus(true);
                                uiSetVisual(VisualState.idle, "Речь не распознана", 900);
                                return;
                            }

                            text = replacements.apply(text);
                            if (text.length == 0) {
                                uiSetIdleStatus(true);
                                uiSetVisual(VisualState.idle, "Речь не распознана", 900);
                                return;
                            }

                            string method;
                            auto mode = decodeInputMode(atomicLoad(g_state.inputModeCode));
                            bool overwriteClip = atomicLoad(g_state.overwriteNonTextClipboard);
                            typeText(text, mode, cfg.charDelayMs, cfg.clipboardRestoreDelayMs, method, overwriteClip);
                            uiSetLastPhrase(text);
                            uiLog(format("[STT] (%.2fс, RMS=%.4f, %s): %s", dur, rms, method, text));
                            uiSetIdleStatus(true);
                            uiSetVisual(VisualState.pasted, "Вставлено: " ~ text, 1100);
                            return;
                    }
                },
                (OwnerTerminated _) {
                    running = false;
                }
            );
        } catch (Throwable e) {
            uiSetProgress(0, 0);
            uiLog("[ОШИБКА воркера] " ~ e.msg);
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
        bool isWhisper = normalizeEngine(cfg.engine) == "whisper";
        bool cliMode = checkOnly || setupOnly;
        bool needTempConsole = !cliMode && allowDownload && !hasRuntimeDll(cfg);
        if (needTempConsole) openTempConsole();

        bool assetsOk = ensureAssets(cfg, allowDownload, cliMode || !allowDownload);
        if (needTempConsole) closeTempConsole();

        if (!assetsOk) {
            auto msg = isWhisper
                ? "Не хватает зависимостей. Запустите с --setup или положите whisper.dll и модель в bin/."
                : "Не хватает зависимостей sherpa-onnx / GigaAM. Проверьте интернет или пути в config.json.";
            if (checkOnly || setupOnly) { writeln(msg); stdout.flush(); }
            else showErrorBox(msg);
            return 1;
        }
        if (setupOnly) {
            writeln("Зависимости готовы.");
            stdout.flush();
            return 0;
        }

        string err;
        SttEngine recognizer = createSttEngine(cfg);
        if (!recognizer.initApi(cfg, err)) {
            if (checkOnly) { writeln("Ошибка: ", err); stdout.flush(); }
            else showErrorBox(err);
            return 1;
        }
        bool startedWorker = false;
        scope (exit) {
            if (!startedWorker && recognizer !is null) recognizer.close();
        }

        if (checkOnly) {
            writefln("Инициализация %s (%s)...", normalizeEngine(cfg.engine), recognizer.modelPath());
            writeln("Загрузка модели...");
            stdout.flush();
            auto t0 = nowMs();
            if (!recognizer.loadModel(err)) {
                writeln("Ошибка: ", err);
                stdout.flush();
                return 1;
            }
            writefln("Модель загружена за %s мс | Engine=%s", nowMs() - t0, recognizer.engineVersion());
            stdout.flush();

            if (wavTestPath.length > 0) {
                auto samples = loadWav16kPcm(resolvePath(wavTestPath));
                auto t1 = nowMs();
                int rc = 0;
                auto text = recognizer.transcribe(samples, &rc);
                writefln("WAV %s (%.2fс) | rc=%s | %s мс | Текст: %s",
                    wavTestPath, cast(double) samples.length / SAMPLE_RATE, rc, nowMs() - t1, text);
                stdout.flush();
                return rc == 0 ? 0 : 1;
            }
        }

        AudioCapture capture;
        if (!capture.init(cfg.micDevice, err)) {
            if (checkOnly) writeln("Ошибка: ", err);
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
                writeln("Ошибка микрофона: ", chkMicErr);
                stdout.flush();
                return 1;
            }
            Thread.sleep(500.msecs);
            auto testBuf = capture.stopAndTakeBuffer();
            writefln("Микрофон: %s сэмплов за 500мс, RMS=%.5f", testBuf.length, calcRms(testBuf));
            writeln("Проверка пройдена: движок STT, модель и микрофон инициализированы.");
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
            format("%s готов (%s, режим: %s)",
                recognizer.engineVersion(), activeModelName, recognizer.useGpu() ? "GPU" : "CPU"),
            format("Активация: [%s], язык: %s, автовыгрузка: %s",
                hotkeyName, cfg.language, cfg.unloadTimeoutMin > 0 ? format("%s мин", cfg.unloadTimeoutMin) : "Никогда"),
            format("Найдено микрофонов: %s", mics.length),
            "Закрытие окна [X] сворачивает программу в трей. Выход — через меню иконки в трее.",
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
                    uiLog("[MIC ОШИБКА] " ~ micErr);
                    uiSetIdleStatus(atomicLoad(g_state.modelLoaded));
                    uiSetVisual(VisualState.idle, "Ошибка микрофона", 1200);
                    return;
                }
                atomicStore(g_state.recording, true);
                atomicStore(g_state.lastActivityMs, nowMs());
                bool beepOn = atomicLoad(g_state.beepEnabled);

                if (!atomicLoad(g_state.modelLoaded)) {
                    uiSetStatus("Загрузка модели (идёт запись)...");
                    uiSetVisual(VisualState.recording, "Загрузка модели и запись...");
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
                    uiSetStatus("Идёт запись...");
                    uiSetVisual(VisualState.recording, "Идёт запись...");
                    if (beepOn) playCueAsync(true);
                }
            },
            () {
                atomicStore(g_state.recording, false);
                atomicStore(g_state.lastActivityMs, nowMs());
                capture.stopStream();
                uiSetVisual(VisualState.processing, "Обработка голоса...");
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
                uiSetVisual(VisualState.idle, "Запись отменена", 1000);
                uiLog("[REC] Запись отменена (Esc)");
            },
            (int newDeviceId) {
                string micErr;
                if (capture.reopen(newDeviceId, micErr)) {
                    cfg.micDevice = newDeviceId;
                    saveConfig(cfg);
                    uiLog(format("[MIC] Переключён микрофон (deviceId=%s)", newDeviceId));
                } else {
                    uiLog("[MIC ОШИБКА] " ~ micErr);
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
                    uiLog("[ОШИБКА] " ~ detErr);
                    showErrorBox(detErr);
                    return;
                }
                cfg = nextCfgMut;
                saveConfig(cfg);
                uiSetModelOptions(buildModelOptions(cfg), modelOptionId(cfg));
                uiLog(format("[CFG] Пользовательская модель (%s/%s): %s",
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
                uiLog(format("[CFG] Новая кнопка активации: [%s]", newName));
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
                uiLog(format("[CFG] Автовыгрузка модели: %s", mins > 0 ? format("%s мин", mins) : "Никогда"));
            },
            (string mode) {
                auto norm = normalizeInputMode(mode);
                cfg.inputMode = norm;
                atomicStore(g_state.inputModeCode, encodeInputMode(norm));
                saveConfig(cfg);
                uiLog("[CFG] Режим ввода: " ~ norm);
            },
            (string newTheme) {
                auto norm = normalizeTheme(newTheme);
                cfg.theme = norm;
                saveConfig(cfg);
                uiLog("[CFG] Тема оформления: " ~ norm);
            },
            (bool overwriteOn) {
                cfg.overwriteNonTextClipboard = overwriteOn;
                atomicStore(g_state.overwriteNonTextClipboard, overwriteOn);
                saveConfig(cfg);
                uiLog(format("[CFG] Заменять нетекстовый буфер: %s", overwriteOn ? "вкл" : "выкл"));
            },
            (bool toggleOn) {
                cfg.toggleMode = toggleOn;
                saveConfig(cfg);
                uiLog(format("[CFG] Режим переключения (Toggle): %s", toggleOn ? "вкл" : "выкл"));
            },
            (bool checked) {
                cfg.autoLoadModel = checked;
                atomicStore(g_state.autoLoadModel, checked);
                saveConfig(cfg);
                uiLog(format("[CFG] Автозагрузка модели: %s", checked ? "вкл" : "выкл"));
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
                uiLog(format("[CFG] Звуковые сигналы: %s", beepOn ? "вкл" : "выкл"));
            },
            (bool overlayOn) {
                cfg.showOverlay = overlayOn;
                saveConfig(cfg);
                uiLog(format("[CFG] Плавающий индикатор (HUD): %s", overlayOn ? "вкл" : "выкл"));
            },
            (bool previewOn) {
                cfg.livePreview = previewOn;
                atomicStore(g_state.livePreview, previewOn);
                saveConfig(cfg);
                uiLog(format("[CFG] Предпросмотр речи (Live): %s", previewOn ? "вкл" : "выкл"));
            },
            (bool checked) {
                cfg.startMinimized = checked;
                saveConfig(cfg);
                uiLog(format("[CFG] Запускать в трее сразу: %s", checked ? "вкл" : "выкл"));
            },
            (bool checked) {
                if (setWindowsAutostart(checked)) {
                    uiLog(format("[CFG] Автозапуск с Windows: %s", checked ? "вкл" : "выкл"));
                } else {
                    uiLog("[ОШИБКА] Не удалось изменить запись автозапуска в реестре.");
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
