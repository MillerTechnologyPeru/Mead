package mead.check;

import android.app.Activity;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.os.Bundle;
import android.os.Handler;
import android.view.InputDevice;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.Window;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;
import mead.view.MeadWindow;

// Phase 4's exit check: an Activity, launched by ActivityThread through
// Mead's in-process activity and window managers, whose View draws with
// Canvas through hwui to a window and takes a touch, a key and a gamepad
// button (injected into SDL's event queue once the first frame is drawn).
// With MEAD_FRAME_DUMP set, the first frame is read back and checked.
//
// Run with: MEAD_CAPTIONS=0 mead --dex activity-check.jar mead.server.MeadApp mead.check mead.check.ActivityCheck 640 480
// (without Android's caption, which the window would have on GNOME: the
// view, the frame and the injected touches are the whole window's).
public class ActivityCheck extends Activity {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    private CheckView mView;
    private final Handler mHandler = new Handler();

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        check("onCreate", getPackageName() + " " + getClass().getName(), "mead.check mead.check.ActivityCheck");
        List<android.app.ActivityManager.AppTask> tasks =
                ((android.app.ActivityManager) getSystemService(Context.ACTIVITY_SERVICE)).getAppTasks();
        check("app tasks", tasks.size(), 1);
        android.app.ActivityManager.RecentTaskInfo task = tasks.get(0).getTaskInfo();
        check("task", task.taskId + " " + task.baseActivity.getClassName() + " " + task.numActivities,
                "1 mead.check.ActivityCheck 1");
        check("ignoring battery optimizations", ((android.os.PowerManager) getSystemService(Context.POWER_SERVICE))
                .isIgnoringBatteryOptimizations(getPackageName()), true);
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        mView = new CheckView(this);
        setContentView(mView);
        mView.requestFocus();
    }

    @Override
    protected void onResume() {
        super.onResume();
        check("onResume", true, true);
    }

    // After the first frame: the input, then the results.
    void firstFrameDrawn() {
        check("hardware accelerated", mView.isHardwareAccelerated(), true);
        check("view fills the window", mView.getWidth() + "x" + mView.getHeight(),
                getWindow().getDecorView().getWidth() + "x" + getWindow().getDecorView().getHeight());
        mHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                MeadWindow.injectTouch(null, 0, 0.25f, 0.25f);
                MeadWindow.injectTouch(null, 1, 0.25f, 0.25f);
                MeadWindow.injectKey(null, 4, true);   // SDL's scancode for A
                MeadWindow.injectKey(null, 4, false);
                MeadWindow.injectGamepadButton(0, true);   // SDL's south button, Android's A
                MeadWindow.injectGamepadButton(0, false);
            }
        }, 300);
        mHandler.postDelayed(new Runnable() {
            @Override
            public void run() {
                finishCheck();
            }
        }, 1500);
    }

    void finishCheck() {
        int width = mView.getWidth(), height = mView.getHeight();
        check("view's input", mView.events, Arrays.asList(
                "touch ACTION_DOWN at " + width / 4 + "," + height / 4,
                "touch ACTION_UP at " + width / 4 + "," + height / 4,
                "key down KEYCODE_A keyboard",
                "key up KEYCODE_A keyboard",
                "key down KEYCODE_BUTTON_A gamepad",
                "key up KEYCODE_BUTTON_A gamepad"));
        String dump = System.getenv("MEAD_FRAME_DUMP");
        if (dump != null) {
            int[][] frame = readFrame(dump);
            check("first frame", frame != null, true);
            if (frame != null) {
                check("frame size", frame[0].length + "x" + frame.length, width + "x" + height);
                check("background", hex(frame[5][5]), hex(CheckView.BACKGROUND));
                check("circle at the centre", hex(frame[height / 2][width / 2]), hex(Color.YELLOW));
            }
        }
        System.out.println(failures == 0 ? "ActivityCheck passed" : "ActivityCheck: " + failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }

    static String hex(int color) {
        return String.format("#%06X", color & 0xFFFFFF);
    }

    static int[][] readFrame(String path) {
        try (DataInputStream in = new DataInputStream(new FileInputStream(new File(path)))) {
            String[] header = new String[4];
            for (int i = 0; i < 4; i++) {
                StringBuilder token = new StringBuilder();
                int c;
                while ((c = in.read()) != -1 && !Character.isWhitespace(c)) token.append((char) c);
                header[i] = token.toString();
            }
            int width = Integer.parseInt(header[1]), height = Integer.parseInt(header[2]);
            int[][] pixels = new int[height][width];
            byte[] row = new byte[width * 3];
            for (int y = 0; y < height; y++) {
                in.readFully(row);
                for (int x = 0; x < width; x++) {
                    pixels[y][x] = (row[x * 3] & 0xFF) << 16 | (row[x * 3 + 1] & 0xFF) << 8 | (row[x * 3 + 2] & 0xFF);
                }
            }
            return pixels;
        } catch (Exception e) {
            return null;
        }
    }

    // A View that draws a circle and the last input, and lists its input.
    static final class CheckView extends View {
        static final int BACKGROUND = 0xFF203040;
        final List<String> events = new ArrayList<>();
        private final Paint mPaint = new Paint(Paint.ANTI_ALIAS_FLAG);
        private float mX = -1, mY = -1;
        private String mLast = "Mead";
        private boolean mDrawn;

        CheckView(Context context) {
            super(context);
            setFocusable(true);
            setFocusableInTouchMode(true);
        }

        @Override
        protected void onDraw(Canvas canvas) {
            canvas.drawColor(BACKGROUND);
            mPaint.setColor(Color.YELLOW);
            canvas.drawCircle(mX < 0 ? getWidth() / 2f : mX, mY < 0 ? getHeight() / 2f : mY,
                    Math.min(getWidth(), getHeight()) / 6f, mPaint);
            mPaint.setColor(Color.WHITE);
            mPaint.setTextSize(36);
            canvas.drawText(mLast, 24, getHeight() - 24, mPaint);
            if (!mDrawn) {
                mDrawn = true;
                post(new Runnable() {
                    @Override
                    public void run() {
                        ((ActivityCheck) getContext()).firstFrameDrawn();
                    }
                });
            }
        }

        @Override
        public boolean onTouchEvent(MotionEvent event) {
            events.add("touch " + MotionEvent.actionToString(event.getActionMasked()) + " at "
                    + Math.round(event.getX()) + "," + Math.round(event.getY()));
            mX = event.getX();
            mY = event.getY();
            mLast = "touch";
            invalidate();
            return true;
        }

        @Override
        public boolean onKeyDown(int keyCode, KeyEvent event) {
            return key("down", event);
        }

        @Override
        public boolean onKeyUp(int keyCode, KeyEvent event) {
            return key("up", event);
        }

        private boolean key(String action, KeyEvent event) {
            String source = event.isFromSource(InputDevice.SOURCE_GAMEPAD) ? "gamepad" : "keyboard";
            events.add("key " + action + " " + KeyEvent.keyCodeToString(event.getKeyCode()) + " " + source);
            mLast = KeyEvent.keyCodeToString(event.getKeyCode());
            invalidate();
            return true;
        }
    }
}
