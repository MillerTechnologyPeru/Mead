import android.graphics.Canvas;
import android.graphics.Color;
import android.os.Handler;
import android.os.Looper;
import android.view.Choreographer;
import android.view.InputChannel;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.InputEventReceiver;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.Surface;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.List;
import java.util.Objects;
import mead.view.MeadWindow;

// Android 10's input and vsync through Mead's display bridge, on a Looper:
// an InputEventReceiver on a window's input channel gets the keys and
// touches SDL reports for the window (injected here into SDL's own event
// queue), as KeyEvents and MotionEvents (and the real mouse's, if it's over
// the window, which are listed apart), and Choreographer's frame callbacks
// arrive at the display's refresh rate.
public class InputCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    public static void main(String[] args) throws Exception {
        Looper.prepare();
        Looper looper = Looper.myLooper();

        Surface surface = MeadWindow.create("Mead: input", 320, 240);
        check("window", surface != null && surface.isValid(), true);
        Canvas canvas = surface.lockCanvas(null);
        int width = canvas.getWidth(), height = canvas.getHeight();
        canvas.drawColor(Color.DKGRAY);
        surface.unlockCanvasAndPost(canvas);

        InputChannel channel = MeadWindow.openInput(surface);
        check("input channel", channel != null, true);
        List<String> events = new ArrayList<>();
        List<String> mouseEvents = new ArrayList<>();
        InputEventReceiver receiver = new InputEventReceiver(channel, looper) {
            @Override
            public void onInputEvent(InputEvent event) {
                if (event instanceof KeyEvent) {
                    KeyEvent key = (KeyEvent) event;
                    events.add("key " + key.getAction() + " " + KeyEvent.keyCodeToString(key.getKeyCode())
                            + " source " + Integer.toHexString(key.getSource()));
                } else if (event instanceof MotionEvent) {
                    MotionEvent motion = (MotionEvent) event;
                    // The real mouse over the window, if there's one.
                    if (motion.isFromSource(InputDevice.SOURCE_MOUSE)) {
                        mouseEvents.add(MotionEvent.actionToString(motion.getActionMasked()));
                        finishInputEvent(event, true);
                        return;
                    }
                    events.add("motion " + MotionEvent.actionToString(motion.getActionMasked()) + " at "
                            + Math.round(motion.getX()) + "," + Math.round(motion.getY())
                            + " source " + Integer.toHexString(motion.getSource()));
                }
                finishInputEvent(event, true);
            }
        };

        // Choreographer's frames, from the display events libgui delivers.
        List<Long> frames = new ArrayList<>();
        Choreographer choreographer = Choreographer.getInstance();
        choreographer.postFrameCallback(new Choreographer.FrameCallback() {
            @Override
            public void doFrame(long frameTimeNanos) {
                frames.add(frameTimeNanos);
                if (frames.size() < 30) choreographer.postFrameCallback(this);
            }
        });

        Handler handler = new Handler(looper);
        // Anonymous classes, not lambdas: Android desugars lambdas at build
        // time, which plain javac and dx don't.
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                MeadWindow.injectKey(surface, 4, true);   // SDL's scancode for A
                MeadWindow.injectKey(surface, 4, false);
                MeadWindow.injectTouch(surface, 0, 0.25f, 0.5f);
                MeadWindow.injectTouch(surface, 2, 0.5f, 0.5f);
                MeadWindow.injectTouch(surface, 1, 0.5f, 0.5f);
            }
        }, 200);
        handler.postDelayed(new Runnable() {
            @Override
            public void run() {
                looper.quitSafely();
            }
        }, 1500);
        Looper.loop();

        String source = "source 1002";
        check("input events", events, Arrays.asList(
                "key 0 KEYCODE_A source 101",
                "key 1 KEYCODE_A source 101",
                "motion ACTION_DOWN at " + width / 4 + "," + height / 2 + " " + source,
                "motion ACTION_MOVE at " + width / 2 + "," + height / 2 + " " + source,
                "motion ACTION_UP at " + width / 2 + "," + height / 2 + " " + source));

        if (!mouseEvents.isEmpty()) System.out.println("     the mouse sent: " + mouseEvents);

        check("30 frames", frames.size(), 30);
        boolean increasing = true;
        long[] intervals = new long[Math.max(frames.size() - 1, 0)];
        for (int i = 1; i < frames.size(); i++) {
            intervals[i - 1] = frames.get(i) - frames.get(i - 1);
            if (intervals[i - 1] <= 0) increasing = false;
        }
        check("frame times increase", increasing, true);
        if (intervals.length > 0) {
            Arrays.sort(intervals);
            long median = intervals[intervals.length / 2] / 1_000_000;
            System.out.println("     median frame interval: " + median + " ms");
            check("frame interval like the display's", median >= 5 && median <= 40, true);
        }

        receiver.dispose();
        System.out.println(failures == 0 ? "InputCheck passed" : "InputCheck: " + failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
