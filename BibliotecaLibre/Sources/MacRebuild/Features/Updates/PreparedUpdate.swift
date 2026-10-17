import Foundation

struct PreparedUpdate: Codable, Sendable {
    let stagedApp: URL
    let installedApp: URL
    let workDirectory: URL
    let tag: String
    var helper: URL { workDirectory.appendingPathComponent("install.sh") }
    var backup: URL { installedApp.deletingLastPathComponent().appendingPathComponent(".Libron-X-previous-\(workDirectory.lastPathComponent).app") }
    // Paths are positional arguments, never interpolated shell source.
    static let helperSource = #"""
    #!/bin/sh
    set -eu
    parent_pid="$1"
    staged="$2"
    destination="$3"
    backup="$4"
    restart="$5"
    result="$6"
    ticks=0
    while kill -0 "$parent_pid" 2>/dev/null; do
        ticks=$((ticks + 1))
        if [ "$ticks" -gt 480 ]; then printf 'timeout\n' > "$result"; exit 1; fi
        sleep 0.25
    done
    if [ ! -d "$staged" ] || [ ! -d "$destination" ] || [ -e "$backup" ]; then
        printf 'invalid-paths\n' > "$result"; exit 1
    fi
    /usr/bin/codesign --verify --deep --strict "$staged" || { printf 'validation-failed\n' > "$result"; exit 1; }
    /bin/mv "$destination" "$backup" || { printf 'backup-failed\n' > "$result"; exit 1; }
    if ! /bin/mv "$staged" "$destination"; then
        /bin/mv "$backup" "$destination"
        printf 'rolled-back\n' > "$result"
        exit 1
    fi
    printf 'installed\n' > "$result"
    if [ "$restart" = "yes" ]; then /usr/bin/open -n "$destination"; fi
    """#
    func writeHelper() throws {
        try Self.helperSource.write(to: helper, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: helper.path)
    }
    func launchAfterExit(pid: Int32, restart: Bool) throws {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [helper.path, String(pid), stagedApp.path, installedApp.path, backup.path,
                             restart ? "yes" : "no", workDirectory.appendingPathComponent("result.txt").path]
        process.standardInput = FileHandle.nullDevice; process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run()
    }
    func discard() {
        try? FileManager.default.removeItem(at: stagedApp)
        try? FileManager.default.removeItem(at: workDirectory)
    }
}
