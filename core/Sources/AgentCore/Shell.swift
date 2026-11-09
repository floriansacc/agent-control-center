import Foundation

enum Shell {
    struct Result {
        var ok: Bool
        var stdout: String
        var stderr: String
    }

    /// Runs a program and returns its stdout even when it exits non-zero
    /// (lsof exits 1 when some filters match nothing, yet its output is valid).
    static func output(_ path: String, _ args: [String], timeout: TimeInterval = 5) -> String {
        run(path, args, timeout: timeout).stdout
    }

    static func run(_ path: String, _ args: [String], timeout: TimeInterval = 5, environment: [String: String]? = nil) -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: path)
        process.arguments = args
        if let environment { process.environment = environment }
        let out = Pipe()
        let err = Pipe()
        process.standardOutput = out
        process.standardError = err
        process.standardInput = FileHandle.nullDevice
        // waitUntilExit() polls the run loop in ~50ms steps; a termination handler returns immediately.
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do {
            try process.run()
        } catch {
            return Result(ok: false, stdout: "", stderr: "\(error)")
        }
        let killer = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: killer)

        // Drain stderr concurrently so a chatty process cannot block on a full pipe.
        var errData = Data()
        let errDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            errData = err.fileHandleForReading.readDataToEndOfFile()
            errDone.signal()
        }
        let outData = out.fileHandleForReading.readDataToEndOfFile()
        errDone.wait()
        exited.wait()
        killer.cancel()
        return Result(
            ok: process.terminationStatus == 0,
            stdout: String(decoding: outData, as: UTF8.self),
            stderr: String(decoding: errData, as: UTF8.self)
        )
    }
}
