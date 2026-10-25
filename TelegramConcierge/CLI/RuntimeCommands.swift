import ArgumentParser
import Foundation
#if canImport(Glibc)
import Glibc
#else
import Darwin
#endif

/// Hidden: `briglia-python`'s target (security plan v24 §7.9.4). Runs ONLY
/// Briglia's validated private venv; never the shared python3 (R21-3).
struct PythonExecCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "__python-exec",
        abstract: "Internal: run Briglia's private Python environment (the briglia-python wrapper's target).",
        shouldDisplay: false
    )

    @Argument(parsing: .captureForPassthrough) var arguments: [String] = []

    func run() throws {
        switch PythonRuntime.execDecisionLeased() {
        case .refuse(let why):
            FileHandle.standardError.write(Data("\(why)\n".utf8))
            throw ExitCode(1)
        case .run(let python):
            let argv = [python] + arguments
            let cArgs = argv.map { strdup($0) } + [nil]
            execv(python, cArgs)
            FileHandle.standardError.write(Data("could not run Briglia's Python: \(String(cString: strerror(errno)))\n".utf8))
            throw ExitCode(126)
        }
    }
}

/// `briglia python-env status | install` — Briglia's private Python
/// environment (the packages the bundled skills use).
struct PythonEnvCommand: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "python-env",
        abstract: "Briglia's private Python environment for the document skills (status, install).",
        shouldDisplay: false
    )

    @Argument var action: String = "status"

    func run() async throws {
        AdaCLI.prepareIO()
        switch action {
        case "status":
            if let c = RuntimeStatus.python() { print("\(c.name): \(c.state.label) — \(c.detail)") }
            else { print("Python environment: not set up (run `briglia python-env install`)") }
        case "install":
            try IdentityMigration.gateMutatingEntry()
            let status = await PythonRuntime.converge(trigger: .install, progress: { print("  \($0)") })
            switch status {
            case .ready(let v): print("✔ Briglia's Python environment is ready (Python \(v))")
            case .notSetUp: print("✔ nothing to do")
            case .unavailable(let w), .failed(let w): print("✖ \(w)"); throw ExitCode(1)
            }
        default:
            print("usage: briglia python-env status | install"); throw ExitCode(64)
        }
    }
}
