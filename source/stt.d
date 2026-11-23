module stt;

import config : AppConfig, resolvePath;
import std.array : appender;
import std.file : exists;
import std.string : fromStringz, strip, toStringz;
import stt_engine : isHallucination, SAMPLE_RATE, SttEngine;
import whisper_c;

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

private extern (C) bool whisperAbortTrampoline(void* userData) nothrow {
    if (userData is null) return false;
    auto fn = cast(bool function() nothrow) userData;
    return fn();
}

class WhisperRecognizer : SttEngine {
    private WhisperApi m_api;
    private whisper_context* m_ctx;
    private string m_modelPath;
    private string m_language;
    private string m_initialPrompt;
    private int m_threads;
    private bool m_useGpu;

    override bool initApi(const ref AppConfig cfg, out string err) {
        auto dllPath = resolvePath(cfg.whisperDll);
        if (!m_api.load(dllPath, err)) return false;

        m_modelPath = resolvePath(cfg.modelPath);
        m_language = cfg.language.length ? cfg.language : "auto";
        m_initialPrompt = cfg.initialPrompt;
        m_threads = cfg.threads > 0 ? cfg.threads : 4;
        m_useGpu = cfg.useGpu;
        return true;
    }

    void setInitialPrompt(string prompt) {
        m_initialPrompt = prompt;
    }

    override void setModelPath(string modelRelOrAbs) {
        m_modelPath = resolvePath(modelRelOrAbs);
    }

    override string modelPath() const {
        return m_modelPath;
    }

    override void setLanguage(string lang) {
        m_language = lang.length ? lang : "auto";
    }

    override void setUseGpu(bool useGpu) {
        m_useGpu = useGpu;
    }

    override bool useGpu() const {
        return m_useGpu;
    }

    override bool supportsGpu() const {
        return true;
    }

    override bool isLoaded() const {
        return m_ctx !is null;
    }

    override bool supportsRemoteDownload() const {
        return true;
    }

    override bool loadModel(out string err) {
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

    override void unloadModel() {
        if (m_ctx !is null) {
            m_api.freeContext(m_ctx);
            m_ctx = null;
        }
    }

    override string engineVersion() {
        auto v = m_api.versionStr ? m_api.versionStr().fromStringz().idup : "unknown";
        return "Whisper " ~ v;
    }

    /// Прогрев модели тишиной (убирает задержку компиляции Vulkan-шейдеров при первой диктовке).
    int warmup() {
        if (m_ctx is null) return -1;
        float[SAMPLE_RATE / 2] silence = 0.0f;
        int rc = 0;
        transcribe(silence[], &rc, null, null);
        return rc;
    }

    override string transcribe(
        const(float)[] samples,
        int* outRc = null,
        void function(int) nothrow onProgress = null,
        bool function() nothrow shouldAbort = null
    ) {
        if (m_ctx is null || samples.length == 0) return null;

        auto paramsPtr = m_api.fullDefaultParamsByRef(whisper_sampling_strategy.WHISPER_SAMPLING_GREEDY);
        whisper_full_params params = *paramsPtr;
        m_api.freeParams(paramsPtr);

        params.n_threads = m_threads;
        params.language = m_language.toStringz();
        if (m_initialPrompt.length > 0) {
            params.initial_prompt = m_initialPrompt.toStringz();
        }
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
        if (shouldAbort !is null) {
            params.abort_callback = &whisperAbortTrampoline;
            params.abort_callback_user_data = cast(void*) shouldAbort;
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

    override void close() {
        unloadModel();
        m_api.unload();
    }
}
