package mead.webkit;

import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import org.json.JSONArray;
import org.json.JSONException;
import org.json.JSONObject;
import org.json.JSONTokener;

/**
 * The native side of Mead's WebView (libmead_webkit, in the runtime's
 * natives): WPE WebKit on a thread of its own, rendering off screen, its
 * frames copied for the view to draw. Without the library (a host without
 * WPE), web views draw nothing and their loads fail.
 *
 * JavaScript interfaces are the page's objects whose methods call back
 * synchronously, as Android's do: a call reaches invoke() on a bridge
 * thread, its arguments and result as JSON.
 */
final class MeadWebKit {
    static final boolean AVAILABLE = load();

    private MeadWebKit() {}

    private static boolean load() {
        try {
            System.loadLibrary("mead_webkit");
            return true;
        } catch (UnsatisfiedLinkError e) {
            System.err.println("mead: no WebView engine: " + e.getMessage());
            return false;
        }
    }

    /** A web view of this size, which calls back into view; 0 when it couldn't be made. */
    static native long nativeCreate(MeadWebView view, int width, int height);
    static native void nativeDestroy(long handle);
    static native void nativeLoadUrl(long handle, String url);
    static native void nativeLoadHtml(long handle, String html, String baseUrl);
    static native void nativeStop(long handle);
    static native void nativeReload(long handle);
    static native void nativeGoBack(long handle);
    static native void nativeGoForward(long handle);
    static native boolean nativeCanGoBack(long handle);
    static native boolean nativeCanGoForward(long handle);
    static native void nativeResize(long handle, int width, int height);
    static native void nativeSetBackground(long handle, int argb);
    static native void nativeSetSettings(long handle, boolean javaScript, boolean fileAccessFromFiles,
            boolean universalAccessFromFiles, String userAgent);
    /** Runs the script; its result comes to the view's onEvaluated with this id. */
    static native void nativeEvaluate(long handle, String script, int id);
    /** The page's JavaScript interfaces: "name:method,method" each. */
    static native void nativeSetInterfaces(long handle, String[] interfaces);
    /** A pointer: 0 down, 1 up, 2 moved; button 1 for a touch or the primary button. */
    static native void nativePointer(long handle, int action, int x, int y, int button);
    static native void nativeScroll(long handle, int x, int y, float dx, float dy);
    /** A key, as an XKB keysym and its character (0 for none). */
    static native void nativeKey(long handle, int keysym, int unicode, boolean down, int modifiers);
    /** Copies the latest frame (RGBA, premultiplied) into pixels; false without one that size. */
    static native boolean nativeCopyFrame(long handle, ByteBuffer pixels, int width, int height);

    // The bridge: a JavaScript interface's method, called with JSON arguments.

    /** The JSON for a call's result: a string, a number, a boolean, null, or undefined for none. */
    static String invoke(Object target, String methodName, String[] jsonArguments) {
        if (target == null) return "undefined";
        for (Method method : target.getClass().getMethods()) {
            if (!method.getName().equals(methodName)) continue;
            if (!method.isAnnotationPresent(android.webkit.JavascriptInterface.class)) continue;
            Class<?>[] types = method.getParameterTypes();
            if (types.length != jsonArguments.length) continue;
            try {
                Object[] arguments = new Object[types.length];
                for (int i = 0; i < types.length; i++) arguments[i] = argument(jsonArguments[i], types[i]);
                Object result = method.invoke(target, arguments);
                return method.getReturnType() == void.class ? "undefined" : json(result);
            } catch (ReflectiveOperationException | JSONException e) {
                Throwable cause = e.getCause() != null ? e.getCause() : e;
                System.err.println("mead: JavaScript interface " + methodName + " threw " + cause);
                return "undefined";
            }
        }
        return "undefined";
    }

    private static Object argument(String json, Class<?> type) throws JSONException {
        Object value = json == null || json.equals("undefined") ? JSONObject.NULL : new JSONTokener(json).nextValue();
        boolean missing = value == JSONObject.NULL;
        if (type == String.class) return missing ? null : value instanceof String ? value : value.toString();
        if (type == boolean.class || type == Boolean.class) return !missing && Boolean.TRUE.equals(value);
        Number number = value instanceof Number ? (Number) value : 0;
        if (type == int.class || type == Integer.class) return number.intValue();
        if (type == long.class || type == Long.class) return number.longValue();
        if (type == float.class || type == Float.class) return number.floatValue();
        if (type == double.class || type == Double.class) return number.doubleValue();
        if (type == short.class || type == Short.class) return number.shortValue();
        if (type == byte.class || type == Byte.class) return number.byteValue();
        return missing ? null : value;
    }

    private static String json(Object value) {
        if (value == null) return "null";
        if (value instanceof Boolean || value instanceof Number) return value.toString();
        if (value instanceof JSONObject || value instanceof JSONArray) return value.toString();
        return JSONObject.quote(value.toString());
    }
}
