import CMeadAndroid
import Glibc
@testable import MeadAndroid
import MeadJava
import MeadJNI
import Testing

// The pieces of libandroid.so on their own; the whole of it, with a real
// native_app_glue app, is the gate in Scripts/docker-test.sh.

private func pipePair() -> (read: Int32, write: Int32) {
    var fds: [Int32] = [0, 0]
    #expect(pipe(&fds) == 0)
    return (fds[0], fds[1])
}

@Test func aLooperTimesOutWhenNothingHappens() {
    #expect(Looper().pollOnce(timeout: 0, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_TIMEOUT)
}

@Test func wakingALooperReturnsWake() {
    let looper = Looper()
    looper.wake()
    #expect(looper.pollOnce(timeout: 1000, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_WAKE)
    #expect(looper.pollOnce(timeout: 0, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_TIMEOUT)
}

@Test func aDescriptorWithAnIdentReturnsIt() {
    let looper = Looper()
    let pipes = pipePair()
    var cookie = 7
    #expect(looper.addFd(pipes.read, ident: 5, events: Int32(MEAD_LOOPER_EVENT_INPUT), callback: nil, data: &cookie) == 1)
    #expect(looper.pollOnce(timeout: 0, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_TIMEOUT)
    var byte: UInt8 = 1
    #expect(write(pipes.write, &byte, 1) == 1)
    var fd: Int32 = 0, events: Int32 = 0
    var data: UnsafeMutableRawPointer?
    #expect(looper.pollOnce(timeout: 1000, outFd: &fd, outEvents: &events, outData: &data) == 5)
    #expect(fd == pipes.read)
    #expect(events & Int32(MEAD_LOOPER_EVENT_INPUT) != 0)
    #expect(data?.assumingMemoryBound(to: Int.self).pointee == 7)
    #expect(looper.removeFd(pipes.read) == 1)
    #expect(looper.removeFd(pipes.read) == 0)
    close(pipes.read)
    close(pipes.write)
}

@Test func anIdentlessDescriptorNeedsACallback() {
    #expect(Looper().addFd(0, ident: -1, events: 1, callback: nil, data: nil) == -1)
}

private nonisolated(unsafe) var callbackCalls = 0

@Test func aCallbackReturningZeroIsRemoved() {
    let looper = Looper()
    let pipes = pipePair()
    callbackCalls = 0
    let added = looper.addFd(pipes.read, ident: 0, events: Int32(MEAD_LOOPER_EVENT_INPUT), callback: { _, _, _ in
        callbackCalls += 1
        return 0
    }, data: nil)
    #expect(added == 1)
    var byte: UInt8 = 1
    _ = write(pipes.write, &byte, 1)
    #expect(looper.pollOnce(timeout: 1000, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_CALLBACK)
    #expect(callbackCalls == 1)
    #expect(looper.pollOnce(timeout: 0, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_TIMEOUT)
    #expect(looper.removeFd(pipes.read) == 0)
    close(pipes.read)
    close(pipes.write)
}

@Test func theInputQueueDeliversInOrderAndWakesItsLooper() {
    let looper = Looper()
    let queue = InputQueue()
    queue.attach(to: looper, ident: 2, callback: nil, data: nil)
    #expect(!queue.hasEvents)
    queue.enqueue(InputEvent(type: AINPUT_EVENT_TYPE_KEY, source: AINPUT_SOURCE_KEYBOARD, action: 0, eventTime: 1, downTime: 1, keyCode: 29))
    queue.enqueue(InputEvent(type: AINPUT_EVENT_TYPE_KEY, source: AINPUT_SOURCE_KEYBOARD, action: 1, eventTime: 2, downTime: 1, keyCode: 30))
    #expect(queue.hasEvents)
    #expect(looper.pollOnce(timeout: 1000, outFd: nil, outEvents: nil, outData: nil) == 2)
    #expect(queue.next()?.keyCode == 29)
    #expect(queue.next()?.keyCode == 30)
    #expect(queue.next() == nil)
    #expect(looper.pollOnce(timeout: 0, outFd: nil, outEvents: nil, outData: nil) == ALOOPER_POLL_TIMEOUT)
    queue.detach()
}

@Test func keysMapToAndroidsCodes() {
    #expect(androidKeyCode(forScancode: 4) == 29) // A
    #expect(androidKeyCode(forScancode: 29) == 54) // Z
    #expect(androidKeyCode(forScancode: 30) == 8) // 1
    #expect(androidKeyCode(forScancode: 39) == 7) // 0
    #expect(androidKeyCode(forScancode: 41) == 111) // escape
    #expect(androidKeyCode(forScancode: 79) == 22) // right
    #expect(androidKeyCode(forScancode: 500) == 0)
}

@Test func gamepadButtonsMapToAndroidsCodes() {
    #expect(androidKeyCode(forGamepadButton: 0) == 96) // south is A
    #expect(androidKeyCode(forGamepadButton: 3) == 100) // north is Y
    #expect(androidKeyCode(forGamepadButton: 11) == 19) // the D-pad is the arrow keys
    #expect(androidKeyCode(forGamepadButton: 200) == 0)
}

@Test func gamepadAxesMapToAndroidsAndKeepTheirRange() {
    #expect(androidAxes(forGamepadAxis: 0) == [AMOTION_EVENT_AXIS_X])
    #expect(androidAxes(forGamepadAxis: 3) == [AMOTION_EVENT_AXIS_RZ])
    #expect(androidAxes(forGamepadAxis: 4) == [AMOTION_EVENT_AXIS_LTRIGGER, AMOTION_EVENT_AXIS_BRAKE])
    #expect(androidAxisValue(32767) == 1)
    #expect(androidAxisValue(-32768) == -1)
    #expect(androidAxisValue(0) == 0)
}

@Test func assetNamesCannotLeaveTheAssets() {
    let manager = AssetManager()
    manager.root = "/game/assets"
    #expect(manager.path(for: "a/b.txt") == "/game/assets/a/b.txt")
    #expect(manager.path(for: "") == "/game/assets")
    #expect(manager.path(for: "../secret") == nil)
    #expect(manager.path(for: "a/../../secret") == nil)
    #expect(manager.path(for: "/etc/passwd") == nil)
}

@Test func aConfigurationKeepsWhatIsSet() {
    let pointer = AConfiguration_new()
    defer { AConfiguration_delete(pointer) }
    AConfiguration_setDensity(pointer, 320)
    #expect(AConfiguration_getDensity(pointer) == 320)
    AConfiguration_setLanguage(pointer, "fr")
    var language: [CChar] = [0, 0]
    AConfiguration_getLanguage(pointer, &language)
    #expect(language == [0x66, 0x72])
    let copy = AConfiguration_new()
    defer { AConfiguration_delete(copy) }
    AConfiguration_copy(copy, pointer)
    #expect(AConfiguration_getDensity(copy) == 320)
}

@Test func aWindowReportsTheGeometryItIsGiven() {
    let window = NativeWindow(handle: nil, width: 800, height: 600)
    #expect(ANativeWindow_getWidth(window.pointer) == 800)
    #expect(ANativeWindow_setBuffersGeometry(window.pointer, 400, 300, 4) == 0)
    #expect(ANativeWindow_getWidth(window.pointer) == 400)
    #expect(ANativeWindow_getHeight(window.pointer) == 300)
    #expect(ANativeWindow_getFormat(window.pointer) == 4)
}

@Test func theFrameworkClassesExist() {
    JavaFramework.register()
    let runtime = JavaRuntime.shared
    for name in ["android/app/NativeActivity", "android/content/Context", "android/os/Build$VERSION",
                 "java/util/ArrayList", "java/util/HashMap", "java/util/UUID", "java/lang/System", "java/lang/Integer",
                 "org/fmod/FMOD", "com/pairip/VMRunner"] {
        #expect(runtime.existingClass(named: name)?.isSynthesized == false, "\(name)")
    }
    let context = runtime.existingClass(named: "android/content/Context")!
    #expect(runtime.existingClass(named: "android/app/NativeActivity")!.isSubclass(of: context))
    let list = runtime.existingClass(named: "java/util/List")!
    #expect(list.isInterface)
    #expect(runtime.existingClass(named: "java/util/ArrayList")!.isSubclass(of: list))
    #expect(runtime.existingClass(named: "java/util/ArrayList")!.isSubclass(of: runtime.existingClass(named: "java/util/Collection")!))
}
