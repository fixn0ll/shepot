module stt_engine;

import config : AppConfig;
import std.algorithm.searching : canFind;
import std.math : sqrt;
import std.range : walkLength;
import std.string : strip, toLower;
import std.utf : stride;

/// Частота дискретизации аудио, ожидаемая всеми STT-движками.
enum int SAMPLE_RATE = 16000;

/// Общий интерфейс движка распознавания речи.
interface SttEngine {
    bool initApi(const ref AppConfig cfg, out string err);
    bool loadModel(out string err);
    void unloadModel();
    bool isLoaded() const;
    string transcribe(
        const(float)[] samples,
        int* outRc = null,
        void function(int) nothrow onProgress = null,
        bool function() nothrow shouldAbort = null
    );
    string engineVersion();
    void close();

    string modelPath() const;
    void setModelPath(string path);
    void setLanguage(string lang);
    void setUseGpu(bool useGpu);
    bool useGpu() const;
    bool supportsGpu() const;
    bool supportsRemoteDownload() const;
}

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
    double duration = cast(double) samples.length / SAMPLE_RATE;
    if (duration < minDurationSec) return false;
    return calcRms(samples) >= rmsThreshold;
}

/// Отсеивает типичные галлюцинации распознавателей на пустой/тихой речи.
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
        if (t == p || (t.length <= p.length + 24 && t.canFind(p))) {
            return true;
        }
    }
    return false;
}

/// Возвращает хвост UTF-8 строки длиной не более maxChars символов.
string tailPreview(string text, size_t maxChars = 48) {
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
