package mead.server;

import android.content.ComponentName;
import android.content.Intent;
import android.content.IntentFilter;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.FeatureInfo;
import android.content.pm.PackageInfo;
import android.content.pm.PackageManager;
import android.content.pm.ParceledListSlice;
import android.content.pm.ResolveInfo;
import android.os.Process;
import java.util.ArrayList;
import java.io.File;
import java.util.Arrays;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import mead.server.base.PackageManagerBase;

/**
 * Android's package manager for Mead: the one app installed, Mead's, with
 * every permission it asks for, on a device with a touchscreen, keys and
 * gamepads.
 */
final class PackageManagerService extends PackageManagerBase {
    /** What this device has, as PackageManager's FEATURE_* names, with their versions. */
    private static final Map<String, Integer> FEATURES = features();

    private static Map<String, Integer> features() {
        Map<String, Integer> features = new HashMap<>();
        for (String name : Arrays.asList(
                PackageManager.FEATURE_TOUCHSCREEN,
                PackageManager.FEATURE_TOUCHSCREEN_MULTITOUCH,
                PackageManager.FEATURE_TOUCHSCREEN_MULTITOUCH_DISTINCT,
                PackageManager.FEATURE_FAKETOUCH,
                PackageManager.FEATURE_SCREEN_LANDSCAPE,
                PackageManager.FEATURE_SCREEN_PORTRAIT,
                PackageManager.FEATURE_GAMEPAD,
                PackageManager.FEATURE_AUDIO_OUTPUT)) {
            features.put(name, 0);
        }
        // Vulkan where the host has a driver, as an Android 10 device lists
        // it: level 1, version 1.1 (what Mead's libvulkan reports to apps),
        // no extra compute. Unreal picks its Vulkan renderer by these.
        if (hasVulkanDriver()) {
            features.put(PackageManager.FEATURE_VULKAN_HARDWARE_LEVEL, 1);
            features.put(PackageManager.FEATURE_VULKAN_HARDWARE_VERSION, 0x401000);
            features.put(PackageManager.FEATURE_VULKAN_HARDWARE_COMPUTE, 0);
        }
        return features;
    }

    /** Whether the host's Vulkan loader has a driver to load (an ICD manifest). */
    private static boolean hasVulkanDriver() {
        for (String directory : new String[] {"/usr/share/vulkan/icd.d", "/etc/vulkan/icd.d",
                "/usr/local/share/vulkan/icd.d"}) {
            String[] manifests = new File(directory).list();
            if (manifests != null) {
                for (String manifest : manifests) {
                    if (manifest.endsWith(".json")) return true;
                }
            }
        }
        return false;
    }

    private static MeadApp app(String packageName) {
        MeadApp app = MeadApp.sCurrent;
        return app != null && app.packageName.equals(packageName) ? app : null;
    }

    @Override
    public PackageInfo getPackageInfo(String packageName, int flags, int userId) {
        MeadApp app = app(packageName);
        if (app == null) return null;
        PackageInfo info = new PackageInfo();
        info.packageName = packageName;
        info.applicationInfo = app.applicationInfo();
        // The manifest's version, which games name their expansion files by
        // (Unreal's main.<versionCode>.<package>.obb); 1 for a dex.
        info.versionName = app.versionName != null ? app.versionName : "1";
        info.setLongVersionCode(app.versionCode > 0 ? app.versionCode : 1);
        if ((flags & PackageManager.GET_ACTIVITIES) != 0) {
            info.activities = app.activityInfos(info.applicationInfo).toArray(new ActivityInfo[0]);
        }
        if ((flags & PackageManager.GET_PERMISSIONS) != 0 && !app.requestedPermissions.isEmpty()) {
            info.requestedPermissions = app.requestedPermissions.toArray(new String[0]);
            info.requestedPermissionsFlags = new int[info.requestedPermissions.length];
            Arrays.fill(info.requestedPermissionsFlags, PackageInfo.REQUESTED_PERMISSION_GRANTED);
        }
        return info;
    }

    @Override
    public int getPackageUid(String packageName, int flags, int userId) {
        return app(packageName) != null ? Process.myUid() : -1;
    }

    @Override
    public ApplicationInfo getApplicationInfo(String packageName, int flags, int userId) {
        MeadApp app = app(packageName);
        return app != null ? app.applicationInfo() : null;
    }

    @Override
    public ActivityInfo getActivityInfo(ComponentName component, int flags, int userId) {
        MeadApp app = app(component.getPackageName());
        return app != null ? app.activityInfo(component.getClassName(), app.applicationInfo()) : null;
    }

    @Override
    public android.content.pm.ServiceInfo getServiceInfo(ComponentName component, int flags, int userId) {
        MeadApp app = app(component.getPackageName());
        return app != null ? app.serviceInfo(component.getClassName(), app.applicationInfo()) : null;
    }

    @Override
    public ResolveInfo resolveIntent(Intent intent, String resolvedType, int flags, int userId) {
        MeadApp app = MeadApp.sCurrent;
        ActivityInfo activity = app != null ? app.resolveActivity(intent, resolvedType) : null;
        if (activity == null) return null;
        ResolveInfo info = new ResolveInfo();
        info.activityInfo = activity;
        info.match = IntentFilter.MATCH_CATEGORY_EMPTY;
        return info;
    }

    @Override
    public ParceledListSlice queryIntentActivities(Intent intent, String resolvedType, int flags, int userId) {
        ResolveInfo info = resolveIntent(intent, resolvedType, flags, userId);
        List<ResolveInfo> infos = new ArrayList<>();
        if (info != null) infos.add(info);
        return new ParceledListSlice<>(infos);
    }

    @Override
    public String[] getPackagesForUid(int uid) {
        MeadApp app = MeadApp.sCurrent;
        return app != null && uid == Process.myUid() ? new String[] {app.packageName} : null;
    }

    @Override
    public String getNameForUid(int uid) {
        String[] packages = getPackagesForUid(uid);
        return packages != null ? packages[0] : null;
    }

    @Override
    public int checkPermission(String permission, String packageName, int userId) {
        return app(packageName) != null ? PackageManager.PERMISSION_GRANTED : PackageManager.PERMISSION_DENIED;
    }

    @Override
    public boolean hasSystemFeature(String name, int version) {
        Integer available = FEATURES.get(name);
        return available != null && version <= available;
    }

    @Override
    public ParceledListSlice getSystemAvailableFeatures() {
        List<FeatureInfo> features = new ArrayList<>();
        for (Map.Entry<String, Integer> entry : FEATURES.entrySet()) {
            FeatureInfo feature = new FeatureInfo();
            feature.name = entry.getKey();
            feature.version = entry.getValue();
            features.add(feature);
        }
        return new ParceledListSlice<>(features);
    }

    @Override
    public String getInstallerPackageName(String packageName) {
        return null;
    }

    @Override
    public int getComponentEnabledSetting(ComponentName component, int userId) {
        return PackageManager.COMPONENT_ENABLED_STATE_DEFAULT;
    }

    @Override
    public int getApplicationEnabledSetting(String packageName, int userId) {
        return PackageManager.COMPONENT_ENABLED_STATE_DEFAULT;
    }

    @Override
    public boolean isSafeMode() {
        return false;
    }
}
