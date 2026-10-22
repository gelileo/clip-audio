import Foundation

/// Owns the embedded interpreter.
///
/// Work runs on a dedicated Thread rather than a DispatchQueue because of the
/// stack. GCD worker threads get 512KB on iOS, and the EJS challenge solver
/// recurses deeply enough while interpreting ~3MB of YouTube player JS to blow
/// straight through that — observed as a SIGBUS at the stack guard page, not a
/// catchable error. A Thread lets us ask for a real stack up front.
final class PythonRuntime: @unchecked Sendable {
    static let shared = PythonRuntime()

    /// Must comfortably exceed the solver's peak depth, and must exceed the
    /// limit handed to QuickJS (see clipaudio_jsc_quickjs.STACK_SIZE) so
    /// QuickJS raises a JS error before the real stack is exhausted.
    static let stackSize = 16 * 1024 * 1024

    private let cond = NSCondition()
    private var pending: [() -> Void] = []
    private var initError: String?
    private var didInit = false

    private init() {
        let t = Thread { [weak self] in self?.serviceLoop() }
        t.name = "stream.clipaudio.python"
        t.stackSize = PythonRuntime.stackSize
        t.qualityOfService = .userInitiated
        t.start()
    }

    struct BridgeError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    private func serviceLoop() {
        while true {
            cond.lock()
            while pending.isEmpty { cond.wait() }
            let job = pending.removeFirst()
            cond.unlock()
            job()
        }
    }

    private func submit(_ job: @escaping () -> Void) {
        cond.lock()
        pending.append(job)
        cond.signal()
        cond.unlock()
    }

    /// Idempotent; only ever called on the Python thread.
    private func ensureInitialized() throws {
        if didInit { return }
        if let e = initError { throw BridgeError(message: e) }

        guard let resourcePath = Bundle.main.resourcePath else {
            throw BridgeError(message: "no resourcePath")
        }
        var errPtr: UnsafeMutablePointer<CChar>?
        let rc = cpa_initialize(resourcePath, &errPtr)
        if rc != 0 {
            let msg = errPtr.map { String(cString: $0) } ?? "unknown"
            errPtr.map { free($0) }
            initError = "init failed (rc=\(rc)): \(msg)"
            throw BridgeError(message: initError!)
        }
        didInit = true
    }

    func call(_ function: String, argument: String? = nil) async throws -> [String: Any] {
        try await withCheckedThrowingContinuation { cont in
            submit {
                do {
                    try self.ensureInitialized()
                } catch {
                    cont.resume(throwing: error); return
                }
                guard let raw = cpa_call(function, argument) else {
                    cont.resume(throwing: BridgeError(message: "\(function) returned null"))
                    return
                }
                defer { free(raw) }
                let json = String(cString: raw)
                guard let data = json.data(using: .utf8),
                      let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else {
                    cont.resume(throwing: BridgeError(message: "bad JSON: \(json.prefix(200))"))
                    return
                }
                cont.resume(returning: obj)
            }
        }
    }

    func boot() async throws -> (wallSeconds: Double, payload: [String: Any]) {
        let t0 = CFAbsoluteTimeGetCurrent()
        let payload = try await call("boot")
        return (CFAbsoluteTimeGetCurrent() - t0, payload)
    }

    func resolve(_ url: String) async throws -> [String: Any] {
        try await call("resolve", argument: url)
    }
}
