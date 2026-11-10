package mead.server;

import android.content.Context;
import android.os.IBinder;
import android.os.ServiceManager;
import java.util.HashMap;
import java.util.Map;

/**
 * Android's system services, as Mead runs them: in the app's own process,
 * as binder objects in ServiceManager's cache, where getService finds them
 * before asking the service manager (which isn't there). The framework's
 * managers then call them directly.
 */
public final class MeadServices {
    private MeadServices() {}

    /** Called by Mead once ART and the framework's JNI are up. */
    public static void start() {
        Map<String, IBinder> services = new HashMap<>();
        services.put(Context.DISPLAY_SERVICE, new DisplayManagerService());
        ServiceManager.initServiceCache(services);
    }
}
