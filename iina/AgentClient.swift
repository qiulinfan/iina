//
//  AgentClient.swift
//  iina
//
//  Created by Qiulin Fan on 2026-10-24.
//  Copyright © 2026 lhc. All rights reserved.
//

import Foundation

/// Talks to a local `omp acp` process over the Agent Client Protocol: newline-delimited JSON-RPC 2.0
/// on stdin/stdout. All callbacks are delivered on the main queue.
class AgentClient {
  typealias JSON = [String: Any]

  struct AgentError: LocalizedError {
    let message: String
    var errorDescription: String? { message }
  }

  static let subsystem = Logger.makeSubsystem("agent")

  /// Sessions started from IINA live apart from the CLI and Zed sessions.
  static let sessionDir = NSHomeDirectory() + "/.omp/agent/sessions-iina"

  /// `session/update` payloads other than config changes.
  var onUpdate: ((JSON) -> Void)?
  /// The session's select options (mode, model, thinking level).
  var onConfigOptions: (([JSON]) -> Void)?
  /// `session/request_permission`; reply with the chosen option id, or nil to cancel.
  var onPermissionRequest: ((JSON, @escaping (String?) -> Void) -> Void)?
  var onExit: ((String) -> Void)?

  private(set) var sessionId: String?
  /// Whether this session got a prompt; a session that never did is deleted when it ends.
  private var prompted = false
  private var process: Process?
  private var input: FileHandle?
  private var buffer = Data()
  private var stderrTail = ""
  private var nextId = 1
  private var pending: [Int: (Result<JSON, Error>) -> Void] = [:]

  var isRunning: Bool { process?.isRunning == true }

  private static func findExecutable() -> String? {
    let candidates = [NSHomeDirectory() + "/.local/bin/omp", "/opt/homebrew/bin/omp", "/usr/local/bin/omp"]
    return candidates.first { FileManager.default.isExecutableFile(atPath: $0) }
  }

  private func log(_ message: String, level: Logger.Level = .debug) {
    Logger.log(message, level: level, subsystem: AgentClient.subsystem)
  }

  // MARK: - Lifecycle

  /// Launch omp, initialize the connection and open a new session rooted at `cwd`.
  func start(cwd: String, completion: @escaping (Error?) -> Void) {
    guard let executable = AgentClient.findExecutable() else {
      completion(AgentError(message: "omp not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin"))
      return
    }
    try? FileManager.default.createDirectory(atPath: AgentClient.sessionDir, withIntermediateDirectories: true)

    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["--session-dir", AgentClient.sessionDir, "acp"]
    process.currentDirectoryURL = URL(fileURLWithPath: cwd)
    // Apps launched from the Dock get a minimal PATH; omp's tools need the usual user locations.
    var env = ProcessInfo.processInfo.environment
    let extraPath = [NSHomeDirectory() + "/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"].joined(separator: ":")
    env["PATH"] = extraPath + ":" + (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin")
    process.environment = env

    let stdinPipe = Pipe(), stdoutPipe = Pipe(), stderrPipe = Pipe()
    process.standardInput = stdinPipe
    process.standardOutput = stdoutPipe
    process.standardError = stderrPipe

    stdoutPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      // An empty read means EOF; stop the handler so it doesn't spin.
      if data.isEmpty { handle.readabilityHandler = nil; return }
      DispatchQueue.main.async { self?.receive(data) }
    }
    stderrPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
      let data = handle.availableData
      if data.isEmpty { handle.readabilityHandler = nil; return }
      guard let text = String(data: data, encoding: .utf8) else { return }
      DispatchQueue.main.async {
        guard let self else { return }
        self.stderrTail = String((self.stderrTail + text).suffix(2000))
      }
    }
    process.terminationHandler = { [weak self] proc in
      DispatchQueue.main.async { self?.didExit(status: proc.terminationStatus) }
    }

    do {
      try process.run()
    } catch {
      completion(error)
      return
    }
    self.process = process
    self.input = stdinPipe.fileHandleForWriting
    log("Started \(executable) in \(cwd)")

    let initParams: JSON = [
      "protocolVersion": 1,
      "clientCapabilities": ["fs": ["readTextFile": false, "writeTextFile": false], "terminal": false],
      "clientInfo": ["name": "iina", "title": "IINA", "version": InfoDictionary.shared.version.0],
    ]
    request("initialize", initParams) { [weak self] result in
      guard let self else { return }
      if case .failure(let error) = result { completion(error); return }
      self.request("session/new", ["cwd": cwd, "mcpServers": []]) { result in
        switch result {
        case .success(let response):
          self.sessionId = response["sessionId"] as? String
          self.prompted = false
          if let options = response["configOptions"] as? [JSON] { self.onConfigOptions?(options) }
          completion(self.sessionId == nil ? AgentError(message: "omp returned no session id") : nil)
        case .failure(let error):
          completion(error)
        }
      }
    }
  }

  /// Cleanups of unused sessions still waiting for their omp to exit.
  private static let cleanups = DispatchGroup()

  /// Called before IINA quits, so the files of unused sessions are gone when it exits.
  static func waitForCleanups() {
    _ = cleanups.wait(timeout: .now() + 3)
  }

  func stop() {
    pending.removeAll()
    let unusedSession = prompted ? nil : sessionId
    sessionId = nil
    guard let process else { return }
    self.process = nil
    try? input?.close()
    input = nil
    let exited = DispatchSemaphore(value: 0)
    process.terminationHandler = { _ in exited.signal() }
    if process.isRunning { process.terminate() } else { exited.signal() }
    guard let unusedSession else { return }
    // Delete only after omp has exited, so it can't write the file again.
    DispatchQueue.global(qos: .utility).async(group: AgentClient.cleanups) {
      if exited.wait(timeout: .now() + 3) == .success { AgentClient.deleteUnusedSession(unusedSession) }
    }
  }

  /// Remove the file of a session that never got a prompt, with the lock omp keeps beside it
  /// (`<time>_<id>.jsonl` and `.<time>_<id>.jsonl.lock.os`). A file holding a message is kept.
  private static func deleteUnusedSession(_ id: String) {
    let fileManager = FileManager.default
    guard let names = try? fileManager.contentsOfDirectory(atPath: sessionDir) else { return }
    let dir = URL(fileURLWithPath: sessionDir)
    guard let file = names.first(where: { $0.hasSuffix("_\(id).jsonl") && !$0.hasPrefix(".") }),
          let content = try? String(contentsOf: dir.appendingPathComponent(file), encoding: .utf8),
          !content.contains(#""type":"message""#) else { return }
    for name in [file, ".\(file).lock.os"] {
      try? fileManager.removeItem(at: dir.appendingPathComponent(name))
    }
    Logger.log("Removed unused omp session \(id)", subsystem: subsystem)
  }

  private func didExit(status: Int32) {
    guard process != nil else { return }
    process = nil
    input = nil
    if let sessionId, !prompted { AgentClient.deleteUnusedSession(sessionId) }
    sessionId = nil
    let reason = stderrTail.trimmingCharacters(in: .whitespacesAndNewlines)
    let message = "omp exited (\(status))" + (reason.isEmpty ? "" : ": \(reason.split(separator: "\n").last ?? "")")
    log(message, level: .warning)
    let callbacks = pending.values
    pending.removeAll()
    callbacks.forEach { $0(.failure(AgentError(message: message))) }
    onExit?(message)
  }

  // MARK: - Session requests

  /// Send a prompt; `completion` receives the stop reason once the turn ends.
  func prompt(_ blocks: [JSON], completion: @escaping (Result<String, Error>) -> Void) {
    guard let sessionId else { completion(.failure(AgentError(message: "No omp session"))); return }
    prompted = true
    request("session/prompt", ["sessionId": sessionId, "prompt": blocks]) { result in
      completion(result.map { $0["stopReason"] as? String ?? "end_turn" })
    }
  }

  func cancel() {
    guard let sessionId else { return }
    send(["jsonrpc": "2.0", "method": "session/cancel", "params": ["sessionId": sessionId]])
  }

  func setConfigOption(_ configId: String, value: String) {
    guard let sessionId else { return }
    request("session/set_config_option", ["sessionId": sessionId, "configId": configId, "value": value]) { [weak self] result in
      if case .success(let response) = result, let options = response["configOptions"] as? [JSON] {
        self?.onConfigOptions?(options)
      }
    }
  }

  // MARK: - JSON-RPC

  private func request(_ method: String, _ params: JSON, completion: @escaping (Result<JSON, Error>) -> Void) {
    let id = nextId
    nextId += 1
    pending[id] = completion
    send(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
  }

  private func send(_ message: JSON) {
    guard let input, let data = try? JSONSerialization.data(withJSONObject: message) else { return }
    do {
      try input.write(contentsOf: data + Data([0x0A]))
    } catch {
      log("Failed to write to omp: \(error)", level: .error)
    }
  }

  private func receive(_ data: Data) {
    buffer.append(data)
    while let newline = buffer.firstIndex(of: 0x0A) {
      let line = buffer[buffer.startIndex..<newline]
      buffer.removeSubrange(buffer.startIndex...newline)
      guard !line.isEmpty,
            let message = (try? JSONSerialization.jsonObject(with: line)) as? JSON else { continue }
      handle(message)
    }
  }

  private func handle(_ message: JSON) {
    let method = message["method"] as? String
    let params = message["params"] as? JSON ?? [:]

    if let method, let id = message["id"] {
      // A request from the agent.
      if method == "session/request_permission", let onPermissionRequest {
        onPermissionRequest(params) { [weak self] optionId in
          let outcome: JSON = optionId.map { ["outcome": "selected", "optionId": $0] } ?? ["outcome": "cancelled"]
          self?.send(["jsonrpc": "2.0", "id": id, "result": ["outcome": outcome]])
        }
      } else {
        send(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not supported: \(method)"]])
      }
    } else if let method {
      guard method == "session/update", let update = params["update"] as? JSON else { return }
      if update["sessionUpdate"] as? String == "config_option_update" {
        if let options = update["configOptions"] as? [JSON] { onConfigOptions?(options) }
      } else {
        onUpdate?(update)
      }
    } else if let id = message["id"] as? Int, let callback = pending.removeValue(forKey: id) {
      if let error = message["error"] as? JSON {
        callback(.failure(AgentError(message: error["message"] as? String ?? "omp error")))
      } else {
        callback(.success(message["result"] as? JSON ?? [:]))
      }
    }
  }
}
