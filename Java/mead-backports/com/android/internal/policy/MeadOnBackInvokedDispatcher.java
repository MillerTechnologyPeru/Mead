package com.android.internal.policy;

import android.view.View;
import android.view.Window;
import android.window.OnBackInvokedCallback;
import android.window.OnBackInvokedDispatcher;
import java.util.ArrayList;
import java.util.List;
import java.util.WeakHashMap;

/**
 * A window's dispatcher of back callbacks (Android 13's), for Mead's windows.
 * It keeps the app's callbacks by priority, as Android 13's does for an app
 * that hasn't opted in to them (android:enableOnBackInvokedCallback): the
 * back key then reaches the app as on Android 10, through onBackPressed,
 * which AndroidX's dispatcher answers too. The callbacks aren't called.
 */
public final class MeadOnBackInvokedDispatcher implements OnBackInvokedDispatcher {
    /** The windows of decor views, for View.findOnBackInvokedDispatcher. */
    private static final WeakHashMap<View, Window> sWindows = new WeakHashMap<>();

    private final List<OnBackInvokedCallback> mCallbacks = new ArrayList<>();
    private final List<Integer> mPriorities = new ArrayList<>();

    /** Records the window of a decor view (PhoneWindow, when it makes one). */
    public static void attach(View decor, Window window) {
        synchronized (sWindows) {
            sWindows.put(decor, window);
        }
    }

    /** The dispatcher of the window a view is in, or null when it isn't in one. */
    public static OnBackInvokedDispatcher forView(View view) {
        Window window;
        synchronized (sWindows) {
            window = sWindows.get(view.getRootView());
        }
        return window != null ? window.getOnBackInvokedDispatcher() : null;
    }

    @Override
    public synchronized void registerOnBackInvokedCallback(int priority, OnBackInvokedCallback callback) {
        if (priority < 0) {
            throw new IllegalArgumentException("Application registered OnBackInvokedCallback "
                    + "cannot have negative priority. Priority: " + priority);
        }
        add(priority, callback);
    }

    @Override
    public synchronized void unregisterOnBackInvokedCallback(OnBackInvokedCallback callback) {
        int index = mCallbacks.indexOf(callback);
        if (index >= 0) {
            mCallbacks.remove(index);
            mPriorities.remove(index);
        }
    }

    @Override
    public synchronized void registerSystemOnBackInvokedCallback(OnBackInvokedCallback callback) {
        add(PRIORITY_SYSTEM, callback);
    }

    /** The callback Android 13 would call for back: the last registered of the highest priority. */
    public synchronized OnBackInvokedCallback topCallback() {
        OnBackInvokedCallback top = null;
        int topPriority = Integer.MIN_VALUE;
        for (int i = 0; i < mCallbacks.size(); i++) {
            if (mPriorities.get(i) >= topPriority) {
                topPriority = mPriorities.get(i);
                top = mCallbacks.get(i);
            }
        }
        return top;
    }

    private void add(int priority, OnBackInvokedCallback callback) {
        unregisterOnBackInvokedCallback(callback);
        mCallbacks.add(callback);
        mPriorities.add(priority);
    }
}
