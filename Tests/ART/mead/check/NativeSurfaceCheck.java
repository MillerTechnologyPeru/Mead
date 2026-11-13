package mead.check;

import android.app.Activity;
import android.graphics.Color;
import android.os.Bundle;
import android.os.Handler;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;
import java.io.File;

// Native code on SurfaceViews' surfaces, as a game's or a video player's:
// libfixture_surface.so takes each surface's ANativeWindow with
// ANativeWindow_fromSurface. It fills the left one on the CPU, red, through
// ANativeWindow_lock, and draws the right one with EGL and GLES on the
// default display, green, reading a pixel back. Each must answer at the
// surface's size; that they show is the compositor's to do: look at the
// screen, which keeps them for four seconds.
//
// Run from the directory holding libfixture_surface.so with:
//   mead --dex native-surface-check.jar mead.server.MeadApp mead.check mead.check.NativeSurfaceCheck 640 480
public class NativeSurfaceCheck extends Activity {
    static native String fill(android.view.Surface surface, int color);

    static native String draw(android.view.Surface surface, float red, float green, float blue, int frames);

    private int mFailures;
    private String mFilled;
    private String mDrawn;
    private final Handler mHandler = new Handler();

    private void check(String name, Object actual, Object expected) {
        boolean ok = expected.equals(actual);
        if (!ok) mFailures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + actual + (ok ? "" : " (expected " + expected + ")"));
    }

    private FrameLayout labeled(SurfaceView view, String text, int size) {
        FrameLayout frame = new FrameLayout(this);
        frame.addView(view, new FrameLayout.LayoutParams(size, size));
        TextView label = new TextView(this);
        label.setText(text);
        label.setTextColor(Color.WHITE);
        label.setTextSize(16);
        frame.addView(label, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        return frame;
    }

    private abstract static class Changed implements SurfaceHolder.Callback {
        @Override
        public void surfaceCreated(SurfaceHolder holder) {
        }

        @Override
        public void surfaceDestroyed(SurfaceHolder holder) {
        }
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        System.load(new File("libfixture_surface.so").getAbsolutePath());
        LinearLayout root = new LinearLayout(this);
        root.setBackgroundColor(Color.WHITE);
        root.setGravity(Gravity.CENTER);
        float density = getResources().getDisplayMetrics().density;
        final int size = Math.round(200 * density);

        SurfaceView filled = new SurfaceView(this);
        filled.getHolder().addCallback(new Changed() {
            @Override
            public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
                if (mFilled == null) mFilled = fill(holder.getSurface(), 0xd02020);
            }
        });
        root.addView(labeled(filled, "ANativeWindow_lock", size));

        SurfaceView drawn = new SurfaceView(this);
        drawn.getHolder().addCallback(new Changed() {
            @Override
            public void surfaceChanged(SurfaceHolder holder, int format, int width, int height) {
                if (mDrawn == null) mDrawn = draw(holder.getSurface(), 0x20 / 255f, 0xc0 / 255f, 0x40 / 255f, 30);
            }
        });
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(size, size);
        params.leftMargin = Math.round(16 * density);
        root.addView(labeled(drawn, "EGL", size), params);
        setContentView(root);

        mHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                check("ANativeWindow_lock", mFilled,
                        "window " + size + "x" + size + ", buffer " + size + "x" + size + " format 1, posted 0");
                check("EGL", mDrawn, "surface " + size + "x" + size + ", middle 20c040, swapped yes");
                System.out.println(mFailures == 0 ? "NativeSurfaceCheck passed" : "NativeSurfaceCheck: " + mFailures + " failed");
                System.exit(mFailures == 0 ? 0 : 1);
            }
        }, 4000);
    }
}
