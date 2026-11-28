package com.newtube.mobile.downloads;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNotEquals;

import android.media.MediaExtractor;
import android.media.MediaMuxer;

import androidx.test.ext.junit.runners.AndroidJUnit4;
import androidx.test.platform.app.InstrumentationRegistry;

import org.junit.Test;
import org.junit.runner.RunWith;

import java.io.File;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;

@RunWith(AndroidJUnit4.class)
public class MediaMuxHelperTest {
    /** A progressive (itag 18) rung is one file with both tracks; it is passed as video and audio part. */
    @Test(timeout = 60000)
    public void progressiveFileKeepsItsAudio() throws Exception {
        File in = asset("musicless/muxed.mp4"), out = new File(in.getParentFile(), "muxed-out.mp4");
        MediaMuxer muxer = new MediaMuxer(out.getPath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        MediaMuxHelper.mux(in, in, muxer, (timeUs, durationUs) -> true);
        muxer.release();

        MediaExtractor extractor = new MediaExtractor();
        extractor.setDataSource(out.getPath());
        int count = extractor.getTrackCount();
        extractor.release();
        assertEquals(2, count);
    }

    /** A phone recording held upright carries a rotation tag; the saved copy must keep it. */
    @Test(timeout = 60000)
    public void keepsTheVideoRotation() throws Exception {
        File in = asset("musicless/rotated.mp4"), out = new File(in.getParentFile(), "rotated-out.mp4");
        MediaMuxer muxer = new MediaMuxer(out.getPath(), MediaMuxer.OutputFormat.MUXER_OUTPUT_MPEG_4);
        MediaMuxHelper.mux(in, in, muxer, (timeUs, durationUs) -> true);
        muxer.release();

        int rotation = rotation(in);
        assertNotEquals(0, rotation);
        assertEquals(rotation, rotation(out));
    }

    private static int rotation(File file) throws Exception {
        MediaExtractor extractor = new MediaExtractor();
        try {
            extractor.setDataSource(file.getPath());
            for (int i = 0; i < extractor.getTrackCount(); i++) {
                android.media.MediaFormat format = extractor.getTrackFormat(i);
                if (format.getString(android.media.MediaFormat.KEY_MIME).startsWith("video/")) {
                    return format.containsKey(android.media.MediaFormat.KEY_ROTATION)
                            ? format.getInteger(android.media.MediaFormat.KEY_ROTATION) : 0;
                }
            }
            return 0;
        } finally {
            extractor.release();
        }
    }

    static File asset(String name) throws Exception {
        File file = new File(InstrumentationRegistry.getInstrumentation().getTargetContext().getCacheDir(),
                name.replace('/', '-'));
        try (InputStream in = InstrumentationRegistry.getInstrumentation().getContext().getAssets().open(name);
             OutputStream out = new FileOutputStream(file)) {
            byte[] buffer = new byte[8192];
            for (int n; (n = in.read(buffer)) > 0; ) out.write(buffer, 0, n);
        }
        return file;
    }
}
