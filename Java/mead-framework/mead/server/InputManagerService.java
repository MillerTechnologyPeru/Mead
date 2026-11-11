package mead.server;

import android.hardware.input.IInputDevicesChangedListener;
import android.os.Environment;
import android.util.SparseArray;
import android.view.InputDevice;
import android.view.InputEvent;
import android.view.KeyCharacterMap;
import android.view.MotionEvent;
import java.lang.reflect.Constructor;
import java.lang.reflect.Method;
import java.util.ArrayList;
import java.util.List;
import mead.server.base.InputManagerBase;

/**
 * Android's input manager for Mead: the input devices Mead's display bridge
 * sends events from (see Sources/MeadRuntime/ARTDisplayInput.swift), with
 * the same IDs: a keyboard, a mouse, a touchscreen, Android's virtual
 * keyboard, and each gamepad SDL has open.
 */
final class InputManagerService extends InputManagerBase {
    // The bridge's device IDs.
    static final int KEYBOARD = 1;
    static final int MOUSE = 2;
    static final int TOUCHSCREEN = 3;
    static final int GAMEPAD_BASE = 16;

    /** A key character map from a .kcm file, for a device. */
    static native KeyCharacterMap nativeLoadKeyCharacterMap(int deviceId, String path);

    /** SDL's IDs for the gamepads open. */
    static native int[] nativeGamepads();

    private final SparseArray<InputDevice> mDevices = new SparseArray<>();
    private final List<IInputDevicesChangedListener> mListeners = new ArrayList<>();

    @Override
    public InputDevice getInputDevice(int id) {
        synchronized (mDevices) {
            InputDevice device = mDevices.get(id);
            if (device == null) {
                device = makeDevice(id);
                if (device != null) mDevices.put(id, device);
            }
            return device;
        }
    }

    @Override
    public int[] getInputDeviceIds() {
        int[] gamepads = nativeGamepads();
        int[] ids = new int[4 + gamepads.length];
        ids[0] = KeyCharacterMap.VIRTUAL_KEYBOARD;
        ids[1] = KEYBOARD;
        ids[2] = MOUSE;
        ids[3] = TOUCHSCREEN;
        for (int i = 0; i < gamepads.length; i++) ids[4 + i] = GAMEPAD_BASE + gamepads[i];
        return ids;
    }

    @Override
    public boolean isInputDeviceEnabled(int deviceId) {
        return true;
    }

    @Override
    public void registerInputDevicesChangedListener(IInputDevicesChangedListener listener) {
        synchronized (mListeners) {
            mListeners.add(listener);
        }
    }

    @Override
    public int isInTabletMode() {
        // InputManagerService.SW_STATE_UNKNOWN: there's no tablet mode switch.
        return -1;
    }

    @Override
    public boolean hasKeys(int deviceId, int sourceMask, int[] keyCodes, boolean[] keyExists) {
        // Every key code from the keyboard, as its key character map has them.
        for (int i = 0; i < keyCodes.length; i++) keyExists[i] = true;
        return true;
    }

    @Override
    public boolean injectInputEvent(InputEvent event, int mode) {
        return false;
    }

    private static KeyCharacterMap keyCharacterMap(int id, String name) {
        String path = Environment.getRootDirectory() + "/usr/keychars/" + name;
        KeyCharacterMap map = nativeLoadKeyCharacterMap(id, path);
        if (map == null) throw new IllegalStateException("No key character map at " + path);
        return map;
    }

    private static InputDevice makeDevice(int id) {
        MeadApp app = MeadApp.sCurrent;
        int width = app != null ? app.width : 1280, height = app != null ? app.height : 720;
        switch (id) {
            case KeyCharacterMap.VIRTUAL_KEYBOARD:
                return device(id, 0, "Virtual", "virtual", InputDevice.SOURCE_KEYBOARD,
                        InputDevice.KEYBOARD_TYPE_ALPHABETIC, keyCharacterMap(id, "Virtual.kcm"));
            case KEYBOARD:
                return device(id, 0, "Mead keyboard", "mead-keyboard", InputDevice.SOURCE_KEYBOARD,
                        InputDevice.KEYBOARD_TYPE_ALPHABETIC, keyCharacterMap(id, "Generic.kcm"));
            case MOUSE: {
                InputDevice device = device(id, 0, "Mead mouse", "mead-mouse", InputDevice.SOURCE_MOUSE,
                        InputDevice.KEYBOARD_TYPE_NONE, keyCharacterMap(id, "Virtual.kcm"));
                addRange(device, MotionEvent.AXIS_X, InputDevice.SOURCE_MOUSE, 0, width - 1, 0);
                addRange(device, MotionEvent.AXIS_Y, InputDevice.SOURCE_MOUSE, 0, height - 1, 0);
                addRange(device, MotionEvent.AXIS_VSCROLL, InputDevice.SOURCE_MOUSE, -1, 1, 0);
                addRange(device, MotionEvent.AXIS_HSCROLL, InputDevice.SOURCE_MOUSE, -1, 1, 0);
                return device;
            }
            case TOUCHSCREEN: {
                InputDevice device = device(id, 0, "Mead touchscreen", "mead-touchscreen",
                        InputDevice.SOURCE_TOUCHSCREEN, InputDevice.KEYBOARD_TYPE_NONE,
                        keyCharacterMap(id, "Virtual.kcm"));
                addRange(device, MotionEvent.AXIS_X, InputDevice.SOURCE_TOUCHSCREEN, 0, width - 1, 0);
                addRange(device, MotionEvent.AXIS_Y, InputDevice.SOURCE_TOUCHSCREEN, 0, height - 1, 0);
                addRange(device, MotionEvent.AXIS_PRESSURE, InputDevice.SOURCE_TOUCHSCREEN, 0, 1, 0);
                addRange(device, MotionEvent.AXIS_SIZE, InputDevice.SOURCE_TOUCHSCREEN, 0, 1, 0);
                return device;
            }
            default: {
                if (id < GAMEPAD_BASE) return null;
                int sources = InputDevice.SOURCE_GAMEPAD | InputDevice.SOURCE_JOYSTICK;
                InputDevice device = device(id, id - GAMEPAD_BASE + 1, "Mead gamepad " + (id - GAMEPAD_BASE),
                        "mead-gamepad-" + (id - GAMEPAD_BASE), sources, InputDevice.KEYBOARD_TYPE_NON_ALPHABETIC,
                        keyCharacterMap(id, "Generic.kcm"));
                for (int axis : new int[] {MotionEvent.AXIS_X, MotionEvent.AXIS_Y, MotionEvent.AXIS_Z,
                        MotionEvent.AXIS_RZ}) {
                    addRange(device, axis, InputDevice.SOURCE_JOYSTICK, -1, 1, 0.1f);
                }
                for (int axis : new int[] {MotionEvent.AXIS_LTRIGGER, MotionEvent.AXIS_RTRIGGER,
                        MotionEvent.AXIS_GAS, MotionEvent.AXIS_BRAKE}) {
                    addRange(device, axis, InputDevice.SOURCE_JOYSTICK, 0, 1, 0);
                }
                return device;
            }
        }
    }

    // InputDevice's constructor and addMotionRange are the framework's own,
    // which the input manager's system side uses on Android.

    private static InputDevice device(int id, int controllerNumber, String name, String descriptor, int sources,
            int keyboardType, KeyCharacterMap keyCharacterMap) {
        try {
            Constructor<InputDevice> constructor = InputDevice.class.getDeclaredConstructor(int.class, int.class,
                    int.class, String.class, int.class, int.class, String.class, boolean.class, int.class,
                    int.class, KeyCharacterMap.class, boolean.class, boolean.class, boolean.class);
            constructor.setAccessible(true);
            return constructor.newInstance(id, 0, controllerNumber, name, 0, 0, descriptor, id >= GAMEPAD_BASE,
                    sources, keyboardType, keyCharacterMap, false, false, false);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("InputDevice has no constructor to make one with", e);
        }
    }

    private static void addRange(InputDevice device, int axis, int source, float min, float max, float flat) {
        try {
            Method add = InputDevice.class.getDeclaredMethod("addMotionRange", int.class, int.class, float.class,
                    float.class, float.class, float.class, float.class);
            add.setAccessible(true);
            add.invoke(device, axis, source, min, max, flat, 0f, 0f);
        } catch (ReflectiveOperationException e) {
            throw new IllegalStateException("InputDevice has no addMotionRange", e);
        }
    }
}
