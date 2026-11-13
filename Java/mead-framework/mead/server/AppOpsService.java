package mead.server;

import android.app.AppOpsManager;
import android.os.IBinder;
import com.android.internal.app.IAppOpsCallback;
import mead.server.base.AppOpsServiceBase;

/**
 * Android's app ops for Mead: the one app may do every operation, as an app
 * granted all it asks for.
 */
final class AppOpsService extends AppOpsServiceBase {
    @Override public int checkOperation(int code, int uid, String packageName) { return AppOpsManager.MODE_ALLOWED; }
    @Override public int noteOperation(int code, int uid, String packageName) { return AppOpsManager.MODE_ALLOWED; }
    @Override public int startOperation(IBinder token, int code, int uid, String packageName, boolean startIfModeDefault) {
        return AppOpsManager.MODE_ALLOWED;
    }
    @Override public void finishOperation(IBinder token, int code, int uid, String packageName) {}
    @Override public void startWatchingMode(int op, String packageName, IAppOpsCallback callback) {}
    @Override public void stopWatchingMode(IAppOpsCallback callback) {}
    @Override public int checkAudioOperation(int code, int usage, int uid, String packageName) { return AppOpsManager.MODE_ALLOWED; }
    @Override public int noteProxyOperation(int code, int proxyUid, String proxyPackageName, int callingUid, String callingPackageName) {
        return AppOpsManager.MODE_ALLOWED;
    }
    @Override public int checkPackage(int uid, String packageName) { return AppOpsManager.MODE_ALLOWED; }
}
