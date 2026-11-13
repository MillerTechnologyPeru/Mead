package mead.server;

import android.os.IBinder;
import android.os.PowerManager;
import android.os.PowerSaveState;
import android.os.Process;
import android.os.WorkSource;
import java.io.IOException;
import java.util.HashMap;
import java.util.Map;
import java.util.TreeSet;
import mead.host.HostPower;
import mead.server.base.PowerManagerBase;

/**
 * Android's power manager for Mead, from the host (mead.host.HostPower):
 * power saving is the host's own, and the device is interactive while its
 * screen is on.
 *
 * Wake locks hold the host awake as they hold a phone: while any is held,
 * Mead takes a logind inhibitor (systemd-inhibit). A partial wake lock
 * blocks suspend; one that keeps the screen on blocks suspend and logind's
 * idle action too. (A compositor's own screen blanking answers to the
 * window instead: FLAG_KEEP_SCREEN_ON, which Mead's windows honor.) The
 * inhibitor goes when the last lock is released, or when Mead exits.
 */
final class PowerManagerService extends PowerManagerBase {
    /** Held locks: their level and tag. */
    private final Map<IBinder, Integer> mLevels = new HashMap<>();
    private final Map<IBinder, String> mTags = new HashMap<>();
    /** What the inhibitor blocks now ("sleep", "sleep:idle"), or null; and it. */
    private String mInhibiting;
    private java.lang.Process mInhibitor;
    private boolean mNoInhibitor;

    @Override public void acquireWakeLock(IBinder lock, int flags, String tag, String packageName, WorkSource ws,
            String historyTag) {
        synchronized (this) {
            mLevels.put(lock, flags & PowerManager.WAKE_LOCK_LEVEL_MASK);
            mTags.put(lock, tag != null ? tag : "wake lock");
            inhibit();
        }
    }

    @Override public void releaseWakeLock(IBinder lock, int flags) {
        synchronized (this) {
            mLevels.remove(lock);
            mTags.remove(lock);
            inhibit();
        }
    }

    @Override public void updateWakeLockUids(IBinder lock, int[] uids) {}

    @Override public boolean isWakeLockLevelSupported(int level) {
        return level == PowerManager.PARTIAL_WAKE_LOCK || keepsScreenOn(level);
    }

    @Override public boolean isInteractive() { return HostPower.screenOn(); }
    @Override public boolean isPowerSaveMode() { return HostPower.powerSave(); }
    @Override public PowerSaveState getPowerSaveState(int serviceType) {
        boolean saving = HostPower.powerSave();
        return new PowerSaveState.Builder().setBatterySaverEnabled(saving).setGlobalBatterySaverEnabled(saving)
                .build();
    }
    @Override public boolean isDeviceIdleMode() { return false; }
    @Override public boolean isLightDeviceIdleMode() { return false; }
    @Override public boolean isScreenBrightnessBoosted() { return false; }

    /** The levels that keep the screen on; a host has no proximity sensor, doze or draw locks. */
    private static boolean keepsScreenOn(int level) {
        return level == PowerManager.SCREEN_DIM_WAKE_LOCK || level == PowerManager.SCREEN_BRIGHT_WAKE_LOCK
                || level == PowerManager.FULL_WAKE_LOCK;
    }

    /** Takes, changes or lets go of the inhibitor, for the locks held now. */
    private void inhibit() {
        String what = null;
        for (int level : mLevels.values()) {
            if (keepsScreenOn(level)) {
                what = "sleep:idle";
            } else if (level == PowerManager.PARTIAL_WAKE_LOCK && what == null) {
                what = "sleep";
            }
        }
        if (what == null ? mInhibiting == null : what.equals(mInhibiting)) return;
        if (mInhibitor != null) {
            mInhibitor.destroy();
            mInhibitor = null;
        }
        mInhibiting = what;
        if (what == null || mNoInhibitor) return;
        String why = String.join(", ", new TreeSet<>(mTags.values()));
        // The inhibitor holds while its command runs: this one ends with Mead.
        String waitForMead = "while kill -0 " + Process.myPid() + " 2>/dev/null; do sleep 5; done";
        try {
            mInhibitor = new ProcessBuilder("systemd-inhibit", "--what=" + what, "--who=Mead",
                    "--why=" + (why.isEmpty() ? "wake lock" : why), "--mode=block", "sh", "-c", waitForMead)
                    .redirectErrorStream(true).start();
        } catch (IOException e) {
            mNoInhibitor = true;
            System.err.println("mead: wake locks can't hold the host awake: " + e.getMessage());
        }
    }
}
