// A bionic JNI library for ART in Mead, as a game's or a video player's
// native code: Tests/ART/mead/check/NativeSurfaceCheck.java hands it
// SurfaceViews' surfaces, and it takes each one's ANativeWindow with
// ANativeWindow_fromSurface. It fills one on the CPU (setBuffersGeometry,
// lock, unlockAndPost) and draws to the other with EGL and GLES on the
// default display, then says what it saw, for the check to compare.

#include <EGL/egl.h>
#include <GLES2/gl2.h>
#include <android/native_window.h>
#include <android/native_window_jni.h>
#include <jni.h>
#include <stdarg.h>
#include <stdint.h>
#include <stdio.h>

static jstring say(JNIEnv *env, const char *format, ...) __attribute__((format(printf, 2, 3)));

static jstring say(JNIEnv *env, const char *format, ...) {
    char line[256];
    va_list arguments;
    va_start(arguments, format);
    vsnprintf(line, sizeof(line), format, arguments);
    va_end(arguments);
    return (*env)->NewStringUTF(env, line);
}

// Fills the surface with color (0xAARRGGBB) as RGBA_8888.
static jstring fill(JNIEnv *env, jclass type, jobject surface, jint color) {
    (void)type;
    ANativeWindow *window = ANativeWindow_fromSurface(env, surface);
    if (!window)
        return say(env, "no window");
    int width = ANativeWindow_getWidth(window), height = ANativeWindow_getHeight(window);
    if (ANativeWindow_setBuffersGeometry(window, 0, 0, WINDOW_FORMAT_RGBA_8888) != 0) {
        ANativeWindow_release(window);
        return say(env, "setBuffersGeometry failed");
    }
    ANativeWindow_Buffer buffer;
    if (ANativeWindow_lock(window, &buffer, NULL) != 0) {
        ANativeWindow_release(window);
        return say(env, "lock failed");
    }
    // RGBA_8888 is R, G, B, A in memory.
    uint32_t pixel = 0xff000000u | ((uint32_t)color & 0xff) << 16 | ((uint32_t)color & 0xff00) |
                     (((uint32_t)color >> 16) & 0xff);
    for (int32_t y = 0; y < buffer.height; y++) {
        uint32_t *row = (uint32_t *)buffer.bits + (size_t)y * (size_t)buffer.stride;
        for (int32_t x = 0; x < buffer.width; x++)
            row[x] = pixel;
    }
    int posted = ANativeWindow_unlockAndPost(window);
    jstring result = say(env, "window %dx%d, buffer %dx%d format %d, posted %d", width, height, buffer.width,
                         buffer.height, buffer.format, posted);
    ANativeWindow_release(window);
    return result;
}

// Draws frames cleared to red, green, blue with EGL and GLES 2 and reads the
// last one's middle back before showing it.
static jstring draw(JNIEnv *env, jclass type, jobject surface, jfloat red, jfloat green, jfloat blue, jint frames) {
    (void)type;
    ANativeWindow *window = ANativeWindow_fromSurface(env, surface);
    if (!window)
        return say(env, "no window");
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    if (display == EGL_NO_DISPLAY || !eglInitialize(display, NULL, NULL)) {
        ANativeWindow_release(window);
        return say(env, "no EGL display: 0x%x", eglGetError());
    }
    const EGLint attributes[] = { EGL_SURFACE_TYPE, EGL_WINDOW_BIT, EGL_RENDERABLE_TYPE, EGL_OPENGL_ES2_BIT,
                                  EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8, EGL_NONE };
    EGLConfig config;
    EGLint count = 0;
    if (!eglChooseConfig(display, attributes, &config, 1, &count) || count < 1) {
        ANativeWindow_release(window);
        return say(env, "no EGL config: 0x%x", eglGetError());
    }
    EGLSurface drawn = eglCreateWindowSurface(display, config, window, NULL);
    if (drawn == EGL_NO_SURFACE) {
        ANativeWindow_release(window);
        return say(env, "no EGL surface: 0x%x", eglGetError());
    }
    const EGLint contextAttributes[] = { EGL_CONTEXT_CLIENT_VERSION, 2, EGL_NONE };
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, contextAttributes);
    if (context == EGL_NO_CONTEXT || !eglMakeCurrent(display, drawn, drawn, context)) {
        eglDestroySurface(display, drawn);
        ANativeWindow_release(window);
        return say(env, "no EGL context: 0x%x", eglGetError());
    }
    // Frames back to back on the UI thread, not paced: at interval 1 a swap
    // waits for the compositor's frame callback, which never comes while
    // the screen is blanked.
    eglSwapInterval(display, 0);
    EGLint width = 0, height = 0;
    eglQuerySurface(display, drawn, EGL_WIDTH, &width);
    eglQuerySurface(display, drawn, EGL_HEIGHT, &height);
    unsigned char middle[4] = { 0 };
    EGLBoolean swapped = EGL_TRUE;
    for (int frame = 0; frame < frames; frame++) {
        glViewport(0, 0, width, height);
        glClearColor(red, green, blue, 1);
        glClear(GL_COLOR_BUFFER_BIT);
        if (frame == frames - 1)
            glReadPixels(width / 2, height / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, middle);
        swapped = swapped && eglSwapBuffers(display, drawn);
    }
    eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT);
    eglDestroyContext(display, context);
    eglDestroySurface(display, drawn);
    ANativeWindow_release(window);
    return say(env, "surface %dx%d, middle %02x%02x%02x, swapped %s", width, height, middle[0], middle[1], middle[2],
               swapped ? "yes" : "no");
}

JNIEXPORT jint JNI_OnLoad(JavaVM *vm, void *reserved) {
    (void)reserved;
    JNIEnv *env = NULL;
    if ((*vm)->GetEnv(vm, (void **)&env, JNI_VERSION_1_6) != JNI_OK)
        return JNI_ERR;
    jclass type = (*env)->FindClass(env, "mead/check/NativeSurfaceCheck");
    if (!type)
        return JNI_ERR;
    const JNINativeMethod methods[] = {
        { "fill", "(Landroid/view/Surface;I)Ljava/lang/String;", (void *)fill },
        { "draw", "(Landroid/view/Surface;FFFI)Ljava/lang/String;", (void *)draw },
    };
    if ((*env)->RegisterNatives(env, type, methods, 2) != JNI_OK)
        return JNI_ERR;
    return JNI_VERSION_1_6;
}
