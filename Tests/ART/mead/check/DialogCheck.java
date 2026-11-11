package mead.check;

import android.app.Activity;
import android.app.AlertDialog;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.view.View;
import android.view.WindowManager;

// A dialog over an activity, as Android's window manager shows one: the
// AlertDialog's window dims what's under it (FLAG_DIM_BEHIND), which the
// display bridge draws as a dim layer over the activity's window while the
// dialog shows. The dialog shows for a few seconds (the first argument after
// the size, in seconds, when given; 3 otherwise), is dismissed, and the
// activity must still draw afterwards. The dim is the compositor's to show:
// look at the screen to see it.
//
// Run with: mead --dex dialog-check.jar mead.server.MeadApp mead.check mead.check.DialogCheck 640 480
public class DialogCheck extends Activity {
    private int mFailures;

    private void check(String name, Object actual, Object expected) {
        boolean ok = expected.equals(actual);
        if (!ok) mFailures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + actual + (ok ? "" : " (expected " + expected + ")"));
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        final View content = new View(this);
        content.setBackgroundColor(Color.rgb(0x40, 0x90, 0xe0));
        setContentView(content);

        final AlertDialog dialog = new AlertDialog.Builder(this)
                .setTitle("Mead")
                .setMessage("A dialog dims the window under it.")
                .setPositiveButton(android.R.string.ok, null)
                .create();
        final Handler handler = new Handler();
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                dialog.show();
                WindowManager.LayoutParams attrs = dialog.getWindow().getAttributes();
                check("dialog dims behind", (attrs.flags & WindowManager.LayoutParams.FLAG_DIM_BEHIND) != 0, true);
                System.out.println("     dim amount: " + attrs.dimAmount);
                handler.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        check("dialog showing", dialog.isShowing(), true);
                        dialog.dismiss();
                        content.invalidate();
                        handler.postDelayed(new Runnable() {
                            @Override
                            public void run() {
                                check("dialog dismissed", dialog.isShowing(), false);
                                check("activity still attached", content.isAttachedToWindow(), true);
                                System.out.println(mFailures == 0 ? "DialogCheck passed"
                                        : "DialogCheck: " + mFailures + " failed");
                                System.exit(mFailures == 0 ? 0 : 1);
                            }
                        }, 500);
                    }
                }, 3000);
            }
        }, 1000);
    }
}
