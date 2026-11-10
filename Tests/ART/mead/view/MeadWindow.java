package mead.view;

import android.view.InputChannel;
import android.view.Surface;

// The Java face of Mead's display bridge (Sources/MeadRuntime/ARTDisplay.swift)
// for checks, until the window manager hands out surfaces and input
// channels: Mead registers these natives when a program it runs has this
// class.
public final class MeadWindow {
    private MeadWindow() {}

    // A new window titled title, of width×height pixels, as a Surface; null
    // when there's no window to be had.
    public static native Surface create(String title, int width, int height);

    // An input channel for surface's window, for an InputEventReceiver: its
    // keys, mouse, touches and gamepads, as Android's input events.
    public static native InputChannel openInput(Surface surface);

    // A key (an SDL scancode) pressed or released in surface's window, as
    // the keyboard would report it.
    public static native void injectKey(Surface surface, int scancode, boolean down);

    // A touch in surface's window at x, y from 0 to 1 across it: action 0
    // down, 1 up, 2 moved.
    public static native void injectTouch(Surface surface, int action, float x, float y);
}
