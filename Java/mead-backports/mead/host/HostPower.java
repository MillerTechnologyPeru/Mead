package mead.host;

import java.io.File;

/**
 * The host's power state in Android's terms, for PowerManager and its
 * service: power saving is Linux's own (the CPU governor set to powersave,
 * as ROCKNIX and others offer, or a low-power platform profile on PCs);
 * the screen is on while a backlight is unblanked and lit, and always on a
 * host without one.
 */
public final class HostPower {
    private static final File CPUFREQ = new File("/sys/devices/system/cpu/cpufreq");
    private static final File PLATFORM_PROFILE = new File("/sys/firmware/acpi");
    private static final File BACKLIGHT = new File("/sys/class/backlight");

    private HostPower() {}

    /** Whether the host is saving power, as Android's battery saver would. */
    public static boolean powerSave() {
        if ("low-power".equals(HostThermal.read(PLATFORM_PROFILE, "platform_profile"))) return true;
        File[] policies = CPUFREQ.listFiles();
        if (policies == null) return false;
        boolean any = false;
        for (File policy : policies) {
            if (!policy.getName().startsWith("policy")) continue;
            String governor = HostThermal.read(policy, "scaling_governor");
            if (governor == null) continue;
            if (!governor.equals("powersave")) return false;
            any = true;
        }
        return any;
    }

    /** Whether the screen is on: a backlight unblanked (bl_power 0) with some brightness. */
    public static boolean screenOn() {
        File[] lights = BACKLIGHT.listFiles();
        if (lights == null || lights.length == 0) return true;
        for (File light : lights) {
            long power = HostThermal.number(HostThermal.read(light, "bl_power"), 0);
            long brightness = HostThermal.number(HostThermal.read(light, "brightness"), 1);
            if (power == 0 && brightness > 0) return true;
        }
        return false;
    }
}
