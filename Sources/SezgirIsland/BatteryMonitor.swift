import Foundation
import IOKit.ps
import Observation

@Observable
@MainActor
final class BatteryMonitor {
    enum Event { case pluggedIn, unplugged, low }

    var level = 100
    var isCharging = false
    var isPluggedIn = false
    var hasBattery = false

    @ObservationIgnored var onEvent: ((Event) -> Void)?
    @ObservationIgnored private var source: CFRunLoopSource?
    @ObservationIgnored private var lastLowAlert: Int?

    func start() {
        refresh(initial: true)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { ctx in
            guard let ctx else { return }
            let monitor = Unmanaged<BatteryMonitor>.fromOpaque(ctx).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.refresh(initial: false) }
        }
        if let src = IOPSNotificationCreateRunLoopSource(callback, ctx)?.takeRetainedValue() {
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            source = src
        }
    }

    func refresh(initial: Bool) {
        guard let snap = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(snap)?.takeRetainedValue() as? [CFTypeRef] else {
            hasBattery = false
            return
        }
        for ps in list {
            guard let d = IOPSGetPowerSourceDescription(snap, ps)?.takeUnretainedValue() as? [String: Any],
                  (d[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
            let cur = d[kIOPSCurrentCapacityKey] as? Int ?? 0
            let mx = d[kIOPSMaxCapacityKey] as? Int ?? 100
            let newLevel = mx > 0 ? Int((Double(cur) / Double(mx) * 100).rounded()) : cur
            let plugged = (d[kIOPSPowerSourceStateKey] as? String) == kIOPSACPowerValue
            let charging = d[kIOPSIsChargingKey] as? Bool ?? false
            let wasPlugged = isPluggedIn

            level = newLevel
            isCharging = charging
            isPluggedIn = plugged
            hasBattery = true

            if !initial {
                if plugged && !wasPlugged { onEvent?(.pluggedIn) }
                else if !plugged && wasPlugged { onEvent?(.unplugged) }
            }
            if !plugged, newLevel == 20 || newLevel == 10, lastLowAlert != newLevel {
                lastLowAlert = newLevel
                if !initial { onEvent?(.low) }
            }
            if plugged { lastLowAlert = nil }
            return
        }
        hasBattery = false
    }
}
