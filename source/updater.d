module updater;

import bootstrap : downloadFile;
import config : APP_VERSION, appDataDir, exeDir;
import i18n : tr;
import std.algorithm.searching : canFind, endsWith;
import std.array : split;
import std.conv : to;
import std.file : exists, mkdirRecurse, thisExePath, write;
import std.json : JSONType, parseJSON;
import std.path : buildPath;
import std.process : Config, pipeProcess, Redirect, spawnProcess, wait;
import std.string : strip, toLower;

private enum string GithubLatestReleaseUrl =
    "https://api.github.com/repos/fixn0ll/shepot/releases/latest";

struct UpdateInfo {
    bool available;
    string latestTag;
    string setupUrl;
    string exeUrl;
    string htmlUrl;
}

private int[] parseVersionParts(string raw) {
    auto s = raw.strip();
    if (s.length > 0 && (s[0] == 'v' || s[0] == 'V')) s = s[1 .. $];
    foreach (i, c; s) {
        if (c == '-' || c == '+') {
            s = s[0 .. i];
            break;
        }
    }
    int[] parts;
    foreach (seg; s.split(".")) {
        auto clean = seg.strip();
        if (clean.length == 0) {
            parts ~= 0;
            continue;
        }
        try {
            parts ~= to!int(clean);
        } catch (Exception) {
            parts ~= 0;
        }
    }
    return parts;
}

bool isNewerVersion(string candidate, string current) {
    auto a = parseVersionParts(candidate);
    auto b = parseVersionParts(current);
    size_t n = a.length > b.length ? a.length : b.length;
    foreach (i; 0 .. n) {
        int av = i < a.length ? a[i] : 0;
        int bv = i < b.length ? b[i] : 0;
        if (av != bv) return av > bv;
    }
    return false;
}

bool isInstalledApp() {
    return exists(buildPath(exeDir(), "unins000.exe"));
}

bool parseReleaseJson(string jsonText, string currentVersion, out UpdateInfo info) {
    auto root = parseJSON(jsonText);
    if (root.type != JSONType.object) return false;
    auto pTag = "tag_name" in root;
    if (pTag is null || pTag.type != JSONType.string || pTag.str.length == 0) return false;

    info.latestTag = pTag.str.strip();
    if (auto pHtml = "html_url" in root) {
        if (pHtml.type == JSONType.string) info.htmlUrl = pHtml.str;
    }
    if (auto pAssets = "assets" in root) {
        if (pAssets.type == JSONType.array) {
            foreach (asset; pAssets.array) {
                if (asset.type != JSONType.object) continue;
                auto pName = "name" in asset;
                auto pUrl = "browser_download_url" in asset;
                if (pName is null || pUrl is null) continue;
                if (pName.type != JSONType.string || pUrl.type != JSONType.string) continue;
                auto nl = pName.str.toLower();
                if (!nl.endsWith(".exe")) continue;
                if (nl.canFind("setup")) info.setupUrl = pUrl.str;
                else if (nl == "shepot.exe") info.exeUrl = pUrl.str;
            }
        }
    }

    info.available = isNewerVersion(info.latestTag, currentVersion);
    return true;
}

bool checkLatestRelease(string currentVersion, out UpdateInfo info, out string err) {
    try {
        auto pipes = pipeProcess([
            "curl.exe", "-fsSL", "--max-time", "8",
            "-H", "Accept: application/vnd.github+json",
            "-H", "User-Agent: Shepot/" ~ APP_VERSION,
            GithubLatestReleaseUrl
        ], Redirect.stdout | Redirect.stderrToStdout | Redirect.stdin, null, Config.suppressConsole);
        pipes.stdin.close();

        char[] bodyBuf;
        ubyte[4096] chunk;
        while (true) {
            auto r = pipes.stdout.rawRead(chunk[]);
            if (r.length == 0) break;
            bodyBuf ~= cast(const(char)[]) r;
        }
        int rc = wait(pipes.pid);
        if (rc != 0 || bodyBuf.length == 0) {
            err = tr("Failed to check GitHub updates.", "Не удалось проверить обновления на GitHub.");
            return false;
        }
        if (!parseReleaseJson(cast(string) bodyBuf, currentVersion, info)) {
            err = tr("Unexpected response from GitHub API.", "Некорректный ответ GitHub API.");
            return false;
        }
        return true;
    } catch (Exception e) {
        err = e.msg;
        return false;
    }
}

bool downloadAndLaunchUpdate(const ref UpdateInfo info, void delegate(int pct) onProgress, out string err) {
    auto dataDir = appDataDir();
    mkdirRecurse(dataDir);

    if ((isInstalledApp() || info.exeUrl.length == 0) && info.setupUrl.length > 0) {
        auto setupPath = buildPath(dataDir, "_ShepotSetup.exe");
        if (!downloadFile(info.setupUrl, setupPath, onProgress)) {
            err = tr("Failed to download installer.", "Не удалось скачать установщик.");
            return false;
        }
        auto args = isInstalledApp()
            ? [setupPath, "/SILENT", "/CLOSEAPPLICATIONS", "/RESTARTAPPLICATIONS"]
            : [setupPath, "/CLOSEAPPLICATIONS", "/RESTARTAPPLICATIONS"];
        spawnProcess(args, null, Config.detached);
        return true;
    }

    if (info.exeUrl.length == 0) {
        err = tr("No shepot.exe asset found in release.", "В релизе не найден файл shepot.exe.");
        return false;
    }

    auto staged = buildPath(dataDir, "_shepot_update.exe");
    if (!downloadFile(info.exeUrl, staged, onProgress)) {
        err = tr("Failed to download update.", "Не удалось скачать обновление.");
        return false;
    }

    auto curExe = thisExePath();
    auto batPath = buildPath(dataDir, "_apply_update.cmd");
    auto script =
        "@echo off\r\n" ~
        "for /l %%i in (1,1,30) do (\r\n" ~
        "  copy /y \"" ~ staged ~ "\" \"" ~ curExe ~ "\" >nul 2>&1 && goto run\r\n" ~
        "  ping -n 2 127.0.0.1 >nul\r\n" ~
        ")\r\n" ~
        "exit /b 1\r\n" ~
        ":run\r\n" ~
        "del \"" ~ staged ~ "\" >nul 2>&1\r\n" ~
        "start \"\" \"" ~ curExe ~ "\"\r\n" ~
        "del \"%~f0\" >nul 2>&1\r\n";
    write(batPath, script);
    spawnProcess(["cmd.exe", "/c", batPath], null, Config.suppressConsole | Config.detached);
    return true;
}

unittest {
    assert(isNewerVersion("v0.1.3", "0.1.2"));
    assert(isNewerVersion("v1.0.0", "0.9.9"));
    assert(!isNewerVersion("v0.1.2", "0.1.2"));
    assert(!isNewerVersion("v0.1.1", "0.1.2"));

    UpdateInfo inf;
    auto sample = `{
        "tag_name": "v0.2.0",
        "html_url": "https://github.com/fixn0ll/shepot/releases/tag/v0.2.0",
        "assets": [
            {"name": "ShepotSetup.exe", "browser_download_url": "https://example.com/ShepotSetup.exe"},
            {"name": "shepot.exe", "browser_download_url": "https://example.com/shepot.exe"}
        ]
    }`;
    assert(parseReleaseJson(sample, "0.1.3", inf));
    assert(inf.available && inf.latestTag == "v0.2.0");
    assert(inf.setupUrl == "https://example.com/ShepotSetup.exe");
    assert(inf.exeUrl == "https://example.com/shepot.exe");

    assert(parseReleaseJson(sample, "0.2.0", inf));
    assert(!inf.available);
}
