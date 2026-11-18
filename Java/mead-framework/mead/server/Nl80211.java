package mead.server;

import android.system.ErrnoException;
import android.system.Os;
import android.system.OsConstants;
import android.system.StructTimeval;
import java.io.BufferedReader;
import java.io.File;
import java.io.FileDescriptor;
import java.io.FileReader;
import java.io.IOException;
import java.nio.ByteBuffer;
import java.nio.ByteOrder;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * The host's Wi-Fi, as the kernel's nl80211 tells it over generic netlink:
 * what wificond and the supplicant tell Android's Wi-Fi service. Mead only
 * asks; the host's own network manager keeps the connection.
 */
final class Nl80211 {
    private Nl80211() {}

    /** A wireless interface's link: the access point it's associated with, or none. */
    static final class Link {
        /** The network's SSID, as its bytes; null when unknown. */
        byte[] ssid;
        /** The access point's address; null when not associated. */
        String bssid;
        /** The channel's frequency in MHz; -1 when unknown. */
        int frequency = -1;
        /** The access point's signal in dBm; Integer.MIN_VALUE when unknown. */
        int rssi = Integer.MIN_VALUE;
        /** The last send and receive rates in Mbps; -1 when unknown. */
        int txMbps = -1;
        int rxMbps = -1;

        boolean associated() {
            return bssid != null;
        }
    }

    // Netlink and generic netlink, from <linux/netlink.h> and <linux/genetlink.h>.
    private static final int NETLINK_GENERIC = 16;
    private static final int NLMSG_ERROR = 2;
    private static final int NLMSG_DONE = 3;
    private static final int NLM_F_REQUEST = 0x1;
    private static final int NLM_F_MULTI = 0x2;
    private static final int NLM_F_DUMP = 0x300;
    private static final int GENL_ID_CTRL = 0x10;
    private static final int CTRL_CMD_GETFAMILY = 3;
    private static final int CTRL_ATTR_FAMILY_ID = 1;
    private static final int CTRL_ATTR_FAMILY_NAME = 2;
    private static final int NLA_TYPE_MASK = 0x3fff;

    // nl80211, from <linux/nl80211.h>.
    private static final int NL80211_CMD_GET_INTERFACE = 5;
    private static final int NL80211_CMD_GET_STATION = 17;
    private static final int NL80211_ATTR_IFINDEX = 3;
    private static final int NL80211_ATTR_MAC = 6;
    private static final int NL80211_ATTR_STA_INFO = 21;
    private static final int NL80211_ATTR_WIPHY_FREQ = 38;
    private static final int NL80211_ATTR_SSID = 52;
    private static final int NL80211_STA_INFO_SIGNAL = 7;
    private static final int NL80211_STA_INFO_TX_BITRATE = 8;
    private static final int NL80211_STA_INFO_SIGNAL_AVG = 13;
    private static final int NL80211_STA_INFO_RX_BITRATE = 14;
    private static final int NL80211_RATE_INFO_BITRATE = 1;
    private static final int NL80211_RATE_INFO_BITRATE32 = 5;

    private static int sFamily;
    private static int sSequence;

    /** The host's wireless interfaces, by name. */
    static List<String> interfaces() {
        List<String> names = new ArrayList<>();
        String[] all = new File("/sys/class/net").list();
        if (all == null) return names;
        Arrays.sort(all);
        for (String name : all) {
            if (new File("/sys/class/net/" + name + "/wireless").isDirectory()
                    || new File("/sys/class/net/" + name + "/phy80211").exists()) {
                names.add(name);
            }
        }
        return names;
    }

    /** Whether an interface is up (IFF_UP). */
    static boolean isUp(String name) {
        String flags = readLine("/sys/class/net/" + name + "/flags");
        try {
            return flags != null && (Integer.decode(flags) & 0x1) != 0;
        } catch (NumberFormatException e) {
            return false;
        }
    }

    /** A wireless interface's link. */
    static synchronized Link link(String name) throws IOException {
        String index = readLine("/sys/class/net/" + name + "/ifindex");
        if (index == null) throw new IOException("no interface " + name);
        int ifindex = Integer.parseInt(index);
        FileDescriptor socket = null;
        try {
            socket = Os.socket(OsConstants.AF_NETLINK, OsConstants.SOCK_DGRAM, NETLINK_GENERIC);
            Os.setsockoptTimeval(socket, OsConstants.SOL_SOCKET, OsConstants.SO_RCVTIMEO,
                    StructTimeval.fromMillis(1000));
            if (sFamily == 0) sFamily = family(socket);
            Link link = new Link();
            byte[] ifindexAttribute = attribute(NL80211_ATTR_IFINDEX, u32(ifindex));
            // The interface: its SSID and channel.
            for (Map<Integer, byte[]> reply : ask(socket, sFamily, 0, NL80211_CMD_GET_INTERFACE, ifindexAttribute)) {
                link.ssid = reply.get(NL80211_ATTR_SSID);
                byte[] frequency = reply.get(NL80211_ATTR_WIPHY_FREQ);
                if (frequency != null) link.frequency = order(frequency).getInt(0);
            }
            // Its station: in managed mode, the access point it's associated with.
            for (Map<Integer, byte[]> reply : ask(socket, sFamily, NLM_F_DUMP, NL80211_CMD_GET_STATION,
                    ifindexAttribute)) {
                byte[] mac = reply.get(NL80211_ATTR_MAC);
                if (mac == null || mac.length != 6) continue;
                link.bssid = String.format("%02x:%02x:%02x:%02x:%02x:%02x",
                        mac[0], mac[1], mac[2], mac[3], mac[4], mac[5]);
                byte[] info = reply.get(NL80211_ATTR_STA_INFO);
                if (info != null) {
                    Map<Integer, byte[]> station = attributes(info, 0, info.length);
                    byte[] signal = station.get(NL80211_STA_INFO_SIGNAL);
                    if (signal == null) signal = station.get(NL80211_STA_INFO_SIGNAL_AVG);
                    if (signal != null && signal.length > 0) link.rssi = signal[0]; // signed dBm
                    link.txMbps = rate(station.get(NL80211_STA_INFO_TX_BITRATE));
                    link.rxMbps = rate(station.get(NL80211_STA_INFO_RX_BITRATE));
                }
                break;
            }
            return link;
        } catch (ErrnoException e) {
            throw new IOException("nl80211: " + e.getMessage(), e);
        } finally {
            if (socket != null) {
                try {
                    Os.close(socket);
                } catch (ErrnoException e) {
                    // Closed or not, it's done with.
                }
            }
        }
    }

    /** nl80211's generic netlink family. */
    private static int family(FileDescriptor socket) throws ErrnoException, IOException {
        byte[] name = "nl80211\0".getBytes(StandardCharsets.US_ASCII);
        for (Map<Integer, byte[]> reply : ask(socket, GENL_ID_CTRL, 0, CTRL_CMD_GETFAMILY,
                attribute(CTRL_ATTR_FAMILY_NAME, name))) {
            byte[] id = reply.get(CTRL_ATTR_FAMILY_ID);
            if (id != null) return order(id).getShort(0) & 0xffff;
        }
        throw new IOException("the kernel has no nl80211");
    }

    /** A rate's Mbps, from its 100 kbps units; -1 for none. */
    private static int rate(byte[] nested) {
        if (nested == null) return -1;
        Map<Integer, byte[]> rate = attributes(nested, 0, nested.length);
        byte[] wide = rate.get(NL80211_RATE_INFO_BITRATE32);
        if (wide != null) return order(wide).getInt(0) / 10;
        byte[] narrow = rate.get(NL80211_RATE_INFO_BITRATE);
        if (narrow != null) return (order(narrow).getShort(0) & 0xffff) / 10;
        return -1;
    }

    /**
     * Sends a generic netlink request and reads its replies' attributes:
     * one reply, or a dump's until NLMSG_DONE.
     */
    private static List<Map<Integer, byte[]>> ask(FileDescriptor socket, int family, int flags, int command,
            byte[] attributes) throws ErrnoException, IOException {
        int sequence = ++sSequence;
        ByteBuffer request = order(ByteBuffer.allocate(16 + 4 + attributes.length));
        request.putInt(request.capacity()).putShort((short) family).putShort((short) (NLM_F_REQUEST | flags))
                .putInt(sequence).putInt(0);
        request.put((byte) command).put((byte) 1).putShort((short) 0);
        request.put(attributes);
        Os.write(socket, request.array(), 0, request.capacity());
        List<Map<Integer, byte[]>> replies = new ArrayList<>();
        byte[] buffer = new byte[32 * 1024];
        while (true) {
            int length = Os.read(socket, buffer, 0, buffer.length);
            ByteBuffer messages = order(ByteBuffer.wrap(buffer, 0, length));
            int offset = 0;
            while (offset + 16 <= length) {
                int messageLength = messages.getInt(offset);
                int type = messages.getShort(offset + 4) & 0xffff;
                int messageFlags = messages.getShort(offset + 6) & 0xffff;
                int messageSequence = messages.getInt(offset + 8);
                if (messageLength < 16 || offset + messageLength > length) {
                    throw new IOException("a malformed netlink message");
                }
                if (messageSequence == sequence) {
                    if (type == NLMSG_DONE) return replies;
                    if (type == NLMSG_ERROR) {
                        int error = messages.getInt(offset + 16);
                        if (error != 0) throw new ErrnoException("nl80211 command " + command, -error);
                        return replies;
                    }
                    // Past the netlink and generic netlink headers.
                    replies.add(attributes(buffer, offset + 20, offset + messageLength));
                    if ((messageFlags & NLM_F_MULTI) == 0) return replies;
                }
                offset += align(messageLength);
            }
        }
    }

    /** The attributes in bytes [start, end), by type. */
    private static Map<Integer, byte[]> attributes(byte[] bytes, int start, int end) {
        Map<Integer, byte[]> attributes = new HashMap<>();
        ByteBuffer buffer = order(ByteBuffer.wrap(bytes));
        int offset = start;
        while (offset + 4 <= end) {
            int length = buffer.getShort(offset) & 0xffff;
            int type = buffer.getShort(offset + 2) & NLA_TYPE_MASK;
            if (length < 4 || offset + length > end) break;
            attributes.put(type, Arrays.copyOfRange(bytes, offset + 4, offset + length));
            offset += align(length);
        }
        return attributes;
    }

    private static byte[] attribute(int type, byte[] payload) {
        ByteBuffer attribute = order(ByteBuffer.allocate(align(4 + payload.length)));
        attribute.putShort((short) (4 + payload.length)).putShort((short) type).put(payload);
        return attribute.array();
    }

    private static byte[] u32(int value) {
        return order(ByteBuffer.allocate(4)).putInt(value).array();
    }

    private static int align(int length) {
        return (length + 3) & ~3;
    }

    /** Netlink is in the host's byte order. */
    private static ByteBuffer order(ByteBuffer buffer) {
        return buffer.order(ByteOrder.nativeOrder());
    }

    private static ByteBuffer order(byte[] bytes) {
        return order(ByteBuffer.wrap(bytes));
    }

    private static String readLine(String path) {
        try (BufferedReader reader = new BufferedReader(new FileReader(path))) {
            String line = reader.readLine();
            return line != null ? line.trim() : null;
        } catch (IOException e) {
            return null;
        }
    }
}
