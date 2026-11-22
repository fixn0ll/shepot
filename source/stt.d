module stt;

import config : AppConfig, resolvePath;
import std.array : appender;
import std.file : exists;
import std.math : sqrt;
import std.string : fromStringz, strip, toLower, toStringz;
import whisper_c;

/// Возвращает среднеквадратичную громкость (RMS) аудиосэмплов.
double calcRms(const(float)[] samples) {
    if (samples.length == 0) return 0.0;
    double sum = 0.0;
    foreach (s; samples) {
        sum += cast(double) s * cast(double) s;
    }
    return sqrt(sum / samples.length);
}

/// Проверяет, проходит ли запись порог длительности и громкости.
bool isSpeechValid(const(float)[] samples, double minDurationSec, double rmsThreshold) {
    double duration = cast(double) samples.length / WHISPER_SAMPLE_RATE;
    if (duration < minDurationSec) return false;
    return calcRms(samples) >= rmsThreshold;
}

/// Отсеивает типичные галлюцинации Whisper на пустой/тихой речи.
bool isHallucination(string text) {
    auto t = text.strip().toLower();
    if (t.length == 0) return true;

    static immutable string[] phantoms = [
        "субтитры создавал",
        "субтитры делал",
        "редактор субтитров",
        "продолжение следует",
        "спасибо за просмотр",
        "подписывайтесь на канал",
        "[музыка]",
        "[аплодисменты]",
        "[тишина]",
        "(музыка)",
        "thank you for watching",
        "thanks for watching",
    ];
    foreach (p; phantoms) {
        if (t == p || (t.length <= p.length + 24 && indexOfFast(t, p))) {
            return true;
        }
    }
    return false;
}

private bool indexOfFast(string haystack, string needle) {
    import std.algorithm.searching : canFind;
    return haystack.canFind(needle);
}

private extern (C) void whisperProgressTrampoline(
    whisper_context* ctx,
    whisper_state* state,
    int progress,
    void* userData
) nothrow {
    if (userData is null) return;
    auto fn = cast(void function(int) nothrow) userData;
    fn(progress);
}

struct WhisperRecognizer {
    private WhisperApi m_api;
    private whisper_context* m_ctx;
    private string m_modelPath;
    private string m_language;
    private int m_threads;
    private bool m_useGpu;

    bool initApi(const ref AppConfig cfg, out string err) {
        auto dllPath = resolvePath(cfg.whisperDll);
        if (!m_api.load(dllPath, err)) return false;

        m_modelPath = resolvePath(cfg.modelPath);
        m_language = cfg.language.length ? cfg.language : "auto";
        m_threads = cfg.threads > 0 ? cfg.threads : 4;
        m_useGpu = cfg.useGpu;
        return true;
    }

    void setModelPath(string modelRelOrAbs) {
        m_modelPath = resolvePath(modelRelOrAbs);
    }

    string modelPath() const {
        return m_modelPath;
    }

    void setLanguage(string lang) {
        m_language = lang.length ? lang : "auto";
    }

    void setUseGpu(bool useGpu) {
        m_useGpu = useGpu;
    }

    bool useGpu() const {
        return m_useGpu;
    }

    bool isLoaded() const {
        return m_ctx !is null;
    }

    bool loadModel(out string err) {
        if (m_ctx !is null) return true;
        if (!exists(m_modelPath)) {
            err = "Модель не найдена: " ~ m_modelPath;
            return false;
        }

        auto cparamsPtr = m_api.contextDefaultParamsByRef();
        whisper_context_params cparams = *cparamsPtr;
        m_api.freeContextParams(cparamsPtr);

        cparams.use_gpu = m_useGpu;
        cparams.flash_attn = true;

        m_ctx = m_api.initFromFileWithParams(m_modelPath.toStringz(), cparams);
        if (m_ctx is null) {
            err = "Не удалось загрузить модель Whisper: " ~ m_modelPath;
            return false;
        }

        warmup();
        return true;
    }

    void unloadModel() {
        if (m_ctx !is null) {
            m_api.freeContext(m_ctx);
            m_ctx = null;
        }
    }

    string whisperVersion() {
        return m_api.versionStr ? m_api.versionStr().fromStringz().idup : "unknown";
    }

    /// Прогрев модели тишиной (убирает задержку компиляции Vulkan-шейдеров при первой диктовке).
    int warmup() {
        if (m_ctx is null) return -1;
        float[WHISPER_SAMPLE_RATE / 2] silence = 0.0f;
        int rc = 0;
        transcribe(silence[], &rc, null);
        return rc;
    }

    string transcribe(
        const(float)[] samples,
        int* outRc = null,
        void function(int) nothrow onProgress = null
    ) {
        if (m_ctx is null || samples.length == 0) return null;

        auto paramsPtr = m_api.fullDefaultParamsByRef(whisper_sampling_strategy.WHISPER_SAMPLING_GREEDY);
        whisper_full_params params = *paramsPtr;
        m_api.freeParams(paramsPtr);

        params.n_threads = m_threads;
        params.language = m_language.toStringz();
        params.no_context = true;
        params.print_progress = false;
        params.print_realtime = false;
        params.print_special = false;
        params.print_timestamps = false;
        params.suppress_blank = true;
        params.suppress_nst = true;
        if (onProgress !is null) {
            params.progress_callback = &whisperProgressTrampoline;
            params.progress_callback_user_data = cast(void*) onProgress;
        }

        int rc = m_api.full(m_ctx, params, samples.ptr, cast(int) samples.length);
        if (outRc !is null) *outRc = rc;
        if (rc != 0) return null;

        auto result = appender!string();
        int nSeg = m_api.fullNSegments(m_ctx);
        foreach (i; 0 .. nSeg) {
            auto segPtr = m_api.fullGetSegmentText(m_ctx, i);
            if (segPtr !is null) {
                result.put(segPtr.fromStringz());
            }
        }

        auto cleaned = result.data.strip();
        if (isHallucination(cleaned)) return null;
        return cleaned;
    }

    void close() {
        unloadModel();
        m_api.unload();
    }
}

/// Возвращает хвост UTF-8 строки длиной не более maxChars символов.
string tailPreview(string text, size_t maxChars = 48) {
    import std.range : walkLength;
    import std.utf : stride;
    size_t total = walkLength(text);
    if (total <= maxChars) return text;
    size_t skip = total - (maxChars - 1);
    size_t bytePos = 0;
    foreach (_; 0 .. skip) {
        bytePos += stride(text, bytePos);
    }
    return "…" ~ text[bytePos .. $];
}

unittest {
    float[4000] quiet = 0.0f;
    assert(!isSpeechValid(quiet[], 0.3, 0.005));

    float[8000] silent = 0.0001f;
    assert(!isSpeechValid(silent[], 0.3, 0.005));

    float[8000] loud = 0.05f;
    assert(isSpeechValid(loud[], 0.3, 0.005));

    assert(isHallucination("  Субтитры создавал DimaTorzok  "));
    assert(isHallucination("[Музыка]"));
    assert(!isHallucination("Привет, это тест диктовки."));
    assert(tailPreview("Привет", 10) == "Привет");
    assert(tailPreview("Привет, мир!", 5) == "…мир!");
}
