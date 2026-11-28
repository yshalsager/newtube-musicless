package com.newtube.mobile.player;

import android.content.Context;
import android.net.Uri;
import android.media.MediaCodec;
import android.media.MediaCodecInfo;
import android.media.MediaExtractor;
import android.media.MediaFormat;
import android.media.MediaMuxer;

import androidx.media3.common.C;
import androidx.media3.common.audio.AudioProcessor;

import java.io.File;
import java.io.IOException;
import java.nio.ByteBuffer;

/**
 * Removes the music from a downloaded audio part: decode -> {@link MusiclessAudioProcessor} ->
 * AAC -> an M4A that the download muxer then joins with the video, so the saved file has only
 * the voices wherever it is played.
 */
public final class MusiclessFile {
    private static final long TIMEOUT_US = 10000;

    public interface Progress {
        /** @param percent of the audio done, or -1 when the length is unknown; return false to cancel. */
        boolean onProgress(int percent);
    }

    /** Separation could not finish; the download shows its own error instead of a generic one. */
    public static final class Failure extends IOException {
        Failure(String message, Throwable cause) { super(message, cause); }
    }

    private MusiclessFile() {
    }

    /**
     * Returns early when cancelled, leaving {@code out} incomplete. Throws {@link Failure} rather
     * than writing a file that is silent or still has its music.
     */
    public static void removeMusic(Context context, Source source, File out, Progress progress) throws IOException {
        removeMusic(source, out, progress, new MusiclessAudioProcessor(context));
    }

    /** Where a {@link MediaExtractor} reads from: a downloaded part, or a file from the phone. */
    public interface Source {
        void open(MediaExtractor extractor) throws IOException;

        static Source of(File file) {
            return extractor -> extractor.setDataSource(file.getPath());
        }

        static Source of(Context context, Uri uri) {
            return extractor -> extractor.setDataSource(context, uri, null);
        }
    }

    static void removeMusic(Source input, File out, Progress progress, MusiclessAudioProcessor processor)
            throws IOException {
        MediaExtractor extractor = new MediaExtractor();
        MediaCodec decoder = null, encoder = null;
        MediaMuxer muxer = null;
        boolean muxing = false;
        try {
            input.open(extractor);
            MediaFormat source = selectAudio(extractor);
            long durationUs = source.containsKey(MediaFormat.KEY_DURATION) ? source.getLong(MediaFormat.KEY_DURATION) : 0;
            decoder = MediaCodec.createDecoderByType(source.getString(MediaFormat.KEY_MIME));
            decoder.configure(source, null, null, 0);
            decoder.start();
            configure(processor, source);

            MediaFormat aac = MediaFormat.createAudioFormat(MediaFormat.MIMETYPE_AUDIO_AAC, MusiclessDsp.RATE, 2);
            aac.setInteger(MediaFormat.KEY_AAC_PROFILE, MediaCodecInfo.CodecProfileLevel.AACObjectLC);
            aac.setInteger(MediaFormat.KEY_BIT_RATE, 128000);
            encoder = MediaCodec.createEncoderByType(MediaFormat.MIMETYPE_AUDIO_AAC);
            encoder.configure(aac, null, null, MediaCodec.CONFIGURE_FLAG_ENCODE);
            encoder.start();
            muxer = new MediaMuxer(out.getPath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);

            MediaCodec.BufferInfo info = new MediaCodec.BufferInfo();
            ByteBuffer pcm = null, voices = AudioProcessor.EMPTY_BUFFER;
            int pcmIndex = -1, track = -1;
            boolean extracted = false, decoded = false, processorEos = false, encoderEos = false, done = false;
            long encodedFrames = 0;
            while (!done) {
                long doneUs = encodedFrames * 1000000L / MusiclessDsp.RATE;
                if (!progress.onProgress(durationUs > 0 ? (int) Math.min(99, doneUs * 100 / durationUs) : -1)) return;
                if (processor.hasFailed()) throw new Failure("separation failed", null);
                // One model thread serves everything. While a video is open, new audio goes in only
                // when that thread is idle, so a playback window waits for at most one of ours.
                MusiclessModelHolder holder = MusiclessModelHolder.get();
                boolean yieldToPlayer = holder.userCount() > 1 && holder.executor.getActiveCount() > 0;
                boolean moved = false;

                if (!extracted) {
                    int in = decoder.dequeueInputBuffer(0);
                    if (in >= 0) {
                        int size = extractor.readSampleData(decoder.getInputBuffer(in), 0);
                        if (size < 0) {
                            decoder.queueInputBuffer(in, 0, 0, 0, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            extracted = true;
                        } else {
                            decoder.queueInputBuffer(in, 0, size, extractor.getSampleTime(), 0);
                            extractor.advance();
                        }
                        moved = true;
                    }
                }

                if (pcm == null && !decoded) {
                    int index = decoder.dequeueOutputBuffer(info, 0);
                    if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                        // Nothing was queued yet, so reconfiguring loses no audio.
                        configure(processor, decoder.getOutputFormat());
                        moved = true;
                    } else if (index >= 0) {
                        if ((info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0) decoded = true;
                        pcm = decoder.getOutputBuffer(index);
                        pcm.position(info.offset).limit(info.offset + info.size);
                        pcmIndex = index;
                        moved = true;
                    }
                }
                if (pcm != null && !yieldToPlayer) {
                    int before = pcm.remaining();
                    if (before > 0) processor.queueInput(pcm);
                    if (!pcm.hasRemaining()) {
                        decoder.releaseOutputBuffer(pcmIndex, false);
                        pcm = null;
                    }
                    moved |= pcm == null || pcm.remaining() != before;
                }
                if (decoded && pcm == null && !processorEos) {
                    processor.queueEndOfStream();
                    processorEos = true;
                }

                if (!voices.hasRemaining()) voices = processor.getOutput();
                if (!encoderEos && (voices.hasRemaining() || processorEos && processor.isEnded())) {
                    int in = encoder.dequeueInputBuffer(0);
                    if (in >= 0) {
                        if (voices.hasRemaining()) {
                            ByteBuffer target = encoder.getInputBuffer(in);
                            int size = Math.min(target.remaining(), voices.remaining()) & ~3;
                            ByteBuffer slice = voices.duplicate();
                            slice.limit(slice.position() + size);
                            target.put(slice);
                            voices.position(voices.position() + size);
                            encodedFrames += size / 4;
                            encoder.queueInputBuffer(in, 0, size, doneUs, 0);
                        } else {
                            encoder.queueInputBuffer(in, 0, 0, doneUs, MediaCodec.BUFFER_FLAG_END_OF_STREAM);
                            encoderEos = true;
                        }
                        moved = true;
                    }
                }

                int index = encoder.dequeueOutputBuffer(info, moved ? 0 : TIMEOUT_US);
                if (index == MediaCodec.INFO_OUTPUT_FORMAT_CHANGED) {
                    track = muxer.addTrack(encoder.getOutputFormat());
                    muxer.start();
                    muxing = true;
                } else if (index >= 0) {
                    if ((info.flags & MediaCodec.BUFFER_FLAG_CODEC_CONFIG) == 0 && info.size > 0) {
                        muxer.writeSampleData(track, encoder.getOutputBuffer(index), info);
                    }
                    done = (info.flags & MediaCodec.BUFFER_FLAG_END_OF_STREAM) != 0;
                    encoder.releaseOutputBuffer(index, false);
                }
            }
            muxer.stop();
            muxing = false;
        } catch (IOException | RuntimeException | AudioProcessor.UnhandledAudioFormatException e) {
            throw e instanceof Failure ? (Failure) e : new Failure("music removal failed", e);
        } finally {
            processor.reset();
            release(decoder);
            release(encoder);
            if (muxer != null) {
                try {
                    if (muxing) muxer.stop();
                } catch (RuntimeException ignored) {
                }
                try {
                    muxer.release();
                } catch (RuntimeException ignored) { // Android 7 re-runs the failed stop() in release()
                }
            }
            extractor.release();
        }
    }

    private static void configure(MusiclessAudioProcessor processor, MediaFormat format)
            throws AudioProcessor.UnhandledAudioFormatException {
        int encoding = format.containsKey(MediaFormat.KEY_PCM_ENCODING)
                ? format.getInteger(MediaFormat.KEY_PCM_ENCODING) : C.ENCODING_PCM_16BIT;
        processor.configure(new AudioProcessor.AudioFormat(format.getInteger(MediaFormat.KEY_SAMPLE_RATE),
                format.getInteger(MediaFormat.KEY_CHANNEL_COUNT), encoding));
        processor.flush();
    }

    private static MediaFormat selectAudio(MediaExtractor extractor) throws IOException {
        for (int i = 0; i < extractor.getTrackCount(); i++) {
            MediaFormat format = extractor.getTrackFormat(i);
            String mime = format.getString(MediaFormat.KEY_MIME);
            if (mime != null && mime.startsWith("audio/")) {
                extractor.selectTrack(i);
                return format;
            }
        }
        throw new IOException("no audio track");
    }

    private static void release(MediaCodec codec) {
        if (codec == null) return;
        try {
            codec.stop();
        } catch (RuntimeException ignored) {
        }
        codec.release();
    }
}
