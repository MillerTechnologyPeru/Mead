package mead.check;

import android.app.Activity;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.os.Bundle;
import android.os.Handler;
import android.view.Gravity;
import android.view.SurfaceHolder;
import android.view.SurfaceView;
import android.widget.FrameLayout;
import android.widget.LinearLayout;
import android.widget.TextView;

// SurfaceViews, as a video player's or a game's: each one's surface is a layer
// in the activity's window, which the display bridge shows as a subsurface
// under the window's content, through the hole the view hierarchy leaves.
// The left one's buffer is the view's size; the right one's is half that, by
// setFixedSize, which its layer's matrix scales up to the view. The check
// draws frames into both with lockCanvas, a moving bar on blue, under labels
// the window draws over them, for four seconds. Each surface must be created
// at its size and take frames; that they show, the right one as big as the
// left with a blurrier bar, is the compositor's to do: look at the screen.
//
// Run with: mead --dex surfaceview-check.jar mead.server.MeadApp mead.check mead.check.SurfaceViewCheck 640 480
public class SurfaceViewCheck extends Activity {
    private int mFailures;
    private final Handler mHandler = new Handler();

    private void check(String name, Object actual, Object expected) {
        boolean ok = expected.equals(actual);
        if (!ok) mFailures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + actual + (ok ? "" : " (expected " + expected + ")"));
    }

    // A SurfaceView drawn into every 16 ms while its surface lasts.
    private class Drawn implements SurfaceHolder.Callback {
        final String mName;
        final SurfaceView mView;
        boolean mCreated;
        int mFrames;

        Drawn(String name, SurfaceView view) {
            mName = name;
            mView = view;
            view.getHolder().addCallback(this);
        }

        @Override
        public void surfaceCreated(SurfaceHolder holder) {
            mCreated = true;
            check(mName + " surface valid", holder.getSurface().isValid(), true);
        }

        @Override
        public void surfaceChanged(final SurfaceHolder holder, int format, int width, int height) {
            System.out.println("     " + mName + " surface " + width + "x" + height + ", format " + format);
            mHandler.post(new Runnable() {
                @Override
                public void run() {
                    if (!mCreated) return;
                    draw(holder);
                    mHandler.postDelayed(this, 16);
                }
            });
        }

        @Override
        public void surfaceDestroyed(SurfaceHolder holder) {
            mCreated = false;
        }

        private void draw(SurfaceHolder holder) {
            Canvas canvas = holder.lockCanvas();
            if (canvas == null) return;
            Rect frame = holder.getSurfaceFrame();
            canvas.drawColor(Color.rgb(0x20, 0x60, 0xd0));
            Paint paint = new Paint();
            paint.setColor(Color.rgb(0xf0, 0xa0, 0x20));
            int bar = frame.width() / 8;
            int x = (mFrames * frame.width() / 100) % Math.max(frame.width() - bar, 1);
            canvas.drawRect(x, 0, x + bar, frame.height(), paint);
            holder.unlockCanvasAndPost(canvas);
            mFrames++;
        }

        void finish(int width, int height) {
            check(mName + " surface created", mCreated, true);
            Rect frame = mView.getHolder().getSurfaceFrame();
            check(mName + " surface size", frame.width() + "x" + frame.height(), width + "x" + height);
            check(mName + " frames drawn", mFrames > 10, true);
            System.out.println("     " + mName + " frames: " + mFrames);
        }
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

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        LinearLayout root = new LinearLayout(this);
        root.setBackgroundColor(Color.WHITE);
        root.setGravity(Gravity.CENTER);
        float density = getResources().getDisplayMetrics().density;
        final int size = Math.round(200 * density);
        final int gap = Math.round(16 * density);

        SurfaceView plain = new SurfaceView(this);
        final Drawn left = new Drawn("view-sized", plain);
        root.addView(labeled(plain, "SurfaceView", size));

        SurfaceView fixed = new SurfaceView(this);
        fixed.getHolder().setFixedSize(size / 2, size / 2);
        final Drawn right = new Drawn("fixed-size", fixed);
        FrameLayout rightFrame = labeled(fixed, "setFixedSize", size);
        LinearLayout.LayoutParams params = new LinearLayout.LayoutParams(size, size);
        params.leftMargin = gap;
        root.addView(rightFrame, params);
        setContentView(root);

        mHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                left.finish(size, size);
                right.finish(size / 2, size / 2);
                System.out.println(mFailures == 0 ? "SurfaceViewCheck passed" : "SurfaceViewCheck: " + mFailures + " failed");
                System.exit(mFailures == 0 ? 0 : 1);
            }
        }, 4000);
    }
}
