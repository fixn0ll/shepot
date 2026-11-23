module sherpa_c;

import core.stdc.stdint : int32_t;
import core.sys.windows.winbase : FreeLibrary, GetProcAddress, LOAD_WITH_ALTERED_SEARCH_PATH,
    LoadLibraryExW, LoadLibraryW;
import core.sys.windows.windef : HMODULE;
import std.path : isAbsolute;
import std.utf : toUTF16z;

// Точное соответствие структурам и функциям из c_src/sherpa-onnx-c-api.h

struct SherpaOnnxOfflineRecognizer;
struct SherpaOnnxOfflineStream;

struct SherpaOnnxFeatureConfig {
    int32_t sample_rate = 16000;
    int32_t feature_dim = 80;
}

struct SherpaOnnxOfflineCtcFstDecoderConfig {
    const(char)* graph;
    int32_t max_active;
}

struct SherpaOnnxHomophoneReplacerConfig {
    const(char)* dict_dir;
    const(char)* lexicon;
    const(char)* rule_fsts;
}

struct SherpaOnnxOfflineTransducerModelConfig {
    const(char)* encoder;
    const(char)* decoder;
    const(char)* joiner;
}

struct SherpaOnnxOfflineParaformerModelConfig {
    const(char)* model;
}

struct SherpaOnnxOfflineNemoEncDecCtcModelConfig {
    const(char)* model;
}

struct SherpaOnnxOfflineWhisperModelConfig {
    const(char)* encoder;
    const(char)* decoder;
    const(char)* language;
    const(char)* task;
    int32_t tail_paddings;
    int32_t enable_token_timestamps;
    int32_t enable_segment_timestamps;
}

struct SherpaOnnxOfflineCanaryModelConfig {
    const(char)* encoder;
    const(char)* decoder;
    const(char)* src_lang;
    const(char)* tgt_lang;
    int32_t use_pnc;
}

struct SherpaOnnxOfflineCohereTranscribeModelConfig {
    const(char)* encoder;
    const(char)* decoder;
    const(char)* language;
    int32_t use_punct;
    int32_t use_itn;
}

struct SherpaOnnxOfflineFireRedAsrModelConfig {
    const(char)* encoder;
    const(char)* decoder;
}

struct SherpaOnnxOfflineFireRedAsrCtcModelConfig {
    const(char)* model;
}

struct SherpaOnnxOfflineMoonshineModelConfig {
    const(char)* preprocessor;
    const(char)* encoder;
    const(char)* uncached_decoder;
    const(char)* cached_decoder;
    const(char)* merged_decoder;
}

struct SherpaOnnxOfflineTdnnModelConfig {
    const(char)* model;
}

struct SherpaOnnxOfflineLMConfig {
    const(char)* model;
    float scale = 0.0f;
}

struct SherpaOnnxOfflineSenseVoiceModelConfig {
    const(char)* model;
    const(char)* language;
    int32_t use_itn;
}

struct SherpaOnnxOfflineDolphinModelConfig {
    const(char)* model;
}

struct SherpaOnnxOfflineZipformerCtcModelConfig {
    const(char)* model;
}

struct SherpaOnnxOfflineWenetCtcModelConfig {
    const(char)* model;
}

struct SherpaOnnxOfflineOmnilingualAsrCtcModelConfig {
    const(char)* model;
}

struct SherpaOnnxOfflineFunASRNanoModelConfig {
    const(char)* encoder_adaptor;
    const(char)* llm;
    const(char)* embedding;
    const(char)* tokenizer;
    const(char)* system_prompt;
    const(char)* user_prompt;
    int32_t max_new_tokens;
    float temperature = 0.0f;
    float top_p = 0.0f;
    int32_t seed;
    const(char)* language;
    int32_t itn;
    const(char)* hotwords;
}

struct SherpaOnnxOfflineQwen3ASRModelConfig {
    const(char)* conv_frontend;
    const(char)* encoder;
    const(char)* decoder;
    const(char)* tokenizer;
    int32_t max_total_len;
    int32_t max_new_tokens;
    float temperature = 0.0f;
    float top_p = 0.0f;
    int32_t seed;
    const(char)* hotwords;
}

struct SherpaOnnxOfflineMedAsrCtcModelConfig {
    const(char)* model;
}

struct SherpaOnnxOfflineModelConfig {
    SherpaOnnxOfflineTransducerModelConfig transducer;
    SherpaOnnxOfflineParaformerModelConfig paraformer;
    SherpaOnnxOfflineNemoEncDecCtcModelConfig nemo_ctc;
    SherpaOnnxOfflineWhisperModelConfig whisper;
    SherpaOnnxOfflineTdnnModelConfig tdnn;

    const(char)* tokens;
    int32_t num_threads;
    int32_t debug_flag;
    const(char)* provider;
    const(char)* model_type;
    const(char)* modeling_unit;
    const(char)* bpe_vocab;
    const(char)* telespeech_ctc;

    SherpaOnnxOfflineSenseVoiceModelConfig sense_voice;
    SherpaOnnxOfflineMoonshineModelConfig moonshine;
    SherpaOnnxOfflineFireRedAsrModelConfig fire_red_asr;
    SherpaOnnxOfflineDolphinModelConfig dolphin;
    SherpaOnnxOfflineZipformerCtcModelConfig zipformer_ctc;
    SherpaOnnxOfflineCanaryModelConfig canary;
    SherpaOnnxOfflineWenetCtcModelConfig wenet_ctc;
    SherpaOnnxOfflineOmnilingualAsrCtcModelConfig omnilingual;
    SherpaOnnxOfflineMedAsrCtcModelConfig medasr;
    SherpaOnnxOfflineFunASRNanoModelConfig funasr_nano;
    SherpaOnnxOfflineFireRedAsrCtcModelConfig fire_red_asr_ctc;
    SherpaOnnxOfflineQwen3ASRModelConfig qwen3_asr;
    SherpaOnnxOfflineCohereTranscribeModelConfig cohere_transcribe;
}

struct SherpaOnnxOfflineRecognizerConfig {
    SherpaOnnxFeatureConfig feat_config;
    SherpaOnnxOfflineModelConfig model_config;
    SherpaOnnxOfflineLMConfig lm_config;

    const(char)* decoding_method;
    int32_t max_active_paths;

    const(char)* hotwords_file;
    float hotwords_score = 0.0f;
    const(char)* rule_fsts;
    const(char)* rule_fars;
    float blank_penalty = 0.0f;

    SherpaOnnxHomophoneReplacerConfig hr;
    SherpaOnnxOfflineCtcFstDecoderConfig ctc_fst_decoder_config;
}

struct SherpaOnnxOfflineRecognizerResult {
    const(char)* text;
    float* timestamps;
    int32_t count;
    const(char)* tokens;
    const(char*)* tokens_arr;
    const(char)* json;
    const(char)* lang;
    const(char)* emotion;
    const(char)* event;
    float* durations;
    float* ys_log_probs;
    const(float)* segment_timestamps;
    const(float)* segment_durations;
    const(char)* segment_texts;
    const(char*)* segment_texts_arr;
    int32_t segment_count;
}

extern (C) nothrow {
    alias FnSherpaGetVersionStr = const(char)* function();
    alias FnSherpaCreateOfflineRecognizer = const(SherpaOnnxOfflineRecognizer)* function(
        const(SherpaOnnxOfflineRecognizerConfig)*);
    alias FnSherpaDestroyOfflineRecognizer = void function(const(SherpaOnnxOfflineRecognizer)*);
    alias FnSherpaCreateOfflineStream = const(SherpaOnnxOfflineStream)* function(
        const(SherpaOnnxOfflineRecognizer)*);
    alias FnSherpaDestroyOfflineStream = void function(const(SherpaOnnxOfflineStream)*);
    alias FnSherpaAcceptWaveformOffline = void function(
        const(SherpaOnnxOfflineStream)*, int32_t, const(float)*, int32_t);
    alias FnSherpaDecodeOfflineStream = void function(
        const(SherpaOnnxOfflineRecognizer)*, const(SherpaOnnxOfflineStream)*);
    alias FnSherpaGetOfflineStreamResult = const(SherpaOnnxOfflineRecognizerResult)* function(
        const(SherpaOnnxOfflineStream)*);
    alias FnSherpaDestroyOfflineRecognizerResult = void function(
        const(SherpaOnnxOfflineRecognizerResult)*);
}

struct SherpaApi {
    HMODULE hMod;
    FnSherpaGetVersionStr getVersionStr;
    FnSherpaCreateOfflineRecognizer createOfflineRecognizer;
    FnSherpaDestroyOfflineRecognizer destroyOfflineRecognizer;
    FnSherpaCreateOfflineStream createOfflineStream;
    FnSherpaDestroyOfflineStream destroyOfflineStream;
    FnSherpaAcceptWaveformOffline acceptWaveformOffline;
    FnSherpaDecodeOfflineStream decodeOfflineStream;
    FnSherpaGetOfflineStreamResult getOfflineStreamResult;
    FnSherpaDestroyOfflineRecognizerResult destroyOfflineRecognizerResult;

    bool load(string dllPath, out string err) {
        if (hMod !is null) return true;

        auto wpath = dllPath.toUTF16z();
        hMod = isAbsolute(dllPath)
            ? LoadLibraryExW(wpath, null, LOAD_WITH_ALTERED_SEARCH_PATH)
            : LoadLibraryW(wpath);
        if (hMod is null) {
            err = "Не удалось загрузить " ~ dllPath ~ " (положите sherpa-onnx-c-api.dll и onnxruntime.dll рядом с exe)";
            return false;
        }

        if (!bind(createOfflineRecognizer, "SherpaOnnxCreateOfflineRecognizer", err) ||
            !bind(destroyOfflineRecognizer, "SherpaOnnxDestroyOfflineRecognizer", err) ||
            !bind(createOfflineStream, "SherpaOnnxCreateOfflineStream", err) ||
            !bind(destroyOfflineStream, "SherpaOnnxDestroyOfflineStream", err) ||
            !bind(acceptWaveformOffline, "SherpaOnnxAcceptWaveformOffline", err) ||
            !bind(decodeOfflineStream, "SherpaOnnxDecodeOfflineStream", err) ||
            !bind(getOfflineStreamResult, "SherpaOnnxGetOfflineStreamResult", err) ||
            !bind(destroyOfflineRecognizerResult, "SherpaOnnxDestroyOfflineRecognizerResult", err)) {
            unload();
            return false;
        }
        getVersionStr = cast(FnSherpaGetVersionStr) GetProcAddress(hMod, "SherpaOnnxGetVersionStr");
        return true;
    }

    void unload() {
        if (hMod !is null) {
            FreeLibrary(hMod);
            hMod = null;
        }
    }

    private bool bind(T)(ref T fn, const(char)* sym, out string err) {
        fn = cast(T) GetProcAddress(hMod, sym);
        if (fn is null) {
            import std.string : fromStringz;
            err = "В sherpa-onnx-c-api.dll не найдена функция: " ~ sym.fromStringz().idup;
            return false;
        }
        return true;
    }
}

unittest {
    // Гарантируем, что float-поля в конфиге по умолчанию не NaN (как ожидает C memset 0)
    SherpaOnnxOfflineRecognizerConfig cfg;
    assert(cfg.feat_config.sample_rate == 16000);
    assert(cfg.feat_config.feature_dim == 80);
    assert(cfg.lm_config.scale == 0.0f);
    assert(cfg.hotwords_score == 0.0f);
    assert(cfg.blank_penalty == 0.0f);

    SherpaApi api;
    string err;
    assert(!api.load("__nonexistent_sherpa__.dll", err));
    assert(err.length > 0);
}
