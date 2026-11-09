import Foundation
import UIKit
import Darwin

private let configDir = "/var/mobile/kdeconnect"
private let typePath = "\(configDir)/type"
private let namePath = "\(configDir)/name"
private let trustedPath = "\(configDir)/trusted"

private func daemonLog(_ message: String) {
    let line = "[kdeconnectd] \(Date()) \(message)"
    NSLog("%@", line)
    if let data = (line + "\n").data(using: .utf8) {
        FileHandle.standardError.write(data)
    }
}

private func describePath(_ path: String) -> String {
    var isDirectory: ObjCBool = false
    let exists = FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory)
    guard exists else { return "missing or not visible to this process" }

    do {
        let attributes = try FileManager.default.attributesOfItem(atPath: path)
        let owner = attributes[.ownerAccountID] ?? "?"
        let permissions = attributes[.posixPermissions] ?? "?"
        return "exists; directory=\(isDirectory.boolValue); owner=\(owner); mode=\(permissions)"
    } catch {
        return "exists, but attributes failed: \(error)"
    }
}

private func ensureDirectory(_ path: String) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
        guard isDirectory.boolValue else {
            throw NSError(
                domain: "KDEConnectDaemon",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey: "Expected a directory at \(path), found a file"]
            )
        }
        daemonLog("Directory ready: \(path)")
        return
    }

    daemonLog("Directory not visible; creating: \(path)")
    try FileManager.default.createDirectory(
        atPath: path,
        withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o755]
    )
    daemonLog("Created directory: \(path)")
}

private func ensureFile(_ path: String, defaultContents: String) throws {
    var isDirectory: ObjCBool = false
    if FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) {
        guard !isDirectory.boolValue else {
            throw NSError(
                domain: "KDEConnectDaemon",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey: "Expected a file at \(path), found a directory"]
            )
        }
        daemonLog("Config file already exists; leaving untouched: \(path)")
        return
    }

    daemonLog("Config file not visible; creating non-atomically: \(path)")
    let data = Data(defaultContents.utf8)
    let created = FileManager.default.createFile(
        atPath: path,
        contents: data,
        attributes: [.posixPermissions: 0o644]
    )

    guard created else {
        throw NSError(
            domain: "KDEConnectDaemon",
            code: 3,
            userInfo: [
                NSLocalizedDescriptionKey: "FileManager.createFile returned false for \(path). Path state: \(describePath(path))"
            ]
        )
    }
    daemonLog("Created config file: \(path)")
}

private func runDaemon() throws {
    daemonLog("Starting. iOS=\(UIDevice.current.systemVersion), uid=\(getuid()), euid=\(geteuid())")
    daemonLog("Config directory state: \(describePath(configDir))")
    daemonLog("type state: \(describePath(typePath))")
    daemonLog("name state: \(describePath(namePath))")
    daemonLog("trusted state: \(describePath(trustedPath))")

    if CommandLine.argc > 1 {
        throw NSError(
            domain: "KDEConnectDaemon",
            code: 4,
            userInfo: [NSLocalizedDescriptionKey: "Unexpected arguments: \(CommandLine.arguments.dropFirst())"]
        )
    }

    try ensureDirectory(configDir)
    try ensureFile(typePath, defaultContents: "phone")
    try ensureFile(namePath, defaultContents: UIDevice.current.name)
    try ensureFile(trustedPath, defaultContents: "")

    let deviceTypeString = try String(contentsOfFile: typePath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)

    var deviceType = K_CONNECT_FFI_DEVICE_TYPE_PHONE
    switch deviceTypeString {
    case "phone":
        deviceType = K_CONNECT_FFI_DEVICE_TYPE_PHONE
    case "tablet":
        deviceType = K_CONNECT_FFI_DEVICE_TYPE_TABLET
    case "tv":
        deviceType = K_CONNECT_FFI_DEVICE_TYPE_TV
    case "desktop":
        deviceType = K_CONNECT_FFI_DEVICE_TYPE_DESKTOP
    case "laptop":
        deviceType = K_CONNECT_FFI_DEVICE_TYPE_LAPTOP
    default:
        throw NSError(
            domain: "KDEConnectDaemon",
            code: 5,
            userInfo: [NSLocalizedDescriptionKey: "Invalid device type '\(deviceTypeString)' in \(typePath)"]
        )
    }

    var deviceName = try String(contentsOfFile: namePath, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    if deviceName.isEmpty {
        deviceName = UIDevice.current.name
        daemonLog("Device name config was empty; using current device name in memory")
    }

    daemonLog("Configuration loaded. name='\(deviceName)', type='\(deviceTypeString)'")
    daemonLog("Entering objc_main; Rust/KDE Connect service startup follows")
    let result = objc_main(deviceName, KConnectFfiDeviceType_t(deviceType.rawValue))
    daemonLog("objc_main returned: \(result)")
    if result != 0 {
        exit(Int32(result))
    }
}

do {
    try runDaemon()
} catch {
    daemonLog("FATAL startup error: \(error)")
    let nsError = error as NSError
    daemonLog("NSError domain=\(nsError.domain), code=\(nsError.code), userInfo=\(nsError.userInfo)")
    exit(EXIT_FAILURE)
}
