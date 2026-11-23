> [!CAUTION]
> $$\color{red}\text{Disclaimer: This project was vibe-coded for the developer's personal purposes.}$$

🌐 **Language:** **English** | [Русский](README.ru.md)

# Shepot

Native Push-to-Talk voice dictation tool for Windows written in **D (LDC2)** + **Win32 API**, supporting two speech-to-text engines: **whisper.cpp** (Vulkan GPU / CPU) and **sherpa-onnx** (GigaAM v3 / Multilingual, SenseVoice, Paraformer, Zipformer, Whisper ONNX, etc.).

## Features
- **Multilingual UI (`English` / `Русский`):** English is the primary language (`"uiLanguage": "en"` in `config.json`), with live runtime switching to Russian (and back) in Settings or the tray menu.
- **Two-page native UI & adaptive themes:**
  - **Main page** — live status, Load/Unload model button + progress bar, model preset selector with **Browse...** and hover/list recommendations, and an activity log with **Copy Last Phrase** and **Clear** buttons.
  - **Settings page** — microphone selector, speech language, hotkey binder, auto-unload timeout, input mode, color theme (**Auto / Light / Dark** with live Windows theme tracking), UI language, checkboxes, tooltips on hover, and quick buttons to open **`replacements.json`** and the **`models/`** folder.
- **Lightweight native runtime:** pure Win32 GUI + system tray icon (no Electron, WebView2, Python, or .NET), single-instance guard (`Single Instance`), and on-demand microphone capture (opens the Windows audio input stream **only during active recording**, so the Windows microphone indicator stays off while idle).
- **Two STT engines & built-in presets:**
  - **Whisper (`whisper.cpp`):** `tiny`, `base`, `small-q5_1`, `medium-q5_0`, `large-v3-turbo-q5_0`, `large-v3-turbo-q8_0` with **Vulkan GPU** acceleration (AMD / NVIDIA / Intel) and CPU fallback.
  - **GigaAM (`sherpa-onnx`):** **GigaAM v3 RNN-T Punct** (Russian with punctuation) and **GigaAM Multilingual CTC** (RU + EN) for ultra-fast CPU inference.
- **Custom local models right from the UI:** **Browse...** in the main window (or *Browse custom model...* in the tray menu) lets you pick a Whisper GGML `.bin` file or an `.onnx` / `tokens.txt` file inside a `sherpa-onnx` folder with automatic architecture detection:
  - Whisper GGML (`*.bin`);
  - `nemo_transducer` / `transducer` (GigaAM v2/v3 RNN-T, Parakeet, Zipformer);
  - `nemo_ctc` / `gigaam_ctc`, `paraformer`, `sense_voice`, `dolphin`, `zipformer_ctc`, `wenet_ctc`, `telespeech_ctc`;
  - `whisper` (ONNX), `fire_red_asr`, `canary`.
- **Automatic dependency setup:** selecting a built-in preset or running `--setup` automatically downloads the required runtime DLLs (`whisper.dll` Vulkan or `sherpa-onnx-c-api.dll` + `onnxruntime.dll`) and model weights with in-UI progress reporting.
- **Reliable text injection (including games):**
  - **Per-character (`sendinput`):** Unicode injection via `KEYEVENTF_UNICODE` with configurable `charDelayMs` and `VK_RETURN` newlines — works in games and apps that ignore `Ctrl+V`.
  - **Clipboard (`clipboard`):** fast `Ctrl+V` paste with non-text protection — if the clipboard currently holds non-text data (such as an **image/screenshot or files**), Shepot skips overwriting it by default, logs a warning, and automatically falls back to **per-character** typing. Enable **Overwrite non-text clipboard** (`overwriteNonTextClipboard`) to always paste via `Ctrl+V`.
  - **Auto (`auto`):** types short phrases (`<= 80` characters) per-character and longer ones via the clipboard.
- **Flexible recording control:**
  - **Push-to-Talk** or **Toggle mode** (press to start, press again to stop);
  - global keyboard and mouse hooks (`MOUSE3`–`MOUSE5`, `F1`–`F12`, `CAPSLOCK`, `SPACE`, etc.) with optional key blocking (`blockHotkey`);
  - **cancel active recording with `Esc`** without transcribing;
  - **copy last phrase** from the window or tray menu.
- **Post-processing & context:**
  - `initialPrompt` support in `config.json` to hint domain terms to Whisper;
  - optional replacement dictionary `bin/replacements.json` (e.g. `{"teh": "the", "new line": "\n"}`).
- **Smart memory management (VRAM/RAM):** idle auto-unload timer (`1`–`30` min / `Never`), instant recording into RAM while the model loads asynchronously in parallel, and a floating HUD status pill with optional live preview.

## Build from Source (Windows x64)
Requires **LDC2** (with `dub`) and the **MSVC** linker (Visual Studio Build Tools; `rc.exe` is not required since `assets/app.res` is prebuilt):

```powershell
dub test --compiler=ldc2
dub build --compiler=ldc2 --build=release
.\bin\shepot.exe
```

On first run, missing runtime DLLs and the selected preset model are downloaded automatically (or pre-install them via `.\bin\shepot.exe --setup`).

## CLI Flags
- `--setup` — verify/download runtime DLLs and the configured model, then exit.
- `--check` — load the model, run warmup, test microphone capture, then exit.
- `--no-download` — disable automatic downloading of missing files.
- `--wav=<path>` — transcribe a 16 kHz mono PCM WAV file using the active `config.json` model and print timing/text to stdout.

## Project Structure
- `source/app.d` — worker thread coordination, `createSttEngine` factory, idle unload timer, live preview.
- `source/i18n.d` — lightweight lock-free English (`en`) / Russian (`ru`) localization helpers.
- `source/stt_engine.d` — common `SttEngine` interface, `SAMPLE_RATE = 16000`, silence and hallucination filters.
- `source/stt.d` / `source/whisper_c.d` — `whisper.cpp` backend, `initial_prompt`, instant preview abort.
- `source/stt_sherpa.d` / `source/sherpa_c.d` — dynamic `sherpa-onnx-c-api.dll` loader and ONNX model support.
- `source/audio.d` — on-demand WinMM microphone capture (16 kHz mono `f32`, zero GC allocations in callback).
- `source/os_win.d` — Win32 GUI, dark/light themes, tooltips, custom model dialog, tray menu, global hooks, HUD overlay, Unicode / clipboard input, `Single Instance`.
- `source/postprocess.d` — `replacements.json` loader and text replacement rules.
- `source/sound.d` — in-memory soft WAV cue synthesizer.
- `source/bootstrap.d` — automatic downloader for Whisper Vulkan / sherpa-onnx DLLs and models via `curl.exe` & `tar.exe`.
- `source/config.d` — `bin/config.json` reader/writer, model presets with hints, custom model folder auto-detection.
