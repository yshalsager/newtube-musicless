package com.liskovsoft.smartyoutubetv2.common.misc;

import static org.junit.Assert.assertEquals;

import android.app.Application;
import android.content.Context;

import org.robolectric.RuntimeEnvironment;

import org.junit.Test;
import org.junit.runner.RunWith;
import org.robolectric.RobolectricTestRunner;
import org.robolectric.annotation.Config;
import org.robolectric.annotation.ConscryptMode;

@RunWith(RobolectricTestRunner.class)
@Config(sdk = 28, manifest = Config.NONE, application = Application.class)
@ConscryptMode(ConscryptMode.Mode.OFF)
public class LocalPositionsTest {
    private final Context context = RuntimeEnvironment.getApplication();

    @Test
    public void eachFileKeepsItsOwnPosition() {
        LocalPositions.save(context, "content://a", 1000);
        LocalPositions.save(context, "content://b", 2000);

        assertEquals(1000, LocalPositions.get(context, "content://a"));
        assertEquals(2000, LocalPositions.get(context, "content://b"));
        assertEquals(0, LocalPositions.get(context, "content://c"));
    }

    @Test
    public void watchedToTheEndStartsOver() {
        LocalPositions.save(context, "content://a", 1000);
        LocalPositions.save(context, "content://a", 0);

        assertEquals(0, LocalPositions.get(context, "content://a"));
    }

    @Test
    public void dropsTheOldestFileWhenFull() {
        android.content.SharedPreferences.Editor editor =
                context.getSharedPreferences(LocalPositions.PREFS, Context.MODE_PRIVATE).edit();
        for (int i = 0; i < LocalPositions.MAX; i++) {
            editor.putString("content://" + i, (100 + i) + ":5");
        }
        editor.commit();

        LocalPositions.save(context, "content://new", 7);

        assertEquals(0, LocalPositions.get(context, "content://0"));
        assertEquals(5, LocalPositions.get(context, "content://1"));
        assertEquals(7, LocalPositions.get(context, "content://new"));
    }
}
