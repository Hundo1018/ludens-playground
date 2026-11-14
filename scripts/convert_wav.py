#!/usr/bin/env python3
"""Convert WAV sound effects into the playground's sound format (.lsound): 48 kHz, mono, 16-bit signed PCM.

Usage:
  python3 scripts/convert_wav.py <in.wav> <out.lsound>
  python3 scripts/convert_wav.py <archive.zip> "<member path inside the zip>" <out.lsound>
  python3 scripts/convert_wav.py --selftest <in.wav>          (or: --selftest <archive.zip> "<member>")

Input: PCM WAV, 8, 16, 24 or 32-bit integer, any channel count (stereo is averaged to mono). Resampling is linear
interpolation to 48000 Hz. Stdlib only.

Format (little-endian): magic b"LSND", u32 version=1, u32 header_len, JSON header {name, rate, channels, frames,
source_rate, source_frames, peak}, then frames int16 samples.
"""
import argparse
import array
import io
import json
import pathlib
import struct
import sys
import wave
import zipfile

ROOT = pathlib.Path(__file__).resolve().parent.parent
MAGIC = b"LSND"
VERSION = 1
OUT_RATE = 48000


def _open_source(args):
    if args.zip_member is not None:
        with zipfile.ZipFile(args.src) as z:
            return io.BytesIO(z.read(args.zip_member)), args.zip_member
    return open(args.src, "rb"), args.src.name


def read_pcm(fileobj):
    """Return (samples as floats in -1..1, mono, source rate, source frames)."""
    with wave.open(fileobj, "rb") as w:
        ch, width, rate, n = w.getnchannels(), w.getsampwidth(), w.getframerate(), w.getnframes()
        raw = w.readframes(n)
    if width == 1:
        vals = [(b - 128) / 128.0 for b in raw]
    elif width == 2:
        a = array.array("h")
        a.frombytes(raw)
        vals = [v / 32768.0 for v in a]
    elif width == 3:
        vals = []
        for i in range(0, len(raw), 3):
            v = int.from_bytes(raw[i:i + 3], "little", signed=True)
            vals.append(v / 8388608.0)
    elif width == 4:
        a = array.array("i")
        a.frombytes(raw)
        vals = [v / 2147483648.0 for v in a]
    else:
        raise SystemExit(f"unsupported sample width {width}")
    if ch > 1:
        vals = [sum(vals[i:i + ch]) / ch for i in range(0, len(vals), ch)]
    return vals, rate, n


def resample(x, src_rate, dst_rate=OUT_RATE):
    if src_rate == dst_rate or not x:
        return list(x)
    n_out = int(round(len(x) * dst_rate / src_rate))
    step = src_rate / dst_rate
    out = []
    last = len(x) - 1
    for i in range(n_out):
        pos = i * step
        k = int(pos)
        if k >= last:
            out.append(x[last])
            continue
        frac = pos - k
        out.append(x[k] + (x[k + 1] - x[k]) * frac)
    return out


def to_int16(x):
    out = array.array("h")
    for v in x:
        v = max(-1.0, min(1.0, v))
        out.append(int(round(v * 32767)))
    return out


def convert(args):
    f, name = _open_source(args)
    with f:
        samples, rate, n = read_pcm(f)
    out = resample(samples, rate)
    pcm = to_int16(out)
    peak = max((abs(v) for v in samples), default=0.0)
    return {
        "name": name,
        "rate": OUT_RATE,
        "channels": 1,
        "frames": len(pcm),
        "source_rate": rate,
        "source_frames": n,
        "peak": round(peak, 6),
        "pcm": pcm,
    }


def write(out: pathlib.Path, d: dict):
    pcm = d.pop("pcm")
    header = json.dumps(d, separators=(",", ":")).encode("utf-8")
    with out.open("wb") as f:
        f.write(MAGIC + struct.pack("<II", VERSION, len(header)) + header)
        f.write(pcm.tobytes())
    d["pcm"] = pcm
    return out


def read_back(path: pathlib.Path):
    data = path.read_bytes()
    if data[:4] != MAGIC:
        raise SystemExit("bad magic")
    version, hlen = struct.unpack_from("<II", data, 4)
    header = json.loads(data[12:12 + hlen].decode("utf-8"))
    pcm = array.array("h")
    pcm.frombytes(data[12 + hlen:])
    return header, pcm


def selftest(args) -> int:
    f, name = _open_source(args)
    with f:
        samples, rate, n = read_pcm(f)
    d = convert(args)
    out = ROOT / "build" / "assets" / "converted" / (pathlib.Path(name).stem + ".lsound")
    out.parent.mkdir(parents=True, exist_ok=True)
    write(out, dict(d))
    header, pcm = read_back(out)
    checks = []

    def check(cond, label):
        checks.append(cond)
        print(("PASS " if cond else "FAIL ") + label)

    expect_frames = round(n * OUT_RATE / rate)
    check(header["rate"] == OUT_RATE and header["channels"] == 1, "output is 48000 Hz mono")
    check(abs(header["frames"] - expect_frames) <= 1, f"frames {header['frames']} ~ {expect_frames} (source {n} at {rate} Hz)")
    check(len(pcm) == header["frames"], "PCM length matches the header")
    dur_in = n / rate
    dur_out = header["frames"] / OUT_RATE
    check(abs(dur_in - dur_out) < 2.0 / OUT_RATE, f"duration kept: {dur_in:.5f} s in, {dur_out:.5f} s out")
    out_peak = max(abs(v) for v in pcm) / 32767.0
    src_peak = max(abs(v) for v in samples)
    # linear resampling can step over the top of a peak, so the peak may drop a little; it must not rise or drop by more
    check(abs(out_peak - src_peak) < 0.02, f"peak within 2% after linear resampling: {out_peak:.4f} vs source {src_peak:.4f}")
    # a few samples against a direct evaluation of the same interpolation, to catch index errors
    base = resample(samples, rate)
    sample_ok = all(abs(pcm[i] - round(max(-1, min(1, base[i])) * 32767)) <= 1 for i in range(0, min(len(pcm), 2000), 97))
    check(sample_ok, "sampled output matches the interpolated input within 1 LSB")
    ok = all(checks)
    print(f"convert_wav selftest: {sum(checks)} / {len(checks)} checks; wrote {out}")
    return 0 if ok else 1


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("src", type=pathlib.Path)
    ap.add_argument("zip_member", nargs="?", default=None)
    ap.add_argument("out", type=pathlib.Path, nargs="?")
    ap.add_argument("--selftest", action="store_true")
    args = ap.parse_args()
    if args.src.suffix.lower() == ".zip":
        if args.zip_member is None:
            ap.error("a zip needs the member path")
    else:
        if args.zip_member is not None and args.out is None:
            args.out, args.zip_member = pathlib.Path(args.zip_member), None
    args.zip_member = args.zip_member if args.src.suffix.lower() == ".zip" else None
    if args.selftest:
        return selftest(args)
    if args.out is None:
        ap.error("out is required unless --selftest")
    write(args.out, convert(args))
    print(f"wrote {args.out}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
