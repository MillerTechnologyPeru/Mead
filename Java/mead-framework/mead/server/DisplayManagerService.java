package mead.server;

import android.content.pm.ParceledListSlice;
import android.graphics.Point;
import android.hardware.display.BrightnessConfiguration;
import android.hardware.display.Curve;
import android.hardware.display.IDisplayManager;
import android.hardware.display.IDisplayManagerCallback;
import android.hardware.display.IVirtualDisplayCallback;
import android.hardware.display.WifiDisplayStatus;
import android.media.projection.IMediaProjection;
import android.os.RemoteException;
import android.view.Display;
import android.view.DisplayInfo;
import android.view.Surface;
import java.util.ArrayList;
import java.util.List;

/**
 * Android's display manager for Mead: one display, the one Mead's display
 * bridge describes (its size, density and refresh rate, from the windowing
 * system), without virtual or Wi-Fi displays or brightness control.
 */
final class DisplayManagerService extends IDisplayManager.Stub {
    private final List<IDisplayManagerCallback> mCallbacks = new ArrayList<>();

    /** The display: width, height, xdpi, ydpi, refresh rate and density (1 at 160 dpi). */
    private static native float[] nativeGetDisplay();

    @Override
    public DisplayInfo getDisplayInfo(int displayId) {
        if (displayId != Display.DEFAULT_DISPLAY) return null;
        float[] display = nativeGetDisplay();
        int width = (int) display[0], height = (int) display[1];
        float refreshRate = display[4];
        DisplayInfo info = new DisplayInfo();
        info.layerStack = 0;
        info.flags = Display.FLAG_SECURE | Display.FLAG_SUPPORTS_PROTECTED_BUFFERS;
        info.type = Display.TYPE_BUILT_IN;
        info.name = "Built-in Screen";
        info.uniqueId = "local:0";
        info.appWidth = info.logicalWidth = width;
        info.appHeight = info.logicalHeight = height;
        info.smallestNominalAppWidth = info.smallestNominalAppHeight = Math.min(width, height);
        info.largestNominalAppWidth = info.largestNominalAppHeight = Math.max(width, height);
        info.rotation = Surface.ROTATION_0;
        info.modeId = info.defaultModeId = 1;
        info.supportedModes = new Display.Mode[] {new Display.Mode(1, width, height, refreshRate)};
        info.colorMode = Display.COLOR_MODE_DEFAULT;
        info.supportedColorModes = new int[] {Display.COLOR_MODE_DEFAULT};
        info.logicalDensityDpi = Math.round(display[5] * 160);
        info.physicalXDpi = display[2];
        info.physicalYDpi = display[3];
        info.appVsyncOffsetNanos = 0;
        info.presentationDeadlineNanos = (long) (1_000_000_000L / refreshRate);
        info.state = Display.STATE_ON;
        info.ownerUid = 0;
        info.ownerPackageName = null;
        return info;
    }

    @Override
    public int[] getDisplayIds() {
        return new int[] {Display.DEFAULT_DISPLAY};
    }

    @Override
    public boolean isUidPresentOnDisplay(int uid, int displayId) {
        return displayId == Display.DEFAULT_DISPLAY;
    }

    @Override
    public void registerCallback(IDisplayManagerCallback callback) {
        synchronized (mCallbacks) {
            mCallbacks.add(callback);
        }
    }

    @Override
    public Point getStableDisplaySize() {
        float[] display = nativeGetDisplay();
        return new Point((int) display[0], (int) display[1]);
    }

    @Override
    public int getPreferredWideGamutColorSpaceId() {
        // No wide color: sRGB.
        return 0;
    }

    @Override
    public void requestColorMode(int displayId, int colorMode) {}

    // No Wi-Fi displays.

    @Override public void startWifiDisplayScan() {}
    @Override public void stopWifiDisplayScan() {}
    @Override public void connectWifiDisplay(String address) {}
    @Override public void disconnectWifiDisplay() {}
    @Override public void renameWifiDisplay(String address, String alias) {}
    @Override public void forgetWifiDisplay(String address) {}
    @Override public void pauseWifiDisplay() {}
    @Override public void resumeWifiDisplay() {}

    @Override
    public WifiDisplayStatus getWifiDisplayStatus() {
        return new WifiDisplayStatus();
    }

    // No virtual displays yet.

    @Override
    public int createVirtualDisplay(IVirtualDisplayCallback callback, IMediaProjection projectionToken,
            String packageName, String name, int width, int height, int densityDpi, Surface surface,
            int flags, String uniqueId) {
        return -1;
    }

    @Override public void resizeVirtualDisplay(IVirtualDisplayCallback token, int width, int height, int densityDpi) {}
    @Override public void setVirtualDisplaySurface(IVirtualDisplayCallback token, Surface surface) {}
    @Override public void releaseVirtualDisplay(IVirtualDisplayCallback token) {}
    @Override public void setVirtualDisplayState(IVirtualDisplayCallback token, boolean isOn) {}

    // No brightness control: the windowing system's.

    @Override public ParceledListSlice getBrightnessEvents(String callingPackage) { return ParceledListSlice.emptyList(); }
    @Override public ParceledListSlice getAmbientBrightnessStats() { return ParceledListSlice.emptyList(); }
    @Override public void setBrightnessConfigurationForUser(BrightnessConfiguration c, int userId, String packageName) {}
    @Override public BrightnessConfiguration getBrightnessConfigurationForUser(int userId) { return null; }
    @Override public BrightnessConfiguration getDefaultBrightnessConfiguration() { return null; }
    @Override public void setTemporaryBrightness(int brightness) {}
    @Override public void setTemporaryAutoBrightnessAdjustment(float adjustment) {}
    @Override public Curve getMinimumBrightnessCurve() { return null; }
}
