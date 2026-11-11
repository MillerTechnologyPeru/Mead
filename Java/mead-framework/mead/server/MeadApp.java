package mead.server;

import android.app.ActivityThread;
import android.app.WindowConfiguration;
import android.content.ComponentName;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.PackageParser;
import android.content.res.Configuration;
import android.graphics.Rect;
import android.os.LocaleList;
import android.os.Process;
import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * The app Mead runs, as the system's services describe it to ActivityThread:
 * its package, code, data directory and activities, from its APK's manifest
 * (or, for a dex without one, a single activity named on the command line),
 * and its window's size, from which its Configuration comes.
 */
public final class MeadApp {
    /** An activity of the app, and the intents it takes. */
    static final class Activity {
        final ActivityInfo info;
        final List<IntentFilter> filters;

        Activity(ActivityInfo info, List<IntentFilter> filters) {
            this.info = info;
            this.filters = filters;
        }
    }

    final String packageName;
    final String sourcePath;
    final int width;
    final int height;
    /** The launcher activity's class. */
    final String activityName;
    /** What the manifest says of the application, without where it's installed. */
    private final ApplicationInfo mApplication;
    private final Map<String, Activity> mActivities = new LinkedHashMap<>();
    /** The permissions the manifest asks for. */
    final List<String> requestedPermissions;

    static volatile MeadApp sCurrent;

    /** A dex's app: one activity, named. */
    MeadApp(String packageName, String activityName, String sourcePath, int width, int height) {
        this.packageName = packageName;
        this.activityName = activityName;
        this.sourcePath = sourcePath;
        this.width = width;
        this.height = height;
        requestedPermissions = Collections.emptyList();
        mApplication = new ApplicationInfo();
        mApplication.packageName = packageName;
        mApplication.targetSdkVersion = 29;
        mApplication.minSdkVersion = 1;
        mApplication.flags = ApplicationInfo.FLAG_HAS_CODE | ApplicationInfo.FLAG_SUPPORTS_SMALL_SCREENS
                | ApplicationInfo.FLAG_SUPPORTS_NORMAL_SCREENS | ApplicationInfo.FLAG_SUPPORTS_LARGE_SCREENS
                | ApplicationInfo.FLAG_SUPPORTS_XLARGE_SCREENS | ApplicationInfo.FLAG_RESIZEABLE_FOR_SCREENS
                | ApplicationInfo.FLAG_SUPPORTS_SCREEN_DENSITIES;
        mApplication.enabled = true;
        ActivityInfo activity = new ActivityInfo();
        activity.name = activityName;
        activity.packageName = packageName;
        activity.launchMode = ActivityInfo.LAUNCH_MULTIPLE;
        activity.screenOrientation = ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
        // As android:hardwareAccelerated is by default from API 14.
        activity.flags = ActivityInfo.FLAG_HARDWARE_ACCELERATED;
        activity.exported = true;
        activity.enabled = true;
        mActivities.put(activityName, new Activity(activity, Collections.<IntentFilter>emptyList()));
    }

    /** An APK's app, from its manifest. */
    MeadApp(PackageParser.Package parsed, String sourcePath, int width, int height) {
        this.packageName = parsed.packageName;
        this.sourcePath = sourcePath;
        this.width = width;
        this.height = height;
        requestedPermissions = new ArrayList<>(parsed.requestedPermissions);
        mApplication = parsed.applicationInfo;
        String launcher = null;
        for (PackageParser.Activity activity : parsed.activities) {
            List<IntentFilter> filters = new ArrayList<IntentFilter>(activity.intents);
            mActivities.put(activity.info.name, new Activity(activity.info, filters));
            if (launcher == null) {
                for (IntentFilter filter : filters) {
                    if (filter.hasAction(Intent.ACTION_MAIN) && filter.hasCategory(Intent.CATEGORY_LAUNCHER)) {
                        launcher = activity.info.name;
                    }
                }
            }
        }
        if (launcher == null) throw new IllegalArgumentException(sourcePath + " has no launcher activity");
        activityName = launcher;
    }

    /**
     * Runs an app as Android does: ActivityThread's main, which attaches to
     * Mead's activity manager, which binds the app and launches its launcher
     * activity. The app's code is the class path's first entry: an APK
     * (arguments: the window's width and height), or a dex (arguments: the
     * package, the activity's class, and the window's width and height). The
     * window is 1280×720 when its size isn't given. Doesn't return.
     */
    public static void main(String[] args) throws Exception {
        String sourcePath = new File(System.getProperty("java.class.path").split(":")[0]).getAbsolutePath();
        if (sourcePath.endsWith(".apk")) {
            int width = args.length >= 2 ? Integer.parseInt(args[0]) : 1280;
            int height = args.length >= 2 ? Integer.parseInt(args[1]) : 720;
            PackageParser.Package parsed = new PackageParser().parsePackage(new File(sourcePath), 0);
            sCurrent = new MeadApp(parsed, sourcePath, width, height);
        } else {
            if (args.length < 2) {
                throw new IllegalArgumentException(
                        "usage: mead.server.MeadApp [width height] for an APK, or <package> <activity> [width height]");
            }
            int width = args.length > 3 ? Integer.parseInt(args[2]) : 1280;
            int height = args.length > 3 ? Integer.parseInt(args[3]) : 720;
            sCurrent = new MeadApp(args[0], args[1], sourcePath, width, height);
        }
        ActivityThread.main(new String[0]);
    }

    /** Where the app keeps its data: ~/.mead/apps/<package>. */
    String dataDir() {
        String home = System.getenv("HOME");
        File data = new File((home != null ? home : "/tmp") + "/.mead/apps/" + packageName);
        new File(data, "lib").mkdirs();
        return data.getAbsolutePath();
    }

    /** The application, installed: where its code and data are. */
    ApplicationInfo applicationInfo() {
        ApplicationInfo info = new ApplicationInfo(mApplication);
        info.packageName = packageName;
        if (info.processName == null) info.processName = packageName;
        info.sourceDir = info.publicSourceDir = sourcePath;
        info.dataDir = info.credentialProtectedDataDir = info.deviceProtectedDataDir = dataDir();
        info.nativeLibraryDir = info.dataDir + "/lib";
        info.uid = Process.myUid();
        info.enabled = true;
        return info;
    }

    /** An activity, by its class name, with the installed application; null for none. */
    ActivityInfo activityInfo(String name, ApplicationInfo application) {
        Activity activity = mActivities.get(name);
        if (activity == null) return null;
        ActivityInfo info = new ActivityInfo(activity.info);
        info.applicationInfo = application;
        if (info.processName == null) info.processName = application.processName;
        return info;
    }

    /** The launcher activity. */
    ActivityInfo activityInfo(ApplicationInfo application) {
        return activityInfo(activityName, application);
    }

    /** Every activity, with the installed application. */
    List<ActivityInfo> activityInfos(ApplicationInfo application) {
        List<ActivityInfo> infos = new ArrayList<>();
        for (String name : mActivities.keySet()) infos.add(activityInfo(name, application));
        return infos;
    }

    /**
     * The activity an intent starts in this app: its component's, or the
     * first whose filters match its action, categories and data; null for
     * none.
     */
    ActivityInfo resolveActivity(Intent intent, String resolvedType) {
        ApplicationInfo application = applicationInfo();
        ComponentName component = intent.getComponent();
        if (component != null) {
            return component.getPackageName().equals(packageName)
                    ? activityInfo(component.getClassName(), application) : null;
        }
        if (intent.getPackage() != null && !intent.getPackage().equals(packageName)) return null;
        for (Activity activity : mActivities.values()) {
            for (IntentFilter filter : activity.filters) {
                if (filter.match(intent.getAction(), resolvedType, intent.getScheme(), intent.getData(),
                        intent.getCategories(), "Mead") >= 0) {
                    return activityInfo(activity.info.name, application);
                }
            }
        }
        return null;
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
