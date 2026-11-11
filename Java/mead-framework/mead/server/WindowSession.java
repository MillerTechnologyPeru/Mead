package mead.server;

import android.graphics.Rect;
import android.graphics.Region;
import android.os.IBinder;
import android.util.MergedConfiguration;
import android.view.DisplayCutout;
import android.view.IWindow;
import android.view.InputChannel;
import android.view.InsetsState;
import android.view.Surface;
import android.view.SurfaceControl;
import android.view.SurfaceSession;
import android.view.View;
import android.view.WindowManager;
import android.view.WindowManagerGlobal;
import android.content.res.Configuration;
import java.util.HashMap;
import java.util.Map;
import mead.server.base.WindowSessionBase;

/**
 * A window session for Mead's window manager: each window added becomes a
 * window of the display bridge's (a SurfaceControl) with an input channel,
 * the size of the app's window, and is shown as it's laid out.
 */
final class WindowSession extends WindowSessionBase {
    /** A window added: its window's SurfaceControl and size. */
    private static final class WindowState {
        SurfaceControl surfaceControl;
        int width;
        int height;
        boolean shown;
    }

    private final SurfaceSession mSurfaceSession = new SurfaceSession();
    private final Map<IBinder, WindowState> mWindows = new HashMap<>();

    @Override
    public int addToDisplay(IWindow window, int seq, WindowManager.LayoutParams attrs, int viewVisibility,
            int displayId, Rect outFrame, Rect outContentInsets, Rect outStableInsets, Rect outOutsets,
            DisplayCutout.ParcelableWrapper outDisplayCutout, InputChannel outInputChannel,
            InsetsState outInsetsState) {
        MeadApp app = MeadApp.sCurrent;
        WindowState state = new WindowState();
        state.width = app != null ? app.width : 1280;
        state.height = app != null ? app.height : 720;
        CharSequence title = attrs.getTitle();
        state.surfaceControl = new SurfaceControl.Builder(mSurfaceSession)
                .setName(title != null && title.length() > 0 ? title.toString() : "Mead")
                .setBufferSize(state.width, state.height)
                .setFormat(attrs.format)
                .build();
        synchronized (mWindows) {
            mWindows.put(window.asBinder(), state);
        }
        if (outInputChannel != null) {
            Surface surface = new Surface();
            surface.copyFrom(state.surfaceControl);
            InputChannel client = WindowManagerService.nativeOpenInput(surface);
            surface.release();
            if (client != null) client.transferTo(outInputChannel);
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
            state = mWindows.remove(window.asBinder());
        }
        if (state != null) state.surfaceControl.remove();
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
            state = mWindows.get(window.asBinder());
        }
        if (state == null) return 0;
        frames(state, outFrame, outContentInsets, outStableInsets, outOutsets, outCutout);
        outOverscanInsets.setEmpty();
        outVisibleInsets.setEmpty();
        outBackdropFrame.set(outFrame);
        MeadApp app = MeadApp.sCurrent;
        Configuration config = app != null ? app.configuration() : new Configuration();
        mergedConfiguration.setConfiguration(config, new Configuration());

        int result = WindowManagerGlobal.RELAYOUT_RES_IN_TOUCH_MODE;
        if (viewVisibility == View.VISIBLE) {
            outSurfaceControl.copyFrom(state.surfaceControl);
            if (!state.shown) {
                state.shown = true;
                result |= WindowManagerGlobal.RELAYOUT_RES_FIRST_TIME | WindowManagerGlobal.RELAYOUT_RES_SURFACE_CHANGED;
                // A window shown has input focus, as Android's window manager
                // gives the top one: without it, keys aren't delivered.
                try {
                    window.windowFocusChanged(true, true);
                } catch (android.os.RemoteException e) {
                    // The window is in this process.
                }
            }
        } else {
            outSurfaceControl.release();
        }
        return result;
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
        MeadApp app = MeadApp.sCurrent;
        outDisplayFrame.set(0, 0, app != null ? app.width : 1280, app != null ? app.height : 720);
    }
    @Override public void onRectangleOnScreenRequested(IBinder token, Rect rectangle) {}
    @Override public void pokeDrawLock(IBinder window) {}
    @Override public void setInTouchMode(boolean showFocus) {}
    @Override public boolean getInTouchMode() { return true; }
    @Override public void reportSystemGestureExclusionChanged(IWindow window, java.util.List<Rect> exclusionRects) {}
    @Override public void updatePointerIcon(IWindow window) {}
}
