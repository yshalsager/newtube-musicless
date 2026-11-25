package com.newtube.mobile.localmedia;

import android.content.Context;
import android.content.Intent;
import android.net.Uri;

import androidx.annotation.Nullable;
import androidx.media3.common.MimeTypes;

import java.io.ByteArrayOutputStream;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.nio.ByteBuffer;
import java.nio.charset.CharacterCodingException;
import java.nio.charset.Charset;
import java.nio.charset.CodingErrorAction;
import java.nio.charset.StandardCharsets;
import java.util.Locale;

/** A subtitle file picked for a video played from the phone or a download. */
public final class SubtitleFile {
    private static final int MAX_BYTES = 10 * 1024 * 1024;

    private SubtitleFile() {
    }

    /** Any file: phones label .srt as text/plain, application/x-subrip or application/octet-stream. */
    public static Intent pickIntent() {
        return new Intent(Intent.ACTION_OPEN_DOCUMENT)
                .addCategory(Intent.CATEGORY_OPENABLE)
                .setType("*/*");
    }

    /** @return the media3 MIME type for the file name's extension, or null when unsupported */
    @Nullable
    public static String mimeType(String name) {
        String lower = name.toLowerCase(Locale.ROOT);
        if (lower.endsWith(".srt")) return MimeTypes.APPLICATION_SUBRIP;
        if (lower.endsWith(".vtt")) return MimeTypes.TEXT_VTT;
        if (lower.endsWith(".ass") || lower.endsWith(".ssa")) return MimeTypes.TEXT_SSA;
        if (lower.endsWith(".ttml") || lower.endsWith(".dfxp")) return MimeTypes.APPLICATION_TTML;
        return null;
    }

    /**
     * Copies the file into the app's cache as UTF-8 (the player reads subtitles as UTF-8) and
     * returns the copy. It replaces the previous copy: one subtitle file is loaded at a time.
     */
    public static File copyAsUtf8(Context context, Uri uri, String name) throws IOException {
        byte[] bytes;
        try (InputStream in = context.getContentResolver().openInputStream(uri)) {
            if (in == null) throw new IOException("can't open " + uri);
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[16384];
            for (int read; (read = in.read(buffer)) != -1; ) {
                out.write(buffer, 0, read);
                if (out.size() > MAX_BYTES) throw new IOException("subtitle file too big");
            }
            bytes = out.toByteArray();
        }
        File dir = new File(context.getCacheDir(), "subtitles");
        if (!dir.isDirectory() && !dir.mkdirs()) throw new IOException("can't create " + dir);
        File copy = new File(dir, System.currentTimeMillis() + "-" + name.replaceAll("[^\\w.-]", "_"));
        try (OutputStream out = new FileOutputStream(copy)) {
            out.write(decode(bytes).getBytes(StandardCharsets.UTF_8));
        }
        // Only now: until the new copy is written, the playing source may still need the old one.
        File[] old = dir.listFiles();
        if (old != null) for (File file : old) if (!file.equals(copy)) file.delete();
        return copy;
    }

    /**
     * UTF-8 or UTF-16 (with a byte order mark) as is. Anything else is read as Windows-1256.
     * shortcut: guesses Arabic for every non-UTF-8 file; add a charset choice if users of other
     * languages report broken letters.
     */
    static String decode(byte[] bytes) {
        if (bytes.length >= 2 && (bytes[0] & 0xff) == 0xfe && (bytes[1] & 0xff) == 0xff) {
            return new String(bytes, 2, bytes.length - 2, StandardCharsets.UTF_16BE);
        }
        if (bytes.length >= 2 && (bytes[0] & 0xff) == 0xff && (bytes[1] & 0xff) == 0xfe) {
            return new String(bytes, 2, bytes.length - 2, StandardCharsets.UTF_16LE);
        }
        try {
            String text = StandardCharsets.UTF_8.newDecoder()
                    .onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT)
                    .decode(ByteBuffer.wrap(bytes)).toString();
            return text.startsWith("﻿") ? text.substring(1) : text;
        } catch (CharacterCodingException e) {
            return new String(bytes, Charset.forName("windows-1256"));
        }
    }
}
