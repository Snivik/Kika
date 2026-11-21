//
//  DevelopSession+Masks.swift
//  Kika
//
//  Mask helpers for the panel and overlay. All edits go through `settings`, so they are
//  saved, rendered and undoable like any other change.
//

import Foundation

extension DevelopSession {
    var selectedMask: Mask? { selectedMaskID.flatMap(mask(id:)) }

    func mask(id: UUID) -> Mask? { settings.masks.first { $0.id == id } }

    /// The selected mask's main shape or selected part.
    var selectedRef: MaskRef? { selectedMaskID.map { MaskRef(mask: $0, part: selectedPartID) } }
    var selectedShape: MaskShape? { selectedRef.flatMap(shape) }

    func shape(_ ref: MaskRef) -> MaskShape? { mask(id: ref.mask)?.shape(part: ref.part) }

    /// Mutates a mask's main shape or one part (one settings change).
    func updateShape(_ ref: MaskRef, _ change: (inout MaskShape) -> Void) {
        updateMask(ref.mask) { $0.updateShape(part: ref.part, change) }
    }

    /// Does a drag on the photo paint (brush cursor)?
    var isBrushing: Bool {
        let tool = MaskToolState.shared
        if let kind = tool.pendingKind { return kind == .brush }
        guard let mask = selectedMask else { return false }
        return mask.brush != nil || selectedShape?.brush != nil || tool.refining
    }

    /// Mutates one mask in place (one settings change).
    func updateMask(_ id: UUID, _ change: (inout Mask) -> Void) {
        guard let i = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        var m = settings.masks[i]
        change(&m)
        if m != settings.masks[i] { settings.masks[i] = m }
    }

    /// Appends a new mask, selects it and activates the mask tool. Returns its id.
    @discardableResult
    func addMask(_ shape: MaskShape) -> UUID {
        let mask = Mask(name: MaskEditing.nextName(for: shape.kind, existing: settings.masks), shape: shape)
        settings.masks.append(mask)
        selectMask(mask.id)
        return mask.id
    }

    /// Adds a mask found by Vision (AIMasks.swift): selected, with the coverage overlay on so the selection
    /// shows, and computed at once. Returns its id.
    @discardableResult
    func addAIMask(_ m: AIMask) -> UUID {
        commitUndoGroup()
        let id = addMask(.ai(m))
        commitUndoGroup()
        MaskToolState.shared.showOverlay = true
        if let source { AIMaskStatus.shared.prepare(m, source: source) }
        return id
    }

    /// Pick Object: clicks on the photo select the subject under them (the overlay previews every one) until Esc;
    /// `adding` = add them to that mask (Add Object / Add ▸ Object), `mode` subtract = remove them from it.
    /// ⌥-click does the opposite.
    func beginPickingObject(adding id: UUID? = nil, mode: MaskPart.Mode = .add) {
        commitUndoGroup()
        if id == nil { selectedMaskID = nil; selectedPartID = nil }
        let tool = MaskToolState.shared
        tool.pendingKind = .object
        tool.addingTo = id
        tool.addMode = mode
        tool.refining = false
        activeTool = .mask
    }

    /// Add / Subtract a shape to the mask `id`: found ones at once, Object by clicking, Linear / Radial by dragging,
    /// Brush by painting (Subtract = erase).
    func beginAddingPart(_ kind: MaskKind, mode: MaskPart.Mode, to id: UUID) {
        guard mask(id: id) != nil else { return }
        let tool = MaskToolState.shared
        switch kind {
        case .object:
            beginPickingObject(adding: id, mode: mode)
        case .subject, .background, .people, .sky:
            commitUndoGroup()
            addPart(.ai(AIMask(target: kind.aiTarget ?? .subject)), mode: mode, to: id)
            commitUndoGroup()
            tool.showOverlay = true
        case .brush:
            selectMask(id)
            tool.refining = true
            tool.eraseMode = mode == .subtract
        case .linear, .radial:
            commitUndoGroup()
            selectMask(id)
            tool.pendingKind = kind
            tool.addingTo = id
            tool.addMode = mode
        }
        activeTool = .mask
    }

    /// Appends a part to mask `id`; `select` = edit it next (its handles, its options). Returns its reference.
    @discardableResult
    func addPart(_ shape: MaskShape, mode: MaskPart.Mode, to id: UUID, select: Bool = true) -> MaskRef? {
        guard mask(id: id) != nil else { return nil }
        let part = MaskPart(mode: mode, shape: shape)
        updateMask(id) { $0.parts.append(part) }
        if select {
            selectMask(id)
            selectedPartID = part.id
        }
        if let ai = shape.ai, let source { AIMaskStatus.shared.prepare(ai, source: source) }
        return MaskRef(mask: id, part: part.id)
    }

    func deletePart(_ ref: MaskRef) {
        guard let part = ref.part else { deleteMask(ref.mask); return }
        commitUndoGroup()
        updateMask(ref.mask) { $0.parts.removeAll { $0.id == part } }
        if selectedPartID == part { selectedPartID = nil }
        commitUndoGroup()
    }

    /// Selects a mask's main shape (`part` nil) or one of its parts.
    func selectPart(_ ref: MaskRef) {
        selectMask(ref.mask)
        selectedPartID = ref.part
    }

    func deleteMask(_ id: UUID) {
        commitUndoGroup()
        settings.masks.removeAll { $0.id == id }
        if selectedMaskID == id { selectedMaskID = nil; selectedPartID = nil }
        commitUndoGroup()
    }

    func duplicateMask(_ id: UUID) {
        guard let i = settings.masks.firstIndex(where: { $0.id == id }) else { return }
        commitUndoGroup()
        var copy = settings.masks[i]
        copy.id = UUID()
        copy.name = copy.name + " copy"
        settings.masks.insert(copy, at: i + 1)
        commitUndoGroup()
        selectMask(copy.id)
    }

    /// Selects a mask (its main shape) and ends any pending creation.
    func selectMask(_ id: UUID?) {
        if id != selectedMaskID { MaskToolState.shared.refining = false }
        selectedMaskID = id
        selectedPartID = nil
        if id != nil {
            MaskToolState.shared.cancelPending()
            activeTool = .mask
        }
    }

    /// "Create New Mask": the next drag on the canvas creates a mask of `kind`.
    func beginCreatingMask(_ kind: MaskKind) {
        commitUndoGroup()
        selectedMaskID = nil
        selectedPartID = nil
        let tool = MaskToolState.shared
        tool.cancelPending()
        tool.refining = false
        tool.pendingKind = kind
        activeTool = .mask
    }

    /// Leaves the mask tool (Esc / Done).
    func finishMasking() {
        MaskToolState.shared.cancelPending()
        commitUndoGroup()
        activeTool = .none
    }
}
