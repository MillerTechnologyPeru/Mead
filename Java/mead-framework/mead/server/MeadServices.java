package mead.server;

import android.content.Context;
import android.os.IBinder;
import android.os.ServiceManager;
import android.util.Log;
import java.lang.reflect.Field;
import java.util.HashMap;
import java.util.HashSet;
import java.util.Map;
import java.util.Set;

/**
 * Android's system services, as Mead runs them: in the app's own process,
 * in a service manager of Mead's (ServiceManagerService), which
 * ServiceManager uses in place of Android's. The framework's managers then
 * call them directly.
 */
public final class MeadServices {
    private static final String TAG = "Mead";
    private static final Set<String> sUnimplemented = new HashSet<>();

    /** The activity task manager, which the activity manager starts the app's activities through. */
    static final ActivityTaskManagerService sActivityTaskManager = new ActivityTaskManagerService();

    /** The activity manager, which broadcasts for PendingIntents. */
    static final ActivityManagerService sActivityManager = new ActivityManagerService();
    static final ThermalService sThermal = new ThermalService();

    private MeadServices() {}

    /** A service method Mead doesn't do was called: said once in the log. */
    public static void unimplemented(String method) {
        synchronized (sUnimplemented) {
            if (!sUnimplemented.add(method)) return;
        }
        Log.w(TAG, "Not implemented: " + method);
    }

    /** Called by Mead once ART and the framework's JNI are up. */
    public static void start() {
        // ServiceManager's own service manager, in place of the one it would
        // reach through binder's context object.
        ServiceManagerService serviceManager = new ServiceManagerService();
        try {
            Field field = ServiceManager.class.getDeclaredField("sServiceManager");
            field.setAccessible(true);
            field.set(null, serviceManager);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("ServiceManager has no sServiceManager to set", e);
        }
        Map<String, IBinder> services = new HashMap<>();
        services.put(Context.DISPLAY_SERVICE, new DisplayManagerService());
        services.put(Context.ACTIVITY_SERVICE, sActivityManager);
        services.put(Context.ACTIVITY_TASK_SERVICE, sActivityTaskManager);
        services.put(Context.WINDOW_SERVICE, new WindowManagerService());
        services.put(Context.INPUT_METHOD_SERVICE, new InputMethodManagerService());
        services.put("package", new PackageManagerService());
        services.put(Context.APP_OPS_SERVICE, new AppOpsService());
        services.put(Context.INPUT_SERVICE, new InputManagerService());
        services.put(Context.AUDIO_SERVICE, new AudioService());
        services.put(Context.USER_SERVICE, new UserManagerService());
        services.put(Context.NOTIFICATION_SERVICE, new NotificationManagerService());
        services.put(Context.ALARM_SERVICE, new AlarmManagerService());
        services.put(Context.POWER_SERVICE, new PowerManagerService());
        services.put(android.content.ContentResolver.CONTENT_SERVICE_NAME, new ContentService());
        services.put(Context.APPWIDGET_SERVICE, new AppWidgetService());
        services.put("mount", new StorageManagerService());
        services.put(Context.WIFI_SERVICE, new WifiManagerService());
        services.put(Context.MEDIA_SESSION_SERVICE, new MediaSessionService());
        services.put(Context.CONNECTIVITY_SERVICE, new ConnectivityService());
        services.put(Context.THERMAL_SERVICE, sThermal);
        for (Map.Entry<String, IBinder> service : services.entrySet()) {
            ServiceManager.addService(service.getKey(), service.getValue());
        }
        // Power saving, the screen and thermals change on the host.
        HostWatcher.start();
        // WebViews are WPE WebKit's, where a phone's are Chromium's.
        mead.webkit.MeadWebViewFactory.install();
    }
}
