import Foundation

/// Locates the Android SDK tools and scrcpy-server. Android support is optional: without adb,
/// the catalog simply lists no Android devices.
enum AndroidTools {
  /// SDK roots in the order Android Studio, the environment and Homebrew's command-line tools use them.
  static var sdkRoots: [String] {
    let environment = ProcessInfo.processInfo.environment
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    return [environment["ANDROID_HOME"], environment["ANDROID_SDK_ROOT"], "\(home)/Library/Android/sdk",
            "/opt/homebrew/share/android-commandlinetools", "/usr/local/share/android-commandlinetools"].compactMap { $0 }
  }

  static let adb: String? = sdkTool("platform-tools/adb") ?? Tools.path(of: "adb")
  static let emulator: String? = sdkTool("emulator/emulator") ?? Tools.path(of: "emulator")

  /// The AVD folder the emulator reads, honouring ANDROID_AVD_HOME and ANDROID_USER_HOME.
  static var avdHome: URL {
    let environment = ProcessInfo.processInfo.environment
    if let path = environment["ANDROID_AVD_HOME"] { return URL(fileURLWithPath: path) }
    if let path = environment["ANDROID_USER_HOME"] { return URL(fileURLWithPath: path).appending(path: "avd") }
    return FileManager.default.homeDirectoryForCurrentUser.appending(path: ".android/avd")
  }

  private static func sdkTool(_ relative: String) -> String? {
    sdkRoots.map { "\($0)/\(relative)" }.first { FileManager.default.isExecutableFile(atPath: $0) }
  }
}

/// The scrcpy-server jar from an installed scrcpy (`brew install scrcpy`). The server only talks
/// to a client of exactly its own version, so the version travels with the path.
struct ScrcpyServerJar: Sendable {
  enum Failure: LocalizedError {
    case missing, unknownVersion

    var errorDescription: String? {
      switch self {
      case .missing: "scrcpy isn't installed. Install it with `brew install scrcpy` to stream Android devices."
      case .unknownVersion: "Couldn't tell which scrcpy version is installed."
      }
    }
  }

  let path: String
  let version: String

  static func locate() async throws -> ScrcpyServerJar {
    let environment = ProcessInfo.processInfo.environment
    let candidates = [environment["SCRCPY_SERVER_PATH"], "/opt/homebrew/share/scrcpy/scrcpy-server", "/usr/local/share/scrcpy/scrcpy-server"]
    guard let path = candidates.compactMap({ $0 }).first(where: { FileManager.default.fileExists(atPath: $0) }) else { throw Failure.missing }
    // Homebrew keeps the jar under Cellar/scrcpy/<version>/.
    let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
    if let version = version(fromCellarPath: resolved) { return ScrcpyServerJar(path: path, version: version) }
    guard let scrcpy = Tools.path(of: "scrcpy"),
          let result = try? await ProcessRunner.run(scrcpy, ["--version"]),
          let version = version(fromVersionOutput: String(decoding: result.output, as: UTF8.self)) else { throw Failure.unknownVersion }
    return ScrcpyServerJar(path: path, version: version)
  }

  /// ".../Cellar/scrcpy/5.0.1/share/scrcpy/scrcpy-server" → "5.0.1".
  static func version(fromCellarPath path: String) -> String? {
    let parts = path.split(separator: "/")
    guard let index = parts.firstIndex(of: "scrcpy"), index > 0, parts[index - 1] == "Cellar", parts.indices.contains(index + 1) else { return nil }
    // Homebrew revisions ("5.0.1_1") aren't part of the scrcpy version.
    return String(parts[index + 1].split(separator: "_").first ?? parts[index + 1])
  }

  /// "scrcpy 5.0.1 <https://…>" → "5.0.1".
  static func version(fromVersionOutput output: String) -> String? {
    let words = output.split(whereSeparator: \.isWhitespace)
    guard let index = words.firstIndex(of: "scrcpy"), words.indices.contains(index + 1) else { return nil }
    return String(words[index + 1])
  }
}

/// One line of `adb devices -l`.
struct ADBDevice: Equatable, Sendable {
  let serial: String
  /// "device" once usable; also "offline", "unauthorized", "recovery", …
  let state: String
  let model: String?

  var isEmulator: Bool { serial.hasPrefix("emulator-") }
  var isOnline: Bool { state == "device" }

  static func parseList(_ output: String) -> [ADBDevice] {
    output.split(whereSeparator: \.isNewline).compactMap { line in
      let fields = line.split(whereSeparator: \.isWhitespace).map(String.init)
      guard fields.count >= 2, !line.hasPrefix("List of devices"), !line.hasPrefix("*") else { return nil }
      let model = fields.dropFirst(2).first { $0.hasPrefix("model:") }.map { String($0.dropFirst(6)).replacingOccurrences(of: "_", with: " ") }
      return ADBDevice(serial: fields[0], state: fields[1], model: model)
    }
  }
}

/// What a running device reports about itself, read once per connection.
struct AndroidProperties: Equatable, Sendable {
  var release: String?
  var sdk: Int?
  var manufacturer: String?
  var model: String?
  /// Set on emulators (API 30+): the AVD this emulator runs.
  var avdName: String?
  var characteristics: String?
  var bootCompleted = false

  /// The `adb shell` script that prints the properties `parse` reads, one per line.
  static let keys = ["ro.build.version.release", "ro.build.version.sdk", "ro.product.manufacturer", "ro.product.model",
                     "ro.boot.qemu.avd_name", "ro.build.characteristics", "sys.boot_completed"]
  static var script: String { keys.map { "getprop \($0)" }.joined(separator: "; ") }

  static func parse(_ output: String) -> AndroidProperties {
    let lines = output.replacingOccurrences(of: "\r", with: "").components(separatedBy: "\n")
    func value(_ index: Int) -> String? {
      guard lines.indices.contains(index) else { return nil }
      let line = lines[index].trimmingCharacters(in: .whitespaces)
      return line.isEmpty ? nil : line
    }
    return AndroidProperties(release: value(0), sdk: value(1).flatMap(Int.init), manufacturer: value(2), model: value(3),
                             avdName: value(4), characteristics: value(5), bootCompleted: value(6) == "1")
  }

  var isTablet: Bool { characteristics?.contains("tablet") ?? false }
}

/// An Android Virtual Device from `~/.android/avd`.
struct AVD: Equatable, Sendable {
  let name: String
  let displayName: String
  let apiLevel: Int?
  let isTablet: Bool

  /// Reads `<name>.avd/config.ini` (key=value lines).
  static func parse(name: String, config: String) -> AVD {
    var values: [String: String] = [:]
    for line in config.split(whereSeparator: \.isNewline) {
      guard let equals = line.firstIndex(of: "=") else { continue }
      values[line[..<equals].trimmingCharacters(in: .whitespaces)] = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
    }
    // image.sysdir.1=system-images/android-35/google_apis/arm64-v8a/
    let api = values["image.sysdir.1"]?.split(separator: "/").first { $0.hasPrefix("android-") }.flatMap { Int($0.dropFirst(8)) }
    let device = values["hw.device.name"] ?? ""
    let tablet = device.localizedCaseInsensitiveContains("tablet") || device.contains("pixel_c")
    return AVD(name: name, displayName: values["avd.ini.displayname"] ?? name.replacingOccurrences(of: "_", with: " "),
               apiLevel: api, isTablet: tablet)
  }

  static func listInstalled(in folder: URL = AndroidTools.avdHome) -> [AVD] {
    let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
    return files.filter { $0.pathExtension == "ini" }.compactMap { ini in
      let name = ini.deletingPathExtension().lastPathComponent
      // <name>.ini points at the data folder, which is usually <name>.avd next to it.
      let pointer = (try? String(contentsOf: ini, encoding: .utf8)) ?? ""
      let path = pointer.split(whereSeparator: \.isNewline).first { $0.hasPrefix("path=") }.map { String($0.dropFirst(5)) }
      let folder = path.map { URL(fileURLWithPath: $0) } ?? folder.appending(path: "\(name).avd")
      guard let config = try? String(contentsOf: folder.appending(path: "config.ini"), encoding: .utf8) else { return nil }
      return parse(name: name, config: config)
    }
  }
}

enum AndroidVersion {
  /// Marketing version for an API level, for AVDs that aren't running.
  static func release(forAPI api: Int) -> String {
    switch api {
    case 37...: String(api - 20)
    case 36: "16"
    case 35: "15"
    case 34: "14"
    case 33: "13"
    case 32: "12L"
    case 31: "12"
    case 30: "11"
    case 29: "10"
    case 28: "9"
    default: "API \(api)"
    }
  }

  /// "15" → [15], "12L" → [12].
  static func components(_ release: String) -> [Int] {
    release.split(separator: ".").compactMap { Int($0.prefix { $0.isNumber }) }
  }
}

/// Runs adb against one device.
enum ADB {
  enum Failure: LocalizedError {
    case missing
    case failed(String)

    var errorDescription: String? {
      switch self {
      case .missing: "adb isn't installed. Install Android Studio or `brew install --cask android-platform-tools`."
      case .failed(let message): message
      }
    }
  }

  static func run(_ arguments: [String], serial: String? = nil, input: Data? = nil) async throws -> ProcessRunner.Result {
    guard let adb = AndroidTools.adb else { throw Failure.missing }
    return try await ProcessRunner.run(adb, (serial.map { ["-s", $0] } ?? []) + arguments, input: input)
  }

  static func shell(_ command: String, serial: String) async throws -> String {
    let result = try await run(["shell", command], serial: serial)
    return String(decoding: result.output, as: UTF8.self)
  }

  /// Starts an AVD headless, the way `simctl boot` starts a simulator without Simulator.app.
  /// The emulator keeps running after SimStream quits. Its log goes to a file (a pipe nobody
  /// drains would stall it), which `bootFailure` reads if it exits early.
  static func boot(avd: String) throws -> Process {
    guard let emulator = AndroidTools.emulator else { throw Failure.failed("The Android emulator isn't installed.") }
    let log = bootLog(avd)
    FileManager.default.createFile(atPath: log.path, contents: nil)
    let handle = try FileHandle(forWritingTo: log)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: emulator)
    // The emulator falls back to CPU rendering for API 35+ (it wants GLES 3.1; the Metal path offers 3.0).
    // On a Pixel 8 AVD that meant 44 ms median frames and 74% jank; the host GPU gave 22 ms and 14%.
    // Apps that require ES 3.1 may fail to draw; most fall back to 3.0 (Chrome does).
    process.arguments = ["-avd", avd, "-no-window", "-no-boot-anim", "-no-audio", "-gpu", "host"]
    process.standardOutput = handle
    process.standardError = handle
    process.standardInput = FileHandle.nullDevice
    try process.run()
    return process
  }

  static func bootLog(_ avd: String) -> URL {
    FileManager.default.temporaryDirectory.appending(path: "simstream-emulator-\(avd).log")
  }

  /// The emulator's own reason for exiting, such as "Not enough space to create userdata partition…".
  static func bootFailure(_ avd: String) -> String {
    let log = (try? String(contentsOf: bootLog(avd), encoding: .utf8)) ?? ""
    return bootFailure(fromLog: log) ?? "The emulator for \(avd) quit while starting."
  }

  static func bootFailure(fromLog log: String) -> String? {
    log.split(whereSeparator: \.isNewline).last { $0.contains("FATAL") || $0.contains("ERROR") }
      .map { line in
        let text = line.split(separator: "|", maxSplits: 1).last.map(String.init) ?? String(line)
        return text.trimmingCharacters(in: .whitespaces)
      }
  }

  static func shutdown(serial: String) async {
    _ = try? await run(["emu", "kill"], serial: serial)
  }
}
