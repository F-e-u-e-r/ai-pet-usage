import SwiftUI
import UsageCore
import PetCore

struct SettingsRoot: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gear") }
            PetSettings().tabItem { Label("Pet", systemImage: "pawprint") }
            ProviderSettings().tabItem { Label("Providers", systemImage: "puzzlepiece.extension") }
            LimitsPricingSettings().tabItem { Label("Limits & Pricing", systemImage: "dollarsign.gauge.chart.lefthalf.righthalf") }
            DataPrivacySettings().tabItem { Label("Data & Privacy", systemImage: "lock.shield") }
        }
        .frame(width: 560, height: 460)
    }
}

// MARK: - General(含 App Mode / 低 RAM 模式)

struct GeneralSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                Picker("App mode", selection: Binding(
                    get: { model.settings.appMode },
                    set: { mode in model.updateSettings { $0.appMode = mode } }
                )) {
                    ForEach(AppMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.radioGroup)
                Text("Monitor only skips the floating pet window, animations, and the feeding/XP engine entirely — useful when RAM is tight. Usage tracking, the menu bar, all three pages, notifications, and HTML export keep working.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Picker("Menu bar", selection: Binding(
                    get: { model.settings.menuBarDisplayMode },
                    set: { v in model.updateSettings { $0.menuBarDisplayMode = v } }
                )) {
                    ForEach(MenuBarDisplayMode.allCases, id: \.self) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                Text("Full lists every detected provider (● CC 91%). Compact keeps only providers at or above the warning threshold. Percent colors: orange ≥ warn, red ≥ alert threshold.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Slider(value: Binding(
                    get: { model.settings.refreshIntervalSeconds },
                    set: { v in model.updateSettings { $0.refreshIntervalSeconds = v } }
                ), in: 15...300, step: 15) {
                    Text("Refresh every \(Int(model.settings.refreshIntervalSeconds))s")
                }
                Toggle("Notifications (thresholds & resets)", isOn: Binding(
                    get: { model.settings.notificationsEnabled },
                    set: { v in
                        model.updateSettings { $0.notificationsEnabled = v }
                        if v { Notifier.requestAuthorization() }
                    }
                ))
                if !Notifier.available {
                    Text("System notifications need the bundled app (Scripts/build-app.sh). Running via `swift run` logs to console instead.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Launch at login at startup", isOn: Binding(
                    get: { model.settings.launchAtLogin },
                    set: { v in model.setLaunchAtLogin(v) }
                ))
                if !LaunchAtLogin.available {
                    Text("Launch at login needs the bundled app (Scripts/build-app.sh).")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Toggle("Quiet mode (freeze animations, silence notifications)", isOn: Binding(
                    get: { model.settings.quietMode },
                    set: { v in model.updateSettings { $0.quietMode = v } }
                ))
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Pet

struct PetSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            if model.settings.appMode == .monitorOnly {
                Section {
                    Label("Pet is disabled in Monitor-only mode. Switch back in General to re-enable.",
                          systemImage: "moon.zzz")
                        .foregroundStyle(.secondary)
                }
            }
            Section {
                Picker("Pet", selection: Binding(
                    get: { model.settings.species },
                    set: { v in model.updateSettings { $0.species = v } }
                )) {
                    ForEach(PetSpecies.allCases, id: \.self) { s in
                        Text(s.displayName).tag(s)
                    }
                }
                Toggle("Wander along the screen edge when idle", isOn: Binding(
                    get: { model.settings.petWanderEnabled },
                    set: { v in model.updateSettings { $0.petWanderEnabled = v } }
                ))
                Toggle("Speech bubbles on mood changes", isOn: Binding(
                    get: { model.settings.petSpeechEnabled },
                    set: { v in model.updateSettings { $0.petSpeechEnabled = v } }
                ))
                Text("Wandering pauses during warnings, quiet mode, and when Reduce Motion is enabled. The pet never steals focus or blocks clicks (enable click-through below to make it fully untouchable).")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Show pet", isOn: Binding(
                    get: { model.settings.petVisible },
                    set: { v in model.updateSettings { $0.petVisible = v } }
                ))
                Slider(value: Binding(
                    get: { model.settings.petSize },
                    set: { v in model.updateSettings { $0.petSize = v } }
                ), in: 64...160, step: 8) {
                    Text("Size (\(Int(model.settings.petSize))pt)")
                }
                Slider(value: Binding(
                    get: { model.settings.petOpacity },
                    set: { v in model.updateSettings { $0.petOpacity = v } }
                ), in: 0.35...1.0) {
                    Text("Opacity")
                }
                Toggle("Click-through (pet ignores the mouse)", isOn: Binding(
                    get: { model.settings.clickThrough },
                    set: { v in model.updateSettings { $0.clickThrough = v } }
                ))
                Text("Drag the pet anywhere; its position is remembered. Click it for a status bubble; right-click to feed.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .disabled(model.settings.appMode == .monitorOnly)

            if model.settings.appMode == .full {
                Section("Care") {
                    LabeledContent("Level", value: "\(model.petState.level)  (\(Int(model.petState.xp)) XP)")
                    LabeledContent("Fullness", value: "\(Int(model.petState.hunger))%")
                    LabeledContent("Treats available", value: "\(model.treatsAvailable)")
                    LabeledContent("Total feeds", value: "\(model.petState.totalFeeds)")
                    Text("Treats are earned by real work time (1 per 25 active minutes, max 6/day). Token XP caps at 200/day; finishing a day without warnings grants +50 XP. Burning tokens for its own sake earns nothing extra.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }
}

// MARK: - Providers

struct ProviderSettings: View {
    @Environment(AppModel.self) private var model
    @State private var infos: [(providerId: String, displayName: String, availability: ProviderAvailability, dataSources: String, permissions: String)] = []

    var body: some View {
        Form {
            ForEach(infos, id: \.providerId) { info in
                Section(info.displayName) {
                    Toggle("Enabled", isOn: Binding(
                        get: { model.settings.core.enabledProviders.contains(info.providerId) },
                        set: { on in
                            model.updateSettings {
                                if on { $0.core.enabledProviders.insert(info.providerId) }
                                else { $0.core.enabledProviders.remove(info.providerId) }
                            }
                            Task { await model.refreshNow() }
                        }
                    ))
                    LabeledContent("Detected", value: info.availability.available ? "yes — \(info.availability.detail)" : "no")
                    Text(info.dataSources).font(.caption).foregroundStyle(.secondary)
                    Text(info.permissions).font(.caption2).foregroundStyle(.tertiary)
                }
            }

            // 選單列/量表短代號圖例(UIUX spec P2):dot = 身分色,恆定不變
            Section("Menu bar legend") {
                ForEach(ProviderBrands.known, id: \.id) { brand in
                    HStack(spacing: 8) {
                        ProviderDot(brand: brand)
                        Text(brand.code)
                            .font(.system(.caption, design: .monospaced).weight(.semibold))
                            .frame(width: 24, alignment: .leading)
                        Text(brand.displayName)
                        Spacer()
                    }
                }
                Text("The dot color identifies the provider and never changes; the percent text turns orange/red with usage severity. Antigravity and Grok Code appear automatically once their adapters ship.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .task { infos = await model.coordinator.adapterInfos() }
    }
}

// MARK: - Limits & Pricing

struct LimitsPricingSettings: View {
    @Environment(AppModel.self) private var model
    @State private var seenModels: [(model: ModelUsageSummary, price: ModelPrice?)] = []
    @State private var editingModel: String?
    @State private var inputPrice = ""
    @State private var outputPrice = ""
    @State private var cachePrice = ""

    var body: some View {
        Form {
            Section("Warning thresholds") {
                Slider(value: Binding(
                    get: { model.settings.core.warnThresholdPercent },
                    set: { v in model.updateSettings { $0.core.warnThresholdPercent = v } }
                ), in: 50...95, step: 5) {
                    Text("Warn at \(Int(model.settings.core.warnThresholdPercent))%")
                }
                Slider(value: Binding(
                    get: { model.settings.core.dangerThresholdPercent },
                    set: { v in model.updateSettings { $0.core.dangerThresholdPercent = v } }
                ), in: 80...100, step: 5) {
                    Text("Alert again at \(Int(model.settings.core.dangerThresholdPercent))%")
                }
            }

            Section("Claude Code estimated budgets (fallback)") {
                Text("Statusline official values take priority; token budgets are fallback estimates. Claude Code's own statusline payload carries official 5h/weekly percentages — any statusline hook that saves it (e.g. Scripts/claude-statusline-hook.sh) enables them automatically. Budgets only kick in when no fresh statusline data exists. Codex never needs budgets.")
                    .font(.caption).foregroundStyle(.secondary)
                BudgetField(label: "5-hour budget (tokens)", value: Binding(
                    get: { model.settings.core.claudeFiveHourTokenBudget },
                    set: { v in model.updateSettings { $0.core.claudeFiveHourTokenBudget = v } }
                ))
                BudgetField(label: "Weekly budget (tokens)", value: Binding(
                    get: { model.settings.core.claudeWeeklyTokenBudget },
                    set: { v in model.updateSettings { $0.core.claudeWeeklyTokenBudget = v } }
                ))
            }

            Section("Model pricing (last 30 days of models seen)") {
                if seenModels.isEmpty {
                    Text("No models seen yet.").foregroundStyle(.secondary)
                }
                ForEach(seenModels, id: \.model.id) { entry in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("\(entry.model.providerId)/\(entry.model.modelId)").font(.callout)
                            Spacer()
                            if let price = entry.price {
                                Text("$\(price.inputPerMillion, specifier: "%.2f") in / $\(price.outputPerMillion, specifier: "%.2f") out per M\(price.userOverride ? " (override)" : "")")
                                    .font(.caption).foregroundStyle(.secondary)
                            } else {
                                Text("unknown — excluded from cost").font(.caption).foregroundStyle(.orange)
                            }
                            Button("Set price…") {
                                editingModel = entry.model.id
                                inputPrice = entry.price.map { String($0.inputPerMillion) } ?? ""
                                outputPrice = entry.price.map { String($0.outputPerMillion) } ?? ""
                                cachePrice = entry.price?.cacheReadPerMillion.map { String($0) } ?? ""
                            }
                            .controlSize(.small)
                        }
                        if editingModel == entry.model.id {
                            HStack {
                                TextField("$/M input", text: $inputPrice).frame(width: 90)
                                TextField("$/M output", text: $outputPrice).frame(width: 90)
                                TextField("$/M cache read", text: $cachePrice).frame(width: 110)
                                Button("Save") { saveOverride(entry.model) }.controlSize(.small)
                                Button("Cancel") { editingModel = nil }.controlSize(.small)
                            }
                            .textFieldStyle(.roundedBorder)
                            .font(.caption)
                        }
                    }
                }
                Text("Pricing snapshots ship with the app and may lag provider price changes — verify against the provider's pricing page. Overrides are stored locally in pricing-overrides.json.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }
        }
        .formStyle(.grouped)
        .task { seenModels = await model.coordinator.modelsSeenWithPricing() }
    }

    private func saveOverride(_ m: ModelUsageSummary) {
        guard let input = Double(inputPrice), let output = Double(outputPrice) else { return }
        let price = ModelPrice(
            providerId: m.providerId, modelId: m.modelId, displayName: m.modelId,
            inputPerMillion: input, outputPerMillion: output,
            cacheReadPerMillion: Double(cachePrice),
            effectiveFrom: PetStateData.dayKey(for: Date()),
            source: "user override", userOverride: true
        )
        editingModel = nil
        Task {
            await model.coordinator.addPricingOverride(price)
            seenModels = await model.coordinator.modelsSeenWithPricing()
            await model.refreshNow()
        }
    }
}

struct BudgetField: View {
    let label: String
    @Binding var value: Int?
    @State private var text = ""

    var body: some View {
        HStack {
            TextField(label, text: $text, prompt: Text("empty = percent off"))
                .textFieldStyle(.roundedBorder)
                .onAppear { text = value.map(String.init) ?? "" }
                .onSubmit { value = Int(text.replacingOccurrences(of: ",", with: "")) }
            Button("Apply") { value = Int(text.replacingOccurrences(of: ",", with: "")) }
                .controlSize(.small)
        }
    }
}

// MARK: - Data & Privacy

struct DataPrivacySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section("Local data") {
                LabeledContent("App data folder", value: AppPaths.dataDirectory().path)
                HStack {
                    Button("Open Data Folder") {
                        NSWorkspace.shared.open(AppPaths.dataDirectory())
                    }
                    Button(model.reindexing ? "Reindexing…" : "Full Reindex") {
                        Task { await model.fullReindex() }
                    }
                    .disabled(model.reindexing)
                }
                Text("Full reindex rebuilds the local ledger from provider logs. It is the only operation allowed to lower a usage percent inside an active window; any such correction is labelled in the UI and reports.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Scheduled export") {
                Toggle("Daily auto-export (HTML report)", isOn: Binding(
                    get: { model.settings.dailyExportEnabled },
                    set: { v in
                        model.updateSettings { $0.dailyExportEnabled = v }
                        model.applyScheduledExport()
                    }
                ))
                if model.settings.dailyExportEnabled {
                    DatePicker("Time", selection: Binding(
                        get: {
                            var c = DateComponents()
                            c.hour = model.settings.dailyExportHour
                            c.minute = model.settings.dailyExportMinute
                            return Calendar.current.date(from: c) ?? Date()
                        },
                        set: { d in
                            let comps = Calendar.current.dateComponents([.hour, .minute], from: d)
                            model.updateSettings {
                                $0.dailyExportHour = comps.hour ?? 9
                                $0.dailyExportMinute = comps.minute ?? 0
                            }
                            model.applyScheduledExport()
                        }
                    ), displayedComponents: .hourAndMinute)

                    Picker("Range", selection: Binding(
                        get: { model.settings.dailyExportRangeDays },
                        set: { v in
                            model.updateSettings { $0.dailyExportRangeDays = v }
                            model.applyScheduledExport()
                        }
                    )) {
                        Text("7 days").tag(7)
                        Text("30 days").tag(30)
                        Text("90 days").tag(90)
                    }

                    HStack {
                        Text("Folder")
                        Spacer()
                        Text(model.settings.dailyExportFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "Not set")
                            .foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                        Button("Choose…") { chooseExportFolder() }
                    }
                }
                if !ScheduledReportManager.available {
                    Text("Scheduled export needs the bundled app (Scripts/build-app.sh); it runs the bundled aipet CLI via a per-user LaunchAgent.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Section("Privacy") {
                Text("""
                • All parsing and storage happen on this Mac. Nothing is uploaded; there is no telemetry and no account login.
                • Only token counts, model IDs, project paths, timestamps, and rate-limit numbers are read — never prompts or message contents.
                • HTML reports are local files and redact full project paths by default.
                """)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func chooseExportFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url {
            model.updateSettings { $0.dailyExportFolderPath = url.path }
            model.applyScheduledExport()
        }
    }
}
