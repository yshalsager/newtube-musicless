package com.newtube.mobile.player;

import java.io.FileOutputStream;
import java.io.IOException;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.nio.file.Files;
import java.nio.file.Path;
import java.nio.file.Paths;
import java.util.Locale;

/**
 * Golden fixtures for the Swift DSP port (US-003). Runs the repo's unchanged MusiclessDsp.java
 * (compiled next to this file by run.sh, same package for its package-private API) and writes
 * little-endian float32 arrays plus manifest.json.
 *
 * The input comes from an integer-only generator that the Swift tests reproduce bit for bit
 * (DspGoldenTests.swift): a 4096-entry sine table rounded to int16, three phase accumulators per
 * channel, and xorshift32 noise. The manifest stores its FNV-1a hash so a mismatch fails loudly.
 *
 * F = 64: full spec, magnitude and synthesize output. F = 512: selected frames and output ranges
 * (the full arrays would be ~20 MB), plus sum / sum of squares / max |x| over the full arrays.
 */
public final class DspGolden {
    static final int HOP = MusiclessDsp.HOP, BINS = MusiclessDsp.BINS;
    static final int[] SPEC_FRAMES_512 = {0, 1, 2, 255, 256, 510, 511, 512};
    static final int[] MAGNITUDE_FRAMES_512 = {0, 1, 2, 255, 256, 509, 510, 511};
    static final int[][] OUTPUT_RANGES_512 = {{0, 4096}, {260096, 264192}, {520192, 524288}};

    public static void main(String[] args) throws IOException {
        Path out = Paths.get(args.length > 0 ? args[0] : "fixtures");
        Files.createDirectories(out);
        StringBuilder manifest = new StringBuilder("{\n  \"fixtures\": [\n");
        manifest.append(fixture(out, 64, true)).append(",\n");
        manifest.append(fixture(out, 512, false)).append("\n  ]\n}\n");
        Files.write(out.resolve("manifest.json"), manifest.toString().getBytes(StandardCharsets.UTF_8));
        System.out.println("wrote " + out.toAbsolutePath());
    }

    static String fixture(Path out, int frames, boolean full) throws IOException {
        int window = frames * HOP;
        short[] pcm = input(window);
        float[] audio = new float[pcm.length];
        for (int i = 0; i < pcm.length; i++) audio[i] = pcm[i] / 32768f;

        MusiclessDsp dsp = new MusiclessDsp(frames);
        float[][] analysis = dsp.analyze(audio);
        float[] spec = analysis[0].clone(), magnitude = analysis[1].clone();
        float[] mask = mask(frames);
        float[] output = dsp.synthesize(spec, mask).clone();

        String prefix = "f" + frames + "_";
        float[] specOut = full ? spec : frames(spec, frames + 1, SPEC_FRAMES_512, 2 * BINS);
        float[] magnitudeOut = full ? magnitude : frames(magnitude, frames, MAGNITUDE_FRAMES_512, BINS);
        float[] outputOut = full ? output : ranges(output, OUTPUT_RANGES_512);
        write(out.resolve(prefix + "spec.f32"), specOut);
        write(out.resolve(prefix + "magnitude.f32"), magnitudeOut);
        write(out.resolve(prefix + "output.f32"), outputOut);

        StringBuilder json = new StringBuilder();
        json.append("    {\n");
        json.append("      \"frames\": ").append(frames).append(",\n");
        json.append("      \"full\": ").append(full).append(",\n");
        json.append(String.format(Locale.ROOT, "      \"inputHash\": \"%016x\",%n", fnv(pcm)));
        if (!full) {
            json.append("      \"specFrames\": ").append(list(SPEC_FRAMES_512)).append(",\n");
            json.append("      \"magnitudeFrames\": ").append(list(MAGNITUDE_FRAMES_512)).append(",\n");
            json.append("      \"outputRanges\": [");
            for (int i = 0; i < OUTPUT_RANGES_512.length; i++) {
                json.append(i == 0 ? "" : ", ").append(list(OUTPUT_RANGES_512[i]));
            }
            json.append("],\n");
        }
        json.append("      \"spec\": ").append(stats(spec)).append(",\n");
        json.append("      \"magnitude\": ").append(stats(magnitude)).append(",\n");
        json.append("      \"output\": ").append(stats(output)).append("\n");
        json.append("    }");
        return json.toString();
    }

    /** Interleaved stereo int16 from integer arithmetic only, so Swift reproduces it exactly. */
    static short[] input(int window) {
        int[] table = new int[4096];
        for (int i = 0; i < 4096; i++) table[i] = (int) Math.floor(Math.sin(2 * Math.PI * i / 4096) * 32767 + 0.5);
        int[] increments = {21_425_000, 133_903_000, 536_870_912, 32_137_000, 194_783_000, 681_706_000};
        int[] phases = new int[6];
        int noise = 0x12345678;
        short[] pcm = new short[window * 2];
        for (int n = 0; n < window; n++) {
            for (int c = 0; c < 2; c++) {
                int s = 0;
                int[] weights = {8, 5, 2};
                for (int j = 0; j < 3; j++) {
                    int k = c * 3 + j;
                    s += table[phases[k] >>> 20] * weights[j];
                    phases[k] += increments[k];
                }
                noise ^= noise << 13;
                noise ^= noise >>> 17;
                noise ^= noise << 5;
                s = s / 32 + (((noise >>> 16) & 0xFFFF) - 32768) / 16;
                pcm[n * 2 + c] = (short) s;
            }
        }
        return pcm;
    }

    /** A fixed mask in [0, 1], exact in float in both languages. */
    static float[] mask(int frames) {
        float[] mask = new float[2 * frames * BINS];
        for (int c = 0; c < 2; c++) {
            for (int f = 0; f < frames; f++) {
                for (int k = 0; k < BINS; k++) {
                    mask[(c * frames + f) * BINS + k] = ((c * 7 + f * 13 + k * 31) % 101) / 100f;
                }
            }
        }
        return mask;
    }

    /** For each channel, then each listed frame: `width` floats. */
    static float[] frames(float[] array, int framesPerChannel, int[] picks, int width) {
        float[] result = new float[2 * picks.length * width];
        int at = 0;
        for (int c = 0; c < 2; c++) {
            for (int f : picks) {
                System.arraycopy(array, (c * framesPerChannel + f) * width, result, at, width);
                at += width;
            }
        }
        return result;
    }

    /** Interleaved stereo sample frames [start, end) of each range, concatenated. */
    static float[] ranges(float[] stereo, int[][] ranges) {
        int total = 0;
        for (int[] range : ranges) total += (range[1] - range[0]) * 2;
        float[] result = new float[total];
        int at = 0;
        for (int[] range : ranges) {
            int length = (range[1] - range[0]) * 2;
            System.arraycopy(stereo, range[0] * 2, result, at, length);
            at += length;
        }
        return result;
    }

    static String stats(float[] values) {
        double sum = 0, squares = 0, max = 0;
        for (float value : values) {
            sum += value;
            squares += (double) value * value;
            max = Math.max(max, Math.abs(value));
        }
        return "{\"count\": " + values.length + ", \"sum\": " + sum + ", \"sumSquares\": " + squares
                + ", \"maxAbs\": " + max + "}";
    }

    static long fnv(short[] pcm) {
        long hash = 0xcbf29ce484222325L;
        for (short sample : pcm) {
            hash ^= sample & 0xFFFF;
            hash *= 0x100000001b3L;
        }
        return hash;
    }

    static String list(int[] values) {
        StringBuilder text = new StringBuilder("[");
        for (int i = 0; i < values.length; i++) text.append(i == 0 ? "" : ", ").append(values[i]);
        return text.append("]").toString();
    }

    static void write(Path path, float[] values) throws IOException {
        ByteBuffer buffer = ByteBuffer.allocate(values.length * 4).order(ByteOrder.LITTLE_ENDIAN);
        buffer.asFloatBuffer().put(values);
        try (OutputStream stream = new FileOutputStream(path.toFile())) {
            stream.write(buffer.array());
        }
    }
}
