//
//  GuideAutopilotPseudoTerminal.swift
//  leanring-buddy
//
//  The only file in the app that touches openpty and posix_spawn. It exists
//  because the two obvious alternatives are both wrong for a terminal:
//
//  - `forkpty` calls fork() without exec inside a process hosting AppKit,
//    dispatch, and ScreenCaptureKit — undefined behaviour in a Cocoa app.
//  - `Foundation.Process` with a pty as stdio gives the child a terminal but
//    not a *controlling* terminal: no session, no foreground process group,
//    so writing Ctrl-C to the primary delivers no SIGINT and a running
//    `npm ci` cannot be cancelled.
//
//  posix_spawn with POSIX_SPAWN_SETSID gives both without forking in
//  process: the child starts a new session, and because its first open of
//  the replica happens after setsid without O_NOCTTY, the pty becomes its
//  controlling terminal and it the foreground process group. Ctrl-C then
//  goes through the line discipline exactly as in Terminal.app.
//
//  Reads happen on a dedicated thread doing blocking read(2) — not
//  FileHandle (EIO becomes an uncatchable ObjC exception there), and not a
//  DispatchSourceRead (kqueue readiness on a pty primary proved unreliable
//  inside the app process — sessions after the first simply never saw their
//  bytes — while a plain blocking read has never missed). One long-lived
//  thread per live shell is the entire cost, and a guide runs at most two.
//  EIO or end-of-file on the primary means every replica is closed: the
//  shell is gone, and the reader thread reaps it with waitpid and reports.
//
//  The class is nonisolated (the target defaults to MainActor, which is
//  wrong for code that must run while the UI is busy). The reader thread
//  owns the primary fd's lifetime: teardown kills the process group, the
//  read unblocks with EIO, and the fd is closed by the thread that was
//  reading it — never out from under a blocked read.
//

import Foundation

final class GuideAutopilotPseudoTerminal: @unchecked Sendable {

    enum SpawnError: Error {
        case openptyFailed(errno: Int32)
        case spawnFailed(errno: Int32)
    }

    /// Bytes from the pty primary, delivered on the reader thread.
    nonisolated(unsafe) var onOutput: (([UInt8]) -> Void)?
    /// The shell exited; the status is waitpid's. Delivered on the reader
    /// thread, after the final bytes.
    nonisolated(unsafe) var onProcessExit: ((Int32) -> Void)?

    nonisolated(unsafe) private(set) var processIdentifier: pid_t = -1

    private let writeQueue = DispatchQueue(label: "iris.autopilot.pty.write")
    nonisolated(unsafe) private var primaryFileDescriptor: Int32 = -1

    nonisolated init() {}

    // MARK: - Spawning

    nonisolated func spawn(
        shellPath: String,
        arguments: [String],
        environment: [String: String]
    ) throws {
        var primary: Int32 = 0
        var replica: Int32 = 0
        // A very wide terminal so long output lines — above all the ready
        // marker, which carries the whole PATH — never wrap. A wrap inserts
        // control bytes mid-line, and the sentinel must arrive on one
        // physical line to be matched. Real terminal apps still see a sane
        // size; nothing here renders a UI to these columns.
        var windowSize = winsize(ws_row: 100, ws_col: 4000, ws_xpixel: 0, ws_ypixel: 0)
        guard openpty(&primary, &replica, nil, nil, &windowSize) == 0 else {
            throw SpawnError.openptyFailed(errno: errno)
        }
        guard let replicaPath = String(validatingUTF8: ttyname(replica)) else {
            close(primary)
            close(replica)
            throw SpawnError.openptyFailed(errno: ENOTTY)
        }

        var fileActions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&fileActions)
        defer { posix_spawn_file_actions_destroy(&fileActions) }
        // Opening the replica by path, after SETSID and without O_NOCTTY,
        // is what makes the pty the child's controlling terminal.
        posix_spawn_file_actions_addopen(&fileActions, 0, replicaPath, O_RDWR, 0)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 1)
        posix_spawn_file_actions_adddup2(&fileActions, 0, 2)

        var attributes: posix_spawnattr_t?
        posix_spawnattr_init(&attributes)
        defer { posix_spawnattr_destroy(&attributes) }
        // CLOEXEC_DEFAULT closes every parent fd in the child except the
        // stdio set up above — the child must not inherit sockets or files
        // the app happens to hold open.
        posix_spawnattr_setflags(
            &attributes,
            Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT)
        )

        var argv: [UnsafeMutablePointer<CChar>?] =
            ([shellPath] + arguments).map { strdup($0) }
        argv.append(nil)
        var envp: [UnsafeMutablePointer<CChar>?] =
            environment.map { strdup("\($0.key)=\($0.value)") }
        envp.append(nil)
        defer {
            argv.forEach { free($0) }
            envp.forEach { free($0) }
        }

        var childProcessIdentifier: pid_t = 0
        let spawnResult = posix_spawn(
            &childProcessIdentifier, shellPath, &fileActions, &attributes, argv, envp
        )
        close(replica)
        guard spawnResult == 0 else {
            close(primary)
            throw SpawnError.spawnFailed(errno: spawnResult)
        }

        processIdentifier = childProcessIdentifier
        primaryFileDescriptor = primary

        let thread = Thread { [weak self] in
            self?.blockingReadLoop(primary: primary, child: childProcessIdentifier)
        }
        thread.name = "iris.autopilot.pty.read"
        thread.stackSize = 512 * 1024
        thread.start()
    }

    // MARK: - Reading

    nonisolated private func blockingReadLoop(primary: Int32, child: pid_t) {
        var chunk = [UInt8](repeating: 0, count: 4_096)
        readLoop: while true {
            let bytesRead = chunk.withUnsafeMutableBytes { buffer -> Int in
                read(primary, buffer.baseAddress, buffer.count)
            }
            if bytesRead > 0 {
                onOutput?(Array(chunk[0..<bytesRead]))
                continue
            }
            switch (bytesRead, errno) {
            case (0, _), (_, EIO):
                // Every replica is closed: the shell is gone.
                break readLoop
            case (_, EINTR):
                continue
            default:
                break readLoop
            }
        }
        var status: Int32 = 0
        waitpid(child, &status, 0)
        // The child is reaped: its pid may be reissued to a stranger at any
        // moment, so it must never be a kill target again. A stale-pid
        // kill(-pid) from a lingering deinit murders whatever innocent
        // process group inherited the number — including our own next shell.
        processIdentifier = -1
        // The reader owns the fd: closing it here, after the last read, is
        // what keeps close from racing a blocked read.
        close(primary)
        primaryFileDescriptor = -1
        onProcessExit?(status)
    }

    // MARK: - Writing and signals

    nonisolated func write(_ text: String) {
        let bytes = Array(text.utf8)
        writeQueue.async { [weak self] in
            guard let self, self.primaryFileDescriptor >= 0 else { return }
            var written = 0
            while written < bytes.count {
                let result = bytes[written...].withUnsafeBytes { buffer -> Int in
                    Darwin.write(self.primaryFileDescriptor, buffer.baseAddress, buffer.count)
                }
                if result > 0 { written += result } else if errno != EINTR { break }
            }
        }
    }

    /// Ctrl-C through the line discipline — reaches whatever is running in
    /// the foreground group, exactly as in a real terminal.
    nonisolated func sendInterrupt() {
        write("\u{03}")
    }

    /// Ctrl-D: end-of-input for tools that read stdin.
    nonisolated func sendEndOfInput() {
        write("\u{04}")
    }

    /// The sledgehammer for a wedged session: SIGKILL to the whole process
    /// group, callers rebuild afterwards.
    nonisolated func killProcessGroup() {
        guard processIdentifier > 0 else { return }
        kill(-processIdentifier, SIGKILL)
    }

    /// Teardown is indirect by design: killing the process group makes the
    /// blocked read return EIO, and the reader thread — the fd's owner —
    /// closes it and reports the exit. Closing the fd here instead would
    /// race the blocked read.
    nonisolated func closeSession() {
        killProcessGroup()
    }

    deinit {
        closeSession()
    }
}
