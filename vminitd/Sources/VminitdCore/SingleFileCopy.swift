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
import GRPCCore
import SystemPackage

#if canImport(Musl)
import Musl
#else
import Glibc
#endif

/// Writes to the resolved file itself, never replacing a directory or a final symlink.
enum SingleFileCopy {
    struct Owner: Equatable, Sendable {
        let uid: UInt32
        let gid: UInt32
    }

    /// Validate before connecting the data stream or touching the destination.
    static func owner(for request: Com_Apple_Containerization_Sandbox_V3_CopyRequest) throws -> Owner? {
        guard request.direction == .copyInOwnedFile else { return nil }
        guard !request.isArchive, request.hasOwnerUid, request.hasOwnerGid,
            request.ownerUid != UInt32.max, request.ownerGid != UInt32.max
        else {
            throw RPCError(code: .invalidArgument, message: "owned file copy requires a file payload and explicit valid UID/GID")
        }
        return Owner(uid: request.ownerUid, gid: request.ownerGid)
    }

    static func copy(from input: Int32, root: Int32, path: String, mode: UInt32, createParents: Bool, owner: Owner?) throws {
        // uid_t(-1)/gid_t(-1) mean "leave unchanged", not a real owner.
        if let owner, owner.uid == UInt32.max || owner.gid == UInt32.max {
            throw RootfsResolver.Error.errno(EINVAL, "invalid copy owner")
        }
        if createParents {
            try RootfsResolver.createDirectoryInRoot(dirFd: root, path: FilePath(path).removingLastComponent().string)
        }
        // Do not truncate until the opened descriptor is known to be a regular file.
        // NONBLOCK makes a FIFO fail promptly rather than waiting for another process.
        let requestedMode = mode > 0 ? mode : 0o644
        // Match archive extraction: copying ownership must not introduce set-ID bits.
        let permissions = owner == nil ? requestedMode : requestedMode & 0o777
        let fd = RootfsResolver.openInRoot(
            dirFd: root, path: path, flags: O_WRONLY | O_CREAT | O_NONBLOCK | O_CLOEXEC,
            mode: UInt64(permissions))
        guard fd >= 0 else { throw RootfsResolver.Error.errno(errno, "open copy destination '\(path)'") }
        defer { close(fd) }
        var info = stat()
        guard fstat(fd, &info) == 0 else { throw RootfsResolver.Error.errno(errno, "stat copy destination") }
        guard info.st_mode & S_IFMT == S_IFREG else { throw RootfsResolver.Error.errno(EINVAL, "copy destination is not a regular file") }
        guard ftruncate(fd, 0) == 0 else { throw RootfsResolver.Error.errno(errno, "truncate copy destination") }

        var buffer = [UInt8](repeating: 0, count: 1024 * 1024)
        while true {
            let count = read(input, &buffer, buffer.count)
            if count == 0 { break }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else { throw RootfsResolver.Error.errno(errno, "read file copy") }
            var written = 0
            while written < count {
                let amount = buffer.withUnsafeBytes { bytes -> Int in
                    guard let base = bytes.baseAddress else { return -1 }
                    return write(fd, base + written, count - written)
                }
                if amount < 0, errno == EINTR { continue }
                guard amount > 0 else { throw RootfsResolver.Error.errno(errno, "write file copy") }
                written += amount
            }
        }
        // The path may have changed during transfer. Apply ownership to the descriptor we
        // wrote, rather than looking the name up again or requiring a utility in the image.
        if let owner, fchown(fd, owner.uid, owner.gid) != 0 {
            throw RootfsResolver.Error.errno(errno, "set copy destination owner")
        }
        if owner != nil, fchmod(fd, mode_t(permissions)) != 0 {
            throw RootfsResolver.Error.errno(errno, "set copy destination permissions")
        }
    }
}
#endif
