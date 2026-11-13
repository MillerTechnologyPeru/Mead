package mead.server;

import android.os.IBinder;
import android.os.PowerSaveState;
import android.os.WorkSource;
import mead.server.base.PowerManagerBase;

/**
 * Android's power manager for Mead: the screen is on, there's no power
 * saving or idling, and wake locks are accepted (the windowing system keeps
 * the screen on as it does).
 */
final class PowerManagerService extends PowerManagerBase {
    @Override public void acquireWakeLock(IBinder lock, int flags, String tag, String packageName, WorkSource ws,
            String historyTag) {}
    @Override public void releaseWakeLock(IBinder lock, int flags) {}
    @Override public void updateWakeLockUids(IBinder lock, int[] uids) {}
    @Override public boolean isInteractive() { return true; }
    @Override public boolean isPowerSaveMode() { return false; }
    @Override public PowerSaveState getPowerSaveState(int serviceType) {
        return new PowerSaveState.Builder().setBatterySaverEnabled(false).setGlobalBatterySaverEnabled(false).build();
    }
    @Override public boolean isDeviceIdleMode() { return false; }
    @Override public boolean isLightDeviceIdleMode() { return false; }
    @Override public boolean isScreenBrightnessBoosted() { return false; }
}
