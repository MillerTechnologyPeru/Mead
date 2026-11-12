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
import android.os.Bundle;
import android.os.LocaleList;
import android.os.Process;
import android.os.SystemProperties;
import java.io.File;
import java.util.ArrayList;
import java.util.Collections;
import java.util.Comparator;
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
    /** An activity of the app, the intents it takes, and its meta-data. */
    static final class Activity {
        final ActivityInfo info;
        final List<IntentFilter> filters;
        final Bundle metaData;

        Activity(ActivityInfo info, List<IntentFilter> filters, Bundle metaData) {
            this.info = info;
            this.filters = filters;
            this.metaData = metaData;
        }
    }

    final String packageName;
    /** The manifest's version code; 0 for a dex. */
    final long versionCode;
    /** The manifest's version name; null for a dex or a manifest without one. */
    final String versionName;
    final String sourcePath;
    final int width;
    final int height;
    /** The launcher activity's class. */
    final String activityName;
    /** What the manifest says of the application, without where it's installed. */
    private final ApplicationInfo mApplication;
    private final Map<String, Activity> mActivities = new LinkedHashMap<>();
    /** Its services, by class name, with their meta-data. */
    private final Map<String, android.content.pm.ServiceInfo> mServices = new LinkedHashMap<>();
    /** The permissions the manifest asks for. */
    final List<String> requestedPermissions;
    /** Its split APKs' names and paths (an asset pack is one); none for a dex. */
    private final String[] mSplitNames;
    private final String[] mSplitPaths;

    static volatile MeadApp sCurrent;

    /** A dex's app: one activity, named. */
    MeadApp(String packageName, String activityName, String sourcePath, int width, int height) {
        this.packageName = packageName;
        versionCode = 0;
        versionName = null;
        this.activityName = activityName;
        this.sourcePath = sourcePath;
        this.width = width;
        this.height = height;
        requestedPermissions = Collections.emptyList();
        mSplitNames = mSplitPaths = new String[0];
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
        mActivities.put(activityName, new Activity(activity, Collections.<IntentFilter>emptyList(), null));
    }

    /** An APK's app, from its manifest. */
    MeadApp(PackageParser.Package parsed, String sourcePath, int width, int height) {
        this.packageName = parsed.packageName;
        versionCode = parsed.getLongVersionCode();
        versionName = parsed.mVersionName;
        this.sourcePath = sourcePath;
        this.width = width;
        this.height = height;
        requestedPermissions = new ArrayList<>(parsed.requestedPermissions);
        List<PackageParser.ApkLite> splits = splits(sourcePath, packageName);
        mSplitNames = new String[splits.size()];
        mSplitPaths = new String[splits.size()];
        for (int index = 0; index < splits.size(); index++) {
            mSplitNames[index] = splits.get(index).splitName;
            mSplitPaths[index] = splits.get(index).codePath;
        }
        mApplication = parsed.applicationInfo;
        // The application's meta-data, as GET_META_DATA gives it: Play
        // services' clients look for com.google.android.gms.version there.
        mApplication.metaData = parsed.mAppMetaData;
        for (PackageParser.Service service : parsed.services) {
            android.content.pm.ServiceInfo info = new android.content.pm.ServiceInfo(service.info);
            info.metaData = service.metaData;
            mServices.put(info.name, info);
        }
        String launcher = null;
        for (PackageParser.Activity activity : parsed.activities) {
            List<IntentFilter> filters = new ArrayList<IntentFilter>(activity.intents);
            mActivities.put(activity.info.name, new Activity(activity.info, filters, activity.metaData));
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
        List<String> apks = new ArrayList<>();
        apks.add(sourcePath);
        Collections.addAll(apks, mSplitPaths);
        NativeLibraries.install(apks, new File(dataDir(), "lib"));
    }

    /**
     * An APK's splits, as a bundle's install leaves them beside it: the other
     * APKs in its directory whose manifests name its package and a split,
     * in their names' order, as the package manager keeps them.
     */
    private static List<PackageParser.ApkLite> splits(String sourcePath, String packageName) {
        List<PackageParser.ApkLite> splits = new ArrayList<>();
        File[] files = new File(sourcePath).getParentFile().listFiles();
        if (files == null) return splits;
        for (File file : files) {
            if (!file.getName().endsWith(".apk") || file.getAbsolutePath().equals(sourcePath)) continue;
            try {
                PackageParser.ApkLite lite = PackageParser.parseApkLite(file, 0);
                if (packageName.equals(lite.packageName) && lite.splitName != null) splits.add(lite);
            } catch (PackageParser.PackageParserException e) {
                // Not an APK of its.
            }
        }
        Collections.sort(splits, new Comparator<PackageParser.ApkLite>() {
            @Override
            public int compare(PackageParser.ApkLite left, PackageParser.ApkLite right) {
                return left.splitName.compareTo(right.splitName);
            }
        });
        return splits;
    }

    /**
     * Runs an app as Android does: ActivityThread's main, which attaches to
     * Mead's activity manager, which binds the app and launches its launcher
     * activity. The app's code is the class path's first entry: an APK
     * (arguments: the window's width and height), or a dex (arguments: the
     * package, the activity's class, and the window's width and height). The
     * window is 1280×720 when its size isn't given. MEAD_PROPERTIES sets
     * system properties first ("debug.hwui.profile=true;key=value"), as
     * setprop would. Doesn't return.
     */
    public static void main(String[] args) throws Exception {
        String properties = System.getenv("MEAD_PROPERTIES");
        if (properties != null) {
            for (String property : properties.split(";")) {
                int equals = property.indexOf('=');
                if (equals > 0) SystemProperties.set(property.substring(0, equals), property.substring(equals + 1));
            }
        }
        String sourcePath = new File(System.getProperty("java.class.path").split(":")[0]).getAbsolutePath();
        if (sourcePath.endsWith(".apk")) {
            int width = pixels(args.length >= 2 ? Integer.parseInt(args[0]) : 1280);
            int height = pixels(args.length >= 2 ? Integer.parseInt(args[1]) : 720);
            PackageParser.Package parsed = new PackageParser().parsePackage(new File(sourcePath), 0);
            sCurrent = new MeadApp(parsed, sourcePath, width, height);
        } else {
            if (args.length < 2) {
                throw new IllegalArgumentException(
                        "usage: mead.server.MeadApp [width height] for an APK, or <package> <activity> [width height]");
            }
            int width = pixels(args.length > 3 ? Integer.parseInt(args[2]) : 1280);
            int height = pixels(args.length > 3 ? Integer.parseInt(args[3]) : 720);
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
        // LoadedApk adds splits to the app's resources and class path.
        if (mSplitPaths.length > 0) {
            info.splitNames = mSplitNames.clone();
            info.splitSourceDirs = mSplitPaths.clone();
            info.splitPublicSourceDirs = mSplitPaths.clone();
        }
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
        // Its meta-data, as GET_META_DATA gives it: AppCompat finds an
        // activity's parent there (android.support.PARENT_ACTIVITY).
        info.metaData = activity.metaData;
        if (info.processName == null) info.processName = application.processName;
        return info;
    }

    /**
     * A service, by its class name, with the installed application; null for
     * none. Its meta-data, as GET_META_DATA gives it: Firebase lists its
     * components on ComponentDiscoveryService's.
     */
    android.content.pm.ServiceInfo serviceInfo(String name, ApplicationInfo application) {
        android.content.pm.ServiceInfo service = mServices.get(name);
        if (service == null) return null;
        android.content.pm.ServiceInfo info = new android.content.pm.ServiceInfo(service);
        info.applicationInfo = application;
        info.metaData = service.metaData;
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

    /**
     * A size given in the desktop's logical pixels (the window's size on the
     * command line), in the display's pixels: twice as many on a display
     * scaled twice, whose density is twice too.
     */
    private static int pixels(int logical) {
        return Math.round(logical * DisplayManagerService.density());
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
        // Freeform, with Android's caption on activities, where the
        // compositor draws no decorations; else fullscreen.
        config.windowConfiguration.setWindowingMode(WindowManagerService.wantsCaptions()
                ? WindowConfiguration.WINDOWING_MODE_FREEFORM : WindowConfiguration.WINDOWING_MODE_FULLSCREEN);
        config.windowConfiguration.setActivityType(WindowConfiguration.ACTIVITY_TYPE_STANDARD);
        return config;
    }
}
