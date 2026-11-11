package mead.view;

import android.view.InputChannel;
import android.view.Surface;

// The Java face of Mead's display bridge (Sources/MeadRuntime/ARTDisplay.swift)
// for checks and programs without the window manager: windows as Surfaces,
// their input channels, and input injected as SDL would report it. Mead
// registers these natives as ART starts.
public final class MeadWindow {
    private MeadWindow() {}

    // A new window titled title, of width×height pixels, as a Surface; null
    // when there's no window to be had.
    public static native Surface create(String title, int width, int height);

    // An input channel for surface's window, for an InputEventReceiver: its
    // keys, mouse, touches and gamepads, as Android's input events.
    public static native InputChannel openInput(Surface surface);

    // A key (an SDL scancode) pressed or released in surface's window (or,
    // with surface null, the window input goes to), as the keyboard would
    // report it.
    public static native void injectKey(Surface surface, int scancode, boolean down);

    // A touch in surface's window (or, with surface null, the window input
    // goes to) at x, y from 0 to 1 across it: action 0 down, 1 up, 2 moved.
    public static native void injectTouch(Surface surface, int action, float x, float y);

    // A gamepad button (SDL's numbering: 0 south, 1 east, 2 west, 3 north...)
    // pressed or released, as the first gamepad would report it, for the
    // window input goes to.
    public static native void injectGamepadButton(int button, boolean down);
}
