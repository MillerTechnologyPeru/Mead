package mead.server;

import android.app.job.IJobScheduler;
import android.app.job.JobInfo;
import android.app.job.JobScheduler;
import android.app.job.JobSnapshot;
import android.app.job.JobWorkItem;
import android.content.pm.ParceledListSlice;
import android.util.Log;
import java.util.ArrayList;
import java.util.Collections;
import java.util.LinkedHashMap;
import java.util.List;
import java.util.Map;

/**
 * Android's job scheduler for Mead: it keeps the app's jobs, by ID, as a
 * phone's does, so the app sees what it scheduled; it doesn't run them yet
 * (Mead doesn't host an app's own services, which a JobService is). Like
 * the alarm manager's alarms, each job is said once in the log.
 */
final class JobSchedulerService extends IJobScheduler.Stub {
    private static final String TAG = "MeadJobs";

    private final Map<Integer, JobInfo> mJobs = new LinkedHashMap<>();

    @Override
    public int schedule(JobInfo job) {
        if (job == null) throw new NullPointerException("job == null");
        JobInfo previous;
        synchronized (mJobs) {
            previous = mJobs.put(job.getId(), job);
        }
        if (previous == null) {
            Log.i(TAG, "Job " + job.getId() + " for " + job.getService().flattenToShortString()
                    + (job.isPeriodic() ? ", every " + job.getIntervalMillis() + " ms" : "")
                    + " is scheduled; jobs aren't run yet");
        }
        return JobScheduler.RESULT_SUCCESS;
    }

    /** Work for a job: the job's kept; its work items would be its to dequeue when it ran. */
    @Override
    public int enqueue(JobInfo job, JobWorkItem work) {
        return schedule(job);
    }

    @Override
    public int scheduleAsPackage(JobInfo job, String packageName, int userId, String tag) {
        return schedule(job);
    }

    @Override
    public void cancel(int jobId) {
        synchronized (mJobs) {
            mJobs.remove(jobId);
        }
    }

    @Override
    public void cancelAll() {
        synchronized (mJobs) {
            mJobs.clear();
        }
    }

    @Override
    public ParceledListSlice getAllPendingJobs() {
        synchronized (mJobs) {
            return new ParceledListSlice<>(new ArrayList<>(mJobs.values()));
        }
    }

    @Override
    public JobInfo getPendingJob(int jobId) {
        synchronized (mJobs) {
            return mJobs.get(jobId);
        }
    }

    @Override
    public List<JobInfo> getStartedJobs() {
        return Collections.emptyList();
    }

    /** The jobs, none of them runnable: nothing runs them. */
    @Override
    public ParceledListSlice getAllJobSnapshots() {
        List<JobSnapshot> snapshots = new ArrayList<>();
        synchronized (mJobs) {
            for (JobInfo job : mJobs.values()) snapshots.add(new JobSnapshot(job, 0, false));
        }
        return new ParceledListSlice<>(snapshots);
    }
}
