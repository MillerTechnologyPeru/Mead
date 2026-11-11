package mead.server;

import android.view.IWindowSession;
import android.view.IWindowSessionCallback;
import android.view.InputChannel;
import android.view.Surface;
import mead.server.base.WindowManagerBase;

/**
 * Android's window manager for Mead: each window its own window on the
 * desktop (or the screen), made by Mead's display bridge (see
 * WindowSession), with its own input channel.
 */
final class WindowManagerService extends WindowManagerBase {
    /**
     * A display bridge window titled title, of kind 0 (top level), 1 (a
     * dialog over parent's window) or 2 (a popup in parent's window, at x, y),
     * width×height pixels, as a SurfaceControl's native object; 0 for none.
     */
    static native long nativeCreateWindow(String title, int kind, Surface parent, int x, int y, int width,
            int height);

    /** A window's size, and a popup's place in its parent. */
    static native void nativeSetWindowFrame(Surface surface, int x, int y, int width, int height, boolean popup);

    /** Shows a window, or hides it. */
    static native void nativeShowWindow(Surface surface, boolean shown);

    /**
     * Where a window's frame starts in its surface, which its surface insets
     * (a shadow's room) make bigger: input is in the frame's coordinates.
     */
    static native void nativeSetInputOffset(Surface surface, int x, int y);

    /** The window Android's focus is on, whose keys it gets; null for none. */
    static native void nativeSetFocus(Surface surface);

    /** Sends a window's input to the server end of its input channel. */
    static native void nativeAttachInput(Surface surface, InputChannel serverChannel);

    @Override
    public IWindowSession openSession(IWindowSessionCallback callback) {
        return new WindowSession();
    }

    @Override
    public float getCurrentAnimatorScale() {
        return 1;
    }

    @Override
    public float getAnimationScale(int which) {
        return 1;
    }

    @Override
    public float[] getAnimationScales() {
        return new float[] {1, 1, 1};
    }

    @Override
    public boolean isKeyguardLocked() {
        return false;
    }

    // As a phone with on-screen navigation: there's no menu key, so apps show
    // their overflow menus. Windows' insets leave no room for the bar.
    @Override
    public boolean hasNavigationBar(int displayId) {
        return true;
    }
}
