package mead.server;

import android.os.Binder;
import android.os.IBinder;
import android.os.IPermissionController;
import android.os.IServiceManager;
import java.util.Map;
import java.util.TreeMap;

/**
 * Android's service manager for Mead: the services in this process, by
 * name. On Android it's a process of its own, reached through binder's
 * context object; here there's no binder driver, so ServiceManager is
 * given this one directly.
 */
final class ServiceManagerService extends Binder implements IServiceManager {
    private final Map<String, IBinder> mServices = new TreeMap<>();

    @Override
    public IBinder asBinder() {
        return this;
    }

    @Override
    public IBinder getService(String name) {
        return checkService(name);
    }

    @Override
    public IBinder checkService(String name) {
        synchronized (mServices) {
            return mServices.get(name);
        }
    }

    @Override
    public void addService(String name, IBinder service, boolean allowIsolated, int dumpPriority) {
        synchronized (mServices) {
            mServices.put(name, service);
        }
    }

    @Override
    public String[] listServices(int dumpPriority) {
        synchronized (mServices) {
            return mServices.keySet().toArray(new String[0]);
        }
    }

    @Override
    public void setPermissionController(IPermissionController controller) {}
}
