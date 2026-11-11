package mead.server;

import android.app.AlarmManager;
import android.app.IAlarmListener;
import android.app.PendingIntent;
import android.os.WorkSource;
import android.util.Log;
import mead.server.base.AlarmManagerBase;

/**
 * Android's alarm manager for Mead: alarms set are logged and not yet
 * fired; the time and time zone are the system's to set.
 */
final class AlarmManagerService extends AlarmManagerBase {
    private static final String TAG = "MeadAlarms";

    @Override
    public void set(String callingPackage, int type, long triggerAtTime, long windowLength, long interval, int flags,
            PendingIntent operation, IAlarmListener listener, String listenerTag, WorkSource workSource,
            AlarmManager.AlarmClockInfo alarmClock) {
        Log.i(TAG, callingPackage + " sets an alarm (type " + type + ") at " + triggerAtTime
                + (interval > 0 ? ", every " + interval + " ms" : "") + "; alarms aren't fired yet");
    }

    @Override public void remove(PendingIntent operation, IAlarmListener listener) {}
    @Override public boolean setTime(long millis) { return false; }
    @Override public void setTimeZone(String zone) {}
    @Override public AlarmManager.AlarmClockInfo getNextAlarmClock(int userId) { return null; }
    @Override public long currentNetworkTimeMillis() { return System.currentTimeMillis(); }
}
