package mead.server;

import android.app.ActivityThread;
import android.app.ContentProviderHolder;
import android.app.IApplicationThread;
import android.app.servertransaction.ClientTransaction;
import android.app.servertransaction.LaunchActivityItem;
import android.app.servertransaction.ResumeActivityItem;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.pm.ApplicationInfo;
import android.content.pm.ProviderInfo;
import android.content.res.CompatibilityInfo;
import android.content.res.Configuration;
import android.os.Binder;
import android.os.Bundle;
import android.os.RemoteException;
import mead.server.base.ActivityManagerBase;

/**
 * Android's activity manager for Mead: one app, in this process. When its
 * ActivityThread attaches, the app is bound and its launch activity started
 * and resumed, as ActivityManagerService and ActivityTaskManagerService do
 * for a new process.
 */
final class ActivityManagerService extends ActivityManagerBase {
    @Override
    public void attachApplication(IApplicationThread thread, long startSeq) throws RemoteException {
        MeadApp app = MeadApp.sCurrent;
        if (app == null) {
            throw new IllegalStateException("No app to attach: Mead runs one through mead.server.MeadApp");
        }
        ApplicationInfo application = app.applicationInfo();
        Configuration config = app.configuration();
        thread.bindApplication(application.processName, application, null, null, null, null, null, null,
                0, false, false, false, false, config, CompatibilityInfo.DEFAULT_COMPATIBILITY_INFO,
                null, new Bundle(), "unknown", null, null);

        ActivityInfo activity = app.activityInfo(application);
        Intent intent = new Intent(Intent.ACTION_MAIN);
        intent.addCategory(Intent.CATEGORY_LAUNCHER);
        intent.setComponent(new ComponentName(app.packageName, app.activityName));
        Binder token = new Binder();
        ClientTransaction transaction = ClientTransaction.obtain(thread, token);
        transaction.addCallback(LaunchActivityItem.obtain(intent, System.identityHashCode(token), activity,
                config, new Configuration(), CompatibilityInfo.DEFAULT_COMPATIBILITY_INFO, null, null,
                android.app.ActivityManager.PROCESS_STATE_TOP, null, null, null, null, true, null, new Binder()));
        transaction.setLifecycleStateRequest(ResumeActivityItem.obtain(true));
        thread.scheduleTransaction(transaction);
    }

    private SettingsProvider mSettings;

    /** The system's content providers: settings. */
    @Override
    public ContentProviderHolder getContentProvider(IApplicationThread caller, String callingPackage, String name,
            int userId, boolean stable) {
        if (!SettingsProvider.AUTHORITY.equals(name)) return null;
        ProviderInfo info = new ProviderInfo();
        info.authority = SettingsProvider.AUTHORITY;
        info.name = "com.android.providers.settings.SettingsProvider";
        info.packageName = "com.android.providers.settings";
        info.applicationInfo = new ApplicationInfo();
        info.applicationInfo.packageName = info.packageName;
        info.exported = true;
        synchronized (this) {
            if (mSettings == null) {
                mSettings = new SettingsProvider();
                mSettings.attachInfo(ActivityThread.currentApplication(), info);
            }
        }
        ContentProviderHolder holder = new ContentProviderHolder(info);
        holder.provider = mSettings.getIContentProvider();
        holder.noReleaseNeeded = true;
        return holder;
    }
}
