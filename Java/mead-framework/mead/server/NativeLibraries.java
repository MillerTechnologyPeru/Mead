package mead.server;

import android.os.Build;
import java.io.File;
import java.io.FileOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.io.OutputStream;
import java.util.ArrayList;
import java.util.Enumeration;
import java.util.List;
import java.util.zip.ZipEntry;
import java.util.zip.ZipFile;

/**
 * An APK's native libraries, installed as Android's package manager installs
 * them: lib/<abi>/*.so from the APK and its splits, for the first of the
 * host's ABIs (Build.SUPPORTED_ABIS) any of them has, copied into the app's
 * library directory, where its class loader looks. A library already there
 * is copied again only when its size differs or its APK is newer.
 */
final class NativeLibraries {
    private NativeLibraries() {}

    static void install(List<String> apks, File directory) {
        String abi = abi(apks);
        if (abi == null) return;
        String prefix = "lib/" + abi + "/";
        directory.mkdirs();
        for (String apk : apks) {
            long modified = new File(apk).lastModified();
            try (ZipFile zip = new ZipFile(apk)) {
                Enumeration<? extends ZipEntry> entries = zip.entries();
                while (entries.hasMoreElements()) {
                    ZipEntry entry = entries.nextElement();
                    String name = entry.getName();
                    if (entry.isDirectory() || !name.startsWith(prefix) || !name.endsWith(".so")) continue;
                    String file = name.substring(prefix.length());
                    if (file.contains("/")) continue;
                    File library = new File(directory, file);
                    if (library.length() == entry.getSize() && library.lastModified() >= modified) continue;
                    copy(zip, entry, library);
                }
            } catch (IOException e) {
                System.err.println("mead: native libraries of " + apk + " not installed: " + e);
            }
        }
    }

    /** The first of the host's ABIs that one of the APKs has libraries for. */
    private static String abi(List<String> apks) {
        List<String> present = new ArrayList<>();
        for (String apk : apks) {
            try (ZipFile zip = new ZipFile(apk)) {
                Enumeration<? extends ZipEntry> entries = zip.entries();
                while (entries.hasMoreElements()) {
                    String name = entries.nextElement().getName();
                    if (!name.startsWith("lib/") || !name.endsWith(".so")) continue;
                    int slash = name.indexOf('/', 4);
                    if (slash > 4) present.add(name.substring(4, slash));
                }
            } catch (IOException e) {
                // Not readable: no libraries from it.
            }
        }
        for (String abi : Build.SUPPORTED_ABIS) {
            if (present.contains(abi)) return abi;
        }
        return null;
    }

    /** Written beside it and renamed, so a run cut short leaves no half library. */
    private static void copy(ZipFile zip, ZipEntry entry, File library) throws IOException {
        File partial = new File(library.getPath() + ".part");
        try (InputStream in = zip.getInputStream(entry); OutputStream out = new FileOutputStream(partial)) {
            byte[] buffer = new byte[1 << 16];
            for (int count; (count = in.read(buffer)) > 0; ) out.write(buffer, 0, count);
        }
        if (!partial.renameTo(library)) throw new IOException("can't rename " + partial);
    }
}
