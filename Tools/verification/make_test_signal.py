#!/usr/bin/env python3
"""Make the test signal: 20 s of independent random 24-bit noise per channel at
about -60 dBFS (quiet, but it exercises every low bit), at 96 kHz.

Writes reference_int24.npy (the exact sample values) and reference.wav
(24-bit). Encode it with:  afconvert -f m4af -d alac reference.wav test-96-24.m4a
Then confirm the encoding is lossless with:  python3 compare.py --check-file test-96-24.m4a
"""
import sys, wave
import numpy as np

rate = int(sys.argv[1]) if len(sys.argv) > 1 else 96000
seconds = 20
rng = np.random.default_rng(20261016)
x = rng.integers(-8388, 8389, size=(rate * seconds, 2), dtype=np.int32)
np.save("reference_int24.npy", x)

u = (x & 0xFFFFFF).astype(np.uint32)
raw = np.stack([u & 0xFF, (u >> 8) & 0xFF, (u >> 16) & 0xFF], axis=-1).astype(np.uint8)
w = wave.open("reference.wav", "wb")
w.setnchannels(2); w.setsampwidth(3); w.setframerate(rate)
w.writeframes(raw.tobytes()); w.close()
print(f"wrote reference_int24.npy and reference.wav: {len(x)} frames at {rate} Hz, 24-bit")
