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
import android.widget.TextView;

// A SurfaceView, as a video player's or a game's: its surface is a layer in
// the activity's window, which the display bridge shows as a subsurface
// under the window's content, through the hole the view hierarchy leaves.
// The check draws frames into it with lockCanvas, a moving bar on blue,
// under a label the window draws over it, for four seconds. The surface must be created at the view's size and take frames; that it shows
// is the compositor's to do: look at the screen to see it.
//
// Run with: mead --dex surfaceview-check.jar mead.server.MeadApp mead.check mead.check.SurfaceViewCheck 640 480
public class SurfaceViewCheck extends Activity implements SurfaceHolder.Callback {
    private int mFailures;
    private SurfaceView mView;
    private boolean mCreated;
    private int mFrames;
    private final Handler mHandler = new Handler();

    private void check(String name, Object actual, Object expected) {
        boolean ok = expected.equals(actual);
        if (!ok) mFailures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + actual + (ok ? "" : " (expected " + expected + ")"));
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        FrameLayout root = new FrameLayout(this);
        root.setBackgroundColor(Color.WHITE);
        float density = getResources().getDisplayMetrics().density;
        int size = Math.round(200 * density);
        mView = new SurfaceView(this);
        mView.getHolder().addCallback(this);
        root.addView(mView, new FrameLayout.LayoutParams(size, size, Gravity.CENTER));
        TextView label = new TextView(this);
        label.setText("SurfaceView");
        label.setTextColor(Color.WHITE);
        label.setTextSize(20);
        root.addView(label, new FrameLayout.LayoutParams(FrameLayout.LayoutParams.WRAP_CONTENT,
                FrameLayout.LayoutParams.WRAP_CONTENT, Gravity.CENTER));
        setContentView(root);

        mHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                finish(size);
            }
        }, 4000);
    }

    @Override
    public void surfaceCreated(SurfaceHolder holder) {
        mCreated = true;
        check("surface valid", holder.getSurface().isValid(), true);
    }

    @Override
    public void surfaceChanged(final SurfaceHolder holder, int format, int width, int height) {
        System.out.println("     surface " + width + "x" + height + ", format " + format);
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
        int x = (mFrames * 4) % Math.max(frame.width() - bar, 1);
        canvas.drawRect(x, 0, x + bar, frame.height(), paint);
        holder.unlockCanvasAndPost(canvas);
        mFrames++;
    }

    private void finish(int size) {
        check("surface created", mCreated, true);
        Rect frame = mView.getHolder().getSurfaceFrame();
        check("surface size", frame.width() + "x" + frame.height(), size + "x" + size);
        check("frames drawn", mFrames > 10, true);
        System.out.println("     frames: " + mFrames);
        System.out.println(mFailures == 0 ? "SurfaceViewCheck passed" : "SurfaceViewCheck: " + mFailures + " failed");
        System.exit(mFailures == 0 ? 0 : 1);
    }
}
