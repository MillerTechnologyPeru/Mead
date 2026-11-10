package mead.view;

import android.view.Surface;

// The Java face of Mead's display bridge (Sources/MeadRuntime/ARTDisplay.swift)
// for checks, until the window manager hands out surfaces: Mead registers
// these natives when a program it runs has this class.
public final class MeadWindow {
    private MeadWindow() {}

    // A new window titled title, of width×height pixels, as a Surface; null
    // when there's no window to be had.
    public static native Surface create(String title, int width, int height);
}
