// Holds mead_sdl.h to SDL3's own headers. Compile-only: a mismatch here is a
// layout Mead would read wrong at run time.

#include "mead_sdl.h"

#include <SDL3/SDL.h>
#include <stddef.h>

#define SAME_VALUE(mine, theirs) _Static_assert((unsigned long long)(mine) == (unsigned long long)(theirs), #mine)
#define SAME_FIELD(mine, theirs, field, theirs_field)                                      \
    _Static_assert(offsetof(mine, field) == offsetof(theirs, theirs_field), #mine "." #field); \
    _Static_assert(sizeof(((mine *)0)->field) == sizeof(((theirs *)0)->theirs_field), #mine "." #field)

SAME_VALUE(MEAD_SDL_INIT_EVENTS, SDL_INIT_EVENTS);
SAME_VALUE(MEAD_SDL_INIT_VIDEO, SDL_INIT_VIDEO);
SAME_VALUE(MEAD_SDL_WINDOW_RESIZABLE, SDL_WINDOW_RESIZABLE);
SAME_VALUE(MEAD_SDL_WINDOW_VULKAN, SDL_WINDOW_VULKAN);
SAME_VALUE(MEAD_SDL_BUTTON_LEFT, SDL_BUTTON_LEFT);
SAME_VALUE(MEAD_SDL_EVENT_QUIT, SDL_EVENT_QUIT);
SAME_VALUE(MEAD_SDL_EVENT_WINDOW_RESIZED, SDL_EVENT_WINDOW_RESIZED);
SAME_VALUE(MEAD_SDL_EVENT_WINDOW_FOCUS_GAINED, SDL_EVENT_WINDOW_FOCUS_GAINED);
SAME_VALUE(MEAD_SDL_EVENT_WINDOW_FOCUS_LOST, SDL_EVENT_WINDOW_FOCUS_LOST);
SAME_VALUE(MEAD_SDL_EVENT_WINDOW_CLOSE_REQUESTED, SDL_EVENT_WINDOW_CLOSE_REQUESTED);
SAME_VALUE(MEAD_SDL_EVENT_KEY_DOWN, SDL_EVENT_KEY_DOWN);
SAME_VALUE(MEAD_SDL_EVENT_KEY_UP, SDL_EVENT_KEY_UP);
SAME_VALUE(MEAD_SDL_EVENT_MOUSE_MOTION, SDL_EVENT_MOUSE_MOTION);
SAME_VALUE(MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN, SDL_EVENT_MOUSE_BUTTON_DOWN);
SAME_VALUE(MEAD_SDL_EVENT_MOUSE_BUTTON_UP, SDL_EVENT_MOUSE_BUTTON_UP);
SAME_VALUE(MEAD_SDL_EVENT_FINGER_DOWN, SDL_EVENT_FINGER_DOWN);
SAME_VALUE(MEAD_SDL_EVENT_FINGER_UP, SDL_EVENT_FINGER_UP);
SAME_VALUE(MEAD_SDL_EVENT_FINGER_MOTION, SDL_EVENT_FINGER_MOTION);

#define SAME_NAME(mine, theirs) _Static_assert(__builtin_strcmp(mine, theirs) == 0, #mine)

SAME_NAME(MEAD_SDL_PROP_X11_DISPLAY, SDL_PROP_WINDOW_X11_DISPLAY_POINTER);
SAME_NAME(MEAD_SDL_PROP_X11_WINDOW, SDL_PROP_WINDOW_X11_WINDOW_NUMBER);
SAME_NAME(MEAD_SDL_PROP_WAYLAND_DISPLAY, SDL_PROP_WINDOW_WAYLAND_DISPLAY_POINTER);
SAME_NAME(MEAD_SDL_PROP_WAYLAND_SURFACE, SDL_PROP_WINDOW_WAYLAND_SURFACE_POINTER);
SAME_NAME(MEAD_SDL_PROP_WAYLAND_EGL_WINDOW, SDL_PROP_WINDOW_WAYLAND_EGL_WINDOW_POINTER);

_Static_assert(sizeof(mead_sdl_event) == sizeof(SDL_Event), "SDL_Event");

SAME_FIELD(mead_sdl_common_event, SDL_CommonEvent, timestamp, timestamp);
SAME_FIELD(mead_sdl_window_event, SDL_WindowEvent, windowID, windowID);
SAME_FIELD(mead_sdl_window_event, SDL_WindowEvent, data1, data1);
SAME_FIELD(mead_sdl_window_event, SDL_WindowEvent, data2, data2);
SAME_FIELD(mead_sdl_keyboard_event, SDL_KeyboardEvent, windowID, windowID);
SAME_FIELD(mead_sdl_keyboard_event, SDL_KeyboardEvent, which, which);
SAME_FIELD(mead_sdl_keyboard_event, SDL_KeyboardEvent, scancode, scancode);
SAME_FIELD(mead_sdl_keyboard_event, SDL_KeyboardEvent, key, key);
SAME_FIELD(mead_sdl_keyboard_event, SDL_KeyboardEvent, mod, mod);
SAME_FIELD(mead_sdl_keyboard_event, SDL_KeyboardEvent, raw, raw);
SAME_FIELD(mead_sdl_keyboard_event, SDL_KeyboardEvent, down, down);
SAME_FIELD(mead_sdl_keyboard_event, SDL_KeyboardEvent, repeat, repeat);
SAME_FIELD(mead_sdl_mouse_motion_event, SDL_MouseMotionEvent, state, state);
SAME_FIELD(mead_sdl_mouse_motion_event, SDL_MouseMotionEvent, x, x);
SAME_FIELD(mead_sdl_mouse_motion_event, SDL_MouseMotionEvent, y, y);
SAME_FIELD(mead_sdl_mouse_button_event, SDL_MouseButtonEvent, button, button);
SAME_FIELD(mead_sdl_mouse_button_event, SDL_MouseButtonEvent, down, down);
SAME_FIELD(mead_sdl_mouse_button_event, SDL_MouseButtonEvent, x, x);
SAME_FIELD(mead_sdl_mouse_button_event, SDL_MouseButtonEvent, y, y);
SAME_FIELD(mead_sdl_touch_event, SDL_TouchFingerEvent, touchID, touchID);
SAME_FIELD(mead_sdl_touch_event, SDL_TouchFingerEvent, fingerID, fingerID);
SAME_FIELD(mead_sdl_touch_event, SDL_TouchFingerEvent, x, x);
SAME_FIELD(mead_sdl_touch_event, SDL_TouchFingerEvent, y, y);
SAME_FIELD(mead_sdl_touch_event, SDL_TouchFingerEvent, pressure, pressure);
