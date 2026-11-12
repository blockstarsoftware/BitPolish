#!/usr/bin/env python3
"""Compare a capture against the reference samples.

  python3 compare.py capture.f32          a capture from capture.swift (float32, interleaved stereo)
  python3 compare.py --check-file X.m4a   decode an encoded test file and check it matches the reference

Reports: share of samples on exact 24-bit values, alignment, the share of
bit-exact samples, best-fit gain, error level, and energy by frequency band
(a resampler shows up as missing energy above its Nyquist frequency).
"""
import subprocess, struct, sys, tempfile, os
import numpy as np

ref = np.load("reference_int24.npy")

def decode(path):
    out = tempfile.mktemp(suffix=".caf")
    subprocess.run(["afconvert", "-f", "caff", "-d", "LEI24", path, out], check=True)
    d = open(out, "rb").read(); os.remove(out); p = 8
    while p < len(d):
        typ = d[p:p+4]; size = struct.unpack(">q", d[p+4:p+12])[0]
        if typ == b"data":
            body = d[p+16:p+12+size] if size >= 0 else d[p+16:]
            b = np.frombuffer(body, dtype=np.uint8); b = b[:len(b)//3*3].reshape(-1, 3)
            v = b[:, 0].astype(np.int32) | (b[:, 1].astype(np.int32) << 8) | (b[:, 2].astype(np.int32) << 16)
            return np.where(v >= 1 << 23, v - (1 << 24), v).reshape(-1, 2)
        p += 12 + size
    raise SystemExit("no audio data found")

def bands(x, rate):
    x = x[:, 0] - x[:, 0].mean(); seg = 8192; w = np.hanning(seg); acc = np.zeros(seg // 2 + 1); k = 0
    for i in range(0, len(x) - seg, seg):
        acc += np.abs(np.fft.rfft(x[i:i+seg] * w)) ** 2; k += 1
    f = np.fft.rfftfreq(seg, 1 / rate); p = acc / max(k, 1)
    e = lambda lo, hi: p[(f >= lo) & (f < hi)].mean()
    base = e(2000, 18000)
    return [(lo, hi, 10 * np.log10(e(lo, hi) / base)) for lo, hi in [(18e3, 20e3), (20e3, 21.5e3), (21.5e3, 22.5e3), (23e3, 30e3), (30e3, 45e3)]]

if sys.argv[1] == "--check-file":
    v = decode(sys.argv[2])
    print("decoded file identical to reference:", np.array_equal(v[:len(ref)], ref))
    sys.exit()

cap = np.fromfile(sys.argv[1], dtype=np.float32).reshape(-1, 2).astype(np.float64)
cap = cap[np.nonzero(np.abs(cap).sum(1))[0][0]:]
scaled = cap * 8388608.0
seg = scaled[:200000]
on_grid = np.mean(np.abs(seg - np.round(seg)) < 1e-6) * 100
probe = seg[1000:1000 + 16384, 0]; r = ref[:, 0].astype(np.float64)
n = 1 << int(np.ceil(np.log2(len(r) + len(probe))))
corr = np.fft.irfft(np.fft.rfft(r, n) * np.conj(np.fft.rfft(probe, n)), n)[: len(r) - len(probe)]
off = int(np.argmax(corr)); start = off - 1000
cc = corr[off] / (np.linalg.norm(probe) * np.linalg.norm(r[off:off + len(probe)]) + 1e-12)
L = min(len(seg), len(ref) - start); a = seg[:L]; b = ref[start:start + L].astype(np.float64)
exact = np.mean(np.round(a) == b) * 100
gain = np.dot(a[:, 0], b[:, 0]) / np.dot(b[:, 0], b[:, 0])
err = 20 * np.log10(np.sqrt(np.mean((a - b) ** 2)) / 8388608.0 + 1e-30)
print(f"samples on exact 24-bit values: {on_grid:.2f}%")
print(f"alignment: reference frame {start}, correlation {cc:.6f}")
print(f"bit-exact samples: {exact:.4f}% of {L}; best-fit gain {gain:.6f}; error {err:.1f} dBFS")
print("energy vs 2-18 kHz (dB): " + ", ".join(f"{lo/1000:g}-{hi/1000:g} kHz {d:+.1f}" for lo, hi, d in bands(cap, 96000)))
print("VERDICT:", "BIT-EXACT" if exact == 100.0 else "NOT bit-exact")
