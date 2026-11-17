package mead.server;

import android.app.IUiModeManager;
import android.app.UiModeManager;
import android.content.res.Configuration;

/**
 * Android's UI mode manager for Mead: the app runs in the normal UI mode
 * with night mode off, as its configuration says (MeadApp), and neither
 * changes: car mode and night mode are the system's to set.
 */
final class UiModeManagerService extends IUiModeManager.Stub {
    @Override public void enableCarMode(int flags) { MeadServices.unimplemented("IUiModeManager.enableCarMode"); }
    @Override public void disableCarMode(int flags) {}
    @Override public int getCurrentModeType() { return Configuration.UI_MODE_TYPE_NORMAL; }
    @Override public void setNightMode(int mode) { MeadServices.unimplemented("IUiModeManager.setNightMode"); }
    @Override public int getNightMode() { return UiModeManager.MODE_NIGHT_NO; }
    @Override public boolean isUiModeLocked() { return true; }
    @Override public boolean isNightModeLocked() { return true; }
}
