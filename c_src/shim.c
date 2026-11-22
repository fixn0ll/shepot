/*
 * Опциональный ABI-безопасный C-шим поверх whisper.h и miniaudio.h.
 * Понадобится при переносе на Linux или если захочется уйти от WinMM / прямой передачи
 * структур whisper_full_params по значению из D.
 */
#define MINIAUDIO_IMPLEMENTATION
#include "miniaudio.h"
#include "whisper.h"
#include <stdlib.h>
#include <string.h>

typedef struct WhisperBridge {
    struct whisper_context* ctx;
} WhisperBridge;

WhisperBridge* wb_init(const char* model_path, int use_gpu) {
    struct whisper_context_params cparams = whisper_context_default_params();
    cparams.use_gpu = use_gpu != 0;
    struct whisper_context* ctx = whisper_init_from_file_with_params(model_path, cparams);
    if (!ctx) return NULL;
    WhisperBridge* b = (WhisperBridge*)malloc(sizeof(WhisperBridge));
    if (!b) {
        whisper_free(ctx);
        return NULL;
    }
    b->ctx = ctx;
    return b;
}

void wb_free(WhisperBridge* b) {
    if (!b) return;
    if (b->ctx) whisper_free(b->ctx);
    free(b);
}

int wb_transcribe(WhisperBridge* b, const float* samples, int n_samples,
                  const char* language, int n_threads, char* out_buf, int out_cap) {
    if (!b || !b->ctx || !samples || n_samples <= 0 || !out_buf || out_cap <= 0) return -1;

    struct whisper_full_params params = whisper_full_default_params(WHISPER_SAMPLING_GREEDY);
    params.language = (language && language[0]) ? language : "auto";
    params.n_threads = n_threads > 0 ? n_threads : 4;
    params.no_context = true;
    params.print_progress = false;
    params.print_realtime = false;
    params.print_special = false;
    params.print_timestamps = false;
    params.suppress_blank = true;
    params.suppress_nst = true;

    if (whisper_full(b->ctx, params, samples, n_samples) != 0) return -2;

    out_buf[0] = '\0';
    int pos = 0;
    int n_seg = whisper_full_n_segments(b->ctx);
    for (int i = 0; i < n_seg; ++i) {
        const char* seg = whisper_full_get_segment_text(b->ctx, i);
        if (!seg) continue;
        size_t len = strlen(seg);
        if (pos + (int)len + 1 >= out_cap) break;
        memcpy(out_buf + pos, seg, len);
        pos += (int)len;
    }
    out_buf[pos] = '\0';
    return pos;
}
