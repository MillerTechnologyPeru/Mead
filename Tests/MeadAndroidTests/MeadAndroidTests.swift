import CMeadAndroid
import CMeadWindow
import Glibc
@testable import MeadAndroid
import MeadCrypto
@testable import MeadJava
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

// A callback the game asks for on the UI thread has to have run by the time
// the call returns: the game's closure and its result live on the caller's stack.

private final class UiCallbackCall {
    let activity: JavaMinecraftActivity
    var returned = false
    init(_ activity: JavaMinecraftActivity) { self.activity = activity }
}

@Test func aUiCallbackBlocksItsCallerUntilTheMainThreadRunsIt() {
    JavaFramework.register()
    let activity = JavaMinecraftActivity()
    activity.beginUiCallbacks()
    let call = UiCallbackCall(activity)
    var thread = pthread_t()
    #expect(pthread_create(&thread, nil, { argument in
        let call = Unmanaged<UiCallbackCall>.fromOpaque(argument!).takeUnretainedValue()
        call.activity.runNativeCallbackOnUiThread(1)
        call.returned = true
        return nil
    }, Unmanaged.passUnretained(call).toOpaque()) == 0)
    usleep(100_000)
    #expect(!call.returned)
    while !call.returned {
        activity.runUiCallbacks()
        usleep(1_000)
    }
    pthread_join(thread, nil)
    activity.endUiCallbacks()
}

@Test func aUiCallbackRunsWhereItIsMadeWithNoMainThreadTurning() {
    JavaFramework.register()
    let activity = JavaMinecraftActivity()
    // Nothing is answering: this must return rather than wait.
    activity.runNativeCallbackOnUiThread(1)
}

@Test func base64DecodesAsAndroidDoes() {
    func decoded(_ text: String, urlSafe: Bool = false) -> String? {
        JavaBase64.decode(Array(text.utf8), urlSafe: urlSafe).map { String(decoding: $0, as: UTF8.self) }
    }
    #expect(decoded("aGVsbG8=") == "hello")
    #expect(decoded("aGVsbG8") == "hello", "padding is optional")
    #expect(decoded("aGVs\nbG8=\n") == "hello", "line breaks are skipped")
    #expect(decoded("aGk=") == "hi")
    #expect(decoded("") == "")
    #expect(decoded("a") == nil)
    #expect(decoded("aGVsbG8=x") == nil, "nothing follows the padding")
    #expect(JavaBase64.decode(Array("-_-_".utf8), urlSafe: true) == [0xfb, 0xff, 0xbf])
}

@Test func sha256MatchesItsPublishedVectors() {
    func hex(_ bytes: [UInt8]) -> String {
        bytes.map { String(UInt($0) + 0x100, radix: 16).dropFirst() }.joined()
    }
    #expect(hex(SHA256.hash(Array("abc".utf8))) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(hex(SHA256.hash([])) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
    // Long enough that the length spills into a second block.
    #expect(hex(SHA256.hash(Array("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8)))
        == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
}

// A throwaway 2048-bit key made with OpenSSL, and its signature of the message.
private let rsaKey = "MIIBIjANBgkqhkiG9w0BAQEFAAOCAQ8AMIIBCgKCAQEAlLJ5a4GU8LlCJVyBrBbnxbKbBZZjpFAw63rRHi2qpKXZqEG21xG2i/rfGTokwDBIzM57vnwf5wxZ8trPj3mDwn9jeHErdg3ng+Gkyx0TwxfBFn/jAA/PpzqLXZjeoNq+PVPLjMQCI7B8H1zkkuh1jZI8Thguxz3/VCkgV+9MBv42Vrec0EU9zF7HAWQgjAs2NwDBJmwi/lBG1NaVhxXdcrkDqSenLydiiCV+G7ns5CN8NHoXIQVrD0YhTEb4hDe+UjafcrCUc6GPVza0wql5flFd3w1lL3vjqg8BK6fAvhDlr9Z6wBtdLcyIg/icaUDzVN4on49/1iyWpw2psTovhwIDAQAB"
private let rsaSignature = "Pu91B4UuuVX/shojUR2mjXgswXfiCqynfBQRrramZrX09tLe6HCfcg0B6DIW85RNd4DiQX5X9/tlMNpfmdcn4UeWSk/sPQU+r9omcqAmNgDAInIZzhCa+Fn/abJLFf6sX+BNoKr+2rCO/dUga5eYgkQpGg6DjipwVzmOIwVg5LoEmh8XqC0S7n296wG8W3mozgCFxwvLLapzwuoCZOfsqI+MjgjsQD2bzQyk7z40+L+AID07+5aR23gQqoFRTWdIVLg6DulfJG+3527ddqPQSsnBeQNHu9NNyGqLg2XAdqbEWI+trg+sdQsQo33s22x4tXX3hwV5y0ZvSQOsfQAzxA=="
private let rsaMessage = Array("mead signature test".utf8)

private func base64Bytes(_ text: String) -> [UInt8] { JavaBase64.decode(Array(text.utf8), urlSafe: false)! }

private func verifies(key: [UInt8], message: [UInt8], signature: [UInt8]) throws -> Bool {
    JavaFramework.register()
    let runtime = JavaRuntime.shared
    let specification = JavaX509EncodedKeySpec(encoded: runtime.newByteArray(key))
    let publicKey = try #require(try JavaKeyFactory.getInstance("RSA")?.generatePublic(specification))
    let verifier = try #require(try JavaSignature.getInstance("SHA256withRSA"))
    try verifier.initVerify(publicKey)
    verifier.update(runtime.newByteArray(message))
    return try verifier.verify(runtime.newByteArray(signature))
}

@Test func aGoodRSASignatureVerifies() throws {
    #expect(try verifies(key: base64Bytes(rsaKey), message: rsaMessage, signature: base64Bytes(rsaSignature)))
}

@Test func aChangedMessageOrSignatureDoesNotVerify() throws {
    #expect(try !verifies(key: base64Bytes(rsaKey), message: rsaMessage + [0], signature: base64Bytes(rsaSignature)))
    var signature = base64Bytes(rsaSignature)
    signature[100] ^= 1
    #expect(try !verifies(key: base64Bytes(rsaKey), message: rsaMessage, signature: signature))
    #expect(try !verifies(key: base64Bytes(rsaKey), message: rsaMessage, signature: Array(signature.dropLast())))
}

// GameActivity's input: SDL events in, Android's MotionEvents and KeyEvents out.

private final class InputRecorder {
    var motions: [JavaMotionEvent] = []
    var keys: [JavaKeyEvent] = []
    lazy var input = GameActivityInput(sendMotion: { self.motions.append($0) }, sendKey: { self.keys.append($0) }, clock: { 5 })

    func send(_ fill: (inout mead_sdl_event) -> Void) {
        var event = mead_sdl_event()
        fill(&event)
        input.handle(event, windowWidth: 1000, windowHeight: 500)
    }
}

@Test func theMouseIsAMouse() {
    JavaFramework.register()
    let recorder = InputRecorder()
    recorder.send { $0.motion.type = UInt32(MEAD_SDL_EVENT_MOUSE_MOTION); $0.motion.x = 5; $0.motion.y = 6 }
    recorder.send { $0.button.type = UInt32(MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN); $0.button.button = 1; $0.button.down = true; $0.button.x = 10; $0.button.y = 20 }
    recorder.send { $0.button.type = UInt32(MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN); $0.button.button = 3; $0.button.down = true; $0.button.x = 10; $0.button.y = 20 }
    recorder.send { $0.motion.type = UInt32(MEAD_SDL_EVENT_MOUSE_MOTION); $0.motion.x = 30; $0.motion.y = 40 }
    recorder.send { $0.button.type = UInt32(MEAD_SDL_EVENT_MOUSE_BUTTON_UP); $0.button.button = 1; $0.button.x = 30; $0.button.y = 40 }
    #expect(recorder.motions.map(\.action) == [JavaMotionEvent.actionHoverMove, JavaMotionEvent.actionButtonPress, JavaMotionEvent.actionButtonPress,
                                               JavaMotionEvent.actionHoverMove, JavaMotionEvent.actionButtonRelease])
    #expect(recorder.motions.map(\.buttonState) == [0, 1, 3, 3, 2])
    #expect(recorder.motions.map(\.actionButton) == [0, 1, 2, 0, 1])
    #expect(recorder.motions.allSatisfy { $0.source == JavaMotionEvent.sourceMouse && $0.getToolType(0) == JavaMotionEvent.toolTypeMouse })
    #expect(recorder.motions[3].getRawX(0) == 30 && recorder.motions[3].getAxisValue(JavaMotionEvent.axisY, 0) == 40)
}

@Test func twoFingersAreTwoPointers() {
    JavaFramework.register()
    let recorder = InputRecorder()
    func finger(_ type: Int, _ id: UInt64, _ x: Float) {
        recorder.send { $0.finger.type = UInt32(type); $0.finger.fingerID = id; $0.finger.x = x; $0.finger.y = 0.5 }
    }
    finger(MEAD_SDL_EVENT_FINGER_DOWN, 7, 0.1)
    finger(MEAD_SDL_EVENT_FINGER_DOWN, 9, 0.9)
    finger(MEAD_SDL_EVENT_FINGER_UP, 7, 0.1)
    finger(MEAD_SDL_EVENT_FINGER_UP, 9, 0.9)
    #expect(recorder.motions.map(\.action) == [JavaMotionEvent.actionDown, JavaMotionEvent.actionPointerDown | 1 << 8,
                                               JavaMotionEvent.actionPointerUp, JavaMotionEvent.actionUp])
    #expect(recorder.motions[1].getPointerCount() == 2)
    #expect(recorder.motions[1].getRawX(1) == 900, "fingers come in 0 to 1, events in pixels")
    #expect(recorder.motions[3].getPointerId(0) == 1, "the second finger keeps its ID")
}

@Test func theWheelScrolls() {
    JavaFramework.register()
    let recorder = InputRecorder()
    recorder.send { $0.wheel.type = UInt32(MEAD_SDL_EVENT_MOUSE_WHEEL); $0.wheel.y = -1; $0.wheel.mouse_x = 3; $0.wheel.mouse_y = 4 }
    #expect(recorder.motions.first?.action == JavaMotionEvent.actionScroll)
    #expect(recorder.motions.first?.source == JavaMotionEvent.sourceMouse)
    #expect(recorder.motions.first?.getAxisValue(JavaMotionEvent.axisVerticalScroll, 0) == -1)
}

@Test func keysCarryTheirCodeCharacterAndModifiers() {
    JavaFramework.register()
    let recorder = InputRecorder()
    // Shift and A, then shift and 1, then Escape.
    recorder.send { $0.key.type = UInt32(MEAD_SDL_EVENT_KEY_DOWN); $0.key.scancode = 4; $0.key.key = 0x61; $0.key.mod = UInt16(MEAD_SDL_KMOD_LSHIFT); $0.key.down = true }
    recorder.send { $0.key.type = UInt32(MEAD_SDL_EVENT_KEY_UP); $0.key.scancode = 4; $0.key.key = 0x61 }
    recorder.send { $0.key.type = UInt32(MEAD_SDL_EVENT_KEY_DOWN); $0.key.scancode = 30; $0.key.key = 0x31; $0.key.mod = UInt16(MEAD_SDL_KMOD_RSHIFT); $0.key.down = true }
    recorder.send { $0.key.type = UInt32(MEAD_SDL_EVENT_KEY_DOWN); $0.key.scancode = 41; $0.key.key = 0x1b; $0.key.down = true }
    #expect(recorder.keys.map(\.keyCode) == [29, 29, 8, 111])
    #expect(recorder.keys.map(\.action) == [JavaKeyEvent.actionDown, JavaKeyEvent.actionUp, JavaKeyEvent.actionDown, JavaKeyEvent.actionDown])
    #expect(recorder.keys[0].unicodeChar == 0x41)
    #expect(recorder.keys[0].getMetaState() == JavaKeyEvent.metaShiftOn | 0x40)
    #expect(recorder.keys[2].unicodeChar == 0x21, "shift and 1 is !")
    #expect(recorder.keys[3].unicodeChar == 0, "escape types nothing")
    #expect(GameActivityInput.character(0x61, mod: UInt16(MEAD_SDL_KMOD_CAPS)) == 0x41)
    #expect(JavaKeyEvent(action: 0, keyCode: 0, scanCode: 0, metaState: JavaKeyEvent.metaCapsLockOn | JavaKeyEvent.metaShiftOn,
                         repeatCount: 0, unicodeChar: 0, eventTime: 0, downTime: 0).getModifiers() == JavaKeyEvent.metaShiftOn)
}
