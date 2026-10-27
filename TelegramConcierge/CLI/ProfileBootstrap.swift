import Foundation

/// Profile selection (MULTI_ASSISTANT_PLAN v5 §3.2). Runs first, from
/// `AdaCLI.main()`, before ArgumentParser and before any root, secrets,
/// preferences, migration or logging static is touched.
///
/// - A leading global `--profile <n>` / `--profile=<n>` (only as the FIRST
///   argument, before the subcommand; a later `--profile` belongs to the
///   subcommand), then `BRIGLIA_PROFILE`.
/// - argv wins over the environment; both present and different → exit 2.
/// - Unknown or invalid name → exit 2 listing the profiles; never a silent
///   fallback to default. `--profile default` equals no flag.
/// - The flag is removed from argv; for an extra `BRIGLIA_PROFILE` is set for
///   this process and every child (Bash, MCP, `__setsid-exec`, watcher
///   scripts). For default an absent variable stays absent, so default's
///   children see exactly today's environment.
enum ProfileBootstrap {
    struct Decision: Equatable {
        var profile: String
        var arguments: [String]
    }

    struct Failure: Error, Equatable {
        var message: String
    }

    /// Pure decision. `arguments` excludes argv[0]. `exists` answers whether
    /// an extra is present (raw resolution, injected for tests).
    static func decide(arguments: [String], environment: [String: String],
                       exists: (String) -> Bool, available: () -> [String]) -> Result<Decision, Failure> {
        var args = arguments
        var fromArgv: String?
        if let first = args.first {
            if first == "--profile" {
                guard args.count >= 2 else {
                    return .failure(Failure(message: "--profile needs a name: briglia --profile <name> <command>"))
                }
                fromArgv = args[1]
                args.removeFirst(2)
            } else if first.hasPrefix("--profile=") {
                fromArgv = String(first.dropFirst("--profile=".count))
                args.removeFirst()
            }
        }
        let rawEnv = environment[AssistantProfile.environmentKey]
        let fromEnv = (rawEnv?.isEmpty ?? true) ? nil : rawEnv
        if let a = fromArgv, let e = fromEnv, a != e {
            return .failure(Failure(message:
                "--profile \(a) conflicts with \(AssistantProfile.environmentKey)=\(e). Use one of them, or make them agree."))
        }
        let name = fromArgv ?? fromEnv ?? AssistantProfile.defaultName
        if name == AssistantProfile.defaultName {
            return .success(Decision(profile: AssistantProfile.defaultName, arguments: args))
        }
        guard AssistantProfile.isValidName(name), !AssistantProfile.reservedNames.contains(name) else {
            return .failure(Failure(message: unknownMessage(name, available: available(), invalid: true)))
        }
        guard environment[AssistantProfile.experimentalKey] == "1" else {
            return .failure(Failure(message:
                "Assistant profiles are not available in this version yet (profile ‘\(name)’ was requested)."))
        }
        guard exists(name) else {
            return .failure(Failure(message: unknownMessage(name, available: available(), invalid: false)))
        }
        if let refusal = refusalForExtra(arguments: args, name: name) {
            return .failure(Failure(message: refusal))
        }
        return .success(Decision(profile: name, arguments: args))
    }

    /// Commands that act on machine-level state or are not available for an
    /// extra assistant in this stage. Refused before anything runs.
    static func refusalForExtra(arguments: [String], name: String) -> String? {
        guard let command = arguments.first else { return nil }
        switch command {
        case "upgrade":
            return "Updates are installed for the whole computer from the default assistant: run `briglia upgrade` without --profile."
        case "toolchain":
            return "The phone toolchain belongs to the default assistant; run `briglia toolchain …` without --profile."
        case "migrate", "__migrate-run", "__migrate-probe", "__migrate-gate":
            return "Migrations run only for the default assistant; run the command without --profile."
        case "service":
            return "Background services for extra assistants are not available yet; run `briglia --profile \(name) daemon` in a terminal."
        case "upgradecheck":
            if arguments.count > 1, ["on", "off"].contains(arguments[1].lowercased()) {
                return "This is a computer-wide setting; change it in your default assistant (`briglia upgradecheck \(arguments[1].lowercased())` without --profile)."
            }
            return nil
        default:
            return nil
        }
    }

    static func unknownMessage(_ name: String, available: [String], invalid: Bool) -> String {
        let list = ([AssistantProfile.defaultName] + available).joined(separator: ", ")
        let what = invalid
            ? "‘\(name)’ is not a valid assistant profile name (lower-case letters, digits and -, up to 24)."
            : "There is no assistant profile ‘\(name)’."
        return what + " Profiles: \(list)."
    }

    /// Decide for the real process and apply the result, or exit 2 with the
    /// explanation on stderr. Returns argv without the global flag.
    static func run(_ argv: [String] = CommandLine.arguments) -> [String] {
        let env = ProcessInfo.processInfo.environment
        let decision = decide(arguments: Array(argv.dropFirst()), environment: env,
                              exists: { AssistantProfile.readMetadata($0, environment: env) != nil },
                              available: { AssistantProfile.listExtras(environment: env) })
        switch decision {
        case .failure(let failure):
            FileHandle.standardError.write(Data(("✖ " + failure.message + "\n").utf8))
            exit(2)
        case .success(let d):
            AssistantProfile.select(d.profile)
            if d.profile != AssistantProfile.defaultName {
                setenv(AssistantProfile.environmentKey, d.profile, 1)
            }
            return d.arguments
        }
    }
}
