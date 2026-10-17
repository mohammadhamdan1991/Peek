#if !PEEK_DISABLED && canImport(UIKit)
import SwiftUI
import PeekCore

/// One flag: its value from each source, an editor for the override, and how often the app read it.
/// Booleans get a switch; numbers and strings a text field; objects, arrays and unknown flags a JSON editor.
struct FlagDetailView: View {
    let key: String

    @State private var flag: FlagStore.Flag?
    @State private var draft = ""
    @FocusState private var isEditing: Bool
    private let store = Inspector.flags

    var body: some View {
        List {
            if let flag {
                Section("Override") { editor(for: flag) }
                Section("Value") {
                    valueRow(store.source, flag.remote, fallback: "Not in \(store.source)")
                    valueRow("Code default", flag.defaultValue, fallback: "Known once the app reads it")
                }
                Section {
                    LabeledContent("Reads", value: "\(flag.reads)")
                    if let lastRead = flag.lastRead { LabeledContent("Last read", value: Format.age(lastRead)) }
                } header: {
                    Text("Reads")
                } footer: {
                    Text("Screens that watch this flag update now. Values read once at launch change on the next launch.")
                }
                Section {
                    Button("Quit app to relaunch", role: .destructive) { exit(0) }
                        .foregroundStyle(Theme.failureText)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Theme.ground)
        .foregroundStyle(Theme.text)
        .navigationTitle(key)
        .navigationBarTitleDisplayMode(.inline)
        .onAppear(perform: reload)
    }

    @ViewBuilder private func editor(for flag: FlagStore.Flag) -> some View {
        switch kind(of: flag) {
        case .bool:
            Toggle(isOn: Binding(
                get: { flag.value == .bool(true) },
                set: { save(.bool($0)) }
            )) {
                Text(flag.isOverridden ? "Overridden" : "Tap to override")
                    .foregroundStyle(flag.isOverridden ? Theme.accent : Theme.secondaryText)
            }
            .tint(Theme.accent)
        case .number, .string:
            TextField("Value", text: $draft)
                .font(Theme.mono)
                .keyboardType(kind(of: flag) == .number ? .decimalPad : .default)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isEditing)
            saveButton(parsed(flag))
        case .json:
            TextEditor(text: $draft)
                .font(Theme.mono)
                .frame(minHeight: 140)
                .scrollContentBackground(.hidden)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .focused($isEditing)
            let value = parsed(flag)
            Label(value == nil ? "Not valid JSON" : "Valid JSON", systemImage: value == nil ? "xmark.circle" : "checkmark.circle")
                .font(.footnote)
                .foregroundStyle(value == nil ? Theme.failureText : Theme.success)
            HStack {
                Button("Format") { if let value { draft = value.json(pretty: true) } }
                    .disabled(value == nil)
                Spacer()
                if let remote = flag.remote {
                    Button("Copy \(store.source) value") { draft = remote.json(pretty: true) }
                }
            }
            .buttonStyle(.borderless)
            .font(.footnote)
            saveButton(value)
        }
        if flag.isOverridden {
            Button("Remove override", role: .destructive) { save(nil) }
                .foregroundStyle(Theme.failureText)
        }
    }

    private func saveButton(_ value: FlagValue?) -> some View {
        Button("Save override") { save(value) }
            .disabled(value == nil || value == flag?.override)
    }

    private func valueRow(_ title: String, _ value: FlagValue?, fallback: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption).foregroundStyle(Theme.tertiaryText)
            if let value {
                Text(value.json(pretty: true))
                    .font(Theme.mono)
                    .foregroundStyle(Theme.secondaryText)
                    .textSelection(.enabled)
            } else {
                Text(fallback).font(.footnote).foregroundStyle(Theme.tertiaryText)
            }
        }
    }

    private enum Kind { case bool, number, string, json }

    /// From the value the app sees now; a flag nobody has served yet is edited as JSON.
    private func kind(of flag: FlagStore.Flag) -> Kind {
        switch flag.value {
        case .bool: .bool
        case .number: .number
        case .string: .string
        default: .json
        }
    }

    private func parsed(_ flag: FlagStore.Flag) -> FlagValue? {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        switch kind(of: flag) {
        case .number: return Double(text).map(FlagValue.number)
        case .string: return .string(draft)
        default: return FlagValue(json: text)
        }
    }

    private func save(_ value: FlagValue?) {
        store.setOverride(value, for: key)
        isEditing = false
        Toast.shared.show(value == nil ? "Override removed" : "Override saved")
        reload()
    }

    private func reload() {
        flag = store.flags.first { $0.key == key }
        guard let flag, let value = flag.value else { return draft = "" }
        draft = switch value {
        case let .string(text): text
        case .array, .object: value.json(pretty: true)
        default: value.json()
        }
    }
}
#endif
