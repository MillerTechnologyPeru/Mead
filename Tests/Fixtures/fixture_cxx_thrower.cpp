// Throws, so that the exception leaves this library for the one that calls.

#include "fixture_cxx.h"

#include <stdexcept>
#include <string>

extern "C" void fixture_cxx_throw_custom(int code) {
    throw FixtureError{ code };
}

extern "C" void fixture_cxx_throw_standard(int value) {
    throw std::runtime_error("value " + std::to_string(value));
}
