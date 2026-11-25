package com.newtube.mobile.localmedia;

import static org.junit.Assert.assertEquals;
import static org.junit.Assert.assertNull;

import androidx.media3.common.MimeTypes;

import org.junit.Test;

import java.nio.charset.Charset;
import java.nio.charset.StandardCharsets;

public class SubtitleFileTest {
    private static final String CUE = "1\n00:00:01,000 --> 00:00:02,000\nمرحبا بكم\n";

    @Test
    public void readsUtf8AndDropsTheByteOrderMark() {
        assertEquals(CUE, SubtitleFile.decode(("﻿" + CUE).getBytes(StandardCharsets.UTF_8)));
    }

    @Test
    public void readsArabicWindows1256() {
        assertEquals(CUE, SubtitleFile.decode(CUE.getBytes(Charset.forName("windows-1256"))));
    }

    @Test
    public void readsUtf16WithByteOrderMark() {
        assertEquals(CUE, SubtitleFile.decode(("﻿" + CUE).getBytes(StandardCharsets.UTF_16LE)));
    }

    @Test
    public void picksTheTypeFromTheExtension() {
        assertEquals(MimeTypes.APPLICATION_SUBRIP, SubtitleFile.mimeType("Movie.AR.SRT"));
        assertEquals(MimeTypes.TEXT_VTT, SubtitleFile.mimeType("a.vtt"));
        assertEquals(MimeTypes.TEXT_SSA, SubtitleFile.mimeType("a.ass"));
        assertNull(SubtitleFile.mimeType("a.txt"));
    }
}
