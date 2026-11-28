package com.newtube.mobile.downloads;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertFalse;
import static org.junit.Assert.assertNull;
import static org.junit.Assert.assertTrue;

import android.app.Application;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.RuntimeEnvironment;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.ConscryptMode;

/** "Save without music" entries: the JSON round trip and the lookup behind the Save button. */
@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE, application = Application.class)
@ConscryptMode(ConscryptMode.Mode.OFF)
public class DownloadItemPhoneTest {
    @Test
    public void phoneEntryKeepsItsSourceThroughJson() throws Exception {
        DownloadItem item = DownloadItem.fromPhone("content://media/external/audio/media/7", "Lecture", true);

        DownloadItem back = DownloadItem.fromJson(item.toJson());

        assertTrue(back.isFromPhone());
        assertEquals("content://media/external/audio/media/7", back.sourceUri);
        assertTrue(back.isAudioOnly());
        assertTrue(back.videoId.startsWith("local:"));
    }

    /** The button on a phone file shows a running save over an older finished copy. */
    @Test
    public void runningSaveWinsOverAFinishedCopy() {
        DownloadRegistry registry = DownloadRegistry.instance(RuntimeEnvironment.getApplication());
        String source = "content://media/external/video/media/41";
        DownloadItem old = DownloadItem.fromPhone(source, "Talk", false);
        old.state = DownloadItem.STATE_DONE;
        old.outputUri = "content://media/external/video/media/42";
        registry.add(old);

        assertEquals(old, registry.findForPhoneFile(source));
        assertEquals(old, registry.findForPhoneFile(old.outputUri));

        DownloadItem again = DownloadItem.fromPhone(source, "Talk", false);
        again.state = DownloadItem.STATE_PROCESSING;
        registry.add(again);

        assertEquals(again, registry.findForPhoneFile(source));
        assertNull(registry.findForPhoneFile("content://media/external/video/media/43"));
    }

    @Test
    public void youTubeEntryIsNotAPhoneFile() throws Exception {
        DownloadItem item = new DownloadItem("id", "dQw4w9WgXcQ", "t", null, null,
                DownloadOption.KIND_VIDEO, null, "137", "140", 0);

        DownloadItem back = DownloadItem.fromJson(item.toJson());

        assertFalse(back.isFromPhone());
        assertNull(back.sourceUri);
    }
}
