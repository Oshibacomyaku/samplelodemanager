#!/usr/bin/env python3
# @noindex
import argparse
import audioop
import math
import re
import wave
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    return p.parse_args()


def _iter_mono_samples(raw: bytes, sampwidth: int):
    if sampwidth == 1:
        for i in range(0, len(raw), 1):
            # 8-bit PCM in WAV is unsigned.
            yield float(raw[i] - 128) / 128.0
    elif sampwidth == 2:
        for i in range(0, len(raw), 2):
            v = int.from_bytes(raw[i : i + 2], byteorder="little", signed=True)
            yield float(v) / 32768.0
    elif sampwidth == 3:
        for i in range(0, len(raw), 3):
            b = raw[i : i + 3]
            if len(b) < 3:
                break
            u = b[0] | (b[1] << 8) | (b[2] << 16)
            if u & 0x800000:
                u -= 0x1000000
            yield float(u) / 8388608.0
    elif sampwidth == 4:
        for i in range(0, len(raw), 4):
            v = int.from_bytes(raw[i : i + 4], byteorder="little", signed=True)
            yield float(v) / 2147483648.0


def estimate_low_band_ratio(raw: bytes, sampwidth: int, sample_rate: int):
    if not raw or sample_rate <= 0:
        return None, None
    # One-pole low-pass around ~220 Hz: low-end proxy.
    cutoff_hz = 220.0
    alpha = math.exp(-2.0 * math.pi * cutoff_hz / float(sample_rate))
    one_minus_alpha = 1.0 - alpha

    total_e = 0.0
    low_e = 0.0
    zc = 0
    n = 0
    prev_x = 0.0
    y = 0.0

    for x in _iter_mono_samples(raw, sampwidth):
      n += 1
      total_e += x * x
      y = alpha * y + one_minus_alpha * x
      low_e += y * y
      if n > 1 and ((x >= 0.0 and prev_x < 0.0) or (x < 0.0 and prev_x >= 0.0)):
          zc += 1
      prev_x = x

    if n <= 0 or total_e <= 1e-12:
        return None, None
    low_ratio = low_e / total_e
    zcr = float(zc) / float(n)
    return low_ratio, zcr


def read_wav_stats(path: Path):
    try:
        with wave.open(str(path), "rb") as wf:
            ch = wf.getnchannels()
            sw = wf.getsampwidth()
            fr = wf.getframerate()
            n = wf.getnframes()
            if n <= 0 or fr <= 0:
                return None
            max_frames = min(n, int(fr * 6.0))
            raw = wf.readframes(max_frames)
            if ch > 1:
                raw = audioop.tomono(raw, sw, 0.5, 0.5)
            low_ratio, zcr = estimate_low_band_ratio(raw, sw, fr)
            win = max(1, int(fr * 0.05))
            frame_bytes = win * sw
            rms_vals = []
            for i in range(0, len(raw), frame_bytes):
                chunk = raw[i : i + frame_bytes]
                if len(chunk) < frame_bytes:
                    break
                rms_vals.append(float(audioop.rms(chunk, sw)))
            if not rms_vals:
                return None
            m = sum(rms_vals) / len(rms_vals)
            var = sum((x - m) * (x - m) for x in rms_vals) / max(1, len(rms_vals))
            sd = var ** 0.5
            trans = sum(1 for x in rms_vals if x > (m + sd)) / max(1, len(rms_vals))
            peak = max(rms_vals) if rms_vals else 0.0
            return {
                "mean_rms": m,
                "std_rms": sd,
                "peak_rms": peak,
                "transient_density": trans,
                "duration_sec": float(n) / float(fr),
                "low_band_ratio": low_ratio,
                "zcr": zcr,
            }
    except Exception:
        return None


def infer_hints(filename: str, full_path: str):
    fn = (filename or "").lower()
    hints = []

    # keyword priors
    if re.search(r"\b(ambience|ambient|atmos|atmosphere|atmospheric)\b", fn):
        hints.append("ambient")
    if re.search(r"\b(texture|textures|textural|drone|pad)\b", fn):
        hints.append("texture")

    # lightweight audio hints (wav only)
    p = Path(full_path or "")
    if p.suffix.lower() == ".wav":
        st = read_wav_stats(p)
        if st:
            td = st["transient_density"]
            dur = float(st.get("duration_sec", 0.0) or 0.0)
            mean_rms = float(st.get("mean_rms", 0.0) or 0.0)
            std_rms = float(st.get("std_rms", 0.0) or 0.0)
            peak_rms = float(st.get("peak_rms", 0.0) or 0.0)
            low_ratio = st.get("low_band_ratio")
            zcr = st.get("zcr")
            std_ratio = std_rms / max(1.0, mean_rms)
            crest_like = peak_rms / max(1.0, mean_rms)
            # Low-transient material tends to be ambient/texture-like.
            if td < 0.10 and "ambient" not in hints:
                hints.append("ambient")
            if td < 0.07 and "texture" not in hints:
                hints.append("texture")

            # Conservative bass hint from audio shape:
            # - avoid very short/transient-heavy one-shots (kick-like)
            # - require relatively sustained envelope
            # - avoid obvious drum filename words
            drum_word = re.search(
                r"\b(kick|kicks|snare|snares|clap|claps|hat|hihat|hats|perc|percussion|cymbal|cymbals|crash|ride|splash)\b",
                fn,
            )
            fx_word = re.search(
                r"\b(reverse|reversed|rev|riser|uplifter|downlifter|sweep|swell|whoosh|impact|transition|fx)\b",
                fn,
            )
            if (
                not drum_word
                and not fx_word
                and dur >= 0.18
                and td <= 0.12
                and isinstance(low_ratio, float)
                and low_ratio >= 0.30
                and isinstance(zcr, float)
                and zcr <= 0.14
                and std_ratio <= 0.58
                and crest_like <= 2.8
                and "bass" not in hints
            ):
                hints.append("bass")

    # keep order, dedupe
    out = []
    seen = set()
    for h in hints:
        if h not in seen:
            seen.add(h)
            out.append(h)
    return out


def main():
    args = parse_args()
    in_path = Path(args.input)
    out_path = Path(args.output)
    rows_out = []
    if in_path.exists():
        for line in in_path.read_text(encoding="utf-8", errors="ignore").splitlines():
            parts = line.split("\t")
            if len(parts) < 4:
                continue
            idx, filename, full_path, _pack = parts[0], parts[1], parts[2], parts[3]
            hints = infer_hints(filename, full_path)
            rows_out.append(f"{idx}\t{','.join(hints)}")
    out_path.write_text("\n".join(rows_out), encoding="utf-8")


if __name__ == "__main__":
    main()

