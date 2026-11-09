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

    MEAD_SDL_BUTTON_LEFT = 1,
};

#define MEAD_SDL_WINDOW_RESIZABLE 0x20ull

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

typedef union mead_sdl_event {
    uint32_t type;
    mead_sdl_common_event common;
    mead_sdl_window_event window;
    mead_sdl_keyboard_event key;
    mead_sdl_mouse_motion_event motion;
    mead_sdl_mouse_button_event button;
    mead_sdl_touch_event finger;
    uint8_t padding[128];
} mead_sdl_event;

#endif
