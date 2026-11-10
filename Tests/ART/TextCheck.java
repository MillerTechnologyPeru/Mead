import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Paint;
import android.graphics.Rect;
import android.graphics.Typeface;
import android.text.Layout;
import android.text.StaticLayout;
import android.text.TextPaint;
import java.util.Objects;

// Android 10's text on ART: the system fonts from $ANDROID_ROOT/fonts (which
// the framework reads as /system/fonts), Typeface's families, measuring and
// drawing through minikin and Skia, fallback to CJK and emoji fonts, and
// StaticLayout's line breaking. Run it on Mead.
public class TextCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    // How many pixels of a bitmap aren't the background.
    static int inked(Bitmap bitmap, int background) {
        int count = 0;
        for (int y = 0; y < bitmap.getHeight(); y++) {
            for (int x = 0; x < bitmap.getWidth(); x++) {
                if (bitmap.getPixel(x, y) != background) count++;
            }
        }
        return count;
    }

    public static void main(String[] args) {
        check("default typeface", Typeface.DEFAULT != null, true);
        check("serif differs from sans", Typeface.create("serif", Typeface.NORMAL) != Typeface.DEFAULT, true);
        check("bold is bold", Typeface.DEFAULT_BOLD.isBold(), true);

        Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
        paint.setTextSize(32);
        float hello = paint.measureText("Hello, Mead");
        check("measureText", hello > 100 && hello < 300, true);
        check("wider text is wider", paint.measureText("Hello, Mead!!") > hello, true);
        Paint.FontMetrics metrics = paint.getFontMetrics();
        check("font metrics", metrics.ascent < 0 && metrics.descent > 0, true);
        Rect bounds = new Rect();
        paint.getTextBounds("H", 0, 1, bounds);
        check("H's bounds", bounds.height() > 15 && bounds.height() < 32, true);

        Paint bold = new Paint(paint);
        bold.setTypeface(Typeface.DEFAULT_BOLD);
        check("bold is wider", bold.measureText("Hello, Mead") > hello, true);

        // Characters only fallback fonts have: CJK and emoji.
        check("CJK has glyphs", paint.hasGlyph("漢") && paint.measureText("漢字") > 40, true);
        check("emoji has a glyph", paint.hasGlyph("😀"), true);

        Bitmap bitmap = Bitmap.createBitmap(240, 48, Bitmap.Config.ARGB_8888);
        Canvas canvas = new Canvas(bitmap);
        canvas.drawColor(Color.WHITE);
        paint.setColor(Color.BLACK);
        canvas.drawText("Hello, Mead", 4, 36, paint);
        int ink = inked(bitmap, Color.WHITE);
        check("drawText inks pixels", ink > 300 && ink < 240 * 48 / 2, true);

        Bitmap cjk = Bitmap.createBitmap(96, 48, Bitmap.Config.ARGB_8888);
        new Canvas(cjk).drawText("漢字", 4, 36, paint);
        check("CJK draws", inked(cjk, Color.TRANSPARENT) > 100, true);

        TextPaint textPaint = new TextPaint(paint);
        String sentence = "The quick brown fox jumps over the lazy dog, twice over.";
        StaticLayout layout = StaticLayout.Builder.obtain(sentence, 0, sentence.length(), textPaint, 200)
                .setAlignment(Layout.Alignment.ALIGN_NORMAL).build();
        check("StaticLayout wraps", layout.getLineCount() > 2, true);
        check("lines fit", layout.getLineWidth(0) <= 200, true);

        System.out.println(failures == 0 ? "TextCheck passed" : "TextCheck: " + failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
