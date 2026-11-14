package mead.webkit;

import mead.server.base.WebSettingsBase;

/**
 * A WebView's settings, kept as Android's are. The ones the engine follows
 * (JavaScript, file access, the user agent) go to it when they change; the
 * rest are kept for apps that read them back.
 */
final class MeadWebSettings extends WebSettingsBase {
    static final String USER_AGENT = "Mozilla/5.0 (Linux; Android 10; Mead) AppleWebKit/605.1.15 "
            + "(KHTML, like Gecko) Mobile Safari/605.1.15";

    private final MeadWebView mOwner;
    private boolean mJavaScript;
    private boolean mFileAccess = true;
    private boolean mFileAccessFromFiles;
    private boolean mUniversalAccessFromFiles;
    private boolean mContentAccess = true;
    private boolean mDomStorage;
    private boolean mDatabase;
    private boolean mBlockNetworkLoads;
    private boolean mBlockNetworkImage;
    private boolean mLoadsImages = true;
    private boolean mSupportZoom = true;
    private boolean mBuiltInZoomControls;
    private boolean mDisplayZoomControls = true;
    private boolean mLoadWithOverviewMode;
    private boolean mUseWideViewPort;
    private boolean mSafeBrowsing = true;
    private boolean mMediaPlaybackRequiresUserGesture = true;
    private boolean mJavaScriptCanOpenWindows;
    private boolean mSupportMultipleWindows;
    private int mCacheMode = LOAD_DEFAULT;
    private int mTextZoom = 100;
    private int mMixedContentMode = MIXED_CONTENT_NEVER_ALLOW;
    private String mUserAgent = USER_AGENT;
    private String mDefaultTextEncoding = "UTF-8";

    MeadWebSettings(MeadWebView owner) {
        mOwner = owner;
    }

    private void changed() {
        mOwner.applySettings();
    }

    @Override public synchronized void setJavaScriptEnabled(boolean flag) { mJavaScript = flag; changed(); }
    @Override public synchronized boolean getJavaScriptEnabled() { return mJavaScript; }
    @Override public void setAllowFileAccess(boolean allow) { mFileAccess = allow; }
    @Override public boolean getAllowFileAccess() { return mFileAccess; }
    @Override public void setAllowFileAccessFromFileURLs(boolean flag) { mFileAccessFromFiles = flag; changed(); }
    @Override public boolean getAllowFileAccessFromFileURLs() { return mFileAccessFromFiles; }
    @Override public void setAllowUniversalAccessFromFileURLs(boolean flag) { mUniversalAccessFromFiles = flag; changed(); }
    @Override public boolean getAllowUniversalAccessFromFileURLs() { return mUniversalAccessFromFiles; }
    @Override public void setAllowContentAccess(boolean allow) { mContentAccess = allow; }
    @Override public boolean getAllowContentAccess() { return mContentAccess; }
    @Override public synchronized void setDomStorageEnabled(boolean flag) { mDomStorage = flag; }
    @Override public synchronized boolean getDomStorageEnabled() { return mDomStorage; }
    @Override public synchronized void setDatabaseEnabled(boolean flag) { mDatabase = flag; }
    @Override public synchronized boolean getDatabaseEnabled() { return mDatabase; }
    @Override public synchronized void setBlockNetworkLoads(boolean flag) { mBlockNetworkLoads = flag; }
    @Override public synchronized boolean getBlockNetworkLoads() { return mBlockNetworkLoads; }
    @Override public synchronized void setBlockNetworkImage(boolean flag) { mBlockNetworkImage = flag; }
    @Override public synchronized boolean getBlockNetworkImage() { return mBlockNetworkImage; }
    @Override public synchronized void setLoadsImagesAutomatically(boolean flag) { mLoadsImages = flag; }
    @Override public synchronized boolean getLoadsImagesAutomatically() { return mLoadsImages; }
    @Override public void setSupportZoom(boolean support) { mSupportZoom = support; }
    @Override public boolean supportZoom() { return mSupportZoom; }
    @Override public void setBuiltInZoomControls(boolean enabled) { mBuiltInZoomControls = enabled; }
    @Override public boolean getBuiltInZoomControls() { return mBuiltInZoomControls; }
    @Override public void setDisplayZoomControls(boolean enabled) { mDisplayZoomControls = enabled; }
    @Override public boolean getDisplayZoomControls() { return mDisplayZoomControls; }
    @Override public void setLoadWithOverviewMode(boolean overview) { mLoadWithOverviewMode = overview; }
    @Override public boolean getLoadWithOverviewMode() { return mLoadWithOverviewMode; }
    @Override public synchronized void setUseWideViewPort(boolean use) { mUseWideViewPort = use; }
    @Override public synchronized boolean getUseWideViewPort() { return mUseWideViewPort; }
    @Override public void setSafeBrowsingEnabled(boolean enabled) { mSafeBrowsing = enabled; }
    @Override public boolean getSafeBrowsingEnabled() { return mSafeBrowsing; }
    @Override public void setMediaPlaybackRequiresUserGesture(boolean require) { mMediaPlaybackRequiresUserGesture = require; }
    @Override public boolean getMediaPlaybackRequiresUserGesture() { return mMediaPlaybackRequiresUserGesture; }
    @Override public synchronized void setJavaScriptCanOpenWindowsAutomatically(boolean flag) { mJavaScriptCanOpenWindows = flag; }
    @Override public synchronized boolean getJavaScriptCanOpenWindowsAutomatically() { return mJavaScriptCanOpenWindows; }
    @Override public synchronized void setSupportMultipleWindows(boolean support) { mSupportMultipleWindows = support; }
    @Override public synchronized boolean supportMultipleWindows() { return mSupportMultipleWindows; }
    @Override public void setCacheMode(int mode) { mCacheMode = mode; }
    @Override public int getCacheMode() { return mCacheMode; }
    @Override public synchronized void setTextZoom(int textZoom) { mTextZoom = textZoom; }
    @Override public synchronized int getTextZoom() { return mTextZoom; }
    @Override public void setMixedContentMode(int mode) { mMixedContentMode = mode; }
    @Override public int getMixedContentMode() { return mMixedContentMode; }
    @Override public synchronized void setDefaultTextEncodingName(String encoding) { mDefaultTextEncoding = encoding; }
    @Override public synchronized String getDefaultTextEncodingName() { return mDefaultTextEncoding; }
    @Override public synchronized void setUserAgentString(String ua) {
        mUserAgent = ua != null && !ua.isEmpty() ? ua : USER_AGENT;
        changed();
    }
    @Override public synchronized String getUserAgentString() { return mUserAgent; }
}
