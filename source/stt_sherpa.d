module stt_sherpa;

import config : AppConfig, resolvePath;
import sherpa_c;
import std.file : exists;
import std.path : buildPath, dirName;
import std.string : fromStringz, strip, toLower, toStringz;
import stt_engine : isHallucination, SAMPLE_RATE, SttEngine;

class SherpaRecognizer : SttEngine {
    private SherpaApi m_api;
    private const(SherpaOnnxOfflineRecognizer)* m_recognizer;

    private string m_modelType;
    private string m_encoder;
    private string m_decoder;
    private string m_joiner;
    private string m_ctcModel;
    private string m_tokens;
    private string m_language;
    private int m_threads = 4;
    private bool m_useGpu;
    private string m_dllDir;
    private string m_activeProvider = "cpu";

    override bool initApi(const ref AppConfig cfg, out string err) {
        auto dllPath = resolvePath(cfg.sherpaDll);
        if (!m_api.load(dllPath, err)) return false;

        m_dllDir = dirName(dllPath);

        m_modelType = cfg.sherpaModelType.strip().toLower();
        m_encoder = resolvePath(cfg.sherpaEncoder);
        m_decoder = resolvePath(cfg.sherpaDecoder);
        m_joiner = resolvePath(cfg.sherpaJoiner);
        m_ctcModel = resolvePath(cfg.sherpaCtcModel);
        m_tokens = resolvePath(cfg.sherpaTokens);
        m_language = cfg.language.length ? cfg.language : "ru";
        m_threads = cfg.threads > 0 ? cfg.threads : 4;
        m_useGpu = cfg.useGpu;
        return true;
    }

    override string modelPath() const {
        if (isCtcMode()) return m_ctcModel;
        return m_encoder.length ? m_encoder : m_ctcModel;
    }

    override void setModelPath(string path) {
        auto resolved = resolvePath(path);
        if (isCtcMode()) {
            m_ctcModel = resolved;
        } else {
            m_encoder = resolved;
        }
    }

    override void setLanguage(string lang) {
        m_language = lang.length ? lang : "ru";
    }

    override void setUseGpu(bool useGpu) {
        m_useGpu = useGpu;
    }

    override bool useGpu() const {
        return m_useGpu && m_activeProvider != "cpu";
    }

    override bool supportsGpu() const {
        return m_dllDir.length > 0 && exists(buildPath(m_dllDir, "onnxruntime_providers_cuda.dll"));
    }

    override bool isLoaded() const {
        return m_recognizer !is null;
    }

    override bool supportsRemoteDownload() const {
        return false;
    }

    override bool loadModel(out string err) {
        if (m_recognizer !is null) return true;

        if (m_tokens.length == 0 || !exists(m_tokens)) {
            err = "Не найден файл токенов sherpa-onnx: " ~ m_tokens;
            return false;
        }

        if (isCtcMode()) {
            if (m_ctcModel.length == 0 || !exists(m_ctcModel)) {
                err = "Не найден ONNX-файл модели: " ~ m_ctcModel;
                return false;
            }
        } else {
            string[2][] required = isEncDecMode()
                ? [[m_encoder, "encoder"], [m_decoder, "decoder"]]
                : [[m_encoder, "encoder"], [m_decoder, "decoder"], [m_joiner, "joiner"]];
            foreach (pair; required) {
                if (pair[0].length == 0 || !exists(pair[0])) {
                    err = "Не найден файл sherpa " ~ pair[1] ~ ": " ~ pair[0];
                    return false;
                }
            }
        }

        if (m_useGpu && supportsGpu()) {
            m_recognizer = tryCreateRecognizer("cuda");
            if (m_recognizer !is null) {
                m_activeProvider = "cuda";
                return true;
            }
        }

        m_recognizer = tryCreateRecognizer("cpu");
        if (m_recognizer is null) {
            err = "SherpaOnnxCreateOfflineRecognizer вернул NULL (проверьте sherpaModelType и файлы модели)";
            return false;
        }
        m_activeProvider = "cpu";
        return true;
    }

    private const(SherpaOnnxOfflineRecognizer)* tryCreateRecognizer(string providerName) {
        SherpaOnnxOfflineRecognizerConfig rcfg;
        rcfg.feat_config.sample_rate = SAMPLE_RATE;
        rcfg.feat_config.feature_dim = 80;

        auto tokensZ = m_tokens.toStringz();
        auto providerZ = providerName.toStringz();
        auto decodingZ = "greedy_search".toStringz();

        rcfg.model_config.tokens = tokensZ;
        rcfg.model_config.num_threads = m_threads;
        rcfg.model_config.debug_flag = 0;
        rcfg.model_config.provider = providerZ;
        rcfg.decoding_method = decodingZ;

        const(char)* encZ = null;
        const(char)* decZ = null;
        const(char)* joinZ = null;
        const(char)* ctcZ = null;
        const(char)* mtypeZ = null;
        const(char)* langZ = null;
        const(char)* taskZ = null;

        if (isCtcMode()) {
            ctcZ = m_ctcModel.toStringz();
            if (m_modelType == "paraformer") {
                rcfg.model_config.paraformer.model = ctcZ;
            } else if (m_modelType == "sense_voice") {
                langZ = (m_language == "auto" ? "auto" : m_language).toStringz();
                rcfg.model_config.sense_voice.model = ctcZ;
                rcfg.model_config.sense_voice.language = langZ;
                rcfg.model_config.sense_voice.use_itn = 1;
            } else if (m_modelType == "dolphin") {
                rcfg.model_config.dolphin.model = ctcZ;
            } else if (m_modelType == "zipformer_ctc") {
                rcfg.model_config.zipformer_ctc.model = ctcZ;
            } else if (m_modelType == "wenet_ctc") {
                rcfg.model_config.wenet_ctc.model = ctcZ;
            } else if (m_modelType == "telespeech_ctc") {
                rcfg.model_config.telespeech_ctc = ctcZ;
            } else {
                rcfg.model_config.nemo_ctc.model = ctcZ;
                if (m_modelType == "nemo_ctc") {
                    mtypeZ = "nemo_ctc".toStringz();
                    rcfg.model_config.model_type = mtypeZ;
                }
            }
        } else if (isEncDecMode()) {
            encZ = m_encoder.toStringz();
            decZ = m_decoder.toStringz();
            if (m_modelType == "fire_red_asr") {
                rcfg.model_config.fire_red_asr.encoder = encZ;
                rcfg.model_config.fire_red_asr.decoder = decZ;
            } else if (m_modelType == "canary") {
                langZ = (m_language == "auto" ? "ru" : m_language).toStringz();
                rcfg.model_config.canary.encoder = encZ;
                rcfg.model_config.canary.decoder = decZ;
                rcfg.model_config.canary.src_lang = langZ;
                rcfg.model_config.canary.tgt_lang = langZ;
                rcfg.model_config.canary.use_pnc = 1;
            } else {
                langZ = (m_language == "auto" ? "" : m_language).toStringz();
                taskZ = "transcribe".toStringz();
                rcfg.model_config.whisper.encoder = encZ;
                rcfg.model_config.whisper.decoder = decZ;
                rcfg.model_config.whisper.language = langZ;
                rcfg.model_config.whisper.task = taskZ;
            }
        } else {
            encZ = m_encoder.toStringz();
            decZ = m_decoder.toStringz();
            joinZ = m_joiner.toStringz();
            rcfg.model_config.transducer.encoder = encZ;
            rcfg.model_config.transducer.decoder = decZ;
            rcfg.model_config.transducer.joiner = joinZ;

            string resolvedType = resolvedTransducerModelType();
            if (resolvedType.length > 0) {
                mtypeZ = resolvedType.toStringz();
                rcfg.model_config.model_type = mtypeZ;
            }
        }

        return m_api.createOfflineRecognizer(&rcfg);
    }

    private bool isCtcMode() const {
        if (m_modelType == "nemo_ctc" || m_modelType == "gigaam_ctc" || m_modelType == "paraformer"
            || m_modelType == "sense_voice" || m_modelType == "dolphin"
            || m_modelType == "zipformer_ctc" || m_modelType == "wenet_ctc"
            || m_modelType == "telespeech_ctc")
        {
            return true;
        }
        return m_modelType.length == 0 && m_ctcModel.length > 0 && m_encoder.length == 0;
    }

    private bool isEncDecMode() const {
        return m_modelType == "whisper" || m_modelType == "fire_red_asr" || m_modelType == "canary";
    }

    private string resolvedTransducerModelType() const {
        if (m_modelType == "transducer" || m_modelType == "zipformer") return "";
        if (m_modelType == "gigaam" || m_modelType == "gigaam_rnnt" || m_modelType == "parakeet" || m_modelType.length == 0) {
            return "nemo_transducer";
        }
        return m_modelType;
    }

    override void unloadModel() {
        if (m_recognizer !is null) {
            m_api.destroyOfflineRecognizer(m_recognizer);
            m_recognizer = null;
        }
    }

    override string engineVersion() {
        auto v = (m_api.getVersionStr !is null)
            ? m_api.getVersionStr().fromStringz().idup
            : "unknown";
        return "sherpa-onnx " ~ v ~ " (" ~ m_activeProvider ~ ")";
    }

    override string transcribe(
        const(float)[] samples,
        int* outRc = null,
        void function(int) nothrow onProgress = null,
        bool function() nothrow shouldAbort = null
    ) {
        if (m_recognizer is null || samples.length == 0) {
            if (outRc !is null) *outRc = -1;
            return null;
        }
        if (shouldAbort !is null && shouldAbort()) {
            if (outRc !is null) *outRc = -1;
            return null;
        }

        auto stream = m_api.createOfflineStream(m_recognizer);
        if (stream is null) {
            if (outRc !is null) *outRc = -2;
            return null;
        }
        scope (exit) m_api.destroyOfflineStream(stream);

        m_api.acceptWaveformOffline(stream, SAMPLE_RATE, samples.ptr, cast(int) samples.length);
        if (onProgress !is null) onProgress(30);

        if (shouldAbort !is null && shouldAbort()) {
            if (outRc !is null) *outRc = -1;
            return null;
        }

        m_api.decodeOfflineStream(m_recognizer, stream);
        if (onProgress !is null) onProgress(100);

        auto res = m_api.getOfflineStreamResult(stream);
        if (res is null) {
            if (outRc !is null) *outRc = -3;
            return null;
        }
        scope (exit) m_api.destroyOfflineRecognizerResult(res);

        if (outRc !is null) *outRc = 0;
        if (res.text is null) return null;

        auto cleaned = res.text.fromStringz().idup.strip();
        if (isHallucination(cleaned)) return null;
        return cleaned;
    }

    override void close() {
        unloadModel();
        m_api.unload();
    }
}

unittest {
    AppConfig cfg;
    cfg.engine = "sherpa";
    cfg.sherpaModelType = "gigaam";
    auto s = new SherpaRecognizer();
    s.m_modelType = cfg.sherpaModelType;
    assert(s.resolvedTransducerModelType() == "nemo_transducer");
    assert(!s.isCtcMode());

    s.m_modelType = "nemo_ctc";
    assert(s.isCtcMode());
    s.m_modelType = "sense_voice";
    assert(s.isCtcMode());
    s.m_modelType = "whisper";
    assert(s.isEncDecMode() && !s.isCtcMode());
    assert(!s.supportsRemoteDownload());
}
