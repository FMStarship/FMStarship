import CA64
import Foundation

/// Runs the game's own code on a copy-on-write view of its memory. Nothing it does reaches the game.
public final class Sandbox {
    public let game: GameProcess
    public private(set) var externalNames: [Int64: String] = [:]
    private var image: OpaquePointer!
    private var idle: [OpaquePointer] = []
    private let lock = NSLock()

    public static let defaultSteps: UInt64 = 20_000_000

    public init(game: GameProcess) throws {
        self.game = game
        let context = Unmanaged.passUnretained(game).toOpaque()
        image = a64_image_new({ context, page, out in
            let game = Unmanaged<GameProcess>.fromOpaque(context!).takeUnretainedValue()
            return game.read(Int64(truncatingIfNeeded: page), into: out!, count: Int(A64_PAGE)) ? 1 : 0
        }, context)
        externalNames = try GameImports.install(game: game, image: image)
    }

    deinit {
        for cpu in idle { a64_free(cpu) }
        a64_image_free(image)
    }

    public struct Failure: Error, CustomStringConvertible {
        public let status: Int, pc: Int64, instruction: UInt32, steps: UInt64, plugin: Int64, external: String
        public var description: String {
            let relative = pc >= plugin ? "+0x" + String(pc - plugin, radix: 16) : "0x" + String(pc, radix: 16)
            return "emulation stopped (status \(status)) at \(relative) on 0x\(String(instruction, radix: 16)) in \(external)"
        }
    }

    public var cachedPages: Int { a64_image_pages(image) }
    public func clearPages() { a64_image_clear_pages(image) }

    /// Calls a function. `prepare` may seed private memory; `stack` holds arguments past x7.
    public func call<T>(_ function: Int64, _ arguments: [UInt64], stack: [UInt64] = [], maxSteps: UInt64 = defaultSteps,
                        prepare: ((OpaquePointer) -> Void)? = nil, result: (OpaquePointer) -> T) throws -> T {
        lock.lock()
        let cpu = idle.popLast() ?? a64_new(image)!
        lock.unlock()
        a64_set_image_bounds(cpu, UInt64(game.pluginBase), UInt64(game.pluginBase + game.pluginSize))
        defer {
            lock.lock()
            idle.append(cpu)
            lock.unlock()
        }
        a64_reset(cpu)
        let sp = UInt64(A64_STACK_TOP) - 0x1000
        a64_set_x(cpu, 31, sp)
        a64_set_x(cpu, 30, UInt64(A64_RETURN_SENTINEL))
        for (i, value) in arguments.enumerated() { a64_set_x(cpu, Int32(i), value) }
        for (i, value) in stack.enumerated() { a64_write(cpu, sp + UInt64(i * 8), value, 8) }
        prepare?(cpu)
        let status = a64_run(cpu, UInt64(function), maxSteps)
        guard status == A64_OK else {
            throw Failure(status: Int(status.rawValue), pc: Int64(truncatingIfNeeded: a64_pc(cpu)), instruction: a64_last_instruction(cpu),
                          steps: a64_steps(cpu), plugin: game.pluginBase,
                          external: externalNames[Int64(truncatingIfNeeded: a64_external_miss(cpu))] ?? "game code")
        }
        return result(cpu)
    }
}
