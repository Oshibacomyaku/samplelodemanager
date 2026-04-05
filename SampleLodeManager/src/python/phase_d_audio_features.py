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


def clamp01(v):
    if v < 0.0:
        return 0.0
    if v > 1.0:
        return 1.0
    return v


def token_score(filename_lc: str, pos, neg, default_value=0.5):
    pos_n = 0
    neg_n = 0
    for t in pos:
        if re.search(rf"\b{re.escape(t)}\b", filename_lc):
            pos_n += 1
    for t in neg:
        if re.search(rf"\b{re.escape(t)}\b", filename_lc):
            neg_n += 1
    return clamp01(default_value + (pos_n * 0.12) - (neg_n * 0.12))


def infer_features_from_filename(filename: str):
    fn = (filename or "").lower()
    brightness = token_score(
        fn,
        ["bright", "air", "top", "hat", "shaker", "crisp", "sharp", "hi"],
        ["dark", "sub", "low", "dull", "muffled", "warm"],
        0.5,
    )
    attack = token_score(
        fn,
        ["hard", "punch", "click", "snap", "transient", "attack"],
        ["soft", "gentle", "smooth", "round", "lofi"],
        0.5,
    )
    decay = token_score(
        fn,
        ["long", "tail", "sustain", "reverb", "ring", "wash", "open"],
        ["short", "tight", "closed", "mute", "dry", "stab"],
        0.5,
    )
    noisiness = token_score(
        fn,
        ["noise", "fx", "sizzle", "hiss", "dist", "dirty"],
        ["tone", "sine", "clean", "pure"],
        0.5,
    )
    tonalness = clamp01(1.0 - noisiness)
    spectral_centroid_norm = brightness
    spectral_rolloff_norm = clamp01((0.75 * brightness) + 0.1)
    spectral_bandwidth_norm = clamp01((0.6 * noisiness) + 0.2)
    spectral_flatness = clamp01((0.7 * noisiness) + 0.15)
    mfcc_timbre_norm = clamp01((0.55 * brightness) + (0.45 * (1.0 - tonalness)))
    inharmonicity = clamp01((0.65 * noisiness) + (0.20 * (1.0 - tonalness)) + (0.15 * attack))
    metallicity = clamp01((0.45 * inharmonicity) + (0.20 * spectral_flatness) + (0.20 * attack) + (0.15 * spectral_rolloff_norm))
    return {
        "brightness": brightness,
        "noisiness": noisiness,
        "attack": attack,
        "decay": decay,
        "tonalness": tonalness,
        "spectral_centroid_norm": spectral_centroid_norm,
        "spectral_rolloff_norm": spectral_rolloff_norm,
        "spectral_bandwidth_norm": spectral_bandwidth_norm,
        "spectral_flatness": spectral_flatness,
        "mfcc_timbre_norm": mfcc_timbre_norm,
        "inharmonicity": inharmonicity,
        "metallicity": metallicity,
    }


def iter_mono_samples(raw: bytes, sampwidth: int):
    if sampwidth == 1:
        for i in range(0, len(raw), 1):
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


def to_mono_samples(raw: bytes, sw: int, ch: int):
    if ch > 1:
        raw = audioop.tomono(raw, sw, 0.5, 0.5)
    return list(iter_mono_samples(raw, sw))


def trim_leading_silence_mono(samples: list, sr: int):
    """Skip beginning until sustained non-silent frames (RMS). Keeps attack features meaningful."""
    if not samples or sr <= 0:
        return samples
    win = max(32, int(sr * 0.01))
    hop = max(1, win // 2)
    n = len(samples)
    thr = 0.012
    need = 2
    run = 0
    i = 0
    while i + win <= n:
        chunk = samples[i : i + win]
        rms = math.sqrt(sum(x * x for x in chunk) / float(len(chunk)))
        if rms >= thr:
            run += 1
            if run >= need:
                start = max(0, i - (need - 1) * hop)
                return samples[start:]
        else:
            run = 0
        i += hop
    return samples


def compute_basic_stats(samples, sr):
    if not samples or sr <= 0:
        return None
    # Downsample for speed on long files.
    step = max(1, len(samples) // 24000)
    xs = samples[::step]
    n = len(xs)
    # Short one-shots: allow smaller windows (was 16; Reaper plays sub-40 ms hits fine).
    if n < 4:
        return None
    total_e = 0.0
    hp_e = 0.0
    zc = 0
    prev = xs[0]
    for i in range(n):
        x = xs[i]
        total_e += x * x
        if i > 0:
            d = x - prev
            hp_e += d * d
            if (x >= 0.0 and prev < 0.0) or (x < 0.0 and prev >= 0.0):
                zc += 1
            prev = x
    if total_e <= 1e-12:
        return None
    zcr = float(zc) / float(n)
    bright = clamp01((hp_e / total_e) * 0.5)
    return {"total_e": total_e, "zcr": zcr, "brightness": bright}


def _attack_decay_from_rms_list(rms):
    """Coarse attack/decay from per-window RMS; supports 1..3 windows (short files)."""
    if not rms:
        return None
    peak = max(rms) or 1.0
    peak_idx = max(range(len(rms)), key=lambda i: rms[i])
    norm = [x / peak for x in rms]
    attack = clamp01(1.0 - (float(peak_idx) / float(len(norm))))
    thr = 0.1
    decay_idx = len(norm) - 1
    for i in range(peak_idx, len(norm)):
        if norm[i] <= thr:
            decay_idx = i
            break
    decay = clamp01(float(decay_idx - peak_idx) / float(max(1, len(norm) - peak_idx)))
    return {"attack": attack, "decay": decay}


def compute_envelope_features(raw, sw, sr):
    if sr <= 0:
        return None
    win = max(1, int(sr * 0.01))  # 10 ms
    frame_bytes = win * sw
    if frame_bytes <= 0:
        return None
    rms = []
    for i in range(0, len(raw), frame_bytes):
        chunk = raw[i : i + frame_bytes]
        if len(chunk) < frame_bytes:
            break
        rms.append(float(audioop.rms(chunk, sw)))
    return _attack_decay_from_rms_list(rms)


def compute_envelope_features_from_samples(samples, sr):
    """Float mono samples; same semantics as compute_envelope_features for short clips."""
    if not samples or sr <= 0:
        return None
    win = max(1, int(sr * 0.01))
    rms = []
    for i in range(0, len(samples), win):
        chunk = samples[i : i + win]
        if len(chunk) < win:
            break
        rms.append(math.sqrt(sum(x * x for x in chunk) / float(len(chunk))))
    if not rms and len(samples) >= 4:
        rms.append(math.sqrt(sum(x * x for x in samples) / float(len(samples))))
    return _attack_decay_from_rms_list(rms)


def compute_tonalness(samples, sr):
    if not samples or sr <= 0:
        return None
    # Keep tonalness lightweight: short window + optional decimation.
    target = min(len(samples), max(1024, int(sr * 0.08)))
    x = samples[:target]
    if len(x) > 8000:
        step = max(1, len(x) // 8000)
        x = x[::step]
        target = len(x)
    e = sum(v * v for v in x)
    if e <= 1e-12:
        return None
    min_lag = max(8, int(sr / 1000.0))
    max_lag = min(target - 2, int(sr / 80.0))
    if max_lag <= min_lag:
        return None
    best = 0.0
    for lag in range(min_lag, max_lag + 1):
        s = 0.0
        m = target - lag
        for i in range(m):
            s += x[i] * x[i + lag]
        c = s / e
        if c > best:
            best = c
    return clamp01(best)


def compute_spectral_shape(samples, sr):
    try:
        import numpy as np
    except Exception:
        return None
    if not samples or sr <= 0:
        return None
    n = min(len(samples), 8192)
    if n < 128:
        return None
    x = np.asarray(samples[:n], dtype=np.float32)
    x = x - np.mean(x)
    win = np.hanning(n).astype(np.float32)
    xw = x * win
    spec = np.fft.rfft(xw)
    mag = np.abs(spec).astype(np.float64)
    pwr = (mag * mag) + 1e-12
    freqs = np.fft.rfftfreq(n, d=1.0 / float(sr)).astype(np.float64)
    psum = float(np.sum(pwr))
    if psum <= 1e-12:
        return None
    nyq = max(1.0, float(sr) * 0.5)
    centroid_hz = float(np.sum(freqs * pwr) / psum)
    centroid = clamp01(centroid_hz / nyq)
    csum = np.cumsum(pwr)
    ridx = int(np.searchsorted(csum, 0.85 * psum))
    ridx = max(0, min(ridx, len(freqs) - 1))
    rolloff = clamp01(float(freqs[ridx]) / nyq)
    bw_hz = float(np.sqrt(np.sum(((freqs - centroid_hz) ** 2.0) * pwr) / psum))
    bandwidth = clamp01(bw_hz / nyq)
    flatness = float(math.exp(float(np.mean(np.log(pwr)))) / float(np.mean(pwr)))
    flatness = clamp01(flatness)
    return {
        "centroid": centroid,
        "rolloff": rolloff,
        "bandwidth": bandwidth,
        "flatness": flatness,
    }


def compute_mfcc_timbre(samples, sr):
    try:
        import numpy as np
        from scipy.fftpack import dct
    except Exception:
        return None
    if not samples or sr <= 0:
        return None
    n = min(len(samples), 4096)
    if n < 256:
        return None
    x = np.asarray(samples[:n], dtype=np.float32)
    x = x - np.mean(x)
    win = np.hanning(n).astype(np.float32)
    spec = np.fft.rfft(x * win)
    mag = np.abs(spec).astype(np.float64)
    log_mag = np.log1p(mag)
    cep = dct(log_mag, type=2, norm="ortho")
    if cep.shape[0] < 4:
        return None
    # Compact timbre proxy from low-order cepstral coefficients.
    score = float((abs(cep[1]) + abs(cep[2]) + abs(cep[3])) / 18.0)
    return clamp01(score)


def compute_inharmonicity_and_peak_irregularity(samples, sr):
    """Estimate inharmonicity + peak spacing irregularity from top spectral peaks."""
    try:
        import numpy as np
    except Exception:
        return None, None
    if not samples or sr <= 0:
        return None, None
    n = min(len(samples), 8192)
    if n < 512:
        return None, None
    x = np.asarray(samples[:n], dtype=np.float32)
    x = x - np.mean(x)
    win = np.hanning(n).astype(np.float32)
    spec = np.fft.rfft(x * win)
    mag = np.abs(spec).astype(np.float64)
    freqs = np.fft.rfftfreq(n, d=1.0 / float(sr)).astype(np.float64)
    if mag.shape[0] < 8:
        return None, None
    peak_idx = []
    for i in range(2, len(mag) - 2):
        m = mag[i]
        if m > mag[i - 1] and m >= mag[i + 1] and m > 1e-8 and freqs[i] >= 40.0:
            peak_idx.append(i)
    if len(peak_idx) < 3:
        return None, None
    peak_idx = sorted(peak_idx, key=lambda i: float(mag[i]), reverse=True)[:16]
    peak_idx = sorted(peak_idx, key=lambda i: float(freqs[i]))
    # Fundamental candidate: lowest strong peak in low-mid region.
    f0 = None
    for i in peak_idx:
        fi = float(freqs[i])
        if 45.0 <= fi <= 1800.0:
            f0 = fi
            break
    if f0 is None:
        f0 = float(freqs[peak_idx[0]])
    if f0 <= 0:
        return None, None
    num = 0.0
    den = 0.0
    for i in peak_idx:
        fi = float(freqs[i])
        amp = float(mag[i])
        if fi <= 0.0 or amp <= 0.0:
            continue
        k = max(1, int(round(fi / f0)))
        target = f0 * float(k)
        if target <= 1e-9:
            continue
        dev = abs(fi - target) / target
        num += dev * amp
        den += amp
    inharm = clamp01((num / den) * 3.5) if den > 1e-12 else None
    if len(peak_idx) >= 4:
        pfs = [float(freqs[i]) for i in peak_idx]
        diffs = [pfs[i + 1] - pfs[i] for i in range(len(pfs) - 1)]
        md = sum(diffs) / float(len(diffs))
        if md > 1e-9:
            var = sum((d - md) * (d - md) for d in diffs) / float(len(diffs))
            cv = math.sqrt(var) / md
            irregular = clamp01(cv * 1.8)
        else:
            irregular = 0.0
    else:
        irregular = None
    return inharm, irregular


def try_read_wav_scipy(path: Path):
    """Float / extended WAV that stdlib `wave` often cannot open; Reaper still plays them."""
    try:
        from scipy.io import wavfile
        import numpy as np

        sr, data = wavfile.read(str(path))
        if data.size == 0 or sr <= 0:
            return None, None
        if data.ndim > 1:
            data = np.mean(data, axis=1)
        data = np.asarray(data)
        dt = data.dtype
        if dt == np.int16:
            samples = (data.astype(np.float64) / 32768.0).tolist()
        elif dt == np.int32:
            samples = (data.astype(np.float64) / 2147483648.0).tolist()
        elif dt == np.uint8:
            samples = ((data.astype(np.float64) - 128.0) / 128.0).tolist()
        elif np.issubdtype(dt, np.floating):
            samples = np.clip(data.astype(np.float64), -1.0, 1.0).tolist()
        else:
            m = float(np.max(np.abs(data.astype(np.float64)))) or 1.0
            samples = (data.astype(np.float64) / m).tolist()
        return int(sr), samples
    except Exception:
        return None, None


def _build_features_from_mono(sr: int, samples: list, mono_raw: bytes | None, sw: int | None):
    if not samples or sr <= 0:
        return None
    stats = compute_basic_stats(samples, sr)
    if mono_raw is not None and sw is not None and sw > 0:
        env = compute_envelope_features(mono_raw, sw, sr)
    else:
        env = compute_envelope_features_from_samples(samples, sr)
    tonal = compute_tonalness(samples, sr)
    shp = compute_spectral_shape(samples, sr)
    mfcc_timbre = compute_mfcc_timbre(samples, sr)
    inharm, peak_irregularity = compute_inharmonicity_and_peak_irregularity(samples, sr)
    if not stats or not env:
        return None
    noisiness = clamp01((stats["zcr"] * 2.8) + (1.0 - (tonal if tonal is not None else 0.35)) * 0.4)
    flatness = (shp and shp.get("flatness")) or noisiness
    hf_decay = clamp01((((shp and shp.get("rolloff")) or stats["brightness"]) * 0.75) + (((shp and shp.get("centroid")) or stats["brightness"]) * 0.25))
    attack = env["attack"]
    tonal_gate = clamp01(((tonal if tonal is not None else 0.35) - 0.25) / 0.45)
    noise_penalty = max(0.0, flatness - 0.55) * 0.35
    metal_core = (0.55 * (inharm if inharm is not None else 0.0)) + (0.35 * (peak_irregularity if peak_irregularity is not None else 0.0)) + (0.10 * hf_decay)
    metallicity = clamp01(((metal_core - noise_penalty) * tonal_gate) + (0.08 * attack))
    return {
        "brightness": stats["brightness"],
        "noisiness": noisiness,
        "attack": attack,
        "decay": env["decay"],
        "tonalness": tonal if tonal is not None else 0.35,
        "spectral_centroid_norm": (shp and shp.get("centroid")) or stats["brightness"],
        "spectral_rolloff_norm": (shp and shp.get("rolloff")) or stats["brightness"],
        "spectral_bandwidth_norm": (shp and shp.get("bandwidth")) or noisiness,
        "spectral_flatness": flatness,
        "mfcc_timbre_norm": mfcc_timbre if mfcc_timbre is not None else stats["brightness"],
        "inharmonicity": inharm if inharm is not None else clamp01((1.0 - (tonal if tonal is not None else 0.35)) * 0.45),
        "metallicity": metallicity,
    }


def extract_audio_features(path: Path):
    path = Path(path)
    try:
        if path.suffix.lower() != ".wav":
            return None
        audio_decoded_len = 0
        # 1) stdlib wave — works for common PCM WAV.
        try:
            with wave.open(str(path), "rb") as wf:
                ch = wf.getnchannels()
                sw = wf.getsampwidth()
                sr = wf.getframerate()
                n = wf.getnframes()
                if n <= 0 or sr <= 0 or sw < 1:
                    raise ValueError("bad wav header")
                max_frames = min(n, int(sr * 1.2))
                raw = wf.readframes(max_frames)
                samples = to_mono_samples(raw, sw, ch)
                samples = trim_leading_silence_mono(samples, int(sr))
                audio_decoded_len = len(samples)
                res = _build_features_from_mono(int(sr), samples, None, None)
                if res is not None:
                    return res
        except Exception:
            pass
        # 2) scipy — float WAV and other layouts Reaper exports / plays.
        sr2, samples2 = try_read_wav_scipy(path)
        if samples2:
            max_samp = min(len(samples2), int(sr2 * 1.2))
            chunk = trim_leading_silence_mono(samples2[:max_samp], int(sr2))
            audio_decoded_len = max(audio_decoded_len, len(chunk))
            res = _build_features_from_mono(sr2, chunk, None, None)
            if res is not None:
                return res
        # 3) Ultra-short / near-silent clips: STFT & stats often fail; filename tokens still help UMAP.
        if audio_decoded_len > 0:
            return infer_features_from_filename(path.name)
        return None
    except Exception:
        return None


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
            feat = extract_audio_features(Path(full_path))
            if feat is None:
                # Do not fabricate values: DB layer stores NULLs so rescans can retry.
                # Keep 13 columns: idx + 12 feature slots.
                rows_out.append("\t".join([idx] + [""] * 12))
            else:
                rows_out.append(
                    (
                        f"{idx}\t{feat['brightness']:.4f}\t{feat['noisiness']:.4f}\t{feat['attack']:.4f}"
                        f"\t{feat['decay']:.4f}\t{feat['tonalness']:.4f}"
                        f"\t{feat['spectral_centroid_norm']:.4f}\t{feat['spectral_rolloff_norm']:.4f}"
                        f"\t{feat['spectral_bandwidth_norm']:.4f}\t{feat['spectral_flatness']:.4f}\t{feat['mfcc_timbre_norm']:.4f}"
                        f"\t{feat['inharmonicity']:.4f}\t{feat['metallicity']:.4f}"
                    )
                )
    out_path.write_text("\n".join(rows_out), encoding="utf-8")


if __name__ == "__main__":
    main()
