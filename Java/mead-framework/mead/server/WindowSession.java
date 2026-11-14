package mead.server;

import android.content.res.Configuration;
import android.graphics.Rect;
import android.graphics.Region;
import android.os.IBinder;
import android.os.RemoteException;
import android.util.Log;
import android.util.MergedConfiguration;
import android.view.DisplayCutout;
import android.view.Gravity;
import android.view.IWindow;
import android.view.InputChannel;
import android.view.InsetsState;
import android.view.Surface;
import android.view.SurfaceControl;
import android.view.View;
import android.view.WindowManager;
import android.view.WindowManagerGlobal;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import mead.server.base.WindowSessionBase;

/**
 * A window session for Mead's window manager. Each window is a window of the
 * display bridge's, made when it's first laid out visible: an activity's (or
 * anything filling the app's window) is a top-level window the app window's
 * size; a dialog is a window its content's size, over its activity's; a
 * popup or panel (a menu, a dropdown) is a popup in its parent window, where
 * its gravity and offset put it. Windows hide while invisible. Input goes to
 * the newest window shown, which has focus; each window's input channel is
 * opened when it's added, the server end kept here as Android's window
 * manager keeps it.
 */
final class WindowSession extends WindowSessionBase {
    private static final String TAG = "MeadWindows";

    /** A window added. */
    private static final class WindowState {
        final IWindow window;
        final WindowManager.LayoutParams attrs = new WindowManager.LayoutParams();
        InputChannel serverChannel;
        SurfaceControl surfaceControl;
        /** A Surface for the window, which the bridge knows it by. */
        Surface surface;
        int kind;
        int x;
        int y;
        int width;
        int height;
        /** A toplevel's frame size as the compositor set it, 0 until it does. */
        int compositorWidth;
        int compositorHeight;
        /** Its window's ID with the bridge. */
        int bridgeId;
        boolean visible;
        boolean focused;
        /** Whether the compositor has stopped showing it (minimized, the screen off). */
        boolean compositorHidden;
        /** Whether it keeps the screen on, as the bridge was told. */
        boolean keepScreenOn;

        WindowState(IWindow window) {
            this.window = window;
        }
    }

    // The bridge's kinds of window (ARTDisplay.WindowKind).
    private static final int KIND_NORMAL = 0;
    private static final int KIND_DIALOG = 1;
    private static final int KIND_POPUP = 2;

    /** The windows, oldest first. */
    private final List<WindowState> mWindows = new ArrayList<>();

    /** Every session: the process's windows, for the bridge's events. */
    private static final List<WindowSession> sSessions = new ArrayList<>();

    WindowSession() {
        synchronized (sSessions) {
            sSessions.add(this);
        }
    }

    /** The window states of every session, as they are now. */
    private static List<WindowState> allWindows() {
        List<WindowState> all = new ArrayList<>();
        synchronized (sSessions) {
            for (WindowSession session : sSessions) {
                synchronized (session.mWindows) {
                    all.addAll(session.mWindows);
                }
            }
        }
        return all;
    }

    /**
     * The compositor resized a toplevel (maximized it, or the user dragged
     * its edge): its window is told its new frame, as Android's window
     * manager tells it, and lays itself out again.
     */
    static void compositorResized(int bridgeId, int width, int height) {
        for (WindowState state : allWindows()) {
            if (state.bridgeId != bridgeId) continue;
            state.compositorWidth = width;
            state.compositorHeight = height;
            Rect frame = new Rect(0, 0, width, height);
            MeadApp app = MeadApp.sCurrent;
            Configuration config = app != null ? app.configuration() : new Configuration();
            try {
                state.window.resized(frame, new Rect(), new Rect(), new Rect(), new Rect(), new Rect(), false,
                        new MergedConfiguration(config, new Configuration()), frame, true, false,
                        android.view.Display.DEFAULT_DISPLAY, new DisplayCutout.ParcelableWrapper(DisplayCutout.NO_CUTOUT));
            } catch (RemoteException e) {
                // The window is in this process.
            }
        }
    }

    /**
     * The compositor stopped showing a toplevel (minimized, covered, the
     * screen off), or shows it again: its activity is stopped, as Android
     * stops it with the display off, and resumed.
     */
    static void compositorHid(int bridgeId, boolean hidden) {
        for (WindowState state : allWindows()) {
            if (state.bridgeId != bridgeId || state.kind != KIND_NORMAL) continue;
            state.compositorHidden = hidden;
            MeadServices.sActivityTaskManager.compositorHid(state.attrs.token, hidden);
        }
    }

    /** Maximizes the activity's window with this token, or restores it (the caption's button). */
    static void toggleMaximized(IBinder token) {
        for (WindowState state : allWindows()) {
            if (state.attrs.token == token && state.kind == KIND_NORMAL && state.surface != null) {
                WindowManagerService.nativeToggleMaximized(state.surface);
                return;
            }
        }
    }

    @Override
    public boolean startMovingTask(IWindow window, float startX, float startY) {
        WindowState state;
        synchronized (mWindows) {
            state = find(window);
        }
        if (state == null || state.surface == null) return false;
        WindowManagerService.nativeStartMove(state.surface);
        return true;
    }

    @Override
    public void finishMovingTask(IWindow window) {}

    private WindowState find(IWindow window) {
        IBinder binder = window.asBinder();
        for (WindowState state : mWindows) {
            if (state.window.asBinder() == binder) return state;
        }
        return null;
    }

    private static int appWidth() {
        MeadApp app = MeadApp.sCurrent;
        return app != null ? app.width : 1280;
    }

    private static int appHeight() {
        MeadApp app = MeadApp.sCurrent;
        return app != null ? app.height : 720;
    }

    /** Whether a window fills the app's window. */
    private static boolean fills(WindowManager.LayoutParams attrs) {
        return attrs.type == WindowManager.LayoutParams.TYPE_BASE_APPLICATION
                || (attrs.width == WindowManager.LayoutParams.MATCH_PARENT
                        && attrs.height == WindowManager.LayoutParams.MATCH_PARENT);
    }

    private static boolean isSubWindow(int type) {
        return type >= WindowManager.LayoutParams.FIRST_SUB_WINDOW
                && type <= WindowManager.LayoutParams.LAST_SUB_WINDOW;
    }

    /** The window a window shows over: a sub-window's parent, or a dialog's activity. */
    private WindowState parentOf(WindowState state) {
        IBinder token = state.attrs.token;
        if (token == null) return null;
        if (isSubWindow(state.attrs.type)) {
            for (WindowState other : mWindows) {
                if (other.window.asBinder() == token) return other;
            }
        }
        for (WindowState other : mWindows) {
            if (other != state && other.attrs.token == token
                    && other.attrs.type == WindowManager.LayoutParams.TYPE_BASE_APPLICATION) {
                return other;
            }
        }
        return null;
    }

    @Override
    public int addToDisplay(IWindow window, int seq, WindowManager.LayoutParams attrs, int viewVisibility,
            int displayId, Rect outFrame, Rect outContentInsets, Rect outStableInsets, Rect outOutsets,
            DisplayCutout.ParcelableWrapper outDisplayCutout, InputChannel outInputChannel,
            InsetsState outInsetsState) {
        WindowState state = new WindowState(window);
        state.attrs.copyFrom(attrs);
        state.width = fills(attrs) || attrs.width <= 0 ? appWidth() : attrs.width;
        state.height = fills(attrs) || attrs.height <= 0 ? appHeight() : attrs.height;
        if (outInputChannel != null) {
            InputChannel[] pair = InputChannel.openInputChannelPair(String.valueOf(attrs.getTitle()));
            state.serverChannel = pair[0];
            pair[1].transferTo(outInputChannel);
        }
        synchronized (mWindows) {
            mWindows.add(state);
        }
        frames(state, outFrame, outContentInsets, outStableInsets, outOutsets, outDisplayCutout);
        return WindowManagerGlobal.ADD_OKAY | WindowManagerGlobal.ADD_FLAG_APP_VISIBLE
                | WindowManagerGlobal.ADD_FLAG_IN_TOUCH_MODE;
    }

    @Override
    public int addToDisplayWithoutInputChannel(IWindow window, int seq, WindowManager.LayoutParams attrs,
            int viewVisibility, int layerStackId, Rect outContentInsets, Rect outStableInsets,
            InsetsState insetsState) {
        return addToDisplay(window, seq, attrs, viewVisibility, layerStackId, new Rect(), outContentInsets,
                outStableInsets, new Rect(), new DisplayCutout.ParcelableWrapper(), null, insetsState);
    }

    @Override
    public void remove(IWindow window) {
        WindowState state;
        synchronized (mWindows) {
            state = find(window);
            if (state == null) return;
            mWindows.remove(state);
        }
        if (state.surfaceControl != null) state.surfaceControl.remove();
        if (state.surface != null) state.surface.release();
        if (state.serverChannel != null) state.serverChannel.dispose();
        updateFocus();
    }

    @Override
    public int relayout(IWindow window, int seq, WindowManager.LayoutParams attrs, int requestedWidth,
            int requestedHeight, int viewVisibility, int flags, long frameNumber, Rect outFrame,
            Rect outOverscanInsets, Rect outContentInsets, Rect outVisibleInsets, Rect outStableInsets,
            Rect outOutsets, Rect outBackdropFrame, DisplayCutout.ParcelableWrapper outCutout,
            MergedConfiguration mergedConfiguration, SurfaceControl outSurfaceControl,
            InsetsState outInsetsState) {
        WindowState state;
        synchronized (mWindows) {
            state = find(window);
        }
        if (state == null) return 0;
        if (attrs != null) state.attrs.copyFrom(attrs);
        boolean visible = viewVisibility == View.VISIBLE;
        WindowState parent = parentOf(state);
        layOut(state, parent, requestedWidth, requestedHeight);

        int result = WindowManagerGlobal.RELAYOUT_RES_IN_TOUCH_MODE;
        if (visible && state.surfaceControl == null) {
            if (!create(state, parent)) return result;
            result |= WindowManagerGlobal.RELAYOUT_RES_FIRST_TIME | WindowManagerGlobal.RELAYOUT_RES_SURFACE_CHANGED;
        } else if (state.surfaceControl != null) {
            Rect surface = surfaceRect(state, parent);
            WindowManagerService.nativeSetWindowFrame(state.surface, surface.left, surface.top, surface.width(),
                    surface.height(), state.kind == KIND_POPUP);
            Rect insets = state.attrs.surfaceInsets;
            WindowManagerService.nativeSetFrameInSurface(state.surface, insets.left, insets.top, state.width,
                    state.height);
            WindowManagerService.nativeSetDimBehind(state.surface, dimAmount(state));
            // A window the compositor hid stays mapped while its activity
            // is stopped, so that the compositor can show it again.
            if (visible != state.visible && (visible || !state.compositorHidden)) {
                WindowManagerService.nativeShowWindow(state.surface, visible);
            }
        }
        state.visible = visible && state.surfaceControl != null;
        // FLAG_KEEP_SCREEN_ON holds while the window is visible, as Android's
        // power manager takes it.
        boolean keepScreenOn = state.visible
                && (state.attrs.flags & WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON) != 0;
        if (keepScreenOn != state.keepScreenOn && state.surface != null) {
            state.keepScreenOn = keepScreenOn;
            WindowManagerService.nativeSetKeepScreenOn(state.surface, keepScreenOn);
        }
        if (state.visible) {
            outSurfaceControl.copyFrom(state.surfaceControl);
        } else {
            outSurfaceControl.release();
        }

        frames(state, outFrame, outContentInsets, outStableInsets, outOutsets, outCutout);
        outOverscanInsets.setEmpty();
        outVisibleInsets.setEmpty();
        outBackdropFrame.set(outFrame);
        MeadApp app = MeadApp.sCurrent;
        Configuration config = app != null ? app.configuration() : new Configuration();
        mergedConfiguration.setConfiguration(config, new Configuration());
        updateFocus();
        return result;
    }

    /** A window's kind, size and place, from its layout and its content's size. */
    private void layOut(WindowState state, WindowState parent, int requestedWidth, int requestedHeight) {
        WindowManager.LayoutParams attrs = state.attrs;
        // An activity's window, or one with nothing under it, is a window of
        // its own; one over another, even filling it, is that one's dialog.
        if (attrs.type == WindowManager.LayoutParams.TYPE_BASE_APPLICATION || parent == null) {
            state.kind = KIND_NORMAL;
            state.x = 0;
            state.y = 0;
            // The compositor's size once it has given one (maximized,
            // resized), else the app's.
            state.width = state.compositorWidth > 0 ? state.compositorWidth : appWidth();
            state.height = state.compositorHeight > 0 ? state.compositorHeight : appHeight();
            return;
        }
        int parentWidth = parent.width, parentHeight = parent.height;
        state.width = attrs.width == WindowManager.LayoutParams.MATCH_PARENT ? parentWidth
                : Math.max(1, Math.min(requestedWidth, parentWidth));
        state.height = attrs.height == WindowManager.LayoutParams.MATCH_PARENT ? parentHeight
                : Math.max(1, Math.min(requestedHeight, parentHeight));
        if (isSubWindow(attrs.type) || attrs.type == WindowManager.LayoutParams.TYPE_APPLICATION_ATTACHED_DIALOG) {
            state.kind = KIND_POPUP;
            Rect frame = new Rect();
            Gravity.apply(attrs.gravity, state.width, state.height, new Rect(0, 0, parentWidth, parentHeight),
                    attrs.x, attrs.y, frame);
            state.x = frame.left;
            state.y = frame.top;
        } else {
            state.kind = KIND_DIALOG;
            state.x = 0;
            state.y = 0;
        }
    }

    /**
     * A window's surface: its frame and its surface insets around it, as
     * Android's window manager sizes it, where hwui draws the frame at the
     * insets' offset. A popup's place is in its parent's surface.
     */
    private static Rect surfaceRect(WindowState state, WindowState parent) {
        Rect insets = state.attrs.surfaceInsets;
        Rect surface = new Rect(state.x - insets.left, state.y - insets.top,
                state.x + state.width + insets.right, state.y + state.height + insets.bottom);
        if (parent != null && state.kind == KIND_POPUP) {
            surface.offset(parent.attrs.surfaceInsets.left, parent.attrs.surfaceInsets.top);
        }
        return surface;
    }

    /** How much a window dims what's under it, as Android's window manager dims it. */
    private static float dimAmount(WindowState state) {
        return (state.attrs.flags & WindowManager.LayoutParams.FLAG_DIM_BEHIND) != 0 ? state.attrs.dimAmount : 0;
    }

    /** The window's bridge window, its SurfaceControl, and its input. */
    private boolean create(WindowState state, WindowState parent) {
        CharSequence title = state.attrs.getTitle();
        Rect surface = surfaceRect(state, parent);
        long nativeObject = WindowManagerService.nativeCreateWindow(
                title != null && title.length() > 0 ? title.toString() : "Mead", state.kind,
                parent != null ? parent.surface : null, surface.left, surface.top, surface.width(),
                surface.height());
        if (nativeObject == 0) {
            Log.e(TAG, "The display bridge made no window for " + title);
            return false;
        }
        Log.i(TAG, "Window " + title + " (kind " + state.kind + ") at " + state.x + "," + state.y + ", "
                + state.width + "×" + state.height + ": " + state.attrs);
        SurfaceControl surfaceControl = new SurfaceControl();
        try {
            Method assign = SurfaceControl.class.getDeclaredMethod("assignNativeObject", long.class);
            assign.setAccessible(true);
            assign.invoke(surfaceControl, nativeObject);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("SurfaceControl has no assignNativeObject", e);
        }
        state.surfaceControl = surfaceControl;
        state.surface = new Surface();
        state.surface.copyFrom(surfaceControl);
        // Its id first: setting the frame can post a size the compositor gave
        // already (a fullscreen window's), which compositorResized finds the
        // window by.
        state.bridgeId = WindowManagerService.nativeWindowId(state.surface);
        Rect insets = state.attrs.surfaceInsets;
        WindowManagerService.nativeSetFrameInSurface(state.surface, insets.left, insets.top, state.width,
                state.height);
        WindowManagerService.nativeSetDimBehind(state.surface, dimAmount(state));
        if (state.serverChannel != null) {
            WindowManagerService.nativeAttachInput(state.surface, state.serverChannel);
        }
        return true;
    }

    /** Focus to the newest visible window, as Android's window manager gives the top one. */
    private void updateFocus() {
        List<WindowState> windows;
        synchronized (mWindows) {
            windows = new ArrayList<>(mWindows);
        }
        WindowState top = null;
        for (WindowState state : windows) {
            if (state.visible && (state.attrs.flags & WindowManager.LayoutParams.FLAG_NOT_FOCUSABLE) == 0) {
                top = state;
            }
        }
        WindowManagerService.nativeSetFocus(top != null ? top.surface : null);
        for (WindowState state : windows) {
            boolean focused = state == top;
            if (focused == state.focused) continue;
            state.focused = focused;
            try {
                state.window.windowFocusChanged(focused, true);
            } catch (RemoteException e) {
                // The window is in this process.
            }
        }
    }

    private static void frames(WindowState state, Rect outFrame, Rect outContentInsets, Rect outStableInsets,
            Rect outOutsets, DisplayCutout.ParcelableWrapper outCutout) {
        if (outFrame != null) outFrame.set(0, 0, state.width, state.height);
        if (outContentInsets != null) outContentInsets.setEmpty();
        if (outStableInsets != null) outStableInsets.setEmpty();
        if (outOutsets != null) outOutsets.setEmpty();
        if (outCutout != null) outCutout.set(DisplayCutout.NO_CUTOUT);
    }

    // What a window tells the window manager that Mead needn't act on.

    @Override public void finishDrawing(IWindow window) {}
    @Override public void setTransparentRegion(IWindow window, Region region) {}
    @Override public void setInsets(IWindow window, int touchableInsets, Rect contentInsets, Rect visibleInsets, Region touchableRegion) {}
    @Override public void getDisplayFrame(IWindow window, Rect outDisplayFrame) {
        outDisplayFrame.set(0, 0, appWidth(), appHeight());
    }
    @Override public void onRectangleOnScreenRequested(IBinder token, Rect rectangle) {}
    @Override public void pokeDrawLock(IBinder window) {}
    @Override public void setInTouchMode(boolean showFocus) {}
    @Override public boolean getInTouchMode() { return true; }
    @Override public void reportSystemGestureExclusionChanged(IWindow window, java.util.List<Rect> exclusionRects) {}
    @Override public void updatePointerIcon(IWindow window) {}
}
