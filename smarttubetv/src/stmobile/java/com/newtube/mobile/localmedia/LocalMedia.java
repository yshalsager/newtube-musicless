package com.newtube.mobile.localmedia;

import android.content.Context;
import android.content.Intent;
import android.database.Cursor;
import android.net.Uri;
import android.provider.OpenableColumns;
import android.util.Log;

import com.liskovsoft.smartyoutubetv2.common.app.models.data.Video;
import com.liskovsoft.smartyoutubetv2.common.app.presenters.PlaybackPresenter;

/**
 * Plays a video or audio file from the phone ("Open with" from another app, or the You panel's
 * "Open a file"). It goes through the downloads' local path, so music removal applies to it too.
 */
public final class LocalMedia {
    private static final String TAG = "LocalMedia";
    public static final String[] MIME_TYPES = {"video/*", "audio/*"};

    private LocalMedia() {
    }

    /** The system file picker for video and audio; its result goes to {@link #play}. */
    public static Intent pickIntent() {
        return new Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*")
                .putExtra(Intent.EXTRA_MIME_TYPES, MIME_TYPES);
    }

    /**
     * The file's read grant is tied to the screen that received it, but
     * the player is another screen that opens and seeks the file later: keep the access for the app.
     */
    public static void play(Context context, Uri uri) {
        keepReadAccess(context, uri);
        Video video = new Video();
        video.title = displayName(context, uri);
        video.localUri = uri.toString();
        PlaybackPresenter.instance(context).openVideo(video);
    }

    private static void keepReadAccess(Context context, Uri uri) {
        try {
            // Not tied to a screen: lasts until the phone restarts. Nothing reopens a file later.
            context.grantUriPermission(context.getPackageName(), uri, Intent.FLAG_GRANT_READ_URI_PERMISSION);
        } catch (SecurityException e) {
            Log.w(TAG, "can't keep access to " + uri + ": " + e); // still plays while the grant lasts
        }
    }

    public static String displayName(Context context, Uri uri) {
        try (Cursor cursor = context.getContentResolver().query(uri,
                new String[] {OpenableColumns.DISPLAY_NAME}, null, null, null)) {
            if (cursor != null && cursor.moveToFirst() && !cursor.isNull(0)) {
                return cursor.getString(0);
            }
        } catch (RuntimeException e) {
            Log.w(TAG, "no name for " + uri + ": " + e);
        }
        String last = uri.getLastPathSegment();
        return last != null ? last : uri.toString();
    }
}
