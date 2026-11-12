#!/usr/bin/env python3
"""Synthesise the addon's own sound effects into GuildSlots/Media/*.ogg.

usage: python3 tools/gen_sounds.py

Needs numpy and ffmpeg (libvorbis). The output is deterministic (fixed seed), so the
committed .ogg files can be rebuilt. Everything is generated here; no samples are used.
"""
import pathlib
import subprocess

import numpy as np

RATE = 44100
OUT = pathlib.Path(__file__).resolve().parent.parent / "GuildSlots" / "Media"
rng = np.random.default_rng(7)


def seconds(n):
    return np.arange(int(n * RATE)) / RATE


def lowpass(x, cutoff):
    """One-pole low-pass."""
    a = 1 - np.exp(-2 * np.pi * cutoff / RATE)
    y = np.empty_like(x)
    acc = 0.0
    for i, v in enumerate(x):
        acc += a * (v - acc)
        y[i] = acc
    return y


def bandpass(x, low, high):
    return lowpass(x, high) - lowpass(x, low)


def add(dst, src, at):
    i = int(at * RATE)
    n = min(len(src), len(dst) - i)
    if n > 0:
        dst[i : i + n] += src[:n]


def tick(pitch, level):
    """One reel ratchet tick: a short noise click with a little pitched body."""
    t = seconds(0.022)
    click = bandpass(rng.standard_normal(len(t)), 1500, 6000) * np.exp(-t / 0.0025)
    body = np.sin(2 * np.pi * pitch * t) * np.exp(-t / 0.006)
    return level * (0.9 * click + 0.5 * body)


def reel_spin(length=3.2, rate=24.0):
    """Ratchet ticks over a soft whirr. The addon stops it when the last reel lands."""
    out = np.zeros(int(length * RATE))
    t = seconds(length)
    whirr = bandpass(rng.standard_normal(len(t)), 180, 900)
    whirr *= 0.10 * (1 + 0.25 * np.sin(2 * np.pi * 7 * t))
    out += whirr
    at, k = 0.0, 0
    while at < length - 0.03:
        pitch = (620, 540, 700)[k % 3] * (1 + 0.03 * rng.standard_normal())
        add(out, tick(pitch, 0.55 + 0.1 * rng.random()), at)
        at += (1 / rate) * (1 + 0.06 * rng.standard_normal())
        k += 1
    fade = int(0.03 * RATE)
    out[:fade] *= np.linspace(0, 1, fade)
    out[-fade:] *= np.linspace(1, 0, fade)
    return out


def reel_stop():
    """A reel locking in: low thunk, hard click, short metallic ring."""
    t = seconds(0.32)
    freq = 70 + 60 * np.exp(-t / 0.03)
    thunk = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t / 0.07)
    click = bandpass(rng.standard_normal(len(t)), 900, 5000) * np.exp(-t / 0.006)
    ring = (np.sin(2 * np.pi * 1830 * t) + 0.5 * np.sin(2 * np.pi * 2740 * t)) * np.exp(-t / 0.05)
    return 0.9 * thunk + 0.6 * click + 0.12 * ring


def write(name, samples, peak=0.8):
    samples = samples / np.max(np.abs(samples)) * peak
    pcm = (samples * 32767).astype("<i2").tobytes()
    OUT.mkdir(exist_ok=True)
    path = OUT / name
    subprocess.run(
        ["ffmpeg", "-loglevel", "error", "-y", "-f", "s16le", "-ar", str(RATE), "-ac", "1",
         "-i", "-", "-c:a", "libvorbis", "-q:a", "5", "-bitexact", str(path)],
        input=pcm, check=True,
    )
    print(path.relative_to(OUT.parent.parent), f"{len(samples) / RATE:.2f}s")


if __name__ == "__main__":
    write("reel_spin.ogg", reel_spin(), peak=0.6)
    write("reel_stop.ogg", reel_stop(), peak=0.85)
