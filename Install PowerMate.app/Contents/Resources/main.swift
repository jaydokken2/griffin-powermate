import Foundation
import IOKit
import IOKit.hid
import Cocoa
import CoreAudio

// MARK: - Griffin PowerMate Constants

let kPowerMateVendorID:  Int = 0x077d  // Griffin Technology
let kPowerMateProductID: Int = 0x0410  // PowerMate

let kVolumeStep: Float32 = 0.02  // Fine volume change per rotation event (~2%)

// MARK: - Logging

func log(_ message: String) {
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
    let timestamp = formatter.string(from: Date())
    print("[\(timestamp)] \(message)")
    fflush(stdout)
}

// MARK: - Volume Overlay HUD

class VolumeOverlayView: NSView {
    var volumeLevel: Float32 = 0.0

    override func draw(_ dirtyRect: NSRect) {
        let bounds = self.bounds
        let path = NSBezierPath(roundedRect: bounds, xRadius: 12, yRadius: 12)
        NSColor(white: 0.1, alpha: 0.85).setFill()
        path.fill()

        // Volume bar background
        let barMargin: CGFloat = 20
        let barHeight: CGFloat = 8
        let barY: CGFloat = bounds.midY + 4
        let barRect = NSRect(x: barMargin, y: barY, width: bounds.width - barMargin * 2, height: barHeight)
        NSColor(white: 0.3, alpha: 1.0).setFill()
        NSBezierPath(roundedRect: barRect, xRadius: 4, yRadius: 4).fill()

        // Volume bar fill
        let fillWidth = (bounds.width - barMargin * 2) * CGFloat(volumeLevel)
        if fillWidth > 0 {
            let fillRect = NSRect(x: barMargin, y: barY, width: fillWidth, height: barHeight)
            NSColor.white.setFill()
            NSBezierPath(roundedRect: fillRect, xRadius: 4, yRadius: 4).fill()
        }

        // Percentage text
        let pctString = "\(Int(volumeLevel * 100))%"
        let attrs: [NSAttributedString.Key: Any] = [
            .foregroundColor: NSColor(white: 1.0, alpha: 0.8),
            .font: NSFont.systemFont(ofSize: 14, weight: .medium)
        ]
        let attrStr = NSAttributedString(string: pctString, attributes: attrs)
        let strSize = attrStr.size()
        let strPoint = NSPoint(x: (bounds.width - strSize.width) / 2, y: barY - strSize.height - 6)
        attrStr.draw(at: strPoint)
    }
}

class VolumeOverlay {
    static let shared = VolumeOverlay()

    private var window: NSWindow?
    private var overlayView: VolumeOverlayView?
    private var hideTimer: Timer?

    private init() {}

    func show(volume: Float32) {
        DispatchQueue.main.async { [self] in
            if window == nil {
                let w = NSWindow(
                    contentRect: NSRect(x: 0, y: 0, width: 200, height: 50),
                    styleMask: .borderless,
                    backing: .buffered,
                    defer: false
                )
                w.isOpaque = false
                w.backgroundColor = .clear
                w.level = .floating
                w.ignoresMouseEvents = true
                w.collectionBehavior = [.canJoinAllSpaces, .stationary]
                w.hasShadow = true

                let view = VolumeOverlayView(frame: NSRect(x: 0, y: 0, width: 200, height: 50))
                w.contentView = view

                window = w
                overlayView = view
            }

            // Center on main screen
            if let screen = NSScreen.main {
                let screenFrame = screen.frame
                let winSize = window!.frame.size
                let x = screenFrame.midX - winSize.width / 2
                let y = screenFrame.midY - winSize.height / 2 + 100
                window!.setFrameOrigin(NSPoint(x: x, y: y))
            }

            overlayView?.volumeLevel = volume
            overlayView?.needsDisplay = true

            window?.alphaValue = 1.0
            window?.orderFrontRegardless()

            // Reset fade timer
            hideTimer?.invalidate()
            hideTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: false) { [self] _ in
                NSAnimationContext.runAnimationGroup({ ctx in
                    ctx.duration = 0.3
                    window?.animator().alphaValue = 0.0
                }, completionHandler: {
                    self.window?.orderOut(nil)
                })
            }
        }
    }
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
    VolumeOverlay.shared.show(volume: clamped)
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

let kMRTogglePlayPause: UInt32 = 2

func sendPlayPause() {
    if let sendCommand = getMRSendCommand() {
        let result = sendCommand(kMRTogglePlayPause, nil)
        log("Play/Pause toggled via MediaRemote (success: \(result))")
        return
    }
    sendMediaKey(16)
    log("Play/Pause toggled (media key fallback)")
}

// MARK: - PowerMate LED Control

let kLEDBrightness: UInt8 = 128

func setLEDBrightness(_ device: IOHIDDevice, brightness: UInt8) {
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

func startLEDKeepAlive() {
    let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global())
    timer.schedule(deadline: .now(), repeating: 5.0)
    timer.setEventHandler {
        if let device = connectedDevice {
            setLEDBrightness(device, brightness: kLEDBrightness)
        }
    }
    timer.resume()
    ledTimer = timer
}

var ledTimer: DispatchSourceTimer?

// MARK: - HID Callbacks

var connectedDevice: IOHIDDevice?
var buttonIsDown = false

// Raw report buffer for low-level HID access
var rawReportBuffer = [UInt8](repeating: 0, count: 64)

// Raw report callback — operates below the value callback, may catch events it misses
func rawReportCallback(
    context: UnsafeMutableRawPointer?,
    result: IOReturn,
    sender: UnsafeMutableRawPointer?,
    type: IOHIDReportType,
    reportID: UInt32,
    report: UnsafeMutablePointer<UInt8>,
    reportLength: CFIndex
) {
    guard reportLength >= 2 else { return }

    let buttonState = report[0]
    let rotationDelta = Int8(bitPattern: report[1])

    // Handle rotation from raw report
    if rotationDelta != 0 {
        let current = getVolume() ?? 0.5
        let delta = kVolumeStep * Float32(rotationDelta)
        let clamped = min(max(current + delta, 0.0), 1.0)
        setVolume(clamped)
        log("Volume: \(Int(clamped * 100))%")
        VolumeOverlay.shared.show(volume: clamped)
    }

    // Handle button from raw report
    if buttonState == 1 && !buttonIsDown {
        buttonIsDown = true
        sendPlayPause()
    } else if buttonState == 0 && buttonIsDown {
        buttonIsDown = false
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

    // Set faster report interval (1ms)
    IOHIDDeviceSetProperty(device, kIOHIDReportIntervalKey as CFString, 1000 as CFNumber)

    // Register raw report callback for low-level HID access
    IOHIDDeviceRegisterInputReportCallback(
        device,
        &rawReportBuffer,
        rawReportBuffer.count,
        rawReportCallback,
        nil
    )
    log("  Raw report callback registered")

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

log("PowerMate Daemon v3.0 starting...")
log("Searching for Griffin PowerMate (VID: 0x077d, PID: 0x0410)...")

setupSignalHandlers()
checkAccessibilityPermission()

// Set up as background app (no Dock icon, but can show windows)
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
// Force connection to window server
let _ = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)

let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))

let matchDict: [String: Any] = [
    kIOHIDVendorIDKey as String: kPowerMateVendorID,
    kIOHIDProductIDKey as String: kPowerMateProductID
]
IOHIDManagerSetDeviceMatching(manager, matchDict as CFDictionary)

IOHIDManagerRegisterDeviceMatchingCallback(manager, matchCallback, nil)
IOHIDManagerRegisterDeviceRemovalCallback(manager, removeCallback, nil)

IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetCurrent(), CFRunLoopMode.defaultMode.rawValue)

let openResult = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
if openResult != kIOReturnSuccess {
    log("ERROR: Failed to open HID manager (status: \(openResult))")
    log("Make sure the app has Input Monitoring permission in System Settings > Privacy & Security")
    exit(1)
}

log("HID Manager open. Waiting for PowerMate device...")

app.run()
