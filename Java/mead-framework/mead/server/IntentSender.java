package mead.server;

import android.app.ActivityManager;
import android.content.IIntentReceiver;
import android.content.IIntentSender;
import android.content.Intent;
import android.os.Bundle;
import android.os.IBinder;
import android.util.Log;

/**
 * A PendingIntent's sender, as Mead's activity manager keeps one: what to
 * do (start an activity, broadcast or start a service) with which intent,
 * for the app. Sending one for an activity starts it in the app; a
 * broadcast goes to the app's registered receivers; services aren't run
 * yet, and are logged.
 */
final class IntentSender extends IIntentSender.Stub {
    private static final String TAG = "MeadIntents";

    final int type;
    final String packageName;
    final int requestCode;
    Intent intent;
    final String resolvedType;
    boolean canceled;

    IntentSender(int type, String packageName, int requestCode, Intent intent, String resolvedType) {
        this.type = type;
        this.packageName = packageName;
        this.requestCode = requestCode;
        this.intent = intent;
        this.resolvedType = resolvedType;
    }

    /** Whether this is the sender for the same request: PendingIntent's equality. */
    boolean matches(int type, String packageName, int requestCode, Intent intent) {
        return this.type == type && this.packageName.equals(packageName) && this.requestCode == requestCode
                && this.intent.filterEquals(intent);
    }

    @Override
    public void send(int code, Intent fillIn, String resolvedType, IBinder whitelistToken,
            IIntentReceiver finishedReceiver, String requiredPermission, Bundle options) {
        if (canceled) return;
        Intent sent = new Intent(intent);
        if (fillIn != null) sent.fillIn(fillIn, 0);
        switch (type) {
            case ActivityManager.INTENT_SENDER_ACTIVITY:
                sent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
                MeadServices.sActivityTaskManager.startActivity(null, packageName, sent, this.resolvedType, null,
                        null, -1, 0, null, options);
                break;
            case ActivityManager.INTENT_SENDER_BROADCAST:
                MeadServices.sActivityManager.broadcast(sent);
                break;
            default:
                Log.i(TAG, "Services aren't run yet: " + sent);
                break;
        }
    }
}
