import Foundation
import Testing

@testable import ClawCore

@Suite("SHA-256")
struct SHA256Tests {
    @Test("Published vectors")
    func vectors() {
        #expect(SHA256.hex(Data()) == "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        #expect(SHA256.hex(Data("abc".utf8)) == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        #expect(
            SHA256.hex(Data("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq".utf8))
                == "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
    }

    @Test("Lengths around the padding boundary")
    func paddingBoundaries() {
        let expected: [(Int, String)] = [
            (55, "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318"),
            (56, "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a"),
            (63, "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34"),
            (64, "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb"),
            (65, "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0"),
            (119, "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb"),
            (1000, "41edece42d63e8d9bf515a9ba6932e1c20cbc9f5a5d134645adb5db1b9737ea3"),
        ]
        for (length, hash) in expected {
            #expect(SHA256.hex(Data(repeating: UInt8(ascii: "a"), count: length)) == hash, "length \(length)")
        }
    }
}

@Suite("Atomic write")
struct AtomicWriteTests {
    private final class Folder {
        let path: String
        init() throws {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            path = url.path
        }
        deinit {
            try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: path)
            try? FileManager.default.removeItem(atPath: path)
        }
        func file(_ name: String) -> String { joinPath(path, name) }
        func names() throws -> [String] { try FileManager.default.contentsOfDirectory(atPath: path).sorted() }
    }

    private func put(_ path: String, _ text: String, mode: Int = 0o644) throws {
        try Data(text.utf8).write(to: URL(fileURLWithPath: path))
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: path)
    }

    private func read(_ path: String) throws -> String {
        String(decoding: try Data(contentsOf: URL(fileURLWithPath: path)), as: UTF8.self)
    }

    private func mode(_ path: String) throws -> Int {
        try #require(FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int)
    }

    private func hash(_ text: String) -> String { SHA256.hex(Data(text.utf8)) }

    @Test("A new file is private and holds the data")
    func newFile() throws {
        let folder = try Folder()
        let target = folder.file("settings.json")
        try AtomicWrite.write(Data("new".utf8), to: target, expectedSHA256: nil)
        #expect(try read(target) == "new")
        #expect(try mode(target) == 0o600)
        #expect(try folder.names() == ["settings.json"])
    }

    @Test("Replacing keeps the file mode, even one the umask would cut", arguments: [0o600, 0o644, 0o664, 0o666])
    func keepsMode(expected: Int) throws {
        let folder = try Folder()
        let target = folder.file("a.json")
        try put(target, "old", mode: expected)
        try AtomicWrite.write(Data("new".utf8), to: target, expectedSHA256: hash("old"))
        #expect(try read(target) == "new")
        #expect(try mode(target) == expected)
        #expect(try folder.names() == ["a.json"])
    }

    @Test("A symlink stays a link, and its target gets the data")
    func symlink() throws {
        let folder = try Folder()
        let real = folder.file("real.json")
        let link = folder.file("link.json")
        let second = folder.file("second.json")
        try put(real, "old", mode: 0o640)
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "real.json")
        try FileManager.default.createSymbolicLink(atPath: second, withDestinationPath: link)
        try AtomicWrite.write(Data("new".utf8), to: second, expectedSHA256: hash("old"))
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: second) == link)
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "real.json")
        #expect(try read(real) == "new")
        #expect(try mode(real) == 0o640)
    }

    @Test("A broken link is refused and left alone")
    func brokenLink() throws {
        let folder = try Folder()
        let link = folder.file("link.json")
        try FileManager.default.createSymbolicLink(atPath: link, withDestinationPath: "gone.json")
        #expect(throws: AtomicWriteError.self) {
            try AtomicWrite.write(Data("new".utf8), to: link, expectedSHA256: nil)
        }
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: link) == "gone.json")
        #expect(try folder.names() == ["link.json"])
    }

    @Test("A file changed since the scan is refused")
    func staleBeforeWriting() throws {
        let folder = try Folder()
        let target = folder.file("a.json")
        try put(target, "changed")
        #expect(throws: StaleFileError(file: target)) {
            try AtomicWrite.write(Data("new".utf8), to: target, expectedSHA256: hash("scanned"))
        }
        #expect(try read(target) == "changed")
        #expect(try folder.names() == ["a.json"])
    }

    @Test("A change while writing is refused, and the other writer's bytes stay")
    func concurrentChange() throws {
        let folder = try Folder()
        let target = folder.file("a.json")
        try put(target, "old")
        let other = target
        #expect(throws: StaleFileError(file: target)) {
            try AtomicWrite.write(
                Data("new".utf8), to: target, expectedSHA256: hash("old"),
                beforeRename: { try? Data("claude wrote this".utf8).write(to: URL(fileURLWithPath: other)) })
        }
        #expect(try read(target) == "claude wrote this")
        #expect(try folder.names() == ["a.json"])
    }

    @Test("Expecting no file when one exists, or a file when none does, is stale")
    func existenceMismatch() throws {
        let folder = try Folder()
        let target = folder.file("a.json")
        #expect(throws: StaleFileError(file: target)) {
            try AtomicWrite.write(Data("new".utf8), to: target, expectedSHA256: hash("old"))
        }
        #expect(try folder.names().isEmpty)
        try put(target, "old")
        #expect(throws: StaleFileError(file: target)) {
            try AtomicWrite.write(Data("new".utf8), to: target, expectedSHA256: nil)
        }
        #expect(try read(target) == "old")
    }

    @Test("A folder that is missing or cannot be written fails, and changes nothing")
    func unwritable() throws {
        let folder = try Folder()
        #expect(throws: AtomicWriteError.self) {
            try AtomicWrite.write(Data("new".utf8), to: folder.file("no/such/a.json"), expectedSHA256: nil)
        }
        #expect(throws: AtomicWriteError.self) {
            try AtomicWrite.write(Data("new".utf8), to: folder.path, expectedSHA256: nil)
        }
        let target = folder.file("a.json")
        try put(target, "old")
        try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: folder.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: folder.path) }
        guard geteuid() != 0 else { return }
        #expect(throws: AtomicWriteError.self) {
            try AtomicWrite.write(Data("new".utf8), to: target, expectedSHA256: hash("old"))
        }
        #expect(try read(target) == "old")
    }

    @Test("Hash of a file, and nil for no file")
    func fileHash() throws {
        let folder = try Folder()
        let target = folder.file("a.json")
        #expect(try AtomicWrite.sha256(ofFile: target) == nil)
        try put(target, "abc")
        #expect(try AtomicWrite.sha256(ofFile: target) == hash("abc"))
    }
}
