# Verification tools

The tools used to show that BitPolish's output is bit-perfect. The method, the results and the limits are in [`docs/VERIFICATION.md`](../../docs/VERIFICATION.md); read that first.

Requirements: an Apple Silicon Mac on macOS 14.4 or later, the Xcode Command Line Tools (`swift`, `swiftc`), and Python 3 with NumPy (`pip3 install numpy`). Run everything from this folder.

| File | What it does |
|---|---|
| `make_test_signal.py` | Writes the test signal: 20 s of random 24-bit noise per channel at 96 kHz (or the rate you pass), about −60 dBFS, fixed seed. Outputs `reference_int24.npy` (the exact samples) and `reference.wav`. |
| `compare.py` | `compare.py capture.f32` compares a capture with the reference. `compare.py --check-file X.m4a` checks an encoded test file decodes back to the reference exactly. |
| `capture.swift` | Records one process's audio as it goes to the output device, using a CoreAudio process tap on the device's stream. Waits for playback to start. Usage: `CaptureTest <pid> <seconds> <outfile>`. Writes float32 interleaved stereo, plus `<outfile>.log`. |
| `build_capture_app.sh` | Builds `capture.swift` into `BitPolish Capture Test.app`, so macOS's one-time audio-recording permission names the test tool. |
| `device_format.swift` | `swift device_format.swift` shows the output device's format, the formats it offers and its volume. `swift device_format.swift 24 96000` sets one. |
| `ratewatch.swift` | `swift ratewatch.swift 180` prints a millisecond timestamp at each change of the device's rate or bit depth, for 180 s. Read-only. |

Notes:
- Turn your DAC or amplifier down before playing the test signal.
- `device_format.swift` with arguments changes your device. Note its format first and set it back afterward.
- The capture app's audio-recording permission stays listed in System Settings › Privacy & Security › Screen & System Audio Recording until you remove it.
- The generated files (`reference*`, `*.m4a`, `*.f32`, the app) are ignored by git.
