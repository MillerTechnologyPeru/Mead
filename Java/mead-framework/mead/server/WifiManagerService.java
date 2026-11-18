package mead.server;

import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.IBinder;
import mead.server.base.WifiManagerBase;

/**
 * Android's Wi-Fi service for Mead: Wi-Fi is off, as Mead doesn't manage the
 * host's networking, and multicast locks are accepted (the host doesn't
 * filter multicast as a phone's Wi-Fi does). Unreal Engine games take one
 * at startup.
 */
final class WifiManagerService extends WifiManagerBase {
    private int mMulticastLocks;

    @Override public int getWifiEnabledState() { return WifiManager.WIFI_STATE_DISABLED; }

    // Not connected, as Android's says with Wi-Fi off: a WifiInfo with no
    // network (an unknown SSID, network ID -1), never null.
    @Override public WifiInfo getConnectionInfo(String callingPackage) { return new WifiInfo(); }

    @Override public synchronized void acquireMulticastLock(IBinder binder, String tag) { mMulticastLocks++; }

    @Override public synchronized void releaseMulticastLock(String tag) {
        if (mMulticastLocks > 0) mMulticastLocks--;
    }

    @Override public synchronized boolean isMulticastEnabled() { return mMulticastLocks > 0; }
}
