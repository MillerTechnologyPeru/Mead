package mead.host;

import android.os.CoolingDevice;
import android.os.Temperature;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.List;

/**
 * The host's thermal state, from Linux's thermal zones and cooling devices
 * (/sys/class/thermal), in Android's terms, for its thermal service and
 * PowerManager.
 *
 * A zone is reported when its type names a part Android's thermal HAL
 * reports (CPU, GPU, battery, skin, NPU, USB port) and it has a reading.
 * Its throttling status comes from its trip points: the first passive trip,
 * where the kernel starts throttling, is SEVERE; 5 °C below it MODERATE,
 * 10 °C below it LIGHT; the hot trip CRITICAL; the critical trip, where the
 * kernel shuts down, SHUTDOWN. The device's status is its hottest zone's.
 */
public final class HostThermal {
    private static final File THERMAL = new File("/sys/class/thermal");

    /** Android 12's headroom scale: 1.0 at SEVERE, 0.0 this many degrees below it. */
    private static final float DEGREES_BETWEEN_ZERO_AND_ONE = 30f;

    private HostThermal() {}

    /** One zone: its Android type, name, temperature (°C), and trips (°C; NaN for none). */
    public static final class Zone {
        public final int type;
        public final String name;
        public final float celsius;
        public final float severe;
        public final float hot;
        public final float critical;

        Zone(int type, String name, float celsius, float severe, float hot, float critical) {
            this.type = type;
            this.name = name;
            this.celsius = celsius;
            this.severe = severe;
            this.hot = hot;
            this.critical = critical;
        }

        public int status() {
            if (!Float.isNaN(critical) && celsius >= critical) return Temperature.THROTTLING_SHUTDOWN;
            if (!Float.isNaN(hot) && celsius >= hot) return Temperature.THROTTLING_CRITICAL;
            if (Float.isNaN(severe)) return Temperature.THROTTLING_NONE;
            if (celsius >= severe) return Temperature.THROTTLING_SEVERE;
            if (celsius >= severe - 5) return Temperature.THROTTLING_MODERATE;
            if (celsius >= severe - 10) return Temperature.THROTTLING_LIGHT;
            return Temperature.THROTTLING_NONE;
        }

        /** How near SEVERE it is, as Android 12 normalizes it; NaN without a passive trip. */
        public float headroom() {
            return (celsius - severe + DEGREES_BETWEEN_ZERO_AND_ONE) / DEGREES_BETWEEN_ZERO_AND_ONE;
        }

        public Temperature temperature() {
            return new Temperature(celsius, type, name, status());
        }
    }

    /** The zones Android would report, read now. */
    public static List<Zone> zones() {
        List<Zone> zones = new ArrayList<>();
        File[] entries = THERMAL.listFiles();
        if (entries == null) return zones;
        for (File zone : entries) {
            if (!zone.getName().startsWith("thermal_zone")) continue;
            String name = read(zone, "type");
            if (name == null) continue;
            int type = temperatureType(name);
            if (type < 0) continue;
            long milli = number(read(zone, "temp"), Long.MIN_VALUE);
            // Sensors without a reading report -40 °C.
            if (milli == Long.MIN_VALUE || milli <= -40000) continue;
            float severe = Float.NaN, hot = Float.NaN, critical = Float.NaN;
            for (int trip = 0; ; trip++) {
                String kind = read(zone, "trip_point_" + trip + "_type");
                if (kind == null) break;
                long at = number(read(zone, "trip_point_" + trip + "_temp"), Long.MIN_VALUE);
                if (at == Long.MIN_VALUE) continue;
                float celsius = at / 1000f;
                if (kind.equals("passive") && (Float.isNaN(severe) || celsius < severe)) severe = celsius;
                else if (kind.equals("hot") && (Float.isNaN(hot) || celsius < hot)) hot = celsius;
                else if (kind.equals("critical") && (Float.isNaN(critical) || celsius < critical)) critical = celsius;
            }
            zones.add(new Zone(type, name, milli / 1000f, severe, hot, critical));
        }
        return zones;
    }

    /** The device's throttling status: its hottest zone's. */
    public static int status() {
        int status = Temperature.THROTTLING_NONE;
        for (Zone zone : zones()) status = Math.max(status, zone.status());
        return status;
    }

    /** The device's thermal headroom, as PowerManager.getThermalHeadroom has it; NaN without a measure. */
    public static float headroom() {
        float headroom = Float.NaN;
        for (Zone zone : zones()) {
            float zoneHeadroom = zone.headroom();
            if (!Float.isNaN(zoneHeadroom) && (Float.isNaN(headroom) || zoneHeadroom > headroom)) {
                headroom = zoneHeadroom;
            }
        }
        // Unclamped, as Android 12's: below 0 on a cool device.
        return headroom;
    }

    /** The zones' temperatures, all or of one type. */
    public static List<Temperature> temperatures(Integer type) {
        List<Temperature> temperatures = new ArrayList<>();
        for (Zone zone : zones()) {
            if (type == null || zone.type == type) temperatures.add(zone.temperature());
        }
        return temperatures;
    }

    /** The host's cooling devices (CPU and GPU frequency limits, fans), at their current states. */
    public static List<CoolingDevice> coolingDevices(Integer type) {
        List<CoolingDevice> devices = new ArrayList<>();
        File[] entries = THERMAL.listFiles();
        if (entries == null) return devices;
        for (File device : entries) {
            if (!device.getName().startsWith("cooling_device")) continue;
            String name = read(device, "type");
            if (name == null) continue;
            int deviceType = coolingType(name);
            if (type != null && deviceType != type) continue;
            devices.add(new CoolingDevice(number(read(device, "cur_state"), 0), deviceType, name));
        }
        return devices;
    }

    private static int temperatureType(String name) {
        String lower = name.toLowerCase();
        if (lower.contains("gpu")) return Temperature.TYPE_GPU;
        if (lower.contains("cpu") || lower.contains("cluster")) return Temperature.TYPE_CPU;
        if (lower.contains("battery")) return Temperature.TYPE_BATTERY;
        if (lower.contains("skin")) return Temperature.TYPE_SKIN;
        if (lower.contains("npu")) return Temperature.TYPE_NPU;
        if (lower.contains("usb")) return Temperature.TYPE_USB_PORT;
        return -1;
    }

    private static int coolingType(String name) {
        String lower = name.toLowerCase();
        if (lower.contains("fan")) return CoolingDevice.TYPE_FAN;
        if (lower.contains("gpu")) return CoolingDevice.TYPE_GPU;
        if (lower.contains("cpu")) return CoolingDevice.TYPE_CPU;
        if (lower.contains("battery") || lower.contains("charger")) return CoolingDevice.TYPE_BATTERY;
        if (lower.contains("modem")) return CoolingDevice.TYPE_MODEM;
        if (lower.contains("npu")) return CoolingDevice.TYPE_NPU;
        return CoolingDevice.TYPE_COMPONENT;
    }

    static String read(File directory, String name) {
        try (FileInputStream in = new FileInputStream(new File(directory, name))) {
            byte[] buffer = new byte[256];
            int length = in.read(buffer);
            return length > 0 ? new String(buffer, 0, length, StandardCharsets.UTF_8).trim() : "";
        } catch (IOException e) {
            return null;
        }
    }

    static long number(String text, long fallback) {
        if (text == null) return fallback;
        try {
            return Long.parseLong(text.trim());
        } catch (NumberFormatException e) {
            return fallback;
        }
    }
}
