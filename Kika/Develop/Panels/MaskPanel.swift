//
//  MaskPanel.swift
//  Kika
//
//  Masks: "Create New Mask" (Linear Gradient / Radial Gradient / Brush; Select: Subject / Background / People /
//  Sky (beta) found by Vision, Object = click a subject — Masking/AIMasks.swift), the mask list
//  (select, show/hide, rename, duplicate, invert, delete) and, for the selected mask: its parts (main shape +
//  Add ▾ / Subtract ▾ shapes, Brush to paint / erase on any mask), the selected shape's options (found ones:
//  Expand, Feather; radial: Feather), brush settings, and local adjustment sliders. Drawing / editing happens
//  in MaskOverlayView.
//

import SwiftUI

struct MaskPanel: View {
    @Bindable var session: DevelopSession
    @State private var tool = MaskToolState.shared
    @State private var renamingID: UUID?
    @State private var draftName = ""
    private var store: ShortcutStore { .shared }

    var body: some View {
        InspectorSection("Masks") {
            VStack(alignment: .leading, spacing: 8) {
                createButtons
                if let hint { Text(hint).font(.caption).foregroundStyle(.secondary) }
                if !session.settings.masks.isEmpty { maskList }
                if let mask = session.selectedMask {
                    Divider()
                    options(for: mask)
                    Divider()
                    adjustments(for: mask)
                }
                if session.activeTool == .mask {
                    HStack {
                        Toggle("Show Overlay" + (store.binding(for: .maskOverlay).map { " (\($0.display))" } ?? ""), isOn: $tool.showOverlay)
                            .toggleStyle(.checkbox)
                            .help(store.help("Show the selected mask's coverage in red", .maskOverlay))
                        Spacer()
                        Button("Done") { session.finishMasking() }
                            .help(store.help("Leave the mask tool", .maskCancel))
                    }
                    .controlSize(.small)
                }
            }
        }
    }

    // MARK: Create

    private var createButtons: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                ForEach(MaskKind.shapes, id: \.self) { kind in
                    createButton(kind, help: "Create New Mask: \(kind.title)") { session.beginCreatingMask(kind) }
                }
            }
            Text("Select").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            HStack(spacing: 4) {
                ForEach(MaskKind.found, id: \.self) { kind in
                    createButton(kind, help: Self.foundHelp(kind)) {
                        if kind == .object { session.beginPickingObject() }
                        else if let target = kind.aiTarget { session.addAIMask(AIMask(target: target)) }
                    }
                }
            }
        }
    }

    private func createButton(_ kind: MaskKind, help: String, action: @escaping () -> Void) -> some View {
        let active = tool.pendingKind == kind && session.activeTool == .mask
        return Button(action: action) {
            VStack(spacing: 2) {
                Image(systemName: kind.systemImage).font(.body)
                Text(kind.title.replacingOccurrences(of: " Gradient", with: "")).font(.caption).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .background(RoundedRectangle(cornerRadius: 6).fill(active ? Color.accentColor.opacity(0.3) : Color.secondary.opacity(0.12)))
        .help(help)
        .accessibilityLabel("New \(kind.title) Mask")
    }

    private static func foundHelp(_ kind: MaskKind) -> String {
        switch kind {
        case .subject: "Select the subjects of the photo (people, animals, objects), found on this Mac"
        case .background: "Select everything but the subjects"
        case .people: "Select the people in the photo"
        case .sky: "Select the sky (beta: found by colour and position, check the overlay)"
        case .object: "Pick Object: click a subject on the photo to select just it"
        default: kind.title
        }
    }

    private var hint: String? {
        switch tool.pendingKind {
        case .linear?: return "Drag on the photo from where the effect is full to where it ends."
        case .radial?: return "Drag on the photo from the center outwards."
        case .brush?: return "Paint on the photo. ⌥ erases, \(brushKeys) change the size."
        case .object?:
            if tool.addingTo == nil { return "Click an object on the photo to select it. The ones found are tinted." }
            return tool.addMode == .add ? "Click objects to add them, ⌥-click to remove them. Esc when done."
                                        : "Click objects to remove them, ⌥-click to add them. Esc when done."
        case .subject?, .background?, .people?, .sky?: return nil
        case nil:
            if session.settings.masks.isEmpty { return "Create a mask, then adjust it with the sliders." }
            if session.activeTool == .mask, session.isBrushing {
                return tool.eraseMode ? "Paint to erase, ⌥ to add. \(brushKeys) size." : "Paint to add, ⌥ or Erase to remove. \(brushKeys) size."
            }
            return nil
        }
    }

    private var brushKeys: String {
        [store.display(.brushSmaller), store.display(.brushLarger)].filter { !$0.isEmpty }.joined(separator: " / ")
    }

    // MARK: List

    private var maskList: some View {
        VStack(spacing: 2) {
            ForEach(session.settings.masks) { mask in
                row(mask)
            }
        }
    }

    private func row(_ mask: Mask) -> some View {
        let selected = mask.id == session.selectedMaskID
        return HStack(spacing: 6) {
            Button {
                session.updateMask(mask.id) { $0.isEnabled.toggle() }
            } label: {
                Image(systemName: mask.isEnabled ? "eye" : "eye.slash")
                    .frame(width: 16)
                    .foregroundStyle(mask.isEnabled ? .primary : .secondary)
            }
            .buttonStyle(.borderless)
            .iconHelp(mask.isEnabled ? "Hide mask effect" : "Show mask effect")

            Image(systemName: mask.shape.kind.systemImage)
                .foregroundStyle(.secondary)
                .frame(width: 16)
            if renamingID == mask.id {
                TextField("Name", text: $draftName)
                    .textFieldStyle(.roundedBorder)
                    .controlSize(.small)
                    .onSubmit { commitRename(mask.id) }
                    .onExitCommand { renamingID = nil }
            } else {
                Text(mask.name)
                    .lineLimit(1)
                    .foregroundStyle(mask.isEnabled ? .primary : .secondary)
            }
            Spacer(minLength: 4)
            if mask.inverted {
                Image(systemName: "circle.lefthalf.filled").foregroundStyle(.secondary).help("Inverted")
                    .accessibilityLabel("Inverted")
            }
            Menu {
                menuItems(mask)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .iconHelp("Mask actions: rename, duplicate, invert, hide, delete")
        }
        .font(.callout)
        .padding(.vertical, 3)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Color.accentColor.opacity(0.25) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { session.selectMask(mask.id) }
        .contextMenu { menuItems(mask) }
    }

    @ViewBuilder
    private func menuItems(_ mask: Mask) -> some View {
        Button("Rename…") {
            draftName = mask.name
            renamingID = mask.id
        }
        Button("Duplicate") { session.duplicateMask(mask.id) }
        Button(mask.inverted ? "Don't Invert" : "Invert") {
            session.updateMask(mask.id) { $0.inverted.toggle() }
        }
        Button(mask.isEnabled ? "Hide" : "Show") {
            session.updateMask(mask.id) { $0.isEnabled.toggle() }
        }
        Divider()
        Button("Delete", role: .destructive) { session.deleteMask(mask.id) }
    }

    private func commitRename(_ id: UUID) {
        let name = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !name.isEmpty { session.updateMask(id) { $0.name = name } }
        renamingID = nil
    }

    // MARK: Selected mask

    @ViewBuilder
    private func options(for mask: Mask) -> some View {
        Toggle("Invert", isOn: Binding(
            get: { session.mask(id: mask.id)?.inverted ?? false },
            set: { v in session.updateMask(mask.id) { $0.inverted = v } }))
            .toggleStyle(.checkbox)
            .help("Apply the adjustments outside the mask instead")
        parts(of: mask)
        if let ref = session.selectedRef, ref.mask == mask.id, let shape = session.shape(ref) {
            shapeOptions(shape, ref: ref)
        }
        if session.isBrushing { brushOptions(mask) }
    }

    /// The mask's shapes (when it has parts) and Add ▾ / Subtract ▾ / Brush.
    @ViewBuilder
    private func parts(of mask: Mask) -> some View {
        if !mask.parts.isEmpty {
            VStack(spacing: 1) {
                partRow(mask.shape, mode: nil, ref: MaskRef(mask: mask.id))
                ForEach(mask.parts) { part in
                    partRow(part.shape, mode: part.shape.brush != nil ? nil : part.mode, ref: MaskRef(mask: mask.id, part: part.id))
                }
            }
        }
        HStack(spacing: 6) {
            partMenu("Add", mode: .add, mask: mask)
            partMenu("Subtract", mode: .subtract, mask: mask)
            Spacer()
            if mask.brush == nil {
                Toggle(isOn: Binding(get: { tool.refining && session.selectedMaskID == mask.id },
                                     set: { on in
                                         if on { session.beginAddingPart(.brush, mode: tool.eraseMode ? .subtract : .add, to: mask.id) }
                                         else { tool.refining = false }
                                     })) {
                    Label("Brush", systemImage: MaskKind.brush.systemImage)
                }
                .toggleStyle(.button)
                .help("Paint on this mask to add to it, ⌥ to erase (cleans up found masks and gradients)")
            }
        }
        .controlSize(.small)
    }

    private func partMenu(_ title: String, mode: MaskPart.Mode, mask: Mask) -> some View {
        Menu(title) {
            ForEach(MaskKind.shapes, id: \.self) { kind in
                Button(kind.title, systemImage: kind.systemImage) { session.beginAddingPart(kind, mode: mode, to: mask.id) }
            }
            Divider()
            ForEach(MaskKind.found, id: \.self) { kind in
                Button(kind == .object ? "Object…" : kind.title, systemImage: kind.systemImage) {
                    session.beginAddingPart(kind, mode: mode, to: mask.id)
                }
            }
        }
        .fixedSize()
        .help(mode == .add ? "Add a shape to this mask" : "Remove a shape from this mask (Subtract Sky, an object, a gradient…)")
    }

    private func partRow(_ shape: MaskShape, mode: MaskPart.Mode?, ref: MaskRef) -> some View {
        let selected = session.selectedRef == ref
        return HStack(spacing: 6) {
            Image(systemName: ref.part == nil ? "circle.fill" : mode == .subtract ? "minus" : mode == .add ? "plus" : "paintbrush.pointed")
                .font(.caption2)
                .frame(width: 12)
                .foregroundStyle(.secondary)
            Image(systemName: shape.kind.systemImage).foregroundStyle(.secondary).frame(width: 16)
            Text(ref.part == nil ? shape.kind.title : shape.brush != nil ? "Brush" : "\(mode == .subtract ? "Subtract" : "Add") \(shape.kind.title)")
                .lineLimit(1)
            Spacer(minLength: 4)
            if ref.part != nil {
                Button { session.deletePart(ref) } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.borderless)
                    .iconHelp("Remove this part")
            }
        }
        .font(.callout)
        .padding(.vertical, 2)
        .padding(.horizontal, 6)
        .background(RoundedRectangle(cornerRadius: 4).fill(selected ? Color.accentColor.opacity(0.18) : Color.clear))
        .contentShape(Rectangle())
        .onTapGesture { session.selectPart(ref) }
    }

    /// Options of the selected shape (the mask's own or a part).
    @ViewBuilder
    private func shapeOptions(_ shape: MaskShape, ref: MaskRef) -> some View {
        if let ai = shape.ai { aiOptions(ai, ref: ref) }
        if shape.radial != nil {
            DevelopSlider(title: "Feather", value: Binding(
                get: { session.shape(ref)?.radial?.feather ?? 50 },
                set: { v in session.updateShape(ref) { $0.radial?.feather = v } }),
                range: 0...100, defaultValue: 50, format: .integer, onEditingChanged: endEdit)
        }
    }

    private func brushOptions(_ mask: Mask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle("Erase (⌥)", isOn: $tool.eraseMode).toggleStyle(.checkbox)
                .help("Brush strokes erase the mask (⌥ while painting does the other)")
            DevelopSlider(title: "Size", value: $tool.brushSize, range: MaskToolState.sizeRange, defaultValue: 16,
                          scale: .logarithmic, format: .integer)
                .help(store.help("Brush size on screen: the same at every zoom, so zooming in paints finer strokes", [.brushSmaller, .brushLarger]))
            DevelopSlider(title: "Feather", value: $tool.brushFeather, range: 0...100, defaultValue: 50, format: .integer)
                .help("How soft the brush edge is")
            DevelopSlider(title: "Flow", value: $tool.brushFlow, range: 0...100, defaultValue: 100, format: .integer)
                .help("How much each stroke adds (or removes)")
            let target = session.selectedShape?.brush != nil ? session.selectedRef : mask.brushTarget
            Button("Clear Strokes") {
                guard let target else { return }
                session.commitUndoGroup()
                session.updateShape(target) { $0.brush?.strokes = [] }
                session.commitUndoGroup()
            }
            .controlSize(.small)
            .disabled(target.flatMap { session.shape($0)?.brush?.strokes.isEmpty == false } != true)
            .help("Remove the brush strokes of this mask")
        }
    }

    /// What Vision found, Expand / Feather, and for objects: Add Object / Pick Again.
    @ViewBuilder
    private func aiOptions(_ ai: AIMask, ref: MaskRef) -> some View {
        if let source = session.source {
            let key = AIMaskEngine.key(ai, source: source)
            aiStatus(ai, state: AIMaskStatus.shared.states[key])
                .task(id: key) { AIMaskStatus.shared.prepare(ai, source: source) }
        }
        DevelopSlider(title: "Expand", value: Binding(
            get: { session.shape(ref)?.ai?.expand ?? 0 },
            set: { v in session.updateShape(ref) { $0.ai?.expand = v } }),
            range: -100...100, defaultValue: 0, format: .signedInteger, onEditingChanged: endEdit,
            help: "Shrink (−) or grow (+) what was found, to drop or take in its edge")
        DevelopSlider(title: "Feather", value: Binding(
            get: { session.shape(ref)?.ai?.feather ?? 0 },
            set: { v in session.updateShape(ref) { $0.ai?.feather = v } }),
            range: 0...100, defaultValue: 0, format: .integer, onEditingChanged: endEdit,
            help: "Soften the edge of what was found")
        if ai.target == .object {
            let mode = session.mask(id: ref.mask)?.parts.first { $0.id == ref.part }?.mode ?? .add
            HStack {
                if ref.part == nil {
                    Button("Add Object") { session.beginPickingObject(adding: ref.mask) }
                        .help("Click more objects on the photo to add them to this mask (⌥-click removes)")
                }
                Button("Pick Again") {
                    session.updateShape(ref) { $0.ai?.points = [] }
                    if ref.part != nil { session.deletePart(ref) }
                    session.beginPickingObject(adding: ref.mask, mode: mode)
                }
                .help("Clear this selection and click the object to select")
            }
            .controlSize(.small)
        }
    }

    @ViewBuilder
    private func aiStatus(_ ai: AIMask, state: AIMaskStatus.State?) -> some View {
        switch state {
        case .computing?, nil:
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text(ai.target == .sky ? "Looking for the sky…" : ai.target == .people ? "Looking for people…" : "Looking for subjects…")
            }
            .font(.caption).foregroundStyle(.secondary)
        case .done(let found, let coverage)?:
            let percent = "\(Int((coverage * 100).rounded())) % of the photo"
            Group {
                if found == 0 {
                    switch ai.target {
                    case .background: Text("No subject found: the whole photo is selected.")
                    case .object where ai.points.isEmpty: Text("Click a subject on the photo.")
                    case .object: Text("No subject there. Click on a person, animal or object.")
                    case .sky: Text("No sky found.")
                    case .people: Text("No people found.")
                    case .subject: Text("No subject found.")
                    }
                } else {
                    switch ai.target {
                    case .subject, .object: Text("\(found) subject\(found == 1 ? "" : "s") · \(percent)")
                    case .background, .people: Text(percent)
                    case .sky: Text("Sky (beta) · \(percent)")
                    }
                }
            }
            .font(.caption)
            .foregroundStyle(found == 0 ? Color.orange : Color.secondary)
        case .failed(let message)?:
            Text("Couldn't analyse the photo: \(message)").font(.caption).foregroundStyle(.red)
        }
    }

    private static let sliders: [(String, WritableKeyPath<LocalAdjustments, Double>)] = [
        ("Temp", \.temperature), ("Tint", \.tint), ("Exposure", \.exposure), ("Contrast", \.contrast),
        ("Highlights", \.highlights), ("Shadows", \.shadows), ("Whites", \.whites), ("Blacks", \.blacks),
        ("Texture", \.texture), ("Clarity", \.clarity), ("Dehaze", \.dehaze), ("Saturation", \.saturation),
    ]

    @ViewBuilder
    private func adjustments(for mask: Mask) -> some View {
        HStack {
            Text("Adjustments").font(.subheadline.weight(.semibold))
            Spacer()
            Button("Reset") {
                session.commitUndoGroup()
                session.updateMask(mask.id) { $0.adjustments = LocalAdjustments() }
                session.commitUndoGroup()
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
            .disabled(mask.adjustments.isDefault)
            .help("Reset this mask's adjustments")
        }
        ForEach(Self.sliders, id: \.0) { title, keyPath in
            let isExposure = keyPath == \LocalAdjustments.exposure
            DevelopSlider(title: title, value: Binding(
                get: { session.mask(id: mask.id)?.adjustments[keyPath: keyPath] ?? 0 },
                set: { v in session.updateMask(mask.id) { $0.adjustments[keyPath: keyPath] = v } }),
                range: isExposure ? LocalAdjustments.exposureRange : LocalAdjustments.range,
                format: isExposure ? .signedDecimal(2) : .signedInteger,
                step: isExposure ? 0.01 : 1,
                onEditingChanged: endEdit)
        }
    }

    private func endEdit(_ editing: Bool) {
        if !editing { session.commitUndoGroup() }
    }
}
