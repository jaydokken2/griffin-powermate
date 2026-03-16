import Foundation
import IOKit
import IOKit.hid
import Cocoa
import CoreAudio

// MARK: - Griffin PowerMate Constants

let kPowerMateVendorID:  Int = 0x077d  // Griffin Technology
let kPowerMateProductID: Int = 0x0410  // PowerMate

let kVolumeStep: Float32 = 0.02  // Volume change per rotation tick (~2%)

// MARK: - Logging

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    print("[\(timestamp)] \(message)")
    fflush(stdout)
}

// MARK: - Volume Control via CoreAudio

func getDefaultOutputDevice() -> AudioDeviceID? {
    var deviceID = AudioDeviceID(0)
    var size = UInt32(MemoryLayout<AudioDeviceID>.size)
    var address = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    let status = AudioObjectGetPropertyData(
        AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &deviceID
    )
    guard status == noErr, deviceID != kAudioObjectUnknown else {
        log("ERROR: Could not get default output device (status: \(status))")
        return nil
    }
    return deviceID
}

func getVolume() -> Float32? {
    guard let device = getDefaultOutputDevice() else { return nil }
    var volume: Float32 = 0
    var size = UInt32(MemoryLayout<Float32>.size)

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )
    if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
        return volume
    }

    address.mElement = 1
    if AudioObjectGetPropertyData(device, &address, 0, nil, &size, &volume) == noErr {
        return volume
    }

    return nil
}

func setVolume(_ volume: Float32) {
    guard let device = getDefaultOutputDevice() else { return }
    var vol = min(max(volume, 0.0), 1.0)
    let size = UInt32(MemoryLayout<Float32>.size)

    var address = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyVolumeScalar,
        mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain
    )

    if AudioObjectSetPropertyData(device, &address, 0, nil, size, &vol) == noErr {
        return
    }

    for channel: UInt32 in [1, 2] {
        address.mElement = channel
        AudioObjectSetPropertyData(device, &address, 0, nil, size, &vol)
    }
}

func adjustVolume(up: Bool) {
    let current = getVolume() ?? 0.5
    let newVol = up ? current + kVolumeStep : current - kVolumeStep
    let clamped = min(max(newVol, 0.0), 1.0)
    setVolume(clamped)
    log("Volume \(up ? "up" : "down"): \(Int(clamped * 100))%")
}

// MARK: - Media Key Simulation

func sendMediaKey(_ keyCode: Int) {
    let downEvent = NSEvent.otherEvent(
        with: .systemDefined,
        location: NSPoint.zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: 0xa00),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: (keyCode << 16) | (0xa << 8),
        data2: -1
    )
    if let cg = downEvent?.cgEvent {
        cg.post(tap: .cghidEventTap)
    } else {
        log("WARNING: Failed to create media key down event")
    }

    let upEvent = NSEvent.otherEvent(
        with: .systemDefined,
        location: NSPoint.zero,
        modifierFlags: NSEvent.ModifierFlags(rawValue: 0xb00),
        timestamp: 0,
        windowNumber: 0,
        context: nil,
        subtype: 8,
        data1: (keyCode << 16) | (0xb << 8),
        data2: -1
    )
    if let cg = upEvent?.cgEvent {
        cg.post(tap: .cghidEventTap)
    } else {
        log("WARNING: Failed to create media key up event")
    }
}

// MARK: - MediaRemote Framework (private, for play/pause without Accessibility)

// Load MediaRemote.framework dynamically
let mrBundle = CFBundleCreate(kCFAllocatorDefault,
    URL(fileURLWithPath: "/System/Library/PrivateFrameworks/MediaRemote.framework") as CFURL)

typealias MRMediaRemoteSendCommandFunc = @convention(c) (UInt32, UnsafeRawPointer?) -> Bool

func getMRSendCommand() -> MRMediaRemoteSendCommandFunc? {
    guard let bundle = mrBundle else {
        log("MediaRemote framework not found")
        return nil
    }
    guard let ptr = CFBundleGetFunctionPointerForName(bundle, "MRMediaRemoteSendCommand" as CFString) else {
        log("MRMediaRemoteSendCommand not found")
        return nil
    }
    return unsafeBitCast(ptr, to: MRMediaRemoteSendCommandFunc.self)
}

// MediaRemote command constants
let kMRTogglePlayPause: UInt32 = 2
let kMRPlay: UInt32 = 0
let kMRPause: UInt32 = 1

func sendPlayPause() {
    // Use MediaRemote private framework — no Accessibility permission needed
    if let sendCommand = getMRSendCommand() {
        let result = sendCommand(kMRTogglePlayPause, nil)
        log("Play/Pause toggled via MediaRemote (success: \(result))")
        return
    }

    // Fallback: try CGEvent media key (requires Accessibility)
    sendMediaKey(16)
    log("Play/Pause toggled (media key fallback)")
}

// MARK: - PowerMate LED Control

let kLEDBrightness: UInt8 = 128  // Fixed brightness (always on)

func setLEDBrightness(_ device: IOHIDDevice, brightness: UInt8) {
    // Use the C helper to send USB vendor control request for LED
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/local/bin/powermate-led")
    task.arguments = [String(brightness)]
    task.standardOutput = nil
    task.standardError = nil
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        log("LED helper failed: \(error)")
    }
}

// Keep LED on by refreshing periodically
func startLEDKeepAlive() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now(), repeating: 5.0)
    timer.setEventHandler {
        if let device = connectedDevice {
            setLEDBrightness(device, brightness: kLEDBrightness)
        }
    }
    timer.resume()
    // Store timer to prevent deallocation
    ledTimer = timer
}

var ledTimer: DispatchSourceTimer?

// MARK: - HID Callbacks

var connectedDevice: IOHIDDevice?
var buttonIsDown = false

func inputCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    value: IOHIDValue
) {
    let element = IOHIDValueGetElement(value)
    let usage = IOHIDElementGetUsage(element)
    let usagePage = IOHIDElementGetUsagePage(element)
    let intValue = IOHIDValueGetIntegerValue(value)

    if usagePage == kHIDPage_GenericDesktop && (usage == 0x37 || usage == 0x33) {
        // Dial rotation: 0x37 = Dial, 0x33 = Rx (PowerMate reports as Rx)
        if intValue > 0 {
            adjustVolume(up: true)
            if let device = connectedDevice { setLEDBrightness(device, brightness: kLEDBrightness) }
        } else if intValue < 0 {
            adjustVolume(up: false)
            if let device = connectedDevice { setLEDBrightness(device, brightness: kLEDBrightness) }
        }
    } else if usagePage == kHIDPage_Button && usage == 1 {
        if intValue == 1 && !buttonIsDown {
            buttonIsDown = true
            sendPlayPause()
        } else if intValue == 0 {
            buttonIsDown = false
        }
    }
}

func matchCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    log("Griffin PowerMate connected!")
    connectedDevice = device

    if let product = IOHIDDeviceGetProperty(device, kIOHIDProductKey as CFString) {
        log("  Product: \(product)")
    }

    // Set LED on and start keep-alive timer
    setLEDBrightness(device, brightness: kLEDBrightness)
    startLEDKeepAlive()
    log("  LED on (brightness: \(kLEDBrightness), keep-alive started)")
}

func removeCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    device: IOHIDDevice
) {
    log("Griffin PowerMate disconnected.")
    connectedDevice = nil
}

// MARK: - Signal Handling

func setupSignalHandlers() {
    signal(SIGINT) { _ in
        log("Shutting down...")
        exit(0)
    }
    signal(SIGTERM) { _ in
        log("Shutting down...")
        exit(0)
    }
}

// MARK: - Permission Check

func checkAccessibilityPermission() {
    let trusted = AXIsProcessTrusted()
    if trusted {
        log("Accessibility permission: GRANTED")
    } else {
        log("WARNING: Accessibility permission NOT granted")
        log("  Media key simulation (play/pause) may not work.")
        log("  Go to System Settings > Privacy & Security > Accessibility")
        log("  and add powermate-daemon.")
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - Main

log("PowerMate Daemon v2.1 starting...")
log("Searching for Griffin PowerMate (VID: 0x077d, PID: 0x0410)...")

setupSignalHandlers()
checkAccessibilityPermission()

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matchDict: [String: Any] = [
    kIOHIDVendorIDKey as String: kPowerMateVendorID,
    kIOHIDProductIDKey as String: kPowerMateProductID
]
IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, removeCallback, nil)
IOHIDManagerRegisterInputValueCallback(manager, inputCallback, nil)

IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    log("ERROR: Failed to open HID manager (status: \(openResult))")
    log("Make sure the app has Input Monitoring permission in System Settings > Privacy & Security")
    exit(1)
}

log("HID Manager open. Waiting for PowerMate device...")

CFRunLoopRun()
