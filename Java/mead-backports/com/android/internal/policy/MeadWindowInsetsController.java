package com.android.internal.policy;

import android.content.Context;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowInsetsAnimationControlListener;
import android.view.WindowInsetsController;
import android.view.inputmethod.InputMethodManager;
import java.util.ArrayList;
import java.util.List;

/**
 * A window's insets controller in Mead, with Android 11's API
 * (WindowInsetsController's backport). Mead's windows are the host's,
 * without status or navigation bars, so showing or hiding system bars
 * changes nothing and there are none to control; what an app sets of their
 * behavior and appearance is kept, as Android keeps it. The input method is
 * shown and hidden through the input method manager, for the window's
 * focused view.
 */
public final class MeadWindowInsetsController implements WindowInsetsController {
    private final Window mWindow;
    private int mAppearance;
    private int mBehavior = BEHAVIOR_SHOW_BARS_BY_SWIPE;
    private final List<OnControllableInsetsChangedListener> mListeners = new ArrayList<>();

    MeadWindowInsetsController(Window window) {
        mWindow = window;
    }

    @Override
    public void show(int types) {
        if ((types & WindowInsets.Type.ime()) == 0) return;
        View focused = mWindow.getCurrentFocus();
        InputMethodManager input = inputMethods();
        if (focused != null && input != null) input.showSoftInput(focused, 0);
    }

    @Override
    public void hide(int types) {
        if ((types & WindowInsets.Type.ime()) == 0) return;
        View decor = mWindow.peekDecorView();
        InputMethodManager input = inputMethods();
        if (decor != null && input != null) input.hideSoftInputFromWindow(decor.getWindowToken(), 0);
    }

    /** No inset is animated: there are no bars, and the input method has no animation to control. */
    @Override
    public void controlWindowInsetsAnimation(int types, WindowInsetsAnimationControlListener listener) {
        listener.onCancelled();
    }

    @Override
    public synchronized void setSystemBarsAppearance(int appearance, int mask) {
        mAppearance = (mAppearance & ~mask) | (appearance & mask);
    }

    @Override
    public synchronized int getSystemBarsAppearance() {
        return mAppearance;
    }

    @Override
    public synchronized void setSystemBarsBehavior(int behavior) {
        mBehavior = behavior;
    }

    @Override
    public synchronized int getSystemBarsBehavior() {
        return mBehavior;
    }

    /** As Android tells a new listener: which types it controls now, none. */
    @Override
    public void addOnControllableInsetsChangedListener(OnControllableInsetsChangedListener listener) {
        synchronized (this) {
            mListeners.add(listener);
        }
        listener.onControllableInsetsChanged(this, 0);
    }

    @Override
    public synchronized void removeOnControllableInsetsChangedListener(OnControllableInsetsChangedListener listener) {
        mListeners.remove(listener);
    }

    private InputMethodManager inputMethods() {
        Context context = mWindow.getContext();
        return context != null ? context.getSystemService(InputMethodManager.class) : null;
    }
}
