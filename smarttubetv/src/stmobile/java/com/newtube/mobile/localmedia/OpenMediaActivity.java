package com.newtube.mobile.localmedia;

import android.app.Activity;
import android.net.Uri;
import android.os.Bundle;

/** "Open with" target for video and audio files: hands the file to the player and closes. */
public final class OpenMediaActivity extends Activity {
    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Uri uri = getIntent().getData();
        if (uri != null) {
            LocalMedia.play(this, uri);
            com.newtube.mobile.ui.playback.SystemPipBridge.routeIn(this);
        }
        finish();
    }
}
