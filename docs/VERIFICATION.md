# How BitPolish's bit-perfect claim was verified

"Bit-perfect" is easy to claim and hard to show. This page explains what BitPolish means by it, how each part of the playback chain was checked, what the results were, and how you can repeat the tests on your own Mac and DAC. The tools are in [`Tools/verification/`](../Tools/verification/).

## What "bit-perfect" means here

The audio samples that reach your DAC are identical, value for value, to the samples in the file Apple Music is playing: same sample rate, and no change to any sample from volume, resampling, dither, EQ or mixing.

A display on a DAC can't show this. A sample-rate indicator proves the **rate** arrived, but the rate stays the same when the values are altered (a volume change, for example). So the values have to be measured.

## The chain, and what checks each part

| Step | What happens | How it was checked |
|---|---|---|
| 1. Music decodes the file | Apple Lossless → samples | Capture test (bit-exact) |
| 2. Music's playback engine and macOS's mixer | Samples as 32-bit floating point, at the device's rate | Capture test (bit-exact) |
| 3. Device rate and bit depth | BitPolish sets the track's rate and the locked bit depth (24-bit by default) | `device_format.swift`, DAC's input-rate indicator |
| 4. Float → the device's integer format | macOS's driver converts for USB | Reasoning (below); not directly captured |
| 5. The DAC connection (USB or S/PDIF) | Integer samples sent to the DAC | Not directly captured (see "What isn't covered") |
| 6. The DAC's own handling | e.g. 16-bit data padded into 24-bit words | The DAC maker's documentation |

## Test 1: device format

`swift Tools/verification/device_format.swift` prints the output device's current rate, bit depth, the formats it offers, and its volume controls. With Bit-Perfect Listening On, the rate must match the track (or BitPolish must say it can't) and the bit depth must be the locked one (24-bit unless you chose the device's maximum). Its volume must read 1.0 (unity); on many USB devices this is the macOS volume slider.

If your DAC shows the incoming sample rate, watch it too. On a Chord Hugo M Scaler, the DX OP button (4th from the left) lights red for 44.1, orange for 48, yellow for 88.2, green for 96, light blue for 176.4 and dark blue for 192 (Chord's quickstart, section 6.1).

## Test 2: the bit-exact capture

This is the core test. It captures exactly what Music sends to the output device and compares it, sample by sample, with the file.

**The test signal.** `make_test_signal.py` writes 20 seconds of independent random 24-bit noise per channel at 96 kHz, about −60 dBFS. Random noise uses every bit, including the lowest, so any processing changes it detectably. It's quiet, but **turn your DAC or amp down** anyway. Encode it as Apple Lossless with `afconvert`, then confirm the encoded file decodes back to the exact reference (`compare.py --check-file`). Only then is it a valid yardstick.

**The capture.** `capture.swift`, built as a small app by `build_capture_app.sh`, uses a CoreAudio process tap on Music. It taps **Music's audio headed for the output device's stream**, so the capture is in the device's own format (e.g. 96 kHz float). It waits for Music to start playing, then records several seconds to a file. macOS asks once for permission to record audio for this test app; BitPolish itself never asks.

**The comparison.** `compare.py` aligns the capture with the reference by cross-correlation, then counts how many samples match exactly. A pass means:
- 100% of samples sit exactly on 24-bit integer values,
- 100% of samples equal the reference,
- best-fit gain exactly 1.000000,
- the full spectrum is present (no missing energy above any frequency).

**The pitfall we hit, so you don't.** Our first captures used a *stereo-mixdown* tap. That kind of tap runs at a fixed 48 kHz and resamples whatever it captures, so every capture came out with everything above about 22 kHz missing. That looked exactly like Music resampling. A control run with Apple's `afplay` showed the same damage, which exposed the tool as the cause. Always validate the instrument with a known-clean source first.

**The runs.** Each run sets the conditions, starts the capture app, and then you press Play in Music.

| Run | Purpose | Conditions |
|---|---|---|
| Instrument check | Prove the capture path itself is clean | `afplay` plays the file, device at 96/24 |
| Control | Music under ideal conditions | Music launched with the device already at 96/24; Music volume 100% |
| Launch-rate scenario | Test a long-standing claim that Music resamples local files through the rate the device had when Music launched | Music launched with the device at 44.1, device then set to 96/24; Music volume 100% |

## Test 3: rate-switch timing

`swift Tools/verification/ratewatch.swift 180` logs, to the millisecond, each change of the device's rate. Line those times up with Music's decoder events (`log show --predicate 'process == "Music" AND eventMessage CONTAINS "Input format"'`) to see how long after a track starts the device switches, and how long the device takes to change rate.

## Test 4: restore safety

With a testing build (`./build.sh --testing`; hooks listed in the README), these were run against a real DAC, checking the device's format before and after and that `~/Library/Application Support/BitPolish/Restore Points/` empties:
- On then Off;
- Off and quit in the same instant;
- force-quit (`kill -9`) while On, then relaunch;
- `SIGTERM` while On;
- On/Off three times, 150 ms apart;
- another app changing the device behind BitPolish's back while On;
- unplugging and replugging the DAC while On.

## Test 5: no permission prompts

After each run, macOS's privacy log was checked for any request from BitPolish that could prompt:
```bash
log show --last 10m --style compact --predicate 'subsystem == "com.apple.TCC"'
```
Group lines by `msgID`, keep groups that mention BitPolish's bundle identifier (`CFBundleIdentifier` in `Support/Info.plist`), and look for `AUTHREQ_PROMPTING`.

## Results

Tested 16 October 2026 on an Apple Silicon Mac, macOS 27.0.1, Apple Music, a generic USB-to-S/PDIF (optical) adapter feeding a Chord Hugo M Scaler and Hugo TT2.

| Test | Result |
|---|---|
| Test file round trip (ALAC encode/decode) | Identical to reference |
| Capture, instrument check (`afplay`) | **Bit-exact**, gain 1.000000, full band to 45 kHz |
| Capture, control (Music launched at 96, volume 100%) | **Bit-exact**, gain 1.000000, full band |
| Capture, launch-rate scenario (launched at 44.1, then 96) | **Bit-exact**, gain 1.000000, full band. The claim doesn't hold on macOS 27.0.1. |
| Capture with Music's volume below 100% | Not bit-exact: every sample scaled (Music restores its saved volume at each launch, so check the slider) |
| Device format, BitPolish On | Track rate at 24-bit (the adapter's maximum); volume 1.0 |
| M Scaler DX OP color | Matched each file's rate (44.1, 96, 192); back to red with BitPolish Off |
| Rate-switch timing | BitPolish acts about 0.2–0.3 s after a track starts; this adapter then takes about 0.8–1.0 s to change rate (silence meanwhile) |
| Restore safety (all cases above) | Device returned to its exact original format; no restore points left |
| Permission prompts from BitPolish | None |

## Why the last steps are safe

Step 4, the conversion from floating point to the device's integer format, happens after the capture point. It's safe for these reasons:
- **Nothing to round.** The capture shows every sample already sitting exactly on a 24-bit integer value, so converting to 24-bit integers is exact arithmetic.
- **Nothing should alter it.** Only dither or a gain change would alter a value. BitPolish checks the device's volume, and nothing in this path is known to add dither.
- **Negligible in the worst case.** Even if something did dither, at 24-bit that sits around −144 dB, and it would affect any bit-depth setting equally.

For step 6, Chord's designer Rob Watts states that the M Scaler treats 16-bit data identically to 24-bit data ("16 bit data is 24 bit with 8 zeroes"; [Head-Fi, 3 March 2019](https://www.head-fi.org/threads/hugo-m-scaler-by-chord-electronics-the-official-thread.885042/post-14813307)), and that S/PDIF always carries 24 bits, with 16-bit audio sent as 16 bits plus 8 zeros ([Head-Fi, 10 January 2020](https://www.head-fi.org/threads/chord-electronics-hugo-2-the-official-thread.831345/post-15408161)). The S/PDIF frame layout agrees: each subframe has room for 24 bits, and a 16-bit sample fills the top 16 with the rest zero ([ST AN5073](https://www.st.com/resource/en/application_note/an5073-receiving-spdif-audio-stream-with-the-stm32f4f7h7-series-stmicroelectronics.pdf)). This is why BitPolish locks the bit depth at 24-bit by default: it changes nothing for 16-bit tracks and keeps 24-bit tracks intact, and it's the most S/PDIF can carry.

## What isn't covered, and how to close it

The capture stops at the stream sent to the device, so steps 4 and 5 weren't measured directly. Two ways to close that gap:
- **Gold standard:** record the DAC connection itself, for example an optical (S/PDIF) output into an audio interface with an optical input, and compare that recording to the file with `compare.py`.
- **Quick check (16-bit):** play a DTS-encoded music file through Music into a receiver that decodes DTS. The receiver only recognizes DTS if every bit arrives untouched.

## Repeat it yourself

1. Choose your DAC in System Settings › Sound › Output. Note its current format with `swift Tools/verification/device_format.swift`.
2. `cd Tools/verification && python3 make_test_signal.py && afconvert -f m4af -d alac reference.wav test-96-24.m4a && python3 compare.py --check-file test-96-24.m4a`
3. `./build_capture_app.sh`
4. Instrument check: `afplay test-96-24.m4a &`, then `open -a "BitPolish Capture Test.app" --args <afplay's PID> 8 afplay.f32`, then `python3 compare.py afplay.f32`. It must say BIT-EXACT before you trust any other result.
5. Add `test-96-24.m4a` to Music. Set Music's volume to 100%, turn your DAC down, switch BitPolish On, run `open -a "BitPolish Capture Test.app" --args $(pgrep -x Music) 8 music.f32`, press Play in Music, then `python3 compare.py music.f32`.
6. Set your device back to its original format, and delete the test track from Music.
