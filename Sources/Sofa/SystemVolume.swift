import Foundation

/// System output volume via osascript (same approach as the legacy app).
enum SystemVolume {
    private static let queue = DispatchQueue(label: "sofa.sysvolume")

    static func get(_ completion: @escaping (Int) -> Void) {
        run(["-e", "output volume of (get volume settings)"]) { out in
            completion(Int(out ?? "") ?? 50)
        }
    }

    static func set(_ value: Int) {
        let v = max(0, min(100, value))
        run(["-e", "set volume output volume \(v)"]) { _ in }
    }

    private static func run(_ args: [String], completion: @escaping (String?) -> Void) {
        queue.async {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
            proc.arguments = args
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = Pipe()
            guard (try? proc.run()) != nil else { completion(nil); return }
            proc.waitUntilExit()
            let out = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            completion(proc.terminationStatus == 0 ? out : nil)
        }
    }
}
