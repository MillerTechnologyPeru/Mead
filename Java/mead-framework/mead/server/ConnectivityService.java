package mead.server;

import android.app.PendingIntent;
import android.net.ConnectivityManager;
import android.net.LinkProperties;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.NetworkInfo;
import android.net.NetworkRequest;
import android.os.Bundle;
import android.os.IBinder;
import android.os.Message;
import android.os.Messenger;
import android.os.Parcelable;
import android.os.RemoteException;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;
import java.util.concurrent.atomic.AtomicInteger;
import mead.server.base.ConnectivityManagerBase;

/**
 * Android's connectivity service for Mead: the host's own connection, as one
 * network. Mead doesn't manage the host's networking, so there's a network
 * while the host has a default route (IPv4 or IPv6), on its interface: Wi-Fi
 * for a wl* one, Ethernet otherwise; none while it has no route. Requests and
 * listens hear that it's available when it satisfies them, as Android's
 * callbacks have it; changes after that aren't reported.
 */
final class ConnectivityService extends ConnectivityManagerBase {
    /** The one network's id; any above Android's reserved ones. */
    private static final int NET_ID = 100;

    private final AtomicInteger mNextRequestId = new AtomicInteger(1);

    /** The host's connection: its interface's name; null for none. */
    private static String hostInterface() {
        String route = defaultRoute("/proc/net/route", 1, "00000000");
        return route != null ? route : defaultRoute("/proc/net/ipv6_route", 0, "00000000000000000000000000000000");
    }

    /**
     * The interface of a table's default route: the first row whose
     * destination column is all zeros, off the loopback.
     */
    private static String defaultRoute(String table, int destinationColumn, String zeros) {
        try (BufferedReader reader = new BufferedReader(new FileReader(table))) {
            String line;
            while ((line = reader.readLine()) != null) {
                String[] columns = line.trim().split("\\s+");
                if (columns.length < 2) continue;
                String name = table.endsWith("ipv6_route") ? columns[columns.length - 1] : columns[0];
                if (columns[destinationColumn].equals(zeros) && !name.equals("lo")) return name;
            }
        } catch (IOException e) {
            // No table: no route.
        }
        return null;
    }

    private static boolean isWifi(String name) {
        return name.startsWith("wl");
    }

    private static Network network() {
        return new Network(NET_ID);
    }

    private static NetworkCapabilities capabilities(String name) {
        NetworkCapabilities capabilities = new NetworkCapabilities();
        capabilities.addTransportType(isWifi(name) ? NetworkCapabilities.TRANSPORT_WIFI
                : NetworkCapabilities.TRANSPORT_ETHERNET);
        for (int capability : new int[] {NetworkCapabilities.NET_CAPABILITY_INTERNET,
                NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED, NetworkCapabilities.NET_CAPABILITY_TRUSTED,
                NetworkCapabilities.NET_CAPABILITY_NOT_VPN, NetworkCapabilities.NET_CAPABILITY_VALIDATED,
                NetworkCapabilities.NET_CAPABILITY_NOT_METERED, NetworkCapabilities.NET_CAPABILITY_NOT_ROAMING,
                NetworkCapabilities.NET_CAPABILITY_NOT_CONGESTED, NetworkCapabilities.NET_CAPABILITY_NOT_SUSPENDED,
                NetworkCapabilities.NET_CAPABILITY_FOREGROUND}) {
            capabilities.addCapability(capability);
        }
        return capabilities;
    }

    private static NetworkInfo info(String name) {
        boolean wifi = isWifi(name);
        NetworkInfo info = new NetworkInfo(wifi ? ConnectivityManager.TYPE_WIFI : ConnectivityManager.TYPE_ETHERNET,
                0, wifi ? "WIFI" : "ETHERNET", "");
        info.setDetailedState(NetworkInfo.DetailedState.CONNECTED, null, null);
        info.setIsAvailable(true);
        return info;
    }

    private static LinkProperties linkProperties(String name) {
        LinkProperties properties = new LinkProperties();
        properties.setInterfaceName(name);
        return properties;
    }

    @Override public Network getActiveNetwork() {
        return hostInterface() != null ? network() : null;
    }

    @Override public Network getActiveNetworkForUid(int uid, boolean ignoreBlocked) {
        return getActiveNetwork();
    }

    @Override public NetworkInfo getActiveNetworkInfo() {
        String name = hostInterface();
        return name != null ? info(name) : null;
    }

    @Override public NetworkInfo getActiveNetworkInfoForUid(int uid, boolean ignoreBlocked) {
        return getActiveNetworkInfo();
    }

    @Override public NetworkInfo getNetworkInfo(int type) {
        NetworkInfo info = getActiveNetworkInfo();
        return info != null && info.getType() == type ? info : null;
    }

    @Override public NetworkInfo getNetworkInfoForUid(Network network, int uid, boolean ignoreBlocked) {
        return network != null && network.netId == NET_ID ? getActiveNetworkInfo() : null;
    }

    @Override public NetworkInfo[] getAllNetworkInfo() {
        NetworkInfo info = getActiveNetworkInfo();
        return info != null ? new NetworkInfo[] {info} : new NetworkInfo[0];
    }

    @Override public Network getNetworkForType(int type) {
        return getNetworkInfo(type) != null ? network() : null;
    }

    @Override public Network[] getAllNetworks() {
        Network network = getActiveNetwork();
        return network != null ? new Network[] {network} : new Network[0];
    }

    @Override public NetworkCapabilities[] getDefaultNetworkCapabilitiesForUser(int userId) {
        String name = hostInterface();
        return name != null ? new NetworkCapabilities[] {capabilities(name)} : new NetworkCapabilities[0];
    }

    @Override public LinkProperties getActiveLinkProperties() {
        String name = hostInterface();
        return name != null ? linkProperties(name) : null;
    }

    @Override public LinkProperties getLinkPropertiesForType(int type) {
        return getNetworkInfo(type) != null ? getActiveLinkProperties() : null;
    }

    @Override public LinkProperties getLinkProperties(Network network) {
        return network != null && network.netId == NET_ID ? getActiveLinkProperties() : null;
    }

    @Override public NetworkCapabilities getNetworkCapabilities(Network network) {
        String name = hostInterface();
        return name != null && network != null && network.netId == NET_ID ? capabilities(name) : null;
    }

    /** No proxy: apps connect directly, as the host does. */
    @Override public android.net.ProxyInfo getProxyForNetwork(Network network) {
        return null;
    }

    @Override public boolean isActiveNetworkMetered() {
        return false;
    }

    @Override public NetworkRequest requestNetwork(NetworkCapabilities need, Messenger messenger, int timeoutMs,
            IBinder binder, int legacyType) {
        return register(need, messenger, legacyType, NetworkRequest.Type.REQUEST);
    }

    @Override public NetworkRequest listenForNetwork(NetworkCapabilities need, Messenger messenger, IBinder binder) {
        return register(need, messenger, ConnectivityManager.TYPE_NONE, NetworkRequest.Type.LISTEN);
    }

    @Override public NetworkRequest pendingRequestForNetwork(NetworkCapabilities need, PendingIntent operation) {
        return register(need, null, ConnectivityManager.TYPE_NONE, NetworkRequest.Type.REQUEST);
    }

    @Override public void pendingListenForNetwork(NetworkCapabilities need, PendingIntent operation) {
    }

    @Override public void releaseNetworkRequest(NetworkRequest request) {
    }

    /**
     * A request with an id of its own, and, when the host's network
     * satisfies it, CALLBACK_AVAILABLE with the network, its capabilities
     * and link properties, as ConnectivityService sends it.
     */
    private NetworkRequest register(NetworkCapabilities need, Messenger messenger, int legacyType,
            NetworkRequest.Type type) {
        // A default-network request (registerDefaultNetworkCallback) comes without capabilities.
        NetworkCapabilities wanted = need != null ? new NetworkCapabilities(need) : defaultNeed();
        NetworkRequest request = new NetworkRequest(wanted, legacyType, mNextRequestId.getAndIncrement(), type);
        String name = hostInterface();
        if (messenger != null && name != null && wanted.satisfiedByNetworkCapabilities(capabilities(name))) {
            Bundle bundle = new Bundle();
            put(bundle, new NetworkRequest(request));
            put(bundle, network());
            put(bundle, capabilities(name));
            put(bundle, linkProperties(name));
            Message message = Message.obtain();
            message.what = ConnectivityManager.CALLBACK_AVAILABLE;
            message.setData(bundle);
            try {
                messenger.send(message);
            } catch (RemoteException e) {
                // The app's handler is in this process.
            }
        }
        return request;
    }

    private static NetworkCapabilities defaultNeed() {
        NetworkCapabilities need = new NetworkCapabilities();
        need.addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET);
        need.addCapability(NetworkCapabilities.NET_CAPABILITY_NOT_RESTRICTED);
        return need;
    }

    /** Keyed by the class's simple name, as ConnectivityManager's callback handler reads it. */
    private static void put(Bundle bundle, Parcelable value) {
        bundle.putParcelable(value.getClass().getSimpleName(), value);
    }
}
