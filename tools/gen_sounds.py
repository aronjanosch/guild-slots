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


def envelope(n, attack, release):
    """Linear fade in over `attack` and out over `release` seconds (n samples)."""
    env = np.ones(n)
    a, r = max(1, int(attack * RATE)), max(1, int(release * RATE))
    env[:a] *= np.linspace(0, 1, a)
    env[-r:] *= np.linspace(1, 0, r)
    return env


def bell(freq, length, decay, partials=((1, 1.0), (2.0, 0.35), (3.01, 0.12))):
    """A soft bell tone: a few sine partials with an exponential decay."""
    t = seconds(length)
    out = np.zeros(len(t))
    for mult, level in partials:
        out += level * np.sin(2 * np.pi * freq * mult * t) * np.exp(-t * mult / decay)
    return out * envelope(len(t), 0.004, 0.02)


def tension_riser(length=3.0):
    """Anticipation: a buzzy tone gliding up an octave and a half with a quickening tremolo and
    a very quiet noise bed. Stopped by the addon when the last teased reel lands."""
    t = seconds(length)
    u = t / length
    freq = 110 * 2 ** (1.6 * u)  # 110 Hz -> about 333 Hz
    phase = 2 * np.pi * np.cumsum(freq) / RATE
    tone = np.sin(phase) + 0.45 * np.sin(2 * phase) + 0.2 * np.sin(3 * phase)
    tremolo = 0.75 + 0.25 * np.sin(2 * np.pi * np.cumsum(4 + 10 * u) / RATE)
    noise = bandpass(rng.standard_normal(len(t)), 400, 3000) * (0.02 + 0.04 * u)  # barely there
    out = (0.55 * tone * tremolo + noise) * (0.35 + 0.65 * u)
    return out * envelope(len(t), 0.25, 0.06)


def count_tick(step):
    """One count-up tick: a short bright blip, a whole tone higher per ladder step."""
    t = seconds(0.07)
    freq = 1046.5 * 2 ** (2 * step / 12)  # C6 upwards in whole tones
    blip = np.sin(2 * np.pi * freq * t) + 0.25 * np.sin(2 * np.pi * 2 * freq * t)
    click = bandpass(rng.standard_normal(len(t)), 2000, 7000) * np.exp(-t / 0.002)
    out = (blip * np.exp(-t / 0.018) + 0.08 * click)
    return out * envelope(len(t), 0.001, 0.01)


def tease_miss():
    """The last teased reel lands without the tome: a dull, falling thud."""
    t = seconds(0.4)
    freq = 55 + 45 * np.exp(-t / 0.05)
    body = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t / 0.11)
    thump = lowpass(rng.standard_normal(len(t)), 300) * np.exp(-t / 0.03)
    return (body + 0.6 * thump) * envelope(len(t), 0.002, 0.05)


def tease_hit():
    """The last teased reel brings it: a bright rising major arpeggio with a shimmer."""
    out = np.zeros(int(0.8 * RATE))
    for i, f in enumerate((1046.5, 1318.5, 1568.0, 2093.0)):
        add(out, 0.8 * bell(f, 0.8 - 0.05 * i, 0.22), 0.05 * i)
    t = seconds(0.8)
    shimmer = bandpass(rng.standard_normal(len(t)), 5000, 11000) * np.exp(-t / 0.12) * 0.03
    return (out + shimmer) * envelope(len(t), 0.002, 0.08)


def free_start():
    """Free games: a magical upward run (A major) over a soft swell, ending on a held chord."""
    length = 1.5
    out = np.zeros(int(length * RATE))
    run = (440.0, 554.4, 659.3, 880.0, 1108.7, 1318.5)
    for i, f in enumerate(run):
        add(out, 0.6 * bell(f, 0.6, 0.18), 0.07 * i)
    for f in (880.0, 1108.7, 1318.5, 1760.0):
        add(out, 0.35 * bell(f, length - 0.45, 0.45), 0.45)
    t = seconds(length)
    swell = bandpass(rng.standard_normal(len(t)), 2500, 9000) * np.sin(np.pi * t / length) ** 2 * 0.015
    return (out + swell) * envelope(len(t), 0.003, 0.25)


def tier_step():
    """The big-win banner steps up: a low boom under a bright chord stab."""
    t = seconds(0.7)
    freq = 48 + 70 * np.exp(-t / 0.04)
    boom = np.sin(2 * np.pi * np.cumsum(freq) / RATE) * np.exp(-t / 0.18)
    burst = lowpass(rng.standard_normal(len(t)), 1200) * np.exp(-t / 0.04) * 0.15
    stab = np.zeros(len(t))
    for f in (523.3, 659.3, 784.0, 1046.5):
        stab += 0.3 * bell(f, 0.7, 0.2)
    return (boom + burst + stab) * envelope(len(t), 0.002, 0.08)


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
    write("tension_riser.ogg", tension_riser(), peak=0.6)
    for k in range(8):
        write(f"count_tick_{k + 1}.ogg", count_tick(k), peak=0.6)
    write("count_tick_soft.ogg", count_tick(0), peak=0.3)
    write("tease_miss.ogg", tease_miss(), peak=0.75)
    write("tease_hit.ogg", tease_hit(), peak=0.7)
    write("free_start.ogg", free_start(), peak=0.75)
    write("tier_step.ogg", tier_step(), peak=0.8)
