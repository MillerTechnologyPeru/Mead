#ifndef MEAD_SDL_H
#define MEAD_SDL_H

// The parts of SDL3's ABI Mead uses. SDL is loaded at run time, so there is
// no SDL header in the build: Tests/Fixtures/sdl_abi_check.c holds these
// layouts and numbers against the real one.

#include <stdbool.h>
#include <stdint.h>

enum {
    MEAD_SDL_INIT_EVENTS = 0x00004000,
    MEAD_SDL_INIT_VIDEO = 0x00000020,
    MEAD_SDL_INIT_AUDIO = 0x00000010,
    MEAD_SDL_INIT_GAMEPAD = 0x00002000,

    MEAD_SDL_AUDIO_U8 = 0x0008,
    MEAD_SDL_AUDIO_S16LE = 0x8010,
    MEAD_SDL_AUDIO_S32LE = 0x8020,
    MEAD_SDL_AUDIO_F32LE = 0x8120,

    MEAD_SDL_EVENT_QUIT = 0x100,
    MEAD_SDL_EVENT_WINDOW_RESIZED = 0x206,
    MEAD_SDL_EVENT_WINDOW_FOCUS_GAINED = 0x20e,
    MEAD_SDL_EVENT_WINDOW_FOCUS_LOST = 0x20f,
    MEAD_SDL_EVENT_WINDOW_CLOSE_REQUESTED = 0x210,
    MEAD_SDL_EVENT_KEY_DOWN = 0x300,
    MEAD_SDL_EVENT_KEY_UP = 0x301,
    MEAD_SDL_EVENT_MOUSE_MOTION = 0x400,
    MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN = 0x401,
    MEAD_SDL_EVENT_MOUSE_BUTTON_UP = 0x402,
    MEAD_SDL_EVENT_FINGER_DOWN = 0x700,
    MEAD_SDL_EVENT_FINGER_UP = 0x701,
    MEAD_SDL_EVENT_FINGER_MOTION = 0x702,
    MEAD_SDL_EVENT_GAMEPAD_AXIS_MOTION = 0x650,
    MEAD_SDL_EVENT_GAMEPAD_BUTTON_DOWN = 0x651,
    MEAD_SDL_EVENT_GAMEPAD_BUTTON_UP = 0x652,
    MEAD_SDL_EVENT_GAMEPAD_ADDED = 0x653,
    MEAD_SDL_EVENT_GAMEPAD_REMOVED = 0x654,

    MEAD_SDL_GAMEPAD_BUTTON_SOUTH = 0,
    MEAD_SDL_GAMEPAD_BUTTON_EAST = 1,
    MEAD_SDL_GAMEPAD_BUTTON_WEST = 2,
    MEAD_SDL_GAMEPAD_BUTTON_NORTH = 3,
    MEAD_SDL_GAMEPAD_BUTTON_BACK = 4,
    MEAD_SDL_GAMEPAD_BUTTON_GUIDE = 5,
    MEAD_SDL_GAMEPAD_BUTTON_START = 6,
    MEAD_SDL_GAMEPAD_BUTTON_LEFT_STICK = 7,
    MEAD_SDL_GAMEPAD_BUTTON_RIGHT_STICK = 8,
    MEAD_SDL_GAMEPAD_BUTTON_LEFT_SHOULDER = 9,
    MEAD_SDL_GAMEPAD_BUTTON_RIGHT_SHOULDER = 10,
    MEAD_SDL_GAMEPAD_BUTTON_DPAD_UP = 11,
    MEAD_SDL_GAMEPAD_BUTTON_DPAD_DOWN = 12,
    MEAD_SDL_GAMEPAD_BUTTON_DPAD_LEFT = 13,
    MEAD_SDL_GAMEPAD_BUTTON_DPAD_RIGHT = 14,

    MEAD_SDL_GAMEPAD_AXIS_LEFTX = 0,
    MEAD_SDL_GAMEPAD_AXIS_LEFTY = 1,
    MEAD_SDL_GAMEPAD_AXIS_RIGHTX = 2,
    MEAD_SDL_GAMEPAD_AXIS_RIGHTY = 3,
    MEAD_SDL_GAMEPAD_AXIS_LEFT_TRIGGER = 4,
    MEAD_SDL_GAMEPAD_AXIS_RIGHT_TRIGGER = 5,

    MEAD_SDL_BUTTON_LEFT = 1,
};

#define MEAD_SDL_WINDOW_RESIZABLE 0x20ull
#define MEAD_SDL_WINDOW_VULKAN 0x10000000ull

#define MEAD_SDL_AUDIO_DEVICE_DEFAULT_PLAYBACK 0xFFFFFFFFu
#define MEAD_SDL_AUDIO_DEVICE_DEFAULT_RECORDING 0xFFFFFFFEu

typedef struct mead_sdl_audio_spec {
    int32_t format;
    int32_t channels;
    int32_t freq;
} mead_sdl_audio_spec;

#define MEAD_SDL_PROP_X11_DISPLAY "SDL.window.x11.display"
#define MEAD_SDL_PROP_X11_WINDOW "SDL.window.x11.window"
#define MEAD_SDL_PROP_WAYLAND_DISPLAY "SDL.window.wayland.display"
#define MEAD_SDL_PROP_WAYLAND_SURFACE "SDL.window.wayland.surface"
#define MEAD_SDL_PROP_WAYLAND_EGL_WINDOW "SDL.window.wayland.egl_window"

typedef struct mead_sdl_common_event {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
} mead_sdl_common_event;

typedef struct mead_sdl_window_event {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    int32_t data1;
    int32_t data2;
} mead_sdl_window_event;

typedef struct mead_sdl_keyboard_event {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    uint32_t which;
    uint32_t scancode;
    uint32_t key;
    uint16_t mod;
    uint16_t raw;
    bool down;
    bool repeat;
} mead_sdl_keyboard_event;

typedef struct mead_sdl_mouse_motion_event {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    uint32_t which;
    uint32_t state;
    float x;
    float y;
    float xrel;
    float yrel;
} mead_sdl_mouse_motion_event;

typedef struct mead_sdl_mouse_button_event {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t windowID;
    uint32_t which;
    uint8_t button;
    bool down;
    uint8_t clicks;
    uint8_t padding;
    float x;
    float y;
} mead_sdl_mouse_button_event;

typedef struct mead_sdl_touch_event {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint64_t touchID;
    uint64_t fingerID;
    float x;
    float y;
    float dx;
    float dy;
    float pressure;
    uint32_t windowID;
} mead_sdl_touch_event;

typedef struct mead_sdl_gamepad_device_event {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t which;
} mead_sdl_gamepad_device_event;

typedef struct mead_sdl_gamepad_button_event {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t which;
    uint8_t button;
    bool down;
    uint8_t padding1;
    uint8_t padding2;
} mead_sdl_gamepad_button_event;

typedef struct mead_sdl_gamepad_axis_event {
    uint32_t type;
    uint32_t reserved;
    uint64_t timestamp;
    uint32_t which;
    uint8_t axis;
    uint8_t padding1;
    uint8_t padding2;
    uint8_t padding3;
    int16_t value;
    uint16_t padding4;
} mead_sdl_gamepad_axis_event;

typedef union mead_sdl_event {
    uint32_t type;
    mead_sdl_common_event common;
    mead_sdl_window_event window;
    mead_sdl_keyboard_event key;
    mead_sdl_mouse_motion_event motion;
    mead_sdl_mouse_button_event button;
    mead_sdl_touch_event finger;
    mead_sdl_gamepad_device_event gdevice;
    mead_sdl_gamepad_button_event gbutton;
    mead_sdl_gamepad_axis_event gaxis;
    uint8_t padding[128];
} mead_sdl_event;

#endif
