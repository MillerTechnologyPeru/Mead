package mead.webkit;

import android.content.res.AssetManager;
import android.graphics.Bitmap;
import android.graphics.Canvas;
import android.graphics.Color;
import android.graphics.Rect;
import android.net.Uri;
import android.os.Handler;
import android.os.Looper;
import android.util.Base64;
import android.view.KeyEvent;
import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebMessage;
import android.webkit.WebResourceError;
import android.webkit.WebResourceRequest;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.webkit.WebViewProvider;
import java.io.ByteArrayOutputStream;
import java.io.IOException;
import java.io.InputStream;
import java.lang.reflect.Method;
import java.nio.ByteBuffer;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.List;
import java.util.Map;
import mead.server.base.WebViewProviderBase;
import mead.server.base.WebViewScrollDelegateBase;
import mead.server.base.WebViewViewDelegateBase;
import org.json.JSONObject;

/**
 * A WebView in Mead: WPE WebKit's page (MeadWebKit), drawn as the view's
 * content. The page renders off screen at the view's size; each frame is
 * copied and drawn in onDraw, so the view draws as any other, into a window
 * or a Canvas an app captures it with. Touches, the mouse and keys go to the
 * page. Its client hears of loads and errors on the UI thread, as from
 * Android's.
 *
 * file:///android_asset/ pages and what they load come from the app's
 * assets, through the mead-asset: scheme.
 */
final class MeadWebView extends WebViewProviderBase {
    private static final String ASSET_PREFIX = "file:///android_asset/";
    static final String ASSET_SCHEME = "mead-asset";

    private final WebView mView;
    private final WebView.PrivateAccess mAccess;
    private final Handler mHandler = new Handler(Looper.getMainLooper());
    private final MeadWebSettings mSettings;
    private final ViewDelegate mViewDelegate = new ViewDelegate();
    private final ScrollDelegate mScrollDelegate = new ScrollDelegate();
    private final Map<String, Object> mInterfaces = new HashMap<>();
    private final Map<Integer, ValueCallback<String>> mEvaluations = new HashMap<>();
    private final List<Runnable> mAfterFrame = new ArrayList<>();
    private WebViewClient mClient = new WebViewClient();
    private WebChromeClient mChromeClient;
    private long mHandle;
    private int mNextEvaluation = 1;
    private String mUrl;
    private String mTitle;
    private int mProgress;
    private boolean mPaused;
    private int mBackground = Color.WHITE;
    private Bitmap mFrame;
    private ByteBuffer mPixels;

    MeadWebView(WebView view, WebView.PrivateAccess access) {
        mView = view;
        mAccess = access;
        mSettings = new MeadWebSettings(this);
    }

    // The page.

    @Override
    public void init(Map<String, Object> javaScriptInterfaces, boolean privateBrowsing) {
        if (javaScriptInterfaces != null) mInterfaces.putAll(javaScriptInterfaces);
        if (MeadWebKit.AVAILABLE) {
            mHandle = MeadWebKit.nativeCreate(this, Math.max(mView.getWidth(), 1), Math.max(mView.getHeight(), 1));
            applySettings();
            applyInterfaces();
        }
    }

    @Override
    public void destroy() {
        if (mHandle != 0) MeadWebKit.nativeDestroy(mHandle);
        mHandle = 0;
    }

    @Override
    public void loadUrl(String url) {
        loadUrl(url, null);
    }

    @Override
    public void loadUrl(String url, Map<String, String> headers) {
        if (url == null) return;
        if (url.startsWith("javascript:")) {
            evaluateJavaScript(Uri.decode(url.substring("javascript:".length())), null);
            return;
        }
        mUrl = url;
        if (mHandle != 0) {
            MeadWebKit.nativeLoadUrl(mHandle, engineUrl(url));
        } else {
            failed(url, WebViewClient.ERROR_UNKNOWN, "no WebView engine");
        }
    }

    @Override
    public void loadData(String data, String mimeType, String encoding) {
        String base64 = "base64".equalsIgnoreCase(encoding) ? data
                : Base64.encodeToString(data.getBytes(java.nio.charset.StandardCharsets.UTF_8), Base64.NO_WRAP);
        loadUrl("data:" + (mimeType != null ? mimeType : "text/html") + ";base64," + base64);
    }

    @Override
    public void loadDataWithBaseURL(String baseUrl, String data, String mimeType, String encoding, String historyUrl) {
        mUrl = historyUrl != null ? historyUrl : baseUrl;
        if (mHandle != 0) {
            MeadWebKit.nativeLoadHtml(mHandle, data != null ? data : "", baseUrl != null ? engineUrl(baseUrl) : "about:blank");
        } else {
            failed(mUrl, WebViewClient.ERROR_UNKNOWN, "no WebView engine");
        }
    }

    @Override public void stopLoading() { if (mHandle != 0) MeadWebKit.nativeStop(mHandle); }
    @Override public void reload() { if (mHandle != 0) MeadWebKit.nativeReload(mHandle); }
    @Override public boolean canGoBack() { return mHandle != 0 && MeadWebKit.nativeCanGoBack(mHandle); }
    @Override public void goBack() { if (mHandle != 0) MeadWebKit.nativeGoBack(mHandle); }
    @Override public boolean canGoForward() { return mHandle != 0 && MeadWebKit.nativeCanGoForward(mHandle); }
    @Override public void goForward() { if (mHandle != 0) MeadWebKit.nativeGoForward(mHandle); }
    @Override public String getUrl() { return mUrl; }
    @Override public String getOriginalUrl() { return mUrl; }
    @Override public String getTitle() { return mTitle; }
    @Override public int getProgress() { return mProgress; }
    @Override public int getContentHeight() { return mView.getHeight(); }
    @Override public int getContentWidth() { return mView.getWidth(); }
    @Override public float getScale() { return 1f; }
    @Override public void setInitialScale(int scaleInPercent) {}
    @Override public void pauseTimers() {}
    @Override public void resumeTimers() {}
    @Override public void onPause() { mPaused = true; }
    @Override public void onResume() { mPaused = false; }
    @Override public boolean isPaused() { return mPaused; }
    @Override public void clearCache(boolean includeDiskFiles) {}
    @Override public void clearHistory() {}
    @Override public void setNetworkAvailable(boolean networkUp) {}
    @Override public void setHorizontalScrollbarOverlay(boolean overlay) {}
    @Override public void setVerticalScrollbarOverlay(boolean overlay) {}
    @Override public void setRendererPriorityPolicy(int priority, boolean waivedWhenNotVisible) {}

    @Override
    public void evaluateJavaScript(String script, ValueCallback<String> resultCallback) {
        if (mHandle == 0) {
            if (resultCallback != null) {
                mHandler.post(new Runnable() {
                    @Override public void run() { resultCallback.onReceiveValue(null); }
                });
            }
            return;
        }
        int id;
        synchronized (mEvaluations) {
            id = mNextEvaluation++;
            if (resultCallback != null) mEvaluations.put(id, resultCallback);
        }
        MeadWebKit.nativeEvaluate(mHandle, script, id);
    }

    /** Delivered as a message event to the page's window, as Android's WebView delivers it. */
    @Override
    public void postMessageToMainFrame(WebMessage message, Uri targetOrigin) {
        String data = message.getData() != null ? JSONObject.quote(message.getData()) : "null";
        evaluateJavaScript("window.dispatchEvent(new MessageEvent('message', {data: " + data + "}));", null);
    }

    /** Called back after the next frame the view draws, as Android's are after the page reaches the screen. */
    @Override
    public void insertVisualStateCallback(long requestId, WebView.VisualStateCallback callback) {
        synchronized (mAfterFrame) {
            mAfterFrame.add(new Runnable() {
                @Override public void run() { callback.onComplete(requestId); }
            });
        }
        mView.postInvalidate();
    }

    @Override public void setWebViewClient(WebViewClient client) { mClient = client != null ? client : new WebViewClient(); }
    @Override public WebViewClient getWebViewClient() { return mClient; }
    @Override public void setWebChromeClient(WebChromeClient client) { mChromeClient = client; }
    @Override public WebChromeClient getWebChromeClient() { return mChromeClient; }
    @Override public WebSettings getSettings() { return mSettings; }
    @Override public WebViewProvider.ViewDelegate getViewDelegate() { return mViewDelegate; }
    @Override public WebViewProvider.ScrollDelegate getScrollDelegate() { return mScrollDelegate; }

    @Override
    public void addJavascriptInterface(Object object, String name) {
        synchronized (mInterfaces) {
            mInterfaces.put(name, object);
        }
        applyInterfaces();
    }

    @Override
    public void removeJavascriptInterface(String name) {
        synchronized (mInterfaces) {
            mInterfaces.remove(name);
        }
        applyInterfaces();
    }

    // What the settings and interfaces mean to the engine.

    void applySettings() {
        if (mHandle == 0) return;
        MeadWebKit.nativeSetSettings(mHandle, mSettings.getJavaScriptEnabled(), mSettings.getAllowFileAccessFromFileURLs(),
                mSettings.getAllowUniversalAccessFromFileURLs(), mSettings.getUserAgentString());
    }

    private void applyInterfaces() {
        if (mHandle == 0) return;
        List<String> described = new ArrayList<>();
        synchronized (mInterfaces) {
            for (Map.Entry<String, Object> entry : mInterfaces.entrySet()) {
                StringBuilder methods = new StringBuilder();
                for (Method method : entry.getValue().getClass().getMethods()) {
                    if (!method.isAnnotationPresent(JavascriptInterface.class)) continue;
                    if (methods.length() > 0) methods.append(',');
                    methods.append(method.getName());
                }
                described.add(entry.getKey() + ":" + methods);
            }
        }
        MeadWebKit.nativeSetInterfaces(mHandle, described.toArray(new String[0]));
    }

    /** The engine's URL for an app's: its assets through mead-asset:. */
    private static String engineUrl(String url) {
        return url.startsWith(ASSET_PREFIX) ? ASSET_SCHEME + ":///" + url.substring(ASSET_PREFIX.length()) : url;
    }

    /** The app's URL for the engine's. */
    private static String appUrl(String url) {
        String prefix = ASSET_SCHEME + ":///";
        return url != null && url.startsWith(prefix) ? ASSET_PREFIX + url.substring(prefix.length()) : url;
    }

    // From the engine: on its thread, passed to the UI thread.

    /** An asset, for the mead-asset: scheme; null when the app has none. On the engine's thread. */
    byte[] readAsset(String path) {
        AssetManager assets = mView.getContext().getAssets();
        try (InputStream in = assets.open(Uri.decode(path))) {
            ByteArrayOutputStream out = new ByteArrayOutputStream();
            byte[] buffer = new byte[65536];
            int length;
            while ((length = in.read(buffer)) > 0) out.write(buffer, 0, length);
            return out.toByteArray();
        } catch (IOException e) {
            return null;
        }
    }

    /** A new frame: the view draws it. */
    void onFrame() {
        mView.postInvalidate();
    }

    /** 0: started, 1: committed, 2: finished. */
    void onLoad(int event, String url) {
        String appUrl = appUrl(url);
        mHandler.post(new Runnable() {
            @Override public void run() { loaded(event, appUrl); }
        });
    }

    private void loaded(int event, String appUrl) {
        if (appUrl != null) mUrl = appUrl;
        if (event == 0) {
            mProgress = 10;
            mClient.onPageStarted(mView, appUrl, null);
        } else if (event == 1) {
            mProgress = 50;
            mClient.onPageCommitVisible(mView, appUrl);
        } else {
            mProgress = 100;
            mClient.onPageFinished(mView, appUrl);
            if (mChromeClient != null) mChromeClient.onProgressChanged(mView, 100);
        }
    }

    void onLoadFailed(String url, int code, String description) {
        failed(appUrl(url), code, description);
    }

    void onTitle(String title) {
        mHandler.post(new Runnable() {
            @Override public void run() {
                mTitle = title;
                if (mChromeClient != null) mChromeClient.onReceivedTitle(mView, title);
            }
        });
    }

    void onEvaluated(int id, String json) {
        ValueCallback<String> callback;
        synchronized (mEvaluations) {
            callback = mEvaluations.remove(id);
        }
        if (callback != null) {
            mHandler.post(new Runnable() {
                @Override public void run() { callback.onReceiveValue(json); }
            });
        }
    }

    /** A JavaScript interface's method, called from the page: on a bridge thread, as Android's are. */
    String invoke(String object, String method, String[] jsonArguments) {
        Object target;
        synchronized (mInterfaces) {
            target = mInterfaces.get(object);
        }
        return MeadWebKit.invoke(target, method, jsonArguments);
    }

    private void failed(String url, int code, String description) {
        mHandler.post(new Runnable() {
            @Override public void run() {
                mClient.onReceivedError(mView, new Request(url), new Error(code, description));
                mClient.onReceivedError(mView, code, description, url);
            }
        });
    }

    private static final class Request implements WebResourceRequest {
        private final Uri mUri;
        Request(String url) { mUri = url != null ? Uri.parse(url) : Uri.EMPTY; }
        @Override public Uri getUrl() { return mUri; }
        @Override public boolean isForMainFrame() { return true; }
        @Override public boolean isRedirect() { return false; }
        @Override public boolean hasGesture() { return false; }
        @Override public String getMethod() { return "GET"; }
        @Override public Map<String, String> getRequestHeaders() { return new HashMap<>(); }
    }

    private static final class Error extends WebResourceError {
        private final int mCode;
        private final CharSequence mDescription;
        Error(int code, CharSequence description) { mCode = code; mDescription = description; }
        @Override public int getErrorCode() { return mCode; }
        @Override public CharSequence getDescription() { return mDescription; }
    }

    // The view.

    private final class ViewDelegate extends WebViewViewDelegateBase {
        @Override public void onDraw(Canvas canvas) {
            canvas.drawColor(mBackground);
            int width = mView.getWidth(), height = mView.getHeight();
            if (mHandle != 0 && width > 0 && height > 0) {
                if (mFrame == null || mFrame.getWidth() != width || mFrame.getHeight() != height) {
                    mFrame = Bitmap.createBitmap(width, height, Bitmap.Config.ARGB_8888);
                    mPixels = ByteBuffer.allocateDirect(width * height * 4);
                }
                mPixels.rewind();
                if (MeadWebKit.nativeCopyFrame(mHandle, mPixels, width, height)) {
                    mPixels.rewind();
                    mFrame.copyPixelsFromBuffer(mPixels);
                    canvas.drawBitmap(mFrame, 0, 0, null);
                }
            }
            List<Runnable> after;
            synchronized (mAfterFrame) {
                after = new ArrayList<>(mAfterFrame);
                mAfterFrame.clear();
            }
            for (Runnable callback : after) mHandler.post(callback);
        }

        @Override public void onSizeChanged(int w, int h, int ow, int oh) {
            if (mHandle != 0 && w > 0 && h > 0) MeadWebKit.nativeResize(mHandle, w, h);
        }

        @Override public void onMeasure(int widthMeasureSpec, int heightMeasureSpec) {
            mAccess.setMeasuredDimension(View.getDefaultSize(0, widthMeasureSpec),
                    View.getDefaultSize(0, heightMeasureSpec));
        }

        @Override public void setBackgroundColor(int color) {
            mBackground = color;
            if (mHandle != 0) MeadWebKit.nativeSetBackground(mHandle, color);
            mView.invalidate();
        }

        @Override public boolean onTouchEvent(MotionEvent event) {
            if (mHandle == 0) return false;
            int action = event.getActionMasked();
            int pointerAction = action == MotionEvent.ACTION_DOWN ? 0
                    : action == MotionEvent.ACTION_UP || action == MotionEvent.ACTION_CANCEL ? 1
                    : action == MotionEvent.ACTION_MOVE ? 2 : -1;
            if (pointerAction < 0) return true;
            MeadWebKit.nativePointer(mHandle, pointerAction, (int) event.getX(), (int) event.getY(), 1);
            return true;
        }

        @Override public boolean onGenericMotionEvent(MotionEvent event) {
            if (mHandle != 0 && event.getActionMasked() == MotionEvent.ACTION_SCROLL) {
                MeadWebKit.nativeScroll(mHandle, (int) event.getX(), (int) event.getY(),
                        event.getAxisValue(MotionEvent.AXIS_HSCROLL), event.getAxisValue(MotionEvent.AXIS_VSCROLL));
                return true;
            }
            if (mHandle != 0 && event.getActionMasked() == MotionEvent.ACTION_HOVER_MOVE) {
                MeadWebKit.nativePointer(mHandle, 2, (int) event.getX(), (int) event.getY(), 0);
                return true;
            }
            return mAccess.super_onGenericMotionEvent(event);
        }

        @Override public boolean onHoverEvent(MotionEvent event) {
            return onGenericMotionEvent(event) || mAccess.super_onHoverEvent(event);
        }

        @Override public boolean onKeyDown(int keyCode, KeyEvent event) { return key(event, true); }
        @Override public boolean onKeyUp(int keyCode, KeyEvent event) { return key(event, false); }

        private boolean key(KeyEvent event, boolean down) {
            int keysym = Keys.keysym(event);
            if (mHandle == 0 || keysym == 0) return false;
            MeadWebKit.nativeKey(mHandle, keysym, event.getUnicodeChar(), down, event.getMetaState());
            return true;
        }

        @Override public boolean dispatchKeyEvent(KeyEvent event) { return mAccess.super_dispatchKeyEvent(event); }
        @Override public boolean requestFocus(int direction, Rect previouslyFocusedRect) {
            return mAccess.super_requestFocus(direction, previouslyFocusedRect);
        }
        @Override public boolean setFrame(int left, int top, int right, int bottom) {
            return mAccess.super_setFrame(left, top, right, bottom);
        }
        @Override public void setLayoutParams(ViewGroup.LayoutParams params) { mAccess.super_setLayoutParams(params); }
        @Override public boolean performLongClick() { return mAccess.super_performLongClick(); }
        @Override public Handler getHandler(Handler originalHandler) { return originalHandler; }
        @Override public View findFocus(View originalFocusedView) { return originalFocusedView; }
        @Override public boolean shouldDelayChildPressedState() { return true; }
        @Override public void setLayerType(int layerType, android.graphics.Paint paint) {}
        @Override public void setOverScrollMode(int mode) {}
        @Override public void setScrollBarStyle(int style) {}
        @Override public void onAttachedToWindow() {}
        @Override public void onDetachedFromWindow() {}
        @Override public void onVisibilityChanged(View changedView, int visibility) {}
        @Override public void onWindowVisibilityChanged(int visibility) {}
        @Override public void onWindowFocusChanged(boolean hasWindowFocus) {}
        @Override public void onFocusChanged(boolean focused, int direction, Rect previouslyFocusedRect) {}
        @Override public void onScrollChanged(int l, int t, int oldl, int oldt) {}
        @Override public void onConfigurationChanged(android.content.res.Configuration newConfig) {}
        @Override public void preDispatchDraw(Canvas canvas) {}
        @Override public void onStartTemporaryDetach() {}
        @Override public void onFinishTemporaryDetach() {}
        @Override public void onOverScrolled(int scrollX, int scrollY, boolean clampedX, boolean clampedY) {}
        @Override public void onDrawVerticalScrollBar(Canvas canvas, android.graphics.drawable.Drawable scrollBar,
                int l, int t, int r, int b) {}
        @Override public boolean requestChildRectangleOnScreen(View child, Rect rect, boolean immediate) { return false; }
    }

    private final class ScrollDelegate extends WebViewScrollDelegateBase {
        @Override public int computeHorizontalScrollRange() { return mView.getWidth(); }
        @Override public int computeHorizontalScrollOffset() { return 0; }
        @Override public int computeVerticalScrollRange() { return mView.getHeight(); }
        @Override public int computeVerticalScrollOffset() { return 0; }
        @Override public int computeVerticalScrollExtent() { return mView.getHeight(); }
        @Override public void computeScroll() {}
    }
}
