module audio;

import core.atomic : atomicLoad, atomicStore;
import core.stdc.stdlib : free, malloc, realloc;
import core.sync.mutex : Mutex;
import core.sys.windows.mmsystem;
import core.sys.windows.winbase : CRITICAL_SECTION, DeleteCriticalSection, EnterCriticalSection,
    InitializeCriticalSection, LeaveCriticalSection;
import core.sys.windows.windef : DWORD, DWORD_PTR, UINT;
import i18n : tr;
import std.utf : toUTF8;
import stt_engine : SAMPLE_RATE;

/// Возвращает список доступных микрофонов Windows (индексы 0..N-1).
string[] listInputDevices() {
    uint count = waveInGetNumDevs();
    string[] names;
    names.reserve(count);
    foreach (i; 0 .. count) {
        WAVEINCAPSW caps;
        if (waveInGetDevCapsW(i, &caps, WAVEINCAPSW.sizeof) == MMSYSERR_NOERROR) {
            size_t len = 0;
            while (len < caps.szPname.length && caps.szPname[len] != 0) ++len;
            names ~= toUTF8(caps.szPname[0 .. len]);
        } else {
            names ~= tr("Device #", "Устройство #") ~ cast(char)('0' + (i % 10));
        }
    }
    return names;
}

/// Захват микрофона (16 кГц, моно, f32) через встроенный WinMM без аллокаций GC в коллбэке.
struct AudioCapture {
    private enum int NumBuffers = 4;
    private enum int SamplesPerChunk = 800; // 50 мс при 16 кГц
    private enum int BytesPerChunk = SamplesPerChunk * short.sizeof;
    private enum size_t InitialCapSamples = SAMPLE_RATE * 16; // 16 сек (~64 КБ)

    private HWAVEIN m_handle;
    private WAVEHDR[NumBuffers] m_headers;
    private ubyte[BytesPerChunk][NumBuffers] m_chunks;

    private CRITICAL_SECTION m_cs;
    private float* m_buf;
    private size_t m_len;
    private size_t m_cap;

    private int m_deviceId = -1;
    private Mutex m_devMtx;
    private shared bool m_recording;
    private shared bool m_closing;
    private bool m_initialized;

    bool init(int deviceId, out string err) {
        atomicStore(m_closing, false);
        atomicStore(m_recording, false);
        m_deviceId = deviceId;
        if (m_devMtx is null) m_devMtx = new Mutex();
        InitializeCriticalSection(&m_cs);
        m_cap = InitialCapSamples;
        m_buf = cast(float*) malloc(m_cap * float.sizeof);
        if (m_buf is null) {
            DeleteCriticalSection(&m_cs);
            err = tr("Failed to allocate audio buffer", "Не удалось выделить аудиобуфер");
            return false;
        }
        m_len = 0;
        m_initialized = true;

        // Проверяем доступность микрофона на старте и сразу закрываем поток, чтобы значок Windows не горел в простое.
        if (!openStream(err)) {
            close();
            return false;
        }
        closeStream();
        return true;
    }

    bool isStreamOpen() const {
        return m_handle !is null;
    }

    private bool openStream(out string err) {
        if (m_handle !is null) return true;
        atomicStore(m_closing, false);

        WAVEFORMATEX fmt;
        fmt.wFormatTag = WAVE_FORMAT_PCM;
        fmt.nChannels = 1;
        fmt.nSamplesPerSec = SAMPLE_RATE;
        fmt.wBitsPerSample = 16;
        fmt.nBlockAlign = cast(ushort)(fmt.nChannels * (fmt.wBitsPerSample / 8));
        fmt.nAvgBytesPerSec = fmt.nSamplesPerSec * fmt.nBlockAlign;
        fmt.cbSize = 0;

        UINT dev = m_deviceId < 0 ? WAVE_MAPPER : cast(UINT) m_deviceId;
        auto rc = waveInOpen(
            &m_handle,
            dev,
            &fmt,
            cast(DWORD_PTR) &waveInCallback,
            cast(DWORD_PTR) &this,
            CALLBACK_FUNCTION
        );
        if (rc != MMSYSERR_NOERROR) {
            m_handle = null;
            err = tr("Failed to open microphone (waveInOpen)", "Не удалось открыть микрофон (waveInOpen)");
            return false;
        }

        foreach (i; 0 .. NumBuffers) {
            m_headers[i] = WAVEHDR.init;
            m_headers[i].lpData = cast(char*) m_chunks[i].ptr;
            m_headers[i].dwBufferLength = BytesPerChunk;
            waveInPrepareHeader(m_handle, &m_headers[i], WAVEHDR.sizeof);
            waveInAddBuffer(m_handle, &m_headers[i], WAVEHDR.sizeof);
        }

        rc = waveInStart(m_handle);
        if (rc != MMSYSERR_NOERROR) {
            closeStream();
            err = tr("Failed to start microphone capture (waveInStart)", "Не удалось запустить поток захвата микрофона (waveInStart)");
            return false;
        }
        return true;
    }

    private void closeStream() {
        atomicStore(m_closing, true);
        if (m_handle !is null) {
            waveInStop(m_handle);
            waveInReset(m_handle);
            foreach (i; 0 .. NumBuffers) {
                if (m_headers[i].dwFlags & WHDR_PREPARED) {
                    waveInUnprepareHeader(m_handle, &m_headers[i], WAVEHDR.sizeof);
                }
            }
            waveInClose(m_handle);
            m_handle = null;
        }
    }

    bool startRecording(out string err) {
        if (m_devMtx !is null) m_devMtx.lock();
        scope (exit) if (m_devMtx !is null) m_devMtx.unlock();

        EnterCriticalSection(&m_cs);
        m_len = 0;
        LeaveCriticalSection(&m_cs);

        if (!openStream(err)) return false;
        atomicStore(m_recording, true);
        return true;
    }

    /// Возвращает копию текущего буфера без остановки записи (для live-предпросмотра).
    float[] peekBuffer(size_t maxSamples = 0) {
        if (!atomicLoad(m_recording)) return null;
        EnterCriticalSection(&m_cs);
        scope (exit) LeaveCriticalSection(&m_cs);

        if (m_len == 0 || m_buf is null) return null;
        size_t start = (maxSamples > 0 && m_len > maxSamples) ? (m_len - maxSamples) : 0;
        return m_buf[start .. m_len].dup;
    }

    void stopStream() {
        atomicStore(m_recording, false);
        if (m_devMtx !is null) m_devMtx.lock();
        scope (exit) if (m_devMtx !is null) m_devMtx.unlock();
        closeStream();
    }

    float[] stopAndTakeBuffer() {
        stopStream();
        if (!m_initialized) return null;
        EnterCriticalSection(&m_cs);
        scope (exit) LeaveCriticalSection(&m_cs);

        if (m_len == 0 || m_buf is null) return null;
        auto result = m_buf[0 .. m_len].dup;
        m_len = 0;
        return result;
    }

    bool reopen(int deviceId, out string err) {
        if (m_devMtx !is null) m_devMtx.lock();
        scope (exit) if (m_devMtx !is null) m_devMtx.unlock();

        bool wasOpen = (m_handle !is null);
        closeStream();
        m_deviceId = deviceId;
        if (!openStream(err)) return false;
        if (!wasOpen) closeStream();
        return true;
    }

    void close() {
        stopStream();
        if (m_buf !is null) {
            free(m_buf);
            m_buf = null;
        }
        if (m_initialized) {
            DeleteCriticalSection(&m_cs);
            m_initialized = false;
        }
    }

    private void onData(WAVEHDR* hdr) nothrow @nogc {
        if (atomicLoad(m_closing)) return;

        if (atomicLoad(m_recording) && hdr.dwBytesRecorded >= short.sizeof) {
            size_t count = hdr.dwBytesRecorded / short.sizeof;
            auto pcm = cast(const(short)*) hdr.lpData;

            EnterCriticalSection(&m_cs);
            if (m_len + count > m_cap) {
                size_t newCap = m_cap * 2;
                while (newCap < m_len + count) newCap *= 2;
                auto grown = cast(float*) realloc(m_buf, newCap * float.sizeof);
                if (grown !is null) {
                    m_buf = grown;
                    m_cap = newCap;
                }
            }
            if (m_len + count <= m_cap) {
                foreach (i; 0 .. count) {
                    m_buf[m_len + i] = pcm[i] * (1.0f / 32768.0f);
                }
                m_len += count;
            }
            LeaveCriticalSection(&m_cs);
        }

        if (!atomicLoad(m_closing)) {
            waveInAddBuffer(m_handle, hdr, WAVEHDR.sizeof);
        }
    }
}

private extern (Windows) void waveInCallback(
    HWAVEIN hwi,
    UINT uMsg,
    DWORD_PTR dwInstance,
    DWORD_PTR dwParam1,
    DWORD_PTR dwParam2
) nothrow @nogc {
    if (uMsg != WIM_DATA || dwInstance == 0 || dwParam1 == 0) return;
    auto self = cast(AudioCapture*) dwInstance;
    self.onData(cast(WAVEHDR*) dwParam1);
}

unittest {
    AudioCapture cap;
    assert(!cap.isStreamOpen());
    assert(cap.stopAndTakeBuffer() is null);
    assert(cap.peekBuffer() is null);
}
