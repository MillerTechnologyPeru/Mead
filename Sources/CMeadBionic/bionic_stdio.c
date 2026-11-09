#include "bionic_internal.h"

#include <stdarg.h>
#include <sys/types.h>
#include <wchar.h>

// FILE is opaque in both libraries, so glibc's streams pass through Android
// code untouched. The exception is __sF, three FILEs Android code built for
// old API levels takes the addresses of; those are placeholders here, as big
// as bionic's so that __sF[2] lands where the code expects.
enum { BIONIC_FILE_SIZE = 152 };
char bionic___sF[3 * BIONIC_FILE_SIZE];

FILE *bionic_file(FILE *file) {
    char *at = (char *)file;
    if (at < bionic___sF || at >= bionic___sF + sizeof(bionic___sF))
        return file;
    switch ((at - bionic___sF) / BIONIC_FILE_SIZE) {
    case 0: return stdin;
    case 1: return stdout;
    default: return stderr;
    }
}

int bionic_fclose(FILE *file) { return fclose(bionic_file(file)); }
int bionic_fflush(FILE *file) { return fflush(file ? bionic_file(file) : NULL); }
int bionic_fileno(FILE *file) { return fileno(bionic_file(file)); }
int bionic_feof(FILE *file) { return feof(bionic_file(file)); }
int bionic_ferror(FILE *file) { return ferror(bionic_file(file)); }
void bionic_clearerr(FILE *file) { clearerr(bionic_file(file)); }
void bionic_rewind(FILE *file) { rewind(bionic_file(file)); }
int bionic_fgetc(FILE *file) { return fgetc(bionic_file(file)); }
int bionic_getc(FILE *file) { return getc(bionic_file(file)); }
int bionic_fputc(int c, FILE *file) { return fputc(c, bionic_file(file)); }
int bionic_putc(int c, FILE *file) { return putc(c, bionic_file(file)); }
int bionic_ungetc(int c, FILE *file) { return ungetc(c, bionic_file(file)); }
int bionic_fputs(const char *text, FILE *file) { return fputs(text, bionic_file(file)); }
char *bionic_fgets(char *buffer, int size, FILE *file) { return fgets(buffer, size, bionic_file(file)); }
long bionic_ftell(FILE *file) { return ftell(bionic_file(file)); }
off_t bionic_ftello(FILE *file) { return ftello(bionic_file(file)); }
int bionic_fseek(FILE *file, long offset, int whence) { return fseek(bionic_file(file), offset, whence); }
int bionic_fseeko(FILE *file, off_t offset, int whence) { return fseeko(bionic_file(file), offset, whence); }
// On 64-bit Android, off_t is 64 bits and the *64 names are the same calls.
off_t bionic_ftello64(FILE *file) { return ftello(bionic_file(file)); }
int bionic_fseeko64(FILE *file, off_t offset, int whence) { return fseeko(bionic_file(file), offset, whence); }
int bionic_setvbuf(FILE *file, char *buffer, int mode, size_t size) {
    return setvbuf(bionic_file(file), buffer, mode, size);
}

// bionic's BUFSIZ is 1024 and glibc's 8192: a buffer given without a size is
// only as big as Android's idea of it.
void bionic_setbuf(FILE *file, char *buffer) {
    setvbuf(bionic_file(file), buffer, buffer ? _IOFBF : _IONBF, 1024);
}

size_t bionic_fread(void *buffer, size_t size, size_t count, FILE *file) {
    return fread(buffer, size, count, bionic_file(file));
}

size_t bionic_fwrite(const void *buffer, size_t size, size_t count, FILE *file) {
    return fwrite(buffer, size, count, bionic_file(file));
}

FILE *bionic_freopen(const char *path, const char *mode, FILE *file) {
    return freopen(path, mode, bionic_file(file));
}

int bionic_vfprintf(FILE *file, const char *format, va_list arguments) {
    return vfprintf(bionic_file(file), format, arguments);
}

int bionic_fprintf(FILE *file, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int result = vfprintf(bionic_file(file), format, arguments);
    va_end(arguments);
    return result;
}

int bionic_vfscanf(FILE *file, const char *format, va_list arguments) {
    return vfscanf(bionic_file(file), format, arguments);
}

int bionic_fscanf(FILE *file, const char *format, ...) {
    va_list arguments;
    va_start(arguments, format);
    int result = vfscanf(bionic_file(file), format, arguments);
    va_end(arguments);
    return result;
}
