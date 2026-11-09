import Glibc

// ASensorManager, for a machine with no sensors: everything answers as a
// device that lacks them would, and a queue never has anything in it.

private final class SensorManager {
    static let shared = SensorManager()
    var pointer: UnsafeMutableRawPointer { Unmanaged.passUnretained(self).toOpaque() }
}

private final class SensorEventQueue {}

@_cdecl("ASensorManager_getInstance")
public func ASensorManager_getInstance() -> UnsafeMutableRawPointer {
    SensorManager.shared.pointer
}

@_cdecl("ASensorManager_getInstanceForPackage")
public func ASensorManager_getInstanceForPackage(_ package: UnsafePointer<CChar>?) -> UnsafeMutableRawPointer {
    SensorManager.shared.pointer
}

@_cdecl("ASensorManager_getSensorList")
public func ASensorManager_getSensorList(_ manager: UnsafeMutableRawPointer, _ list: UnsafeMutablePointer<UnsafeRawPointer?>?) -> Int32 {
    list?.pointee = nil
    return 0
}

@_cdecl("ASensorManager_getDefaultSensor")
public func ASensorManager_getDefaultSensor(_ manager: UnsafeMutableRawPointer, _ type: Int32) -> UnsafeRawPointer? {
    nil
}

@_cdecl("ASensorManager_getDefaultSensorEx")
public func ASensorManager_getDefaultSensorEx(_ manager: UnsafeMutableRawPointer, _ type: Int32, _ wakeUp: Bool) -> UnsafeRawPointer? {
    nil
}

@_cdecl("ASensorManager_createEventQueue")
public func ASensorManager_createEventQueue(_ manager: UnsafeMutableRawPointer, _ looper: UnsafeMutableRawPointer?, _ ident: Int32,
                                            _ callback: LooperCallback?, _ data: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(SensorEventQueue()).toOpaque()
}

@_cdecl("ASensorManager_destroyEventQueue")
public func ASensorManager_destroyEventQueue(_ manager: UnsafeMutableRawPointer, _ queue: UnsafeMutableRawPointer) -> Int32 {
    Unmanaged<SensorEventQueue>.fromOpaque(queue).release()
    return 0
}

@_cdecl("ASensorEventQueue_enableSensor")
public func ASensorEventQueue_enableSensor(_ queue: UnsafeMutableRawPointer, _ sensor: UnsafeRawPointer?) -> Int32 { 0 }

@_cdecl("ASensorEventQueue_disableSensor")
public func ASensorEventQueue_disableSensor(_ queue: UnsafeMutableRawPointer, _ sensor: UnsafeRawPointer?) -> Int32 { 0 }

@_cdecl("ASensorEventQueue_setEventRate")
public func ASensorEventQueue_setEventRate(_ queue: UnsafeMutableRawPointer, _ sensor: UnsafeRawPointer?, _ microseconds: Int32) -> Int32 { 0 }

@_cdecl("ASensorEventQueue_hasEvents")
public func ASensorEventQueue_hasEvents(_ queue: UnsafeMutableRawPointer) -> Int32 { 0 }

@_cdecl("ASensorEventQueue_getEvents")
public func ASensorEventQueue_getEvents(_ queue: UnsafeMutableRawPointer, _ events: UnsafeMutableRawPointer?, _ count: Int) -> Int { 0 }
