module bootstrap;

import config : AppConfig, resolvePath;
import std.algorithm.searching : endsWith, startsWith;
import std.conv : to;
import std.file : dirEntries, exists, mkdirRecurse, remove, rename, rmdirRecurse, SpanMode;
import std.path : baseName, buildPath, dirName;
import std.process : pipeProcess, Redirect, spawnProcess, wait;
import std.stdio : writeln, writefln;
import std.string : strip;

private enum string VulkanRuntimeUrl =
    "https://api.nuget.org/v3-flatcontainer/whisper.net.runtime.vulkan/1.9.1/whisper.net.runtime.vulkan.1.9.1.nupkg";
private enum string HfModelBaseUrl =
    "https://huggingface.co/ggerganov/whisper.cpp/resolve/main/";

/// Проверяет наличие whisper.dll и модели; при отсутствии скачивает автоматически.
bool ensureAssets(const ref AppConfig cfg, bool allowDownload) {
    auto dllPath = resolvePath(cfg.whisperDll);
    auto modelPath = resolvePath(cfg.modelPath);

    if (exists(dllPath) && exists(modelPath)) {
        return true;
    }

    if (!allowDownload) {
        if (!exists(dllPath)) writefln("Отсутствует библиотека: %s", dllPath);
        if (!exists(modelPath)) writefln("Отсутствует модель: %s", modelPath);
        return false;
    }

    if (!exists(dllPath)) {
        if (!downloadVulkanRuntime(dirName(dllPath))) return false;
    }

    if (!exists(modelPath)) {
        if (!downloadModel(modelPath, null)) return false;
    }
    return true;
}

bool downloadVulkanRuntime(string targetDir) {
    mkdirRecurse(targetDir);
    auto nupkg = buildPath(targetDir, "_whisper_vulkan.nupkg");
    auto tmpExtract = buildPath(targetDir, "_whisper_extract");

    scope (exit) {
        if (exists(nupkg)) remove(nupkg);
        if (exists(tmpExtract)) rmdirRecurse(tmpExtract);
    }

    writeln("Скачивание Vulkan-библиотек whisper.cpp (~35 МБ)...");
    if (!runTool(["curl.exe", "-fL", "--progress-bar", VulkanRuntimeUrl, "-o", nupkg])) {
        writeln("Ошибка: не удалось скачать Vulkan-пакет whisper.cpp.");
        return false;
    }

    mkdirRecurse(tmpExtract);
    writeln("Распаковка DLL...");
    if (!runTool(["tar.exe", "-xf", nupkg, "-C", tmpExtract, "build/win-x64"])) {
        writeln("Ошибка: не удалось распаковать архив через tar.exe.");
        return false;
    }

    auto winDir = buildPath(tmpExtract, "build", "win-x64");
    if (!exists(winDir)) {
        writeln("Ошибка: в архиве не найдена папка build/win-x64.");
        return false;
    }

    size_t count = 0;
    foreach (entry; dirEntries(winDir, "*.dll", SpanMode.shallow)) {
        auto dst = buildPath(targetDir, baseName(entry.name));
        if (exists(dst)) remove(dst);
        rename(entry.name, dst);
        ++count;
    }
    writefln("Установлено DLL: %s", count);
    return count > 0;
}

bool downloadModel(string modelPath, void delegate(int pct) onProgress = null) {
    auto fileName = baseName(modelPath);
    if (!isStandardModelName(fileName)) {
        if (onProgress is null) {
            writefln("Модель не найдена: %s (нестандартное имя, скачайте вручную)", modelPath);
        }
        return false;
    }

    mkdirRecurse(dirName(modelPath));
    auto partPath = modelPath ~ ".part";
    scope (exit) {
        if (exists(partPath)) remove(partPath);
    }

    auto url = HfModelBaseUrl ~ fileName;
    string[] cmd = ["curl.exe", "-fL", "--progress-bar", url, "-o", partPath];

    bool ok;
    if (onProgress is null) {
        writefln("Скачивание модели %s...", fileName);
        ok = runTool(cmd);
    } else {
        ok = runCurlWithProgress(cmd, onProgress);
    }

    if (!ok) {
        if (onProgress is null) writeln("Ошибка: не удалось скачать модель с HuggingFace.");
        return false;
    }

    if (exists(modelPath)) remove(modelPath);
    rename(partPath, modelPath);
    if (onProgress is null) writeln("Модель сохранена.");
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
    auto pipes = pipeProcess(cmd, Redirect.stderrToStdout | Redirect.stdin);
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

private bool runTool(string[] args) {
    auto pid = spawnProcess(args);
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
