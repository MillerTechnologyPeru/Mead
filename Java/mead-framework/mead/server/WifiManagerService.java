package mead.server;

import android.Manifest;
import android.net.wifi.SupplicantState;
import android.net.wifi.WifiConfiguration;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.net.wifi.WifiSsid;
import android.os.Build;
import android.os.IBinder;
import android.util.Log;
import java.io.IOException;
import java.net.Inet4Address;
import java.net.InetAddress;
import java.net.NetworkInterface;
import java.net.SocketException;
import java.util.Collections;
import mead.server.base.WifiManagerBase;

/**
 * Android's Wi-Fi service for Mead: the host's Wi-Fi, as the host's network
 * manager keeps it. Mead doesn't manage the host's networking, so Wi-Fi is
 * on while the host has a wireless interface up, and its connection is
 * that interface's (the default route's, when that's wireless), read from
 * the kernel (Nl80211). Multicast locks are accepted (the host doesn't
 * filter multicast as a phone's Wi-Fi does). Unreal Engine games take one
 * at startup.
 */
final class WifiManagerService extends WifiManagerBase {
    private static final String TAG = "Mead";

    private int mMulticastLocks;

    /** The host's Wi-Fi interface: the default route's if wireless, else the first up; null for none. */
    private static String wifiInterface() {
        String route = ConnectivityService.hostInterface();
        String first = null;
        for (String name : Nl80211.interfaces()) {
            if (!Nl80211.isUp(name)) continue;
            if (name.equals(route)) return name;
            if (first == null) first = name;
        }
        return first;
    }

    @Override public int getWifiEnabledState() {
        return wifiInterface() != null ? WifiManager.WIFI_STATE_ENABLED : WifiManager.WIFI_STATE_DISABLED;
    }

    /**
     * The connection, as Android 10's Wi-Fi service gives it to apps: the
     * signal, link speeds, frequency and IPv4 address; the SSID, BSSID and
     * network ID only to apps that may see where the device is (location
     * permission, which Mead grants when asked for); never the device's own
     * MAC address. Not connected (an unknown SSID, network ID -1) while
     * Wi-Fi is off or not associated; never null.
     */
    @Override public WifiInfo getConnectionInfo(String callingPackage) {
        WifiInfo info = new WifiInfo();
        info.setMacAddress(WifiInfo.DEFAULT_MAC_ADDRESS);
        String name = wifiInterface();
        if (name == null) return info;
        info.setSupplicantState(SupplicantState.DISCONNECTED);
        Nl80211.Link link;
        try {
            link = Nl80211.link(name);
        } catch (IOException e) {
            Log.w(TAG, "Unable to read " + name + "'s Wi-Fi link: " + e.getMessage());
            return info;
        }
        if (!link.associated()) return info;
        info.setSupplicantState(SupplicantState.COMPLETED);
        if (link.rssi != Integer.MIN_VALUE) info.setRssi(link.rssi);
        if (link.frequency > 0) info.setFrequency(link.frequency);
        // The send rate is the link speed, as Android's; unknown (-1) where
        // the driver doesn't say (ath10k reports only what it receives at).
        info.setLinkSpeed(link.txMbps >= 0 ? link.txMbps : WifiInfo.LINK_SPEED_UNKNOWN);
        info.setTxLinkSpeedMbps(link.txMbps >= 0 ? link.txMbps : WifiInfo.LINK_SPEED_UNKNOWN);
        info.setRxLinkSpeedMbps(link.rxMbps >= 0 ? link.rxMbps : WifiInfo.LINK_SPEED_UNKNOWN);
        info.setInetAddress(ipv4Address(name));
        if (maySeeNetwork()) {
            if (link.ssid != null) info.setSSID(WifiSsid.createFromByteArray(link.ssid));
            info.setBSSID(link.bssid);
            // Mead keeps no saved networks: the one connected is the first.
            info.setNetworkId(0);
        } else {
            info.setBSSID(WifiInfo.DEFAULT_MAC_ADDRESS);
            info.setNetworkId(WifiConfiguration.INVALID_NETWORK_ID);
        }
        return info;
    }

    /**
     * Whether the app may see the network, as WifiPermissionsUtil decides:
     * fine location from Android 10's target SDK, coarse before it.
     */
    private static boolean maySeeNetwork() {
        MeadApp app = MeadApp.sCurrent;
        if (app == null) return false;
        if (app.requestedPermissions.contains(Manifest.permission.ACCESS_FINE_LOCATION)) return true;
        return app.applicationInfo().targetSdkVersion < Build.VERSION_CODES.Q
                && app.requestedPermissions.contains(Manifest.permission.ACCESS_COARSE_LOCATION);
    }

    /** An interface's IPv4 address; null for none. */
    private static InetAddress ipv4Address(String name) {
        try {
            NetworkInterface network = NetworkInterface.getByName(name);
            if (network == null) return null;
            for (InetAddress address : Collections.list(network.getInetAddresses())) {
                if (address instanceof Inet4Address) return address;
            }
        } catch (SocketException e) {
            // No addresses to give.
        }
        return null;
    }

    @Override public synchronized void acquireMulticastLock(IBinder binder, String tag) { mMulticastLocks++; }

    @Override public synchronized void releaseMulticastLock(String tag) {
        if (mMulticastLocks > 0) mMulticastLocks--;
    }

    @Override public synchronized boolean isMulticastEnabled() { return mMulticastLocks > 0; }
}
