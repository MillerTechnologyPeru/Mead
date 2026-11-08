// What the two C++ fixtures share: a type thrown by one and caught by the
// other, whose typeinfo each of them has a copy of.

struct FixtureError {
    int code;
};

extern "C" void fixture_cxx_throw_custom(int code);
extern "C" void fixture_cxx_throw_standard(int value);
