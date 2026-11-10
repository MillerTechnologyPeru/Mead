import android.graphics.Bitmap;
import android.graphics.BitmapFactory;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.LinearGradient;
import android.graphics.Matrix;
import android.graphics.Paint;
import android.graphics.Path;
import android.graphics.PorterDuff;
import android.graphics.Rect;
import android.graphics.RectF;
import android.graphics.Region;
import android.graphics.Shader;
import java.io.ByteArrayOutputStream;
import java.util.Objects;

// Android 10's software drawing: Bitmap, Canvas, Paint, Path, Matrix and
// Region over hwui and Skia, and PNG and JPEG through Bitmap.compress and
// BitmapFactory. No text: there are no system fonts yet. Run it on Mead,
// which loads libandroid_runtime as app_process would.
public class GraphicsCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    static String hex(int color) {
        return String.format("#%08X", color);
    }

    public static void main(String[] args) throws Exception {
        Bitmap bitmap = Bitmap.createBitmap(64, 48, Bitmap.Config.ARGB_8888);
        check("Bitmap size", bitmap.getWidth() + "x" + bitmap.getHeight() + " " + bitmap.getConfig(), "64x48 ARGB_8888");
        check("Bitmap starts clear", hex(bitmap.getPixel(10, 10)), hex(Color.TRANSPARENT));

        Canvas canvas = new Canvas(bitmap);
        canvas.drawColor(Color.WHITE);
        check("drawColor", hex(bitmap.getPixel(0, 0)), hex(Color.WHITE));

        Paint paint = new Paint();
        paint.setColor(Color.RED);
        canvas.drawRect(new Rect(4, 4, 20, 20), paint);
        check("drawRect inside", hex(bitmap.getPixel(10, 10)), hex(Color.RED));
        check("drawRect outside", hex(bitmap.getPixel(25, 10)), hex(Color.WHITE));

        paint.setColor(Color.BLUE);
        paint.setAntiAlias(true);
        canvas.drawCircle(40, 24, 6, paint);
        check("drawCircle centre", hex(bitmap.getPixel(40, 24)), hex(Color.BLUE));
        check("drawCircle outside", hex(bitmap.getPixel(40, 35)), hex(Color.WHITE));

        Path triangle = new Path();
        triangle.moveTo(50, 40);
        triangle.lineTo(62, 40);
        triangle.lineTo(56, 30);
        triangle.close();
        paint.setAntiAlias(false);
        paint.setColor(Color.GREEN);
        canvas.drawPath(triangle, paint);
        check("drawPath", hex(bitmap.getPixel(56, 38)), hex(Color.GREEN));
        RectF bounds = new RectF();
        triangle.computeBounds(bounds, true);
        check("Path bounds", bounds.toShortString(), "[50.0,30.0][62.0,40.0]");

        canvas.save();
        Matrix matrix = new Matrix();
        matrix.setTranslate(30, 0);
        canvas.concat(matrix);
        paint.setColor(Color.MAGENTA);
        canvas.drawRect(0, 40, 4, 44, paint);
        canvas.restore();
        check("Matrix translate", hex(bitmap.getPixel(31, 41)), hex(Color.MAGENTA));
        float[] point = {1, 2};
        matrix.postScale(2, 3);
        matrix.mapPoints(point);
        check("Matrix mapPoints", point[0] + "," + point[1], "62.0,6.0");

        canvas.save();
        canvas.clipRect(0, 0, 8, 8);
        canvas.drawColor(Color.YELLOW, PorterDuff.Mode.SRC);
        canvas.restore();
        check("clipRect inside", hex(bitmap.getPixel(2, 2)), hex(Color.YELLOW));
        check("clipRect outside", hex(bitmap.getPixel(9, 9)), hex(Color.RED));

        Bitmap gradient = Bitmap.createBitmap(16, 1, Bitmap.Config.ARGB_8888);
        Paint gradientPaint = new Paint();
        gradientPaint.setShader(new LinearGradient(0, 0, 16, 0, Color.BLACK, Color.WHITE, Shader.TileMode.CLAMP));
        new Canvas(gradient).drawPaint(gradientPaint);
        int left = Color.red(gradient.getPixel(0, 0));
        int right = Color.red(gradient.getPixel(15, 0));
        check("LinearGradient", left < 32 && right > 223 && left < Color.red(gradient.getPixel(8, 0)), true);

        Region region = new Region(0, 0, 10, 10);
        region.op(5, 5, 15, 15, Region.Op.UNION);
        check("Region", region.contains(12, 12) + " " + region.contains(12, 2) + " " + region.getBounds().toShortString(),
              "true false [0,0][15,15]");

        int[] pixels = new int[4];
        bitmap.getPixels(pixels, 0, 2, 9, 9, 2, 2);
        check("getPixels", hex(pixels[0]) + " " + hex(pixels[3]), hex(Color.RED) + " " + hex(Color.RED));

        ByteArrayOutputStream png = new ByteArrayOutputStream();
        check("PNG encode", bitmap.compress(Bitmap.CompressFormat.PNG, 100, png), true);
        byte[] pngBytes = png.toByteArray();
        Bitmap decoded = BitmapFactory.decodeByteArray(pngBytes, 0, pngBytes.length);
        check("PNG round trip", decoded != null && decoded.sameAs(bitmap), true);

        ByteArrayOutputStream jpeg = new ByteArrayOutputStream();
        check("JPEG encode", bitmap.compress(Bitmap.CompressFormat.JPEG, 90, jpeg), true);
        BitmapFactory.Options options = new BitmapFactory.Options();
        options.inJustDecodeBounds = true;
        byte[] jpegBytes = jpeg.toByteArray();
        BitmapFactory.decodeByteArray(jpegBytes, 0, jpegBytes.length, options);
        check("JPEG bounds", options.outWidth + "x" + options.outHeight + " " + options.outMimeType, "64x48 image/jpeg");

        Bitmap scaled = Bitmap.createScaledBitmap(bitmap, 32, 24, false);
        check("createScaledBitmap", scaled.getWidth() + "x" + scaled.getHeight() + " " + hex(scaled.getPixel(5, 5)),
              "32x24 " + hex(Color.RED));

        System.out.println(failures == 0 ? "GraphicsCheck passed" : "GraphicsCheck: " + failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
