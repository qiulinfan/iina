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

  /// omp's own session store, shared with the CLI, Zed and omp gui. IINA's sessions are the ones whose
  /// header names IINA as the ACP client that started them.
  static let sessionsRoot = NSHomeDirectory() + "/.omp/agent/sessions"

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

  /// A stored session, labelled by its first question.
  struct PastSession {
    let id: String
    let cwd: String
    let question: String
    let video: String?
    let date: Date
  }

  /// The most recent IINA sessions in `sessionsRoot` that hold a question, newest first. Read from the
  /// files, so the list is ready before omp has started.
  static func pastSessions(limit: Int = 30) -> [PastSession] {
    let root = URL(fileURLWithPath: sessionsRoot)
    let found = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey],
                                               options: [.skipsHiddenFiles])
    let files = (found?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "jsonl" }
    let dated = files.map { file in
      (file, (try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast)
    }.sorted { $0.1 > $1.1 }
    var sessions: [PastSession] = []
    for (file, date) in dated where sessions.count < limit {
      if let session = readPastSession(file, date: date) { sessions.append(session) }
    }
    return sessions
  }

  /// The session header and its first user message, which carries the panel's context block.
  private static func readPastSession(_ file: URL, date: Date) -> PastSession? {
    guard let handle = try? FileHandle(forReadingFrom: file) else { return nil }
    defer { try? handle.close() }
    // The first question is near the top; tool output later in the file can be large.
    guard let data = try? handle.read(upToCount: 512 * 1024) else { return nil }
    // Lenient decoding: the cut may split a character, which only affects the last, incomplete line.
    let text = String(decoding: data, as: UTF8.self)
    var id: String?, cwd: String?
    for line in text.split(separator: "\n") {
      guard let entry = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? JSON else { continue }
      if entry["type"] as? String == "session" {
        // Sessions the CLI, Zed or omp gui started share the store; only IINA's are listed.
        guard (entry["origin"] as? JSON)?["client"] as? String == "iina" else { return nil }
        id = entry["id"] as? String
        cwd = entry["cwd"] as? String
      }
      guard entry["type"] as? String == "message", let message = entry["message"] as? JSON,
            message["role"] as? String == "user", let id, let cwd else { continue }
      let content = (message["content"] as? [JSON])?.compactMap { $0["text"] as? String }.joined(separator: "\n")
        ?? message["content"] as? String ?? ""
      let (question, video) = splitContext(content)
      return PastSession(id: id, cwd: cwd, question: question, video: video, date: date)
    }
    return nil
  }

  /// The question and video title of a prompt the panel built with its context block.
  static func splitContext(_ prompt: String) -> (question: String, video: String?) {
    guard let range = prompt.range(of: "\n\nQuestion: ") else { return (prompt, nil) }
    let video = prompt.split(separator: "\n").first { $0.hasPrefix("Video: ") }.map {
      String($0.dropFirst("Video: ".count).components(separatedBy: " — ")[0])
    }
    return (String(prompt[range.upperBound...]), video)
  }

  // MARK: - Lifecycle

  /// Launch omp, initialize the connection and open a session rooted at `cwd`: a new one, or the
  /// stored session `resume`, whose history omp replays through `onUpdate` before this completes.
  func start(cwd: String, resume: String? = nil, completion: @escaping (Error?) -> Void) {
    guard let executable = AgentClient.findExecutable() else {
      completion(AgentError(message: "omp not found in ~/.local/bin, /opt/homebrew/bin or /usr/local/bin"))
      return
    }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = ["acp"]
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
      var params: JSON = ["cwd": cwd, "mcpServers": []]
      if let resume { params["sessionId"] = resume }
      self.request(resume == nil ? "session/new" : "session/load", params) { result in
        switch result {
        case .success(let response):
          self.sessionId = resume ?? response["sessionId"] as? String
          // A reopened session already holds a conversation, so it is never cleaned up as unused.
          self.prompted = resume != nil
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
  /// (`<time>_<id>.jsonl` and `.<time>_<id>.jsonl.lock.os`), in whichever project folder of the store
  /// omp put it. A file holding a message, or one another client started, is kept.
  private static func deleteUnusedSession(_ id: String) {
    let fileManager = FileManager.default
    let found = fileManager.enumerator(at: URL(fileURLWithPath: sessionsRoot), includingPropertiesForKeys: nil,
                                       options: [.skipsHiddenFiles])
    guard let path = (found?.allObjects as? [URL])?.first(where: { $0.lastPathComponent.hasSuffix("_\(id).jsonl") }),
          let content = try? String(contentsOf: path, encoding: .utf8),
          content.contains(#""origin":{"mode":"acp","client":"iina"}"#),
          !content.contains(#""type":"message""#) else { return }
    let file = path.lastPathComponent
    let dir = path.deletingLastPathComponent()
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
