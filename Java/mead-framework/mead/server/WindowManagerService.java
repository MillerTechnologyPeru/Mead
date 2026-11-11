package mead.server;

import android.view.IWindowSession;
import android.view.IWindowSessionCallback;
import android.view.InputChannel;
import android.view.Surface;
import mead.server.base.WindowManagerBase;

/**
 * Android's window manager for Mead: each window its own window on the
 * desktop (or the screen), made by Mead's display bridge through its
 * SurfaceControl, with its own input channel.
 */
final class WindowManagerService extends WindowManagerBase {
    /** An input channel for the window surface draws to: the client end. */
    static native InputChannel nativeOpenInput(Surface surface);

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

    @Override
    public boolean hasNavigationBar(int displayId) {
        return false;
    }
}
