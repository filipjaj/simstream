import Darwin
import Foundation

// simstream — headless SimStream for Macs you reach over SSH (e.g. the Mac mini).
//
//   simstream list [--json]                       simulators, emulators and Android devices on this Mac
//   simstream start [share options] [--json]      share in the background; survives logout and SSH
//                                                 disconnects; prints the link once it's live
//   simstream status [--json]                     the background share, if any
//   simstream ctl <command>                       extend · pass · control on|off · switching on|off ·
//                                                 quality data-saver|balanced|sharp · lock <bundle-id>|off
//   simstream apps --udid <udid> [--json]         user apps on a simulator or Android device, for --lock-app
//   simstream stop                                end the background share
//   simstream share [share options]               share in the foreground; Ctrl-C stops
//
// Share options: --udid <udid> | --name <name>, --minutes 15, --quality balanced, --port <n>,
// --no-tunnel, --view-only, --allow-switching, --lock-app <bundle-id> (keep viewers inside one app),
// --allow-physical (required to share a real Android phone: viewers get everything on it).
//
// A background share keeps its state in ~/.local/state/simstream/share.json and reads commands
// from the FIFO ~/.local/state/simstream/control, which is what `status` and `ctl` use.

setvbuf(stdout, nil, _IOLBF, 0)

struct Flags {
  var values: [String: String] = [:]
  var switches: Set<String> = []
  var positional: [String] = []

  init(_ arguments: ArraySlice<String>) {
    var iterator = arguments.makeIterator()
    while let argument = iterator.next() {
      guard argument.hasPrefix("--") else { positional.append(argument); continue }
      let name = String(argument.dropFirst(2))
      if ["no-tunnel", "view-only", "allow-switching", "allow-physical", "json"].contains(name) {
        switches.insert(name)
      } else if let value = iterator.next() {
        values[name] = value
      }
    }
  }
}

/// The background share's state, as written to share.json and printed by `status --json`.
struct ShareState: Codable, Equatable {
  enum Phase: String, Codable { case starting, live, ended, failed, none }

  var phase: Phase
  var pid: Int32 = 0
  var step: String?
  var udid: String?
  var deviceName: String?
  var runtime: String?
  var url: String?
  var localURL: String?
  /// Milliseconds since 1970.
  var expiresAt: Double?
  var viewers = 0
  var holder: String?
  var waiting = 0
  var fps = 0
  var bytesPerSecond = 0
  var codec = ""
  var transport: String?
  var message: String?
  var allowControl = true
  var allowSwitching = false
  var quality = "balanced"
  var lockedApp: LockedApp?
}

struct DeviceRow: Encodable {
  let udid: String
  let name: String
  let runtime: String
  let runtimeVersion: [Int]
  let family: String
  let booted: Bool
  let platform: SimulatorDevice.Platform
  let physical: Bool
}

enum Paths {
  static let state = FileManager.default.homeDirectoryForCurrentUser.appending(path: ".local/state/simstream")
  static let stateFile = state.appending(path: "share.json")
  static let control = state.appending(path: "control")
  static let log = state.appending(path: "share.log")
}

/// share.json and share.log hold the live link, which grants control of the simulator. Keeps the
/// folder and its files private to this user, including ones an older version left world-readable.
func preparePrivateStateDirectory() {
  try? FileManager.default.createDirectory(at: Paths.state, withIntermediateDirectories: true,
                                           attributes: [.posixPermissions: 0o700])
  chmod(Paths.state.path, 0o700)
  for file in [Paths.stateFile, Paths.log, Paths.control] { chmod(file.path, 0o600) }
}

func fail(_ message: String) -> Int32 {
  FileHandle.standardError.write(Data("simstream: \(message)\n".utf8))
  return 1
}

func quality(named name: String?) -> StreamQuality? {
  switch name {
  case "data-saver": .dataSaver
  case "balanced": .balanced
  case "sharp": .sharp
  default: nil
  }
}

func encode<T: Encodable>(_ value: T) -> String {
  String(decoding: (try? JSONEncoder().encode(value)) ?? Data("{}".utf8), as: UTF8.self)
}

/// The background share's state, or `.none` if it isn't running.
func readState() -> ShareState {
  guard let data = try? Data(contentsOf: Paths.stateFile),
        let state = try? JSONDecoder().decode(ShareState.self, from: data) else { return ShareState(phase: .none) }
  let alive = state.pid > 0 && kill(state.pid, 0) == 0
  if !alive, state.phase == .starting || state.phase == .live { return ShareState(phase: .none) }
  return state
}

func printState(_ state: ShareState, json: Bool) {
  if json { return print(encode(state)) }
  switch state.phase {
  case .none: print("No share running")
  case .starting: print("Starting: \(state.step ?? "…")")
  case .live:
    print("Sharing \(state.deviceName ?? "?") (\(state.runtime ?? "")) \(state.udid ?? "")")
    // Without a tunnel the share's URL is the local one.
    let isPublic = state.url != nil && state.url != state.localURL
    if let url = state.url { print("\(isPublic ? "Public" : "Local"): \(url)") }
    if isPublic, state.allowControl { warnAboutControl() }
    if let expires = state.expiresAt {
      print("Expires: \(Date(timeIntervalSince1970: expires / 1000).formatted(date: .omitted, time: .standard))")
    }
    print("Viewers: \(state.viewers) · Control: \(state.holder ?? "nobody") · \(state.waiting) waiting")
    if let app = state.lockedApp { print("Locked to: \(app.name) (\(app.bundleID))") }
  case .ended: print("Ended: \(state.message ?? "")")
  case .failed: print("Failed: \(state.message ?? "")")
  }
}

/// Sends one command line to the background share. Fails if nothing is reading the FIFO.
func sendControl(_ command: String) -> Bool {
  let fd = open(Paths.control.path, O_WRONLY | O_NONBLOCK)
  guard fd >= 0 else { return false }
  defer { close(fd) }
  let line = Array((command + "\n").utf8)
  return write(fd, line, line.count) == line.count
}

nonisolated(unsafe) var retained: [AnyObject] = [] // Signal sources live for the whole process.

// MARK: - Commands

@MainActor
func run() async -> Int32 {
  // Files this process and its background share create (share.json, share.log, the FIFO) carry
  // the live link, so none of them may be readable by other accounts.
  umask(0o077)
  let arguments = CommandLine.arguments.dropFirst()
  let command = arguments.first ?? "help"
  let flags = Flags(arguments.dropFirst())
  let json = flags.switches.contains("json")

  switch command {
  case "list":
    let catalog = SimulatorCatalog()
    await catalog.refresh()
    if json {
      print(encode(catalog.devices.map {
        DeviceRow(udid: $0.udid, name: $0.name, runtime: $0.runtime, runtimeVersion: $0.runtimeVersion, family: $0.family.symbol,
                  booted: $0.isBooted, platform: $0.platform, physical: $0.isPhysical)
      }))
    } else {
      for device in catalog.booted { print("\(device.udid)  \(device.name)  \(device.runtime)\(device.isPhysical ? "  (physical)" : "")") }
    }
    return 0

  case "apps":
    guard let udid = flags.values["udid"] else { return fail("usage: simstream apps --udid <udid>") }
    let catalog = SimulatorCatalog()
    await catalog.refresh()
    let apps: [LockedApp]
    if let device = catalog.device(udid) { apps = await InstalledApps.list(device: device) } else { apps = await InstalledApps.list(udid: udid) }
    if json { print(encode(apps)) } else { apps.forEach { print("\($0.bundleID)  \($0.name)") } }
    return 0

  case "status":
    printState(readState(), json: json)
    return 0

  case "ctl":
    guard !flags.positional.isEmpty else { return fail("usage: simstream ctl <command>") }
    return sendControl(flags.positional.joined(separator: " ")) ? 0 : fail("no share is running")

  case "stop":
    return await stopBackground() ? 0 : fail("the share didn't stop")

  case "start":
    return await startBackground(flags: flags, json: json)

  case "share":
    return await share(flags: flags, stateDirectory: flags.values["state"] != nil)

  default:
    print("usage: simstream list|start|status|ctl|stop|share — see the header of SimStreamCLI/main.swift")
    return command == "help" ? 0 : 1
  }
}

/// Stops the background share: asks politely, then SIGTERM.
@MainActor
func stopBackground() async -> Bool {
  let state = readState()
  guard state.phase == .starting || state.phase == .live else { return true }
  _ = sendControl("stop")
  for _ in 0..<30 {
    if kill(state.pid, 0) != 0 { return true }
    try? await Task.sleep(for: .milliseconds(100))
  }
  kill(state.pid, SIGTERM)
  try? await Task.sleep(for: .milliseconds(500))
  return kill(state.pid, 0) != 0
}

/// Spawns `simstream share --state …` in a new session so it outlives this SSH connection,
/// then waits until it is live (or failed) and prints its state.
@MainActor
func startBackground(flags: Flags, json: Bool) async -> Int32 {
  guard await stopBackground() else { return fail("a previous share is still running") }
  preparePrivateStateDirectory()
  try? FileManager.default.removeItem(at: Paths.stateFile)

  var childArguments = ["share", "--state", Paths.state.path]
  for (key, value) in flags.values where key != "state" { childArguments += ["--\(key)", value] }
  for key in flags.switches where key != "json" { childArguments.append("--\(key)") }

  var attributes: posix_spawnattr_t?
  posix_spawnattr_init(&attributes)
  defer { posix_spawnattr_destroy(&attributes) }
  posix_spawnattr_setflags(&attributes, Int16(POSIX_SPAWN_SETSID))
  var actions: posix_spawn_file_actions_t?
  posix_spawn_file_actions_init(&actions)
  defer { posix_spawn_file_actions_destroy(&actions) }
  posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
  posix_spawn_file_actions_addopen(&actions, 1, Paths.log.path, O_WRONLY | O_CREAT | O_TRUNC, 0o600)
  posix_spawn_file_actions_adddup2(&actions, 1, 2)

  let executable = Bundle.main.executablePath ?? CommandLine.arguments[0]
  let argv = ([executable] + childArguments).map { strdup($0) } + [nil]
  defer { argv.forEach { free($0) } }
  var pid: pid_t = 0
  let status = posix_spawn(&pid, executable, &actions, &attributes, argv, environ)
  guard status == 0 else { return fail("couldn't start the background share (\(status))") }

  // Wait for the link: tunnel + DNS usually take 5–15 s.
  for _ in 0..<(90 * 4) {
    try? await Task.sleep(for: .milliseconds(250))
    let state = readState()
    if state.pid == pid, state.phase == .live || state.phase == .failed || state.phase == .ended {
      printState(state, json: json)
      return state.phase == .live ? 0 : 1
    }
    if kill(pid, 0) != 0 {
      let log = (try? String(contentsOf: Paths.log, encoding: .utf8)) ?? ""
      return fail("the share exited: \(log.trimmingCharacters(in: .whitespacesAndNewlines))")
    }
  }
  return fail("the share didn't go live within 90 seconds; see \(Paths.log.path)")
}

/// The simulator shares this Mac's network, so control over a public link reaches it too. To stderr,
/// so scripts reading the link from stdout are unaffected.
func warnAboutControl() {
  FileHandle.standardError.write(Data("Note: viewers with control can use Safari in the simulator to reach this Mac's localhost and network. Use --view-only or `simstream ctl control off` to prevent that.\n".utf8))
}

/// The installed app with this bundle ID, if it's a user app on that device.
func installedApp(_ bundleID: String, device: SimulatorDevice) async -> LockedApp? {
  guard LockedApp.isValidBundleID(bundleID) else { return nil }
  return await InstalledApps.list(device: device).first { $0.bundleID == bundleID }
}

/// Runs a share in this process. With `--state` it also publishes share.json and reads the control FIFO.
@MainActor
func share(flags: Flags, stateDirectory: Bool) async -> Int32 {
  let catalog = SimulatorCatalog()
  await catalog.refresh()
  var state = ShareState(phase: .starting, pid: getpid())
  func publish() {
    guard stateDirectory, let data = try? JSONEncoder().encode(state) else { return }
    try? data.write(to: Paths.stateFile, options: .atomic)
  }

  let device: SimulatorDevice?
  if let udid = flags.values["udid"] {
    device = catalog.device(udid)
  } else if let name = flags.values["name"] {
    device = catalog.booted.first { $0.name == name } ?? catalog.booted.first { $0.name.localizedCaseInsensitiveContains(name) }
  } else {
    device = catalog.booted.first { !$0.isPhysical }
  }
  guard let device, device.isBooted else {
    state.phase = .failed
    state.message = device.map { "\($0.name) isn't booted." } ?? "No matching booted simulator."
    publish()
    return fail(state.message ?? "")
  }
  guard !device.isPhysical || flags.switches.contains("allow-physical") else {
    state.phase = .failed
    state.message = "\(device.name) is a real phone: viewers could reach everything on it. Pass --allow-physical to share it anyway."
    publish()
    return fail(state.message ?? "")
  }

  let session = ShareSession(pool: LinkPool(), catalog: catalog)
  if let minutes = flags.values["minutes"].flatMap(Double.init) { session.options.lifetime = minutes * 60 }
  if let port = flags.values["port"].flatMap(UInt16.init) { session.options.port = port }
  session.options.tunnel = !flags.switches.contains("no-tunnel")
  session.allowControl = !flags.switches.contains("view-only")
  session.allowSwitching = flags.switches.contains("allow-switching")
  session.quality = quality(named: flags.values["quality"]) ?? .balanced
  if let bundleID = flags.values["lock-app"] {
    guard let app = await installedApp(bundleID, device: device) else {
      state.phase = .failed
      state.message = "\(bundleID) isn't installed on \(device.name)."
      publish()
      return fail(state.message ?? "")
    }
    session.lockedApp = app
  }

  for signal in [SIGINT, SIGTERM, SIGHUP] {
    Foundation.signal(signal, SIG_IGN)
    let source = DispatchSource.makeSignalSource(signal: signal, queue: .main)
    source.setEventHandler {
      MainActor.assumeIsolated { session.stop() }
    }
    source.resume()
    retained.append(source)
  }

  func handle(_ line: String) {
    // Only the command word is case-insensitive: bundle IDs aren't.
    let words = line.split(separator: " ").map(String.init)
    switch (words.first?.lowercased(), words.dropFirst().first) {
    case ("extend", _): session.extend()
    case ("pass", _): session.passControl()
    case ("stop", _): session.stop()
    case ("control", let value?): session.allowControl = value.lowercased() == "on"
    case ("switching", let value?): session.allowSwitching = value.lowercased() == "on"
    case ("quality", let value?): if let q = quality(named: value.lowercased()) { session.quality = q }
    case ("lock", "off"?): session.lockedApp = nil
    case ("lock", let bundleID?):
      Task { @MainActor in
        if let app = await installedApp(bundleID, device: session.device ?? device) { session.lockedApp = app }
      }
    default: break
    }
  }
  if stateDirectory {
    unlink(Paths.control.path)
    mkfifo(Paths.control.path, 0o600)
    Thread.detachNewThread {
      // O_RDWR keeps the FIFO open between writers, so reads block instead of hitting EOF.
      guard let fifo = FileHandle(forUpdatingAtPath: Paths.control.path) else { return }
      var pending = ""
      while true {
        let chunk = fifo.availableData
        guard !chunk.isEmpty else { continue }
        pending += String(decoding: chunk, as: UTF8.self)
        var lines = pending.components(separatedBy: "\n")
        pending = lines.removeLast()
        for line in lines { DispatchQueue.main.async { MainActor.assumeIsolated { handle(line) } } }
      }
    }
  }

  state.udid = device.udid
  state.deviceName = device.name
  state.runtime = device.runtime
  publish()
  print("Sharing \(device.name) (\(device.runtime)) \(device.udid)")
  session.start(device)

  var printed = Set<String>()
  func once(_ key: String, _ line: String) { if printed.insert(key).inserted { print(line) } }
  while true {
    var next = state
    next.allowControl = session.allowControl
    next.allowSwitching = session.allowSwitching
    next.lockedApp = session.lockedApp
    next.quality = session.quality.cliName
    next.localURL = session.localURL?.absoluteString
    next.viewers = session.viewers
    next.holder = session.controllerName
    next.waiting = session.waitingCount
    next.fps = session.stats.framesPerSecond
    next.bytesPerSecond = session.stats.bytesPerSecond
    next.codec = session.stats.codec
    next.transport = session.inputTransport
    next.expiresAt = session.expiresAt.map { $0.timeIntervalSince1970 * 1000 }
    switch session.phase {
    case .idle: break
    case .starting(let step): next.step = step
    case .live(let url): next.phase = .live; next.url = url.absoluteString
    case .ended(let reason): next.phase = .ended; next.message = reason == .expired ? "The link expired." : "Stopped."
    case .failed(let message): next.phase = .failed; next.message = message
    }
    if next != state {
      state = next
      publish()
      if let local = state.localURL { once("local", "Local: \(local)") }
      if state.phase == .live, let url = state.url, session.options.tunnel {
        once("public", "Public: \(url)")
        if session.allowControl, printed.insert("warning").inserted { warnAboutControl() }
      }
    }
    switch state.phase {
    case .ended:
      print(state.message ?? "Ended")
      if stateDirectory { unlink(Paths.control.path) }
      return 0
    case .failed:
      if stateDirectory { unlink(Paths.control.path) }
      return fail(state.message ?? "failed")
    default:
      break
    }
    try? await Task.sleep(for: .milliseconds(250))
  }
}

Task { @MainActor in exit(await run()) }
dispatchMain()
