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
     * Where a window's frame is in its surface, which its surface insets (a
     * shadow's room) make bigger: input is in the frame's coordinates, and a
     * toplevel's frame is its window to the compositor.
     */
    static native void nativeSetFrameInSurface(Surface surface, int x, int y, int width, int height);

    /**
     * Whether windows draw their own decorations: the compositor draws none
     * (GNOME's), so activities show Android's freeform caption.
     */
    static native boolean nativeWantsCaptions();

    /** Starts the compositor moving a window's toplevel with the pointer or finger. */
    static native void nativeStartMove(Surface surface);

    /** Maximizes a window's toplevel, or restores it. */
    static native void nativeToggleMaximized(Surface surface);

    /** A window's ID with the bridge, which its events name. */
    static native int nativeWindowId(Surface surface);

    /**
     * The bridge's next window event, waiting for one: {kind, window ID,
     * width, height}. Kind 1 is a toplevel the compositor resized, to a frame
     * of width×height pixels.
     */
    static native int[] nativeNextWindowEvent();

    private static Boolean sWantsCaptions;

    /** Whether activities show Android's caption (see nativeWantsCaptions). */
    static synchronized boolean wantsCaptions() {
        if (sWantsCaptions == null) {
            String forced = System.getenv("MEAD_CAPTIONS");
            sWantsCaptions = forced != null ? !forced.equals("0") : nativeWantsCaptions();
            Thread events = new Thread(new Runnable() {
                @Override
                public void run() {
                    while (true) {
                        int[] event = nativeNextWindowEvent();
                        if (event != null && event[0] == 1) WindowSession.compositorResized(event[1], event[2], event[3]);
                    }
                }
            }, "MeadWindowEvents");
            events.setDaemon(true);
            events.start();
        }
        return sWantsCaptions;
    }

    /**
     * How much a window dims the window under it while it shows, as
     * FLAG_DIM_BEHIND's dimAmount: 0 for none.
     */
    static native void nativeSetDimBehind(Surface surface, float amount);

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
