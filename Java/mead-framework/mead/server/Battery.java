package mead.server;

import android.content.Intent;
import android.os.BatteryManager;
import java.io.File;
import java.io.FileInputStream;
import java.io.IOException;
import java.nio.charset.StandardCharsets;

/**
 * The host's battery, as Android's battery service reports it: the sticky
 * ACTION_BATTERY_CHANGED broadcast, read from Linux's power supplies
 * (/sys/class/power_supply). Games read it: Unity's SystemInfo.batteryStatus
 * comes from it, and Subnautica: Below Zero holds itself to 30 frames a
 * second while the status is unknown. The system's battery is the first
 * of type Battery that isn't a device's own (a controller's has scope
 * Device); it's plugged in when a mains or USB supply is online. With no
 * battery the host reports mains power, as Android TV does.
 */
final class Battery {
    private static final File SUPPLIES = new File("/sys/class/power_supply");

    private Battery() {}

    static Intent changed() {
        File battery = null;
        int plugged = 0;
        File[] supplies = SUPPLIES.listFiles();
        if (supplies != null) {
            for (File supply : supplies) {
                String type = read(supply, "type");
                if ("Battery".equals(type)) {
                    if (battery == null && !"Device".equals(read(supply, "scope"))) battery = supply;
                } else if ("1".equals(read(supply, "online"))) {
                    plugged |= "Mains".equals(type) ? BatteryManager.BATTERY_PLUGGED_AC : BatteryManager.BATTERY_PLUGGED_USB;
                }
            }
        }
        Intent intent = new Intent(Intent.ACTION_BATTERY_CHANGED);
        intent.addFlags(Intent.FLAG_RECEIVER_REGISTERED_ONLY | Intent.FLAG_RECEIVER_REPLACE_PENDING);
        intent.putExtra(BatteryManager.EXTRA_SCALE, 100);
        if (battery == null) {
            intent.putExtra(BatteryManager.EXTRA_PRESENT, false);
            intent.putExtra(BatteryManager.EXTRA_STATUS, BatteryManager.BATTERY_STATUS_UNKNOWN);
            intent.putExtra(BatteryManager.EXTRA_PLUGGED, BatteryManager.BATTERY_PLUGGED_AC);
            intent.putExtra(BatteryManager.EXTRA_LEVEL, 100);
            intent.putExtra(BatteryManager.EXTRA_HEALTH, BatteryManager.BATTERY_HEALTH_UNKNOWN);
            return intent;
        }
        intent.putExtra(BatteryManager.EXTRA_PRESENT, true);
        intent.putExtra(BatteryManager.EXTRA_STATUS, status(read(battery, "status")));
        intent.putExtra(BatteryManager.EXTRA_PLUGGED, plugged);
        intent.putExtra(BatteryManager.EXTRA_LEVEL, number(read(battery, "capacity"), 100));
        intent.putExtra(BatteryManager.EXTRA_HEALTH, BatteryManager.BATTERY_HEALTH_GOOD);
        intent.putExtra(BatteryManager.EXTRA_TECHNOLOGY, "Li-ion");
        // Tenths of a degree Celsius, and millivolts, from the kernel's
        // tenths and microvolts.
        intent.putExtra(BatteryManager.EXTRA_TEMPERATURE, number(read(battery, "temp"), 250));
        intent.putExtra(BatteryManager.EXTRA_VOLTAGE, number(read(battery, "voltage_now"), 0) / 1000);
        return intent;
    }

    private static int status(String status) {
        if (status == null) return BatteryManager.BATTERY_STATUS_UNKNOWN;
        switch (status) {
            case "Charging": return BatteryManager.BATTERY_STATUS_CHARGING;
            case "Discharging": return BatteryManager.BATTERY_STATUS_DISCHARGING;
            case "Not charging": return BatteryManager.BATTERY_STATUS_NOT_CHARGING;
            case "Full": return BatteryManager.BATTERY_STATUS_FULL;
            default: return BatteryManager.BATTERY_STATUS_UNKNOWN;
        }
    }

    private static int number(String text, int otherwise) {
        if (text == null) return otherwise;
        try {
            return Integer.parseInt(text);
        } catch (NumberFormatException e) {
            return otherwise;
        }
    }

    /** A power supply's attribute, trimmed; null when it has none. */
    private static String read(File supply, String name) {
        try (FileInputStream in = new FileInputStream(new File(supply, name))) {
            byte[] bytes = new byte[64];
            int count = in.read(bytes);
            return count > 0 ? new String(bytes, 0, count, StandardCharsets.UTF_8).trim() : null;
        } catch (IOException e) {
            return null;
        }
    }
}
