package com.liskovsoft.smartyoutubetv2.common.misc;

import android.content.Context;
import android.content.SharedPreferences;

import java.util.Map;

/**
 * NEWTUBE(local-media): resume points for files opened from the phone. They have no YouTube id,
 * so the history in VideoStateService (keyed by videoId) can't tell them apart.
 */
public final class LocalPositions {
    static final String PREFS = "local_positions";
    static final int MAX = 100;

    private LocalPositions() {
    }

    /** @return the saved position, or 0 to start from the beginning */
    public static long get(Context context, String uri) {
        String value = prefs(context).getString(uri, null);
        return value != null ? Long.parseLong(value.substring(value.indexOf(':') + 1)) : 0;
    }

    /** {@code positionMs <= 0} (watched to the end) forgets the file. Keeps the last {@link #MAX} files. */
    public static void save(Context context, String uri, long positionMs) {
        SharedPreferences prefs = prefs(context);
        SharedPreferences.Editor editor = prefs.edit();
        if (positionMs <= 0) {
            editor.remove(uri).apply();
            return;
        }
        Map<String, ?> all = prefs.getAll();
        if (!all.containsKey(uri) && all.size() >= MAX) {
            String oldest = null;
            long oldestTime = Long.MAX_VALUE;
            for (Map.Entry<String, ?> entry : all.entrySet()) {
                long time = savedAt(entry.getValue());
                if (time < oldestTime) {
                    oldestTime = time;
                    oldest = entry.getKey();
                }
            }
            editor.remove(oldest);
        }
        editor.putString(uri, System.currentTimeMillis() + ":" + positionMs).apply();
    }

    private static long savedAt(Object value) {
        String text = String.valueOf(value);
        return Long.parseLong(text.substring(0, text.indexOf(':')));
    }

    private static SharedPreferences prefs(Context context) {
        return context.getSharedPreferences(PREFS, Context.MODE_PRIVATE);
    }
}
