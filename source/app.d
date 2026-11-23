module app;

import audio : AudioCapture, listInputDevices;
import bootstrap : downloadModel, ensureAssets;
import config : AppConfig, loadConfig, normalizeInputMode, parseHotkeyVk, resolvePath, saveConfig, vkToKeyName;
import core.atomic : atomicLoad, atomicStore;
import core.time : MonoTime;
import os_win : acquireSingleInstance, attachParentConsoleIfAny, closeTempConsole,
    isWindowsAutostartEnabled, openTempConsole, releaseSingleInstance, runTrayApp,
    setWindowsAutostart, showErrorBox, typeText, uiLog, uiSetIdleStatus, uiSetLastPhrase,
    uiSetLoadWaiting, uiSetModelState, uiSetProgress, uiSetStatus, uiSetVisual, UiOption,
    VisualState;
import postprocess : ReplacementStore;
import sound : playActivationCueAsync, playClickAsync, playCueAsync;
import std.algorithm.searching : any, canFind;
import std.concurrency : OwnerTerminated, receive, send, spawn, Tid;
import std.file : exists;
import std.format : format;
import std.path : baseName;
import std.stdio : writeln, writefln;
import stt : calcRms, isSpeechValid, tailPreview, WhisperRecognizer;
import whisper_c : WHISPER_SAMPLE_RATE;

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
    string modelPath;
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
    int unloadTimeoutMin;
    int inputModeCode; // 0 = sendinput, 1 = clipboard, 2 = auto
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

private UiOption[] buildModelOptions(string currentModelPath) {
    UiOption[] opts = [
        UiOption("tiny (~75 МБ, сверхбыстрая)", "models/ggml-tiny.bin"),
        UiOption("base (~142 МБ, быстрая)", "models/ggml-base.bin"),
        UiOption("small-q5_1 (~182 МБ, лёгкая для CPU)", "models/ggml-small-q5_1.bin"),
        UiOption("medium-q5_0 (~515 МБ, баланс)", "models/ggml-medium-q5_0.bin"),
        UiOption("large-v3-turbo-q5_0 (~547 МБ, рекомендуется)", "models/ggml-large-v3-turbo-q5_0.bin"),
        UiOption("large-v3-turbo-q8_0 (~834 МБ, макс. точность)", "models/ggml-large-v3-turbo-q8_0.bin"),
    ];
    if (!opts.any!(o => o.value == currentModelPath)) {
        opts ~= UiOption(baseName(currentModelPath) ~ " (пользовательская)", currentModelPath);
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

private bool ensureModelDownloadedUi(string modelRelPath) {
    auto absPath = resolvePath(modelRelPath);
    if (exists(absPath)) return true;

    auto name = baseName(absPath);
    uiSetModelState(false, true);
    uiSetStatus(format("Скачивание %s: 0%%...", name));
    uiSetProgress(2, 0);
    uiLog(format("[DL] Начато скачивание модели %s...", name));

    bool ok = downloadModel(absPath, (int pct) {
        uiSetProgress(2, pct);
        uiSetStatus(format("Скачивание %s: %s%%...", name, pct));
    });

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

private bool ensureModelLoaded(WhisperRecognizer* recognizer, bool notifyCue) {
    if (recognizer.isLoaded()) {
        atomicStore(g_state.modelLoaded, true);
        atomicStore(g_state.modelLoading, false);
        uiSetLoadWaiting(false);
        uiSetProgress(0, 0);
        return true;
    }

    atomicStore(g_state.modelLoading, true);
    uiSetModelState(false, true);

    if (!exists(recognizer.modelPath())) {
        if (!ensureModelDownloadedUi(recognizer.modelPath())) {
            atomicStore(g_state.modelLoading, false);
            uiSetLoadWaiting(false);
            return false;
        }
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
    uiLog(format("[MDL] Модель %s загружена (%s) и прогрета.",
        baseName(recognizer.modelPath()), recognizer.useGpu() ? "GPU Vulkan" : "CPU"));
    if (notifyCue && atomicLoad(g_state.beepEnabled)) {
        playActivationCueAsync();
    }
    return true;
}

private void unloadModelNow(WhisperRecognizer* recognizer, string reason) {
    if (!recognizer.isLoaded()) return;
    recognizer.unloadModel();
    atomicStore(g_state.modelLoaded, false);
    uiSetModelState(false, false);
    uiSetProgress(0, 0);
    uiLog("[MDL] " ~ reason);
    uiSetIdleStatus(false);
}

private void workerLoop(shared(AudioCapture)* audioPtr, shared(WhisperRecognizer)* sttPtr, immutable AppConfig cfg) {
    auto audio = cast(AudioCapture*) audioPtr;
    auto recognizer = cast(WhisperRecognizer*) sttPtr;
    ReplacementStore replacements;

    if (cfg.autoLoadModel) {
        if (ensureModelLoaded(recognizer, false)) {
            uiSetIdleStatus(true);
        }
    }

    bool running = true;
    while (running) {
        try {
            receive(
                (SwitchModelMsg msg) {
                    bool needReload = recognizer.isLoaded() || msg.reloadNow;
                    if (recognizer.isLoaded()) {
                        unloadModelNow(recognizer, "Смена модели...");
                    }
                    recognizer.setModelPath(msg.modelPath);
                    if (needReload) {
                        if (ensureModelLoaded(recognizer, true)) {
                            uiSetIdleStatus(true);
                        }
                    } else {
                        uiLog("[CFG] Выбрана модель: " ~ baseName(msg.modelPath));
                        uiSetIdleStatus(false);
                    }
                },
                (SetUseGpuMsg msg) {
                    bool wasLoaded = recognizer.isLoaded();
                    recognizer.setUseGpu(msg.useGpu);
                    if (wasLoaded) {
                        unloadModelNow(recognizer, format("Переключение режима на %s...", msg.useGpu ? "GPU Vulkan" : "CPU"));
                        if (ensureModelLoaded(recognizer, true)) {
                            uiSetIdleStatus(true);
                        }
                    } else {
                        uiLog(format("[CFG] Режим вычислений: %s", msg.useGpu ? "GPU (Vulkan)" : "Только процессор (CPU)"));
                    }
                },
                (SetLangMsg msg) {
                    recognizer.setLanguage(msg.language);
                    uiLog("[CFG] Язык распознавания: " ~ msg.language);
                },
                (WorkerCmd cmd) {
                    final switch (cmd) {
                        case WorkerCmd.shutdown:
                            running = false;
                            return;

                        case WorkerCmd.loadModel:
                            if (ensureModelLoaded(recognizer, true)) {
                                if (!atomicLoad(g_state.recording)) uiSetIdleStatus(true);
                            }
                            return;

                        case WorkerCmd.loadModelFromHotkey:
                            if (ensureModelLoaded(recognizer, true)) {
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

                            auto previewSamples = audio.peekBuffer(WHISPER_SAMPLE_RATE * 15);
                            if (!isSpeechValid(previewSamples, 0.4, cfg.rmsThreshold)) return;

                            auto draft = recognizer.transcribe(previewSamples, null, null, &shouldAbortPreview);
                            if (atomicLoad(g_state.recording) && draft.length > 0) {
                                uiSetVisual(VisualState.recording, tailPreview(draft));
                            }
                            return;

                        case WorkerCmd.transcribe:
                            auto samples = audio.stopAndTakeBuffer();
                            double dur = cast(double) samples.length / WHISPER_SAMPLE_RATE;
                            double rms = calcRms(samples);

                            if (!recognizer.isLoaded()) {
                                if (!ensureModelLoaded(recognizer, true)) {
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
                                uiLog(format("[ОШИБКА] whisper_full вернул код %s", rc));
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
                            typeText(text, mode, cfg.charDelayMs, cfg.clipboardRestoreDelayMs, method);
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
            uiSetIdleStatus(recognizer.isLoaded());
        }
    }
}

version (unittest) {
    // Точка входа отключена при запуске dub test
} else {
    int main(string[] args) {
        bool checkOnly = args.canFind("--check");
        bool setupOnly = args.canFind("--setup");
        bool allowDownload = !args.canFind("--no-download");

        if (checkOnly || setupOnly) {
            attachParentConsoleIfAny();
        } else {
            if (!acquireSingleInstance()) return 0;
        }
        scope (exit) {
            if (!checkOnly && !setupOnly) releaseSingleInstance();
        }

        auto cfg = loadConfig();
        bool needTempConsole = !checkOnly && !setupOnly && allowDownload &&
            (!exists(resolvePath(cfg.whisperDll)) || !exists(resolvePath(cfg.modelPath)));
        if (needTempConsole) openTempConsole();

        bool assetsOk = ensureAssets(cfg, allowDownload);
        if (needTempConsole) closeTempConsole();

        if (!assetsOk) {
            auto msg = "Не хватает зависимостей. Запустите с --setup или положите whisper.dll и модель в bin/.";
            if (checkOnly || setupOnly) writeln(msg);
            else showErrorBox(msg);
            return 1;
        }
        if (setupOnly) {
            writeln("Зависимости готовы.");
            return 0;
        }

        string err;
        WhisperRecognizer recognizer;
        if (checkOnly) writefln("Инициализация Whisper (%s)...", cfg.modelPath);
        if (!recognizer.initApi(cfg, err)) {
            if (checkOnly) writeln("Ошибка: ", err);
            else showErrorBox(err);
            return 1;
        }
        scope (exit) recognizer.close();

        if (checkOnly) {
            writeln("Загрузка и прогрев модели...");
            if (!recognizer.loadModel(err)) {
                writeln("Ошибка: ", err);
                return 1;
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
            writefln("Whisper version=%s", recognizer.whisperVersion());
            capture.startRecording();
            Thread.sleep(500.msecs);
            auto testBuf = capture.stopAndTakeBuffer();
            writefln("Микрофон: %s сэмплов за 500мс, RMS=%.5f", testBuf.length, calcRms(testBuf));
            writeln("Проверка пройдена: Whisper, Vulkan/модель и микрофон инициализированы.");
            return 0;
        }

        atomicStore(g_state.modelLoaded, false);
        atomicStore(g_state.modelLoading, cfg.autoLoadModel);
        atomicStore(g_state.recording, false);
        atomicStore(g_state.autoLoadModel, cfg.autoLoadModel);
        atomicStore(g_state.beepEnabled, cfg.beep);
        atomicStore(g_state.livePreview, cfg.livePreview);
        atomicStore(g_state.previewBusy, false);
        atomicStore(g_state.unloadTimeoutMin, cfg.unloadTimeoutMin);
        atomicStore(g_state.inputModeCode, encodeInputMode(normalizeInputMode(cfg.inputMode)));
        atomicStore(g_state.lastActivityMs, nowMs());

        auto hotkeyVk = parseHotkeyVk(cfg.hotkey);
        auto hotkeyName = vkToKeyName(hotkeyVk);
        auto mics = listInputDevices();
        auto modelOpts = buildModelOptions(cfg.modelPath);
        auto langOpts = buildLangOptions(cfg.language);
        bool winAuto = isWindowsAutostartEnabled();

        immutable AppConfig immCfg = cfg;
        Tid worker = spawn(&workerLoop, cast(shared(AudioCapture)*) &capture, cast(shared(WhisperRecognizer)*) &recognizer, immCfg);
        scope (exit) worker.send(WorkerCmd.shutdown);

        string[] initLogs = [
            format("Whisper %s готов (%s, режим: %s)",
                recognizer.whisperVersion(), baseName(cfg.modelPath), cfg.useGpu ? "GPU Vulkan" : "CPU"),
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
            cfg.modelPath,
            langOpts,
            cfg.language,
            normalizeInputMode(cfg.inputMode),
            cfg.startMinimized,
            cfg.autoLoadModel,
            !cfg.useGpu,
            winAuto,
            cfg.showOverlay,
            cfg.beep,
            cfg.livePreview,
            cfg.unloadTimeoutMin,
            false,
            cfg.autoLoadModel,
            initLogs,
            () {
                atomicStore(g_state.recording, true);
                atomicStore(g_state.lastActivityMs, nowMs());
                capture.startRecording();
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
            (string newModelPath) {
                cfg.modelPath = newModelPath;
                saveConfig(cfg);
                worker.send(SwitchModelMsg(newModelPath, atomicLoad(g_state.autoLoadModel)));
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
