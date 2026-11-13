package mead.server;

import android.app.ActivityManager;
import java.io.BufferedReader;
import java.io.FileReader;
import java.io.IOException;

/**
 * The host's memory, as Android's activity manager reports it: from
 * /proc/meminfo. Games pick their quality by it (Unreal's config rules read
 * totalMem), so a device reporting none gets the lowest settings.
 */
final class Memory {
    private Memory() {}

    static void fill(ActivityManager.MemoryInfo info) {
        long total = 0, available = 0;
        try (BufferedReader reader = new BufferedReader(new FileReader("/proc/meminfo"))) {
            for (String line; (line = reader.readLine()) != null; ) {
                if (line.startsWith("MemTotal:")) total = kilobytes(line) * 1024;
                else if (line.startsWith("MemAvailable:")) available = kilobytes(line) * 1024;
            }
        } catch (IOException e) {
            // No /proc: nothing known.
        }
        info.totalMem = total;
        info.availMem = available;
        // Android's low-memory threshold is a few hundred megabytes on a
        // phone; a tenth of the total keeps it in proportion.
        info.threshold = total / 10;
        info.lowMemory = total > 0 && available < info.threshold;
    }

    private static long kilobytes(String line) {
        String[] fields = line.trim().split("\\s+");
        try {
            return fields.length > 1 ? Long.parseLong(fields[1]) : 0;
        } catch (NumberFormatException e) {
            return 0;
        }
    }
}
