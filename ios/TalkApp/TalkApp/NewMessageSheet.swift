import SwiftUI
import PttTalkLib

/// The directory and group wizard deliberately keep selection when a request fails.
struct NewMessageSheet: View {
    @ObservedObject var model: TalkModel
    var onOpened: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var selected: Set<String> = []
    @State private var group = false
    @State private var reviewing = false
    @State private var name = ""
    @State private var loading = true
    @State private var sending = false
    @State private var error: String?

    private var members: [DirectoryMember] {
        model.directoryMembers.filter {
            query.isEmpty || $0.displayName.localizedCaseInsensitiveContains(query)
        }.sorted { $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending }
    }

    var body: some View {
        NavigationStack {
            List {
                if let error {
                    Section {
                        Text(error).foregroundStyle(.red)
                        if !sending { Button("Retry loading teammates") { Task { await load() } } }
                    }
                }
                if loading {
                    ProgressView("Loading teammates…")
                } else if reviewing {
                    Section("Group name") { TextField("Name your group", text: $name) }
                    Section("Members · \(selected.count + 1) of 8") {
                        Text("You")
                        ForEach(model.directoryMembers.filter { selected.contains($0.aci) }) { member in
                            Text(member.displayName)
                        }
                    }
                    Section { Text("Your private group includes you and up to seven teammates.").font(.footnote) }
                } else {
                    if !group {
                        Button { group = true; query = "" } label: { Label("New group", systemImage: "person.2.badge.plus") }
                    } else {
                        Text("Choose 2–7 teammates. Groups support eight people including you.").font(.footnote)
                    }
                    if members.isEmpty {
                        Text(query.isEmpty ? "No teammates yet. Ask your administrator to invite someone." : "No teammates match your search.")
                    }
                    ForEach(members) { member in
                        Button {
                            if group {
                                if selected.contains(member.aci) { selected.remove(member.aci) }
                                else if selected.count < 7 { selected.insert(member.aci) }
                            } else { Task { await open([member.aci]) } }
                        } label: {
                            HStack(spacing: 12) {
                                Text(member.displayName.split(separator: " ").prefix(2).compactMap(\.first).map(String.init).joined().uppercased())
                                    .font(.subheadline.weight(.semibold)).frame(width: 42, height: 42)
                                    .background(Color.accentColor.opacity(0.12), in: Circle())
                                    .accessibilityHidden(true)
                                Text(member.displayName).foregroundStyle(.primary)
                                Spacer()
                                if group { Image(systemName: selected.contains(member.aci) ? "checkmark.circle.fill" : "circle") }
                            }.padding(.vertical, 4)
                        }
                        .disabled(sending || (group && selected.count == 7 && !selected.contains(member.aci)))
                        .accessibilityValue(group ? (selected.contains(member.aci) ? "Selected" : "Not selected") : "")
                    }
                }
                if sending { ProgressView("Opening encrypted conversation…") }
            }
            .searchable(text: $query, prompt: "Search teammates")
            .navigationTitle(reviewing ? "Review group" : (group ? "New group" : "New message"))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(reviewing || group ? "Back" : "Cancel") {
                        if reviewing { reviewing = false }
                        else if group { group = false; selected = []; query = "" }
                        else { dismiss() }
                    }.disabled(sending)
                }
                ToolbarItem(placement: .confirmationAction) {
                    if group {
                        Button(reviewing ? "Create" : "Next") {
                            if reviewing { Task { await open(Array(selected).sorted()) } }
                            else { reviewing = true; query = "" }
                        }.disabled(sending || selected.count < 2 || (reviewing && name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                    }
                }
            }
            .task { await load() }
            .interactiveDismissDisabled(sending)
        }
    }

    private func load() async {
        loading = true
        error = await model.loadMessageDirectory()
        loading = false
    }

    private func open(_ ids: [String]) async {
        sending = true
        if await model.createConversation(memberAcis: ids, displayName: group ? name.trimmingCharacters(in: .whitespacesAndNewlines) : "") {
            onOpened()
        } else { error = "Could not open the conversation. Check your connection and try again. Your selection is saved." }
        sending = false
    }
}
