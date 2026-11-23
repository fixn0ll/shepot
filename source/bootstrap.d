module bootstrap;

import config : AppConfig, modelOptionId, normalizeEngine, resolvePath;
import std.algorithm.searching : endsWith, startsWith;
import std.conv : to;
import std.file : dirEntries, exists, mkdirRecurse, remove, rename, rmdirRecurse, SpanMode;
import std.path : baseName, buildPath, dirName;
import std.process : Config, pipeProcess, Redirect, spawnProcess, wait;
import std.stdio : stdout, writeln, writefln;
import std.string : strip;

private enum string VulkanRuntimeUrl =
    "https://api.nuget.org/v3-flatcontainer/whisper.net.runtime.vulkan/1.9.1/whisper.net.runtime.vulkan.1.9.1.nupkg";
private enum string HfModelBaseUrl =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

private enum string SherpaRuntimeUrl =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/v2.0.3/sherpa-onnx-v2.0.3-win-x64-shared-MD-Release-no-tts-lib.tar.bz2";
private enum string GigaAmV3PunctUrl =
    "https://github.com/k2-fsa/sherpa-onnx/releases/download/asr-models/sherpa-onnx-nemo-transducer-punct-giga-am-v3-russian-2025-12-16.tar.bz2";
private enum string GigaAmMultiModelUrl =
    "https://huggingface.co/i2z1/gigaam-multilingual-ctc-onnx-int8/resolve/main/model.int8.onnx";
private enum string GigaAmMultiTokensUrl =
    "https://huggingface.co/i2z1/gigaam-multilingual-ctc-onnx-int8/resolve/main/tokens.txt";

bool isSherpaModelReady(const ref AppConfig cfg) {
    if (cfg.sherpaTokens.length == 0 || !exists(resolvePath(cfg.sherpaTokens))) return false;
    if (cfg.sherpaCtcModel.length > 0 && cfg.sherpaEncoder.length == 0) {
        return exists(resolvePath(cfg.sherpaCtcModel));
    }
    return cfg.sherpaEncoder.length > 0 && exists(resolvePath(cfg.sherpaEncoder)) &&
           cfg.sherpaDecoder.length > 0 && exists(resolvePath(cfg.sherpaDecoder)) &&
           cfg.sherpaJoiner.length > 0 && exists(resolvePath(cfg.sherpaJoiner));
}

bool hasAllStartupAssets(const ref AppConfig cfg) {
    if (normalizeEngine(cfg.engine) == "sherpa") {
        return exists(resolvePath(cfg.sherpaDll)) && isSherpaModelReady(cfg);
    }
    return exists(resolvePath(cfg.whisperDll)) && exists(resolvePath(cfg.modelPath));
}

/// Проверяет наличие DLL и модели для активного движка; при отсутствии скачивает автоматически.
bool ensureAssets(const ref AppConfig cfg, bool allowDownload) {
    if (normalizeEngine(cfg.engine) == "sherpa") {
        auto dllPath = resolvePath(cfg.sherpaDll);
        bool dllOk = exists(dllPath);
        bool mdlOk = isSherpaModelReady(cfg);
        if (dllOk && mdlOk) return true;

        if (!allowDownload) {
            if (!dllOk) writefln("Отсутствует библиотека sherpa-onnx: %s", dllPath);
            if (!mdlOk) writeln("Отсутствуют файлы модели sherpa-onnx / GigaAM.");
            stdout.flush();
            return false;
        }

        if (!dllOk && !downloadSherpaRuntime(dirName(dllPath), null)) return false;
        if (!mdlOk && !downloadSherpaModel(cfg, null)) return false;
        return true;
    }

    auto dllPath = resolvePath(cfg.whisperDll);
    auto modelPath = resolvePath(cfg.modelPath);
    if (exists(dllPath) && exists(modelPath)) return true;

    if (!allowDownload) {
        if (!exists(dllPath)) writefln("Отсутствует библиотека: %s", dllPath);
        if (!exists(modelPath)) writefln("Отсутствует модель: %s", modelPath);
        stdout.flush();
        return false;
    }

    if (!exists(dllPath) && !downloadVulkanRuntime(dirName(dllPath), null)) return false;
    if (!exists(modelPath) && !downloadModel(modelPath, null)) return false;
    return true;
}

bool downloadVulkanRuntime(string targetDir, void delegate(int pct) onProgress = null) {
    mkdirRecurse(targetDir);
    auto nupkg = buildPath(targetDir, "_whisper_vulkan.nupkg");
    auto tmpExtract = buildPath(targetDir, "_whisper_extract");

    scope (exit) {
        if (exists(nupkg)) remove(nupkg);
        if (exists(tmpExtract)) rmdirRecurse(tmpExtract);
    }

    if (onProgress is null) writeln("Скачивание Vulkan-библиотек whisper.cpp (~35 МБ)...");
    if (!downloadFile(VulkanRuntimeUrl, nupkg, onProgress)) {
        if (onProgress is null) writeln("Ошибка: не удалось скачать Vulkan-пакет whisper.cpp.");
        return false;
    }

    mkdirRecurse(tmpExtract);
    if (onProgress is null) writeln("Распаковка DLL...");
    if (!runTool(["tar.exe", "-xf", nupkg, "-C", tmpExtract, "build/win-x64"], onProgress !is null)) {
        if (onProgress is null) writeln("Ошибка: не удалось распаковать архив через tar.exe.");
        return false;
    }

    auto winDir = buildPath(tmpExtract, "build", "win-x64");
    if (!exists(winDir)) {
        if (onProgress is null) writeln("Ошибка: в архиве не найдена папка build/win-x64.");
        return false;
    }

    size_t count = 0;
    foreach (entry; dirEntries(winDir, "*.dll", SpanMode.shallow)) {
        auto dst = buildPath(targetDir, baseName(entry.name));
        if (exists(dst)) remove(dst);
        rename(entry.name, dst);
        ++count;
    }
    if (onProgress is null) writefln("Установлено DLL: %s", count);
    return count > 0;
}

bool downloadSherpaRuntime(string targetDir, void delegate(int pct) onProgress = null) {
    mkdirRecurse(targetDir);
    auto archive = buildPath(targetDir, "_sherpa_runtime.tar.bz2");
    scope (exit) {
        if (exists(archive)) remove(archive);
    }

    if (onProgress is null) writeln("Скачивание sherpa-onnx Runtime для Windows x64...");
    if (!downloadFile(SherpaRuntimeUrl, archive, onProgress)) {
        if (onProgress is null) writeln("Ошибка: не удалось скачать sherpa-onnx-c-api.dll.");
        return false;
    }

    enum string prefix = "sherpa-onnx-v2.0.3-win-x64-shared-MD-Release-no-tts-lib/lib/";
    if (onProgress is null) writeln("Распаковка sherpa-onnx DLL...");
    return runTool([
        "tar.exe", "-xjf", archive, "-C", targetDir, "--strip-components=2",
        prefix ~ "onnxruntime.dll",
        prefix ~ "onnxruntime_providers_shared.dll",
        prefix ~ "sherpa-onnx-c-api.dll",
    ], onProgress !is null);
}

bool downloadSherpaModel(const ref AppConfig cfg, void delegate(int pct) onProgress = null) {
    auto id = modelOptionId(cfg);
    if (id == "sherpa:gigaam-v3-punct") {
        auto encAbs = resolvePath(cfg.sherpaEncoder);
        auto modelsRoot = dirName(dirName(encAbs));
        mkdirRecurse(modelsRoot);
        auto archive = buildPath(modelsRoot, "_gigaam_v3_punct.tar.bz2");
        scope (exit) {
            if (exists(archive)) remove(archive);
        }

        if (onProgress is null) writeln("Скачивание GigaAM v3 RNN-T Punct (~162 МБ)...");
        if (!downloadFile(GigaAmV3PunctUrl, archive, onProgress)) {
            if (onProgress is null) writeln("Ошибка: не удалось скачать GigaAM v3.");
            return false;
        }
        if (onProgress is null) writeln("Распаковка GigaAM v3...");
        return runTool(["tar.exe", "-xjf", archive, "-C", modelsRoot], onProgress !is null);
    }

    if (id == "sherpa:gigaam-multilingual") {
        auto modelAbs = resolvePath(cfg.sherpaCtcModel);
        auto tokensAbs = resolvePath(cfg.sherpaTokens);
        mkdirRecurse(dirName(modelAbs));

        if (!exists(tokensAbs)) {
            if (!downloadFile(GigaAmMultiTokensUrl, tokensAbs, null)) return false;
        }
        if (!exists(modelAbs)) {
            if (onProgress is null) writeln("Скачивание GigaAM Multilingual CTC int8 (~215 МБ)...");
            if (!downloadFile(GigaAmMultiModelUrl, modelAbs, onProgress)) return false;
        }
        return true;
    }

    if (onProgress is null) writeln("Пользовательская sherpa-модель не найдена (автоскачивание не поддерживается).");
    return false;
}

bool downloadModel(string modelPath, void delegate(int pct) onProgress = null) {
    auto fileName = baseName(modelPath);
    if (!isStandardModelName(fileName)) {
        if (onProgress is null) {
            writefln("Модель не найдена: %s (нестандартное имя, скачайте вручную)", modelPath);
        }
        return false;
    }

    if (onProgress is null) writefln("Скачивание модели %s...", fileName);
    bool ok = downloadFile(HfModelBaseUrl ~ fileName, modelPath, onProgress);
    if (!ok && onProgress is null) {
        writeln("Ошибка: не удалось скачать модель с HuggingFace.");
    } else if (ok && onProgress is null) {
        writeln("Модель сохранена.");
    }
    return ok;
}

private bool downloadFile(string url, string dstPath, void delegate(int pct) onProgress) {
    mkdirRecurse(dirName(dstPath));
    auto partPath = dstPath ~ ".part";
    scope (exit) {
        if (exists(partPath)) remove(partPath);
    }

    string[] cmd = ["curl.exe", "-fL", "--progress-bar", url, "-o", partPath];
    bool ok = (onProgress is null) ? runTool(cmd) : runCurlWithProgress(cmd, onProgress);
    if (!ok) return false;

    if (exists(dstPath)) remove(dstPath);
    rename(partPath, dstPath);
    return true;
}

bool isStandardModelName(string fileName) {
    return fileName.startsWith("ggml-") && fileName.endsWith(".bin");
}

int parseCurlPercent(string line) {
    auto s = line.strip();
    if (s.length == 0 || s[$ - 1] != '%') return -1;

    size_t start = s.length - 1;
    while (start > 0 && ((s[start - 1] >= '0' && s[start - 1] <= '9') || s[start - 1] == '.')) {
        --start;
    }
    if (start == s.length - 1) return -1;

    try {
        double val = to!double(s[start .. $ - 1]);
        int pct = cast(int)(val + 0.5);
        if (pct < 0) pct = 0;
        if (pct > 100) pct = 100;
        return pct;
    } catch (Exception) {
        return -1;
    }
}

private bool runCurlWithProgress(string[] cmd, void delegate(int) onProgress) {
    auto pipes = pipeProcess(cmd, Redirect.stderrToStdout | Redirect.stdin, null, Config.suppressConsole);
    pipes.stdin.close();

    int lastPct = -1;
    char[] lineBuf;
    ubyte[256] raw;

    while (true) {
        auto chunk = pipes.stdout.rawRead(raw[]);
        if (chunk.length == 0) break;
        foreach (b; chunk) {
            char c = cast(char) b;
            if (c == '\r' || c == '\n') {
                if (lineBuf.length > 0) {
                    int pct = parseCurlPercent(cast(string) lineBuf);
                    if (pct >= 0 && pct != lastPct) {
                        lastPct = pct;
                        onProgress(pct);
                    }
                    lineBuf.length = 0;
                }
            } else {
                lineBuf ~= c;
            }
        }
    }
    if (lineBuf.length > 0) {
        int pct = parseCurlPercent(cast(string) lineBuf);
        if (pct >= 0 && pct != lastPct) onProgress(pct);
    }

    return wait(pipes.pid) == 0;
}

private bool runTool(string[] args, bool silent = false) {
    auto pid = spawnProcess(args, null, silent ? Config.suppressConsole : Config.none);
    return wait(pid) == 0;
}

unittest {
    assert(isStandardModelName("ggml-large-v3-turbo-q5_0.bin"));
    assert(isStandardModelName("ggml-small-q5_1.bin"));
    assert(!isStandardModelName("custom_model.gguf"));
    assert(parseCurlPercent("######                         54.1%") == 54);
    assert(parseCurlPercent("######################################## 100.0%") == 100);
    assert(parseCurlPercent("##O#-#") == -1);
}
