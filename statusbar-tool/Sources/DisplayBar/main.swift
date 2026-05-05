import AppKit
import ColorSync
import CoreGraphics
import Foundation

@_silgen_name("CoreDisplay_Display_SupportsHDRMode")
private func CoreDisplay_Display_SupportsHDRMode(_ display: CGDirectDisplayID) -> Bool

@_silgen_name("CoreDisplay_Display_IsHDRModeEnabled")
private func CoreDisplay_Display_IsHDRModeEnabled(_ display: CGDirectDisplayID) -> Bool

@_silgen_name("CoreDisplay_Display_SetHDRModeEnabled")
private func CoreDisplay_Display_SetHDRModeEnabled(_ display: CGDirectDisplayID, _ enabled: Bool) -> Bool

@_silgen_name("SLSDisplaySupportsHDRMode")
private func SLSDisplaySupportsHDRMode(_ display: CGDirectDisplayID) -> Bool

@_silgen_name("SLSDisplayIsHDRModeEnabled")
private func SLSDisplayIsHDRModeEnabled(_ display: CGDirectDisplayID) -> Bool

@_silgen_name("SLSDisplaySetHDRModeEnabled")
private func SLSDisplaySetHDRModeEnabled(_ display: CGDirectDisplayID, _ enabled: Bool) -> Bool

struct DisplayMode: Codable, Equatable, Hashable {
    var modeNumber: Int
    var width: Int
    var height: Int
    var hertz: Int?
    var colorDepth: Int?
    var scaling: String?
    var isCurrent: Bool
    var coreGraphicsModeID: Int?

    var resolution: String {
        "\(width)x\(height)"
    }

    var isHiDPI: Bool {
        scaling == "on"
    }

    var title: String {
        var parts: [String] = []
        if let hertz {
            parts.append("\(hertz)Hz")
        }
        if let colorDepth {
            parts.append("\(colorDepth)-bit")
        }
        parts.append(isHiDPI ? "HiDPI" : "标准")
        return parts.joined(separator: "  ")
    }
}

struct DisplayInfo: Codable, Equatable {
    var persistentID: String
    var contextualID: UInt32?
    var serialID: String?
    var type: String
    var resolution: String?
    var hertz: Int?
    var colorDepth: Int?
    var scaling: String?
    var origin: String?
    var rotation: Int?
    var enabled: Bool?
    var isMain: Bool
    var online: Bool = true
    var modes: [DisplayMode] = []

    var title: String {
        let base = type.isEmpty ? persistentID.prefix(8) + "..." : type
        if isMain {
            return "\(base) - 主屏"
        }
        return String(base)
    }

    var detail: String {
        var parts: [String] = []
        if let resolution {
            parts.append(resolution)
        }
        if let hertz {
            parts.append("\(hertz)Hz")
        }
        if let contextualID {
            parts.append("id:\(contextualID)")
        }
        if scaling == "on" {
            parts.append("HiDPI")
        }
        if online == false {
            parts.append("离线/上次见到")
        }
        return parts.joined(separator: "  ")
    }

    var width: Int? {
        resolutionDimensions?.width
    }

    var height: Int? {
        resolutionDimensions?.height
    }

    private var resolutionDimensions: (width: Int, height: Int)? {
        guard let resolution else {
            return nil
        }
        let parts = resolution.split(separator: "x")
        guard parts.count == 2,
              let width = Int(parts[0]),
              let height = Int(parts[1]) else {
            return nil
        }
        return (width, height)
    }
}

struct CommandResult {
    var status: Int32
    var stdout: String
    var stderr: String

    var combinedOutput: String {
        let output = [stdout, stderr].filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        return output.joined(separator: "\n")
    }
}

struct DisplayColorProfile {
    var profileID: String
    var name: String
    var path: String?
    var isCurrent: Bool
    var isDefault: Bool
}

struct ColorProfileOption {
    var name: String
    var path: String
}

final class Shell {
    static func run(_ executable: String, _ arguments: [String], timeout: TimeInterval = 20) throws -> CommandResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments

        let tempDirectory = FileManager.default.temporaryDirectory
        let stdoutURL = tempDirectory.appendingPathComponent("DisplayBar-\(UUID().uuidString).stdout")
        let stderrURL = tempDirectory.appendingPathComponent("DisplayBar-\(UUID().uuidString).stderr")
        FileManager.default.createFile(atPath: stdoutURL.path, contents: nil)
        FileManager.default.createFile(atPath: stderrURL.path, contents: nil)

        let stdoutHandle = try FileHandle(forWritingTo: stdoutURL)
        let stderrHandle = try FileHandle(forWritingTo: stderrURL)
        defer {
            try? stdoutHandle.close()
            try? stderrHandle.close()
            try? FileManager.default.removeItem(at: stdoutURL)
            try? FileManager.default.removeItem(at: stderrURL)
        }

        process.standardOutput = stdoutHandle
        process.standardError = stderrHandle

        try process.run()

        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline {
            RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
        }

        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
            throw NSError(domain: "DisplayBar.Shell", code: 124, userInfo: [
                NSLocalizedDescriptionKey: "Command timed out: \(executable) \(arguments.joined(separator: " "))"
            ])
        }

        try? stdoutHandle.close()
        try? stderrHandle.close()
        let stdoutData = (try? Data(contentsOf: stdoutURL)) ?? Data()
        let stderrData = (try? Data(contentsOf: stderrURL)) ?? Data()

        return CommandResult(
            status: process.terminationStatus,
            stdout: String(data: stdoutData, encoding: .utf8) ?? "",
            stderr: String(data: stderrData, encoding: .utf8) ?? ""
        )
    }
}

final class DisplayPlacer {
    let executable: String

    init(executable: String) {
        self.executable = executable
    }

    func list() throws -> [DisplayInfo] {
        let result = try Shell.run(executable, ["list"], timeout: 30)
        guard result.status == 0 else {
            throw NSError(domain: "DisplayBar.DisplayPlacer", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: result.combinedOutput.isEmpty ? "displayplacer list failed." : result.combinedOutput
            ])
        }
        return Self.parseList(result.stdout)
    }

    func setEnabled(_ enabled: Bool, display: DisplayInfo) throws -> CommandResult {
        let value = enabled ? "true" : "false"
        let result = try Shell.run(executable, ["id:\(display.persistentID) enabled:\(value)"], timeout: 30)
        return result
    }

    func setMode(_ mode: DisplayMode, for display: DisplayInfo, preserving displays: [DisplayInfo]) throws -> CommandResult {
        let arguments = displays.compactMap { current -> String? in
            guard current.online, current.enabled == true else {
                return nil
            }
            let origin = current.origin ?? "(0,0)"
            let degree = current.rotation ?? 0

            if current.persistentID == display.persistentID {
                return "id:\(current.persistentID) mode:\(mode.modeNumber) origin:\(origin) degree:\(degree)"
            }

            guard let resolution = current.resolution,
                  let hertz = current.hertz,
                  let colorDepth = current.colorDepth,
                  let scaling = current.scaling else {
                return nil
            }

            return "id:\(current.persistentID) res:\(resolution) hz:\(hertz) color_depth:\(colorDepth) enabled:true scaling:\(scaling) origin:\(origin) degree:\(degree)"
        }

        return try Shell.run(executable, arguments, timeout: 30)
    }

    static func parseList(_ text: String) -> [DisplayInfo] {
        var displays: [DisplayInfo] = []
        var current: DisplayInfo?
        var parsingModes = false

        func finishCurrent() {
            guard let display = current else {
                return
            }
            displays.append(display)
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)

            if line.hasPrefix("Persistent screen id:") {
                finishCurrent()
                parsingModes = false
                let id = value(after: "Persistent screen id:", in: line)
                current = DisplayInfo(
                    persistentID: id,
                    contextualID: nil,
                    serialID: nil,
                    type: "",
                    resolution: nil,
                    hertz: nil,
                    colorDepth: nil,
                    scaling: nil,
                    origin: nil,
                    rotation: nil,
                    enabled: nil,
                    isMain: false,
                    modes: []
                )
                continue
            }

            if line.hasPrefix("Resolutions for rotation") {
                parsingModes = true
                continue
            }

            if parsingModes {
                if let mode = parseMode(line) {
                    current?.modes.append(mode)
                }
                continue
            }

            guard current != nil else {
                continue
            }

            if line.hasPrefix("Contextual screen id:") {
                current?.contextualID = UInt32(value(after: "Contextual screen id:", in: line))
            } else if line.hasPrefix("Serial screen id:") {
                current?.serialID = value(after: "Serial screen id:", in: line)
            } else if line.hasPrefix("Type:") {
                current?.type = value(after: "Type:", in: line)
            } else if line.hasPrefix("Resolution:") {
                current?.resolution = value(after: "Resolution:", in: line)
            } else if line.hasPrefix("Hertz:") {
                current?.hertz = Int(value(after: "Hertz:", in: line))
            } else if line.hasPrefix("Color Depth:") {
                current?.colorDepth = Int(value(after: "Color Depth:", in: line))
            } else if line.hasPrefix("Scaling:") {
                current?.scaling = value(after: "Scaling:", in: line)
            } else if line.hasPrefix("Origin:") {
                let origin = value(after: "Origin:", in: line)
                current?.isMain = origin.contains("main display")
                current?.origin = origin.replacingOccurrences(of: " - main display", with: "")
            } else if line.hasPrefix("Rotation:") {
                current?.rotation = Int(value(after: "Rotation:", in: line))
            } else if line.hasPrefix("Enabled:") {
                current?.enabled = value(after: "Enabled:", in: line).lowercased() == "true"
            }
        }

        finishCurrent()
        return displays
    }

    private static func value(after prefix: String, in line: String) -> String {
        String(line.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
    }

    private static func parseMode(_ line: String) -> DisplayMode? {
        let pattern = #"^mode\s+(\d+):\s+res:(\d+)x(\d+)\s+hz:(\d+)\s+color_depth:(\d+)(?:\s+scaling:(on|off))?(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return nil
        }
        let range = NSRange(line.startIndex..<line.endIndex, in: line)
        guard let match = regex.firstMatch(in: line, range: range), match.numberOfRanges == 7 else {
            return nil
        }

        func capture(_ index: Int) -> String? {
            guard match.range(at: index).location != NSNotFound,
                  let range = Range(match.range(at: index), in: line) else {
                return nil
            }
            return String(line[range])
        }

        guard let modeNumber = capture(1).flatMap(Int.init),
              let width = capture(2).flatMap(Int.init),
              let height = capture(3).flatMap(Int.init) else {
            return nil
        }

        return DisplayMode(
            modeNumber: modeNumber,
            width: width,
            height: height,
            hertz: capture(4).flatMap(Int.init),
            colorDepth: capture(5).flatMap(Int.init),
            scaling: capture(6),
            isCurrent: capture(7)?.contains("current mode") == true,
            coreGraphicsModeID: nil
        )
    }
}

final class HDRController {
    func supports(displayID: UInt32) -> Bool {
        let display = CGDirectDisplayID(displayID)
        return CoreDisplay_Display_SupportsHDRMode(display) || SLSDisplaySupportsHDRMode(display)
    }

    func isEnabled(displayID: UInt32) -> Bool {
        let display = CGDirectDisplayID(displayID)
        return CoreDisplay_Display_IsHDRModeEnabled(display) || SLSDisplayIsHDRModeEnabled(display)
    }

    func setEnabled(_ enabled: Bool, displayID: UInt32) throws {
        let display = CGDirectDisplayID(displayID)
        _ = CoreDisplay_Display_SetHDRModeEnabled(display, enabled)
        _ = SLSDisplaySetHDRModeEnabled(display, enabled)

        Thread.sleep(forTimeInterval: 0.35)

        let changed = CoreDisplay_Display_IsHDRModeEnabled(display) == enabled || SLSDisplayIsHDRModeEnabled(display) == enabled
        let ok = changed
        guard ok else {
            throw NSError(domain: "DisplayBar.HDR", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "macOS did not report the requested HDR state after toggling. The private HDR API can vary between macOS releases."
            ])
        }
    }
}

final class ColorProfileController {
    let helperPath: String

    init(helperPath: String) {
        self.helperPath = helperPath
    }

    func displayProfiles(displayID: UInt32) -> [DisplayColorProfile] {
        guard FileManager.default.isExecutableFile(atPath: helperPath),
              let result = try? Shell.run(helperPath, ["list", "\(displayID)"], timeout: 15),
              result.status == 0 else {
            return []
        }
        return Self.parseDisplayProfiles(result.stdout)
    }

    func installedProfiles() -> [ColorProfileOption] {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let roots = [
            "/System/Library/ColorSync/Profiles",
            "/System/Library/CoreServices/Resources/Profiles",
            "/Library/ColorSync/Profiles",
            "\(home)/Library/ColorSync/Profiles"
        ]

        var byPath: [String: ColorProfileOption] = [:]
        let allowed = Set(["icc", "icm"])

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(atPath: root) else {
                continue
            }
            for case let relative as String in enumerator {
                let ext = (relative as NSString).pathExtension.lowercased()
                guard allowed.contains(ext) else {
                    continue
                }
                let path = (root as NSString).appendingPathComponent(relative)
                guard Self.isDisplayICCProfile(path: path) else {
                    continue
                }
                byPath[path] = ColorProfileOption(name: Self.profileName(path: path), path: path)
            }
        }

        return byPath.values.sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    func setProfile(_ option: ColorProfileOption, displayID: UInt32, profileID: String) throws {
        let result = try Shell.run(helperPath, ["set", "\(displayID)", profileID, option.path], timeout: 20)
        guard result.status == 0 else {
            throw NSError(domain: "DisplayBar.ColorProfile", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: result.combinedOutput.isEmpty ? "ColorSync did not accept the selected profile." : result.combinedOutput
            ])
        }
    }

    func resetProfile(displayID: UInt32, profileID: String) throws {
        let result = try Shell.run(helperPath, ["reset", "\(displayID)", profileID], timeout: 20)
        guard result.status == 0 else {
            throw NSError(domain: "DisplayBar.ColorProfile", code: Int(result.status), userInfo: [
                NSLocalizedDescriptionKey: result.combinedOutput.isEmpty ? "ColorSync did not reset the profile." : result.combinedOutput
            ])
        }
    }

    private static func parseDisplayProfiles(_ text: String) -> [DisplayColorProfile] {
        var profiles: [DisplayColorProfile] = []
        let pattern = #"profile id:(.*?) name:(.*?) default:(true|false) current:(true|false) value:(.*)$"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return profiles
        }

        for rawLine in text.components(separatedBy: .newlines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let range = NSRange(line.startIndex..<line.endIndex, in: line)
            guard let match = regex.firstMatch(in: line, range: range),
                  match.numberOfRanges == 6 else {
                continue
            }

            func capture(_ index: Int) -> String {
                guard let range = Range(match.range(at: index), in: line) else {
                    return ""
                }
                return String(line[range])
            }

            let value = capture(5)
            let path = value == "<factory>" ? nil : value
            let rawName = capture(2).trimmingCharacters(in: .whitespacesAndNewlines)
            let fileName = path.map { profileName(path: $0) }
            let displayName: String
            if rawName.isEmpty {
                displayName = fileName ?? capture(1)
            } else if rawName.hasPrefix("HDMI ") {
                displayName = fileName ?? rawName
            } else {
                displayName = rawName
            }
            profiles.append(DisplayColorProfile(
                profileID: capture(1),
                name: displayName,
                path: path,
                isCurrent: capture(4) == "true",
                isDefault: capture(3) == "true"
            ))
        }

        return profiles
    }

    private static func profileName(path: String) -> String {
        let url = URL(fileURLWithPath: path)
        var unmanagedError: Unmanaged<CFError>?
        guard let unmanagedProfile = ColorSyncProfileCreateWithURL(url as CFURL, &unmanagedError),
              let profile = Optional(unmanagedProfile.takeRetainedValue()),
              let unmanagedDescription = ColorSyncProfileCopyDescriptionString(profile) else {
            return url.deletingPathExtension().lastPathComponent
        }
        let description = unmanagedDescription.takeRetainedValue()
        return description as String
    }

    private static func isDisplayICCProfile(path: String) -> Bool {
        guard let handle = FileHandle(forReadingAtPath: path) else {
            return false
        }
        defer {
            try? handle.close()
        }
        let data = handle.readData(ofLength: 16)
        guard data.count >= 16 else {
            return false
        }
        let signature = String(bytes: data[12..<16], encoding: .ascii)
        return signature == "mntr"
    }
}

enum MenuAction {
    case refresh
    case projection(DisplayProjectionMode)
    case arrangement(DisplayArrangement)
    case openDisplayArrangementSettings
    case enable(DisplayInfo)
    case disable(DisplayInfo)
    case makeMain(DisplayInfo)
    case hdr(DisplayInfo, Bool)
    case displayMode(DisplayInfo, DisplayMode)
    case displayResolution(DisplayInfo, String)
    case displayRefreshRate(DisplayInfo, Int)
    case displayColorDepth(DisplayInfo, Int)
    case displayHiDPI(DisplayInfo, Bool)
    case colorProfile(DisplayInfo, ColorProfileOption)
    case resetColorProfile(DisplayInfo)
    case rescue(DisplayInfo?)
    case quit
}

enum DisplayProjectionMode {
    case extend
    case duplicate
    case mainOnly
    case secondaryOnly

    var title: String {
        switch self {
        case .extend:
            return "扩展"
        case .duplicate:
            return "复制"
        case .mainOnly:
            return "仅主屏"
        case .secondaryOnly:
            return "仅副屏"
        }
    }
}

enum DisplayArrangement {
    case secondaryLeft
    case secondaryRight
    case secondaryAbove
    case secondaryBelow

    var title: String {
        switch self {
        case .secondaryLeft:
            return "副屏在左"
        case .secondaryRight:
            return "副屏在右"
        case .secondaryAbove:
            return "副屏在上"
        case .secondaryBelow:
            return "副屏在下"
        }
    }
}

final class ActionBox: NSObject {
    let action: MenuAction

    init(_ action: MenuAction) {
        self.action = action
    }
}

final class ActionButton: NSButton {
    var menuAction: MenuAction?
}

final class FlippedView: NSView {
    override var isFlipped: Bool {
        true
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate {
    private let statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let popover = NSPopover()
    private let hdr = HDRController()
    private var colorProfiles: ColorProfileController!
    private var displayPlacer: DisplayPlacer!
    private var projectRoot: URL!
    private var onlineDisplays: [DisplayInfo] = []
    private var knownDisplays: [DisplayInfo] = []
    private var localEventMonitor: Any?
    private var globalEventMonitor: Any?

    private let displayplacerPath = ProcessInfo.processInfo.environment["DISPLAYPLACER"] ?? "/opt/homebrew/bin/displayplacer"
    private let knownDisplaysKey = "knownDisplays"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        projectRoot = Self.findProjectRoot()
        displayPlacer = DisplayPlacer(executable: displayplacerPath)
        colorProfiles = ColorProfileController(helperPath: projectRoot.appendingPathComponent("statusbar-tool/build/profilectl").path)

        statusItem.button?.title = "▣"
        statusItem.button?.toolTip = "Display Bar"
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover(_:))
        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self

        loadKnownDisplays()
        refreshDisplays(showErrors: false)
        rebuildMenu()
    }

    @objc private func togglePopover(_ sender: Any?) {
        if popover.isShown {
            popover.performClose(sender)
            return
        }

        refreshDisplays(showErrors: false)
        rebuildPopover()
        guard let button = statusItem.button else {
            return
        }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        startPopoverEventMonitors()
    }

    func popoverDidClose(_ notification: Notification) {
        stopPopoverEventMonitors()
    }

    private func startPopoverEventMonitors() {
        stopPopoverEventMonitors()

        localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] event in
            guard let self else {
                return event
            }
            if self.popover.isShown,
               event.window !== self.popover.contentViewController?.view.window,
               event.window !== self.statusItem.button?.window {
                self.popover.performClose(nil)
            }
            return event
        }

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            DispatchQueue.main.async {
                self?.popover.performClose(nil)
            }
        }
    }

    private func stopPopoverEventMonitors() {
        if let localEventMonitor {
            NSEvent.removeMonitor(localEventMonitor)
            self.localEventMonitor = nil
        }
        if let globalEventMonitor {
            NSEvent.removeMonitor(globalEventMonitor)
            self.globalEventMonitor = nil
        }
    }

    @objc private func handleMenuAction(_ sender: NSMenuItem) {
        guard let box = sender.representedObject as? ActionBox else {
            return
        }
        let action = box.action
        performAction(action)
    }

    @objc private func handleControlAction(_ sender: NSControl) {
        guard let button = sender as? ActionButton,
              let action = button.menuAction else {
            return
        }
        performAction(action)
    }

    @objc private func handlePopUpSelection(_ sender: NSPopUpButton) {
        guard let box = sender.selectedItem?.representedObject as? ActionBox else {
            return
        }
        performAction(box.action)
    }

    private func performAction(_ action: MenuAction) {
        switch action {
        case .refresh:
            refreshDisplays(showErrors: true)
            rebuildMenu()
        case .projection(let mode):
            performProjectionMode(mode)
        case .arrangement(let arrangement):
            performArrangement(arrangement)
        case .openDisplayArrangementSettings:
            openDisplayArrangementSettings()
        case .enable(let display):
            performDisplayEnable(true, display: display)
        case .disable(let display):
            confirmAndDisable(display)
        case .makeMain(let display):
            performMakeMain(display)
        case .hdr(let display, let enabled):
            performHDR(enabled, display: display)
        case .displayMode(let display, let mode):
            performDisplayMode(mode, display: display)
        case .displayResolution(let display, let resolution):
            performDisplayResolution(resolution, display: display)
        case .displayRefreshRate(let display, let hertz):
            performDisplayRefreshRate(hertz, display: display)
        case .displayColorDepth(let display, let colorDepth):
            performDisplayColorDepth(colorDepth, display: display)
        case .displayHiDPI(let display, let enabled):
            performDisplayHiDPI(enabled, display: display)
        case .colorProfile(let display, let option):
            performColorProfile(option, display: display)
        case .resetColorProfile(let display):
            resetColorProfile(display)
        case .rescue(let display):
            performRescue(display)
        case .quit:
            NSApp.terminate(nil)
        }
    }

    private func shouldReopenMenu(after action: MenuAction) -> Bool {
        switch action {
        case .displayMode, .displayResolution, .displayRefreshRate, .displayHiDPI, .hdr:
            return true
        default:
            return false
        }
    }

    private func reopenMenuSoon() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            self?.statusItem.button?.performClick(nil)
        }
    }

    private func rebuildPopover(restoring scrollOrigin: NSPoint? = nil) {
        let contentView = FlippedView()
        contentView.translatesAutoresizingMaskIntoConstraints = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = false
        scrollView.drawsBackground = false

        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 14, bottom: 14, right: 14)
        stack.translatesAutoresizingMaskIntoConstraints = false

        let documentView = FlippedView()
        documentView.translatesAutoresizingMaskIntoConstraints = false
        documentView.addSubview(stack)
        scrollView.documentView = documentView
        contentView.addSubview(scrollView)

        NSLayoutConstraint.activate([
            scrollView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: contentView.topAnchor),
            scrollView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: documentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: documentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: documentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: documentView.bottomAnchor),
            stack.widthAnchor.constraint(equalToConstant: 460),
            documentView.widthAnchor.constraint(equalTo: stack.widthAnchor)
        ])

        addPopoverHeader(to: stack)
        addGlobalPopoverControls(to: stack)

        let displays = visibleDisplays()
        if displays.isEmpty {
            stack.addArrangedSubview(label("没有读到显示器", font: .systemFont(ofSize: 13), color: .secondaryLabelColor))
        } else {
            for display in displays {
                stack.addArrangedSubview(displaySection(for: display))
            }
        }
        addRecoverableDisplays(to: stack)

        let controller = NSViewController()
        controller.view = contentView
        popover.contentViewController = controller
        popover.contentSize = NSSize(width: 488, height: 700)

        if let scrollOrigin {
            DispatchQueue.main.async {
                scrollView.contentView.scroll(to: scrollOrigin)
                scrollView.reflectScrolledClipView(scrollView.contentView)
            }
        }
    }

    private func addPopoverHeader(to stack: NSStackView) {
        let row = horizontalStack(spacing: 8)
        let title = label("DisplayBar", font: .boldSystemFont(ofSize: 16))
        row.addArrangedSubview(title)
        row.addArrangedSubview(flexibleSpace())
        row.addArrangedSubview(actionButton("刷新", action: .refresh))
        row.addArrangedSubview(actionButton("退出", action: .quit))
        stack.addArrangedSubview(row)
    }

    private func addGlobalPopoverControls(to stack: NSStackView) {
        let box = sectionBox()
        let section = verticalStack(spacing: 8)
        box.contentView?.addSubview(section)
        pin(section, to: box.contentView)

        let projection = popUpButton(
            title: "屏幕模式",
            options: [
                ("扩展", .projection(.extend), activeDisplays.count >= 2),
                ("复制", .projection(.duplicate), activeDisplays.count >= 2),
                ("仅主屏", .projection(.mainOnly), activeDisplays.count >= 2),
                ("仅副屏", .projection(.secondaryOnly), activeDisplays.count >= 2)
            ],
            selectedTitle: nil
        )
        section.addArrangedSubview(labeledRow("屏幕模式", control: projection))

        let arrangement = popUpButton(
            title: "屏幕排列",
            options: [
                ("副屏在左", .arrangement(.secondaryLeft), activeDisplays.count >= 2),
                ("副屏在右", .arrangement(.secondaryRight), activeDisplays.count >= 2),
                ("副屏在上", .arrangement(.secondaryAbove), activeDisplays.count >= 2),
                ("副屏在下", .arrangement(.secondaryBelow), activeDisplays.count >= 2)
            ],
            selectedTitle: nil
        )
        section.addArrangedSubview(labeledRow("屏幕排列", control: arrangement))
        section.addArrangedSubview(actionButton("屏幕排列（系统配置）", action: .openDisplayArrangementSettings))

        stack.addArrangedSubview(box)
    }

    private func displaySection(for display: DisplayInfo) -> NSView {
        let box = sectionBox()
        let section = verticalStack(spacing: 8)
        box.contentView?.addSubview(section)
        pin(section, to: box.contentView)

        let titleRow = horizontalStack(spacing: 8)
        titleRow.addArrangedSubview(label(display.title, font: .boldSystemFont(ofSize: 14)))
        titleRow.addArrangedSubview(flexibleSpace())
        if display.online && display.enabled == true && display.isMain == false {
            titleRow.addArrangedSubview(actionButton("设为主屏幕", action: .makeMain(display)))
        }
        section.addArrangedSubview(titleRow)

        if display.detail.isEmpty == false {
            section.addArrangedSubview(label(display.detail, font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        }

        let powerRow = horizontalStack(spacing: 8)
        powerRow.addArrangedSubview(actionButton("开启屏幕", action: .enable(display), enabled: display.online == false || display.enabled != true))
        powerRow.addArrangedSubview(actionButton("关闭屏幕", action: .disable(display), enabled: display.online && enabledDisplayCount > 1))
        if display.online == false && FileManager.default.isExecutableFile(atPath: patchedPath.path) {
            powerRow.addArrangedSubview(actionButton("救援开启", action: .rescue(display)))
        }
        section.addArrangedSubview(powerRow)

        section.addArrangedSubview(label(currentDisplayModeTitle(display), font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
        addDisplayModeControls(for: display, to: section)
        addToggleControls(for: display, to: section)
        addColorControls(for: display, to: section)

        return box
    }

    private func addRecoverableDisplays(to stack: NSStackView) {
        let visibleIDs = Set(visibleDisplays().map(\.persistentID))
        let recoverable = mergedDisplays().filter { display in
            visibleIDs.contains(display.persistentID) == false &&
                (display.online == false || display.enabled != true)
        }
        guard recoverable.isEmpty == false else {
            return
        }

        let box = sectionBox()
        let section = verticalStack(spacing: 8)
        box.contentView?.addSubview(section)
        pin(section, to: box.contentView)
        section.addArrangedSubview(label("已关闭/离线屏幕", font: .boldSystemFont(ofSize: 13)))

        for display in recoverable {
            let row = horizontalStack(spacing: 8)
            row.addArrangedSubview(label(display.title, font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
            row.addArrangedSubview(flexibleSpace())
            row.addArrangedSubview(actionButton("开启", action: .enable(display)))
            if display.online == false && FileManager.default.isExecutableFile(atPath: patchedPath.path) {
                row.addArrangedSubview(actionButton("救援", action: .rescue(display)))
            }
            section.addArrangedSubview(row)
        }

        stack.addArrangedSubview(box)
    }

    private func addDisplayModeControls(for display: DisplayInfo, to section: NSStackView) {
        guard display.online, display.modes.isEmpty == false else {
            section.addArrangedSubview(label("没有模式列表", font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
            return
        }

        let modes = displayModeMenuModes(display.modes)
        let grouped = Dictionary(grouping: modes, by: { $0.resolution })
        let resolutions = grouped.keys.sorted { left, right in
            let lhs = grouped[left]?.first
            let rhs = grouped[right]?.first
            if lhs?.width != rhs?.width {
                return (lhs?.width ?? 0) > (rhs?.width ?? 0)
            }
            return (lhs?.height ?? 0) > (rhs?.height ?? 0)
        }
        let resolutionPopup = popUpButton(
            title: "分辨率",
            options: resolutions.map { ($0, MenuAction.displayResolution(display, $0), true) },
            selectedTitle: display.resolution
        )
        section.addArrangedSubview(labeledRow("分辨率", control: resolutionPopup))

        let currentResolutionModes = modes.filter { $0.resolution == display.resolution }
        let sourceModes = currentResolutionModes.isEmpty ? modes : currentResolutionModes
        let rates = Array(Set(sourceModes.compactMap(\.hertz))).sorted(by: >)
        let refreshPopup = popUpButton(
            title: "刷新率",
            options: rates.map { ("\($0)Hz", MenuAction.displayRefreshRate(display, $0), true) },
            selectedTitle: display.hertz.map { "\($0)Hz" }
        )
        section.addArrangedSubview(labeledRow("刷新率", control: refreshPopup))

        let currentExactModes = modes.filter {
            $0.resolution == display.resolution && $0.hertz == display.hertz
        }
        let colorDepthSourceModes = currentExactModes.isEmpty ? sourceModes : currentExactModes
        let listedColorDepths = Set(colorDepthSourceModes.compactMap(\.colorDepth))
        var colorDepths = listedColorDepths
        if let contextualID = display.contextualID,
           hdr.supports(displayID: contextualID) {
            colorDepths.insert(10)
        }
        let colorDepthPopup = popUpButton(
            title: "颜色位数",
            options: colorDepths.sorted(by: >).map {
                let title = $0 == 10 && listedColorDepths.contains(10) == false ? "10-bit（尝试）" : "\($0)-bit"
                return (title, MenuAction.displayColorDepth(display, $0), true)
            },
            selectedTitle: display.colorDepth.map { "\($0)-bit" }
        )
        section.addArrangedSubview(labeledRow("颜色位数", control: colorDepthPopup))
    }

    private func addToggleControls(for display: DisplayInfo, to section: NSStackView) {
        let row = horizontalStack(spacing: 14)
        let hiDPI = checkbox("HiDPI", checked: display.scaling == "on", action: .displayHiDPI(display, display.scaling != "on"), enabled: display.online && display.resolution != nil && display.hertz != nil)
        row.addArrangedSubview(hiDPI)

        if display.online, let contextualID = display.contextualID, hdr.supports(displayID: contextualID) {
            let enabled = hdr.isEnabled(displayID: contextualID)
            row.addArrangedSubview(checkbox("HDR", checked: enabled, action: .hdr(display, !enabled)))
        } else {
            let hdrLabel = label("HDR 不支持", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
            row.addArrangedSubview(hdrLabel)
        }
        section.addArrangedSubview(row)
    }

    private func addColorControls(for display: DisplayInfo, to section: NSStackView) {
        guard display.online, let contextualID = display.contextualID else {
            section.addArrangedSubview(label("颜色配置：屏幕离线", font: .systemFont(ofSize: 12), color: .secondaryLabelColor))
            return
        }

        let currentProfiles = colorProfiles.displayProfiles(displayID: contextualID)
        let current = currentProfiles.first { $0.isCurrent } ?? currentProfiles.first
        let currentName = displayName(forProfileName: current?.name, path: current?.path)
        let currentValue = label(currentName ?? "未知", font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        section.addArrangedSubview(labeledRow("当前颜色配置", control: currentValue))

        var options = currentProfiles.compactMap { profile -> ColorProfileOption? in
            guard let path = profile.path else {
                return nil
            }
            return ColorProfileOption(
                name: displayName(forProfileName: profile.name, path: path) ?? "未知颜色配置",
                path: path
            )
        }
        if let currentPath = current?.path,
           options.contains(where: { $0.path == currentPath }) == false {
            options.append(ColorProfileOption(
                name: displayName(forProfileName: current?.name, path: currentPath) ?? "当前颜色配置",
                path: currentPath
            ))
        }
        options = Array(Dictionary(grouping: options, by: \.path).compactMap { $0.value.first })
        options.sort {
            if $0.path == current?.path {
                return true
            }
            if $1.path == current?.path {
                return false
            }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        let profilePopup = popUpButton(
            title: "选择颜色配置",
            options: options.map { ($0.name, MenuAction.colorProfile(display, $0), true) },
            selectedTitle: current?.path.flatMap { path in options.first { $0.path == path }?.name } ?? currentName
        )
        section.addArrangedSubview(labeledRow("颜色配置", control: profilePopup))
        section.addArrangedSubview(actionButton("恢复默认颜色配置", action: .resetColorProfile(display), enabled: current != nil))
    }

    private func displayName(forProfileName name: String?, path: String?) -> String? {
        let trimmed = name?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty == false {
            return trimmed
        }

        guard let path, path.isEmpty == false else {
            return nil
        }
        return URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
    }

    private func label(_ text: String, font: NSFont, color: NSColor = .labelColor) -> NSTextField {
        let field = NSTextField(labelWithString: text)
        field.font = font
        field.textColor = color
        field.lineBreakMode = .byTruncatingTail
        return field
    }

    private func horizontalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = spacing
        return stack
    }

    private func verticalStack(spacing: CGFloat) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    private func flexibleSpace() -> NSView {
        let view = NSView()
        view.setContentHuggingPriority(.defaultLow, for: .horizontal)
        return view
    }

    private func sectionBox() -> NSBox {
        let box = NSBox()
        box.boxType = .custom
        box.borderType = .lineBorder
        box.cornerRadius = 8
        box.contentViewMargins = NSSize(width: 10, height: 10)
        box.translatesAutoresizingMaskIntoConstraints = false
        box.widthAnchor.constraint(equalToConstant: 460).isActive = true
        return box
    }

    private func pin(_ child: NSView, to parent: NSView?) {
        guard let parent else {
            return
        }
        child.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            child.leadingAnchor.constraint(equalTo: parent.leadingAnchor),
            child.trailingAnchor.constraint(equalTo: parent.trailingAnchor),
            child.topAnchor.constraint(equalTo: parent.topAnchor),
            child.bottomAnchor.constraint(equalTo: parent.bottomAnchor)
        ])
    }

    private func labeledRow(_ title: String, control: NSView) -> NSStackView {
        let row = horizontalStack(spacing: 8)
        let titleLabel = label(title, font: .systemFont(ofSize: 12), color: .secondaryLabelColor)
        titleLabel.widthAnchor.constraint(equalToConstant: 84).isActive = true
        row.addArrangedSubview(titleLabel)
        row.addArrangedSubview(control)
        control.widthAnchor.constraint(equalToConstant: 340).isActive = true
        return row
    }

    private func actionButton(_ title: String, action: MenuAction, enabled: Bool = true) -> ActionButton {
        let button = ActionButton(title: title, target: self, action: #selector(handleControlAction(_:)))
        button.menuAction = action
        button.isEnabled = enabled
        button.bezelStyle = .rounded
        button.controlSize = .small
        return button
    }

    private func checkbox(_ title: String, checked: Bool, action: MenuAction, enabled: Bool = true) -> ActionButton {
        let button = ActionButton(checkboxWithTitle: title, target: self, action: #selector(handleControlAction(_:)))
        button.menuAction = action
        button.state = checked ? .on : .off
        button.isEnabled = enabled
        return button
    }

    private func popUpButton(title: String, options: [(String, MenuAction, Bool)], selectedTitle: String?) -> NSPopUpButton {
        let popUp = NSPopUpButton()
        popUp.target = self
        popUp.action = #selector(handlePopUpSelection(_:))
        popUp.controlSize = .small

        if options.isEmpty {
            popUp.addItem(withTitle: "无可用选项")
            popUp.isEnabled = false
            return popUp
        }

        for option in options {
            popUp.addItem(withTitle: option.0)
            let item = popUp.lastItem
            item?.representedObject = ActionBox(option.1)
            item?.isEnabled = option.2
        }

        if let selectedTitle,
           let index = options.firstIndex(where: { $0.0 == selectedTitle }) {
            popUp.selectItem(at: index)
        }

        return popUp
    }

    private func refreshDisplays(showErrors: Bool) {
        do {
            let listedDisplays = try displayPlacer.list()
            onlineDisplays = displaysWithCoreGraphicsModes(listedDisplays)
            mergeKnownDisplays(onlineDisplays)
            saveKnownDisplays()
        } catch {
            let fallbackDisplays = displaysWithCoreGraphicsModes([])
            if fallbackDisplays.isEmpty == false {
                onlineDisplays = fallbackDisplays
                mergeKnownDisplays(onlineDisplays)
                saveKnownDisplays()
            } else if showErrors {
                showAlert(title: "刷新失败", message: error.localizedDescription)
            }
        }
    }

    private func displaysWithCoreGraphicsModes(_ listedDisplays: [DisplayInfo]) -> [DisplayInfo] {
        var displays = listedDisplays
        var displayIDs = [CGDirectDisplayID](repeating: 0, count: 32)
        var displayCount: UInt32 = 0
        guard CGGetOnlineDisplayList(UInt32(displayIDs.count), &displayIDs, &displayCount) == .success else {
            return displays
        }

        let onlineIDs = Array(displayIDs.prefix(Int(displayCount)))
        guard onlineIDs.isEmpty == false else {
            return displays
        }

        if displays.isEmpty {
            displays = onlineIDs.map { displayID in
                let cached = knownDisplays.first { $0.contextualID == displayID }
                let currentMode = CGDisplayCopyDisplayMode(displayID)
                let resolution = currentMode.map { "\($0.width)x\($0.height)" } ?? cached?.resolution
                let hertz = currentMode.flatMap(Self.refreshRate) ?? cached?.hertz
                let scaling = currentMode.map(Self.scalingState) ?? cached?.scaling
                return DisplayInfo(
                    persistentID: cached?.persistentID ?? "\(displayID)",
                    contextualID: displayID,
                    serialID: cached?.serialID,
                    type: cached?.type ?? "Display \(displayID)",
                    resolution: resolution,
                    hertz: hertz,
                    colorDepth: cached?.colorDepth ?? 8,
                    scaling: scaling,
                    origin: cached?.origin,
                    rotation: cached?.rotation ?? 0,
                    enabled: true,
                    isMain: CGDisplayIsMain(displayID) != 0,
                    online: true,
                    modes: coreGraphicsModes(for: displayID, currentMode: currentMode, colorDepth: cached?.colorDepth ?? 8)
                )
            }
            return displays
        }

        for index in displays.indices {
            guard let displayID = displays[index].contextualID,
                  onlineIDs.contains(displayID) else {
                continue
            }
            let currentMode = CGDisplayCopyDisplayMode(displayID)
            if let currentMode {
                displays[index].resolution = "\(currentMode.width)x\(currentMode.height)"
                displays[index].hertz = Self.refreshRate(currentMode) ?? displays[index].hertz
                displays[index].scaling = Self.scalingState(currentMode)
            }
            let modes = coreGraphicsModes(for: displayID, currentMode: currentMode, colorDepth: displays[index].colorDepth ?? 8)
            if modes.isEmpty == false {
                displays[index].modes = modes
            }
            displays[index].online = true
            displays[index].enabled = true
            displays[index].isMain = CGDisplayIsMain(displayID) != 0
        }

        return displays
    }

    private func coreGraphicsModes(for displayID: CGDirectDisplayID, currentMode: CGDisplayMode?, colorDepth: Int) -> [DisplayMode] {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return []
        }

        let currentModeID = currentMode.map { Int($0.ioDisplayModeID) }
        var seen: Set<String> = []
        var displayModes: [DisplayMode] = []

        for mode in modes {
            let hertz = Self.refreshRate(mode)
            let scaling = Self.scalingState(mode)
            let modeID = Int(mode.ioDisplayModeID)
            let key = "\(mode.width)x\(mode.height)-\(hertz ?? 0)-\(colorDepth)-\(scaling)-\(modeID)"
            if seen.contains(key) {
                continue
            }
            seen.insert(key)

            displayModes.append(DisplayMode(
                modeNumber: modeID,
                width: mode.width,
                height: mode.height,
                hertz: hertz,
                colorDepth: colorDepth,
                scaling: scaling,
                isCurrent: currentModeID == modeID,
                coreGraphicsModeID: modeID
            ))
        }

        return displayModes
    }

    private static func refreshRate(_ mode: CGDisplayMode) -> Int? {
        let rate = mode.refreshRate
        guard rate > 0 else {
            return nil
        }
        return Int(rate.rounded())
    }

    private static func scalingState(_ mode: CGDisplayMode) -> String {
        mode.pixelWidth > mode.width || mode.pixelHeight > mode.height ? "on" : "off"
    }

    private func rebuildMenu() {
        statusItem.menu = nil
        let activeCount = activeDisplays.count
        statusItem.button?.title = activeCount > 1 ? "▣ \(activeCount)" : "▣"
        if popover.isShown {
            rebuildPopover(restoring: currentPopoverScrollOrigin())
        }
        return

        let menu = NSMenu()

        addItem("刷新", action: .refresh, to: menu)
        addProjectionItems(to: menu)
        addArrangementItems(to: menu)
        if FileManager.default.isExecutableFile(atPath: patchedPath.path) {
            addItem("救援唤醒离线屏幕", action: .rescue(nil), to: menu)
        }

        menu.addItem(.separator())

        let merged = mergedDisplays()
        if merged.isEmpty {
            let empty = NSMenuItem(title: "没有读到显示器", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            menu.addItem(empty)
        } else {
            for display in merged {
                let displayItem = NSMenuItem(title: display.title, action: nil, keyEquivalent: "")
                let submenu = NSMenu()

                let detail = NSMenuItem(title: display.detail.isEmpty ? display.persistentID : display.detail, action: nil, keyEquivalent: "")
                detail.isEnabled = false
                submenu.addItem(detail)
                submenu.addItem(.separator())

                addItem("开启屏幕", action: .enable(display), to: submenu, enabled: display.online == false || display.enabled != true)
                addItem("关闭屏幕", action: .disable(display), to: submenu, enabled: display.online && enabledDisplayCount > 1)
                addItem("设为主屏幕", action: .makeMain(display), to: submenu, enabled: display.online && display.enabled == true && display.isMain == false)

                if display.online == false && FileManager.default.isExecutableFile(atPath: patchedPath.path) {
                    addItem("救援开启这个屏幕", action: .rescue(display), to: submenu)
                }

                submenu.addItem(.separator())
                addDisplayModeItems(for: display, to: submenu)

                submenu.addItem(.separator())
                addHDRItems(for: display, to: submenu)

                submenu.addItem(.separator())
                addColorProfileItems(for: display, to: submenu)

                displayItem.submenu = submenu
                menu.addItem(displayItem)
            }
        }

        menu.addItem(.separator())
        addItem("退出", action: .quit, to: menu)

        statusItem.menu = menu
        statusItem.button?.title = onlineDisplays.count > 1 ? "▣ \(onlineDisplays.count)" : "▣"
    }

    private func currentPopoverScrollOrigin() -> NSPoint? {
        guard let view = popover.contentViewController?.view,
              let scrollView = firstScrollView(in: view) else {
            return nil
        }
        return scrollView.contentView.bounds.origin
    }

    private func firstScrollView(in view: NSView) -> NSScrollView? {
        if let scrollView = view as? NSScrollView {
            return scrollView
        }
        for subview in view.subviews {
            if let scrollView = firstScrollView(in: subview) {
                return scrollView
            }
        }
        return nil
    }

    private func addProjectionItems(to menu: NSMenu) {
        let projectionItem = NSMenuItem(title: "屏幕模式", action: nil, keyEquivalent: "")
        let projectionMenu = NSMenu()
        let hasTwoDisplays = activeDisplays.count >= 2

        addItem("扩展", action: .projection(.extend), to: projectionMenu, enabled: hasTwoDisplays)
        addItem("复制", action: .projection(.duplicate), to: projectionMenu, enabled: hasTwoDisplays)
        projectionMenu.addItem(.separator())
        addItem("仅主屏", action: .projection(.mainOnly), to: projectionMenu, enabled: hasTwoDisplays)
        addItem("仅副屏", action: .projection(.secondaryOnly), to: projectionMenu, enabled: hasTwoDisplays)

        projectionItem.submenu = projectionMenu
        menu.addItem(projectionItem)
    }

    private func addArrangementItems(to menu: NSMenu) {
        let arrangementItem = NSMenuItem(title: "屏幕排列", action: nil, keyEquivalent: "")
        let arrangementMenu = NSMenu()
        let hasTwoDisplays = activeDisplays.count >= 2

        for arrangement in [DisplayArrangement.secondaryLeft, .secondaryRight, .secondaryAbove, .secondaryBelow] {
            addItem(arrangement.title, action: .arrangement(arrangement), to: arrangementMenu, enabled: hasTwoDisplays)
        }
        arrangementMenu.addItem(.separator())
        addItem("屏幕排列（系统配置）", action: .openDisplayArrangementSettings, to: arrangementMenu)

        arrangementItem.submenu = arrangementMenu
        menu.addItem(arrangementItem)
    }

    private func addHDRItems(for display: DisplayInfo, to menu: NSMenu) {
        guard display.online, let contextualID = display.contextualID else {
            let item = NSMenuItem(title: "HDR：屏幕离线", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        guard hdr.supports(displayID: contextualID) else {
            let item = NSMenuItem(title: "HDR：不支持", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let enabled = hdr.isEnabled(displayID: contextualID)
        let item = addItem("HDR", action: .hdr(display, !enabled), to: menu)
        item.state = enabled ? .on : .off
        item.toolTip = enabled ? "点击关闭 HDR" : "点击开启 HDR"
    }

    private func addDisplayModeItems(for display: DisplayInfo, to menu: NSMenu) {
        guard display.online else {
            let item = NSMenuItem(title: "分辨率 / 刷新率：屏幕离线", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let modes = display.modes
        guard modes.isEmpty == false else {
            let item = NSMenuItem(title: "分辨率 / 刷新率：没有模式列表", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let menuModes = displayModeMenuModes(modes)
        let current = modes.first { $0.isCurrent }
        let currentTitle = current.map { "当前模式：\($0.resolution)  \($0.title)" } ?? currentDisplayModeTitle(display)
        let currentItem = NSMenuItem(title: currentTitle, action: nil, keyEquivalent: "")
        currentItem.isEnabled = false
        menu.addItem(currentItem)

        addResolutionItems(for: display, modes: menuModes, to: menu)
        addRefreshRateItems(for: display, modes: menuModes, to: menu)
        addHiDPIItem(for: display, to: menu)
    }

    private func currentDisplayModeTitle(_ display: DisplayInfo) -> String {
        var parts: [String] = []
        if let resolution = display.resolution {
            parts.append(resolution)
        }
        if let hertz = display.hertz {
            parts.append("\(hertz)Hz")
        }
        if let colorDepth = display.colorDepth {
            parts.append("\(colorDepth)-bit")
        }
        if display.scaling == "on" {
            parts.append("HiDPI")
        } else if display.scaling != nil {
            parts.append("标准")
        }
        return parts.isEmpty ? "当前模式：未知" : "当前模式：\(parts.joined(separator: "  "))"
    }

    private func addResolutionItems(for display: DisplayInfo, modes: [DisplayMode], to menu: NSMenu) {
        let item = NSMenuItem(title: "分辨率", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let grouped = Dictionary(grouping: modes, by: { $0.resolution })
        let resolutions = grouped.keys.sorted { left, right in
            let lhs = grouped[left]?.first
            let rhs = grouped[right]?.first
            if lhs?.width != rhs?.width {
                return (lhs?.width ?? 0) > (rhs?.width ?? 0)
            }
            return (lhs?.height ?? 0) > (rhs?.height ?? 0)
        }

        for resolution in resolutions {
            let resolutionItem = addItem(resolution, action: .displayResolution(display, resolution), to: submenu)
            resolutionItem.state = display.resolution == resolution ? .on : .off
            if let mode = bestMode(for: display, resolution: resolution) {
                resolutionItem.toolTip = "保留当前刷新率/HiDPI，displayplacer mode:\(mode.modeNumber)"
            }
        }

        item.submenu = submenu
        menu.addItem(item)
    }

    private func addRefreshRateItems(for display: DisplayInfo, modes: [DisplayMode], to menu: NSMenu) {
        let item = NSMenuItem(title: "刷新率", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        let currentResolutionModes = modes.filter { $0.resolution == display.resolution }
        let sourceModes = currentResolutionModes.isEmpty ? modes : currentResolutionModes
        let rates = Array(Set(sourceModes.compactMap(\.hertz))).sorted(by: >)

        if rates.isEmpty {
            let empty = NSMenuItem(title: "没有刷新率列表", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            submenu.addItem(empty)
        } else {
            for hertz in rates {
                let rateItem = addItem("\(hertz)Hz", action: .displayRefreshRate(display, hertz), to: submenu)
                rateItem.state = display.hertz == hertz ? .on : .off
                if let mode = bestMode(for: display, hertz: hertz) {
                    rateItem.toolTip = "保留当前分辨率/HiDPI，displayplacer mode:\(mode.modeNumber)"
                }
            }
        }

        item.submenu = submenu
        menu.addItem(item)
    }

    private func addHiDPIItem(for display: DisplayInfo, to menu: NSMenu) {
        let hiDPIEnabled = display.scaling == "on"
        let canSetScaling = display.online && display.resolution != nil && display.hertz != nil
        let item = addItem("HiDPI", action: .displayHiDPI(display, !hiDPIEnabled), to: menu, enabled: canSetScaling)
        item.state = hiDPIEnabled ? .on : .off
        item.toolTip = hiDPIEnabled
            ? "点击切换到标准模式，保留当前分辨率/刷新率"
            : "点击开启 HiDPI，保留当前分辨率/刷新率"
    }

    private func displayModeMenuModes(_ modes: [DisplayMode]) -> [DisplayMode] {
        var byKey: [String: DisplayMode] = [:]
        for mode in modes {
            if mode.width < 1024 || mode.height < 536 {
                continue
            }
            let key = "\(mode.width)x\(mode.height)-\(mode.hertz ?? 0)-\(mode.colorDepth ?? 0)-\(mode.scaling ?? "off")"
            if byKey[key]?.isCurrent == true {
                continue
            }
            byKey[key] = mode
        }

        for mode in modes where mode.isCurrent {
            let key = "\(mode.width)x\(mode.height)-\(mode.hertz ?? 0)-\(mode.colorDepth ?? 0)-\(mode.scaling ?? "off")"
            byKey[key] = mode
        }

        return Array(byKey.values)
    }

    private func displayModeSort(_ left: DisplayMode, _ right: DisplayMode) -> Bool {
        if left.hertz != right.hertz {
            return (left.hertz ?? 0) > (right.hertz ?? 0)
        }
        if left.isHiDPI != right.isHiDPI {
            return left.isHiDPI
        }
        return (left.colorDepth ?? 0) > (right.colorDepth ?? 0)
    }

    private func bestMode(for display: DisplayInfo, resolution: String? = nil, hertz: Int? = nil, colorDepth: Int? = nil, hiDPI: Bool? = nil) -> DisplayMode? {
        let targetResolution = resolution ?? display.resolution
        let targetHertz = hertz ?? display.hertz
        let targetColorDepth = colorDepth ?? display.colorDepth
        let targetHiDPI = hiDPI ?? (display.scaling == "on")

        var candidates = displayModeMenuModes(display.modes)
        if let targetResolution {
            candidates = candidates.filter { $0.resolution == targetResolution }
        }
        if let hertz {
            candidates = candidates.filter { $0.hertz == hertz }
        }
        if let colorDepth {
            candidates = candidates.filter { $0.colorDepth == colorDepth }
        }
        if let hiDPI {
            candidates = candidates.filter { $0.isHiDPI == hiDPI }
        }

        return candidates.sorted { left, right in
            modeScore(left, targetHertz: targetHertz, targetColorDepth: targetColorDepth, targetHiDPI: targetHiDPI) >
                modeScore(right, targetHertz: targetHertz, targetColorDepth: targetColorDepth, targetHiDPI: targetHiDPI)
        }.first
    }

    private func modeScore(_ mode: DisplayMode, targetHertz: Int?, targetColorDepth: Int?, targetHiDPI: Bool) -> Int {
        var score = 0
        if mode.hertz == targetHertz {
            score += 10_000
        }
        if mode.colorDepth == targetColorDepth {
            score += 5_000
        }
        if mode.isHiDPI == targetHiDPI {
            score += 1_000
        }
        if mode.isCurrent {
            score += 100
        }
        score += mode.hertz ?? 0
        score += mode.colorDepth ?? 0
        return score
    }

    private func addColorProfileItems(for display: DisplayInfo, to menu: NSMenu) {
        guard display.online, let contextualID = display.contextualID else {
            let item = NSMenuItem(title: "颜色配置：屏幕离线", action: nil, keyEquivalent: "")
            item.isEnabled = false
            menu.addItem(item)
            return
        }

        let currentProfiles = colorProfiles.displayProfiles(displayID: contextualID)
        let current = currentProfiles.first { $0.isCurrent } ?? currentProfiles.first
        let currentTitle = current.map { "当前颜色配置：\($0.name)" } ?? "当前颜色配置：未知"
        let currentItem = NSMenuItem(title: currentTitle, action: nil, keyEquivalent: "")
        currentItem.isEnabled = false
        menu.addItem(currentItem)

        addItem("恢复默认颜色配置", action: .resetColorProfile(display), to: menu, enabled: current != nil)

        let profileMenuItem = NSMenuItem(title: "选择颜色配置", action: nil, keyEquivalent: "")
        let profileMenu = NSMenu()
        let options = colorProfiles.installedProfiles()

        if options.isEmpty {
            let empty = NSMenuItem(title: "没有找到 ICC/ICM 文件", action: nil, keyEquivalent: "")
            empty.isEnabled = false
            profileMenu.addItem(empty)
        } else {
            for option in options {
                let item = addItem(option.name, action: .colorProfile(display, option), to: profileMenu)
                if let currentPath = current?.path, currentPath == option.path {
                    item.state = .on
                }
                item.toolTip = option.path
            }
        }

        profileMenuItem.submenu = profileMenu
        menu.addItem(profileMenuItem)
    }

    @discardableResult
    private func addItem(_ title: String, action: MenuAction, to menu: NSMenu, enabled: Bool = true) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: #selector(handleMenuAction(_:)), keyEquivalent: "")
        item.target = self
        item.representedObject = ActionBox(action)
        item.isEnabled = enabled
        menu.addItem(item)
        return item
    }

    private func performProjectionMode(_ mode: DisplayProjectionMode) {
        guard let pair = displayPair() else {
            showAlert(title: "屏幕模式失败", message: "需要两个在线屏幕。")
            return
        }

        switch mode {
        case .extend:
            performExtendProjection()
        case .duplicate:
            performDuplicateProjection(main: pair.main, secondary: pair.secondary)
        case .mainOnly:
            confirmProjection(mode) {
                self.performSingleDisplayProjection(keep: pair.main, disable: pair.secondary)
            }
        case .secondaryOnly:
            confirmProjection(mode) {
                self.performSingleDisplayProjection(keep: pair.secondary, disable: pair.main)
            }
        }
    }

    private func performArrangement(_ arrangement: DisplayArrangement) {
        guard let pair = displayPair() else {
            showAlert(title: "屏幕排列失败", message: "需要两个在线屏幕。")
            return
        }

        let secondaryOrigin: String
        switch arrangement {
        case .secondaryLeft:
            secondaryOrigin = "(-\(pair.secondary.width ?? 0),146)"
        case .secondaryRight:
            secondaryOrigin = "(\(pair.main.width ?? 1920),0)"
        case .secondaryAbove:
            let x = ((pair.main.width ?? 1920) - (pair.secondary.width ?? 2048)) / 2
            secondaryOrigin = "(\(x),-\(pair.secondary.height ?? 858))"
        case .secondaryBelow:
            let x = ((pair.main.width ?? 1920) - (pair.secondary.width ?? 2048)) / 2
            secondaryOrigin = "(\(x),\(pair.main.height ?? 1080))"
        }

        runDisplayConfiguration(
            title: "屏幕排列",
            arguments: [
                displayConfigArgument(for: pair.main, origin: "(0,0)", forceMain: true),
                displayConfigArgument(for: pair.secondary, origin: secondaryOrigin)
            ]
        )
    }

    private func openDisplayArrangementSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.Displays-Settings.extension") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func performExtendProjection() {
        restoreKnownLayoutAfterEnable()
        Thread.sleep(forTimeInterval: 0.5)
        refreshDisplays(showErrors: false)
        rebuildMenu()
    }

    private func performDuplicateProjection(main: DisplayInfo, secondary: DisplayInfo) {
        let resolution = main.resolution ?? "1920x1080"
        let scaling = main.scaling ?? "on"
        let degree = main.rotation ?? 0
        let mirrorArgument = "id:\(main.persistentID)+\(secondary.persistentID) res:\(resolution) scaling:\(scaling) origin:(0,0) degree:\(degree)"

        runDisplayConfiguration(title: "复制屏幕", arguments: [mirrorArgument])
    }

    private func performSingleDisplayProjection(keep: DisplayInfo, disable: DisplayInfo) {
        runDisplayConfiguration(
            title: "屏幕模式",
            arguments: [
                displayConfigArgument(for: keep, origin: "(0,0)", forceMain: true),
                "id:\(disable.persistentID) enabled:false"
            ]
        )
    }

    private func runDisplayConfiguration(title: String, arguments: [String], afterRefresh: (() -> Void)? = nil) {
        do {
            let result = try Shell.run(displayplacerPath, arguments, timeout: 30)
            Thread.sleep(forTimeInterval: 0.7)
            refreshDisplays(showErrors: false)
            afterRefresh?()
            if result.status != 0 {
                showAlert(title: "\(title)可能未完全生效", message: result.combinedOutput.isEmpty ? "displayplacer 返回非零状态。" : result.combinedOutput)
            }
            rebuildMenu()
        } catch {
            showAlert(title: "\(title)失败", message: error.localizedDescription)
        }
    }

    private func confirmProjection(_ mode: DisplayProjectionMode, action: () -> Void) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "切换到\(mode.title)？"
        alert.informativeText = "这个模式会禁用其中一块屏幕。macOS 重新启用屏幕后可能短暂重排，DisplayBar 会保留救援入口。"
        alert.addButton(withTitle: "切换")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            action()
        }
    }

    private func displayConfigArgument(
        for display: DisplayInfo,
        origin: String,
        forceMain: Bool = false,
        resolutionOverride: String? = nil,
        hertzOverride: Int? = nil,
        colorDepthOverride: Int? = nil,
        scalingOverride: String? = nil
    ) -> String {
        let resolution = resolutionOverride ?? display.resolution ?? "\(display.width ?? 1920)x\(display.height ?? 1080)"
        let hertz = hertzOverride ?? display.hertz ?? 60
        let colorDepth = colorDepthOverride ?? display.colorDepth ?? 8
        let scaling = scalingOverride ?? display.scaling ?? "on"
        let degree = display.rotation ?? 0
        return "id:\(display.persistentID) res:\(resolution) hz:\(hertz) color_depth:\(colorDepth) enabled:true scaling:\(scaling) origin:\(origin) degree:\(degree)"
    }

    private func parseOrigin(_ origin: String?) -> (x: Int, y: Int)? {
        guard let origin else {
            return nil
        }

        let trimmed = origin
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        let parts = trimmed.split(separator: ",")
        guard parts.count == 2,
              let x = Int(parts[0].trimmingCharacters(in: .whitespaces)),
              let y = Int(parts[1].trimmingCharacters(in: .whitespaces)) else {
            return nil
        }
        return (x, y)
    }

    private func performDisplayEnable(_ enabled: Bool, display: DisplayInfo) {
        var outputs: [String] = []

        do {
            if enabled, display.online == false, let contextualID = display.contextualID, FileManager.default.isExecutableFile(atPath: patchedPath.path) {
                let rescueResult = try Shell.run(patchedPath.path, ["id:\(contextualID) enabled:true quiet:true"], timeout: 15)
                if rescueResult.combinedOutput.isEmpty == false {
                    outputs.append(rescueResult.combinedOutput)
                }
                Thread.sleep(forTimeInterval: 0.7)
            }

            let result = try displayPlacer.setEnabled(enabled, display: display)
            if result.combinedOutput.isEmpty == false {
                outputs.append(result.combinedOutput)
            }

            Thread.sleep(forTimeInterval: 0.7)
            refreshDisplays(showErrors: false)

            if displayEnableStateMatches(display, enabled: enabled) {
                if enabled {
                    restoreKnownLayoutAfterEnable()
                    Thread.sleep(forTimeInterval: 0.5)
                    refreshDisplays(showErrors: false)
                }
                rebuildMenu()
                return
            }

            let message = outputs
                .filter { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false }
                .joined(separator: "\n")
            showAlert(
                title: enabled ? "开启屏幕失败" : "关闭屏幕失败",
                message: message.isEmpty ? "命令执行后没有读到目标屏幕状态变化。" : message
            )
        } catch {
            showAlert(title: enabled ? "开启屏幕失败" : "关闭屏幕失败", message: error.localizedDescription)
        }
    }

    private func confirmAndDisable(_ display: DisplayInfo) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "关闭 \(display.title)？"
        alert.informativeText = "关闭后它可能会从 displayplacer 列表里消失。菜单里保留了补丁版救援入口，但这个动作仍建议谨慎使用。"
        alert.addButton(withTitle: "关闭")
        alert.addButton(withTitle: "取消")

        if alert.runModal() == .alertFirstButtonReturn {
            performDisplayEnable(false, display: display)
        }
    }

    private func performMakeMain(_ display: DisplayInfo) {
        let displays = activeDisplays
        guard displays.contains(where: { $0.persistentID == display.persistentID }) else {
            showAlert(title: "设置主屏幕失败", message: "目标屏幕当前不在线。")
            return
        }

        guard let targetOrigin = parseOrigin(display.origin) else {
            showAlert(title: "设置主屏幕失败", message: "没有读到目标屏幕当前位置。")
            return
        }

        let arguments = displays.map { current -> String in
            let currentOrigin = parseOrigin(current.origin) ?? (x: 0, y: 0)
            let translatedOrigin = "(\(currentOrigin.x - targetOrigin.x),\(currentOrigin.y - targetOrigin.y))"
            return displayConfigArgument(for: current, origin: translatedOrigin, forceMain: current.persistentID == display.persistentID)
        }

        runDisplayConfiguration(title: "设置主屏幕", arguments: arguments)
    }

    private func performDisplayResolution(_ resolution: String, display: DisplayInfo) {
        guard let mode = bestMode(for: display, resolution: resolution) else {
            showAlert(title: "分辨率设置失败", message: "没有找到 \(resolution) 对应的可用模式。")
            return
        }

        performDisplayModeWithDisplayPlacer(mode, display: display)
    }

    private func performDisplayRefreshRate(_ hertz: Int, display: DisplayInfo) {
        guard let mode = bestMode(for: display, hertz: hertz) else {
            showAlert(title: "刷新率设置失败", message: "当前分辨率下没有找到 \(hertz)Hz 对应的可用模式。")
            return
        }

        performDisplayModeWithDisplayPlacer(mode, display: display)
    }

    private func performDisplayColorDepth(_ colorDepth: Int, display: DisplayInfo) {
        guard display.online, display.enabled == true else {
            showAlert(title: "颜色位数设置失败", message: "目标屏幕当前不在线。")
            return
        }

        let mode = bestMode(for: display, colorDepth: colorDepth)
        let displays = activeDisplays.isEmpty ? [display] : activeDisplays
        let arguments = displays.map { current -> String in
            if current.persistentID == display.persistentID {
                return displayConfigArgument(
                    for: current,
                    origin: current.origin ?? "(0,0)",
                    forceMain: current.isMain,
                    resolutionOverride: mode?.resolution ?? current.resolution,
                    hertzOverride: mode?.hertz ?? current.hertz,
                    colorDepthOverride: colorDepth,
                    scalingOverride: current.scaling
                )
            }
            return displayConfigArgument(for: current, origin: current.origin ?? "(0,0)", forceMain: current.isMain)
        }

        runDisplayConfiguration(title: "颜色位数", arguments: arguments) { [weak self] in
            guard let self else {
                return
            }
            let updated = self.onlineDisplays.first { $0.persistentID == display.persistentID }
            if updated?.colorDepth != colorDepth {
                let actual = updated?.colorDepth.map { "\($0)-bit" } ?? "未知"
                self.showAlert(
                    title: "\(colorDepth)-bit 未生效",
                    message: "命令已发送，但刷新后系统仍报告 \(actual)。这通常表示 macOS 或当前线缆/刷新率/HDR 组合没有接受这个颜色位数。"
                )
            }
        }
    }

    private func performDisplayModeWithDisplayPlacer(_ mode: DisplayMode, display: DisplayInfo) {
        let displays = activeDisplays.isEmpty ? [display] : activeDisplays
        let arguments = displays.map { current -> String in
            if current.persistentID == display.persistentID {
                return displayConfigArgument(
                    for: current,
                    origin: current.origin ?? "(0,0)",
                    forceMain: current.isMain,
                    resolutionOverride: mode.resolution,
                    hertzOverride: mode.hertz ?? current.hertz,
                    colorDepthOverride: mode.colorDepth ?? current.colorDepth,
                    scalingOverride: current.scaling
                )
            }
            return displayConfigArgument(for: current, origin: current.origin ?? "(0,0)", forceMain: current.isMain)
        }

        runDisplayConfiguration(title: "显示模式", arguments: arguments)
    }

    private func performDisplayHiDPI(_ enabled: Bool, display: DisplayInfo) {
        guard display.online, display.enabled == true else {
            showAlert(title: "HiDPI 设置失败", message: "目标屏幕当前不在线。")
            return
        }

        guard display.resolution != nil, display.hertz != nil else {
            showAlert(title: "HiDPI 设置失败", message: "没有读到当前分辨率或刷新率。")
            return
        }

        let scaling = enabled ? "on" : "off"
        let displays = activeDisplays.isEmpty ? [display] : activeDisplays
        let arguments = displays.map { current -> String in
            displayConfigArgument(
                for: current,
                origin: current.origin ?? "(0,0)",
                forceMain: current.isMain,
                scalingOverride: current.persistentID == display.persistentID ? scaling : nil
            )
        }

        runDisplayConfiguration(title: enabled ? "开启 HiDPI" : "关闭 HiDPI", arguments: arguments)
    }

    private func performDisplayMode(_ mode: DisplayMode, display: DisplayInfo) {
        if let coreGraphicsModeID = mode.coreGraphicsModeID,
           let contextualID = display.contextualID,
           let cgMode = coreGraphicsMode(displayID: contextualID, modeID: coreGraphicsModeID) {
            let error = CGDisplaySetDisplayMode(contextualID, cgMode, nil)
            Thread.sleep(forTimeInterval: 0.5)
            refreshDisplays(showErrors: false)
            if error == .success {
                rebuildMenu()
            } else {
                showAlert(title: "显示模式设置失败", message: "CoreGraphics 返回错误：\(error.rawValue)")
            }
            return
        }

        let currentDisplays = onlineDisplays.isEmpty ? [display] : onlineDisplays

        do {
            let result = try displayPlacer.setMode(mode, for: display, preserving: currentDisplays)
            Thread.sleep(forTimeInterval: 0.7)
            refreshDisplays(showErrors: false)

            if displayModeStateMatches(display, mode: mode) {
                rebuildMenu()
                return
            }

            let message = result.combinedOutput.isEmpty ? "命令执行后没有读到目标模式。macOS 可能选择了最接近的可用模式。" : result.combinedOutput
            showAlert(title: "显示模式设置可能未生效", message: message)
            rebuildMenu()
        } catch {
            showAlert(title: "显示模式设置失败", message: error.localizedDescription)
        }
    }

    private func coreGraphicsMode(displayID: CGDirectDisplayID, modeID: Int) -> CGDisplayMode? {
        let options = [kCGDisplayShowDuplicateLowResolutionModes as String: true] as CFDictionary
        guard let modes = CGDisplayCopyAllDisplayModes(displayID, options) as? [CGDisplayMode] else {
            return nil
        }

        return modes.first { Int($0.ioDisplayModeID) == modeID }
    }

    private func performHDR(_ enabled: Bool, display: DisplayInfo) {
        guard let contextualID = display.contextualID else {
            showAlert(title: "HDR 操作失败", message: "没有读到这个屏幕的 contextual id。")
            return
        }

        do {
            try hdr.setEnabled(enabled, displayID: contextualID)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                self.rebuildMenu()
            }
        } catch {
            showAlert(title: enabled ? "开启 HDR 失败" : "关闭 HDR 失败", message: error.localizedDescription)
        }
    }

    private func performColorProfile(_ option: ColorProfileOption, display: DisplayInfo) {
        guard let contextualID = display.contextualID else {
            showAlert(title: "颜色配置失败", message: "没有读到这个屏幕的 contextual id。")
            return
        }

        let current = colorProfiles.displayProfiles(displayID: contextualID).first { $0.isCurrent } ??
            colorProfiles.displayProfiles(displayID: contextualID).first
        let profileID = current?.profileID ?? "1"

        do {
            try colorProfiles.setProfile(option, displayID: contextualID, profileID: profileID)
        } catch {
            showAlert(title: "颜色配置失败", message: error.localizedDescription)
        }
    }

    private func resetColorProfile(_ display: DisplayInfo) {
        guard let contextualID = display.contextualID else {
            showAlert(title: "颜色配置失败", message: "没有读到这个屏幕的 contextual id。")
            return
        }

        let current = colorProfiles.displayProfiles(displayID: contextualID).first { $0.isCurrent } ??
            colorProfiles.displayProfiles(displayID: contextualID).first
        let profileID = current?.profileID ?? "1"

        do {
            try colorProfiles.resetProfile(displayID: contextualID, profileID: profileID)
        } catch {
            showAlert(title: "颜色配置失败", message: error.localizedDescription)
        }
    }

    private func performRescue(_ display: DisplayInfo?) {
        if let display, let contextualID = display.contextualID {
            do {
                _ = try Shell.run(patchedPath.path, ["id:\(contextualID) enabled:true quiet:true"], timeout: 15)
                Thread.sleep(forTimeInterval: 0.7)
                performDisplayEnable(true, display: display)
            } catch {
                showAlert(title: "救援开启失败", message: error.localizedDescription)
            }
            return
        }

        runProjectScript("scripts/wake-displays-patched.sh", title: "救援唤醒")
    }

    private func runProjectScript(_ relativePath: String, title: String) {
        let script = projectRoot.appendingPathComponent(relativePath).path
        do {
            let result = try Shell.run(script, [], timeout: 60)
            if result.status != 0 {
                showAlert(title: "\(title)失败", message: result.combinedOutput)
            }
            refreshDisplays(showErrors: false)
        } catch {
            showAlert(title: "\(title)失败", message: error.localizedDescription)
        }
    }

    private func restoreKnownLayoutAfterEnable() {
        let restoreScript = projectRoot.appendingPathComponent("scripts/restore-dual.sh").path
        if FileManager.default.isExecutableFile(atPath: restoreScript),
           let result = try? Shell.run(restoreScript, [], timeout: 20),
           result.status == 0,
           knownLayoutIsRestored() {
            return
        }

        _ = try? Shell.run(displayplacerPath, [
            "id:2 res:1920x1080 hz:60 color_depth:8 enabled:true scaling:on origin:(0,0) degree:0",
            "id:3 res:2048x858 hz:60 color_depth:8 enabled:true scaling:on origin:(-2048,146) degree:0"
        ], timeout: 20)
    }

    private func knownLayoutIsRestored() -> Bool {
        guard let displays = try? displayPlacer.list() else {
            return false
        }

        let main = displays.first { $0.persistentID == "643845E2-6FAA-4FD4-9AF4-530EA3C69D8E" }
        let secondary = displays.first { $0.persistentID == "DC01248D-9DAA-4C45-8EA2-E70EE246333A" }

        return main?.origin == "(0,0)" &&
            main?.isMain == true &&
            secondary?.origin == "(-2048,146)" &&
            secondary?.enabled == true
    }

    private var enabledDisplayCount: Int {
        onlineDisplays.filter { $0.enabled == true }.count
    }

    private var activeDisplays: [DisplayInfo] {
        onlineDisplays.filter { $0.online && $0.enabled == true }
    }

    private func displayPair() -> (main: DisplayInfo, secondary: DisplayInfo)? {
        let displays = activeDisplays
        guard displays.count >= 2 else {
            return nil
        }

        let main = displays.first { $0.isMain } ?? displays[0]
        let secondary = displays.first { $0.persistentID != main.persistentID } ?? displays[1]
        return (main, secondary)
    }

    private func displayEnableStateMatches(_ display: DisplayInfo, enabled: Bool) -> Bool {
        let match = onlineDisplays.first {
            $0.persistentID == display.persistentID ||
                (display.contextualID != nil && $0.contextualID == display.contextualID) ||
                (display.serialID != nil && $0.serialID == display.serialID)
        }

        if enabled {
            return match?.enabled == true
        }

        return match == nil || match?.enabled == false
    }

    private func displayModeStateMatches(_ display: DisplayInfo, mode: DisplayMode) -> Bool {
        guard let match = onlineDisplays.first(where: {
            $0.persistentID == display.persistentID ||
                (display.contextualID != nil && $0.contextualID == display.contextualID) ||
                (display.serialID != nil && $0.serialID == display.serialID)
        }) else {
            return false
        }

        return match.modes.contains { $0.modeNumber == mode.modeNumber && $0.isCurrent }
    }

    private var patchedPath: URL {
        projectRoot.appendingPathComponent("bin/displayplacer-patched")
    }

    private func mergedDisplays() -> [DisplayInfo] {
        var byID: [String: DisplayInfo] = [:]
        for display in knownDisplays {
            var offline = display
            offline.online = false
            byID[display.persistentID] = offline
        }
        for display in onlineDisplays {
            byID[display.persistentID] = display
        }
        return byID.values.sorted { left, right in
            if left.isMain != right.isMain {
                return left.isMain
            }
            return left.title < right.title
        }
    }

    private func visibleDisplays() -> [DisplayInfo] {
        let active = activeDisplays
        let displays = active.isEmpty ? onlineDisplays.filter(\.online) : active
        return displays.sorted { left, right in
            if left.isMain != right.isMain {
                return left.isMain
            }
            return left.title < right.title
        }
    }

    private func mergeKnownDisplays(_ displays: [DisplayInfo]) {
        var byID = Dictionary(uniqueKeysWithValues: knownDisplays.map { ($0.persistentID, $0) })
        for display in displays {
            byID[display.persistentID] = display
        }
        knownDisplays = byID.values.sorted { $0.title < $1.title }
    }

    private func loadKnownDisplays() {
        guard let data = UserDefaults.standard.data(forKey: knownDisplaysKey),
              let decoded = try? JSONDecoder().decode([DisplayInfo].self, from: data) else {
            knownDisplays = []
            return
        }
        knownDisplays = decoded
    }

    private func saveKnownDisplays() {
        if let data = try? JSONEncoder().encode(knownDisplays) {
            UserDefaults.standard.set(data, forKey: knownDisplaysKey)
            UserDefaults.standard.synchronize()
        }
    }

    private func showAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = title
        alert.informativeText = message.isEmpty ? "没有更多输出。" : message
        alert.addButton(withTitle: "好")
        alert.runModal()
    }

    private static func findProjectRoot() -> URL {
        if let explicit = ProcessInfo.processInfo.environment["DISPLAY_CONTROL_TOOL_HOME"], explicit.isEmpty == false {
            return URL(fileURLWithPath: explicit)
        }

        let bundleURL = Bundle.main.bundleURL
        if bundleURL.pathExtension == "app" {
            return bundleURL
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
        }

        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
