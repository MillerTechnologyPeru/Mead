package mead.server;

import android.content.pm.PackageParser;
import java.io.File;
import java.io.FilenameFilter;
import java.io.IOException;
import java.nio.file.Files;
import java.util.zip.ZipFile;

/**
 * Asset packs a game fetches through Play (fast-follow and on-demand ones),
 * from files: each APK in an "assetpacks" folder beside the game's APK.
 * They reach the game through Play Core's own local testing, as
 * bundletool's --local-testing sets it up on a phone: the app's meta-data
 * names a folder in its external files, and Play Core delivers the
 * <pack>-*.apk files there as Play would deliver the pack (sessions,
 * extraction, verification), without the Play Store. A pack's name is its
 * split name, or the file's name for a file without a manifest.
 */
final class AssetPacks {
    /** The meta-data Play Core reads for local testing, and the folder it names. */
    static final String META_DATA = "local_testing_dir";
    static final String FOLDER = "local_testing";

    private AssetPacks() {}

    /**
     * Links the game's local packs where Play Core's local testing reads
     * them. False when the game has none, and nothing is changed.
     */
    static boolean install(String sourcePath, String packageName) {
        File[] packs = new File(new File(sourcePath).getParentFile(), "assetpacks").listFiles(new FilenameFilter() {
            @Override
            public boolean accept(File directory, String name) {
                return name.endsWith(".apk");
            }
        });
        if (packs == null || packs.length == 0) return false;
        File folder = new File(StorageManagerService.sharedStorage(), "Android/data/" + packageName + "/files/" + FOLDER);
        folder.mkdirs();
        // The links an earlier run made go first: a pack may have been taken away.
        File[] earlier = folder.listFiles();
        if (earlier != null) {
            for (File file : earlier) {
                if (Files.isSymbolicLink(file.toPath())) file.delete();
            }
        }
        for (File pack : packs) {
            String name = packName(pack);
            File link = new File(folder, name + "-master.apk");
            try {
                Files.createSymbolicLink(link.toPath(), pack.getAbsoluteFile().toPath());
                System.err.println("mead: asset pack " + name + " from " + pack);
            } catch (IOException e) {
                System.err.println("mead: asset pack " + name + " not linked: " + e);
            }
        }
        return true;
    }

    /** The pack's split name, from its manifest; or its file's name, without ".apk". */
    private static String packName(File pack) {
        if (hasManifest(pack)) {
            try {
                PackageParser.ApkLite lite = PackageParser.parseApkLite(pack, 0);
                if (lite.splitName != null) return lite.splitName;
            } catch (PackageParser.PackageParserException e) {
                System.err.println("mead: asset pack " + pack + " has a manifest that doesn't parse: " + e.getMessage());
            }
        }
        String name = pack.getName();
        return name.substring(0, name.length() - ".apk".length());
    }

    private static boolean hasManifest(File pack) {
        try (ZipFile zip = new ZipFile(pack)) {
            return zip.getEntry("AndroidManifest.xml") != null;
        } catch (IOException e) {
            return false;
        }
    }
}
