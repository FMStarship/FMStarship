import CA64
import Foundation
import MachO

/// Maps game_plugin's imported functions to sandbox stubs, so emulated code calls no real system code.
enum GameImports {
    private static let stubs: [String: a64_stub] = [
        "_memcpy": A64_STUB_MEMCPY, "_memmove": A64_STUB_MEMCPY, "_memset": A64_STUB_MEMSET, "_bzero": A64_STUB_BZERO,
        "_memcmp": A64_STUB_MEMCMP, "_memchr": A64_STUB_MEMCHR, "_strlen": A64_STUB_STRLEN, "_strcmp": A64_STUB_STRCMP,
        "_strncmp": A64_STUB_STRNCMP, "_malloc": A64_STUB_MALLOC, "_calloc": A64_STUB_CALLOC, "_realloc": A64_STUB_REALLOC,
        "_free": A64_STUB_FREE, "__Znwm": A64_STUB_MALLOC, "__Znam": A64_STUB_MALLOC, "__ZnwmRKSt9nothrow_t": A64_STUB_MALLOC,
        "__ZdlPv": A64_STUB_FREE, "__ZdaPv": A64_STUB_FREE, "_posix_memalign": A64_STUB_POSIX_MEMALIGN,
        "_malloc_size": A64_STUB_MALLOC_SIZE,
        "___cxa_guard_acquire": A64_STUB_GUARD_ACQUIRE, "___cxa_guard_release": A64_STUB_GUARD_RELEASE,
        "___cxa_guard_abort": A64_STUB_RET0,
        "_pthread_mutex_lock": A64_STUB_RET0, "_pthread_mutex_unlock": A64_STUB_RET0, "_pthread_mutex_trylock": A64_STUB_RET0,
        "_pthread_rwlock_rdlock": A64_STUB_RET0, "_pthread_rwlock_wrlock": A64_STUB_RET0, "_pthread_rwlock_unlock": A64_STUB_RET0,
        "_pthread_cond_signal": A64_STUB_RET0, "_pthread_cond_broadcast": A64_STUB_RET0,
        "_pthread_once": A64_STUB_RET0, "_pthread_getspecific": A64_STUB_RET0, "_pthread_setspecific": A64_STUB_RET0,
        "_pthread_self": A64_STUB_RET1, "_os_unfair_lock_lock": A64_STUB_RET0, "_os_unfair_lock_unlock": A64_STUB_RET0,
        "___dynamic_cast": A64_STUB_DYNAMIC_CAST,
        "___stack_chk_fail": A64_STUB_ABORT, "_abort": A64_STUB_ABORT, "___cxa_throw": A64_STUB_ABORT,
        "___cxa_rethrow": A64_STUB_ABORT, "__Unwind_Resume": A64_STUB_ABORT, "___cxa_allocate_exception": A64_STUB_ABORT,
    ]

    /// libm functions run natively; the numbers index the tables in math_stubs.c.
    private static let mathStubs: [String: Int32] = [
        "_acos": 0,
        "_asin": 1,
        "_atan": 2,
        "_cos": 3,
        "_exp": 4,
        "_exp2": 5,
        "_log": 6,
        "_log10": 7,
        "_sin": 8,
        "_tan": 9,
        "_acosf": 256,
        "_asinf": 257,
        "_cosf": 258,
        "_expf": 259,
        "_logf": 260,
        "_sinf": 261,
        "_atan2": 512,
        "_pow": 513,
        "_fmod": 514,
        "_atan2f": 768,
        "_powf": 769,
        "_fmodf": 770,
    ]

    /// The dyld shared cache is mapped at one address per boot, so these match the game's.
    private static func abiVtable(_ name: String) -> UInt64 {
        guard let symbol = dlsym(UnsafeMutableRawPointer(bitPattern: -2), name) else { return 0 }
        return UInt64(UInt(bitPattern: symbol)) + 16
    }

    /// Reads the import table of the arm64 slice from disk and pairs it with the live __got slots.
    static func install(game: GameProcess, image: OpaquePointer) throws -> [Int64: String] {
        let file = try Data(contentsOf: URL(fileURLWithPath: game.pluginPath), options: .alwaysMapped)
        func u32be(_ o: Int) -> UInt32 { file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self).bigEndian } }
        func u32(_ o: Int) -> UInt32 { file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) } }
        func u64(_ o: Int) -> UInt64 { file.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) } }

        var slice = 0
        if u32be(0) == FAT_MAGIC {
            for i in 0..<Int(u32be(4)) where u32be(8 + i * 20) == UInt32(CPU_TYPE_ARM64) {
                slice = Int(u32be(8 + i * 20 + 8))
            }
        }
        var got: (address: Int, size: Int, fileOffset: Int)?
        var thread: (address: Int, size: Int)?
        var fixups = 0
        var command = slice + 32
        for _ in 0..<Int(u32(slice + 16)) {
            let cmd = u32(command), size = Int(u32(command + 4))
            if cmd == UInt32(LC_SEGMENT_64) {
                let sections = Int(u32(command + 64))
                for s in 0..<sections {
                    let at = command + 72 + s * 80
                    let name = file[(file.startIndex + at)..<(file.startIndex + at + 16)]
                    let text = String(decoding: name.prefix { $0 != 0 }, as: UTF8.self)
                    if text == "__got" { got = (Int(u64(at + 32)), Int(u64(at + 40)), Int(u32(at + 48))) }
                    if text == "__thread_vars" { thread = (Int(u64(at + 32)), Int(u64(at + 40))) }
                }
            } else if cmd == 0x8000_0034 {  // LC_DYLD_CHAINED_FIXUPS
                fixups = slice + Int(u32(command + 8))
            }
            command += size
        }
        guard let got, fixups != 0 else { throw ReadError.classesNotFound("imports") }

        let importsOffset = fixups + Int(u32(fixups + 8)), symbols = fixups + Int(u32(fixups + 12))
        let importCount = Int(u32(fixups + 16)), format = u32(fixups + 20)
        let stride = format == 1 ? 4 : format == 2 ? 8 : 16
        func importName(_ ordinal: Int) -> String? {
            guard ordinal < importCount else { return nil }
            let entry = u32(importsOffset + ordinal * stride)
            let offset = symbols + Int(entry >> 9)
            return file.withUnsafeBytes { String(cString: $0.baseAddress!.advanced(by: offset).assumingMemoryBound(to: CChar.self)) }
        }

        a64_image_set_rtti(image, abiVtable("_ZTVN10__cxxabiv117__class_type_infoE"),
                           abiVtable("_ZTVN10__cxxabiv120__si_class_type_infoE"),
                           abiVtable("_ZTVN10__cxxabiv121__vmi_class_type_infoE"))

        var names: [Int64: String] = [:]
        for slot in Swift.stride(from: 0, to: got.size, by: 8) {
            let raw = u64(slice + got.fileOffset + slot)
            guard raw >> 63 == 1, let name = importName(Int(raw & 0xff_ffff)) else { continue }
            let live = game.readPointer(game.pluginBase + Int64(got.address + slot))
            guard live != 0 else { continue }
            names[live] = name
            if let stub = stubs[name] { a64_image_add_stub(image, UInt64(live), stub) }
            if let math = mathStubs[name] { a64_image_add_math_stub(image, UInt64(live), math) }
        }
        if let thread {
            // Every thread-local access goes through the thunk stored at the start of each descriptor.
            for slot in Swift.stride(from: 0, to: thread.size, by: 24) {
                let thunk = game.readPointer(game.pluginBase + Int64(thread.address + slot))
                if thunk != 0 { a64_image_add_stub(image, UInt64(thunk), A64_STUB_TLV) }
            }
        }
        return names
    }
}
