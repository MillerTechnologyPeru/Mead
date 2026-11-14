import android.app.job.IJobScheduler;
import android.app.job.JobInfo;
import android.app.job.JobScheduler;
import android.app.job.JobSnapshot;
import android.content.ComponentName;
import android.os.ServiceManager;
import java.util.List;
import java.util.Objects;

// Mead's job scheduler (mead.server.JobSchedulerService), through its
// binder as JobSchedulerImpl calls it: jobs are kept by ID, replaced,
// listed and cancelled; none is started, and none is runnable. Run it on
// Mead with mead-framework.jar.
public class JobSchedulerCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    public static void main(String[] args) throws Exception {
        IJobScheduler scheduler = IJobScheduler.Stub.asInterface(ServiceManager.getService("jobscheduler"));
        check("service", scheduler != null, true);
        ComponentName service = new ComponentName("mead.check", "mead.check.CheckJobService");

        JobInfo once = new JobInfo.Builder(1, service).setMinimumLatency(60000).build();
        JobInfo periodic = new JobInfo.Builder(2, service).setPeriodic(15 * 60 * 1000L).build();
        check("schedule", scheduler.schedule(once), JobScheduler.RESULT_SUCCESS);
        check("schedule periodic", scheduler.schedule(periodic), JobScheduler.RESULT_SUCCESS);
        check("pending", scheduler.getAllPendingJobs().getList().size(), 2);
        check("pending job", scheduler.getPendingJob(2).isPeriodic(), true);

        JobInfo replacement = new JobInfo.Builder(1, service).setMinimumLatency(120000).build();
        scheduler.schedule(replacement);
        check("replaced", scheduler.getPendingJob(1).getMinLatencyMillis(), 120000L);
        check("still two", scheduler.getAllPendingJobs().getList().size(), 2);

        check("started", scheduler.getStartedJobs().size(), 0);
        @SuppressWarnings("unchecked")
        List<JobSnapshot> snapshots = scheduler.getAllJobSnapshots().getList();
        check("snapshots", snapshots.size(), 2);
        check("not runnable", snapshots.get(0).isRunnable(), false);

        scheduler.cancel(1);
        check("cancelled", scheduler.getPendingJob(1), null);
        scheduler.cancelAll();
        check("all cancelled", scheduler.getAllPendingJobs().getList().size(), 0);

        System.out.println(failures == 0 ? "JobSchedulerCheck: all passed" : "JobSchedulerCheck: " + failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
