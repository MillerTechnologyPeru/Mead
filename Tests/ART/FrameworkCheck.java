import android.content.ComponentName;
import android.content.Intent;
import android.content.res.AssetManager;
import android.content.res.Resources;
import android.net.Uri;
import android.os.Bundle;
import android.os.Parcel;
import android.util.Log;
import java.util.ArrayList;
import java.util.Arrays;
import java.util.Objects;

// Android 10's framework without a Context: Parcel, Bundle and Intent round
// trips through libbinder's Parcel, and Resources from framework-res.apk
// through libandroidfw. Phase 3's exit check. Run it on Mead, which loads
// libandroid_runtime as app_process would.
public class FrameworkCheck {
    static int failures = 0;

    static void check(String name, Object got, Object expected) {
        boolean ok = Objects.equals(got, expected);
        if (!ok) failures++;
        System.out.println((ok ? "ok   " : "FAIL ") + name + ": " + got + (ok ? "" : " (expected " + expected + ")"));
    }

    public static void main(String[] args) throws Exception {
        Log.i("FrameworkCheck", "android.util.Log reaches liblog");

        Parcel parcel = Parcel.obtain();
        parcel.writeInt(42);
        parcel.writeString("parcelled");
        parcel.writeLong(-7L);
        parcel.writeDouble(2.5);
        parcel.writeIntArray(new int[] {1, 2, 3});
        parcel.writeByteArray(new byte[] {9, 8});
        int size = parcel.dataSize();
        byte[] marshalled = parcel.marshall();
        parcel.recycle();
        Parcel copy = Parcel.obtain();
        copy.unmarshall(marshalled, 0, marshalled.length);
        copy.setDataPosition(0);
        check("Parcel primitives", Arrays.asList(copy.readInt(), copy.readString(), copy.readLong(), copy.readDouble()),
              Arrays.asList(42, "parcelled", -7L, 2.5));
        check("Parcel arrays", Arrays.toString(copy.createIntArray()) + Arrays.toString(copy.createByteArray()), "[1, 2, 3][9, 8]");
        check("Parcel size", copy.dataSize(), size);
        copy.recycle();

        Bundle bundle = new Bundle();
        bundle.putString("name", "Mead");
        bundle.putInt("level", 3);
        bundle.putStringArrayList("items", new ArrayList<>(Arrays.asList("a", "b")));
        Bundle inner = new Bundle();
        inner.putBoolean("nested", true);
        bundle.putBundle("inner", inner);
        Parcel bundleParcel = Parcel.obtain();
        bundleParcel.writeBundle(bundle);
        bundleParcel.setDataPosition(0);
        Bundle readBundle = bundleParcel.readBundle(FrameworkCheck.class.getClassLoader());
        bundleParcel.recycle();
        check("Bundle round trip", readBundle.getString("name") + "/" + readBundle.getInt("level") + "/"
              + readBundle.getStringArrayList("items") + "/" + readBundle.getBundle("inner").getBoolean("nested"),
              "Mead/3/[a, b]/true");

        Intent intent = new Intent(Intent.ACTION_VIEW, Uri.parse("https://example.com/path?q=1"));
        intent.setComponent(new ComponentName("com.example.app", "com.example.app.MainActivity"));
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK);
        intent.putExtra("count", 5);
        Parcel intentParcel = Parcel.obtain();
        intent.writeToParcel(intentParcel, 0);
        intentParcel.setDataPosition(0);
        Intent readIntent = Intent.CREATOR.createFromParcel(intentParcel);
        intentParcel.recycle();
        check("Intent round trip", readIntent.getAction() + " " + readIntent.getData().getQueryParameter("q") + " "
              + readIntent.getComponent().flattenToShortString() + " " + readIntent.getIntExtra("count", 0) + " "
              + ((readIntent.getFlags() & Intent.FLAG_ACTIVITY_NEW_TASK) != 0),
              "android.intent.action.VIEW 1 com.example.app/.MainActivity 5 true");
        check("Intent filterEquals", readIntent.filterEquals(intent), true);

        {
            // The system's resources, from framework-res.apk, which the
            // framework finds at /system/framework: under ANDROID_ROOT here.
            Resources resources = Resources.getSystem();
            AssetManager assets = resources.getAssets();
            check("android.R.string.ok", resources.getString(android.R.string.ok), "OK");
            check("android.R.string.cancel", resources.getString(android.R.string.cancel), "Cancel");
            check("resource name", resources.getResourceName(android.R.string.ok), "android:string/ok");
            check("config_longAnimTime", resources.getInteger(android.R.integer.config_longAnimTime), 500);
            check("dimen status_bar_height > 0",
                  resources.getDimensionPixelSize(resources.getIdentifier("status_bar_height", "dimen", "android")) > 0, true);
            check("AndroidManifest.xml opens", assets.openXmlResourceParser("AndroidManifest.xml") != null, true);
        }

        System.out.println(failures == 0 ? "all passed" : failures + " failed");
        System.exit(failures == 0 ? 0 : 1);
    }
}
