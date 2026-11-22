module whisper_c;

import core.stdc.stdint : int32_t, int64_t, uint32_t;
import core.sys.windows.winbase : FreeLibrary, GetProcAddress, LoadLibraryW;
import core.sys.windows.windef : HMODULE;
import std.utf : toUTF16z;

// Точное соответствие структурам и enum из c_src/whisper.h

enum int WHISPER_SAMPLE_RATE = 16000;

struct whisper_context;
struct whisper_state;

alias whisper_pos = int32_t;
alias whisper_token = int32_t;
alias whisper_seq_id = int32_t;

enum whisper_alignment_heads_preset : int {
    WHISPER_AHEADS_NONE,
    WHISPER_AHEADS_N_TOP_MOST,
    WHISPER_AHEADS_CUSTOM,
    WHISPER_AHEADS_TINY_EN,
    WHISPER_AHEADS_TINY,
    WHISPER_AHEADS_BASE_EN,
    WHISPER_AHEADS_BASE,
    WHISPER_AHEADS_SMALL_EN,
    WHISPER_AHEADS_SMALL,
    WHISPER_AHEADS_MEDIUM_EN,
    WHISPER_AHEADS_MEDIUM,
    WHISPER_AHEADS_LARGE_V1,
    WHISPER_AHEADS_LARGE_V2,
    WHISPER_AHEADS_LARGE_V3,
    WHISPER_AHEADS_LARGE_V3_TURBO,
}

struct whisper_ahead {
    int n_text_layer;
    int n_head;
}

struct whisper_aheads {
    size_t n_heads;
    const(whisper_ahead)* heads;
}

struct whisper_context_params {
    bool use_gpu;
    bool flash_attn;
    int gpu_device;

    bool dtw_token_timestamps;
    whisper_alignment_heads_preset dtw_aheads_preset;

    int dtw_n_top;
    whisper_aheads dtw_aheads;

    size_t dtw_mem_size;
}

struct whisper_token_data {
    whisper_token id;
    whisper_token tid;
    float p;
    float plog;
    float pt;
    float ptsum;
    int64_t t0;
    int64_t t1;
    int64_t t_dtw;
    float vlen;
}

struct whisper_grammar_element {
    int type;
    uint32_t value;
}

struct whisper_vad_params {
    float threshold;
    int min_speech_duration_ms;
    int min_silence_duration_ms;
    float max_speech_duration_s;
    int speech_pad_ms;
    float samples_overlap;
}

enum whisper_sampling_strategy : int {
    WHISPER_SAMPLING_GREEDY,
    WHISPER_SAMPLING_BEAM_SEARCH,
}

extern (C) {
    alias whisper_new_segment_callback = void function(whisper_context*, whisper_state*, int, void*);
    alias whisper_progress_callback = void function(whisper_context*, whisper_state*, int, void*);
    alias whisper_encoder_begin_callback = bool function(whisper_context*, whisper_state*, void*);
    alias ggml_abort_callback = bool function(void*);
    alias whisper_logits_filter_callback = void function(
        whisper_context*, whisper_state*, const(whisper_token_data)*, int, float*, void*);
}

struct whisper_full_params {
    whisper_sampling_strategy strategy;

    int n_threads;
    int n_max_text_ctx;
    int offset_ms;
    int duration_ms;

    bool translate;
    bool no_context;
    bool no_timestamps;
    bool single_segment;
    bool print_special;
    bool print_progress;
    bool print_realtime;
    bool print_timestamps;

    bool token_timestamps;
    float thold_pt;
    float thold_ptsum;
    int max_len;
    bool split_on_word;
    int max_tokens;

    bool debug_mode;
    int audio_ctx;

    bool tdrz_enable;
    const(char)* suppress_regex;

    const(char)* initial_prompt;
    bool carry_initial_prompt;
    const(whisper_token)* prompt_tokens;
    int prompt_n_tokens;

    const(char)* language;
    bool detect_language;

    bool suppress_blank;
    bool suppress_nst;

    float temperature;
    float max_initial_ts;
    float length_penalty;

    float temperature_inc;
    float entropy_thold;
    float logprob_thold;
    float no_speech_thold;

    struct Greedy {
        int best_of;
    }
    Greedy greedy;

    struct BeamSearch {
        int beam_size;
        float patience;
    }
    BeamSearch beam_search;

    whisper_new_segment_callback new_segment_callback;
    void* new_segment_callback_user_data;

    whisper_progress_callback progress_callback;
    void* progress_callback_user_data;

    whisper_encoder_begin_callback encoder_begin_callback;
    void* encoder_begin_callback_user_data;

    ggml_abort_callback abort_callback;
    void* abort_callback_user_data;

    whisper_logits_filter_callback logits_filter_callback;
    void* logits_filter_callback_user_data;

    const(whisper_grammar_element)** grammar_rules;
    size_t n_grammar_rules;
    size_t i_start_rule;
    float grammar_penalty;

    bool vad;
    const(char)* vad_model_path;
    whisper_vad_params vad_params;
}

struct WhisperApi {
    private HMODULE m_lib;

    extern (C) {
        whisper_context_params* function() contextDefaultParamsByRef;
        void function(whisper_context_params*) freeContextParams;
        whisper_full_params* function(whisper_sampling_strategy) fullDefaultParamsByRef;
        void function(whisper_full_params*) freeParams;
        whisper_context* function(const(char)*, whisper_context_params) initFromFileWithParams;
        void function(whisper_context*) freeContext;
        int function(whisper_context*, whisper_full_params, const(float)*, int) full;
        int function(whisper_context*) fullNSegments;
        const(char)* function(whisper_context*, int) fullGetSegmentText;
        const(char)* function() printSystemInfo;
        const(char)* function() versionStr;
    }

    bool load(string dllPath, out string err) {
        m_lib = LoadLibraryW(dllPath.toUTF16z());
        if (m_lib is null) {
            err = "Не удалось загрузить " ~ dllPath ~ " (проверьте наличие whisper.dll и ggml*.dll рядом с exe)";
            return false;
        }

        bool bind(T)(ref T fn, const(char)* sym) {
            auto p = GetProcAddress(m_lib, sym);
            if (p is null) {
                import std.string : fromStringz;
                err = "В whisper.dll не найдена функция: " ~ sym.fromStringz().idup;
                return false;
            }
            fn = cast(T) p;
            return true;
        }

        if (!bind(contextDefaultParamsByRef, "whisper_context_default_params_by_ref") ||
            !bind(freeContextParams, "whisper_free_context_params") ||
            !bind(fullDefaultParamsByRef, "whisper_full_default_params_by_ref") ||
            !bind(freeParams, "whisper_free_params") ||
            !bind(initFromFileWithParams, "whisper_init_from_file_with_params") ||
            !bind(freeContext, "whisper_free") ||
            !bind(full, "whisper_full") ||
            !bind(fullNSegments, "whisper_full_n_segments") ||
            !bind(fullGetSegmentText, "whisper_full_get_segment_text") ||
            !bind(printSystemInfo, "whisper_print_system_info") ||
            !bind(versionStr, "whisper_version")) {
            unload();
            return false;
        }
        return true;
    }

    void unload() {
        if (m_lib !is null) {
            FreeLibrary(m_lib);
            m_lib = null;
        }
    }
}
