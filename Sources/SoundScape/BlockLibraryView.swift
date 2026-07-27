import SwiftUI

struct BlockLibraryView: View {
    @EnvironmentObject private var audioUnitCatalog: AudioUnitCatalog
    @EnvironmentObject private var vst3Catalog: VST3Catalog
    @Binding var searchText: String
    let addItem: (LibraryItem) -> Void
    let dragChanged: (LibraryItem, CGPoint) -> Void
    let dropItem: (LibraryItem, CGPoint) -> Void
    let focusedField: FocusState<WorkspaceTextFocus?>.Binding
    @State private var draggingItemID: String?
    @State private var expandedSections: Set<String> = [
        "built-in",
        "audio-units",
        "vst3"
    ]

    private var librarySections: [LibrarySection] {
        let audioUnits = audioUnitCatalog.components.map { descriptor in
            LibraryItem(
                id: "audio-unit-\(descriptor.id)",
                title: descriptor.name,
                icon: "puzzlepiece.extension.fill",
                kind: .processor,
                nodeType: .audioUnit(descriptor)
            )
        }
        let vst3Plugins = vst3Catalog.components.map { descriptor in
            LibraryItem(
                id: "vst3-\(descriptor.id)",
                title: descriptor.name,
                icon: "waveform.badge.plus",
                kind: .processor,
                nodeType: .vst3(descriptor)
            )
        }

        return [
            DemoContent.builtInLibrarySection,
            LibrarySection(
                id: "audio-units",
                title: "Audio Units",
                items: audioUnits
            ),
            LibrarySection(
                id: "vst3",
                title: "VST3",
                items: vst3Plugins
            )
        ]
    }

    private var filteredSections: [LibrarySection] {
        librarySections.compactMap { section in
            let items = section.items.filter { item in
                searchText.isEmpty ||
                item.title.localizedCaseInsensitiveContains(searchText)
            }
            if items.isEmpty &&
                (!["audio-units", "vst3"].contains(section.id)
                    || !searchText.isEmpty) {
                return nil
            }
            return LibrarySection(id: section.id, title: section.title, items: items)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 13) {
                HStack {
                    Text("Block Library")
                        .font(.system(size: 15, weight: .bold))
                    Spacer()
                    Button {
                        audioUnitCatalog.refresh()
                        vst3Catalog.refresh()
                    } label: {
                        Image(
                            systemName: audioUnitCatalog.isScanning
                                ? "arrow.clockwise"
                                : "arrow.clockwise"
                        )
                        .foregroundStyle(AppTheme.secondaryText)
                    }
                    .buttonStyle(.plain)
                    .help("Rescan installed Audio Units and VST3 plug-ins")
                    .accessibilityLabel("Rescan audio plug-ins")
                }

                HStack(spacing: 8) {
                    Image(systemName: "magnifyingglass")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(AppTheme.tertiaryText)

                    TextField("Search blocks", text: $searchText)
                        .textFieldStyle(.plain)
                        .font(.system(size: 12))
                        .focused(focusedField, equals: .librarySearch)
                        .onSubmit {
                            focusedField.wrappedValue = nil
                            dismissTextInputFocus()
                        }
                        .onExitCommand {
                            focusedField.wrappedValue = nil
                            dismissTextInputFocus()
                        }

                    if !searchText.isEmpty {
                        Button {
                            searchText = ""
                            focusedField.wrappedValue = nil
                            dismissTextInputFocus()
                        } label: {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundStyle(AppTheme.tertiaryText)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(.horizontal, 11)
                .frame(height: 34)
                .background(Color.white.opacity(0.055))
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(AppTheme.line, lineWidth: 1)
                }
            }
            .padding(16)

            Rectangle()
                .fill(AppTheme.line)
                .frame(height: 1)

            ScrollView {
                // The library is intentionally small. Keeping all rows alive is
                // more stable than LazyVStack recycling inside a macOS
                // ScrollView, which can enter an expensive layout loop while
                // rapidly scrolling nested dynamic sections.
                VStack(spacing: 4) {
                    ForEach(filteredSections) { section in
                        librarySection(section)
                    }
                }
                .padding(.vertical, 10)
            }
        }
        .background(Color.black.opacity(0.10))
    }

    private func librarySection(_ section: LibrarySection) -> some View {
        VStack(spacing: 3) {
            Button {
                if expandedSections.contains(section.id) {
                    expandedSections.remove(section.id)
                } else {
                    expandedSections.insert(section.id)
                }
            } label: {
                HStack {
                    Image(systemName: expandedSections.contains(section.id) ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .bold))
                        .frame(width: 12)

                    Text(section.title.uppercased())
                        .font(.system(size: 10, weight: .bold))
                        .tracking(0.8)

                    Spacer()

                    Text("\(section.items.count)")
                        .font(.system(size: 10, weight: .semibold, design: .rounded))
                        .foregroundStyle(AppTheme.tertiaryText)
                }
                .foregroundStyle(AppTheme.secondaryText)
                .padding(.horizontal, 15)
                .frame(maxWidth: .infinity, minHeight: 30)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())

            if expandedSections.contains(section.id) {
                if section.items.isEmpty {
                    Text(emptyMessage(for: section))
                    .font(.system(size: 10.5, weight: .medium))
                    .foregroundStyle(AppTheme.tertiaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, 21)
                    .padding(.vertical, 10)
                } else {
                    ForEach(section.items) { item in
                        libraryRow(item)
                    }
                }
            }
        }
    }

    private func emptyMessage(for section: LibrarySection) -> String {
        if section.id == "vst3" {
            if vst3Catalog.isScanning {
                return "Scanning installed plug-ins…"
            }
            return vst3Catalog.errorMessage ?? "No compatible VST3 effects found"
        }
        if audioUnitCatalog.isScanning {
            return "Scanning installed plug-ins…"
        }
        return audioUnitCatalog.errorMessage ?? "No compatible AU effects found"
    }

    private func libraryRow(_ item: LibraryItem) -> some View {
        libraryRowLabel(item, showsAddIcon: true)
        .padding(.horizontal, 6)
        .contentShape(Rectangle())
        .onTapGesture {
            addItem(item)
        }
        .scaleEffect(draggingItemID == item.id ? 0.985 : 1)
        .opacity(draggingItemID == item.id ? 0.82 : 1)
        .simultaneousGesture(
            DragGesture(
                minimumDistance: 4,
                coordinateSpace: .global
            )
            .onChanged { value in
                draggingItemID = item.id
                dragChanged(item, value.location)
            }
            .onEnded { value in
                draggingItemID = nil
                dropItem(item, value.location)
            }
        )
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Add \(item.title)")
        .accessibilityAction {
            addItem(item)
        }
    }

    private func libraryRowLabel(
        _ item: LibraryItem,
        showsAddIcon: Bool
    ) -> some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DemoContent.cyan.opacity(0.09))

                Image(systemName: item.displayIcon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(DemoContent.cyan)
            }
            .frame(width: 34, height: 34)

            Text(item.title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)

            Spacer(minLength: 4)

            if showsAddIcon {
                Image(systemName: "plus")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(AppTheme.secondaryText)
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 42)
        .contentShape(Rectangle())
    }
}
