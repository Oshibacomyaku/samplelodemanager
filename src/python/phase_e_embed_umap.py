#!/usr/bin/env python3
import argparse
import math
from pathlib import Path


def parse_args():
    p = argparse.ArgumentParser()
    p.add_argument("--input", required=True)
    p.add_argument("--output", required=True)
    p.add_argument("--preset", default="core5")
    p.add_argument("--meta", default="")
    p.add_argument("--neighbors", type=int, default=0)
    p.add_argument("--min-dist", dest="min_dist", type=float, default=-1.0)
    return p.parse_args()


def read_rows(path: Path):
    rows = []
    if not path.exists():
        return rows
    for line in path.read_text(encoding="utf-8", errors="ignore").splitlines():
        parts = line.split("\t")
        if len(parts) < 3:
            continue
        idx = int(parts[0])
        vals = []
        ok = True
        for t in parts[1:]:
            try:
                vals.append(float(t))
            except Exception:
                ok = False
                break
        if ok:
            rows.append((idx, vals))
    return rows


def minmax_scale(v):
    if not v:
        return []
    lo = min(v)
    hi = max(v)
    if hi - lo < 1e-12:
        return [0.5 for _ in v]
    return [(x - lo) / (hi - lo) for x in v]


def embed_coords_clip_minmax(idxs, xs, ys, low_q=1.0, high_q=99.0):
    """Clip raw 2D coords per axis to [percentile(low_q), percentile(high_q)], then min-max to 0..1.

    Narrow percentiles (e.g. 1..99) squash every outlier onto the same clip boundary before
    scaling, which creates visible vertical/horizontal "walls" in the galaxy view. For UMAP
    output, use low_q=0, high_q=100 to only min-max the natural spread (no pre-clip).
    """
    import numpy as np

    if not xs or len(xs) != len(ys) or len(xs) != len(idxs):
        return []
    xa = np.array(xs, dtype=np.float64)
    ya = np.array(ys, dtype=np.float64)
    lo_x, hi_x = float(np.percentile(xa, low_q)), float(np.percentile(xa, high_q))
    lo_y, hi_y = float(np.percentile(ya, low_q)), float(np.percentile(ya, high_q))
    if hi_x - lo_x < 1e-12:
        lo_x, hi_x = float(xa.min()), float(xa.max())
    if hi_y - lo_y < 1e-12:
        lo_y, hi_y = float(ya.min()), float(ya.max())
    xa = np.clip(xa, lo_x, hi_x)
    ya = np.clip(ya, lo_y, hi_y)
    xs_out = minmax_scale(xa.tolist())
    ys_out = minmax_scale(ya.tolist())
    return [(idxs[i], xs_out[i], ys_out[i]) for i in range(len(idxs))]


def percentile_clip_matrix(x, low_q=1.0, high_q=99.0):
    import numpy as np
    if x.size == 0:
        return x
    lo = np.percentile(x, low_q, axis=0, keepdims=True)
    hi = np.percentile(x, high_q, axis=0, keepdims=True)
    return np.clip(x, lo, hi)


def fallback_embed(rows):
    # rows: [(idx, [features...]), ...]
    def fv(vec, i, default=0.5):
        if i < len(vec):
            return float(vec[i])
        return default
    xs = []
    ys = []
    idxs = []
    for idx, f in rows:
        # Generic low-dim fallback from selected feature vector.
        a = fv(f, 0)
        d = fv(f, 1)
        t = fv(f, 2)
        c = fv(f, 3)
        mf = fv(f, 4)
        x = (0.24 * a) + (0.24 * t) + (0.24 * c) + (0.28 * mf)
        y = (0.34 * d) + (0.28 * (1.0 - t)) + (0.38 * (1.0 - c))
        # Tiny deterministic jitter in embed space.
        h = math.sin((idx * 12.9898) + 78.233) * 43758.5453
        h2 = math.sin((idx * 23.3571) + 41.114) * 24631.1431
        x += ((h - math.floor(h)) - 0.5) * 0.02
        y += ((h2 - math.floor(h2)) - 0.5) * 0.02
        idxs.append(idx)
        xs.append(x)
        ys.append(y)
    return embed_coords_clip_minmax(idxs, xs, ys, 0.0, 100.0)


def build_rows_for_preset(rows, preset):
    """
    Input row vector order from phase_d:
    [brightness, noisiness, attack, decay, tonalness, centroid, rolloff, bandwidth, flatness, mfcc]
    """
    preset = (preset or "core5").strip().lower()
    indices_map = {
        # default: current tuned set
        "core5": [2, 3, 4, 5, 6, 9],              # attack, decay, tonalness, centroid, rolloff, mfcc
        # ablation presets
        "no_mfcc": [2, 3, 4, 5, 8],               # replace mfcc with flatness
        "no_tonal": [2, 3, 5, 8, 9],              # remove tonalness
        "with_flatness": [2, 3, 4, 5, 8, 9],      # add flatness back
        "spectral_only": [5, 6, 7, 8, 9],         # centroid, rolloff, bandwidth, flatness, mfcc
        "envelope_only": [2, 3, 4],               # attack, decay, tonalness
    }
    idxs = indices_map.get(preset, indices_map["core5"])
    out = []
    for idx, vals in rows:
        vec = []
        for i in idxs:
            if i < len(vals):
                vec.append(float(vals[i]))
            else:
                vec.append(0.5)
        out.append((idx, vec))
    return out


def umap_embed(rows, neighbors=0, min_dist=-1.0):
    auto_neighbors = min(96, max(18, len(rows) // 12))
    use_neighbors = int(neighbors) if isinstance(neighbors, int) else 0
    if use_neighbors <= 0:
        use_neighbors = auto_neighbors
    use_neighbors = max(4, min(240, use_neighbors))
    use_min_dist = float(min_dist) if isinstance(min_dist, (int, float)) else -1.0
    if use_min_dist < 0:
        use_min_dist = 0.34
    use_min_dist = max(0.0, min(0.99, use_min_dist))
    try:
        import numpy as np
        import umap
    except Exception:
        return None
    if len(rows) < 4:
        return None
    idxs = [idx for idx, _ in rows]
    x = np.array([f for _, f in rows], dtype=np.float32)
    # Robustify against outliers before standardization.
    x = percentile_clip_matrix(x, 2.0, 98.0)
    # Simple standardization
    m = x.mean(axis=0, keepdims=True)
    s = x.std(axis=0, keepdims=True) + 1e-8
    z = (x - m) / s
    # Feature weighting (after standardization):
    # For core5-like vectors, index 3/4 are centroid/rolloff; boost both to reduce pitch-adjacent mixups.
    if z.shape[1] >= 4:
        z[:, 3] *= 1.30
    if z.shape[1] >= 5:
        z[:, 4] *= 1.15
    try:
        # Slightly more local than before:
        # old: len(rows)//10 clamped to [24,120]
        # new: len(rows)//12 clamped to [18,96]
        # This tends to separate nearby timbre groups a bit better while keeping global stability.
        reducer = umap.UMAP(
            n_components=2,
            n_neighbors=use_neighbors,
            # Slightly higher min_dist spreads points and reduces edge-piling in 2D.
            min_dist=use_min_dist,
            metric="euclidean",
            random_state=42,
        )
        emb = reducer.fit_transform(z)
    except Exception:
        return None
    # Guard: if UMAP returns NaN/Inf, caller should fallback.
    if not np.isfinite(emb).all():
        return None
    ex = emb[:, 0].tolist()
    ey = emb[:, 1].tolist()
    # Full-range min-max only: avoids 1..99% clip stacking into straight "walls".
    return embed_coords_clip_minmax(idxs, ex, ey, 0.0, 100.0)


def main():
    args = parse_args()
    in_path = Path(args.input)
    out_path = Path(args.output)
    meta_path = Path(args.meta) if (args.meta or "").strip() else None
    rows = read_rows(in_path)
    if not rows:
        out_path.write_text("", encoding="utf-8")
        if meta_path is not None:
            meta_path.write_text(f"mode=empty\npreset={args.preset}\nrows=0\ndims=0\n", encoding="utf-8")
        return
    rows = build_rows_for_preset(rows, args.preset)
    dims = len(rows[0][1]) if rows else 0
    mode = "umap"
    emb = umap_embed(rows, args.neighbors, args.min_dist)
    if emb is None:
        mode = "fallback"
        emb = fallback_embed(rows)
    # Final guard for serialization stability.
    safe = []
    for idx, x, y in emb:
      if not (math.isfinite(x) and math.isfinite(y)):
          continue
      safe.append((idx, x, y))
    if not safe:
      mode = "fallback"
      safe = fallback_embed(rows)
    lines = [f"{idx}\t{x:.6f}\t{y:.6f}" for idx, x, y in safe]
    out_path.write_text("\n".join(lines), encoding="utf-8")
    if meta_path is not None:
        meta_path.write_text(
            f"mode={mode}\npreset={args.preset}\nrows={len(rows)}\ndims={dims}\n"
            f"neighbors={args.neighbors}\nmin_dist={args.min_dist}\n",
            encoding="utf-8",
        )


if __name__ == "__main__":
    main()
