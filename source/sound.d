module sound;

import core.sys.windows.mmsystem : PlaySoundW, SND_ASYNC, SND_MEMORY, SND_NODEFAULT;
import core.sys.windows.windef : LPCWSTR;
import std.math : cos, PI, sin;

private enum int SampleRate = 22050;

struct ToneNote {
    double freqStart;
    double freqEnd;
    int durationMs;
    double volume;
}

/// Синтезирует 16-битный моно PCM WAV в памяти с плавным нарастанием и затуханием.
ubyte[] buildWav(const(ToneNote)[] notes) {
    size_t totalSamples = 0;
    foreach (n; notes) {
        totalSamples += cast(size_t)(SampleRate * n.durationMs / 1000);
    }

    uint dataBytes = cast(uint)(totalSamples * short.sizeof);
    uint riffSize = 36 + dataBytes;
    ubyte[] wav = new ubyte[44 + dataBytes];

    void put4(size_t off, const(char)[4] tag) {
        wav[off .. off + 4] = cast(const(ubyte)[]) tag[];
    }
    void putU32(size_t off, uint v) {
        wav[off .. off + 4] = (cast(ubyte*) &v)[0 .. 4];
    }
    void putU16(size_t off, ushort v) {
        wav[off .. off + 2] = (cast(ubyte*) &v)[0 .. 2];
    }

    put4(0, "RIFF");
    putU32(4, riffSize);
    put4(8, "WAVE");
    put4(12, "fmt ");
    putU32(16, 16);             // PCM chunk size
    putU16(20, 1);              // PCM format
    putU16(22, 1);              // Mono
    putU32(24, SampleRate);
    putU32(28, SampleRate * 2); // ByteRate
    putU16(32, 2);              // BlockAlign
    putU16(34, 16);             // BitsPerSample
    put4(36, "data");
    putU32(40, dataBytes);

    size_t outIdx = 0;
    foreach (note; notes) {
        size_t count = cast(size_t)(SampleRate * note.durationMs / 1000);
        if (count == 0) continue;
        size_t fadeSamples = SampleRate * 6 / 1000; // 6 мс плавный вход/выход
        if (fadeSamples * 2 > count) fadeSamples = count / 2;

        double phase = 0.0;
        foreach (i; 0 .. count) {
            double t = cast(double) i / count;
            double freq = note.freqStart + (note.freqEnd - note.freqStart) * t;
            phase += 2.0 * PI * freq / SampleRate;

            double env = 1.0;
            if (i < fadeSamples) {
                env = 0.5 * (1.0 - cos(PI * i / fadeSamples));
            } else if (i >= count - fadeSamples) {
                size_t rem = count - 1 - i;
                env = 0.5 * (1.0 - cos(PI * rem / fadeSamples));
            }
            // Мягкий спад к концу ноты
            env *= (1.0 - 0.35 * t);

            double sample = sin(phase) * note.volume * env;
            int pcm = cast(int)(sample * 32767.0);
            if (pcm > 32767) pcm = 32767;
            if (pcm < -32768) pcm = -32768;
            short s = cast(short) pcm;
            size_t byteOff = 44 + outIdx * 2;
            wav[byteOff .. byteOff + 2] = (cast(ubyte*) &s)[0 .. 2];
            ++outIdx;
        }
    }
    return wav;
}

private __gshared immutable(ubyte)[] g_wavStart;
private __gshared immutable(ubyte)[] g_wavStop;
private __gshared immutable(ubyte)[] g_wavTick;
private __gshared immutable(ubyte)[] g_wavReady;

shared static this() {
    g_wavStart = buildWav([
        ToneNote(523.25, 523.25, 45, 0.13),
        ToneNote(659.25, 659.25, 55, 0.12),
    ]).idup;
    g_wavStop = buildWav([
        ToneNote(523.25, 490.0, 40, 0.11),
        ToneNote(392.00, 380.0, 50, 0.09),
    ]).idup;
    g_wavTick = buildWav([
        ToneNote(660.0, 340.0, 22, 0.09),
    ]).idup;
    g_wavReady = buildWav([
        ToneNote(523.25, 523.25, 50, 0.12),
        ToneNote(659.25, 659.25, 50, 0.12),
        ToneNote(783.99, 783.99, 70, 0.13),
    ]).idup;
}

private void playBuffer(immutable(ubyte)[] wav) nothrow @nogc {
    if (wav.length == 0) return;
    PlaySoundW(cast(LPCWSTR) wav.ptr, null, SND_MEMORY | SND_ASYNC | SND_NODEFAULT);
}

void playCueAsync(bool start) nothrow @nogc {
    playBuffer(start ? g_wavStart : g_wavStop);
}

void playClickAsync() nothrow @nogc {
    playBuffer(g_wavTick);
}

void playActivationCueAsync() nothrow @nogc {
    playBuffer(g_wavReady);
}

unittest {
    auto w = buildWav([ToneNote(440.0, 440.0, 50, 0.15)]);
    assert(w.length == 44 + (SampleRate * 50 / 1000) * 2);
    assert(cast(const(char)[]) w[0 .. 4] == "RIFF");
    assert(cast(const(char)[]) w[8 .. 12] == "WAVE");
}
