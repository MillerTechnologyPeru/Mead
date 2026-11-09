// A real GLES 3 app on native_app_glue: makes a context on its window, draws
// a triangle with shaders, reads the pixels back, and presents. Only success
// gets as far as finishing.

#include <EGL/egl.h>
#include <GLES3/gl3.h>
#include <android/log.h>
#include <android/native_window.h>
#include <android_native_app_glue.h>
#include <stdio.h>
#include <string.h>
#include <unistd.h>

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fixture_gles: line %d: %s (egl 0x%x, gl 0x%x)\n", __LINE__,   \
                    #condition, eglGetError(), glGetError());                              \
            _exit(2);                                                                      \
        }                                                                                  \
    } while (0)

static const char vertex_source[] =
    "#version 300 es\n"
    "layout(location = 0) in vec2 position;\n"
    "void main() { gl_Position = vec4(position, 0.0, 1.0); }\n";

static const char fragment_source[] =
    "#version 300 es\n"
    "precision mediump float;\n"
    "out vec4 color;\n"
    "void main() { color = vec4(0.0, 1.0, 0.0, 1.0); }\n";

static GLuint compile(GLenum type, const char *source) {
    GLuint shader = glCreateShader(type);
    glShaderSource(shader, 1, &source, NULL);
    glCompileShader(shader);
    GLint compiled = 0;
    glGetShaderiv(shader, GL_COMPILE_STATUS, &compiled);
    CHECK(compiled);
    return shader;
}

static bool drawn;

static void render(struct android_app *app) {
    EGLDisplay display = eglGetDisplay(EGL_DEFAULT_DISPLAY);
    CHECK(display != EGL_NO_DISPLAY);
    EGLint major = 0, minor = 0;
    CHECK(eglInitialize(display, &major, &minor));

    // EGL_RECORDABLE_ANDROID is Android's alone, and games ask for it.
    const EGLint attributes[] = {
        EGL_RENDERABLE_TYPE, EGL_OPENGL_ES3_BIT, EGL_SURFACE_TYPE, EGL_WINDOW_BIT,
        EGL_RED_SIZE, 8, EGL_GREEN_SIZE, 8, EGL_BLUE_SIZE, 8,
        0x3142 /* EGL_RECORDABLE_ANDROID */, EGL_TRUE, EGL_NONE,
    };
    EGLConfig config;
    EGLint count = 0;
    CHECK(eglChooseConfig(display, attributes, &config, 1, &count) && count == 1);

    // What games hand straight to setBuffersGeometry: a window format.
    EGLint format = 0;
    CHECK(eglGetConfigAttrib(display, config, EGL_NATIVE_VISUAL_ID, &format));
    CHECK(format == WINDOW_FORMAT_RGBA_8888 || format == WINDOW_FORMAT_RGBX_8888);
    CHECK(ANativeWindow_setBuffersGeometry(app->window, 0, 0, format) == 0);

    EGLSurface surface = eglCreateWindowSurface(display, config, app->window, NULL);
    CHECK(surface != EGL_NO_SURFACE);
    const EGLint context_attributes[] = { EGL_CONTEXT_CLIENT_VERSION, 3, EGL_NONE };
    EGLContext context = eglCreateContext(display, config, EGL_NO_CONTEXT, context_attributes);
    CHECK(context != EGL_NO_CONTEXT);
    CHECK(eglMakeCurrent(display, surface, surface, context));

    EGLint width = 0, height = 0;
    CHECK(eglQuerySurface(display, surface, EGL_WIDTH, &width));
    CHECK(eglQuerySurface(display, surface, EGL_HEIGHT, &height));
    CHECK(width == ANativeWindow_getWidth(app->window));
    CHECK(height == ANativeWindow_getHeight(app->window));

    const char *version = (const char *)glGetString(GL_VERSION);
    CHECK(version != NULL && strncmp(version, "OpenGL ES 3", 11) == 0);
    __android_log_print(ANDROID_LOG_INFO, "fixture_gles", "%s on %s", version, glGetString(GL_RENDERER));

    GLuint program = glCreateProgram();
    glAttachShader(program, compile(GL_VERTEX_SHADER, vertex_source));
    glAttachShader(program, compile(GL_FRAGMENT_SHADER, fragment_source));
    glLinkProgram(program);
    GLint linked = 0;
    glGetProgramiv(program, GL_LINK_STATUS, &linked);
    CHECK(linked);
    glUseProgram(program);

    const GLfloat triangle[] = { -0.5f, -0.5f, 0.5f, -0.5f, 0.0f, 0.5f };
    GLuint buffer;
    glGenBuffers(1, &buffer);
    glBindBuffer(GL_ARRAY_BUFFER, buffer);
    glBufferData(GL_ARRAY_BUFFER, sizeof(triangle), triangle, GL_STATIC_DRAW);
    GLuint vertices;
    glGenVertexArrays(1, &vertices);
    glBindVertexArray(vertices);
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, 0);

    glViewport(0, 0, width, height);
    glClearColor(1.0f, 0.0f, 0.0f, 1.0f);
    glClear(GL_COLOR_BUFFER_BIT);
    glDrawArrays(GL_TRIANGLES, 0, 3);
    CHECK(glGetError() == GL_NO_ERROR);

    GLubyte center[4], corner[4];
    glReadPixels(width / 2, height / 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, center);
    glReadPixels(2, 2, 1, 1, GL_RGBA, GL_UNSIGNED_BYTE, corner);
    CHECK(center[0] == 0 && center[1] == 255 && center[2] == 0);
    CHECK(corner[0] == 255 && corner[1] == 0 && corner[2] == 0);

    // Through eglGetProcAddress too, as engines load much of GL.
    void (*clear_color)(GLfloat, GLfloat, GLfloat, GLfloat) =
        (void (*)(GLfloat, GLfloat, GLfloat, GLfloat))eglGetProcAddress("glClearColor");
    CHECK(clear_color != NULL);
    clear_color(0.0f, 0.0f, 1.0f, 1.0f);

    CHECK(eglSwapBuffers(display, surface));
    CHECK(eglMakeCurrent(display, EGL_NO_SURFACE, EGL_NO_SURFACE, EGL_NO_CONTEXT));
    CHECK(eglDestroyContext(display, context));
    CHECK(eglDestroySurface(display, surface));
    CHECK(eglTerminate(display));

    drawn = true;
    __android_log_print(ANDROID_LOG_INFO, "fixture_gles", "the triangle's pixels are right");
    ANativeActivity_finish(app->activity);
}

static void on_command(struct android_app *app, int32_t command) {
    if (command == APP_CMD_INIT_WINDOW)
        render(app);
}

void android_main(struct android_app *app) {
    app->onAppCmd = on_command;
    while (!app->destroyRequested) {
        struct android_poll_source *source = NULL;
        int ident = ALooper_pollOnce(-1, NULL, NULL, (void **)&source);
        if (ident >= 0 && source != NULL)
            source->process(app, source);
    }
    CHECK(drawn);
}
