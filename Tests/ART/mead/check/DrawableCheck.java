package mead.check;

import android.app.Activity;
import android.content.res.Resources;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.drawable.Drawable;
import android.os.Bundle;
import android.os.Handler;
import android.view.View;
import android.view.ViewTreeObserver;
import android.widget.ImageView;
import android.widget.LinearLayout;

// Drawables at the display's density, through hwui and in software: the
// framework's overflow icon as a VectorDrawable (material) and as a bitmap
// (holo), at the density's size on white. Each must mark a software bitmap,
// and the frame dump shows both drawn by hwui.
//
// Run with: mead --dex drawable-check.jar mead.server.MeadApp mead.check mead.check.DrawableCheck 400 200
public class DrawableCheck extends Activity {
    private int mFailures;

    private void check(String name, Object actual, Object expected) {
        boolean ok = expected.equals(actual);
        if (!ok) mFailures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + actual + (ok ? "" : " (expected " + expected + ")"));
    }

    private Drawable system(String name) {
        Resources resources = getResources();
        int id = resources.getIdentifier(name, "drawable", "android");
        if (id == 0) return null;
        Drawable drawable = resources.getDrawable(id, getTheme()).mutate();
        drawable.setTint(Color.BLACK);
        return drawable;
    }

    /** Pixels a drawable marks, on white, in a software bitmap its own size. */
    private static int markedPixels(Drawable drawable, int size) {
        Bitmap bitmap = Bitmap.createBitmap(size, size, Bitmap.Config.ARGB_8888);
        bitmap.eraseColor(Color.WHITE);
        drawable.setBounds(0, 0, size, size);
        drawable.draw(new Canvas(bitmap));
        int dark = 0;
        for (int y = 0; y < size; y++) {
            for (int x = 0; x < size; x++) {
                if (bitmap.getPixel(x, y) != Color.WHITE) dark++;
            }
        }
        return dark;
    }

    @Override
    protected void onCreate(Bundle state) {
        super.onCreate(state);
        float density = getResources().getDisplayMetrics().density;
        System.out.println("     density: " + density);
        int size = Math.round(48 * density);

        LinearLayout row = new LinearLayout(this);
        row.setBackgroundColor(Color.WHITE);
        String[] names = {"ic_menu_moreoverflow_material", "ic_menu_moreoverflow_normal_holo_light"};
        for (String name : names) {
            Drawable drawable = system(name);
            check(name + " found", drawable != null, true);
            if (drawable == null) continue;
            System.out.println("     " + name + ": " + drawable.getClass().getSimpleName() + ", "
                    + drawable.getIntrinsicWidth() + "x" + drawable.getIntrinsicHeight());
            check(name + " in software", markedPixels(system(name), size) > 0, true);
            ImageView view = new ImageView(this);
            view.setImageDrawable(drawable);
            row.addView(view, new LinearLayout.LayoutParams(size, size));
        }
        setContentView(row);

        final View content = row;
        content.getViewTreeObserver().addOnDrawListener(new ViewTreeObserver.OnDrawListener() {
            boolean mScheduled;

            @Override
            public void onDraw() {
                if (mScheduled) return;
                mScheduled = true;
                new Handler().postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        check("hardware accelerated", content.isHardwareAccelerated(), true);
                        System.out.println(mFailures == 0 ? "DrawableCheck passed"
                                : "DrawableCheck: " + mFailures + " failed");
                        System.exit(mFailures == 0 ? 0 : 1);
                    }
                }, 1000);
            }
        });
    }
}
