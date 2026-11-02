import Foundation

/// Starts Football Manager with FM Starship's agent loaded. macOS will not let an outside app read a
/// hardened game, but FM27 opts in to environment-injected libraries, so the agent needs no game file
/// changed and only applies to the launch made here.
public enum GameLauncher {
    public enum State: Equatable {
        case notInstalled
        case notRunning
        case runningWithoutAgent
        case ready
    }

    public enum LaunchError: Error, CustomStringConvertible {
        case gameNotFound, agentMissing, agentNotCopied(String), alreadyRunning, failed(Int32)
        public var description: String {
            switch self {
            case .gameNotFound: return "Football Manager 27 wasn't found in your Steam library."
            case .agentMissing: return "FM Starship's agent is missing from the app. Reinstall FM Starship."
            case .agentNotCopied(let reason): return "FM Starship couldn't copy its agent to Application Support: \(reason)"
            case .alreadyRunning: return "Football Manager is already running. Save, quit it, then start it from FM Starship."
            case .failed(let code): return "macOS couldn't start Football Manager (error \(code))."
            }
        }
    }

    public static let steamAppID = "4530370"
    private static let installFolder = "Football Manager 27"

    /// Every Steam library the user has, the main one first.
    private static func steamLibraries() -> [URL] {
        let steam = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Steam")
        var libraries = [steam]
        if let text = try? String(contentsOf: steam.appendingPathComponent("steamapps/libraryfolders.vdf"), encoding: .utf8),
           let pattern = try? NSRegularExpression(pattern: #""path"\s+"([^"]+)""#) {
            let range = NSRange(text.startIndex..., in: text)
            for match in pattern.matches(in: text, range: range) {
                if let path = Range(match.range(at: 1), in: text) {
                    libraries.append(URL(fileURLWithPath: String(text[path])))
                }
            }
        }
        return libraries
    }

    public static var gameApp: URL? {
        for library in steamLibraries() {
            let app = library.appendingPathComponent("steamapps/common/\(installFolder)/fm.app")
            if FileManager.default.fileExists(atPath: app.path) { return app }
        }
        return nil
    }

    public static var state: State {
        guard gameApp != nil else { return .notInstalled }
        guard let pid = GameProcess.runningPID() else { return .notRunning }
        return FileManager.default.fileExists(atPath: AgentConnection.socketPath(pid: pid)) ? .ready : .runningWithoutAgent
    }

    /// FM holds on to the agent for as long as it runs, so it loads a copy outside the app, where replacing the app
    /// can't reach it. Written rather than copied, because a copy would keep the download's quarantine flag.
    static func placeAgent(_ agent: URL, in folder: URL) throws -> URL {
        let placed = folder.appendingPathComponent(agent.lastPathComponent)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data(contentsOf: agent).write(to: placed, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: placed.path)
        return placed
    }

    /// Never touches a game that is already running: that would risk an unsaved career.
    public static func launch(agent: URL) throws {
        guard let app = gameApp else { throw LaunchError.gameNotFound }
        guard FileManager.default.fileExists(atPath: agent.path) else { throw LaunchError.agentMissing }
        guard GameProcess.runningPID() == nil else { throw LaunchError.alreadyRunning }
        let placed: URL
        do {
            let support = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
            placed = try placeAgent(agent, in: support.appendingPathComponent("FMStarship", isDirectory: true))
        } catch {
            throw LaunchError.agentNotCopied(error.localizedDescription)
        }
        let open = Process()
        open.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        open.arguments = [
            "--env", "\(GameProcess.agentLibraryEnv)=\(placed.path)",
            // With these set, the Steam API does not restart the game through Steam, which would lose the agent.
            "--env", "SteamAppId=\(steamAppID)",
            "--env", "SteamGameId=\(steamAppID)",
            app.path,
        ]
        try open.run()
        open.waitUntilExit()
        guard open.terminationStatus == 0 else { throw LaunchError.failed(open.terminationStatus) }
    }
}
