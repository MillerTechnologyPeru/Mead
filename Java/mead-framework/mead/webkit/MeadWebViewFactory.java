package mead.webkit;

import android.content.Context;
import android.net.Uri;
import android.webkit.ValueCallback;
import android.webkit.WebView;
import android.webkit.WebViewFactoryProvider;
import android.webkit.WebViewProvider;
import java.lang.reflect.Field;
import java.util.List;
import mead.server.base.WebViewFactoryProviderBase;
import mead.server.base.WebViewStaticsBase;

/**
 * Android's WebView provider for Mead: WebViewFactory hands it out where a
 * phone loads Chromium's from the WebView package. Its web views are WPE
 * WebKit's (MeadWebView).
 */
public final class MeadWebViewFactory extends WebViewFactoryProviderBase {
    private final Statics mStatics = new Statics();

    /** Makes this the provider WebViewFactory gives every WebView. */
    public static void install() {
        try {
            Field field = Class.forName("android.webkit.WebViewFactory").getDeclaredField("sProviderInstance");
            field.setAccessible(true);
            field.set(null, new MeadWebViewFactory());
        } catch (ReflectiveOperationException e) {
            System.err.println("mead: WebViewFactory has no provider to set: " + e);
        }
    }

    @Override
    public WebViewProvider createWebView(WebView webView, WebView.PrivateAccess privateAccess) {
        return new MeadWebView(webView, privateAccess);
    }

    @Override
    public WebViewFactoryProvider.Statics getStatics() {
        return mStatics;
    }

    @Override
    public ClassLoader getWebViewClassLoader() {
        return MeadWebViewFactory.class.getClassLoader();
    }

    private static final class Statics extends WebViewStaticsBase {
        @Override public String getDefaultUserAgent(Context context) { return MeadWebSettings.USER_AGENT; }
        @Override public String findAddress(String addr) { return null; }
        @Override public void setWebContentsDebuggingEnabled(boolean enable) {}
        @Override public void freeMemoryForTests() {}
        @Override public void enableSlowWholeDocumentDraw() {}
        @Override public void clearClientCertPreferences(Runnable onCleared) { if (onCleared != null) onCleared.run(); }
        @Override public Uri[] parseFileChooserResult(int resultCode, android.content.Intent intent) { return null; }
        /** Safe Browsing is Google's service, which Mead doesn't reach: it isn't on. */
        @Override public void initSafeBrowsing(Context context, ValueCallback<Boolean> callback) {
            if (callback != null) callback.onReceiveValue(false);
        }
        @Override public void setSafeBrowsingWhitelist(List<String> hosts, ValueCallback<Boolean> callback) {
            if (callback != null) callback.onReceiveValue(false);
        }
        @Override public Uri getSafeBrowsingPrivacyPolicyUrl() { return null; }
    }
}
