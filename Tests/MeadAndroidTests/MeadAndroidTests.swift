import CMeadAndroid
import CMeadWindow
import Glibc
@testable import MeadAndroid
import MeadCrypto
@testable import MeadJava
@testable import MeadMinecraft
@testable import MeadUnity
@testable import MeadJNI
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
    MinecraftFramework.register()
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
    MinecraftFramework.register()
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
    MinecraftFramework.register()
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
    MinecraftFramework.register()
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
    MinecraftFramework.register()
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

@Test func forATouchGameTheMouseIsAFinger() {
    MinecraftFramework.register()
    let recorder = InputRecorder()
    recorder.input.mouseIsFinger = true
    recorder.send { $0.motion.type = UInt32(MEAD_SDL_EVENT_MOUSE_MOTION); $0.motion.x = 5; $0.motion.y = 6 }
    recorder.send { $0.button.type = UInt32(MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN); $0.button.button = 3; $0.button.down = true }
    recorder.send { $0.button.type = UInt32(MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN); $0.button.button = 1; $0.button.down = true; $0.button.x = 10; $0.button.y = 20 }
    recorder.send { $0.motion.type = UInt32(MEAD_SDL_EVENT_MOUSE_MOTION); $0.motion.x = 30; $0.motion.y = 40 }
    recorder.send { $0.button.type = UInt32(MEAD_SDL_EVENT_MOUSE_BUTTON_UP); $0.button.button = 1; $0.button.x = 30; $0.button.y = 40 }
    // What SDL makes up from a real touch isn't a second finger.
    recorder.send { $0.button.type = UInt32(MEAD_SDL_EVENT_MOUSE_BUTTON_DOWN); $0.button.button = 1; $0.button.down = true; $0.button.which = UInt32.max }
    #expect(recorder.motions.map(\.action) == [JavaMotionEvent.actionDown, JavaMotionEvent.actionMove, JavaMotionEvent.actionUp])
    #expect(recorder.motions.allSatisfy { $0.source == JavaMotionEvent.sourceTouchscreen && $0.getToolType(0) == JavaMotionEvent.toolTypeFinger })
    #expect(recorder.motions[1].getX(0) == 30 && recorder.motions[1].getY() == 40)
    #expect(recorder.motions[1].getActionMasked() == JavaMotionEvent.actionMove && recorder.motions[1].getPressure(0) == 1)
    #expect(JavaMotionEvent.obtain(recorder.motions[1]) === recorder.motions[1])
    #expect(JavaMotionEvent.obtain(nil) == nil)
    recorder.send { $0.finger.type = UInt32(MEAD_SDL_EVENT_FINGER_DOWN); $0.finger.fingerID = 7; $0.finger.x = 0.5; $0.finger.y = 0.5 }
    recorder.send { $0.finger.type = UInt32(MEAD_SDL_EVENT_FINGER_DOWN); $0.finger.fingerID = 9; $0.finger.x = 0.1; $0.finger.y = 0.5 }
    #expect(recorder.motions.last?.getActionMasked() == JavaMotionEvent.actionPointerDown && recorder.motions.last?.getActionIndex() == 1)
}

@Test func twoFingersAreTwoPointers() {
    MinecraftFramework.register()
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
    MinecraftFramework.register()
    let recorder = InputRecorder()
    recorder.send { $0.wheel.type = UInt32(MEAD_SDL_EVENT_MOUSE_WHEEL); $0.wheel.y = -1; $0.wheel.mouse_x = 3; $0.wheel.mouse_y = 4 }
    #expect(recorder.motions.first?.action == JavaMotionEvent.actionScroll)
    #expect(recorder.motions.first?.source == JavaMotionEvent.sourceMouse)
    #expect(recorder.motions.first?.getAxisValue(JavaMotionEvent.axisVerticalScroll, 0) == -1)
}

@Test func keysCarryTheirCodeCharacterAndModifiers() {
    MinecraftFramework.register()
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

@Test func aCapturedPointerSendsMovement() {
    MinecraftFramework.register()
    let recorder = InputRecorder()
    recorder.input.pointerCaptured = true
    recorder.send { $0.motion.type = UInt32(MEAD_SDL_EVENT_MOUSE_MOTION); $0.motion.x = 500; $0.motion.y = 500; $0.motion.xrel = 3; $0.motion.yrel = -2 }
    #expect(recorder.motions.first?.source == JavaMotionEvent.sourceMouseRelative)
    #expect(recorder.motions.first?.action == JavaMotionEvent.actionHoverMove)
    #expect(recorder.motions.first?.getRawX(0) == 3 && recorder.motions.first?.getRawY(0) == -2)
    recorder.input.pointerCaptured = false
    recorder.send { $0.motion.type = UInt32(MEAD_SDL_EVENT_MOUSE_MOTION); $0.motion.x = 500; $0.motion.y = 400; $0.motion.xrel = 0; $0.motion.yrel = -100 }
    #expect(recorder.motions.last?.source == JavaMotionEvent.sourceMouse && recorder.motions.last?.getRawY(0) == 400)
}

@Test func theGameLocksAndUnlocksTheCursor() {
    MinecraftFramework.register()
    let activity = JavaMinecraftActivity()
    activity.lockCursor()
    #expect(JavaMinecraftActivity.cursorLocked)
    activity.unlockCursor()
    #expect(!JavaMinecraftActivity.cursorLocked)
}

// GameActivity's text input: the keyboard's edits on the game's text box.

@Test func typingEditsTheTextAtTheCursor() {
    MinecraftFramework.register()
    let connection = JavaTextInputConnection()
    connection.setState(JavaTextInputState(text: "My World", selectionStart: 2, selectionEnd: 2, composingRegionStart: -1, composingRegionEnd: -1))
    var state = connection.apply(.insert(" New"))
    #expect(state.text == "My New World" && state.selectionStart == 6 && state.selectionEnd == 6)
    state = connection.apply(.deleteBackward)
    #expect(state.text == "My Ne World" && state.selectionStart == 5)
    state = connection.apply(.moveToEnd)
    #expect(state.selectionStart == 11)
    state = connection.apply(.deleteForward)
    #expect(state.text == "My Ne World", "nothing after the end")
    _ = connection.apply(.moveToStart)
    state = connection.apply(.moveRight)
    #expect(state.selectionStart == 1)
    state = connection.apply(.deleteBackward)
    #expect(state.text == "y Ne World")
}

@Test func aSelectionIsReplacedOrDeletedWhole() {
    MinecraftFramework.register()
    let connection = JavaTextInputConnection()
    connection.setState(JavaTextInputState(text: "hello world", selectionStart: 6, selectionEnd: 11, composingRegionStart: -1, composingRegionEnd: -1))
    #expect(connection.apply(.insert("there")).text == "hello there")
    connection.setState(JavaTextInputState(text: "hello world", selectionStart: 11, selectionEnd: 5, composingRegionStart: -1, composingRegionEnd: -1))
    let state = connection.apply(.deleteBackward)
    #expect(state.text == "hello" && state.selectionStart == 5 && state.selectionEnd == 5)
}

@Test func positionsCountUTF16AndPairsGoTogether() {
    MinecraftFramework.register()
    let connection = JavaTextInputConnection()
    connection.setState(JavaTextInputState(text: "", selectionStart: 0, selectionEnd: 0, composingRegionStart: -1, composingRegionEnd: -1))
    var state = connection.apply(.insert("é🙂"))
    #expect(state.selectionStart == 3, "é is one unit, the emoji two")
    state = connection.apply(.moveLeft)
    #expect(state.selectionStart == 1)
    state = connection.apply(.deleteForward)
    #expect(state.text == "é")
}

@Test func anOpenTextBoxTakesTypingAndLeavesOtherKeys() {
    MinecraftFramework.register()
    var edits: [TextEdit] = []
    var keys: [Int32] = []
    let input = GameActivityInput(sendMotion: { _ in }, sendKey: { keys.append($0.keyCode) }, editText: { edits.append($0) }, clock: { 0 })
    func key(_ scancode: UInt32, _ typed: UInt32, down: Bool = true) {
        var event = mead_sdl_event()
        event.key.type = UInt32(down ? MEAD_SDL_EVENT_KEY_DOWN : MEAD_SDL_EVENT_KEY_UP)
        event.key.scancode = scancode
        event.key.key = typed
        event.key.down = down
        input.handle(event, windowWidth: 100, windowHeight: 100)
    }
    key(4, 0x61)
    #expect(keys == [29] && edits.isEmpty, "with no text box, a letter is a key")
    input.textInputActive = true
    keys = []
    key(4, 0x61)
    key(42, 8)
    key(42, 8, down: false)
    key(80, 0)
    key(40, 13)
    key(41, 27)
    #expect(edits == [.deleteBackward, .moveLeft], "letters come as text input, not as keys")
    #expect(keys == [66, 111], "Enter and Escape stay keys")
    "hi".withCString { text in
        var event = mead_sdl_event()
        event.text.type = UInt32(MEAD_SDL_EVENT_TEXT_INPUT)
        event.text.text = text
        input.handle(event, windowWidth: 100, windowHeight: 100)
    }
    #expect(edits.last == .insert("hi"))
}

// Minecraft's own text boxes: showKeyboard, and the whole text back.

@Test func showKeyboardOpensTheBoxWithTheCaretAtTheEnd() {
    MinecraftFramework.register()
    let box = TextBox()
    box.open(text: "My World", maxLength: 10)
    #expect(box.isActive && box.current.start == 8)
    box.apply(.moveToStart)
    box.open(text: "My World", maxLength: 10)
    #expect(box.current.start == 0, "opened again on the same text, the caret stays")
    #expect(box.apply(.insert("abcdef")).text == "abMy World", "only as much as the limit allows")
    box.setActive(false)
    box.open(text: "Other")
    #expect(box.current.text == "Other" && box.current.start == 5)
}

@Test func minecraftsKeyboardCallsDriveItsBox() {
    MinecraftFramework.register()
    let activity = JavaMinecraftActivity()
    activity.showKeyboard("Seed", 32, false, false, false)
    #expect(JavaMinecraftActivity.textBox.isActive && activity.getCaretPosition() == 4)
    activity.setCaretPosition(1)
    #expect(JavaMinecraftActivity.textBox.apply(.insert("x")).text == "Sxeed")
    activity.hideKeyboard()
    #expect(!JavaMinecraftActivity.textBox.isActive)
}

@Test func enterIsDoneWhenTheBoxTakesIt() {
    MinecraftFramework.register()
    var edits: [TextEdit] = []
    var keys: [Int32] = []
    let input = GameActivityInput(sendMotion: { _ in }, sendKey: { keys.append($0.keyCode) }, editText: { edits.append($0) }, clock: { 0 })
    input.textInputActive = true
    input.textInputTakesReturn = true
    for down in [true, false] {
        var event = mead_sdl_event()
        event.key.type = UInt32(down ? MEAD_SDL_EVENT_KEY_DOWN : MEAD_SDL_EVENT_KEY_UP)
        event.key.scancode = 40
        event.key.key = 13
        event.key.down = down
        input.handle(event, windowWidth: 100, windowHeight: 100)
    }
    #expect(edits == [.submit] && keys.isEmpty)
}

@Test func anIntArrayHoldsItsValues() {
    MinecraftFramework.register()
    let array = JavaRuntime.shared.newIntArray([3, -1, 7]) as? JavaPrimitiveArray
    #expect(array?.count == 3)
    let values = (0..<3).map { array!.storage.load(fromByteOffset: $0 * 4, as: Int32.self) }
    #expect(values == [3, -1, 7])
}

@Test func anImageThatCannotBeReadIsNull() {
    MinecraftFramework.register()
    #expect(JavaMinecraftActivity().getImageData("/nonexistent/image.png") == nil)
}

// Unity's Java player, and the frame callbacks its engine uses.

@Test func unitysClassesAreDefined() {
    UnityFramework.register()
    for name in ["com/unity3d/player/UnityPlayer", "com/unity3d/player/UnityPlayerForActivityOrService",
                 "com/unity3d/player/NativeLoader", "com/unity3d/player/UnityPlayerActivity"] {
        #expect(JavaRuntime.shared.findClassPublic(named: name) != nil, "\(name)")
    }
}

@Test func unitysMainThreadJobsRunOnceInOrder() {
    UnityFramework.register()
    let player = JavaUnityPlayerForActivityOrService(activity: JavaUnityPlayerActivity())
    var order: [Int] = []
    player.post { order.append(1) }
    player.post { order.append(2) }
    player.executeMainThreadJobs()
    player.executeMainThreadJobs()
    #expect(order == [1, 2])
}

nonisolated(unsafe) private var framesSeen: [Int64] = []

@Test func choreographerCallbacksRunOnTheNextFrame() {
    framesSeen = []
    let callback: @convention(c) (Int64, UnsafeMutableRawPointer?) -> Void = { time, _ in framesSeen.append(time) }
    let choreographer = AChoreographer_getInstance()
    AChoreographer_postFrameCallback64(choreographer, unsafeBitCast(callback, to: UnsafeRawPointer.self), nil)
    AChoreographer_postFrameCallbackDelayed64(choreographer, unsafeBitCast(callback, to: UnsafeRawPointer.self), nil, 60_000)
    Choreographer.runFrame()
    #expect(framesSeen.count == 1 && framesSeen[0] > 0, "the delayed one waits")
    Choreographer.runFrame()
    #expect(framesSeen.count == 1, "a callback runs once")
}

@Test func unitysPlayerOffersTheActivityAndLoadsPlugins() {
    UnityFramework.register()
    let activity = JavaUnityPlayerActivity()
    let player = JavaUnityPlayerForActivityOrService(activity: activity)
    #expect(JavaUnityPlayer.currentActivity === activity)
    #expect(!player.loadLibrary("mead-no-such-library"))
    #expect(!player.loadLibrary(nil))
}

@Test func aStringCanBeMadeFromBytes() {
    JavaFramework.register()
    let bytes = JavaRuntime.shared.newByteArray([0xc3, 0xa9, 0x41])
    #expect(JavaString(bytes: bytes, charset: "UTF-8").swiftValue == "\u{e9}A")
    #expect(JavaString(bytes: bytes, charset: "ISO-8859-1").units == [0xc3, 0xa9, 0x41])
    #expect(JavaString(bytes: bytes).swiftValue == "\u{e9}A")
    #expect(JavaRuntime.shared.findClassPublic(named: "java/lang/String")?
        .findMethod(MemberKey(name: "<init>", signature: "([BLjava/lang/String;)V"))?.constructor != nil)
}

@Test func unitysReflectionFindsFieldsByNameAlone() {
    UnityFramework.register()
    let player = JavaRuntime.shared.findClassPublic(named: "com/unity3d/player/UnityPlayer")!
    let field = JavaUnityReflectionHelper.getFieldID(player, "currentActivity", "", true)
    #expect(field?.field.name == "currentActivity")
    #expect(JavaUnityReflectionHelper.getFieldSignature(field) == "Landroid/app/Activity;")
    #expect(JavaUnityReflectionHelper.getFieldID(player, "meadNoSuchField", "", true) == nil)
    let method = JavaUnityReflectionHelper.getMethodID(player, "getContext", "()Landroid/content/Context;", false)
    #expect(method?.getName() == "getContext" && method?.method.isSynthesized == false)
    #expect(JavaUnityReflectionHelper.getConstructorID(JavaRuntime.shared.findClassPublic(named: "java/lang/String"), "()V")?.method.constructor != nil)
}

@Test func aFieldAskedForAsAnObjectIsTheRealOne() {
    UnityFramework.register()
    let player = JavaRuntime.shared.findClassPublic(named: "com/unity3d/player/UnityPlayer")!
    #expect(player.field(named: "currentActivity", signature: "Ljava/lang/Object;", isStatic: true)?.isSynthesized == false)
    #expect(player.field(named: "meadNoSuchObject", signature: "Ljava/lang/Object;", isStatic: true)?.isSynthesized == true)
}

@Test func unitysReflectionFindsTheClosestMethod() {
    UnityFramework.register()
    let activity = JavaRuntime.shared.findClassPublic(named: "com/unity3d/player/UnityPlayerActivity")!
    // C# knows the result only as some object.
    let found = JavaUnityReflectionHelper.getMethodID(activity, "getSharedPreferences", "(Ljava/lang/String;I)Ljava/lang/Object;", false)
    #expect(found?.method.signature == "(Ljava/lang/String;I)Landroid/content/SharedPreferences;")
    // A primitive that differs is another method altogether.
    let missing = JavaUnityReflectionHelper.getMethodID(activity, "getSharedPreferences", "(Ljava/lang/String;J)Ljava/lang/Object;", false)
    #expect(missing?.method.isSynthesized == true)
}

@Test func playBillingSaysItIsUnavailable() {
    UnityFramework.register()
    let client = JavaBillingClient.newBuilder(nil)?.enablePendingPurchases()?.setListener(nil)?.build()
    #expect(client?.isReady() == false && client?.getConnectionState() == 0)
    #expect(client?.isFeatureSupported("subscriptions")?.getResponseCode() == 3)
    #expect(client?.launchBillingFlow(nil, nil)?.getResponseCode() == 3)
    let codes = LockedValue([Int32]())
    let listener = JavaProxy(interfaces: [JavaRuntime.shared.findClassPublic(named: "com/android/billingclient/api/BillingClientStateListener")!]) { thread, method, arguments in
        if method.name == "onBillingSetupFinished", let result = thread.resolve(arguments![0].l) as? JavaBillingResult {
            codes.withLock { $0.append(result.getResponseCode()) }
        }
        return jvalue()
    }
    client?.startConnection(listener)
    JavaLooper.main.runDue()
    #expect(codes.withLock { $0 } == [3])
    // What Unity's C# looks up, knowing only that it wants some object.
    let billing = JavaRuntime.shared.findClassPublic(named: "com/android/billingclient/api/BillingClient")!
    #expect(JavaUnityReflectionHelper.getMethodID(billing, "newBuilder", "(Lcom.unity3d.player.UnityPlayerActivity;)Ljava/lang/Object;", true)?.method.isSynthesized == false)
}

@Test func playGamesSaysNobodyIsSignedIn() {
    UnityFramework.register()
    let client = JavaPlayGames.getGamesSignInClient(nil)
    let answers = LockedValue([Bool]())
    let listener = JavaProxy(interfaces: [JavaRuntime.shared.findClassPublic(named: "com/google/android/gms/tasks/OnSuccessListener")!]) { thread, _, arguments in
        if let result = thread.resolve(arguments![0].l) as? JavaAuthenticationResult {
            answers.withLock { $0.append(result.isAuthenticated()) }
        }
        return jvalue()
    }
    _ = client?.isAuthenticated()?.addOnSuccessListener(listener)?.addOnFailureListener(nil)
    _ = client?.signIn()?.addOnSuccessListener(listener)
    JavaLooper.main.runDue()
    #expect(answers.withLock { $0 } == [false, false])
    let games = JavaRuntime.shared.findClassPublic(named: "com/google/android/gms/games/PlayGames")!
    #expect(JavaUnityReflectionHelper.getMethodID(games, "getGamesSignInClient", "(Lcom.unity3d.player.UnityPlayerActivity;)Ljava/lang/Object;", true)?.method.isSynthesized == false)
}

@Test func aNativeMethodIsKnownOnceRegistered() {
    UnityFramework.register()
    let type = JavaRuntime.shared.findClassPublic(named: "com/unity3d/player/UnityPlayer")!
    let method = type.method(named: "meadTestNative", signature: "(I)V", isStatic: false)
    #expect(!type.hasNativeMethod(named: "meadTestNative", signature: "(I)V"))
    method?.everRegistered = true
    #expect(type.hasNativeMethod(named: "meadTestNative", signature: "(I)V"))
    #expect(!type.hasNativeMethod(named: "meadTestNative", signature: "(J)V"))
}

@Test func classForNameTakesJavasDottedNames() {
    UnityFramework.register()
    let thread = JavaRuntime.shared.attachCurrentThread()
    thread.pushFrame()
    defer { thread.popFrame() }
    var name = jvalue()
    name.l = thread.newLocal(JavaString("com.unity3d.player.UnityPlayer"))
    let found = thread.call("java/lang/Class", "forName", "(Ljava/lang/String;)Ljava/lang/Class;", isStatic: true, on: nil, [name])
    #expect((thread.resolve(found.l) as? JavaClass)?.name == "com/unity3d/player/UnityPlayer")
    let loader = thread.call("java/lang/Class", "getClassLoader", "()Ljava/lang/ClassLoader;", on: thread.resolve(found.l), [])
    #expect(thread.resolve(loader.l) is JavaClassLoader)
    var library = jvalue()
    library.l = thread.newLocal(JavaString("missing"))
    let path = thread.call("java/lang/ClassLoader", "findLibrary", "(Ljava/lang/String;)Ljava/lang/String;",
                           on: thread.resolve(loader.l), [library])
    #expect(path.l == nil)
    #expect(JavaRuntime.shared.findClassPublic(named: "java/lang/ClassLoader").map { $0.findMethod(MemberKey(name: "findLibrary", signature: "(Ljava/lang/String;)Ljava/lang/String;"))?.isSynthesized == false } == true)
}

// Java's text and stream classes.

// Proxies, and Android's message loop, which Unity paces its frames through.

@Test func aProxysCallsGoToItsHandler() {
    JavaFramework.register()
    let thread = JavaRuntime.shared.attachCurrentThread()
    thread.pushFrame()
    defer { thread.popFrame() }
    let callback = JavaRuntime.shared.findClassPublic(named: "android/os/Handler$Callback")!
    var seen: [String] = []
    let proxy = JavaProxy(interfaces: [callback]) { _, method, _ in
        seen.append("\(method.owner.name).\(method.name)")
        var handled = jvalue()
        handled.z = 1
        return handled
    }
    #expect(proxy.javaClass.isSubclass(of: callback))
    var message = jvalue()
    message.l = thread.newLocal(JavaMessage())
    let result = thread.call("android/os/Handler$Callback", "handleMessage", "(Landroid/os/Message;)Z", on: proxy, [message])
    #expect(result.z == 1)
    #expect(seen == ["android/os/Handler$Callback.handleMessage"])
    let method = JavaRuntime.shared.findClassPublic(named: "android/view/Choreographer$FrameCallback")!
        .method(named: "doFrame", signature: "(J)V", isStatic: false)
    #expect(method?.parameterTypes == ["J"])
    #expect(method?.returnType == "V")
}

@Test func aHandlerDeliversMessagesThroughItsLooper() {
    JavaFramework.register()
    let looper = JavaLooper()
    var delivered: [Int32] = []
    let callback = JavaProxy(interfaces: [JavaRuntime.shared.findClassPublic(named: "android/os/Handler$Callback")!]) { thread, _, arguments in
        delivered.append((thread.resolve(arguments![0].l) as? JavaMessage)?.what ?? -1)
        var handled = jvalue()
        handled.z = 1
        return handled
    }
    let handler = JavaHandler(queue: looper, callback: callback)
    handler.obtainMessage(3)?.sendToTarget()
    #expect(handler.sendEmptyMessage(5))
    #expect(handler.sendEmptyMessageDelayed(9, 10_000))
    #expect(handler.hasMessages(9))
    handler.removeMessages(9)
    #expect(!handler.hasMessages(9))
    looper.runDue()
    #expect(delivered == [3, 5])
}

@Test func aHandlerThreadRunsItsOwnLooper() {
    JavaFramework.register()
    let worker = JavaHandlerThread(name: "UnityChoreograp")
    worker.start()
    let looper = worker.getLooper()
    #expect(looper != nil)
    let done = LockedValue(false)
    looper?.post { done.withLock { $0 = true } }
    for _ in 0..<500 where !done.withLock({ $0 }) { usleep(1000) }
    #expect(done.withLock { $0 })
    _ = worker.quit()
}

@Test func theChoreographerCallsBackOnTheNextFrame() {
    JavaFramework.register()
    let looper = JavaLooper()
    JavaLooper.setCurrent(looper)
    let frames = LockedValue([Int64]())
    let callback = JavaProxy(interfaces: [JavaRuntime.shared.findClassPublic(named: "android/view/Choreographer$FrameCallback")!]) { _, _, arguments in
        frames.withLock { $0.append(arguments![0].j) }
        return jvalue()
    }
    let choreographer = JavaChoreographer.getInstance()
    #expect(choreographer?.looper === looper)
    choreographer?.postFrameCallback(callback)
    looper.runDue()
    #expect(frames.withLock { $0 }.isEmpty)
    usleep(UInt32(JavaChoreographer.frameInterval / 1000) + 2000)
    looper.runDue()
    #expect(frames.withLock { $0 }.count == 1)
    #expect((frames.withLock { $0 }.first ?? 0) > 0)
}

@Test func unitysBridgeBoxesWhatItPasses() {
    UnityFramework.register()
    let thread = JavaRuntime.shared.attachCurrentThread()
    thread.pushFrame()
    defer { thread.popFrame() }
    var long = jvalue()
    long.j = 1234
    #expect((JavaJNIBridge.box(long, as: "J", in: thread) as? JavaLong)?.value == 1234)
    var flag = jvalue()
    flag.z = 1
    #expect((JavaJNIBridge.box(flag, as: "Z", in: thread) as? JavaBoolean)?.value == true)
    #expect(JavaJNIBridge.unbox(JavaBoolean(value: true), as: "Z", in: thread).z == 1)
    #expect(JavaJNIBridge.unbox(JavaInteger(value: 7), as: "I", in: thread).i == 7)
    let array = JavaRuntime.shared.newObjectArray(elementClass: "java/lang/Class", count: 0) as! JavaObjectArray
    array.elements = [JavaRuntime.shared.findClassPublic(named: "java/lang/Runnable")]
    let proxy = JavaJNIBridge.newInterfaceProxy(1, array)
    #expect(proxy?.javaClass.isSubclass(of: JavaRuntime.shared.findClassPublic(named: "java/lang/Runnable")!) == true)
    JavaJNIBridge.disableInterfaceProxy(proxy)
    // Disabled, a call reaches nothing.
    thread.call("java/lang/Runnable", "run", "()V", on: proxy)
}

@Test func preferencesOutlastTheirObject() {
    JavaFramework.register()
    let path = "/tmp/mead-prefs-\(getpid()).prefs"
    defer { remove(path) }
    let preferences = JavaSharedPreferences(path: path)
    let editor = preferences.edit()
    _ = editor?.putString("name with space", "line\none \\ two")
    _ = editor?.putInt("level", 12)
    _ = editor?.putFloat("volume", 0.5)
    _ = editor?.putBoolean("music", true)
    editor?.apply()
    let reread = JavaSharedPreferences(path: path)
    #expect(reread.getString("name with space", nil) == "line\none \\ two")
    #expect(reread.getInt("level", 0) == 12)
    #expect(reread.getFloat("volume", 0) == 0.5)
    #expect(reread.getBoolean("music", false))
    #expect(reread.getInt("missing", 7) == 7)
    #expect(reread.getAll()?.size() == 4)
    _ = reread.edit()?.remove("level")?.commit()
    #expect(!JavaSharedPreferences(path: path).contains("level"))
}

@Test func aMapsEntriesCanBeWalked() throws {
    JavaFramework.register()
    let map = JavaHashMap()
    _ = map.put(JavaString("a"), JavaInteger(value: 1))
    let iterator = map.entrySet()?.iterator()
    #expect(iterator?.hasNext() == true)
    let entry = try iterator?.next() as? JavaMapEntry
    #expect((entry?.getKey() as? JavaString)?.swiftValue == "a")
    #expect((entry?.getValue() as? JavaInteger)?.value == 1)
    #expect(iterator?.hasNext() == false)
}

@Test func theLocaleAndDisplayAreADesktops() {
    JavaFramework.register()
    #expect(JavaUri.encode("a b/c?é") == "a%20b%2Fc%3F%C3%A9")
    #expect(JavaConfiguration().getLocales()?.get(0)?.toLanguageTag() == "en-US")
    DisplaySize.current.withLock { $0 = (1366, 768) }
    #expect(JavaDisplay().getWidth() == 1366)
    #expect(JavaWindowManager().getMaximumWindowMetrics()?.getBounds()?.height() == 768)
    #expect(JavaUnityPlayerActivity().getSystemService("audio") is JavaAudioManager)
    #expect(JavaAudioManager().getProperty(JavaAudioManager.outputSampleRate) == "48000")
}

@Test func aFileCanBeMadeInADirectoryAndWritten() throws {
    JavaFramework.register()
    let directory = JavaFile(path: "/tmp")
    let file = JavaFile(parent: directory, child: "mead-output-\(getpid())")
    #expect(file.path == "/tmp/mead-output-\(getpid())")
    #expect(JavaFile(parentPath: "/tmp/", child: "a").path == "/tmp/a")
    defer { _ = file.delete() }
    let output = try JavaFileOutputStream(file: file)
    try output.write(JavaRuntime.shared.newByteArray([1, 2, 3, 4]), 1, 2)
    output.close()
    var status = stat()
    #expect(stat(file.path, &status) == 0 && status.st_size == 2)
    #expect(file.setReadOnly())
    stat(file.path, &status)
    #expect(status.st_mode & mode_t(S_IWUSR) == 0)
    #expect(file.setWritable(true))
    #expect(throws: (any Error).self) { try output.write(JavaRuntime.shared.newByteArray([1])) }
}

@Test func aFileKnowsItsParentAndName() {
    #expect(JavaFile(path: "/data/data/net.defensezone2/files").getParent() == "/data/data/net.defensezone2")
    #expect(JavaFile(path: "/data/files/").getParent() == "/data")
    #expect(JavaFile(path: "/files").getParent() == "/")
    #expect(JavaFile(path: "/").getParent() == nil)
    #expect(JavaFile(path: "files").getParent() == nil)
    #expect(JavaFile(path: "/data/files/").getName() == "files")
    #expect(JavaFile(path: "/tmp").getUsableSpace() > 0)
}

@Test func stringsAreEqualByTheirText() {
    JavaFramework.register()
    let thread = JavaRuntime.shared.attachCurrentThread()
    thread.pushFrame()
    defer { thread.popFrame() }
    var other = jvalue()
    other.l = thread.newLocal(JavaString(JavaEnvironment.mediaMounted ?? ""))
    let same = thread.call("java/lang/String", "equals", "(Ljava/lang/Object;)Z", on: JavaString("mounted"), [other])
    #expect(same.z == 1)
    other.l = thread.newLocal(JavaString("removed"))
    let different = thread.call("java/lang/String", "equals", "(Ljava/lang/Object;)Z", on: JavaString("mounted"), [other])
    #expect(different.z == 0)
    #expect(JavaString("a").javaHashCode() == 97)
}

@Test func anAlertDialogKeepsItsTitleAndMessage() {
    JavaFramework.register()
    let builder = JavaAlertDialogBuilder(context: nil)
    _ = builder.setTitle(JavaString("Failure to initialize!"))
    _ = builder.setMessage(JavaStringBuilder(text: "Your hardware does not support this application."))
    let dialog = builder.create()
    #expect(dialog?.title == "Failure to initialize!")
    #expect(dialog?.message == "Your hardware does not support this application.")
}

@Test func aStringBuilderBuildsAString() {
    JavaFramework.register()
    let builder = JavaStringBuilder(text: "Unity ")
    _ = builder.append(int: 6)
    _ = builder.append(char: 0x2e)  // "."
    _ = builder.append(long: 3)
    _ = builder.append(string: nil)
    #expect(builder.javaToString() == "Unity 6.3null" && builder.length() == 13)
}

@Test func aScannerReadsAWholeAssetOrItsWords() throws {
    JavaFramework.register()
    let directory = "/tmp/mead-assets-\(getpid())"
    _ = AndroidEnvironment.makeDirectories("\(directory)/assets/bin")
    let file = fopen("\(directory)/assets/bin/settings.txt", "w")!
    fputs("gfx-enable-gfx-jobs=1\nwait-for-native-debugger=0\n", file)
    fclose(file)
    setenv("MEAD_DATA_DIR", directory, 1)
    defer { unsetenv("MEAD_DATA_DIR") }

    let manager = JavaAssetManager()
    let whole = JavaScanner(stream: try manager.open("bin/settings.txt"), charset: "UTF-8")
    _ = whole.useDelimiter("\\A")
    #expect(try whole.next() == "gfx-enable-gfx-jobs=1\nwait-for-native-debugger=0\n")
    #expect(!whole.hasNext())

    let words = JavaScanner(stream: try manager.open("bin/settings.txt"))
    #expect(try words.next() == "gfx-enable-gfx-jobs=1")
    #expect(try words.next() == "wait-for-native-debugger=0")
    #expect(throws: JavaException.self) { try words.next() }
    #expect(throws: JavaException.self) { try manager.open("missing.txt") }
}

@Test func anInputStreamReadsIntoAnArray() throws {
    JavaFramework.register()
    let stream = JavaInputStream(bytes: [1, 2, 3, 4, 5])
    let array = JavaRuntime.shared.newByteArray([0, 0, 0]) as! JavaPrimitiveArray
    #expect(try stream.read(array) == 3)
    #expect(array.storage.load(fromByteOffset: 2, as: UInt8.self) == 3)
    #expect(stream.read() == 4 && stream.available() == 1)
    #expect(try stream.read(array, 0, 3) == 1)
    #expect(try stream.read(array, 0, 3) == -1)
}

@Test func theAppIsInstalledFromItsAPKs() {
    JavaFramework.register()
    let directory = "/tmp/mead-apks-\(getpid())"
    _ = AndroidEnvironment.makeDirectories(directory)
    for name in ["base.apk", "split_b.apk", "split_a.apk", "other.apk"] {
        fclose(fopen("\(directory)/\(name)", "w"))
    }
    setenv("MEAD_DATA_DIR", directory, 1)
    defer { unsetenv("MEAD_DATA_DIR") }
    let context = JavaContext()
    #expect(context.getPackageCodePath() == "\(directory)/base.apk")
    let info = JavaApplicationInfo()
    let splits = (info.splitSourceDirs as? JavaObjectArray)?.elements.compactMap { ($0 as? JavaString)?.swiftValue }
    #expect(splits == ["\(directory)/split_a.apk", "\(directory)/split_b.apk"])
    let publicSplits = (info.splitPublicSourceDirs as? JavaObjectArray)?.elements.compactMap { ($0 as? JavaString)?.swiftValue }
    #expect(publicSplits == splits)
    #expect(info.nativeLibraryDir == "\(directory)/lib/arm64-v8a")
    _ = AndroidEnvironment.makeDirectories("\(directory)/lib/arm64-v8a")
    fclose(fopen("\(directory)/lib/arm64-v8a/libil2cpp.so", "w"))
    let loader = JavaClassLoader()
    #expect(loader.findLibrary("il2cpp") == "\(directory)/lib/arm64-v8a/libil2cpp.so")
    #expect(loader.findLibrary("missing") == nil)
    #expect(JavaEnvironment.getExternalStorageState() == JavaEnvironment.mediaMounted)
}
