import Glibc

/// An AConfiguration: a phone-shaped device description, as settable as the
/// NDK makes it.
public final class Configuration {
    var language: [CChar] = [0x65, 0x6e] // "en"
    var country: [CChar] = [0x55, 0x53] // "US"
    var values: [Int: Int32] = [
        Slot.orientation.rawValue: 2, // landscape
        Slot.touchscreen.rawValue: 3, // finger
        Slot.density.rawValue: 160,
        Slot.keyboard.rawValue: 2, // qwerty
        Slot.navigation.rawValue: 1, // none
        Slot.keysHidden.rawValue: 1, // no
        Slot.navHidden.rawValue: 1, // no
        Slot.sdkVersion.rawValue: 33,
        Slot.screenSize.rawValue: 3, // large
        Slot.screenLong.rawValue: 2, // yes
        Slot.uiModeType.rawValue: 1, // normal
        Slot.uiModeNight.rawValue: 1, // no
        Slot.layoutDirection.rawValue: 0, // left to right
    ]

    enum Slot: Int {
        case mcc, mnc, orientation, touchscreen, density, keyboard, navigation, keysHidden, navHidden,
             sdkVersion, screenSize, screenLong, uiModeType, uiModeNight, screenWidthDp, screenHeightDp,
             smallestScreenWidthDp, layoutDirection
    }

    func copy() -> Configuration {
        let other = Configuration()
        other.language = language
        other.country = country
        other.values = values
        return other
    }
}

private func configuration(_ pointer: UnsafeMutableRawPointer) -> Configuration {
    Unmanaged<Configuration>.fromOpaque(pointer).takeUnretainedValue()
}

private func get(_ pointer: UnsafeMutableRawPointer, _ slot: Configuration.Slot) -> Int32 {
    configuration(pointer).values[slot.rawValue] ?? 0
}

private func set(_ pointer: UnsafeMutableRawPointer, _ slot: Configuration.Slot, _ value: Int32) {
    configuration(pointer).values[slot.rawValue] = value
}

@_cdecl("AConfiguration_new")
public func AConfiguration_new() -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(Configuration()).toOpaque()
}

@_cdecl("AConfiguration_delete")
public func AConfiguration_delete(_ pointer: UnsafeMutableRawPointer) {
    Unmanaged<Configuration>.fromOpaque(pointer).release()
}

@_cdecl("AConfiguration_fromAssetManager")
public func AConfiguration_fromAssetManager(_ pointer: UnsafeMutableRawPointer, _ manager: UnsafeMutableRawPointer) {
    let fresh = Configuration()
    configuration(pointer).language = fresh.language
    configuration(pointer).country = fresh.country
    configuration(pointer).values = fresh.values
}

@_cdecl("AConfiguration_copy")
public func AConfiguration_copy(_ destination: UnsafeMutableRawPointer, _ source: UnsafeMutableRawPointer) {
    configuration(destination).language = configuration(source).language
    configuration(destination).country = configuration(source).country
    configuration(destination).values = configuration(source).values
}

@_cdecl("AConfiguration_getLanguage")
public func AConfiguration_getLanguage(_ pointer: UnsafeMutableRawPointer, _ out: UnsafeMutablePointer<CChar>) {
    out[0] = configuration(pointer).language[0]
    out[1] = configuration(pointer).language[1]
}

@_cdecl("AConfiguration_setLanguage")
public func AConfiguration_setLanguage(_ pointer: UnsafeMutableRawPointer, _ text: UnsafePointer<CChar>) {
    configuration(pointer).language = [text[0], text[1]]
}

@_cdecl("AConfiguration_getCountry")
public func AConfiguration_getCountry(_ pointer: UnsafeMutableRawPointer, _ out: UnsafeMutablePointer<CChar>) {
    out[0] = configuration(pointer).country[0]
    out[1] = configuration(pointer).country[1]
}

@_cdecl("AConfiguration_setCountry")
public func AConfiguration_setCountry(_ pointer: UnsafeMutableRawPointer, _ text: UnsafePointer<CChar>) {
    configuration(pointer).country = [text[0], text[1]]
}

@_cdecl("AConfiguration_getMcc") public func AConfiguration_getMcc(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .mcc) }
@_cdecl("AConfiguration_setMcc") public func AConfiguration_setMcc(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .mcc, v) }
@_cdecl("AConfiguration_getMnc") public func AConfiguration_getMnc(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .mnc) }
@_cdecl("AConfiguration_setMnc") public func AConfiguration_setMnc(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .mnc, v) }
@_cdecl("AConfiguration_getOrientation") public func AConfiguration_getOrientation(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .orientation) }
@_cdecl("AConfiguration_setOrientation") public func AConfiguration_setOrientation(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .orientation, v) }
@_cdecl("AConfiguration_getTouchscreen") public func AConfiguration_getTouchscreen(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .touchscreen) }
@_cdecl("AConfiguration_setTouchscreen") public func AConfiguration_setTouchscreen(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .touchscreen, v) }
@_cdecl("AConfiguration_getDensity") public func AConfiguration_getDensity(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .density) }
@_cdecl("AConfiguration_setDensity") public func AConfiguration_setDensity(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .density, v) }
@_cdecl("AConfiguration_getKeyboard") public func AConfiguration_getKeyboard(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .keyboard) }
@_cdecl("AConfiguration_setKeyboard") public func AConfiguration_setKeyboard(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .keyboard, v) }
@_cdecl("AConfiguration_getNavigation") public func AConfiguration_getNavigation(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .navigation) }
@_cdecl("AConfiguration_setNavigation") public func AConfiguration_setNavigation(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .navigation, v) }
@_cdecl("AConfiguration_getKeysHidden") public func AConfiguration_getKeysHidden(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .keysHidden) }
@_cdecl("AConfiguration_setKeysHidden") public func AConfiguration_setKeysHidden(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .keysHidden, v) }
@_cdecl("AConfiguration_getNavHidden") public func AConfiguration_getNavHidden(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .navHidden) }
@_cdecl("AConfiguration_setNavHidden") public func AConfiguration_setNavHidden(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .navHidden, v) }
@_cdecl("AConfiguration_getSdkVersion") public func AConfiguration_getSdkVersion(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .sdkVersion) }
@_cdecl("AConfiguration_setSdkVersion") public func AConfiguration_setSdkVersion(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .sdkVersion, v) }
@_cdecl("AConfiguration_getScreenSize") public func AConfiguration_getScreenSize(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .screenSize) }
@_cdecl("AConfiguration_setScreenSize") public func AConfiguration_setScreenSize(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .screenSize, v) }
@_cdecl("AConfiguration_getScreenLong") public func AConfiguration_getScreenLong(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .screenLong) }
@_cdecl("AConfiguration_setScreenLong") public func AConfiguration_setScreenLong(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .screenLong, v) }
@_cdecl("AConfiguration_getUiModeType") public func AConfiguration_getUiModeType(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .uiModeType) }
@_cdecl("AConfiguration_setUiModeType") public func AConfiguration_setUiModeType(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .uiModeType, v) }
@_cdecl("AConfiguration_getUiModeNight") public func AConfiguration_getUiModeNight(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .uiModeNight) }
@_cdecl("AConfiguration_setUiModeNight") public func AConfiguration_setUiModeNight(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .uiModeNight, v) }
@_cdecl("AConfiguration_getScreenWidthDp") public func AConfiguration_getScreenWidthDp(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .screenWidthDp) }
@_cdecl("AConfiguration_setScreenWidthDp") public func AConfiguration_setScreenWidthDp(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .screenWidthDp, v) }
@_cdecl("AConfiguration_getScreenHeightDp") public func AConfiguration_getScreenHeightDp(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .screenHeightDp) }
@_cdecl("AConfiguration_setScreenHeightDp") public func AConfiguration_setScreenHeightDp(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .screenHeightDp, v) }
@_cdecl("AConfiguration_getSmallestScreenWidthDp") public func AConfiguration_getSmallestScreenWidthDp(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .smallestScreenWidthDp) }
@_cdecl("AConfiguration_setSmallestScreenWidthDp") public func AConfiguration_setSmallestScreenWidthDp(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .smallestScreenWidthDp, v) }
@_cdecl("AConfiguration_getLayoutDirection") public func AConfiguration_getLayoutDirection(_ p: UnsafeMutableRawPointer) -> Int32 { get(p, .layoutDirection) }
@_cdecl("AConfiguration_setLayoutDirection") public func AConfiguration_setLayoutDirection(_ p: UnsafeMutableRawPointer, _ v: Int32) { set(p, .layoutDirection, v) }
