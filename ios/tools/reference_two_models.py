#!/usr/bin/env python3
"""Offline music removal exactly as the Android app runs it (US-005 reference).

Mirrors MusiclessDsp.java and MusiclessAudioProcessor.java with the two release models
(vocals.onnx, accompaniment.onnx from musicless-models-v1), on the app's window grid:

- window sizes 64, 128, 256, 512, 512, ... frames of 1024 samples, each window's input starting
  with the previous window's last 2048 samples; each window emits size * 1024 - 2048 samples;
- per window: the -24 dBFS RMS gain (at most 30 dB either way), a reflect-padded centred STFT
  (n_fft 4096, hop 1024, periodic Hann), mask = (v + 5e-11) / (v + 2a + 1e-10) on bins < 1024
  (the last frame reuses the previous frame's mask), inverse STFT with Hann^2 normalisation;
- the first 2048 output samples rise linearly into the previous window's falling tail;
- at the end, the remaining samples go out as a short last window, zero-padded to its size.

Precision follows the Java code: squares in float32 summed in float64, spectrum and mask in
float32, FFTs in float64. Started from tools/musicless/reference.py (one model, fixed grid).

Usage: reference_two_models.py MODELS_DIR INPUT.wav OUTPUT.f32
  MODELS_DIR holds <sha256>-vocals.onnx and <sha256>-accompaniment.onnx (ios/.models).
  INPUT.wav: 16-bit PCM, 44.1 kHz, stereo. OUTPUT.f32: interleaved little-endian float32 voices.
Needs numpy and onnxruntime.
"""

import sys
import wave
from pathlib import Path

import numpy as np
import onnxruntime as ort

RATE, N_FFT, HOP, BINS, MAX_FRAMES = 44100, 4096, 1024, 1024, 512
OVERLAP = 2 * HOP
RAMP = 64
HANN = 0.5 - 0.5 * np.cos(2 * np.pi * np.arange(N_FFT) / N_FFT)
RISE = (np.arange(OVERLAP, dtype=np.float32) + np.float32(0.5)) / np.float32(OVERLAP)
FALL = np.float32(1) - RISE


def session(path):
    """Android's MusiclessModelHolder settings."""
    options = ort.SessionOptions()
    options.intra_op_num_threads = 2
    options.inter_op_num_threads = 1
    options.enable_cpu_mem_arena = False
    options.enable_mem_pattern = False
    options.add_session_config_entry("session.intra_op.allow_spinning", "0")
    options.graph_optimization_level = ort.GraphOptimizationLevel.ORT_ENABLE_BASIC
    options.add_free_dimension_override_by_name("num_splits", 1)
    return ort.InferenceSession(str(path), options, providers=["CPUExecutionProvider"])


class Models:
    def __init__(self, directory):
        directory = Path(directory)
        self.vocals = session(next(directory.glob("*-vocals.onnx")))
        self.accompaniment = session(next(directory.glob("*-accompaniment.onnx")))

    def mask(self, magnitude):
        v = self.vocals.run(None, {self.vocals.get_inputs()[0].name: magnitude})[0]
        a = self.accompaniment.run(None, {self.accompaniment.get_inputs()[0].name: magnitude})[0]
        return (v + np.float32(5e-11)) / (v + np.float32(2) * a + np.float32(1e-10))


def separate_window(block, models):
    """block: (W, 2) float32, W = F * HOP -> voices (W, 2) float32."""
    window = block.shape[0]
    frames = window // HOP
    squares = (block * block).astype(np.float64)  # float32 squares, float64 sum (Java)
    gain = np.clip(10 ** -1.2 / (np.sqrt(squares.sum() / block.size) + 1e-9), 10 ** -1.5, 10 ** 1.5)

    x = block.astype(np.float64).T
    padded = np.pad(x, ((0, 0), (N_FFT // 2, N_FFT // 2)), mode="reflect")
    index = np.arange(frames + 1)[:, None] * HOP + np.arange(N_FFT)[None, :]
    spectrum = np.fft.rfft(padded[:, index] * HANN, axis=-1)[..., :BINS]          # (2, F+1, BINS)
    magnitude = (np.abs(spectrum[:, :frames]) * gain).astype(np.float32)[:, None]  # (2, 1, F, BINS)
    spec32 = spectrum.astype(np.complex64)

    mask = models.mask(magnitude)[:, 0]                                            # (2, F, BINS)
    mask = np.concatenate([mask, mask[:, -1:]], axis=1)                            # last frame reuses
    full = np.zeros((2, frames + 1, N_FFT // 2 + 1), np.complex128)
    full[..., :BINS] = spec32 * mask
    pieces = np.fft.irfft(full, n=N_FFT, axis=-1) * HANN

    out = np.zeros((2, window + N_FFT))
    weight = np.zeros(window + N_FFT)
    for f in range(frames + 1):
        out[:, f * HOP:f * HOP + N_FFT] += pieces[:, f]
        weight[f * HOP:f * HOP + N_FFT] += HANN ** 2
    weight = weight[N_FFT // 2:N_FFT // 2 + window]
    voices = out[:, N_FFT // 2:N_FFT // 2 + window] / np.where(weight > 1e-11, weight, 1)
    return voices.T.astype(np.float32)


def separate(stereo, models, log=print):
    """stereo: (n, 2) float32 at 44.1 kHz -> voices (n, 2) float32, on the app's ramped grid."""
    total = stereo.shape[0]
    output, tail = [], None
    buffer = np.zeros((MAX_FRAMES * HOP, 2), np.float32)
    window, filled, position, submitted = RAMP * HOP, 0, 0, 0

    def emit(block, output_frames):
        nonlocal tail
        voices = separate_window(block, models)
        if tail is not None:
            voices[:OVERLAP] = tail + voices[:OVERLAP] * RISE[:, None]
        tail = voices[-OVERLAP:] * FALL[:, None]
        output.append(voices[:output_frames])
        log(f"window frames={block.shape[0] // HOP} outputStartFrame={submitted} outputFrames={output_frames}")

    while position < total:
        take = min(window - filled, total - position)
        buffer[filled:filled + take] = stereo[position:position + take]
        filled += take
        position += take
        if filled == window:
            block = buffer[:window].copy()
            emit(block, window - OVERLAP)
            submitted += window - OVERLAP
            buffer = np.zeros_like(buffer)
            buffer[:OVERLAP] = block[-OVERLAP:]
            filled = OVERLAP
            window = min(window * 2, MAX_FRAMES * HOP)
    if total > submitted:
        emit(buffer[:window].copy(), total - submitted)
    return np.concatenate(output) if output else np.zeros((0, 2), np.float32)


def read_wav(path):
    with wave.open(str(path), "rb") as source:
        if source.getsampwidth() != 2 or source.getnchannels() != 2 or source.getframerate() != RATE:
            raise SystemExit(f"{path}: need 16-bit stereo 44.1 kHz PCM")
        pcm = np.frombuffer(source.readframes(source.getnframes()), "<i2").reshape(-1, 2)
    return pcm.astype(np.float32) / np.float32(32768)


def main():
    if len(sys.argv) != 4:
        raise SystemExit(__doc__)
    models_dir, input_path, output_path = sys.argv[1:]
    stereo = read_wav(input_path)
    voices = separate(stereo, Models(models_dir))
    voices.astype("<f4").tofile(output_path)
    print(f"wrote {output_path}: {voices.shape[0]} frames (onnxruntime {ort.__version__})")


if __name__ == "__main__":
    main()
