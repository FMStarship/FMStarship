import Darwin
import Foundation

/// FM's C# side, through the IL2CPP API that GameAssembly exports. Everything here runs on the main thread, where Unity
/// runs FM's scripts. Nothing in FM's code is changed: these are the calls IL2CPP offers anything that hosts it.
@MainActor
final class IL2CPP {
    typealias Pointer = UnsafeMutableRawPointer
    /// A GC handle, which keeps an object alive while only Swift points at it.
    typealias Handle = UnsafeMutableRawPointer

    struct Failure: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }

    /// Nil outside FM, until FM has started IL2CPP's runtime, or if this build of IL2CPP is missing a function we use.
    /// Only success is kept: until then each use tries again, so a look before FM is ready doesn't leave FM Starship
    /// off until FM starts again.
    static var shared: IL2CPP? {
        guard !stopped else { return nil }
        if let attached { return attached }
        do {
            attached = try IL2CPP()
            if !lastFailure.isEmpty { PluginLog.write("IL2CPP: ready now") }
            lastFailure = ""
        } catch {
            if "\(error)" != lastFailure { PluginLog.write("IL2CPP: \(error)") }
            lastFailure = "\(error)"
        }
        return attached
    }

    private static var attached: IL2CPP?
    /// Why it last couldn't attach, logged once rather than on every try.
    private static var lastFailure = ""
    /// Set as FM quits, when Unity may shut the runtime down before anything of ours runs again.
    private(set) static var stopped = false

    /// Nothing calls into FM's runtime after this: `shared` is nil from now on.
    static func stop() { stopped = true }

    private typealias P = UnsafeMutableRawPointer?
    private typealias Text = UnsafePointer<CChar>?

    private struct API {
        let corlib: @convention(c) () -> P
        let domainGet: @convention(c) () -> P
        let domainAssemblies: @convention(c) (P, UnsafeMutablePointer<Int>) -> UnsafeMutablePointer<P>?
        let threadAttach: @convention(c) (P) -> P
        let assemblyImage: @convention(c) (P) -> P
        let imageName: @convention(c) (P) -> Text
        let imageClassCount: @convention(c) (P) -> Int
        let imageClass: @convention(c) (P, Int) -> P
        let classFromName: @convention(c) (P, UnsafePointer<CChar>, UnsafePointer<CChar>) -> P
        let classMethods: @convention(c) (P, UnsafeMutablePointer<P>) -> P
        let classFields: @convention(c) (P, UnsafeMutablePointer<P>) -> P
        let classField: @convention(c) (P, UnsafePointer<CChar>) -> P
        let className: @convention(c) (P) -> Text
        let classNamespace: @convention(c) (P) -> Text
        let classParent: @convention(c) (P) -> P
        let classType: @convention(c) (P) -> P
        let classFromType: @convention(c) (P) -> P
        let classIsValueType: @convention(c) (P) -> Bool
        let classElement: @convention(c) (P) -> P
        let classIsEnum: @convention(c) (P) -> Bool
        let classIsInited: @convention(c) (P) -> Bool
        let classIsGeneric: @convention(c) (P) -> Bool
        let classIsSubclass: @convention(c) (P, P, Bool) -> Bool
        let classValueSize: @convention(c) (P, UnsafeMutablePointer<UInt32>?) -> Int32
        let methodName: @convention(c) (P) -> Text
        let methodClass: @convention(c) (P) -> P
        let methodParamCount: @convention(c) (P) -> UInt32
        let methodParam: @convention(c) (P, UInt32) -> P
        let methodParamName: @convention(c) (P, UInt32) -> Text
        let methodReturnType: @convention(c) (P) -> P
        let methodFlags: @convention(c) (P, UnsafeMutablePointer<UInt32>?) -> UInt32
        let methodIsGeneric: @convention(c) (P) -> Bool
        let typeName: @convention(c) (P) -> UnsafeMutablePointer<CChar>?
        let typeKind: @convention(c) (P) -> Int32
        let typeObject: @convention(c) (P) -> P
        let fieldName: @convention(c) (P) -> Text
        let fieldType: @convention(c) (P) -> P
        let fieldOffset: @convention(c) (P) -> Int
        let fieldFlags: @convention(c) (P) -> Int32
        let fieldStaticValue: @convention(c) (P, Pointer) -> Void
        let fieldSetValue: @convention(c) (P, P, P) -> Void
        let setFieldWithBarrier: @convention(c) (P, P, P) -> Void
        let free: @convention(c) (P) -> Void
        let runtimeInvoke: @convention(c) (P, P, UnsafeMutablePointer<P>?, UnsafeMutablePointer<P>?) -> P
        let formatException: @convention(c) (P, UnsafeMutablePointer<CChar>, Int32) -> Void
        let objectNew: @convention(c) (P) -> P
        let objectClass: @convention(c) (P) -> P
        let objectUnbox: @convention(c) (P) -> P
        let objectVirtualMethod: @convention(c) (P, P) -> P
        let stringNew: @convention(c) (UnsafePointer<CChar>) -> P
        let stringChars: @convention(c) (P) -> UnsafeMutablePointer<UInt16>?
        let stringLength: @convention(c) (P) -> Int32
        let arrayLength: @convention(c) (P) -> UInt32
        let arrayLengthOffset: @convention(c) () -> Int32
        // Il2CppGCHandle is pointer-sized in this IL2CPP, not the 32-bit number older ones used.
        let gchandleNew: @convention(c) (P, Bool) -> P
        let gchandleFree: @convention(c) (P) -> Void
        let gchandleTarget: @convention(c) (P) -> P
        let gcDisable: @convention(c) () -> Void
        let gcEnable: @convention(c) () -> Void
    }

    private let api: API
    private lazy var images: [Pointer] = loadImages()
    private var methodCache: [String: Pointer] = [:]
    private var nativeMethods: [Pointer: Pointer] = [:]

    private init() throws {
        // Unity loads GameAssembly on its own, so its functions aren't in the global namespace: ask the library itself.
        let path = (0..<_dyld_image_count()).lazy.compactMap { _dyld_get_image_name($0).map { String(cString: $0) } }
            .first { $0.hasSuffix("GameAssembly.dylib") }
        guard let path else { throw Failure("GameAssembly isn't loaded") }
        // RTLD_NOLOAD still counts a reference to the library. Each try that fails gives it back, so the tries made
        // until FM is ready don't pile up references; the one that works keeps it, for the functions it holds.
        let opened = dlopen(path, RTLD_LAZY | RTLD_NOLOAD)
        var kept = false
        defer { if !kept, let opened { dlclose(opened) } }
        guard let library = opened ?? UnsafeMutableRawPointer(bitPattern: -2) else {
            throw Failure("No handle for \(path)")
        }
        func load<T>(_ name: String) throws -> T {
            guard let address = dlsym(library, name) else {
                throw Failure("\(name) is missing from \(path): \(dlerror().map { String(cString: $0) } ?? "")")
            }
            return unsafeBitCast(address, to: T.self)
        }
        api = API(
            corlib: try load("il2cpp_get_corlib"),
            domainGet: try load("il2cpp_domain_get"),
            domainAssemblies: try load("il2cpp_domain_get_assemblies"),
            threadAttach: try load("il2cpp_thread_attach"),
            assemblyImage: try load("il2cpp_assembly_get_image"),
            imageName: try load("il2cpp_image_get_name"),
            imageClassCount: try load("il2cpp_image_get_class_count"),
            imageClass: try load("il2cpp_image_get_class"),
            classFromName: try load("il2cpp_class_from_name"),
            classMethods: try load("il2cpp_class_get_methods"),
            classFields: try load("il2cpp_class_get_fields"),
            classField: try load("il2cpp_class_get_field_from_name"),
            className: try load("il2cpp_class_get_name"),
            classNamespace: try load("il2cpp_class_get_namespace"),
            classParent: try load("il2cpp_class_get_parent"),
            classType: try load("il2cpp_class_get_type"),
            classFromType: try load("il2cpp_class_from_type"),
            classIsValueType: try load("il2cpp_class_is_valuetype"),
            classElement: try load("il2cpp_class_get_element_class"),
            classIsEnum: try load("il2cpp_class_is_enum"),
            classIsInited: try load("il2cpp_class_is_inited"),
            classIsGeneric: try load("il2cpp_class_is_generic"),
            classIsSubclass: try load("il2cpp_class_is_subclass_of"),
            classValueSize: try load("il2cpp_class_value_size"),
            methodName: try load("il2cpp_method_get_name"),
            methodClass: try load("il2cpp_method_get_class"),
            methodParamCount: try load("il2cpp_method_get_param_count"),
            methodParam: try load("il2cpp_method_get_param"),
            methodParamName: try load("il2cpp_method_get_param_name"),
            methodReturnType: try load("il2cpp_method_get_return_type"),
            methodFlags: try load("il2cpp_method_get_flags"),
            methodIsGeneric: try load("il2cpp_method_is_generic"),
            typeName: try load("il2cpp_type_get_name"),
            typeKind: try load("il2cpp_type_get_type"),
            typeObject: try load("il2cpp_type_get_object"),
            fieldName: try load("il2cpp_field_get_name"),
            fieldType: try load("il2cpp_field_get_type"),
            fieldOffset: try load("il2cpp_field_get_offset"),
            fieldFlags: try load("il2cpp_field_get_flags"),
            fieldStaticValue: try load("il2cpp_field_static_get_value"),
            fieldSetValue: try load("il2cpp_field_set_value"),
            setFieldWithBarrier: try load("il2cpp_gc_wbarrier_set_field"),
            free: try load("il2cpp_free"),
            runtimeInvoke: try load("il2cpp_runtime_invoke"),
            formatException: try load("il2cpp_format_exception"),
            objectNew: try load("il2cpp_object_new"),
            objectClass: try load("il2cpp_object_get_class"),
            objectUnbox: try load("il2cpp_object_unbox"),
            objectVirtualMethod: try load("il2cpp_object_get_virtual_method"),
            stringNew: try load("il2cpp_string_new"),
            stringChars: try load("il2cpp_string_chars"),
            stringLength: try load("il2cpp_string_length"),
            arrayLength: try load("il2cpp_array_length"),
            arrayLengthOffset: try load("il2cpp_offset_of_array_length_in_array_object_header"),
            gchandleNew: try load("il2cpp_gchandle_new"),
            gchandleFree: try load("il2cpp_gchandle_free"),
            gchandleTarget: try load("il2cpp_gchandle_get_target"),
            gcDisable: try load("il2cpp_gc_disable"),
            gcEnable: try load("il2cpp_gc_enable"))
        // FM loads GameAssembly before it starts IL2CPP's runtime, and nothing may be asked of the runtime before then.
        // corlib is set once it has started, and reading it does nothing else. Then the domain has to be there, with
        // FM's interface classes loaded, before this thread is attached.
        guard api.corlib() != nil else { throw Failure("IL2CPP hasn't started yet") }
        guard let domain = api.domainGet() else { throw Failure("IL2CPP has no domain yet") }
        guard findClass("UnityEngine.UIElements", "VisualElement") != nil else { throw Failure("UI Toolkit isn't loaded yet") }
        // Unity's main thread is attached already, so this only hands back its thread.
        _ = api.threadAttach(domain)
        kept = true
    }

    /// GameAssembly's Mach-O UUID, which is new each time FM's game code is built. Nil while it isn't loaded.
    nonisolated static func gameAssemblyUUID() -> String? {
        guard let index = (0..<_dyld_image_count()).first(where: {
            _dyld_get_image_name($0).map { String(cString: $0).hasSuffix("GameAssembly.dylib") } ?? false
        }), let header = _dyld_get_image_header(index) else { return nil }
        return uuid(ofMachO: UnsafeRawPointer(header))
    }

    /// The UUID in a 64-bit Mach-O header's load commands. Nil if it has none, or isn't one.
    nonisolated static func uuid(ofMachO header: UnsafeRawPointer) -> String? {
        let mach = header.loadUnaligned(as: mach_header_64.self)
        guard mach.magic == MH_MAGIC_64 else { return nil }
        let end = MemoryLayout<mach_header_64>.size + Int(mach.sizeofcmds)
        var offset = MemoryLayout<mach_header_64>.size
        for _ in 0..<mach.ncmds {
            guard offset + MemoryLayout<load_command>.size <= end else { return nil }
            let command = header.loadUnaligned(fromByteOffset: offset, as: load_command.self)
            guard command.cmdsize >= UInt32(MemoryLayout<load_command>.size), offset + Int(command.cmdsize) <= end else { return nil }
            if command.cmd == UInt32(LC_UUID), Int(command.cmdsize) >= MemoryLayout<uuid_command>.size {
                return UUID(uuid: header.loadUnaligned(fromByteOffset: offset, as: uuid_command.self).uuid).uuidString
            }
            offset += Int(command.cmdsize)
        }
        return nil
    }

    // MARK: Classes

    private func loadImages() -> [Pointer] {
        var count = 0
        guard let assemblies = api.domainAssemblies(api.domainGet(), &count) else { return [] }
        return (0..<count).compactMap { api.assemblyImage(assemblies[$0]) }
    }

    private func string(_ text: Text) -> String { text.map { String(cString: $0) } ?? "" }

    func findClass(_ namespace: String, _ name: String) -> Pointer? {
        for image in images {
            let found = namespace.withCString { ns in name.withCString { api.classFromName(image, ns, $0) } }
            if let found { return found }
        }
        return nil
    }

    var imageNames: [String] { images.map { string(api.imageName($0)) } }

    /// Each method of the class with where its code is in its image, as an offset from the image's start, to read
    /// alongside a disassembly of FM's GameAssembly, which has no names of its own.
    func codeOffsets(_ klass: Pointer) -> [(name: String, offset: Int)] {
        var found: [(name: String, offset: Int)] = []
        var iterator: P = nil
        while let m = api.classMethods(klass, &iterator) {
            guard let code = UnsafeRawPointer(m).load(as: UnsafeRawPointer?.self) else { continue }
            var info = Dl_info()
            guard dladdr(code, &info) != 0, let base = info.dli_fbase else { continue }
            let parameters = (0..<api.methodParamCount(m)).map { typeName(api.methodParam(m, $0)) }
            found.append(("\(string(api.methodName(m)))(\(parameters.joined(separator: ", ")))", UnsafeRawPointer(base).distance(to: code)))
        }
        return found
    }

    /// Every class in one assembly, such as "FM.UI.dll".
    func classes(inImage imageName: String) -> [Pointer] {
        guard let image = images.first(where: { string(api.imageName($0)) == imageName }) else { return [] }
        return (0..<api.imageClassCount(image)).compactMap { api.imageClass(image, $0) }
    }

    func name(of klass: Pointer?) -> String {
        guard let klass else { return "null" }
        let namespace = string(api.classNamespace(klass)), name = string(api.className(klass))
        return namespace.isEmpty ? name : "\(namespace).\(name)"
    }

    func classOf(_ object: Pointer?) -> Pointer? { object.flatMap { api.objectClass($0) } }

    func isSubclass(_ klass: Pointer?, of parent: Pointer?) -> Bool {
        guard let klass, let parent else { return false }
        return klass == parent || api.classIsSubclass(klass, parent, false)
    }

    func systemType(_ klass: Pointer) -> Pointer? { api.typeObject(api.classType(klass)) }

    /// Open generic classes, which have no statics or objects of their own.
    func isGeneric(_ klass: Pointer) -> Bool { api.classIsGeneric(klass) }

    /// Runs work with FM's garbage collector paused. Objects we make are held only by us between calls, where the
    /// collector can't see them, so it mustn't run until they're in FM's own structures.
    func withoutCollection<T>(_ body: () throws -> T) rethrows -> T {
        api.gcDisable()
        defer { api.gcEnable() }
        return try body()
    }

    func typeName(_ type: Pointer?) -> String {
        guard let type, let text = api.typeName(type) else { return "?" }
        defer { api.free(text) }
        return String(cString: text)
    }

    /// The size of a struct without the object header, to check a layout before building one by hand.
    func valueSize(_ type: Pointer?) -> Int {
        guard let klass = api.classFromType(type) else { return -1 }
        return Int(api.classValueSize(klass, nil))
    }

    // MARK: Methods

    /// A method by name and parameter count, in the class or a parent. Generic definitions are skipped, since they
    /// can't be called as they are, and `firstParameter` or `parameterTypes` tell overloads apart.
    func method(_ klass: Pointer?, _ name: String, parameters: Int, firstParameter: String? = nil,
                parameterTypes: [String]? = nil, inherited: Bool = true) -> Pointer? {
        let key = "\(Int(bitPattern: klass)) \(name) \(parameters) \(firstParameter ?? "") \(parameterTypes ?? []) \(inherited)"
        if let cached = methodCache[key] { return cached }
        var current = klass
        while let k = current {
            var iterator: P = nil
            while let m = api.classMethods(k, &iterator) {
                guard string(api.methodName(m)) == name, Int(api.methodParamCount(m)) == parameters, !api.methodIsGeneric(m) else { continue }
                if let firstParameter, typeName(api.methodParam(m, 0)) != firstParameter { continue }
                if let parameterTypes, parameterTypes.indices.contains(where: { typeName(api.methodParam(m, UInt32($0))) != parameterTypes[$0] }) {
                    continue
                }
                methodCache[key] = m
                return m
            }
            current = inherited ? api.classParent(k) : nil
        }
        return nil
    }

    func methodParameter(_ method: Pointer, _ index: Int) -> Pointer? { api.methodParam(method, UInt32(index)) }
    func returnType(_ method: Pointer) -> Pointer? { api.methodReturnType(method) }

    /// The class of a type, such as a parameter's. This is how a generic class FM uses, like its List<TypedValue>,
    /// is found: there's no name to look it up by.
    func klass(of type: Pointer?) -> Pointer? { type.flatMap { api.classFromType($0) } }

    /// Calls a method, through the object's own override when it's virtual. Value-type arguments are passed as
    /// pointers to the value; reference types as the object. FM's exceptions come back as errors, not crashes.
    @discardableResult
    func call(_ method: Pointer?, _ object: Pointer?, _ arguments: [Pointer?] = []) throws -> Pointer? {
        guard let method else { throw Failure("Method not found") }
        var target = method
        let flags = api.methodFlags(method, nil)
        if let object, flags & 0x40 != 0, let override = api.objectVirtualMethod(object, method) {
            target = override
        } else if flags & 0x400 != 0 {
            // An abstract or interface method has no code of its own to run.
            throw Failure("No implementation of \(string(api.methodName(method))) for \(name(of: classOf(object)))")
        }
        var exception: P = nil
        var arguments = arguments
        let result = arguments.withUnsafeMutableBufferPointer { api.runtimeInvoke(target, object, $0.baseAddress, &exception) }
        if let exception {
            var buffer = [CChar](repeating: 0, count: 4096)
            api.formatException(exception, &buffer, Int32(buffer.count))
            throw Failure("\(string(api.methodName(method))): \(String(cString: buffer))")
        }
        return result
    }

    /// Calls a method found by name on the object's class.
    @discardableResult
    func call(_ object: Pointer, _ name: String, _ arguments: [Pointer?] = []) throws -> Pointer? {
        guard let method = method(classOf(object), name, parameters: arguments.count) else {
            throw Failure("\(self.name(of: classOf(object))).\(name) not found")
        }
        return try call(method, object, arguments)
    }

    /// A new object through one of its constructors.
    func new(_ klass: Pointer, _ arguments: [Pointer?] = [], firstParameter: String? = nil) throws -> Pointer {
        guard let object = api.objectNew(klass) else { throw Failure("Couldn't allocate \(name(of: klass))") }
        guard let constructor = method(klass, ".ctor", parameters: arguments.count, firstParameter: firstParameter, inherited: false) else {
            throw Failure("\(name(of: klass)) has no constructor for \(arguments.count) arguments")
        }
        try call(constructor, object, arguments)
        return object
    }

    // MARK: Values

    func unbox<T>(_ boxed: Pointer?, as: T.Type) -> T? {
        guard let boxed, let value = api.objectUnbox(boxed) else { return nil }
        return value.load(as: T.self)
    }

    func managedString(_ text: String) -> Pointer? { text.withCString { api.stringNew($0) } }

    /// A string's text. Nil for any object that isn't a System.String, whose memory isn't a string's.
    func text(_ string: Pointer?) -> String? {
        guard let string, let stringClass, api.objectClass(string) == stringClass, let chars = api.stringChars(string) else { return nil }
        return String(utf16CodeUnits: chars, count: Int(api.stringLength(string)))
    }

    private lazy var stringClass: Pointer? = findClass("System", "String")

    /// The references in an array of them. Empty for an array of structs or numbers, whose items aren't objects.
    func elements(_ array: Pointer?) -> [Pointer?] {
        guard let array, !holdsValues(array) else { return [] }
        let start = Int(api.arrayLengthOffset()) + 8
        return (0..<Int(api.arrayLength(array))).map { array.load(fromByteOffset: start + $0 * 8, as: Pointer?.self) }
    }

    /// The objects in an array of references or a List<T> of them. Empty for anything else, and for structs.
    func items(of collection: Pointer) -> [Pointer] {
        let className = name(of: classOf(collection))
        if className.hasSuffix("[]") { return elements(collection).compactMap { $0 } }
        guard className.hasPrefix("System.Collections.Generic.List`1"), let contents = listContents(collection) else { return [] }
        return elements(contents.array).prefix(contents.count).compactMap { $0 }
    }

    /// A List<T>'s array and how many of its items are in use. Nil for anything not laid out like one.
    private func listContents(_ list: Pointer) -> (array: Pointer, count: Int)? {
        // The array is a T[], and the count an Int32.
        guard let items = referenceField(classOf(list), "_items"), api.typeKind(api.fieldType(items)) == 0x1d,
              let array = (list + api.fieldOffset(items)).load(as: P.self), let size = value(list, "_size", as: Int32.self) else { return nil }
        return (array, max(0, min(Int(size), Int(api.arrayLength(array)))))
    }

    /// Where each item of a List<T> of structs sits in the list's array, `size` bytes apart, to read in place. Empty
    /// unless the array holds structs of exactly that size.
    func structItems(of list: Pointer, size: Int) -> [UnsafeRawPointer] {
        guard let contents = listContents(list), let element = api.classElement(classOf(contents.array)), api.classIsValueType(element),
              Int(api.classValueSize(element, nil)) == size else { return [] }
        let start = Int(api.arrayLengthOffset()) + 8
        return (0..<contents.count).map { UnsafeRawPointer(contents.array + start + $0 * size) }
    }

    /// Where, in each struct a List<T> holds, the first field holding an object of `klass` or a subclass sits: found by
    /// the field's type, not taken on trust.
    func offset(of klass: Pointer, inStructsOf list: Pointer) -> Int? {
        guard let contents = listContents(list), let element = api.classElement(classOf(contents.array)),
              api.classIsValueType(element) else { return nil }
        var iterator: P = nil
        while let f = api.classFields(element, &iterator) {
            guard holdsReference(f), isSubclass(api.classFromType(api.fieldType(f)), of: klass) else { continue }
            // A struct's field offsets count the object header it has when boxed.
            return api.fieldOffset(f) - 16
        }
        return nil
    }

    /// The strings in a List<string>. Empty if it holds anything else.
    func strings(inList list: Pointer?) -> [String] {
        guard let list, let contents = listContents(list), let stringClass,
              api.classElement(classOf(contents.array)) == stringClass else { return [] }
        return elements(contents.array).prefix(contents.count).compactMap { text($0) }
    }

    /// Where a field is in an object of the class, or in the struct itself for a value type.
    func fieldOffset(_ klass: Pointer?, _ name: String, inStruct: Bool = false) -> Int? {
        guard let found = field(klass, name) else { return nil }
        return api.fieldOffset(found) - (inStruct ? 16 : 0)
    }

    /// A constant's value, such as FM's property IDs, which IL2CPP keeps in its metadata. Nil unless it's a number or
    /// struct of exactly T's size, since IL2CPP copies the whole of it.
    func constant<T>(_ klass: Pointer?, _ name: String, as: T.Type) -> T? {
        guard let found = field(klass, name), api.fieldFlags(found) & 0x10 != 0, let fieldClass = api.classFromType(api.fieldType(found)),
              api.classIsValueType(fieldClass), Int(api.classValueSize(fieldClass, nil)) == MemoryLayout<T>.size else { return nil }
        let size = max(8, MemoryLayout<T>.size)
        let buffer = UnsafeMutableRawPointer.allocate(byteCount: size, alignment: 8)
        defer { buffer.deallocate() }
        buffer.initializeMemory(as: UInt8.self, repeating: 0, count: size)
        api.fieldStaticValue(found, buffer)
        return buffer.load(as: T.self)
    }

    /// Sets a field through IL2CPP, which tells FM's garbage collector about a reference written into an object.
    /// `value` is the field's value itself: a pointer for a reference, the struct or number otherwise, of the field's
    /// own size. Anything else is refused, since a store of the wrong kind or size would corrupt the object.
    func setField<T>(_ object: Pointer, _ name: String, _ value: T) throws {
        let klass = classOf(object)
        let isPointer = T.self == P.self || T.self == Pointer.self
        guard let found = isPointer ? referenceField(klass, name) : valueField(klass, name, size: MemoryLayout<T>.size) else {
            throw Failure("\(self.name(of: klass)).\(name) can't take a \(T.self)")
        }
        var copy = value
        withUnsafeMutablePointer(to: &copy) { store(object, found, from: Pointer($0)) }
    }

    /// Puts the value at `value` in one of an object's fields. IL2CPP's own setter wants the address of a reference,
    /// except for a generic class's, such as a List<T>, where it stores the address it's given in place of the
    /// object. So references are stored here instead, through the garbage collector's write barrier.
    private func store(_ object: Pointer, _ field: P, from value: Pointer) {
        if let fieldClass = api.classFromType(api.fieldType(field)), !api.classIsValueType(fieldClass) {
            api.setFieldWithBarrier(object, object + api.fieldOffset(field), value.load(as: P.self))
        } else {
            api.fieldSetValue(object, field, value)
        }
    }

    /// Copies every instance field of `source` into `target`, an object of the same class, field by field through
    /// IL2CPP, so FM's garbage collector sees the references the copy now holds.
    func copyFields(from source: Pointer, to target: Pointer) {
        var klass = classOf(source)
        while let k = klass, name(of: k) != "System.Object" {
            var iterator: P = nil
            while let f = api.classFields(k, &iterator) {
                guard api.fieldFlags(f) & 0x10 == 0 else { continue }
                store(target, f, from: source + api.fieldOffset(f))
            }
            klass = api.classParent(k)
        }
    }

    /// What a reference field of the object holds, by the field's name in its class or a parent. Nil if the field holds
    /// a struct or a number, which isn't an object to hand to FM's runtime.
    func fieldObject(_ object: Pointer, _ name: String) -> Pointer? {
        guard let found = referenceField(classOf(object), name) else { return nil }
        return (object + api.fieldOffset(found)).load(as: P.self)
    }

    /// A number or struct in one of the object's fields, read in place. Nil unless the field holds one of exactly T's size.
    func value<T>(_ object: Pointer, _ name: String, as: T.Type) -> T? {
        guard let found = valueField(classOf(object), name, size: MemoryLayout<T>.size) else { return nil }
        return (object + api.fieldOffset(found)).load(as: T.self)
    }

    /// An instance field that holds a reference to an object, by its name in the class or a parent.
    func referenceField(_ klass: Pointer?, _ name: String) -> Pointer? {
        field(klass, name).flatMap { holdsReference($0) ? $0 : nil }
    }

    /// An instance field that holds a number or struct of `size` bytes, by its name in the class or a parent.
    func valueField(_ klass: Pointer?, _ name: String, size: Int) -> Pointer? {
        guard let found = field(klass, name), api.fieldFlags(found) & 0x10 == 0, let fieldClass = api.classFromType(api.fieldType(found)),
              api.classIsValueType(fieldClass), Int(api.classValueSize(fieldClass, nil)) == size else { return nil }
        return found
    }

    /// Whether an instance field holds a reference: a string, an object, an array or a generic class, not a struct.
    private func holdsReference(_ field: Pointer) -> Bool {
        guard api.fieldFlags(field) & 0x10 == 0, let type = api.fieldType(field), [0x0e, 0x12, 0x14, 0x15, 0x1c, 0x1d].contains(api.typeKind(type)),
              let fieldClass = api.classFromType(type) else { return false }
        return !api.classIsValueType(fieldClass)
    }

    func field(_ klass: Pointer?, _ name: String) -> Pointer? {
        var current = klass
        while let k = current {
            if let found = name.withCString({ api.classField(k, $0) }) { return found }
            current = api.classParent(k)
        }
        return nil
    }

    /// Keeps an object alive while only we point at it.
    func pin(_ object: Pointer) -> Handle? { api.gchandleNew(object, false) }
    func unpin(_ handle: Handle) { api.gchandleFree(handle) }
    func target(of handle: Handle) -> Pointer? { api.gchandleTarget(handle) }

    // MARK: Delegates

    /// A delegate of FM's type, such as System.Action, that calls a function of ours with `target` as its first
    /// argument. IL2CPP's own delegate constructor takes a MethodInfo: ours is a copy of a real one with the same shape
    /// (an instance method with no parameters that returns nothing), pointing at our function instead.
    func delegate(_ delegateClass: Pointer, target: Pointer,
                  callback: @convention(c) (UnsafeMutableRawPointer?, UnsafeRawPointer?) -> Void) throws -> Pointer {
        let method = try nativeMethod(unsafeBitCast(callback, to: Pointer.self))
        var methodAddress = Int(bitPattern: method)
        return try withUnsafeMutablePointer(to: &methodAddress) {
            try new(delegateClass, [target, Pointer($0)], firstParameter: "System.Object")
        }
    }

    private func nativeMethod(_ function: Pointer) throws -> Pointer {
        if let made = nativeMethods[function] { return made }
        guard let element = findClass("UnityEngine.UIElements", "VisualElement") else { throw Failure("No VisualElement") }
        var source: Pointer?
        var iterator: P = nil
        while let m = api.classMethods(element, &iterator) {
            let flags = api.methodFlags(m, nil)
            if flags & 0x10 == 0, flags & 0x40 == 0, api.methodParamCount(m) == 0, !api.methodIsGeneric(m),
               api.typeKind(api.methodReturnType(m)) == 0x01 {
                source = m
                break
            }
        }
        guard let source else { throw Failure("No method to copy") }
        let size = 0x80
        let copy = Pointer.allocate(byteCount: size, alignment: 16)
        var got: mach_vm_size_t = 0
        guard mach_vm_read_overwrite(mach_task_self_, mach_vm_address_t(UInt(bitPattern: source)), mach_vm_size_t(size),
                                     mach_vm_address_t(UInt(bitPattern: copy)), &got) == KERN_SUCCESS else {
            throw Failure("Couldn't read a MethodInfo")
        }
        // Where the name and class sit says whether this IL2CPP has a virtualMethodPointer after methodPointer.
        let name = api.methodName(source).map(UnsafeRawPointer.init), klass = api.methodClass(source)
        let withVirtual = copy.load(fromByteOffset: 0x18, as: UnsafeRawPointer?.self) == name
            && copy.load(fromByteOffset: 0x20, as: P.self) == klass
        let without = copy.load(fromByteOffset: 0x10, as: UnsafeRawPointer?.self) == name
            && copy.load(fromByteOffset: 0x18, as: P.self) == klass
        guard withVirtual || without else { throw Failure("Unexpected MethodInfo layout") }
        copy.storeBytes(of: function, toByteOffset: 0, as: Pointer.self)
        if withVirtual { copy.storeBytes(of: function, toByteOffset: 8, as: Pointer.self) }
        nativeMethods[function] = copy
        PluginLog.write("Native method made from \(self.name(of: klass)).\(string(api.methodName(source))), \(withVirtual ? "with" : "without") virtualMethodPointer")
        return copy
    }

    // MARK: Describing

    /// A class's fields with offsets, the values of its static references once it's initialised, and its methods.
    func describe(_ klass: Pointer) -> String {
        var lines = ["\(name(of: klass)) : \(name(of: api.classParent(klass)))"]
        var iterator: P = nil
        while let f = api.classFields(klass, &iterator) {
            let flags = api.fieldFlags(f)
            let isStatic = flags & 0x10 != 0, constant = flags & 0x40 != 0
            var line = "  \(constant ? "const " : isStatic ? "static " : "")\(typeName(api.fieldType(f))) \(string(api.fieldName(f)))"
            if !isStatic {
                line += " @0x" + String(api.fieldOffset(f), radix: 16)
            } else if !constant, !api.classIsGeneric(klass), api.classIsInited(klass), let value = staticReference(f) {
                line += " = \(value)"
            }
            lines.append(line)
        }
        iterator = nil
        while let m = api.classMethods(klass, &iterator) {
            let flags = api.methodFlags(m, nil)
            let parameters = (0..<api.methodParamCount(m)).map { "\(typeName(api.methodParam(m, $0))) \(string(api.methodParamName(m, $0)))" }
            lines.append("  \(flags & 0x10 != 0 ? "static " : "")\(flags & 0x40 != 0 ? "virtual " : "")"
                + "\(typeName(api.methodReturnType(m))) \(string(api.methodName(m)))(\(parameters.joined(separator: ", ")))")
        }
        return lines.joined(separator: "\n")
    }

    private func staticReference(_ field: Pointer) -> String? {
        guard let fieldClass = api.classFromType(api.fieldType(field)), !api.classIsValueType(fieldClass) else { return nil }
        var value: P = nil
        withUnsafeMutablePointer(to: &value) { api.fieldStaticValue(field, Pointer($0)) }
        return value.map { summary(of: $0) } ?? "null"
    }

    func parentClass(_ klass: Pointer) -> Pointer? { api.classParent(klass) }

    /// An object's instance fields that point at other objects, from its own class up to any class in `stop`: each
    /// field's name and the object. Nulls, strings and structs are left out.
    func references(in object: Pointer, upTo stop: Set<String> = []) -> [(name: String, object: Pointer)] {
        var found: [(name: String, object: Pointer)] = []
        var klass = classOf(object)
        while let k = klass, !stop.contains(name(of: k)), !["System.Object", "UnityEngine.Object"].contains(name(of: k)) {
            var iterator: P = nil
            while let f = api.classFields(k, &iterator) {
                let type = api.fieldType(f)
                guard api.fieldFlags(f) & 0x10 == 0, [0x12, 0x14, 0x15, 0x1c, 0x1d].contains(api.typeKind(type)),
                      let fieldClass = api.classFromType(type), !api.classIsValueType(fieldClass),
                      let value = (object + api.fieldOffset(f)).load(as: P.self) else { continue }
                found.append((string(api.fieldName(f)), value))
            }
            klass = api.classParent(k)
        }
        return found
    }

    /// An object's instance fields and their values, following lists and arrays one level down. Fields of the
    /// classes in `stop` and above aren't listed.
    func describe(object: Pointer, upTo stop: Set<String> = []) -> String {
        var lines = ["\(summary(of: object))"]
        var klass = classOf(object)
        while let k = klass, !stop.contains(name(of: k)), !["System.Object", "UnityEngine.Object"].contains(name(of: k)) {
            var iterator: P = nil
            while let f = api.classFields(k, &iterator) {
                guard api.fieldFlags(f) & 0x10 == 0 else { continue }
                let address = object + api.fieldOffset(f)
                lines.append("  \(string(api.fieldName(f))) = \(value(at: address, type: api.fieldType(f)))")
            }
            klass = api.classParent(k)
        }
        return lines.joined(separator: "\n")
    }

    private func value(at address: Pointer, type: Pointer?) -> String {
        switch api.typeKind(type) {
        case 0x02: return address.load(as: Bool.self) ? "true" : "false"
        case 0x04, 0x05: return "\(address.load(as: UInt8.self))"
        case 0x06, 0x07: return "\(address.load(as: Int16.self))"
        case 0x08, 0x09: return "\(address.load(as: Int32.self))"
        case 0x0a, 0x0b, 0x18, 0x19: return "\(address.load(as: Int64.self))"
        case 0x0c: return "\(address.load(as: Float.self))"
        case 0x0d: return "\(address.load(as: Double.self))"
        // Strings, classes, objects, arrays and generic instances may be references; anything else isn't followed.
        case 0x0e, 0x12, 0x14, 0x15, 0x1c, 0x1d, 0x11, 0x55: break
        default: return "(type \(api.typeKind(type)))"
        }
        guard let klass = api.classFromType(type) else { return "?" }
        if api.classIsEnum(klass) { return "\(address.load(as: Int32.self)) (\(name(of: klass)))" }
        if api.classIsValueType(klass) || [0x11, 0x55].contains(api.typeKind(type)) { return "{\(name(of: klass))}" }
        guard let reference = address.load(as: P.self) else { return "null" }
        return summary(of: reference, expand: true)
    }

    /// One line for an object: its class, a Unity object's name, a string's text, a list's or array's items.
    func summary(of object: Pointer, expand: Bool = false) -> String {
        let klass = classOf(object)
        let className = name(of: klass)
        if className == "System.String" { return "\"\(text(object) ?? "")\"" }
        var line = "<\(className)"
        if let unityObject = findClass("UnityEngine", "Object"), isSubclass(klass, of: unityObject),
           let objectName = text(try? call(object, "get_name")), !objectName.isEmpty {
            line += " '\(objectName)'"
        }
        line += ">"
        guard expand else { return line }
        var items: [Pointer?]?
        if className.hasSuffix("[]") {
            guard !holdsValues(object) else { return line + " [\(api.arrayLength(object))]" }
            items = elements(object)
        } else if className.hasPrefix("System.Collections.Generic.List`1"),
                  let itemsField = field(klass, "_items"), let sizeField = field(klass, "_size") {
            let count = max(0, Int(object.load(fromByteOffset: api.fieldOffset(sizeField), as: Int32.self)))
            // A list of structs keeps them inline, which this doesn't read.
            guard let array = object.load(fromByteOffset: api.fieldOffset(itemsField), as: P.self), !holdsValues(array) else {
                return line + " count \(count)"
            }
            items = Array(elements(array).prefix(count))
        }
        guard let items else { return line }
        let shown = items.prefix(40).map { $0.map { summary(of: $0) } ?? "null" }
        return line + " [\(items.count)] " + shown.joined(separator: ", ") + (items.count > 40 ? ", ..." : "")
    }

    /// True for an array of structs or numbers, whose items aren't object pointers.
    private func holdsValues(_ array: Pointer) -> Bool {
        guard let element = api.classElement(classOf(array)) else { return true }
        return api.classIsValueType(element)
    }
}
