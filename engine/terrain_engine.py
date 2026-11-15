"""Vectorised local plane-fit terrain features (research engine, v0.3 draft).

For every pixel, fit z = a*x + b*y + c by least squares over a circular
neighbourhood of diameter L (metres), using only valid pixels.
Outputs per pixel:
  slope_deg  = degrees(arctan(hypot(a, b)))        (absolute slope of fitted plane)
  rough_m    = sqrt(mean squared residual)          (detrended RMS roughness, metres)
  frac_valid = valid pixels / disc pixels
Exact same estimator as the v0.2 prototype's plane_fit(), but computed for all
pixels at once with FFT convolutions of weighted moments.

Draft written with AI assistance (Claude, Anthropic) for NASA Space Apps 2026; disclosed per the
Space Apps AI policy. Reviewed and run by the team.
"""
from __future__ import annotations
import numpy as np
from scipy.signal import fftconvolve


def disc_kernel(r: int):
    yy, xx = np.mgrid[-r:r + 1, -r:r + 1]
    k = ((xx ** 2 + yy ** 2) <= r * r).astype(float)
    return k, xx.astype(float), yy.astype(float)


def _corr(a, k):
    # correlation = convolution with flipped kernel
    return fftconvolve(a, k[::-1, ::-1], mode="same")


def plane_features(z: np.ndarray, valid: np.ndarray, pixel_m: float, L_m: float,
                   min_frac: float = 0.8):
    r = int(round(L_m / (2 * pixel_m)))
    if r < 2:
        raise ValueError("baseline below 5 grid samples across")
    k, kx, ky = disc_kernel(r)
    kx = kx * pixel_m
    ky = ky * pixel_m  # metres; image row index increases downward, sign irrelevant for |grad|
    m = valid.astype(float)
    zz = np.where(valid, z - np.nanmean(z[valid]), 0.0)  # de-mean for numerical stability
    # moments
    S0 = _corr(m, k)
    Sx = _corr(m, k * kx); Sy = _corr(m, k * ky)
    Sxx = _corr(m, k * kx * kx); Syy = _corr(m, k * ky * ky); Sxy = _corr(m, k * kx * ky)
    Sz = _corr(zz, k); Sxz = _corr(zz, k * kx); Syz = _corr(zz, k * ky); Szz = _corr(zz * zz, k)
    A = np.stack([np.stack([Sxx, Sxy, Sx], -1), np.stack([Sxy, Syy, Sy], -1), np.stack([Sx, Sy, S0], -1)], -2)
    bvec = np.stack([Sxz, Syz, Sz], -1)
    frac = S0 / k.sum()
    ok = (frac >= min_frac) & valid
    out_slope = np.full(z.shape, np.nan); out_rough = np.full(z.shape, np.nan)
    idx = np.nonzero(ok)
    Ai = A[idx]; bi = bvec[idx]
    sol = np.linalg.solve(Ai, bi[..., None])[..., 0]
    a, b, c = sol[:, 0], sol[:, 1], sol[:, 2]
    ssr = Szz[idx] - (sol * bi).sum(-1)
    ssr = np.maximum(ssr, 0.0)
    out_slope[idx] = np.degrees(np.arctan(np.hypot(a, b)))
    out_rough[idx] = np.sqrt(ssr / S0[idx])
    # edges: discs that extend past the array are not valid estimates
    out_slope[:r, :] = out_slope[-r:, :] = out_slope[:, :r] = out_slope[:, -r:] = np.nan
    out_rough[:r, :] = out_rough[-r:, :] = out_rough[:, :r] = out_rough[:, -r:] = np.nan
    return out_slope, out_rough, frac, r


def connectivity_curve(slope: np.ndarray, thresholds=(5, 10, 15, 20, 25), stride: int = 1):
    """Largest 4-connected component of cells with slope <= t, as a fraction of all
    valid cells (not of passable cells), so a fully passable window scores 1.0.
    Diagnostic only; thresholds are sweeps, not vehicle limits."""
    from scipy.ndimage import label
    s = slope[::stride, ::stride]
    v = np.isfinite(s); n = v.sum()
    out = {}
    for t in thresholds:
        ok = v & (s <= t)
        if n == 0:
            out[t] = None; continue
        lab, num = label(ok, structure=[[0, 1, 0], [1, 1, 1], [0, 1, 0]])
        out[t] = float(np.bincount(lab[ok]).max() / n) if num else 0.0
    return out


def plane_features_fast(z: np.ndarray, valid: np.ndarray, pixel_m: float, L_m: float):
    """Closed form for COMPLETE discs only (any missing pixel in the disc -> NaN).
    For a full symmetric disc: Sx=Sy=Sxy=0 and Sxx=Syy, so
      a = sum(k*x*z)/Sxx, b = sum(k*y*z)/Syy, c = mean(z),
      SSR = sum(k*z^2) - n*c^2 - a^2*Sxx - b^2*Syy.
    Every term is a convolution with a FIXED kernel, so the identical estimator can
    run in Google Earth Engine with ee.Kernel.fixed + ee.Image.convolve."""
    r = int(round(L_m / (2 * pixel_m)))
    if r < 2:
        raise ValueError("baseline below 5 grid samples across")
    k, kx, ky = disc_kernel(r)
    kx = kx * pixel_m; ky = ky * pixel_m
    n = k.sum(); Sxx = (k * kx * kx).sum(); Syy = (k * ky * ky).sum()
    zz = np.where(valid, z - np.nanmean(z[valid]), 0.0)
    full = _corr(valid.astype(float), k) > n - 0.5
    a = _corr(zz, k * kx) / Sxx
    b = _corr(zz, k * ky) / Syy
    c = _corr(zz, k) / n
    ssr = _corr(zz * zz, k) - n * c * c - a * a * Sxx - b * b * Syy
    slope = np.degrees(np.arctan(np.hypot(a, b)))
    rough = np.sqrt(np.maximum(ssr, 0) / n)
    bad = ~full
    bad[:r, :] = bad[-r:, :] = True; bad[:, :r] = True; bad[:, -r:] = True
    slope[bad] = np.nan; rough[bad] = np.nan
    return slope, rough, r
