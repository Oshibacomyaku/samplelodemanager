#!/usr/bin/env python3
# @noindex
"""
Phase C-lite reranker.

Design goals:
- Generic: works with any candidate tags (no fixed tag list).
- Optional dependency: if CLAP is unavailable, exits with empty output.
- Read-only side effect: writes only output TSV.
"""
import argparse
from pathlib import Path


def read_candidates(path: Path):
    if not path.exists():
        return []
    out = []
    seen = set()
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        t = line.strip().lower()
        if t and t not in seen:
            seen.add(t)
            out.append(t)
    return out


def tag_to_prompt(tag: str) -> str:
    # Generic prompt template to avoid hardcoding specific tags.
    return f"a music sample tagged as {tag}"


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--audio", required=True)
    ap.add_argument("--candidates", required=True)
    ap.add_argument("--output", required=True)
    args = ap.parse_args()

    audio_path = Path(args.audio)
    candidates = read_candidates(Path(args.candidates))
    out_path = Path(args.output)

    if not audio_path.exists() or not candidates:
        out_path.write_text("", encoding="utf-8")
        return

    try:
        import numpy as np
        import torch
        import torchaudio
        import laion_clap
    except Exception:
        # Dependency missing: keep pipeline functional by returning no scores.
        out_path.write_text("", encoding="utf-8")
        return

    try:
        device = "cuda" if torch.cuda.is_available() else "cpu"
        model = laion_clap.CLAP_Module(enable_fusion=False, amodel="HTSAT-base")
        model.load_ckpt()
        model.to(device)
        model.eval()

        waveform, sr = torchaudio.load(str(audio_path))
        if waveform.shape[0] > 1:
            waveform = waveform.mean(dim=0, keepdim=True)
        target_sr = 48000
        if sr != target_sr:
            waveform = torchaudio.functional.resample(waveform, sr, target_sr)
        max_len = target_sr * 10
        if waveform.shape[1] > max_len:
            waveform = waveform[:, :max_len]

        audio_np = waveform.squeeze(0).cpu().numpy().astype("float32")
        with torch.no_grad():
            a_emb = model.get_audio_embedding_from_data(x=[audio_np], use_tensor=False)
            prompts = [tag_to_prompt(t) for t in candidates]
            t_emb = model.get_text_embedding(prompts, use_tensor=False)

        a = np.array(a_emb[0], dtype=np.float32)
        an = np.linalg.norm(a) + 1e-9
        rows = []
        for tag, vec in zip(candidates, t_emb):
            v = np.array(vec, dtype=np.float32)
            score = float(np.dot(a, v) / (an * (np.linalg.norm(v) + 1e-9)))
            # map cosine [-1,1] -> [0,1]
            score01 = max(0.0, min(1.0, 0.5 * (score + 1.0)))
            rows.append((tag, score01))

        out_lines = [f"{tag}\t{score:.4f}" for tag, score in rows]
        out_path.write_text("\n".join(out_lines), encoding="utf-8")
    except Exception:
        out_path.write_text("", encoding="utf-8")


if __name__ == "__main__":
    main()

