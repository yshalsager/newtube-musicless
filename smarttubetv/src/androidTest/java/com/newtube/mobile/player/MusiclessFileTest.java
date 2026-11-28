package com.newtube.mobile.player;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertTrue;
import static org.junit.Assert.fail;

import android.content.Context;
import android.media.MediaExtractor;
import android.media.MediaFormat;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.concurrent.Executors;
import java.util.concurrent.atomic.AtomicInteger;

/** Runs the real decoder/encoder loop on 3 s fixtures: a fragmented-MP4 tone (a YouTube audio part) and a muxed MP4. */
@RunWith(AndroidJUnit4.class)
public class MusiclessFileTest {
    private static final long TONE_US = 3_000_000;

    @Test(timeout = 60000)
    public void writesWholeTrackThroughTheModel() throws Exception {
        assertVoicesTrack(fixture("musicless/tone.m4a"));
    }

    /** A progressive (single-file) download: the audio comes from the file that also holds the video. */
    @Test(timeout = 60000)
    public void readsTheAudioOfAMuxedFile() throws Exception {
        assertVoicesTrack(fixture("musicless/muxed.mp4"));
    }

    private static void assertVoicesTrack(File in) throws Exception {
        File out = new File(in.getParentFile(), "voices.m4a");
        AtomicInteger lastPercent = new AtomicInteger(-1);
        MusiclessFile.removeMusic(MusiclessFile.Source.of(in), out, percent -> { lastPercent.set(percent); return true; },
                new MusiclessAudioProcessor(new MusiclessAudioProcessor.Worker() {
                    @Override float[] infer(float[] block) { return block.clone(); }
                }, Executors.newSingleThreadExecutor()));

        MediaExtractor extractor = new MediaExtractor();
        extractor.setDataSource(out.getPath());
        assertEquals(1, extractor.getTrackCount());
        MediaFormat format = extractor.getTrackFormat(0);
        extractor.release();
        assertEquals(MediaFormat.MIMETYPE_AUDIO_AAC, format.getString(MediaFormat.KEY_MIME));
        assertEquals(44100, format.getInteger(MediaFormat.KEY_SAMPLE_RATE));
        assertEquals(2, format.getInteger(MediaFormat.KEY_CHANNEL_COUNT));
        long durationUs = format.getLong(MediaFormat.KEY_DURATION);
        assertTrue("duration " + durationUs, Math.abs(durationUs - TONE_US) < 100_000);
        assertTrue("progress " + lastPercent.get(), lastPercent.get() > 50);
    }

    @Test(timeout = 60000)
    public void failedSeparationIsAFailureNotASilentFile() throws Exception {
        File in = fixture("musicless/tone.m4a"), out = new File(in.getParentFile(), "voices.m4a");
        try {
            MusiclessFile.removeMusic(MusiclessFile.Source.of(in), out, percent -> true,
                    new MusiclessAudioProcessor(new MusiclessAudioProcessor.Worker() {
                        @Override float[] infer(float[] block) { throw new IllegalStateException("model broke"); }
                    }, Executors.newSingleThreadExecutor()));
            fail("expected Failure");
        } catch (MusiclessFile.Failure expected) {
            // The download shows "Couldn't remove the music" and keeps its parts for a retry.
        }
    }

    private static File fixture(String name) throws Exception {
        Context target = InstrumentationRegistry.getInstrumentation().getTargetContext();
        File file = new File(target.getCacheDir(), name.replace('/', '-'));
        try (InputStream in = InstrumentationRegistry.getInstrumentation().getContext().getAssets()
                .open(name); OutputStream out = new FileOutputStream(file)) {
            byte[] buffer = new byte[8192];
            for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
        }
        return file;
    }
}
