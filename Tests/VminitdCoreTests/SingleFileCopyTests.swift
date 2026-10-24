//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the Containerization project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

#if os(Linux)
import Containerization
import ContainerizationOS
import Foundation
import GRPCCore
import Testing

#if canImport(Musl)
import Musl
#else
import Glibc
#endif

@testable import VminitdCore

@Suite(.timeLimit(.minutes(1)))
struct SingleFileCopyTests {
    struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        init() throws { try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true) }
        func path(_ name: String) -> URL { root.appendingPathComponent(name) }
        func clean() { try? FileManager.default.removeItem(at: root) }
        var owner: SingleFileCopy.Owner { .init(uid: geteuid() == 0 ? 1001 : geteuid(), gid: geteuid() == 0 ? 1002 : getegid()) }
        func copy(to name: String, parents: Bool = false, mode: UInt32 = 0o640, owner: SingleFileCopy.Owner? = nil) throws {
            let source = path("input-payload")
            try Data("new contents".utf8).write(to: source)
            let input = open(source.path, O_RDONLY | O_CLOEXEC)
            let directory = open(root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
            defer {
                close(input)
                close(directory)
            }
            try #require(input >= 0 && directory >= 0)
            try SingleFileCopy.copy(from: input, root: directory, path: name, mode: mode, createParents: parents, owner: owner)
        }
        func info(_ name: String) throws -> stat {
            var value = stat()
            try #require(lstat(path(name).path, &value) == 0)
            return value
        }
    }

    @Test("checked archive destinations refuse a final symlink but ordinary directories still resolve it")
    func checkedArchiveRoot() throws {
        let f = try Fixture()
        defer { f.clean() }
        try FileManager.default.createDirectory(at: f.path("target"), withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: f.path("link").path, withDestinationPath: "/target")
        let root = open(f.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        defer { close(root) }
        try #require(root >= 0)
        #expect(throws: (any Error).self) {
            try RootfsResolver.withDirectoryInRoot(dirFd: root, path: "link", followFinalSymlink: false) { _ in }
        }
        try RootfsResolver.withDirectoryInRoot(dirFd: root, path: "link") { fd in #expect(fd >= 0) }
        #expect(try f.info("link").st_mode & S_IFMT == S_IFLNK)
    }

    @Test("a file cannot replace a directory or erase its contents")
    func directoryCollision() throws {
        let f = try Fixture()
        defer { f.clean() }
        try FileManager.default.createDirectory(at: f.path("destination/item"), withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: f.path("destination/item/sentinel"))
        #expect(throws: (any Error).self) { try f.copy(to: "destination/item", owner: f.owner) }
        #expect(try String(contentsOf: f.path("destination/item/sentinel"), encoding: .utf8) == "keep")
        #expect(try f.info("destination/item").st_mode & S_IFMT == S_IFDIR)
    }

    @Test("a final symlink is retained and its in-root target receives contents and ownership", arguments: [false, true], [false, true])
    func symlink(dangling: Bool, relative: Bool) throws {
        let f = try Fixture()
        defer { f.clean() }
        if !dangling { try Data("old".utf8).write(to: f.path("target")) }
        try FileManager.default.createSymbolicLink(atPath: f.path("link").path, withDestinationPath: relative ? "target" : "/target")
        try f.copy(to: "link", owner: f.owner)
        #expect(try f.info("link").st_mode & S_IFMT == S_IFLNK)
        #expect(try String(contentsOf: f.path("target"), encoding: .utf8) == "new contents")
        let info = try f.info("target")
        #expect(info.st_uid == f.owner.uid && info.st_gid == f.owner.gid)
    }

    @Test("an absolute symlink cannot overwrite outside the container root")
    func rootConfinement() throws {
        let f = try Fixture()
        defer { f.clean() }
        let outside = try Fixture()
        defer { outside.clean() }
        try Data("outside".utf8).write(to: outside.path("keep"))
        try FileManager.default.createSymbolicLink(atPath: f.path("escape").path, withDestinationPath: outside.path("keep").path)
        #expect(throws: (any Error).self) { try f.copy(to: "escape", owner: f.owner) }
        #expect(try String(contentsOf: outside.path("keep"), encoding: .utf8) == "outside")
        #expect(try f.info("escape").st_mode & S_IFMT == S_IFLNK)
    }

    @Test("new parents are optional; owned copies keep the file identity and apply source permissions")
    func createAndOverwrite() throws {
        let f = try Fixture()
        defer { f.clean() }
        #expect(throws: (any Error).self) { try f.copy(to: "missing/file", owner: f.owner) }
        try f.copy(to: "missing/file", parents: true, owner: f.owner)
        try #require(chmod(f.path("missing/file").path, 0o600) == 0)
        let before = try f.info("missing/file")
        try f.copy(to: "missing/file", owner: f.owner)
        let after = try f.info("missing/file")
        #expect(after.st_ino == before.st_ino)
        #expect(after.st_mode & 0o777 == 0o640)
        #expect(after.st_uid == f.owner.uid && after.st_gid == f.owner.gid)
        #expect(try String(contentsOf: f.path("missing/file"), encoding: .utf8) == "new contents")
        try #require(chmod(f.path("missing/file").path, 0o600) == 0)
        try f.copy(to: "missing/file")
        #expect(try f.info("missing/file").st_mode & 0o777 == 0o600, "legacy raw copies preserve destination permissions")
    }

    @Test("invalid owners are rejected before truncating a destination")
    func invalidOwner() throws {
        let f = try Fixture()
        defer { f.clean() }
        try Data("keep".utf8).write(to: f.path("target"))
        for owner in [SingleFileCopy.Owner(uid: .max, gid: 0), .init(uid: 0, gid: .max)] {
            #expect(throws: (any Error).self) { try f.copy(to: "target", owner: owner) }
            #expect(try String(contentsOf: f.path("target"), encoding: .utf8) == "keep")
        }
    }

    @Test("owned copies strip set-ID bits, as archive extraction does")
    func noSetID() throws {
        let f = try Fixture()
        defer { f.clean() }
        try f.copy(to: "target", mode: 0o6755, owner: f.owner)
        #expect(try f.info("target").st_mode & 0o7777 == 0o755)
    }

    @Test("owned-file requests require both IDs and a file payload; zero is explicit")
    func requestValidation() throws {
        var request = Com_Apple_Containerization_Sandbox_V3_CopyRequest()
        request.direction = .copyInOwnedFile
        #expect(throws: RPCError.self) { try SingleFileCopy.owner(for: request) }
        request.ownerUid = 0
        #expect(throws: RPCError.self) { try SingleFileCopy.owner(for: request) }
        request.ownerGid = 0
        #expect(try SingleFileCopy.owner(for: request) == .init(uid: 0, gid: 0))
        request.isArchive = true
        #expect(throws: RPCError.self) { try SingleFileCopy.owner(for: request) }
        request.isArchive = false
        request.ownerUid = .max
        #expect(throws: RPCError.self) { try SingleFileCopy.owner(for: request) }
        request.direction = .copyIn
        #expect(try SingleFileCopy.owner(for: request) == nil)
    }

    @Test("a renamed destination cannot redirect the final ownership update")
    func ownershipStaysWithOpenedFile() async throws {
        let f = try Fixture()
        defer { f.clean() }
        try Data("old".utf8).write(to: f.path("target"))
        try Data("victim".utf8).write(to: f.path("victim"))
        try FileManager.default.createSymbolicLink(atPath: f.path("link").path, withDestinationPath: "/target")
        let victimBefore = try f.info("victim")
        var pipeFDs: [Int32] = [0, 0]
        try #require(pipe(&pipeFDs) == 0)
        let input = pipeFDs[0]
        let output = pipeFDs[1]
        let root = open(f.root.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(root >= 0)
        defer {
            close(input)
            close(root)
        }
        let task = Task.detached { try SingleFileCopy.copy(from: input, root: root, path: "link", mode: 0o644, createParents: false, owner: f.owner) }
        var byte: UInt8 = 65
        #expect(write(output, &byte, 1) == 1)
        let deadline = ContinuousClock.now + .seconds(5)
        while (try? Data(contentsOf: f.path("target"))) != Data([65]), ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(5))
        }
        #expect((try? Data(contentsOf: f.path("target"))) == Data([65]))
        // Even if this swap fails, close the producer before propagating an error.
        do {
            try FileManager.default.removeItem(at: f.path("link"))
            try FileManager.default.createSymbolicLink(atPath: f.path("link").path, withDestinationPath: "/victim")
        } catch {
            close(output)
            _ = try? await task.value
            throw error
        }
        close(output)
        try await task.value
        let target = try f.info("target")
        let victim = try f.info("victim")
        #expect(target.st_uid == f.owner.uid && target.st_gid == f.owner.gid)
        #expect(victim.st_uid == victimBefore.st_uid && victim.st_gid == victimBefore.st_gid)
        #expect(try String(contentsOf: f.path("victim"), encoding: .utf8) == "victim")
    }
}
#endif
