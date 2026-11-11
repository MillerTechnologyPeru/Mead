package mead.server;

import android.app.ActivityThread;
import android.app.ContentProviderHolder;
import android.app.IApplicationThread;
import android.app.PendingIntent;
import android.content.IIntentReceiver;
import android.content.IIntentSender;
import android.content.Intent;
import android.content.IntentFilter;
import android.os.IBinder;
import java.util.ArrayList;
import java.util.List;
import android.content.pm.ApplicationInfo;
import android.content.pm.ProviderInfo;
import android.content.res.CompatibilityInfo;
import android.content.res.Configuration;
import android.os.Bundle;
import android.os.RemoteException;
import mead.server.base.ActivityManagerBase;

/**
 * Android's activity manager for Mead: one app, in this process. When its
 * ActivityThread attaches, the app is bound and the activity task manager
 * starts its launcher activity, as ActivityManagerService and
 * ActivityTaskManagerService do for a new process.
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

        MeadServices.sActivityTaskManager.attached(thread, app);
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

    @Override
    public void setRenderThread(int tid) {}

    @Override
    public boolean handleApplicationWtf(android.os.IBinder app, String tag, boolean system,
            android.app.ApplicationErrorReport.ParcelableCrashInfo crashInfo) {
        // Logged already, by the app; nothing kills it here.
        return false;
    }

    // PendingIntents: their senders, one for each distinct request.

    private final List<IntentSender> mIntentSenders = new ArrayList<>();

    @Override
    public IIntentSender getIntentSender(int type, String packageName, IBinder token, String resultWho,
            int requestCode, Intent[] intents, String[] resolvedTypes, int flags, Bundle options, int userId) {
        if (intents == null || intents.length == 0) return null;
        Intent intent = intents[intents.length - 1];
        String resolvedType = resolvedTypes != null ? resolvedTypes[resolvedTypes.length - 1] : null;
        synchronized (mIntentSenders) {
            for (IntentSender sender : mIntentSenders) {
                if (!sender.canceled && sender.matches(type, packageName, requestCode, intent)) {
                    if ((flags & PendingIntent.FLAG_CANCEL_CURRENT) != 0) {
                        sender.canceled = true;
                        break;
                    }
                    if ((flags & PendingIntent.FLAG_UPDATE_CURRENT) != 0) sender.intent = new Intent(intent);
                    return sender;
                }
            }
            if ((flags & PendingIntent.FLAG_NO_CREATE) != 0) return null;
            IntentSender sender = new IntentSender(type, packageName, requestCode, new Intent(intent), resolvedType);
            mIntentSenders.add(sender);
            return sender;
        }
    }

    @Override
    public void cancelIntentSender(IIntentSender sender) {
        if (sender instanceof IntentSender) {
            synchronized (mIntentSenders) {
                ((IntentSender) sender).canceled = true;
                mIntentSenders.remove(sender);
            }
        }
    }

    @Override
    public String getPackageForIntentSender(IIntentSender sender) {
        return sender instanceof IntentSender ? ((IntentSender) sender).packageName : null;
    }

    @Override
    public int getUidForIntentSender(IIntentSender sender) {
        return android.os.Process.myUid();
    }

    @Override
    public boolean isIntentSenderAnActivity(IIntentSender sender) {
        return sender instanceof IntentSender
                && ((IntentSender) sender).type == android.app.ActivityManager.INTENT_SENDER_ACTIVITY;
    }

    @Override
    public Intent getIntentForIntentSender(IIntentSender sender) {
        return sender instanceof IntentSender ? new Intent(((IntentSender) sender).intent) : null;
    }

    // Broadcasts: to the receivers the app registers.

    private static final class Receiver {
        final IIntentReceiver receiver;
        final IntentFilter filter;

        Receiver(IIntentReceiver receiver, IntentFilter filter) {
            this.receiver = receiver;
            this.filter = filter;
        }
    }

    private final List<Receiver> mReceivers = new ArrayList<>();

    @Override
    public Intent registerReceiver(IApplicationThread caller, String callerPackage, IIntentReceiver receiver,
            IntentFilter filter, String requiredPermission, int userId, int flags) {
        if (receiver != null) {
            synchronized (mReceivers) {
                mReceivers.add(new Receiver(receiver, filter));
            }
        }
        // No sticky broadcasts.
        return null;
    }

    @Override
    public void unregisterReceiver(IIntentReceiver receiver) {
        synchronized (mReceivers) {
            for (int i = mReceivers.size() - 1; i >= 0; i--) {
                if (mReceivers.get(i).receiver.asBinder() == receiver.asBinder()) mReceivers.remove(i);
            }
        }
    }

    @Override
    public int broadcastIntent(IApplicationThread caller, Intent intent, String resolvedType,
            IIntentReceiver resultTo, int resultCode, String resultData, Bundle map, String[] requiredPermissions,
            int appOp, Bundle options, boolean serialized, boolean sticky, int userId) {
        broadcast(intent);
        return android.app.ActivityManager.BROADCAST_SUCCESS;
    }

    /** Delivers a broadcast to the registered receivers its filters match. */
    void broadcast(Intent intent) {
        List<IIntentReceiver> matching = new ArrayList<>();
        synchronized (mReceivers) {
            for (Receiver receiver : mReceivers) {
                if (receiver.filter.match(intent.getAction(), intent.getType(), intent.getScheme(), intent.getData(),
                        intent.getCategories(), "Mead") >= 0) {
                    matching.add(receiver.receiver);
                }
            }
        }
        for (IIntentReceiver receiver : matching) {
            try {
                receiver.performReceive(new Intent(intent), 0, null, null, false, false, 0);
            } catch (RemoteException e) {
                // The receiver is in this process.
            }
        }
    }
}
