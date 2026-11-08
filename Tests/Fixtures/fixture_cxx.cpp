// mead --selftest's C++ half: exceptions across libraries and through frames
// with destructors, thread_local, the threading a C++ program leans on, the
// standard library's locale machinery, and zlib.

#include "fixture_cxx.h"

#include <atomic>
#include <condition_variable>
#include <cstdio>
#include <cstring>
#include <exception>
#include <mutex>
#include <pthread.h>
#include <sstream>
#include <stdexcept>
#include <string>
#include <thread>
#include <vector>
#include <zlib.h>

#define CHECK(condition)                                                                   \
    do {                                                                                   \
        if (!(condition)) {                                                                \
            fprintf(stderr, "fixture_cxx: line %d: %s\n", __LINE__, #condition);           \
            return __LINE__;                                                               \
        }                                                                                  \
    } while (0)

namespace {

int unwound = 0;

struct CountsUnwinding {
    ~CountsUnwinding() { unwound++; }
};

__attribute__((noinline)) void through_a_frame(int code) {
    CountsUnwinding guard;
    fixture_cxx_throw_custom(code);
}

std::atomic<int> thread_local_destroyed{ 0 };

struct ThreadCounter {
    int value;
    ThreadCounter() : value(41) {}
    ~ThreadCounter() { thread_local_destroyed++; }
};

thread_local ThreadCounter counter;

int test_exceptions() {
    bool caught = false;
    try {
        through_a_frame(7);
    } catch (const FixtureError &error) {
        caught = error.code == 7;
    }
    CHECK(caught);
    CHECK(unwound == 1);

    std::string message;
    try {
        fixture_cxx_throw_standard(42);
    } catch (const std::exception &error) {
        message = error.what();
    }
    CHECK(message == "value 42");

    bool rethrown = false;
    try {
        try {
            fixture_cxx_throw_custom(1);
        } catch (...) {
            throw;
        }
    } catch (const FixtureError &) {
        rethrown = true;
    }
    CHECK(rethrown);
    CHECK(std::current_exception() == nullptr);
    return 0;
}

int test_thread_local() {
    CHECK(counter.value == 41);
    counter.value = 100;
    int seen = 0;
    std::thread worker([&] {
        seen = counter.value;
        counter.value = 5;
    });
    worker.join();
    CHECK(seen == 41);
    CHECK(counter.value == 100);
    CHECK(thread_local_destroyed.load() == 1);
    return 0;
}

int test_exception_on_a_thread() {
    bool caught = false;
    std::thread worker([&] {
        try {
            through_a_frame(9);
        } catch (const FixtureError &error) {
            caught = error.code == 9;
        }
    });
    worker.join();
    CHECK(caught);
    return 0;
}

int test_threading() {
    std::mutex mutex;
    std::condition_variable changed;
    int turn = 0;
    std::thread worker([&] {
        std::unique_lock<std::mutex> lock(mutex);
        changed.wait(lock, [&] { return turn == 1; });
        turn = 2;
        changed.notify_all();
    });
    {
        std::unique_lock<std::mutex> lock(mutex);
        turn = 1;
        changed.notify_all();
        changed.wait(lock, [&] { return turn == 2; });
    }
    worker.join();
    CHECK(turn == 2);

    static pthread_mutex_t recursive = PTHREAD_RECURSIVE_MUTEX_INITIALIZER_NP;
    CHECK(pthread_mutex_lock(&recursive) == 0);
    CHECK(pthread_mutex_lock(&recursive) == 0);
    CHECK(pthread_mutex_unlock(&recursive) == 0);
    CHECK(pthread_mutex_unlock(&recursive) == 0);
    return 0;
}

int test_library() {
    std::ostringstream stream;
    stream << 42 << ' ' << 1.5 << ' ' << std::hex << 255;
    CHECK(stream.str() == "42 1.5 ff");
    CHECK(std::stoi("123") == 123);
    bool threw = false;
    try {
        (void)std::stoi("not a number");
    } catch (const std::invalid_argument &) {
        threw = true;
    }
    CHECK(threw);
    return 0;
}

int test_zlib() {
    std::vector<unsigned char> original(64 * 1024);
    for (size_t index = 0; index < original.size(); index++)
        original[index] = (unsigned char)(index % 251);

    std::vector<unsigned char> packed(compressBound(original.size()));
    z_stream deflater;
    memset(&deflater, 0, sizeof(deflater));
    CHECK(deflateInit(&deflater, Z_BEST_COMPRESSION) == Z_OK);
    deflater.next_in = original.data();
    deflater.avail_in = (uInt)original.size();
    deflater.next_out = packed.data();
    deflater.avail_out = (uInt)packed.size();
    CHECK(deflate(&deflater, Z_FINISH) == Z_STREAM_END);
    size_t packed_size = deflater.total_out;
    CHECK(deflateEnd(&deflater) == Z_OK);
    CHECK(packed_size < original.size() / 10);

    std::vector<unsigned char> restored(original.size());
    z_stream inflater;
    memset(&inflater, 0, sizeof(inflater));
    CHECK(inflateInit(&inflater) == Z_OK);
    inflater.next_in = packed.data();
    inflater.avail_in = (uInt)packed_size;
    inflater.next_out = restored.data();
    inflater.avail_out = (uInt)restored.size();
    CHECK(inflate(&inflater, Z_FINISH) == Z_STREAM_END);
    CHECK(inflater.total_out == original.size());
    CHECK(inflateEnd(&inflater) == Z_OK);
    CHECK(restored == original);
    CHECK(crc32(0, original.data(), (uInt)original.size()) ==
          crc32(0, restored.data(), (uInt)restored.size()));
    return 0;
}

} // namespace

extern "C" int mead_selftest(void) {
    int (*const tests[])() = { test_exceptions, test_thread_local, test_exception_on_a_thread,
                               test_threading,  test_library,      test_zlib };
    for (int (*test)() : tests)
        if (int failed = test())
            return failed;
    return 0;
}
