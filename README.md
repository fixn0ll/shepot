> [!CAUTION]
> $$\color{red}\text{Disclaimer: This project was vibe-coded for the developer's personal purposes.}$$

🌐 **Language:** **English** | [Русский](README.ru.md)

# Shepot

Push-to-Talk voice dictation tool for Windows x64 written in D (`ldc2`) and Win32 API.

## What It Does
- **STT engines:** `whisper.cpp` (Vulkan GPU / CPU) and `sherpa-onnx` (CPU). Built-in presets (`GigaAM v4 RNN-T`, `GigaAM Multilingual CTC`, `Whisper tiny`–`large-v3-turbo`) auto-download DLLs and weights, or you can pick any local `.bin` / `.onnx` via **Browse...**.
- **Text input:**
  - `sendinput` — per-character Unicode typing with configurable delay (`charDelayMs` in Settings) for games.
  - `clipboard` — `Ctrl+V` paste (skips overwriting clipboard if it holds an image/files unless enabled).
  - `auto` — `sendinput` for `<= 80` chars, `clipboard` otherwise.
- **Controls:** Hold (Push-to-Talk) or Toggle mode, global keyboard/mouse hotkey, `Esc` to cancel, system tray icon, floating status HUD, idle model auto-unload, `bin/replacements.json`, and `EN / RU` UI.

## Build (Windows x64)
Requires **LDC2** (`dub`) and the **MSVC** linker:

```powershell
dub test --compiler=ldc2
dub build --compiler=ldc2 --build=release
.\bin\shepot.exe
```

## CLI Flags
- `--setup` — download missing DLLs and configured model, then exit.
- `--check` — load model, test microphone, and exit.
- `--no-download` — skip automatic downloads.
- `--wav=<path>` — transcribe a 16 kHz mono PCM WAV file and print timing/text.
