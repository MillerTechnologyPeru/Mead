package mead.server;

import android.os.Environment;
import android.os.UserHandle;
import android.os.storage.StorageVolume;
import java.io.File;
import mead.server.base.StorageManagerBase;

/**
 * Android's storage manager for Mead: one shared storage volume, emulated,
 * in ~/.mead/storage (Android's /storage/emulated/0), always mounted, and
 * the user's files unlocked.
 */
final class StorageManagerService extends StorageManagerBase {
    static File sharedStorage() {
        String home = System.getenv("HOME");
        File storage = new File((home != null ? home : "/tmp") + "/.mead/storage");
        storage.mkdirs();
        return storage;
    }

    @Override
    public StorageVolume[] getVolumeList(int uid, String packageName, int flags) {
        File path = sharedStorage();
        return new StorageVolume[] {new StorageVolume("emulated", path, path, "Internal shared storage", true, false,
                true, false, 0, UserHandle.SYSTEM, null, Environment.MEDIA_MOUNTED)};
    }

    @Override
    public void mkdirs(String callingPkg, String path) {
        new File(path).mkdirs();
    }

    @Override public String getPrimaryStorageUuid() { return null; }
    @Override public boolean isUserKeyUnlocked(int userId) { return true; }
    @Override public long getCacheQuotaBytes(String volumeUuid, int uid) { return 64L * 1024 * 1024; }
    @Override public long getCacheSizeBytes(String volumeUuid, int uid) { return 0; }
    @Override public long getAllocatableBytes(String volumeUuid, int flags, String callingPackage) {
        return sharedStorage().getUsableSpace();
    }
}
