import Cocoa
import SwiftUI
import ApplicationServices
import ServiceManagement

enum Journal {
    static let directory = FileManager.default.urls(for:.libraryDirectory,in:.userDomainMask)[0].appendingPathComponent("Logs/AgentIsland")
    static let queue = DispatchQueue(label:"AgentIsland.Journal")
    static func write(_ event: String, _ fields: [String:String] = [:]) {
        guard !CommandLine.arguments.contains(where: { $0.hasPrefix("--self-test") }) else { return }
        queue.async {
            let fm = FileManager.default
            try? fm.createDirectory(at:directory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
            let now = Date()
            let stamp = ISO8601DateFormatter().string(from:now)
            for file in (try? fm.contentsOfDirectory(at:directory,includingPropertiesForKeys:[.contentModificationDateKey])) ?? [] where file.pathExtension == "jsonl" {
                if let modified = try? file.resourceValues(forKeys:[.contentModificationDateKey]).contentModificationDate, now.timeIntervalSince(modified) > 7*86400 { try? fm.removeItem(at:file) }
            }
            let file = directory.appendingPathComponent("app-" + String(stamp.prefix(10)) + ".jsonl")
            if ((try? fm.attributesOfItem(atPath:file.path)[.size] as? NSNumber)?.intValue ?? 0) > 2*1024*1024 { return }
            var row = fields; row["time"] = stamp; row["event"] = event
            guard var data = try? JSONSerialization.data(withJSONObject:row,options:.sortedKeys) else { return }
            data.append(10)
            if !fm.fileExists(atPath:file.path) { fm.createFile(atPath:file.path,contents:nil,attributes:[.posixPermissions:0o600]) }
            guard let handle = try? FileHandle(forWritingTo:file) else { return }
            defer { try? handle.close() }
            do { try handle.seekToEnd(); try handle.write(contentsOf:data) } catch {}
        }
    }
}

struct Session: Codable, Identifiable {
    var id: String; var source: String; var status: String; var updated: Double; var project: String; var attention: String? = nil
    var turnStarted: Double? = nil
    var sessionStarted: Double? = nil
    var ended: Double? = nil
    var inputTokens: Int? = nil
    var outputTokens: Int? = nil
    var cachedTokens: Int? = nil
    var totalTokens: Int? = nil
    var noticeText: String? = nil
    var quotaRemaining: Double? = nil
    var title: String? = nil
    var desktopSessionID: String? = nil
    var displayTitle: String { title?.isEmpty == false ? title! : project }
}
struct Quota: Codable, Identifiable {
    var id: String; var provider: String; var label: String
    var remaining: Double; var resetsAt: Double; var updated: Double
}
struct Snapshot: Codable { var sessions: [Session]; var limits: [Quota] }
func tokenNumber(_ value: Int) -> String {
    if value >= 1_000_000 { return String(format:"%.1f млн",Double(value)/1_000_000) }
    if value >= 1_000 { return String(format:"%.1f тыс.",Double(value)/1_000) }
    return String(value)
}
func elapsedTime(_ seconds: Double) -> String {
    let value = max(0,Int(seconds));let hours=value/3600;let minutes=value/60%60
    return hours > 0 ? "\(hours) ч \(minutes) мин" : minutes > 0 ? "\(minutes) мин \(value%60) с" : "\(value) с"
}
func statusColor(_ status: String) -> Color {
    switch status { case "working": return Color(red:124.0/255,green:158.0/255,blue:1); case "waiting": return .orange; case "done": return .green; case "error": return .red; default: return .gray }
}
func label(_ status: String) -> String {
    switch status { case "working": return "В работе"; case "waiting": return "Требует внимания"; case "done": return "Готово"; case "error": return "Ошибка"; case "idle": return "В покое"; case "access": return "Нужен доступ"; default: return "Нет сигнала" }
}
let sources = [("codex-app", "Codex", "Приложение"), ("codex-cli", "Codex", "Терминал"), ("claude-app", "Claude", "Приложение · Code / Cowork"), ("claude-cli", "Claude Code", "Терминал")]

enum Preferences {
    static let defaults: [String:Any] = [
        "notificationsEnabled":true,"notifyWaiting":true,"notifyDone":true,"notifyErrors":true,"notifyQuota":true,
        "notifyCodex":true,"notifyClaude":true,"notificationSound":false,"autoHideNotifications":true,"notificationDelay":7.0,
        "animateLogos":true,"animatePanel":true,"logoSpeed":1.0,"logoSize":14.0,"overlapLogos":true,
        "compactSide":"left","expandedWidth":350.0,"cornerRadius":24.0,"panelShadow":true,
        "showSessions":true,"showTokens":true,"showTime":true,"showQuotas":true,"combineQuotas":true,"showChat":true,"showAccessButton":true,"hideInactive":true,"visibility.codex-app":"active","visibility.codex-cli":"active","visibility.claude-app":"active","visibility.claude-cli":"active","sessionCount":3,
        "closeOnOutsideClick":true
    ]
    static func enabled(_ key: String) -> Bool { UserDefaults.standard.bool(forKey:key) }
    static var signature: String { defaults.keys.sorted().map { "\($0)=\(String(describing:UserDefaults.standard.object(forKey:$0)))" }.joined(separator:";") }
}

final class IslandModel: ObservableObject {
    @Published var sessions: [Session] = []
    @Published var quotas: [Quota] = []
    @Published var expanded = false
    @Published var showingDetails = false
    @Published var displayedAttention: Session? = nil
    var completionSession: Session? = nil
    var quotaNotices: [Session] = []
    var quotaNotice: Session? { quotaNotices.first }
    var dismissedWaiting: Set<String> = []
    var attentionTimer: Timer?
    var timedAttentionID: String?
    var lastSoundID: String?
    @Published var panelWidth: CGFloat = 300
    @Published var panelHeight: CGFloat = 32
    @Published var accessibilityGranted = AXIsProcessTrusted()
    @Published var chatStatus = "unknown"
    @Published var chatDetail = "Claude закрыт"
    @Published var demo = false
    @Published var error: String? = nil
    var process: Process?
    var pipe = Pipe()
    var buffer = Data()
    var timer: Timer?
    var onResize: (() -> Void)?
    var onShowSettings: (() -> Void)?
    var onDemoStart: (() -> Void)?
    var demoTimer: Timer?
    var demoStep = 0
    var latestReal: Snapshot?
    var savedDismissed: Set<String> = []
    var lastWaiting: Set<String> = []
    var axQueue = DispatchQueue(label: "island.accessibility")
    var axBusy = false
    func start() {
        guard let path = Bundle.main.path(forResource: "monitor", ofType: "py") else { error = "Не найден модуль подключения"; return }
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/python3"); p.arguments = [path]
        p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            DispatchQueue.main.async { self?.receive(data) }
        }
        p.terminationHandler = { [weak self] _ in DispatchQueue.main.async { self?.error = "Подключение остановлено. Перезапустите Agent Island." } }
        do { try p.run(); process = p } catch { self.error = "Не удалось запустить подключение: \(error.localizedDescription)" }
        timer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in self?.checkClaude() }
        checkClaude()
    }
    func receive(_ data: Data) {
        buffer.append(data)
        while let end = buffer.firstIndex(of: 10) {
            let line = buffer.prefix(upTo: end); buffer.removeSubrange(...end)
            let snapshot = try? JSONDecoder().decode(Snapshot.self,from:line)
            if let snapshot { latestReal = snapshot }
            else if let list = try? JSONDecoder().decode([Session].self,from:line) { latestReal = Snapshot(sessions:list,limits:quotas) }
            if let list = snapshot?.sessions ?? (try? JSONDecoder().decode([Session].self, from: line)), !demo {
                if let snapshot { checkQuotaThresholds(snapshot.limits); quotas = snapshot.limits }
                let previous = Dictionary(sessions.map { ($0.id,$0.status) },uniquingKeysWith: { _,new in new })
                if let completed = list.first(where: { ["done","error"].contains($0.status) && ["working","waiting"].contains(previous[$0.id] ?? "") }) {
                    if allowsNotice(completed) { completionSession = completed }
                }
                if let completion = completionSession, !list.contains(where: { $0.id == completion.id && $0.status == completion.status }) {
                    completionSession = nil
                }
                for session in list where previous[session.id] != session.status {
                    Journal.write("status_changed",["session":session.id,"source":session.source,"from":previous[session.id] ?? "unseen","to":session.status,"reason":session.attention ?? "source_update"])
                }
                sessions = list
                let waiting = Set(list.filter { $0.status == "waiting" }.map { $0.id })
                dismissedWaiting.formIntersection(waiting)
                lastWaiting = waiting
                onResize?()
            }
        }
    }
    func status(_ source: String) -> String {
        let items = sessions.filter { $0.source == source }
        for state in ["waiting", "working", "error", "done", "idle", "unknown"] {
            if items.contains(where: { $0.status == state }) { return state }
        }
        return "unknown"
    }
    func showsSource(_ source: String) -> Bool {
        if demo { return true }
        let mode = UserDefaults.standard.string(forKey:"visibility." + source) ?? "active"
        switch mode {
        case "hidden": return false
        case "connected": return status(source) != "unknown"
        case "active": return ["working","waiting","error"].contains(status(source))
        default: return true
        }
    }
    var active: Int { sessions.filter { $0.status == "working" }.count + (chatStatus == "working" ? 1 : 0) }
    var codexWorking: Bool { sessions.contains { $0.source.hasPrefix("codex-") && $0.status == "working" } }
    var claudeWorking: Bool { (!demo && chatStatus == "working") || sessions.contains { $0.source.hasPrefix("claude-") && $0.status == "working" } }
    var codexNeedsAttention: Bool { sessions.contains { $0.source.hasPrefix("codex-") && $0.status == "waiting" } }
    var claudeNeedsAttention: Bool { sessions.contains { $0.source.hasPrefix("claude-") && $0.status == "waiting" } }
    var codexVisible: Bool { codexWorking || codexNeedsAttention }
    var claudeVisible: Bool { claudeWorking || claudeNeedsAttention }
    var activityLabel: String {
        var labels: [String] = []
        if codexNeedsAttention { labels.append("Codex требует внимания") }
        else if codexWorking { labels.append("Codex в работе") }
        if claudeNeedsAttention { labels.append("Claude требует внимания") }
        else if claudeWorking { labels.append("Claude в работе") }
        return labels.isEmpty ? "Нет работающих агентов" : labels.joined(separator:"; ")
    }
    var waiting: Int { sessions.filter { $0.status == "waiting" }.count }
    var attentionSession: Session? {
        guard demo || Preferences.enabled("notificationsEnabled") else { return nil }
        if let waiting = sessions.first(where: { $0.status == "waiting" && !dismissedWaiting.contains($0.id) && allowsNotice($0) }) { return waiting }
        if let completionSession, allowsNotice(completionSession) { return completionSession }
        return quotaNotices.first(where: { allowsNotice($0) })
    }
    func allowsNotice(_ session: Session) -> Bool {
        if demo { return true }
        guard Preferences.enabled("notificationsEnabled"), Preferences.enabled(session.source.hasPrefix("codex") ? "notifyCodex" : "notifyClaude") else { return false }
        let key = session.status == "waiting" ? "notifyWaiting" : session.status == "done" ? "notifyDone" : session.status == "error" ? "notifyErrors" : "notifyQuota"
        return Preferences.enabled(key)
    }
    func checkQuotaThresholds(_ limits: [Quota]) {
        for quota in limits where quota.resetsAt > Date().timeIntervalSince1970 {
            let key = "quota-threshold-v2:" + quota.id
            let step = [90.0,80,70,60,50,40,30,25,20,15,10,5,0].filter { quota.remaining <= $0 }.count
            let saved = UserDefaults.standard.dictionary(forKey:key)
            let sameWindow = (saved?["reset"] as? Double) == quota.resetsAt
            let previous = sameWindow ? (saved?["step"] as? Int) : nil
            if let previous, step > previous, Preferences.enabled("notificationsEnabled"), Preferences.enabled("notifyQuota"), Preferences.enabled(quota.provider == "codex" ? "notifyCodex" : "notifyClaude") {
                quotaNotices.append(Session(id:key + ":" + String(step),source:quota.provider + "-app",status:"quota",updated:quota.updated,project:(quota.provider == "codex" ? "Codex" : "Claude") + " · " + quota.label,attention:"quota",noticeText:String(format:"Осталось %.0f%% лимита",quota.remaining),quotaRemaining:quota.remaining))
            }
            UserDefaults.standard.set(["reset":quota.resetsAt,"step":max(step,previous ?? step)],forKey:key)
        }
    }
    func scheduleAttentionDismissal() {
        let next = expanded ? nil : attentionSession
        let key = next.map { $0.id + ":" + $0.status }
        guard key != timedAttentionID else { return }
        attentionTimer?.invalidate()
        timedAttentionID = key
        guard let next else { return }
        let nextID = next.id
        if key != lastSoundID {
            lastSoundID = key
            if Preferences.enabled("notificationSound") { NSSound(named:"Pop")?.play() }
        }
        guard Preferences.enabled("autoHideNotifications") else { return }
        let savedDelay = UserDefaults.standard.double(forKey:"notificationDelay")
        let delay = savedDelay > 0 ? savedDelay : 7
        attentionTimer = Timer.scheduledTimer(withTimeInterval:delay,repeats:false) { [weak self] _ in
            guard let self, !self.expanded else { return }
            if next.status == "quota" { self.quotaNotices.removeAll { $0.id == nextID } }
            else if ["done","error"].contains(next.status) { self.completionSession = nil }
            else { self.dismissedWaiting.insert(nextID) }
            self.onResize?()
        }
    }
    func dismissAttention() {
        quotaNotices.removeAll()
        completionSession = nil
        dismissedWaiting.formUnion(sessions.filter { $0.status == "waiting" }.map { $0.id })
        onResize?()
    }
    func toggle() { expanded.toggle(); onResize?() }
    func prepareDemo() {
        if !demo {
            latestReal = Snapshot(sessions:sessions,limits:quotas)
            savedDismissed = dismissedWaiting
        }
        demoTimer?.invalidate(); demoTimer = nil
        attentionTimer?.invalidate(); timedAttentionID = nil
        completionSession = nil; quotaNotices.removeAll(); dismissedWaiting.removeAll()
        demo = true; expanded = false
        onDemoStart?()
    }
    func stopDemo() {
        demoTimer?.invalidate(); demoTimer = nil
        attentionTimer?.invalidate(); timedAttentionID = nil
        completionSession = nil; quotaNotices.removeAll()
        demo = false; expanded = false
        sessions = latestReal?.sessions ?? []
        quotas = latestReal?.limits ?? []
        dismissedWaiting = savedDismissed.intersection(Set(sessions.filter { $0.status == "waiting" }.map { $0.id }))
        onResize?()
    }
    func sample(_ id: String,_ source: String,_ status: String,_ title: String) -> Session {
        var item = Session(id:id,source:source,status:status,updated:Date().timeIntervalSince1970,project:"Демо-проект")
        item.title = title; item.turnStarted = Date().timeIntervalSince1970 - 45
        item.totalTokens = 18400; item.inputTokens = 15000; item.outputTokens = 3400; item.cachedTokens = 10000
        return item
    }
    func previewCompletion() {
        prepareDemo()
        sessions = [sample("preview-done","codex-app","done","Пример завершения")]
        completionSession = sessions.first
        onResize?()
    }
    func previewAttention() {
        prepareDemo()
        var item = sample("preview-attention","claude-cli","waiting","Пример запроса разрешения")
        item.attention = "permission";sessions = [item]
        onResize?()
    }
    func setDemo() {
        if demo { stopDemo(); return }
        prepareDemo()
        sessions = [sample("demo1","codex-app","working","Собрать главную страницу"),sample("demo2","claude-cli","working","Проверить изменения")]
        let now = Date().timeIntervalSince1970
        quotas = [Quota(id:"demo-quota",provider:"codex",label:"Неделя",remaining:20,resetsAt:now+86400,updated:now)]
        demoStep = 0; applyDemoStep()
        demoTimer = Timer.scheduledTimer(withTimeInterval:3,repeats:true) { [weak self] _ in
            guard let self else { return }
            self.demoStep += 1; self.applyDemoStep()
        }
    }
    func applyDemoStep() {
        attentionTimer?.invalidate();timedAttentionID = nil
        switch demoStep {
        case 0: expanded = false
        case 1: expanded = true
        case 2:
            sessions[1].status = "waiting";sessions[1].attention = "permission"
        case 3: expanded = false
        case 4:
            sessions[1].status = "working";dismissedWaiting.removeAll();expanded = false
        case 5:
            sessions[0].status = "done";completionSession = sessions[0]
        case 6:
            completionSession = nil
            var notice = sample("demo-limit","codex-app","quota","Недельный лимит")
            notice.quotaRemaining = 20; notice.noticeText = "Осталось 20% лимита";quotaNotices = [notice]
        case 7:
            quotaNotices.removeAll();sessions[1].status = "error";completionSession = sessions[1]
        case 8:
            completionSession = nil;sessions[1].status = "done";expanded = true
        case 9:
            completionSession = nil; quotaNotices.removeAll(); expanded = true
            let titles = ["Обновить профиль", "Проверить оплату", "Исправить поиск", "Подготовить отчёт", "Собрать настройки", "Написать тесты", "Обновить документацию", "Проверить уведомления", "Ускорить загрузку", "Добавить фильтры", "Проверить вёрстку", "Настроить авторизацию"]
            sessions = titles.enumerated().map { index, title in
                var item = sample("demo-many-\(index)",sources[index % sources.count].0,["working","waiting","done","idle"][index % 4],title)
                item.project = ["website","mobile-app","dashboard"][index % 3]
                item.turnStarted = Date().timeIntervalSince1970 - Double((index + 1) * 73)
                if item.status == "done" { item.ended = Date().timeIntervalSince1970 }
                return item
            }
        case 10...12: break
        default: stopDemo();return
        }
        onResize?()
    }
    func checkClaude() {
        let granted = AXIsProcessTrusted()
        if accessibilityGranted != granted { accessibilityGranted = granted; onResize?() }
        guard !axBusy else { return }
        guard let app = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == "com.anthropic.claudefordesktop" }) else {
            chatStatus = "idle"; chatDetail = "Claude закрыт"; return
        }
        guard AXIsProcessTrusted() else { chatStatus = "access"; chatDetail = "Разрешите доступность для обычного чата"; return }
        axBusy = true
        let pid = app.processIdentifier
        axQueue.async { [weak self] in
            let root = AXUIElementCreateApplication(pid)
            AXUIElementSetMessagingTimeout(root, 0.2)
            var count = 0
            var generating = false
            func walk(_ node: AXUIElement, _ depth: Int) {
                guard depth < 22, count < 600, !generating else { return }; count += 1
                var role: CFTypeRef?
                AXUIElementCopyAttributeValue(node,kAXRoleAttribute as CFString,&role)
                if (role as? String) == "AXButton" {
                    for key in [kAXTitleAttribute,kAXDescriptionAttribute,kAXHelpAttribute] {
                        var value: CFTypeRef?; AXUIElementCopyAttributeValue(node,key as CFString,&value)
                        let text = (value as? String ?? "").lowercased()
                        if ["stop response", "stop generating", "stop streaming", "остановить ответ", "остановить генерацию"].contains(where: { text.contains($0) }) { generating = true }
                    }
                }
                var children: CFTypeRef?
                if AXUIElementCopyAttributeValue(node,kAXChildrenAttribute as CFString,&children) == .success, let list = children as? [AXUIElement] { for child in list { walk(child,depth+1) } }
            }
            walk(root,0)
            DispatchQueue.main.async {
                self?.axBusy = false
                self?.chatStatus = generating ? "working" : "unknown"
                self?.chatDetail = generating ? "Генерирует ответ в открытом окне" : "В открытом окне генерация не обнаружена"
            }
        }
    }
    func requestAccess() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }
    func openSession(_ session: Session) {
        guard !demo else { return }
        Journal.write("open_session",["session":session.id,"source":session.source,"accessibility":String(AXIsProcessTrusted())])
        var target: URL?
        if session.source.hasPrefix("codex"), UUID(uuidString:session.id) != nil {
            target = URL(string:"codex://threads/" + session.id)
        } else if session.source == "claude-app", let local = session.desktopSessionID,
                  local.hasPrefix("local_"), UUID(uuidString:String(local.dropFirst(6))) != nil {
            target = URL(string:"claude://claude.ai/cowork/" + local)
        }
        if let target, NSWorkspace.shared.open(target) {
            Journal.write("deeplink_dispatched",["session":session.id])
            expanded = false; onResize?(); return
        }
        if session.source.hasSuffix("cli"), AXIsProcessTrusted() {
            var windows: [(NSRunningApplication, AXUIElement)] = []
            var tabs: [(NSRunningApplication, AXUIElement)] = []
            var menuItems: [(NSRunningApplication, AXUIElement)] = []
            func attribute(_ element: AXUIElement, _ key: String) -> CFTypeRef? {
                var value: CFTypeRef?
                AXUIElementCopyAttributeValue(element,key as CFString,&value)
                return value
            }
            func matchesTitle(_ title: String) -> Bool {
                if title.contains(session.id) { return true }
                guard let name = session.title, !name.isEmpty else { return false }
                func normalized(_ value: String) -> String {
                    let cleaned = String(value.unicodeScalars.filter { !CharacterSet.nonBaseCharacters.contains($0) && !CharacterSet.controlCharacters.contains($0) })
                    let trim = CharacterSet.alphanumerics.inverted
                    return cleaned.trimmingCharacters(in:trim).precomposedStringWithCanonicalMapping
                }
                return normalized(title).localizedCaseInsensitiveCompare(normalized(name)) == .orderedSame
            }
            for app in NSWorkspace.shared.runningApplications where ["com.googlecode.iterm2","com.apple.Terminal","com.mitchellh.ghostty"].contains(app.bundleIdentifier ?? "") {
                let root = AXUIElementCreateApplication(app.processIdentifier)
                AXUIElementSetMessagingTimeout(root,0.2)
                let appWindows = attribute(root,kAXWindowsAttribute) as? [AXUIElement] ?? []
                for window in appWindows {
                    if matchesTitle(attribute(window,kAXTitleAttribute) as? String ?? "") { windows.append((app,window)) }
                }
                var openedMenus: [AXUIElement] = []
                var queue = appWindows.map { ($0,0) }
                if let menu = attribute(root,kAXMenuBarAttribute) {
                    let menuBar = menu as! AXUIElement
                    // Native window menus can populate lazily when opened.
                    for item in attribute(menuBar,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                        let name = attribute(item,kAXTitleAttribute) as? String ?? ""
                        if ["Window","Окно"].contains(name) {
                            if AXUIElementPerformAction(item,kAXPressAction as CFString) == .success { openedMenus.append(item) }
                        }
                    }
                    queue.append((menuBar,0))
                }
                var visited = 0
                while !queue.isEmpty && visited < 500 {
                    let (element,depth) = queue.removeFirst(); visited += 1
                    let role = attribute(element,kAXRoleAttribute) as? String ?? ""
                    // Never read terminal contents or send keystrokes to a shell.
                    if ["AXTextArea","AXTextField","AXWebArea"].contains(role) { continue }
                    if ["AXRadioButton","AXTab","AXMenuItem","AXButton"].contains(role) {
                        let title = attribute(element,kAXTitleAttribute) as? String ?? ""
                        let description = attribute(element,kAXDescriptionAttribute) as? String ?? ""
                        let value = attribute(element,kAXValueAttribute) as? String ?? ""
                        if matchesTitle(title) || matchesTitle(description) || matchesTitle(value) {
                            if role == "AXMenuItem" { menuItems.append((app,element)) }
                            else { tabs.append((app,element)) }
                        }
                    }
                    if depth < 12 {
                        queue += (attribute(element,kAXChildrenAttribute) as? [AXUIElement] ?? []).map { ($0,depth+1) }
                    }
                }
                for item in openedMenus {
                    for menu in attribute(item,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                        AXUIElementPerformAction(menu,kAXCancelAction as CFString)
                    }
                }
            }
            // Window-menu entries select a native tab even when it is not the
            // currently visible tab in its window group.
            let candidates = !menuItems.isEmpty ? menuItems : !tabs.isEmpty ? tabs : windows
            Journal.write("terminal_candidates",["session":session.id,"windows":String(windows.count),"tabs":String(tabs.count),"menuItems":String(menuItems.count)])
            if candidates.count == 1 {
                let (app,element) = candidates[0]
                let isWindow = menuItems.isEmpty && tabs.isEmpty
                app.activate()
                DispatchQueue.main.asyncAfter(deadline:.now() + 0.2) { [weak self] in
                    guard let self else { return }
                    if isWindow {
                        AXUIElementSetAttributeValue(element,kAXMinimizedAttribute as CFString,kCFBooleanFalse)
                        AXUIElementSetAttributeValue(element,kAXMainAttribute as CFString,kCFBooleanTrue)
                    } else if menuItems.isEmpty, let window = attribute(element,kAXWindowAttribute) {
                        AXUIElementPerformAction(window as! AXUIElement,kAXRaiseAction as CFString)
                    }
                    var selectedElement = element
                    if !menuItems.isEmpty {
                        let root = AXUIElementCreateApplication(app.processIdentifier)
                        var freshMatches: [AXUIElement] = []
                        if let bar = attribute(root,kAXMenuBarAttribute) {
                            for item in attribute(bar as! AXUIElement,kAXChildrenAttribute) as? [AXUIElement] ?? [] {
                                guard ["Window","Окно"].contains(attribute(item,kAXTitleAttribute) as? String ?? "") else { continue }
                                AXUIElementPerformAction(item,kAXPressAction as CFString)
                                var pending = attribute(item,kAXChildrenAttribute) as? [AXUIElement] ?? []
                                var count = 0
                                while !pending.isEmpty && count < 150 {
                                    let child = pending.removeFirst(); count += 1
                                    if attribute(child,kAXRoleAttribute) as? String == "AXMenuItem",
                                       matchesTitle(attribute(child,kAXTitleAttribute) as? String ?? "") {
                                        freshMatches.append(child)
                                    }
                                    pending += attribute(child,kAXChildrenAttribute) as? [AXUIElement] ?? []
                                }
                            }
                        }
                        guard freshMatches.count == 1 else {
                            self.error = nil
                            self.onResize?(); return
                        }
                        selectedElement = freshMatches[0]
                    }
                    let result = AXUIElementPerformAction(selectedElement,(isWindow ? kAXRaiseAction : kAXPressAction) as CFString)
                    DispatchQueue.main.asyncAfter(deadline:.now() + 0.25) {
                        let root = AXUIElementCreateApplication(app.processIdentifier)
                        let focused = attribute(root,kAXFocusedWindowAttribute)
                        let title = focused.flatMap { attribute($0 as! AXUIElement,kAXTitleAttribute) as? String } ?? ""
                        Journal.write("terminal_selection",["session":session.id,"result":String(result.rawValue),"confirmed":String(matchesTitle(title))])
                        if result == .success && matchesTitle(title) {
                            self.error = nil; self.expanded = false
                        } else {
                            self.error = nil
                        }
                        self.onResize?()
                    }
                }
                return
            }
            error = nil
        } else {
            error = nil
        }
        onResize?()
    }

    func openApp(_ source: String) {
        let id = source.contains("claude") ? "com.anthropic.claudefordesktop" : "com.openai.codex"
        if source.hasSuffix("cli") {
            if let app = NSWorkspace.shared.runningApplications.first(where: { ["com.googlecode.iterm2","com.apple.Terminal","com.mitchellh.ghostty"].contains($0.bundleIdentifier ?? "") }) { app.activate(); return }
            if let terminal = NSWorkspace.shared.urlForApplication(withBundleIdentifier:"com.apple.Terminal") { NSWorkspace.shared.openApplication(at:terminal,configuration:.init()) }
            return
        }
        if let app = NSWorkspace.shared.runningApplications.first(where: { ($0.bundleIdentifier ?? "").lowercased().contains(source.contains("claude") ? "claude" : "codex") }) { app.activate(); return }
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: id) { NSWorkspace.shared.openApplication(at: url, configuration: .init()) }
    }
}

struct ActivityLight: View {
    var status: String
    var size: CGFloat = 7
    var body: some View {
        Circle().fill(statusColor(status))
            .frame(width:size,height:size)
            .frame(width:size + 6,height:size + 6)
            .accessibilityHidden(true)
    }
}

enum BrandIcons {
    static let codex = load("openai")
    static let claude = load("claude")
    private static func load(_ name: String) -> NSImage {
        guard let url = Bundle.main.url(forResource:name,withExtension:"svg"),
              let image = NSImage(contentsOf:url) else { return NSImage(size:NSSize(width:24,height:24)) }
        return image
    }
}

struct WorkingLogo: View {
    @AppStorage("animateLogos") private var animateLogos = true
    @AppStorage("logoSpeed") private var logoSpeed = 1.0
    @AppStorage("logoSize") private var logoSize = 14.0
    let image: NSImage
    let rays: Bool
    var needsAttention = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var body: some View {
        TimelineView(.animation(minimumInterval:1.0 / 30,paused:reduceMotion || !animateLogos)) { context in
            let duration = needsAttention ? 2.2 : (rays ? 4.3 : 10.0) / logoSpeed
            let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy:duration) / duration
            let attentionLift: Double = needsAttention && !reduceMotion && animateLogos
                ? (phase < 0.22 ? sin(phase / 0.22 * .pi) * 5.0
                   : phase < 0.40 ? sin((phase - 0.22) / 0.18 * .pi) * 2.5 : 0) : 0
            Canvas { canvas, size in
                let logo = canvas.resolve(Image(nsImage:image))
                let rect = CGRect(x:1,y:1,width:14,height:14)
                if reduceMotion || !animateLogos {
                    canvas.draw(logo,in:rect)
                } else if needsAttention {
                    canvas.draw(logo,in:rect)
                } else if !rays {
                    canvas.translateBy(x:8,y:8)
                    canvas.rotate(by:.degrees(phase * 360))
                    canvas.draw(logo,in:CGRect(x:-7,y:-7,width:14,height:14))
                } else {
                    // Move narrow sections of the original vector mark. Color and overall size stay fixed.
                    let progress = min(1,phase / 0.72)
                    let envelope = pow(sin(progress * .pi),2)
                    for index in 0..<32 {
                        let coordinate = Double(index) / 31
                        let displacement = sin(coordinate * .pi * 2 - progress * .pi * 2) * envelope * 0.9
                        var strip = canvas
                        if rays {
                            strip.clip(to:Path(CGRect(x:CGFloat(index) * 0.5,y:0,width:0.5,height:16)))
                            strip.translateBy(x:0,y:displacement)
                        } else {
                            strip.clip(to:Path(CGRect(x:0,y:CGFloat(index) * 0.5,width:16,height:0.5)))
                            strip.translateBy(x:displacement,y:0)
                        }
                        strip.draw(logo,in:rect)
                    }
                }
            }.frame(width:16,height:16).offset(y:-attentionLift)
        }.frame(width:14,height:14).scaleEffect(logoSize / 14).frame(width:logoSize,height:logoSize)
        .overlay(alignment:.bottomTrailing) {
            if needsAttention { Circle().fill(.orange).frame(width:5,height:5).offset(x:1,y:1) }
        }
    }
}

struct AttentionView: View {
    @ObservedObject var model: IslandModel
    let session: Session
    var body: some View {
        HStack(spacing:12) {
            Image(nsImage:session.source.hasPrefix("codex") ? BrandIcons.codex : BrandIcons.claude)
                .resizable().frame(width:22,height:22)
            VStack(alignment:.leading,spacing:4) {
                Text(session.status == "quota" ? (model.demo ? "Пример · лимит подписки" : "Лимит подписки") : session.status == "error" ? (model.demo ? "Пример · ошибка агента" : "Агент сообщил об ошибке") : session.status == "done" ? (model.demo ? "Пример · ответ готов" : (session.source.hasPrefix("codex") ? "Codex · ответ готов" : "Claude · ответ готов")) : (model.demo ? "Пример · нужен ваш ответ" : (session.source.hasPrefix("codex") ? "Codex ждёт вас" : "Claude ждёт вас")))
                    .font(.system(size:13,weight:.semibold))
                Text(session.status == "quota" ? (session.noticeText ?? "Лимит обновился") : session.status == "error" ? "Откройте сеанс для подробностей" : session.status == "done" ? "Можно посмотреть результат" : (session.attention == "permission" ? "Нужно разрешение на действие" : "Нужен ответ или подтверждение"))
                    .font(.system(size:11)).foregroundStyle(session.status == "done" ? Color.green : session.status == "quota" && (session.quotaRemaining ?? 100) <= 10 ? Color.red : Color.orange)
                Text(session.displayTitle).font(.system(size:10)).foregroundStyle(.gray).lineLimit(1)
            }
            Spacer(minLength:0)
            if !model.demo {
                Button("Открыть") { model.openApp(session.source) }
                    .buttonStyle(.bordered).font(.system(size:11))
            }
            Button {
                if model.demo { model.setDemo() } else { model.dismissAttention() }
            } label: {
                Image(systemName:"xmark").font(.system(size:9,weight:.semibold)).foregroundStyle(.gray)
            }.buttonStyle(.plain).help("Скрыть это уведомление")
        }
        .padding(.horizontal,16).padding(.top,10).padding(.bottom,18)
    }
}

struct IslandSettings: View {
    @ObservedObject var model: IslandModel
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("Основные",systemImage:"gearshape") }
            NotificationSettings(model:model).tabItem { Label("Уведомления",systemImage:"bell") }
            AppearanceSettings().tabItem { Label("Внешний вид",systemImage:"paintbrush") }
            DataSettings(model:model).tabItem { Label("Панель",systemImage:"slider.horizontal.3") }
        }.padding(16).frame(width:490,height:525).preferredColorScheme(.dark)
    }
}
struct GeneralSettings: View {
    @State private var enabled = SMAppService.mainApp.status == .enabled
    @State private var message: String?
    var body: some View {
        Form {
            Section("Запуск") {
                Toggle("Запускать при входе в macOS",isOn:Binding(get:{enabled},set:{ value in
                    do {
                        if value { try SMAppService.mainApp.register() }
                        else { try SMAppService.mainApp.unregister() }
                        enabled = SMAppService.mainApp.status == .enabled
                        message = nil
                    } catch { message = "Не удалось изменить автозапуск: " + error.localizedDescription }
                }))
                if SMAppService.mainApp.status == .requiresApproval {
                    Button("Разрешить в настройках macOS") { SMAppService.openSystemSettingsLoginItems() }
                }
                if let message { Text(message).font(.caption).foregroundStyle(.orange) }
            }
            Section("Диагностика") {
                Button("Открыть логи") {
                    try? FileManager.default.createDirectory(at:Journal.directory,withIntermediateDirectories:true)
                    NSWorkspace.shared.open(Journal.directory)
                }
                Text("Хранятся 7 дней. Только технические события и ID сеансов — без переписки, названий проектов и ключей. До 2 МБ в сутки на журнал.").font(.caption).foregroundStyle(.secondary)
            }
            Section("Приложение") {
                Button("Выйти из Agent Island") { NSApp.terminate(nil) }
                Text("Выход завершает приложение сейчас. Чтобы оно не запускалось при следующем входе, отключите автозапуск выше.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped)
        .onReceive(NotificationCenter.default.publisher(for:NSApplication.didBecomeActiveNotification)) { _ in
            enabled = SMAppService.mainApp.status == .enabled
        }
    }
}
struct NotificationSettings: View {
    @ObservedObject var model: IslandModel
    @AppStorage("notificationsEnabled") private var enabled = true
    @AppStorage("notifyWaiting") private var waiting = true
    @AppStorage("notifyDone") private var done = true
    @AppStorage("notifyErrors") private var errors = true
    @AppStorage("notifyQuota") private var quota = true
    @AppStorage("notifyCodex") private var codex = true
    @AppStorage("notifyClaude") private var claude = true
    @AppStorage("notificationSound") private var sound = false
    @AppStorage("autoHideNotifications") private var autoHide = true
    @AppStorage("notificationDelay") private var delay = 7.0
    var body: some View {
        Form {
            Toggle("Показывать уведомления",isOn:$enabled)
            Section("События") {
                Toggle("Нужен ответ или разрешение",isOn:$waiting)
                Toggle("Ответ готов",isOn:$done)
                Toggle("Ошибка агента",isOn:$errors)
                Toggle("Расход лимита подписки",isOn:$quota)
                Text("Уведомления на остатке 90%, 80%…30%, затем 25%, 20%, 15%, 10%, 5% и 0%. При скачке — одно уведомление с актуальным остатком.").font(.caption).foregroundStyle(.secondary)
                Text("Цвет остатка: 25% и ниже — жёлтый; 10% и ниже — красный.").font(.caption).foregroundStyle(.secondary)
            }.disabled(!enabled)
            Section("От кого") {
                HStack { Toggle("Codex",isOn:$codex); Toggle("Claude",isOn:$claude) }
            }.disabled(!enabled)
            Section("Поведение") {
                Toggle("Звук при появлении",isOn:$sound)
                Toggle("Скрывать автоматически",isOn:$autoHide)
                Picker("Через",selection:$delay) {
                    ForEach([3,5,7,10,15,30],id:\.self) { Text("\($0) секунд").tag(Double($0)) }
                }.disabled(!autoHide)
            }.disabled(!enabled)
            Section("Проверить") {
                HStack {
                    Button("Нужен ответ") { model.previewAttention() }
                    Button("Готово") { model.previewCompletion() }
                    Button(model.demo ? "Остановить демо" : "Демо") { model.setDemo() }
                }
            }
        }.formStyle(.grouped)
    }
}
struct AppearanceSettings: View {
    @AppStorage("animateLogos") private var logos = true
    @AppStorage("animatePanel") private var panel = true
    @AppStorage("logoSpeed") private var speed = 1.0
    @AppStorage("logoSize") private var size = 14.0
    @AppStorage("overlapLogos") private var overlap = true
    @AppStorage("compactSide") private var side = "left"
    @AppStorage("expandedWidth") private var width = 350.0
    @AppStorage("cornerRadius") private var corners = 24.0
    @AppStorage("panelShadow") private var shadow = true
    var body: some View {
        Form {
            Section("Логотипы") {
                Picker("Сторона чёлки",selection:$side) { Text("Слева").tag("left");Text("Справа").tag("right") }
                Picker("Размер",selection:$size) { Text("Маленький").tag(14.0);Text("Средний").tag(17.0);Text("Крупный").tag(20.0) }
                Toggle("Накладывать друг на друга",isOn:$overlap)
                Toggle("Анимация логотипов",isOn:$logos)
                Picker("Скорость",selection:$speed) { Text("Медленно").tag(0.6);Text("Обычно").tag(1.0);Text("Быстро").tag(1.6) }.disabled(!logos)
            }
            Section("Остров") {
                Picker("Ширина раскрытой панели",selection:$width) { Text("Компактная").tag(330.0);Text("Обычная").tag(350.0);Text("Широкая").tag(390.0) }
                Picker("Скругление",selection:$corners) { Text("Небольшое").tag(12.0);Text("Обычное").tag(24.0);Text("Сильное").tag(32.0) }
                Toggle("Тень раскрытой панели",isOn:$shadow)
                Toggle("Плавное раскрытие и сворачивание",isOn:$panel)
            }
            Text("Настройка macOS «Уменьшение движения» имеет приоритет.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}
struct SourceVisibilityPicker: View {
    let title: String
    @AppStorage private var mode: String
    init(source: String, title: String) {
        self.title = title
        self._mode = AppStorage(wrappedValue:"active","visibility." + source)
    }
    var body: some View {
        Picker(title,selection:$mode) {
            Text("Всегда показывать").tag("always")
            Text("Скрывать без связи").tag("connected")
            Text("Скрывать без активных задач").tag("active")
            Text("Всегда скрывать").tag("hidden")
        }
    }
}
struct DataSettings: View {
    @ObservedObject var model: IslandModel
    @AppStorage("showSessions") private var sessions = true
    @AppStorage("showTokens") private var tokens = true
    @AppStorage("showTime") private var time = true
    @AppStorage("showQuotas") private var quotas = true
    @AppStorage("combineQuotas") private var combineQuotas = true
    @AppStorage("showAccessButton") private var showAccessButton = true
    @AppStorage("hideInactive") private var inactive = true
    @AppStorage("sessionCount") private var count = 3
    @AppStorage("closeOnOutsideClick") private var outside = true
    var body: some View {
        Form {
            Section("Что показывать") {
                Toggle("Список сеансов",isOn:$sessions)
                Picker("Количество сеансов",selection:$count) { ForEach([1,2,3,5],id:\.self) { Text(String($0)).tag($0) } }.disabled(!sessions)
                Toggle("Счётчики токенов",isOn:$tokens).disabled(!sessions)
                Toggle("Время запроса",isOn:$time).disabled(!sessions)
                Toggle("Остатки лимитов подписки",isOn:$quotas)
                Toggle("Объединять лимиты 5ч и 7д",isOn:$combineQuotas).disabled(!quotas)
            }
            Section("Видимость источников") {
                ForEach(sources,id:\.0) { source in
                    SourceVisibilityPicker(source:source.0,title:source.1 + " · " + (source.0.hasSuffix("cli") ? "терминал" : "приложение"))
                }
                Text("Без связи — нет сигнала о состоянии. Активные задачи — работа, ожидание ответа или ошибка. Эти настройки скрывают строки источников; сеансы и уведомления настраиваются отдельно.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Универсальный доступ") {
                Toggle("Показывать кнопку доступа в панели",isOn:$showAccessButton)
                Text("Кнопка скрывается автоматически, когда разрешение выдано.").font(.caption).foregroundStyle(.secondary)
                TimelineView(.periodic(from:.now,by:2)) { _ in
                    HStack {
                        Text(AXIsProcessTrusted() ? "Универсальный доступ подключён" : "Нужен универсальный доступ")
                        Spacer()
                        if AXIsProcessTrusted() {
                            Image(systemName:"checkmark.circle.fill").foregroundStyle(.green)
                        } else {
                            Button("Подключить") { model.requestAccess() }
                        }
                    }
                }
            }
            Section("Поведение") {
                Toggle("Закрывать по клику вне панели",isOn:$outside)
            }
            Text("Скрытие строк не отключает сбор данных и уведомления.").font(.caption).foregroundStyle(.secondary)
        }.formStyle(.grouped)
    }
}

struct QuotaBadge: View {
    let quota: Quota
    var fresh: Bool { quota.resetsAt > Date().timeIntervalSince1970 }
    var tint: Color { !fresh ? .gray : quota.remaining <= 10 ? .red : quota.remaining <= 25 ? .yellow : .white }
    var title: String { quota.label == "Неделя" ? "7д" : quota.label == "5 часов" ? "5ч" : quota.label }
    var hint: String {
        let provider = quota.provider == "codex" ? "Codex" : "Claude"
        let snapshot = Date(timeIntervalSince1970:quota.updated).formatted(date:.abbreviated,time:.shortened)
        let reset = Date(timeIntervalSince1970:quota.resetsAt).formatted(date:.abbreviated,time:.shortened)
        return "\(provider) · \(quota.label). Остаток лимита. Снимок: \(snapshot). Сброс: \(reset)"
    }
    var body: some View {
        HStack(spacing:4) {
            Image(nsImage:quota.provider == "codex" ? BrandIcons.codex : BrandIcons.claude).resizable().frame(width:12,height:12)
            Text(title).foregroundStyle(.gray)
            Text(fresh ? String(format:"%.0f%%",quota.remaining) : "—").foregroundStyle(tint).fontWeight(.semibold)
        }.help(hint)
    }
}
struct QuotaStrip: View {
    @AppStorage("combineQuotas") private var combineQuotas = true
    let quotas: [Quota]
    var body: some View {
        HStack(spacing:12) {
            ForEach(["codex","claude"],id:\.self) { provider in
                let limits = quotas.filter { $0.provider == provider }.sorted { ($0.label == "5 часов" ? 0 : 1) < ($1.label == "5 часов" ? 0 : 1) }
                if limits.isEmpty {
                    HStack(spacing:4) {
                        Image(nsImage:provider == "codex" ? BrandIcons.codex : BrandIcons.claude).resizable().frame(width:12,height:12)
                        Text("—").foregroundStyle(.gray)
                    }.help((provider == "codex" ? "Codex" : "Claude") + ": нет данных")
                } else if !combineQuotas {
                    ForEach(limits) { quota in QuotaBadge(quota:quota) }
                } else {
                    HStack(spacing:4) {
                        Image(nsImage:provider == "codex" ? BrandIcons.codex : BrandIcons.claude).resizable().frame(width:12,height:12)
                        HStack(spacing:1) {
                            ForEach(Array(limits.enumerated()),id:\.element.id) { index, quota in
                                if index > 0 { Text("/").foregroundStyle(.gray) }
                                let badge = QuotaBadge(quota:quota)
                                Text(badge.fresh ? String(format:"%.0f%%",quota.remaining) : "—")
                                    .foregroundStyle(badge.tint).fontWeight(.semibold).help(badge.hint)
                            }
                        }
                        Text(limits.map { QuotaBadge(quota:$0).title }.joined(separator:"/"))
                            .foregroundStyle(.gray)
                    }
                }
            }
            Spacer(minLength:0)
        }.font(.system(size:10))
    }
}

struct AgentRowStyle: ButtonStyle {
    @State private var hovered = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    func makeBody(configuration:Configuration) -> some View {
        configuration.label
            .padding(.horizontal,12).padding(.vertical,4)
            .frame(maxWidth:.infinity,alignment:.leading)
            .contentShape(RoundedRectangle(cornerRadius:9))
            .background(Color.white.opacity(configuration.isPressed ? 0.12 : hovered ? 0.07 : 0),in:RoundedRectangle(cornerRadius:9))
            .onHover { hovered = $0 }
            .animation(reduceMotion ? nil : .easeOut(duration:0.14),value:hovered)
    }
}

struct SessionCardStyle: ButtonStyle {
    @State private var hovered = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .contentShape(RoundedRectangle(cornerRadius:12))
            .background(Color.white.opacity(configuration.isPressed ? 0.10 : hovered ? 0.05 : 0),in:RoundedRectangle(cornerRadius:12))
            .onHover { hovered = $0 }
    }
}

final class PersistentScrollView<Content: View>: NSScrollView {
    let hosting: NSHostingView<Content>
    init(content: Content) {
        hosting = NSHostingView(rootView:content)
        super.init(frame:.zero)
        drawsBackground = false
        hasVerticalScroller = true
        hasHorizontalScroller = false
        autohidesScrollers = false
        scrollerStyle = .legacy
        borderType = .noBorder
        documentView = hosting
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func layout() {
        super.layout()
        hosting.setFrameSize(NSSize(width:contentSize.width,height:hosting.frame.height))
        hosting.setFrameSize(NSSize(width:contentSize.width,height:hosting.fittingSize.height))
    }
}
struct VisibleScrollView<Content: View>: NSViewRepresentable {
    let content: Content
    init(@ViewBuilder content: () -> Content) { self.content = content() }
    func makeNSView(context: Context) -> PersistentScrollView<Content> { PersistentScrollView(content:content) }
    func updateNSView(_ view: PersistentScrollView<Content>, context: Context) {
        view.hosting.rootView = content
        view.needsLayout = true
    }
}

struct IslandView: View {
    @AppStorage("showSessions") private var showSessions = true
    @AppStorage("showTokens") private var showTokens = true
    @AppStorage("showTime") private var showTime = true
    @AppStorage("showQuotas") private var showQuotas = true
    @AppStorage("showAccessButton") private var showAccessButton = true
    @AppStorage("hideInactive") private var hideInactive = true
    @AppStorage("sessionCount") private var sessionCount = 3
    @AppStorage("cornerRadius") private var cornerRadius = 24.0
    @AppStorage("overlapLogos") private var overlapLogos = true
    @AppStorage("compactSide") private var compactSide = "left"
    @ObservedObject var model: IslandModel
    var notchHeight: CGFloat
    var measurementWidth: CGFloat? = nil
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var hovering = false
    var body: some View {
        VStack(spacing: 0) {
            HStack {
                if compactSide == "right" && !model.expanded { Spacer(minLength:0) }
                HStack(spacing:overlapLogos ? -3 : 5) {
                    if model.codexVisible {
                        WorkingLogo(image:BrandIcons.codex,rays:false,needsAttention:model.codexNeedsAttention)
                            .help(model.codexNeedsAttention ? "Codex требует внимания" : "Codex в работе")
                            .transition(.opacity)
                    }
                    if model.claudeVisible {
                        WorkingLogo(image:BrandIcons.claude,rays:true,needsAttention:model.claudeNeedsAttention)
                            .zIndex(1).help(model.claudeNeedsAttention ? "Claude требует внимания" : "Claude в работе")
                            .transition(.opacity)
                    }
                }
                .animation(reduceMotion ? nil : .easeInOut(duration:0.2),value:model.codexVisible)
                .animation(reduceMotion ? nil : .easeInOut(duration:0.2),value:model.claudeVisible)
                if compactSide != "right" || model.expanded { Spacer(minLength:0) }
                if model.expanded {
                    Button { model.toggle() } label: { Image(systemName:"chevron.up").font(.system(size:11)).foregroundStyle(.gray) }
                        .buttonStyle(.plain).help("Свернуть")
                }
            }.padding(.leading,model.expanded ? 16 : 8).padding(.trailing,model.expanded ? 16 : 8).frame(height: max(notchHeight,32))
            .contentShape(Rectangle())
            .accessibilityElement(children:.ignore)
            .accessibilityLabel(model.activityLabel)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.toggle() }
            if let attention = model.displayedAttention {
                AttentionView(model:model,session:attention)
            } else if model.showingDetails {
                VStack(alignment:.leading,spacing:2) {
                    if model.demo { Text("ДЕМОНСТРАЦИЯ").font(.system(size:9,weight:.medium)).foregroundStyle(.orange) }
                    ForEach(sources.filter { model.showsSource($0.0) },id:\.0) { source in
                        let state = model.status(source.0)
                        let items = model.sessions.filter { $0.source == source.0 }
                        Button(action:{model.openApp(source.0)}) {
                            HStack(spacing:9) {
                                ZStack {
                                    RoundedRectangle(cornerRadius:8)
                                        .fill(source.0.contains("claude") ? Color(red:0.85,green:0.47,blue:0.34).opacity(0.13) : Color.white.opacity(0.09))
                                        .frame(width:28,height:28)
                                    Image(nsImage:source.0.contains("claude") ? BrandIcons.claude : BrandIcons.codex)
                                        .resizable().scaledToFit().frame(width:18,height:18)
                                }
                                VStack(alignment:.leading,spacing:3) {
                                    Text(source.1).font(.system(size:13,weight:.semibold)).foregroundStyle(.white)
                                    Text(source.2).font(.system(size:10)).foregroundStyle(.gray)
                                }
                                Spacer()
                                VStack(alignment:.trailing,spacing:3) {
                                    HStack(spacing:5) { ActivityLight(status:state,size:5); Text(label(state)).foregroundStyle(statusColor(state)) }.font(.system(size:11,weight:.medium))
                                    Text(items.isEmpty ? "Ожидаем сеанс" : "\(items.count) сеанс(ов)").font(.system(size:10)).foregroundStyle(.gray)
                                }
                            }
                        }.buttonStyle(AgentRowStyle())
                    }
                    let recent = Array(model.sessions.sorted { a,b in
                        let aActive = ["working","waiting","error"].contains(a.status)
                        let bActive = ["working","waiting","error"].contains(b.status)
                        return aActive != bActive ? aActive : a.updated > b.updated
                    }.prefix(model.demo ? model.sessions.count : sessionCount))
                    if (showSessions || model.demo) && !recent.isEmpty {
                        let cards = VStack(spacing:6) {
                            ForEach(recent) { session in
                                Button { model.openSession(session) } label: {
                                VStack(alignment:.leading,spacing:3) {
                                    HStack {
                                        Image(nsImage:session.source.hasPrefix("codex") ? BrandIcons.codex : BrandIcons.claude)
                                            .resizable().frame(width:11,height:11)
                                        Text(session.displayTitle).lineLimit(1).help(session.displayTitle)
                                        Spacer(minLength:4)
                                        Text(label(session.status)).font(.system(size:9,weight:.medium)).foregroundStyle(statusColor(session.status)).fixedSize()
                                    }.font(.system(size:11))
                                    HStack {
                                        Text(session.project).lineLimit(1).font(.system(size:9)).foregroundStyle(.gray)
                                        Spacer()
                                        if showTime { TimelineView(.periodic(from:.now,by:1)) { context in
                                            if let start = session.turnStarted {
                                                Label(elapsedTime((session.ended ?? context.date.timeIntervalSince1970)-start),systemImage:"clock").help("Время с начала запроса")
                                            } else { Text("Время неизвестно") }
                                        }.foregroundStyle(.gray).font(.system(size:10)).monospacedDigit() }
                                    }.font(.system(size:11))
                                    if showTokens { if let total = session.totalTokens {
                                        HStack(spacing:12) {
                                            Label(tokenNumber(total),systemImage:"square.stack.3d.up").help("Всего обработано токенов за сеанс, включая кэш")
                                            Label(tokenNumber(session.outputTokens ?? 0),systemImage:"arrow.down").help("Токены ответа")
                                            Label(tokenNumber(session.cachedTokens ?? 0),systemImage:"archivebox").help("Повторно прочитанные токены кэша; входят в общий объём")
                                        }.font(.system(size:10)).foregroundStyle(.gray)
                                    } else { Text("Токены ещё не получены").font(.system(size:10)).foregroundStyle(.gray) } }
                                }
                                .padding(.horizontal,12).padding(.vertical,9)
                                .frame(maxWidth:.infinity,alignment:.leading)
                                .background(.white.opacity(0.05),in:RoundedRectangle(cornerRadius:12))
                                }.buttonStyle(SessionCardStyle()).disabled(model.demo)
                            }
                        }
                        if recent.count > 3 {
                            VisibleScrollView { cards.padding(.trailing,4) }.frame(height:250)
                        } else { cards }
                    }
                    if showQuotas { VStack(alignment:.leading,spacing:7) {
                        Text("Остаток подписки").font(.system(size:11,weight:.semibold))
                        QuotaStrip(quotas:model.quotas)
                    }.padding(.horizontal,12).padding(.vertical,6) }
                    if showAccessButton && !model.accessibilityGranted {
                        Button { model.requestAccess() } label: {
                            Label("Универсальный доступ",systemImage:"hand.raised")
                                .font(.system(size:10)).frame(maxWidth:.infinity)
                        }.buttonStyle(.bordered).padding(.horizontal,12).padding(.vertical,4)
                        .help("Разрешить переключение окон терминала и определение активности обычного чата Claude")
                    }
                    if let error = model.error { Text(error).font(.system(size:10)).foregroundStyle(.orange) }
                    ZStack {
                        Text("Agent Island").font(.system(size:9,weight:.medium)).foregroundStyle(.white)
                        HStack(spacing:10) {
                            Image(systemName:"lock.shield").help("Все данные обрабатываются локально на этом Mac")
                            Spacer()
                            Button { model.onShowSettings?() } label: {
                                Image(systemName:"gearshape").font(.system(size:12))
                            }.buttonStyle(.plain).help("Настройки").accessibilityLabel("Настройки")
                        }.font(.system(size:10)).foregroundStyle(.gray).padding(.horizontal,12)
                    }.frame(height:18)
                }.padding(.horizontal,4).padding(.top,8).padding(.bottom,6)

            }
        }
        .frame(width:measurementWidth ?? model.panelWidth)
        .fixedSize(horizontal:false,vertical:true)
        .frame(height:measurementWidth == nil ? model.panelHeight : nil,alignment:.top)
        .clipped()
        .background(Color.black,in:UnevenRoundedRectangle(bottomLeadingRadius:cornerRadius,bottomTrailingRadius:cornerRadius))
        .overlay(alignment:.bottom) { if !model.expanded && model.displayedAttention == nil { Capsule().fill(.white.opacity(hovering ? 0.65 : 0.24)).frame(width:hovering ? 38 : 28,height:2).padding(.bottom,3) } }
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .easeOut(duration:0.2),value:hovering)
        .frame(maxHeight:.infinity,alignment:.top)
        .clipped()
        .preferredColorScheme(.dark)
    }
}

final class IslandHostingView: NSHostingView<IslandView> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class Panel: NSPanel { override var canBecomeKey: Bool { true }; override var canBecomeMain: Bool { false } }
final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = IslandModel()
    var panel: Panel!
    var item: NSStatusItem!
    var host: NSHostingView<IslandView>!
    var motionTimer: Timer?
    var headerHeight: CGFloat = 32
    var targetFrame: NSRect = .zero
    var settingsWindow: NSWindow?
    var preferencesObserver: NSObjectProtocol?
    var preferencesSignature = ""
    var outsideClickMonitor: Any?
    var localClickMonitor: Any?
    func applicationDidFinishLaunching(_ notification: Notification) {
        Journal.write("app_started",["version":Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown","accessibility":String(AXIsProcessTrusted())])
        NSApp.setActivationPolicy(.accessory)
        panel = Panel(contentRect:.zero,styleMask:[.borderless,.nonactivatingPanel],backing:.buffered,defer:false)
        panel.isOpaque = false; panel.backgroundColor = .clear; panel.hasShadow = true
        panel.level = .statusBar; panel.collectionBehavior = [.canJoinAllSpaces,.fullScreenAuxiliary,.stationary]
        panel.isReleasedWhenClosed = false
        let clicks: NSEvent.EventTypeMask = [.leftMouseDown,.rightMouseDown,.otherMouseDown]
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching:clicks) { [weak self] _ in
            self?.closeIfOutside()
        }
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching:clicks) { [weak self] event in
            guard let self else { return event }
            if event.type == .leftMouseDown, event.window === self.panel {
                let point = event.locationInWindow
                let header = NSRect(x:0,y:max(0,self.panel.frame.height-self.headerHeight),width:self.panel.frame.width,height:self.headerHeight)
                if header.contains(point) {
                    self.model.toggle()
                    return nil
                }
            }
            self.closeIfOutside()
            return event
        }
        model.onResize = { [weak self] in self?.position() }
        model.onShowSettings = { [weak self] in self?.showSettings() }
        model.onDemoStart = { [weak self] in self?.settingsWindow?.orderOut(nil) }
        preferencesSignature = Preferences.signature
        preferencesObserver = NotificationCenter.default.addObserver(forName:UserDefaults.didChangeNotification,object:nil,queue:.main) { [weak self] _ in
            guard let self else { return }
            let signature = Preferences.signature
            guard signature != self.preferencesSignature else { return }
            self.preferencesSignature = signature
            self.model.timedAttentionID = nil
            self.model.objectWillChange.send()
            self.position()
        }
        position()
        panel.orderFrontRegardless()
        item = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength)
        item.button?.image = NSImage(systemSymbolName:"capsule.tophalf.filled",accessibilityDescription:"Agent Island")
        let menu = NSMenu()
        menu.addItem(withTitle:"Показать / свернуть",action:#selector(toggle),keyEquivalent:"")
        menu.addItem(withTitle:"Настройки…",action:#selector(showSettings),keyEquivalent:",")
        menu.addItem(.separator())
        menu.addItem(withTitle:"Выйти",action:#selector(quit),keyEquivalent:"q")
        for entry in menu.items { entry.target = self }; item.menu = menu
        NotificationCenter.default.addObserver(self,selector:#selector(screenChanged),name:NSApplication.didChangeScreenParametersNotification,object:nil)
        model.start()
        if CommandLine.arguments.contains("--demo") { model.setDemo() }
        if CommandLine.arguments.contains("--preview-attention") { model.previewAttention() }
        if CommandLine.arguments.contains("--preview-completion") { model.previewCompletion() }
        if CommandLine.arguments.contains("--settings") { showSettings() }
    }
    func position() {
        model.scheduleAttentionDismissal()
        guard let screen = NSScreen.screens.first(where: {$0.safeAreaInsets.top > 0}) ?? NSScreen.main else { return }
        let notch = max(screen.safeAreaInsets.top, 32)
        headerHeight = notch
        let peek = model.expanded ? nil : model.attentionSession
        let opened = model.expanded || peek != nil
        if model.expanded {
            model.displayedAttention = nil
            model.showingDetails = true
        } else if let peek {
            model.displayedAttention = peek
            model.showingDetails = false
        }
        if host == nil {
            host = IslandHostingView(rootView:IslandView(model:model,notchHeight:notch))
            panel.contentView = host
        }
        let leftEdge = screen.auxiliaryTopLeftArea?.maxX ?? screen.frame.midX
        let rightEdge = screen.auxiliaryTopRightArea?.minX ?? screen.frame.midX
        let notchWidth = max(0, rightEdge - leftEdge)
        let logoSize = UserDefaults.standard.double(forKey:"logoSize")
        let indicatorWidth: CGFloat = model.codexVisible && model.claudeVisible ? logoSize * 2 + (Preferences.enabled("overlapLogos") ? -3 : 5) : logoSize
        let leftExtension: CGFloat = 8 + indicatorWidth + 8
        let compactWidth: CGFloat = notchWidth > 0 ? notchWidth + leftExtension : leftExtension
        let width: CGFloat = model.expanded ? UserDefaults.standard.double(forKey:"expandedWidth") : (opened ? 390 : compactWidth)
        let rightSide = UserDefaults.standard.string(forKey:"compactSide") == "right"
        let originX = opened ? screen.frame.midX - width / 2 : (notchWidth > 0 ? (rightSide ? leftEdge : leftEdge - leftExtension) : screen.frame.midX - width / 2)
        panel.hasShadow = opened && Preferences.enabled("panelShadow")
        let measure = NSHostingView(rootView:IslandView(model:model,notchHeight:notch,measurementWidth:width))
        let height = opened ? measure.fittingSize.height : notch
        let frame = NSRect(x:originX,y:screen.frame.maxY-height,width:width,height:height)
        guard frame != targetFrame else {
            if motionTimer?.isValid != true {
                model.showingDetails = model.expanded
                model.displayedAttention = peek
            }
            return
        }
        targetFrame = frame
        motionTimer?.invalidate()
        let initial = panel.frame
        guard panel.isVisible, Preferences.enabled("animatePanel"), !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else {
            model.panelWidth = width
            model.panelHeight = height
            model.showingDetails = model.expanded
            model.displayedAttention = peek
            panel.setFrame(frame,display:true)
            return
        }
        let start = Date.timeIntervalSinceReferenceDate
        // Keep the top edge attached to the notch and retarget from the current frame on rapid clicks.
        motionTimer = Timer.scheduledTimer(withTimeInterval:1.0/60,repeats:true) { [weak self] timer in
            guard let self else { timer.invalidate(); return }
            let t = min(1, (Date.timeIntervalSinceReferenceDate - start) / 0.42)
            let eased = t * t * t * (t * (t * 6 - 15) + 10)
            let w = initial.width + (frame.width - initial.width) * eased
            let h = initial.height + (frame.height - initial.height) * eased
            self.model.panelWidth = w
            self.model.panelHeight = h
            let x = initial.minX + (frame.minX - initial.minX) * eased
            self.panel.setFrame(NSRect(x:x,y:screen.frame.maxY-h,width:w,height:h),display:true)
            if t >= 1 {
                timer.invalidate()
                self.model.showingDetails = self.model.expanded
                self.model.displayedAttention = peek
            }
        }
    }
    @objc func showSettings() {
        model.expanded = false
        model.dismissAttention()
        if settingsWindow == nil {
            let controller = NSHostingController(rootView:IslandSettings(model:model))
            let window = NSWindow(contentViewController:controller)
            window.title = "Agent Island"
            window.styleMask = [.titled,.closable]
            window.isReleasedWhenClosed = false
            window.center()
            settingsWindow = window
        }
        settingsWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps:true)
    }
    func closeIfOutside() {
        guard Preferences.enabled("closeOnOutsideClick"), model.expanded || model.displayedAttention != nil,
              !panel.frame.contains(NSEvent.mouseLocation) else { return }
        model.expanded = false
        model.dismissAttention()
    }
    @objc func screenChanged() {position()}
    @objc func toggle() {model.toggle();panel.orderFrontRegardless()}
    @objc func demo() {model.setDemo()}
    @objc func previewAttention() {model.previewAttention()}
    @objc func previewCompletion() {model.previewCompletion()}
    @objc func access() {model.requestAccess()}
    @objc func quit() {NSApp.terminate(nil)}
    func applicationWillTerminate(_ notification: Notification) {
        if let preferencesObserver { NotificationCenter.default.removeObserver(preferencesObserver) }
        if let outsideClickMonitor { NSEvent.removeMonitor(outsideClickMonitor) }
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        motionTimer?.invalidate()
        model.attentionTimer?.invalidate()
        model.demoTimer?.invalidate()
        model.process?.terminationHandler = nil
        model.process?.terminate()
    }
}
UserDefaults.standard.register(defaults:Preferences.defaults)
if CommandLine.arguments.contains("--self-test-demo") {
    let model = IslandModel()
    model.sessions = [Session(id:"real",source:"codex-cli",status:"working",updated:1,project:"real")]
    model.setDemo()
    precondition(model.demo && !model.expanded)
    model.demoStep = 1;model.applyDemoStep();precondition(model.expanded)
    model.demoStep = 2;model.applyDemoStep();precondition(model.sessions[1].status == "waiting")
    model.demoStep = 3;model.applyDemoStep();precondition(model.attentionSession?.status == "waiting" && !model.expanded)
    model.demoStep = 4;model.applyDemoStep();precondition(model.attentionSession == nil)
    model.demoStep = 5;model.applyDemoStep();precondition(model.attentionSession?.status == "done")
    model.demoStep = 6;model.applyDemoStep();precondition(model.attentionSession?.status == "quota")
    model.demoStep = 7;model.applyDemoStep();precondition(model.attentionSession?.status == "error")
    var data = try! JSONEncoder().encode([Session(id:"real-new",source:"codex-cli",status:"working",updated:2,project:"real")]);data.append(10);model.receive(data)
    precondition(model.demo && model.sessions[0].id == "demo1")
    model.demoStep = 9;model.applyDemoStep()
    precondition(model.demo && model.expanded && model.sessions.count == 12)
    model.demoStep = 13;model.applyDemoStep()
    precondition(!model.demo && model.sessions.first?.id == "real-new")
    print("Demo sequence and live restoration passed")
    exit(0)
}
if CommandLine.arguments.contains("--self-test-settings") {
    let keys = ["notificationsEnabled","notifyWaiting","notifyDone","notifyErrors","notifyQuota","notifyCodex","notifyClaude","autoHideNotifications","notificationSound"]
    let saved = Dictionary(uniqueKeysWithValues:keys.map { ($0,UserDefaults.standard.object(forKey:$0)) })
    for key in keys { UserDefaults.standard.set(key != "notificationSound",forKey:key) }
    let model = IslandModel()
    let waiting = Session(id:"settings-test",source:"claude-cli",status:"waiting",updated:1,project:"test")
    model.sessions = [waiting]
    precondition(model.attentionSession != nil)
    UserDefaults.standard.set(false,forKey:"notifyWaiting")
    precondition(model.attentionSession == nil)
    UserDefaults.standard.set(true,forKey:"notifyWaiting")
    UserDefaults.standard.set(false,forKey:"notifyClaude")
    precondition(model.attentionSession == nil)
    UserDefaults.standard.set(true,forKey:"notifyClaude")
    UserDefaults.standard.set(false,forKey:"notificationsEnabled")
    precondition(model.attentionSession == nil)
    UserDefaults.standard.set(true,forKey:"notificationsEnabled")
    UserDefaults.standard.set(false,forKey:"autoHideNotifications")
    model.scheduleAttentionDismissal()
    precondition(model.attentionTimer == nil)
    let failure = Session(id:"error",source:"codex-app",status:"error",updated:1,project:"test")
    precondition(model.allowsNotice(failure))
    UserDefaults.standard.set(false,forKey:"notifyErrors")
    precondition(!model.allowsNotice(failure))
    for key in keys {
        if let value = saved[key] ?? nil { UserDefaults.standard.set(value,forKey:key) }
        else { UserDefaults.standard.removeObject(forKey:key) }
    }
    print("Settings filters and manual dismissal passed")
    exit(0)
}
if CommandLine.arguments.contains("--self-test-attention") {
    let model = IslandModel()
    func deliver(_ status: String) {
        let session = Session(id:"test",source:"codex-cli",status:status,updated:1,project:"test",attention:"permission")
        var data = try! JSONEncoder().encode([session]); data.append(10); model.receive(data)
    }
    deliver("waiting")
    precondition(model.attentionSession != nil && !model.expanded)
    model.dismissAttention()
    deliver("waiting")
    precondition(model.attentionSession == nil)
    deliver("working")
    precondition(model.attentionSession == nil)
    deliver("waiting")
    precondition(model.attentionSession != nil)
    deliver("done")
    precondition(model.attentionSession?.status == "done")
    model.scheduleAttentionDismissal()
    model.attentionTimer?.fire()
    precondition(model.attentionSession == nil)
    deliver("done")
    precondition(model.attentionSession == nil)
    let fresh = IslandModel()
    let oldDone = Session(id:"old",source:"codex-cli",status:"done",updated:1,project:"old")
    var oldData = try! JSONEncoder().encode([oldDone]); oldData.append(10); fresh.receive(oldData)
    precondition(fresh.attentionSession == nil)
    let quotaID = "test-agent-island-quota"
    let key = "quota-threshold-v2:" + quotaID
    UserDefaults.standard.removeObject(forKey:key)
    let reset = Date().timeIntervalSince1970 + 600
    let quotaModel = IslandModel()
    func quota(_ remaining: Double, _ resetAt: Double) -> Quota {
        Quota(id:quotaID,provider:"codex",label:"Тест",remaining:remaining,resetsAt:resetAt,updated:1)
    }
    quotaModel.checkQuotaThresholds([quota(95,reset)])
    precondition(quotaModel.quotaNotices.isEmpty)
    quotaModel.checkQuotaThresholds([quota(85,reset)])
    quotaModel.checkQuotaThresholds([quota(84,reset)])
    precondition(quotaModel.quotaNotices.count == 1)
    quotaModel.checkQuotaThresholds([quota(62,reset)])
    precondition(quotaModel.quotaNotices.count == 2)
    let restarted = IslandModel()
    restarted.checkQuotaThresholds([quota(62,reset)])
    precondition(restarted.quotaNotices.isEmpty)
    restarted.checkQuotaThresholds([quota(95,reset + 600)])
    precondition(restarted.quotaNotices.isEmpty)
    quotaModel.quotaNotices.removeAll()
    quotaModel.checkQuotaThresholds([quota(30,reset)])
    quotaModel.quotaNotices.removeAll()
    for value in [29.0,26,25,24,20,15,10,5,0] { quotaModel.checkQuotaThresholds([quota(value,reset)]) }
    precondition(quotaModel.quotaNotices.count == 6)
    quotaModel.checkQuotaThresholds([quota(0,reset)])
    precondition(quotaModel.quotaNotices.count == 6)
    UserDefaults.standard.removeObject(forKey:key)
    print("Attention and quota transitions passed")
    exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
