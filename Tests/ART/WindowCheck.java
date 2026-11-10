import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.view.Surface;
import java.io.DataInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.util.Objects;
import mead.view.MeadWindow;

// Android 10 drawing to windows through Mead's display bridge: a Surface
// for an SDL window, drawn in software (lockCanvas) and by hwui's GL
// pipeline (lockHardwareCanvas). With MEAD_FRAME_DUMP set, each window's
// first frame is read back from there and its pixels checked. The first
// argument, if any, is how many seconds to keep the windows up.
public class WindowCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    static String hex(int color) {
        return String.format("#%06X", color & 0xFFFFFF);
    }

    // A binary PPM's pixels, as RGB colors, once it's there.
    static int[][] readFrame(String path, long timeoutMillis) throws Exception {
        File file = new File(path);
        long deadline = System.currentTimeMillis() + timeoutMillis;
        while (!file.exists() || file.length() == 0) {
            if (System.currentTimeMillis() > deadline) return null;
            Thread.sleep(50);
        }
        Thread.sleep(100);
        try (DataInputStream in = new DataInputStream(new FileInputStream(file))) {
            String[] header = new String[4];
            for (int i = 0; i < 4; i++) {
                StringBuilder token = new StringBuilder();
                int c;
                while ((c = in.read()) != -1 && !Character.isWhitespace(c)) token.append((char) c);
                header[i] = token.toString();
            }
            int width = Integer.parseInt(header[1]);
            int height = Integer.parseInt(header[2]);
            int[][] pixels = new int[height][width];
            byte[] row = new byte[width * 3];
            for (int y = 0; y < height; y++) {
                in.readFully(row);
                for (int x = 0; x < width; x++) {
                    pixels[y][x] = (row[x * 3] & 0xFF) << 16 | (row[x * 3 + 1] & 0xFF) << 8 | (row[x * 3 + 2] & 0xFF);
                }
            }
            return pixels;
        }
    }

    public static void main(String[] args) throws Exception {
        String dump = System.getenv("MEAD_FRAME_DUMP");
        int hold = args.length > 0 ? Integer.parseInt(args[0]) : 0;
        Paint paint = new Paint();

        // Software: lockCanvas draws into Mead's surface's buffer, which the
        // bridge copies to the window.
        if (dump != null) new File(dump).delete();
        Surface software = MeadWindow.create("Mead: software", 320, 240);
        check("software window", software != null && software.isValid(), true);
        Canvas canvas = software.lockCanvas(null);
        int width = canvas.getWidth(), height = canvas.getHeight();
        check("lockCanvas is software", canvas.isHardwareAccelerated(), false);
        canvas.drawColor(Color.RED);
        paint.setColor(Color.BLUE);
        canvas.drawRect(0, 0, width / 2, height / 2, paint);
        software.unlockCanvasAndPost(canvas);
        if (dump != null) {
            int[][] frame = readFrame(dump, 5000);
            check("software frame", frame != null, true);
            if (frame != null) {
                check("software frame size", frame[0].length + "x" + frame.length, width + "x" + height);
                check("software top left", hex(frame[height / 4][width / 4]), hex(Color.BLUE));
                check("software bottom right", hex(frame[3 * height / 4][3 * width / 4]), hex(Color.RED));
            }
        }

        // hwui: lockHardwareCanvas records a display list that hwui's render
        // thread draws with GL, through EGL, to the window itself.
        if (dump != null) new File(dump).delete();
        Surface hardware = MeadWindow.create("Mead: hwui", 320, 240);
        check("hwui window", hardware != null && hardware.isValid(), true);
        Canvas hardwareCanvas = hardware.lockHardwareCanvas();
        width = hardwareCanvas.getWidth();
        height = hardwareCanvas.getHeight();
        check("lockHardwareCanvas is hardware", hardwareCanvas.isHardwareAccelerated(), true);
        hardwareCanvas.drawColor(Color.GREEN);
        paint.setColor(Color.MAGENTA);
        paint.setAntiAlias(true);
        hardwareCanvas.drawCircle(width / 2f, height / 2f, Math.min(width, height) / 4f, paint);
        hardware.unlockCanvasAndPost(hardwareCanvas);
        if (dump != null) {
            int[][] frame = readFrame(dump, 10000);
            check("hwui frame", frame != null, true);
            if (frame != null) {
                check("hwui frame size", frame[0].length + "x" + frame.length, width + "x" + height);
                check("hwui corner", hex(frame[5][5]), hex(Color.GREEN));
                check("hwui centre", hex(frame[height / 2][width / 2]), hex(Color.MAGENTA));
            }
        } else {
            System.out.println("MEAD_FRAME_DUMP isn't set: the frames weren't read back");
        }

        Thread.sleep(hold * 1000L);
        System.out.println(failures == 0 ? "WindowCheck passed" : "WindowCheck: " + failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
