package mead.server;

import android.app.ActivityManager;
import android.app.IApplicationThread;
import android.app.IRequestFinishCallback;
import android.app.ProfilerInfo;
import android.app.ResultInfo;
import android.app.servertransaction.ActivityLifecycleItem;
import android.app.servertransaction.ActivityResultItem;
import android.app.servertransaction.ClientTransaction;
import android.app.servertransaction.ClientTransactionItem;
import android.app.servertransaction.DestroyActivityItem;
import android.app.servertransaction.LaunchActivityItem;
import android.app.servertransaction.PauseActivityItem;
import android.app.servertransaction.ResumeActivityItem;
import android.app.servertransaction.StopActivityItem;
import android.content.ComponentName;
import android.content.Intent;
import android.content.pm.ActivityInfo;
import android.content.res.CompatibilityInfo;
import android.content.res.Configuration;
import android.os.Binder;
import android.os.Bundle;
import android.os.IBinder;
import android.os.PersistableBundle;
import android.os.Process;
import android.os.RemoteException;
import android.util.Log;
import java.util.ArrayList;
import java.util.List;
import mead.server.base.ActivityTaskManagerBase;

/**
 * Android's activity task manager for Mead: the app's one task, a stack of
 * its activities, whose lifecycles it drives through ActivityThread's client
 * transactions as Android's does. Starting an activity pauses the top one,
 * then launches and resumes the new one, then stops the one below once the
 * new one is idle. Finishing pauses the finishing one, resumes the one below
 * (with the result it was waiting for), then destroys the finished one. The
 * app's process ends with its last activity.
 */
final class ActivityTaskManagerService extends ActivityTaskManagerBase {
    private static final String TAG = "MeadActivities";

    /** An activity in the task. */
    private static final class ActivityRecord {
        final IBinder token = new Binder();
        final ActivityInfo info;
        final Intent intent;
        /** The activity waiting for this one's result, and its request. */
        final ActivityRecord resultTo;
        final String resultWho;
        final int requestCode;
        /** Results waiting for this activity's next resume. */
        final List<ResultInfo> results = new ArrayList<>();
        boolean finishing;
        boolean paused;
        boolean stopped;

        ActivityRecord(ActivityInfo info, Intent intent, ActivityRecord resultTo, String resultWho, int requestCode) {
            this.info = info;
            this.intent = intent;
            this.resultTo = resultTo;
            this.resultWho = resultWho;
            this.requestCode = requestCode;
        }
    }

    private IApplicationThread mThread;
    private final List<ActivityRecord> mStack = new ArrayList<>();
    /** The activity to launch once the top one has paused. */
    private ActivityRecord mPendingLaunch;

    /** The app's thread, from its attaching: its launcher activity is started. */
    void attached(IApplicationThread thread, MeadApp app) {
        Intent intent = new Intent(Intent.ACTION_MAIN);
        intent.addCategory(Intent.CATEGORY_LAUNCHER);
        intent.setComponent(new ComponentName(app.packageName, app.activityName));
        ActivityInfo info = app.activityInfo(app.applicationInfo());
        synchronized (this) {
            mThread = thread;
            ActivityRecord record = new ActivityRecord(info, intent, null, null, -1);
            mStack.add(record);
            launch(record);
        }
    }

    private ActivityRecord find(IBinder token) {
        for (ActivityRecord record : mStack) {
            if (record.token == token) return record;
        }
        return null;
    }

    /** The top activity not finishing. */
    private ActivityRecord top() {
        for (int i = mStack.size() - 1; i >= 0; i--) {
            if (!mStack.get(i).finishing) return mStack.get(i);
        }
        return null;
    }

    private void schedule(ActivityRecord record, ClientTransactionItem callback, ActivityLifecycleItem lifecycle) {
        ClientTransaction transaction = ClientTransaction.obtain(mThread, record.token);
        if (callback != null) transaction.addCallback(callback);
        if (lifecycle != null) transaction.setLifecycleStateRequest(lifecycle);
        try {
            mThread.scheduleTransaction(transaction);
        } catch (RemoteException e) {
            // The app is in this process.
        }
    }

    private void launch(ActivityRecord record) {
        Configuration config = MeadApp.sCurrent.configuration();
        schedule(record, LaunchActivityItem.obtain(record.intent, System.identityHashCode(record.token), record.info,
                config, new Configuration(), CompatibilityInfo.DEFAULT_COMPATIBILITY_INFO, null, null,
                ActivityManager.PROCESS_STATE_TOP, null, null, null, null, true, null, new Binder()),
                ResumeActivityItem.obtain(true));
    }

    private void resume(ActivityRecord record) {
        record.paused = false;
        record.stopped = false;
        ClientTransactionItem results = null;
        if (!record.results.isEmpty()) {
            results = ActivityResultItem.obtain(new ArrayList<>(record.results));
            record.results.clear();
        }
        schedule(record, results, ResumeActivityItem.obtain(false));
    }

    private void destroy(ActivityRecord record) {
        schedule(record, null, DestroyActivityItem.obtain(true, 0));
    }

    @Override
    public int startActivity(IApplicationThread caller, String callingPackage, Intent intent, String resolvedType,
            IBinder resultTo, String resultWho, int requestCode, int flags, ProfilerInfo profilerInfo,
            Bundle options) {
        MeadApp app = MeadApp.sCurrent;
        ActivityInfo info = app != null ? app.resolveActivity(intent, resolvedType) : null;
        if (info == null) {
            Log.w(TAG, "Nothing in the app to start for " + intent);
            return ActivityManager.START_INTENT_NOT_RESOLVED;
        }
        Intent started = new Intent(intent);
        started.setComponent(new ComponentName(info.packageName, info.name));
        synchronized (this) {
            ActivityRecord waiting = requestCode >= 0 && resultTo != null ? find(resultTo) : null;
            ActivityRecord record = new ActivityRecord(info, started, waiting, resultWho, requestCode);
            ActivityRecord top = top();
            mStack.add(record);
            if (top == null) {
                launch(record);
            } else {
                mPendingLaunch = record;
                schedule(top, null, PauseActivityItem.obtain(false, true, 0, false));
            }
        }
        return ActivityManager.START_SUCCESS;
    }

    @Override
    public int startActivities(IApplicationThread caller, String callingPackage, Intent[] intents,
            String[] resolvedTypes, IBinder resultTo, Bundle options, int userId) {
        int result = ActivityManager.START_SUCCESS;
        for (int i = 0; i < intents.length; i++) {
            result = startActivity(caller, callingPackage, intents[i],
                    resolvedTypes != null ? resolvedTypes[i] : null, resultTo, null, -1, 0, null, options);
        }
        return result;
    }

    @Override
    public boolean finishActivity(IBinder token, int resultCode, Intent resultData, int finishTask) {
        synchronized (this) {
            ActivityRecord record = find(token);
            if (record == null) return false;
            if (record.finishing) return true;
            record.finishing = true;
            if (record.resultTo != null) {
                record.resultTo.results.add(
                        new ResultInfo(record.resultWho, record.requestCode, resultCode, resultData));
            }
            if (record.paused) {
                destroy(record);
            } else {
                schedule(record, null, PauseActivityItem.obtain(true, false, 0, false));
            }
        }
        return true;
    }

    @Override
    public boolean finishActivityAffinity(IBinder token) {
        return finishActivity(token, android.app.Activity.RESULT_CANCELED, null, 0);
    }

    @Override
    public void activityPaused(IBinder token) {
        synchronized (this) {
            ActivityRecord record = find(token);
            if (record == null) return;
            record.paused = true;
            if (mPendingLaunch != null) {
                ActivityRecord next = mPendingLaunch;
                mPendingLaunch = null;
                launch(next);
            } else if (record.finishing) {
                ActivityRecord below = top();
                if (below != null) resume(below);
                destroy(record);
            }
        }
    }

    @Override
    public void activityResumed(IBinder token) {}

    @Override
    public void activityIdle(IBinder token, Configuration config, boolean stopProfiling) {
        synchronized (this) {
            // What's paused under the top activity is stopped.
            ActivityRecord top = top();
            for (ActivityRecord record : mStack) {
                if (record != top && record.paused && !record.stopped && !record.finishing) {
                    record.stopped = true;
                    schedule(record, null, StopActivityItem.obtain(false, 0));
                }
            }
        }
    }

    @Override
    public void activityStopped(IBinder token, Bundle state, PersistableBundle persistentState,
            CharSequence description) {}

    @Override
    public void activityDestroyed(IBinder token) {
        boolean last;
        synchronized (this) {
            ActivityRecord record = find(token);
            if (record != null) mStack.remove(record);
            last = mStack.isEmpty();
        }
        if (last) {
            // With its last activity gone, the app is done, as on Android
            // only the launcher would be left.
            Log.i(TAG, "The app's last activity has finished");
            Process.killProcess(Process.myPid());
        }
    }

    @Override
    public String getCallingPackage(IBinder token) {
        synchronized (this) {
            ActivityRecord record = find(token);
            return record != null && record.resultTo != null ? record.resultTo.info.packageName : null;
        }
    }

    @Override
    public ComponentName getCallingActivity(IBinder token) {
        synchronized (this) {
            ActivityRecord record = find(token);
            return record != null && record.resultTo != null
                    ? new ComponentName(record.resultTo.info.packageName, record.resultTo.info.name) : null;
        }
    }

    @Override
    public int getTaskForActivity(IBinder token, boolean onlyRoot) {
        synchronized (this) {
            ActivityRecord record = find(token);
            if (record == null || (onlyRoot && record != root())) return -1;
            return 1;
        }
    }

    /** The bottom activity not finishing: the task's root. */
    private ActivityRecord root() {
        for (ActivityRecord record : mStack) {
            if (!record.finishing) return record;
        }
        return null;
    }

    @Override
    public void onBackPressedOnTaskRoot(IBinder token, IRequestFinishCallback callback) {
        // As Android does for a task that isn't the home screen's: Back on
        // its root finishes it.
        try {
            callback.requestFinish();
        } catch (RemoteException e) {
            // The app is in this process.
        }
    }

    @Override
    public boolean isTopOfTask(IBinder token) {
        synchronized (this) {
            ActivityRecord top = top();
            return top != null && top.token == token;
        }
    }

    @Override
    public ComponentName getActivityClassForToken(IBinder token) {
        synchronized (this) {
            ActivityRecord record = find(token);
            return record != null ? new ComponentName(record.info.packageName, record.info.name) : null;
        }
    }

    @Override
    public String getPackageForToken(IBinder token) {
        synchronized (this) {
            ActivityRecord record = find(token);
            return record != null ? record.info.packageName : null;
        }
    }

    @Override
    public boolean willActivityBeVisible(IBinder token) {
        return isTopOfTask(token);
    }

    @Override
    public boolean shouldUpRecreateTask(IBinder token, String destAffinity) {
        return false;
    }

    @Override
    public boolean navigateUpTo(IBinder token, Intent destIntent, int resultCode, Intent resultData) {
        // Up finishes activities until the one asked for is on top.
        ComponentName destination = destIntent.getComponent();
        List<ActivityRecord> finishing = new ArrayList<>();
        synchronized (this) {
            int index = mStack.indexOf(find(token));
            if (index < 0) return false;
            int target = -1;
            for (int i = index - 1; i >= 0; i--) {
                // An alias's activity answers to its target's name too.
                ActivityInfo info = mStack.get(i).info;
                String name = destination != null ? destination.getClassName() : null;
                if (name == null || info.name.equals(name) || name.equals(info.targetActivity)) {
                    target = i;
                    break;
                }
            }
            if (target < 0) return false;
            for (int i = mStack.size() - 1; i > target; i--) finishing.add(mStack.get(i));
        }
        for (ActivityRecord record : finishing) {
            boolean self = record.token == token;
            finishActivity(record.token, self ? resultCode : android.app.Activity.RESULT_CANCELED,
                    self ? resultData : null, 0);
        }
        return true;
    }

    @Override
    public int getRequestedOrientation(IBinder token) {
        return ActivityInfo.SCREEN_ORIENTATION_UNSPECIFIED;
    }

    @Override
    public void setRequestedOrientation(IBinder token, int requestedOrientation) {}

    @Override
    public int getActivityDisplayId(IBinder activityToken) {
        return android.view.Display.DEFAULT_DISPLAY;
    }

    @Override
    public void setTaskDescription(IBinder token, ActivityManager.TaskDescription values) {}

    @Override
    public void reportSizeConfigurations(IBinder token, int[] horizontalSizeConfiguration,
            int[] verticalSizeConfigurations, int[] smallestWidthConfigurations) {}

    @Override
    public Bundle getActivityOptions(IBinder token) {
        return null;
    }
}
