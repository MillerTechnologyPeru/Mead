package mead.server;

import mead.server.base.DeviceIdleControllerBase;

/**
 * Android's device idle (Doze) controller for Mead. Mead never dozes
 * (PowerManagerService.isDeviceIdleMode is false), so no app's work is
 * held back for battery: every app is as good as on the power save
 * whitelist, and PowerManager.isIgnoringBatteryOptimizations says so.
 * The whitelist itself is the system's to change.
 */
final class DeviceIdleControllerService extends DeviceIdleControllerBase {
    @Override public boolean isPowerSaveWhitelistApp(String packageName) { return true; }
    @Override public boolean isPowerSaveWhitelistExceptIdleApp(String packageName) { return true; }

    @Override public String[] getFullPowerWhitelist() { return currentApp(); }
    @Override public String[] getFullPowerWhitelistExceptIdle() { return currentApp(); }
    @Override public String[] getUserPowerWhitelist() { return new String[0]; }
    @Override public String[] getSystemPowerWhitelist() { return new String[0]; }
    @Override public String[] getSystemPowerWhitelistExceptIdle() { return new String[0]; }
    @Override public String[] getRemovedSystemPowerWhitelistApps() { return new String[0]; }

    private static String[] currentApp() {
        MeadApp app = MeadApp.sCurrent;
        return app != null ? new String[] {app.packageName} : new String[0];
    }
}
