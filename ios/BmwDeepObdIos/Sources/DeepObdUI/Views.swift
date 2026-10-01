import SwiftUI
import EdiabasKit
import UniformTypeIdentifiers

public struct RootView: View {
    @StateObject private var session = DiagnosticSession()

    public init() {}

    public var body: some View {
        TabView {
            NavigationStack { AdapterView() }
                .tabItem { Label("Adapter", systemImage: "antenna.radiowaves.left.and.right") }
            NavigationStack { ToolView() }
                .tabItem { Label("Tool", systemImage: "wrench.and.screwdriver") }
            NavigationStack { LogView() }
                .tabItem { Label("Log", systemImage: "text.alignleft") }
        }
        .environmentObject(session)
        .environmentObject(session.translator)
        .background {
            #if canImport(Translation)
            if #available(iOS 18.0, macOS 15.0, *) { TranslationHost(store: session.translator) }
            #endif
        }
        .alert("Error", isPresented: Binding(get: { session.errorMessage != nil }, set: { if !$0 { session.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(session.errorMessage ?? "")
        }
    }
}

// MARK: adapter

struct AdapterView: View {
    @EnvironmentObject var session: DiagnosticSession
    @EnvironmentObject var translator: TranslationStore
    @State private var pickingFolder = false
    @State private var nameDraft = ""
    @State private var naming: Naming = .none

    enum Naming: Equatable {
        case none
        case add(URL)
        case rename(UUID)

        var title: String {
            switch self {
            case .add: return "Name this ECU set"
            case .rename: return "Rename ECU set"
            case .none: return ""
            }
        }
    }

    private var adapters: [BleDevice] { session.devices.filter { $0.looksLikeAdapter } }
    private var others: [BleDevice] { session.devices.filter { !$0.looksLikeAdapter } }

    private func deviceRow(_ d: BleDevice) -> some View {
        Button {
            Task { await session.connect(d) }
        } label: {
            HStack {
                Text(d.name)
                Spacer()
                Text("\(d.rssi) dBm").font(.footnote).foregroundStyle(.secondary)
            }
        }
        .disabled(session.isConnected)
    }

    var body: some View {
        List {
            Section("Status") {
                switch session.state {
                case .disconnected: Label("Not connected", systemImage: "circle")
                case .scanning: Label("Scanning…", systemImage: "magnifyingglass")
                case .connecting(let n): Label("Connecting to \(n)…", systemImage: "arrow.triangle.2.circlepath")
                case .connected(let n):
                    Label("Connected: \(n)", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    Button("Disconnect", role: .destructive) { session.disconnect() }
                }
            }

            Section("Display") {
                Toggle("Translate German to English", isOn: $translator.enabled)
            }

            Section {
                ForEach(session.profiles) { p in
                    Button {
                        session.activate(p)
                    } label: {
                        HStack {
                            Image(systemName: p.id == session.activeProfileID ? "checkmark.circle.fill" : "circle")
                                .foregroundStyle(p.id == session.activeProfileID ? Color.accentColor : .secondary)
                            VStack(alignment: .leading) {
                                Text(p.name).foregroundStyle(.primary)
                                if p.id == session.activeProfileID {
                                    Text("\(session.sgbdFiles.count) SGBD files").font(.footnote).foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                    .swipeActions {
                        Button(role: .destructive) { session.deleteProfile(p.id) } label: { Label("Delete", systemImage: "trash") }
                        Button { nameDraft = p.name; naming = .rename(p.id) } label: { Label("Rename", systemImage: "pencil") }.tint(.orange)
                    }
                    .contextMenu {
                        Button { nameDraft = p.name; naming = .rename(p.id) } label: { Label("Rename", systemImage: "pencil") }
                        Button(role: .destructive) { session.deleteProfile(p.id) } label: { Label("Delete", systemImage: "trash") }
                    }
                }
                if session.profiles.isEmpty {
                    Text("Add a folder with EDIABAS ECU files (.prg / .grp). You can add one per vehicle, for example \"Mini R56\" or \"BMW N47\".")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Button { pickingFolder = true } label: { Label("Add ECU folder", systemImage: "plus") }
            } header: {
                Text("ECU sets")
            } footer: {
                if !session.profiles.isEmpty { Text("Tap to switch. Swipe or long-press to rename or delete.") }
            }

            Section("Likely adapters") {
                if adapters.isEmpty {
                    Text(session.state == .scanning ? "Searching…" : "Tap Scan to search.")
                        .foregroundStyle(.secondary)
                }
                ForEach(adapters) { d in deviceRow(d) }
            }

            if !others.isEmpty {
                Section {
                    DisclosureGroup("Other Bluetooth devices (\(others.count))") {
                        ForEach(others) { d in deviceRow(d) }
                    }
                } footer: {
                    Text("Adapters that do not advertise a serial service appear here.")
                }
            }
        }
        .navigationTitle("BMW Deep OBD")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                if session.state == .scanning {
                    Button("Stop") { session.stopScan() }
                } else {
                    Button("Scan") { Task { await session.startScan() } }
                        .disabled(session.isConnected)
                }
            }
        }
        .background {
            Color.clear.fileImporter(isPresented: $pickingFolder, allowedContentTypes: [.folder]) { result in
                if case .success(let url) = result {
                    nameDraft = url.lastPathComponent
                    // present the alert after the picker has fully gone away
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { naming = .add(url) }
                }
            }
        }
        .alert(naming.title, isPresented: Binding(get: { naming != .none }, set: { if !$0 { naming = .none } })) {
            TextField("Nickname", text: $nameDraft)
            Button("Save") {
                switch naming {
                case .add(let url): session.addProfile(url: url, name: nameDraft)
                case .rename(let id): session.renameProfile(id, to: nameDraft)
                case .none: break
                }
                naming = .none
            }
            Button("Cancel", role: .cancel) { naming = .none }
        } message: {
            Text("For example the vehicle this ECU set belongs to.")
        }
    }
}

// MARK: tool

struct ToolView: View {
    @EnvironmentObject var session: DiagnosticSession
    @State private var search = ""

    private var filtered: [String] {
        let q = search.lowercased()
        return q.isEmpty ? session.sgbdFiles : session.sgbdFiles.filter { $0.lowercased().contains(q) }
    }

    /// Recent tools that still exist in the chosen ECU folder.
    private var recent: [String] {
        session.recentSgbd.compactMap { r in session.sgbdFiles.first { $0.caseInsensitiveCompare(r) == .orderedSame } }
    }

    var body: some View {
        Group {
            if !session.isConnected {
                ContentUnavailableView("Not connected", systemImage: "antenna.radiowaves.left.and.right.slash",
                                       description: Text("Connect to a BLE ELM327 adapter on the Adapter tab."))
            } else if session.ecuFolder == nil {
                ContentUnavailableView("No ECU set", systemImage: "folder.badge.questionmark",
                                       description: Text("Add or select an ECU set on the Adapter tab."))
            } else if let sgbd = session.selectedSgbd, !session.jobs.isEmpty {
                JobListView(sgbd: sgbd)
            } else {
                List {
                    if search.isEmpty {
                        Section("Whole vehicle") {
                            NavigationLink {
                                ScanView()
                            } label: {
                                Label("Scan all ECUs for faults", systemImage: "car.side.rear.and.collision.and.car.side.front")
                            }
                        }
                    }
                    if search.isEmpty && !recent.isEmpty {
                        Section("Recently used") {
                            ForEach(recent, id: \.self) { name in
                                Button { Task { await session.selectSgbd(name) } } label: {
                                    Label(name, systemImage: "clock.arrow.circlepath")
                                }
                            }
                        }
                    }
                    Section(search.isEmpty ? "All ECUs" : "Results") {
                        ForEach(filtered, id: \.self) { name in
                            Button(name) { Task { await session.selectSgbd(name) } }
                        }
                    }
                }
                .overlay { if session.busy { ProgressView("Reading SGBD…") } }
                .searchable(text: $search, prompt: "SGBD (e.g. d_motor)")
            }
        }
        .navigationTitle(session.selectedSgbd ?? (session.activeProfile?.name ?? "Tool"))
        .toolbar {
            if session.selectedSgbd != nil {
                ToolbarItem(placement: .primaryAction) {
                    Button("Change ECU") { session.selectedSgbd = nil; session.jobs = [] }
                }
            }
        }
    }
}

struct JobListView: View {
    @EnvironmentObject var session: DiagnosticSession
    let sgbd: String
    @State private var search = ""

    private var filtered: [JobEntry] {
        let q = search.lowercased()
        return q.isEmpty ? session.jobs : session.jobs.filter {
            $0.name.lowercased().contains(q) || $0.comment.lowercased().contains(q)
                || (JobNameGlossary.english($0.name)?.lowercased().contains(q) ?? false)
        }
    }

    var body: some View {
        List {
            if session.canReadFaults {
                Section {
                    NavigationLink {
                        FaultView()
                    } label: {
                        Label("Fault memory", systemImage: "exclamationmark.triangle")
                    }
                }
            }
            Section("Jobs") {
                ForEach(filtered) { job in
                    NavigationLink {
                        JobRunView(job: job.name)
                    } label: {
                        JobRow(job: job)
                    }
                }
            }
        }
        .searchable(text: $search, prompt: "Job")
    }
}

struct JobRunView: View {
    @EnvironmentObject var session: DiagnosticSession
    let job: String
    @State private var args = ""
    @State private var results = ""
    @State private var info: [String] = []

    var body: some View {
        List {
            Section("Run") {
                TextField("Arguments (separated by ;)", text: $args)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                TextField("Results filter (separated by ;)", text: $results)
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    #endif
                HStack {
                    Button {
                        Task { await session.run(job: job, args: args, results: results) }
                    } label: {
                        Label("Execute", systemImage: "play.fill")
                    }
                    .disabled(session.busy)
                    if session.busy {
                        Spacer()
                        ProgressView()
                        Button("Cancel", role: .cancel) { session.cancelJob() }
                    }
                }
                Toggle("Show system results", isOn: $session.showSystemResults)
            }

            ForEach(session.sections) { section in
                Section(section.title) {
                    ForEach(section.rows) { row in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(row.name).font(.footnote).foregroundStyle(.secondary)
                            TText(row.text).textSelection(.enabled)
                        }
                    }
                }
            }

            if !info.isEmpty {
                Section("Description") {
                    ForEach(Array(info.enumerated()), id: \.offset) { _, line in
                        TText(line).font(.footnote)
                    }
                }
            }
        }
        .navigationTitle(job)
        .task { info = await session.jobInfo(job) }
    }
}

// MARK: log

struct LogView: View {
    @EnvironmentObject var session: DiagnosticSession

    var body: some View {
        ScrollView {
            Text(session.logText.isEmpty ? "No trace yet." : session.logText)
                .font(.system(.caption, design: .monospaced))
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
                .textSelection(.enabled)
        }
        .navigationTitle("Trace")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                ShareLink(item: session.logText)
            }
            ToolbarItem(placement: .secondaryAction) {
                Button("Clear") { session.clearLog() }
            }
        }
    }
}

// MARK: faults

struct FaultView: View {
    @EnvironmentObject var session: DiagnosticSession
    @State private var confirmClear = false

    var body: some View {
        List {
            Section {
                Button {
                    Task { await session.readFaults() }
                } label: {
                    Label(session.faultsRead ? "Read again" : "Read fault memory", systemImage: "arrow.clockwise")
                }
                .disabled(session.busy)
                if session.busy { HStack { ProgressView(); Text(session.faultStatus).foregroundStyle(.secondary) } }
                else if !session.faultStatus.isEmpty { Text(session.faultStatus).foregroundStyle(.secondary) }
            }

            if session.faultsRead {
                if session.faults.isEmpty {
                    Section { Label("No faults stored", systemImage: "checkmark.circle").foregroundStyle(.green) }
                } else {
                    Section("\(session.faults.count) fault\(session.faults.count == 1 ? "" : "s")") {
                        ForEach(session.faults) { f in FaultRow(f: f) }
                    }
                }

                if session.canClearFaults {
                    Section {
                        Button("Clear fault memory", role: .destructive) { confirmClear = true }
                            .disabled(session.busy || session.faults.isEmpty)
                    } footer: {
                        Text("Clearing removes the stored codes and their freeze-frame data. Note them down first.")
                    }
                }
            }
        }
        .navigationTitle("Fault memory")
        .confirmationDialog("Clear all faults in this ECU?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) { Task { await session.clearFaults() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
        .onAppear { session.resetFaults() }
    }
}

/// Job name with its English meaning in italics: translated description if the SGBD has one, else a reading of the name.
struct JobRow: View {
    @EnvironmentObject var translator: TranslationStore
    let job: JobEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(job.name).font(.body.monospaced())
            if translator.enabled {
                if !job.comment.isEmpty {
                    TText(job.comment, italic: true).font(.footnote).foregroundStyle(.secondary)
                } else if let en = JobNameGlossary.english(job.name) {
                    Text(en).italic().font(.footnote).foregroundStyle(.secondary)
                }
            } else if !job.comment.isEmpty {
                Text(job.comment).font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct FaultRow: View {
    let f: Fault

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(f.codeText).font(.headline.monospaced())
                Spacer()
                Text(f.hex.map { String(format: "%02X", $0) }.joined(separator: " "))
                    .font(.caption.monospaced()).foregroundStyle(.secondary)
            }
            TText(f.location)
            if !f.symptom.isEmpty { TText(f.symptom).font(.subheadline).foregroundStyle(.secondary) }
            if !f.presence.isEmpty { TText(f.presence).font(.footnote).foregroundStyle(.orange) }
            if !f.warning.isEmpty { TText(f.warning).font(.footnote).foregroundStyle(.secondary) }
            if !f.ready.isEmpty { TText(f.ready).font(.footnote).foregroundStyle(.secondary) }
        }
        .padding(.vertical, 2)
        .textSelection(.enabled)
    }
}

// MARK: vehicle scan

struct ScanView: View {
    @EnvironmentObject var session: DiagnosticSession
    @State private var confirmClearAll = false

    private var withFaults: [EcuScanResult] { session.scanResults.filter { !$0.faults.isEmpty } }
    private var clean: [EcuScanResult] { session.scanResults.filter { $0.faults.isEmpty && $0.error == nil } }
    private var problems: [EcuScanResult] { session.scanResults.filter { $0.faults.isEmpty && $0.error != nil } }

    var body: some View {
        List {
            Section {
                if session.scanning {
                    VStack(alignment: .leading, spacing: 8) {
                        ProgressView(value: session.scanProgress)
                        Text(session.scanMessage).font(.footnote).foregroundStyle(.secondary)
                        Button("Cancel", role: .cancel) { session.cancelJob() }
                    }
                } else {
                    Button {
                        Task { await session.startVehicleScan() }
                    } label: {
                        Label(session.scanFinished ? "Scan again" : "Start scan", systemImage: "magnifyingglass")
                    }
                    .disabled(session.busy)
                }
            } footer: {
                if !session.scanning && session.scanResults.isEmpty {
                    Text("Looks for every ECU that answers on the diagnostic bus, then reads its fault memory. This takes about a minute. Ignition on, engine off.")
                }
            }

            if session.scanFinished || !session.scanResults.isEmpty {
                Section {
                    Text("\(session.scanResults.count) ECUs found, \(session.scanFaultCount) fault\(session.scanFaultCount == 1 ? "" : "s") in \(withFaults.count) ECU\(withFaults.count == 1 ? "" : "s")")
                        .font(.headline)
                }
            }

            if !withFaults.isEmpty {
                Section("With faults") {
                    ForEach(withFaults) { ecu in
                        NavigationLink { EcuFaultsView(address: ecu.address) } label: { EcuRow(ecu: ecu) }
                    }
                }
                Section {
                    Button("Clear all faults", role: .destructive) { confirmClearAll = true }
                        .disabled(session.busy)
                } footer: {
                    Text("Clears the fault memory of every ECU listed above. Note the codes down first.")
                }
            }

            if !clean.isEmpty {
                Section("No faults") {
                    ForEach(clean) { ecu in EcuRow(ecu: ecu) }
                }
            }

            if !problems.isEmpty {
                Section("Could not be read") {
                    ForEach(problems) { ecu in EcuRow(ecu: ecu) }
                }
            }
        }
        .navigationTitle("Vehicle scan")
        .confirmationDialog("Clear the faults of all ECUs?", isPresented: $confirmClearAll, titleVisibility: .visible) {
            Button("Clear all", role: .destructive) { Task { await session.clearAllScanned() } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This cannot be undone.")
        }
    }
}

struct EcuRow: View {
    let ecu: EcuScanResult

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(ecu.name).font(.body)
                HStack(spacing: 6) {
                    Text(ecu.addressText).font(.caption.monospaced())
                    if !ecu.variant.isEmpty { Text(ecu.variant.uppercased()).font(.caption.monospaced()) }
                }
                .foregroundStyle(.secondary)
                if let e = ecu.error { Text(e).font(.caption).foregroundStyle(.orange) }
            }
            Spacer()
            if !ecu.faults.isEmpty {
                Text("\(ecu.faults.count)").font(.headline).foregroundStyle(.white)
                    .padding(.horizontal, 9).padding(.vertical, 3).background(Capsule().fill(.red))
            }
        }
    }
}

struct EcuFaultsView: View {
    @EnvironmentObject var session: DiagnosticSession
    let address: UInt8
    @State private var confirmClear = false

    private var ecu: EcuScanResult? { session.scanResults.first { $0.address == address } }

    var body: some View {
        List {
            if let ecu {
                Section {
                    LabeledContent("Address", value: ecu.addressText)
                    LabeledContent("Group", value: ecu.group)
                    LabeledContent("Variant", value: ecu.variant.uppercased())
                }
                if ecu.faults.isEmpty {
                    Section { Label("No faults stored", systemImage: "checkmark.circle").foregroundStyle(.green) }
                } else {
                    Section("\(ecu.faults.count) fault\(ecu.faults.count == 1 ? "" : "s")") {
                        ForEach(ecu.faults) { f in FaultRow(f: f) }
                    }
                    Section {
                        Button("Clear this ECU's faults", role: .destructive) { confirmClear = true }
                            .disabled(session.busy)
                        if session.busy { ProgressView() }
                    }
                }
            }
        }
        .navigationTitle(ecu?.name ?? "ECU")
        .confirmationDialog("Clear the fault memory of this ECU?", isPresented: $confirmClear, titleVisibility: .visible) {
            Button("Clear", role: .destructive) {
                if let ecu { Task { await session.clearScanned(ecu) } }
            }
            Button("Cancel", role: .cancel) {}
        }
    }
}
