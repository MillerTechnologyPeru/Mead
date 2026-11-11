package mead.server;

import android.app.Notification;
import android.app.NotificationChannel;
import android.app.NotificationChannelGroup;
import android.content.pm.ParceledListSlice;
import android.service.notification.StatusBarNotification;
import android.util.Log;
import java.util.ArrayList;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;
import mead.server.base.NotificationManagerBase;

/**
 * Android's notification manager for Mead: notifications are enabled, and
 * each one posted is logged (there's no shade to show it in yet); channels
 * are kept as the app makes them.
 */
final class NotificationManagerService extends NotificationManagerBase {
    private static final String TAG = "MeadNotifications";
    private final Map<String, NotificationChannel> mChannels = new LinkedHashMap<>();

    @Override
    public void enqueueNotificationWithTag(String pkg, String opPkg, String tag, int id, Notification notification,
            int userId) {
        CharSequence title = notification.extras.getCharSequence(Notification.EXTRA_TITLE);
        CharSequence text = notification.extras.getCharSequence(Notification.EXTRA_TEXT);
        Log.i(TAG, pkg + " notifies (" + tag + ", " + id + "): " + title + (text != null ? ": " + text : ""));
    }

    @Override public void cancelNotificationWithTag(String pkg, String tag, int id, int userId) {}
    @Override public void cancelAllNotifications(String pkg, int userId) {}
    @Override public boolean areNotificationsEnabledForPackage(String pkg, int uid) { return true; }
    @Override public boolean areNotificationsEnabled(String pkg) { return true; }
    @Override public void createNotificationChannelGroups(String pkg, ParceledListSlice channelGroupList) {}

    @Override
    @SuppressWarnings("unchecked")
    public void createNotificationChannels(String pkg, ParceledListSlice channelsList) {
        synchronized (mChannels) {
            for (NotificationChannel channel : (List<NotificationChannel>) channelsList.getList()) {
                mChannels.put(channel.getId(), channel);
            }
        }
    }

    @Override
    public NotificationChannel getNotificationChannel(String callingPkg, int userId, String pkg, String channelId) {
        synchronized (mChannels) {
            return mChannels.get(channelId);
        }
    }

    @Override
    public void deleteNotificationChannel(String pkg, String channelId) {
        synchronized (mChannels) {
            mChannels.remove(channelId);
        }
    }

    @Override
    public ParceledListSlice getNotificationChannels(String callingPkg, String targetPkg, int userId) {
        synchronized (mChannels) {
            return new ParceledListSlice<>(new ArrayList<>(mChannels.values()));
        }
    }

    @Override
    public StatusBarNotification[] getActiveNotifications(String callingPkg) {
        return new StatusBarNotification[0];
    }
}
