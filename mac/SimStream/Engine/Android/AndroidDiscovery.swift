import Foundation

/// Lists Android devices for the catalog: installed AVDs (bootable, even when shut down) merged with
/// whatever `adb devices` reports (running emulators, USB and Wi-Fi phones).
///
/// IDs are stable across boots: an emulator is `avd:<name>` whether or not it runs, so selection and
/// app-lock memory survive a restart. Anything else is `adb:<serial>`.
actor AndroidDiscovery {
  /// Properties per serial, kept once a device has finished booting.
  private var properties: [String: AndroidProperties] = [:]

  static func avdName(fromUDID udid: String) -> String? {
    udid.hasPrefix("avd:") ? String(udid.dropFirst(4)) : nil
  }

  func devices() async -> [SimulatorDevice] {
    let avds = AVD.listInstalled()
    guard AndroidTools.adb != nil else { return Self.merge(avds: avds, running: []) }
    let listing = (try? await ADB.run(["devices", "-l"])).map { String(decoding: $0.output, as: UTF8.self) } ?? ""
    let online = ADBDevice.parseList(listing).filter(\.isOnline)
    var running: [(ADBDevice, AndroidProperties)] = []
    for device in online {
      if let cached = properties[device.serial] {
        running.append((device, cached))
        continue
      }
      guard let output = try? await ADB.shell(AndroidProperties.script, serial: device.serial) else { continue }
      let parsed = AndroidProperties.parse(output)
      if parsed.bootCompleted { properties[device.serial] = parsed }
      running.append((device, parsed))
    }
    // Forget serials that went away; an emulator restarted on the same port is a new device.
    let serials = Set(online.map(\.serial))
    properties = properties.filter { serials.contains($0.key) }
    return Self.merge(avds: avds, running: running)
  }

  static func merge(avds: [AVD], running: [(ADBDevice, AndroidProperties)]) -> [SimulatorDevice] {
    var result: [String: SimulatorDevice] = [:]
    for avd in avds {
      let release = avd.apiLevel.map(AndroidVersion.release(forAPI:))
      result["avd:\(avd.name)"] = SimulatorDevice(
        udid: "avd:\(avd.name)", name: avd.displayName, runtime: release.map { "Android \($0)" } ?? "Android",
        runtimeVersion: release.map(AndroidVersion.components) ?? [], state: .shutdown,
        family: avd.isTablet ? .androidTablet : .androidPhone, platform: .android)
    }
    for (device, props) in running {
      let avd = device.isEmulator ? props.avdName : nil
      let udid = avd.map { "avd:\($0)" } ?? "adb:\(device.serial)"
      let known = result[udid]
      let model = [props.manufacturer, props.model ?? device.model].compactMap { $0 }
      let name = known?.name ?? (model.isEmpty ? device.serial : model.joined(separator: " "))
      let release = props.release
      result[udid] = SimulatorDevice(
        udid: udid, name: name, runtime: release.map { "Android \($0)" } ?? known?.runtime ?? "Android",
        runtimeVersion: release.map(AndroidVersion.components) ?? known?.runtimeVersion ?? [],
        state: props.bootCompleted ? .booted : .booting,
        family: props.isTablet || known?.family == .androidTablet ? .androidTablet : .androidPhone,
        platform: .android, adbSerial: device.serial, isPhysical: !device.isEmulator)
    }
    return Array(result.values)
  }
}
