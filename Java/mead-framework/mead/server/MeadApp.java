package mead.server;

import android.app.ActivityThread;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.res.Configuration;
import android.graphics.Rect;
import android.os.LocaleList;
import android.os.Process;
import android.app.WindowConfiguration;
import java.io.File;

/**
 * The app Mead runs, as the system's services describe it to ActivityThread:
 * its package, code, data directory and launch activity, and its window's
 * size, from which its Configuration comes.
 */
public final class MeadApp {
    final String packageName;
    final String activityName;
    final String sourcePath;
    final int width;
    final int height;

    static volatile MeadApp sCurrent;

    MeadApp(String packageName, String activityName, String sourcePath, int width, int height) {
        this.packageName = packageName;
        this.activityName = activityName;
        this.sourcePath = sourcePath;
        this.width = width;
        this.height = height;
    }

    /**
     * Runs an app's activity as Android does: ActivityThread's main, which
     * attaches to Mead's activity manager, which binds the app and launches
     * the activity. Arguments: the package, the activity's class, and the
     * window's width and height (1280×720 when not given). The app's code is
     * the class path's first entry. Doesn't return.
     */
    public static void main(String[] args) {
        if (args.length < 2) {
            throw new IllegalArgumentException("usage: mead.server.MeadApp <package> <activity> [width height]");
        }
        int width = args.length > 3 ? Integer.parseInt(args[2]) : 1280;
        int height = args.length > 3 ? Integer.parseInt(args[3]) : 720;
        String sourcePath = System.getProperty("java.class.path").split(":")[0];
        sCurrent = new MeadApp(args[0], args[1], new File(sourcePath).getAbsolutePath(), width, height);
        ActivityThread.main(new String[0]);
    }

    /** Where the app keeps its data: ~/.mead/apps/<package>. */
    String dataDir() {
        String home = System.getenv("HOME");
        File data = new File((home != null ? home : "/tmp") + "/.mead/apps/" + packageName);
        new File(data, "lib").mkdirs();
        return data.getAbsolutePath();
    }

    ApplicationInfo applicationInfo() {
        ApplicationInfo info = new ApplicationInfo();
        info.packageName = packageName;
        info.processName = packageName;
        info.sourceDir = info.publicSourceDir = sourcePath;
        info.dataDir = info.credentialProtectedDataDir = info.deviceProtectedDataDir = dataDir();
        info.nativeLibraryDir = info.dataDir + "/lib";
        info.uid = Process.myUid();
        info.targetSdkVersion = 29;
        info.minSdkVersion = 1;
        info.flags = ApplicationInfo.FLAG_HAS_CODE | ApplicationInfo.FLAG_SUPPORTS_SMALL_SCREENS
                | ApplicationInfo.FLAG_SUPPORTS_NORMAL_SCREENS | ApplicationInfo.FLAG_SUPPORTS_LARGE_SCREENS
                | ApplicationInfo.FLAG_SUPPORTS_XLARGE_SCREENS | ApplicationInfo.FLAG_RESIZEABLE_FOR_SCREENS
                | ApplicationInfo.FLAG_SUPPORTS_SCREEN_DENSITIES;
        info.enabled = true;
        return info;
    }

    ActivityInfo activityInfo(ApplicationInfo application) {
        ActivityInfo info = new ActivityInfo();
        info.name = activityName;
        info.packageName = packageName;
        info.applicationInfo = application;
        info.processName = application.processName;
        info.launchMode = ActivityInfo.LAUNCH_MULTIPLE;
        info.screenOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
        // As android:hardwareAccelerated is by default from API 14.
        info.flags = ActivityInfo.FLAG_HARDWARE_ACCELERATED;
        info.exported = true;
        info.enabled = true;
        return info;
    }

    /** The app's configuration: its window's size, on the display's density. */
    Configuration configuration() {
        float density = DisplayManagerService.density();
        Configuration config = new Configuration();
        config.setToDefaults();
        config.seq = 1;
        config.densityDpi = Math.round(density * 160);
        config.screenWidthDp = Math.round(width / density);
        config.screenHeightDp = Math.round(height / density);
        config.smallestScreenWidthDp = Math.min(config.screenWidthDp, config.screenHeightDp);
        config.orientation = width >= height ? Configuration.ORIENTATION_LANDSCAPE : Configuration.ORIENTATION_PORTRAIT;
        config.screenLayout = Configuration.SCREENLAYOUT_SIZE_NORMAL | Configuration.SCREENLAYOUT_LONG_NO
                | Configuration.SCREENLAYOUT_LAYOUTDIR_LTR | Configuration.SCREENLAYOUT_ROUND_NO;
        config.uiMode = Configuration.UI_MODE_TYPE_NORMAL | Configuration.UI_MODE_NIGHT_NO;
        config.touchscreen = Configuration.TOUCHSCREEN_FINGER;
        config.keyboard = Configuration.KEYBOARD_QWERTY;
        config.keyboardHidden = Configuration.KEYBOARDHIDDEN_NO;
        config.hardKeyboardHidden = Configuration.HARDKEYBOARDHIDDEN_NO;
        config.navigation = Configuration.NAVIGATION_DPAD;
        config.navigationHidden = Configuration.NAVIGATIONHIDDEN_NO;
        config.fontScale = 1;
        config.setLocales(LocaleList.getDefault());
        Rect bounds = new Rect(0, 0, width, height);
        config.windowConfiguration.setBounds(bounds);
        config.windowConfiguration.setAppBounds(bounds);
        config.windowConfiguration.setWindowingMode(WindowConfiguration.WINDOWING_MODE_FULLSCREEN);
        config.windowConfiguration.setActivityType(WindowConfiguration.ACTIVITY_TYPE_STANDARD);
        return config;
    }
}
