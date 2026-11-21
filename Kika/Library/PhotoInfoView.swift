//
//  PhotoInfoView.swift
//  Kika
//
//  File info of a photo (all from the catalog, no file reads): name, folder, device, size, type, pixel size
//  (and the cropped size when cropped), capture date, camera, lens, exposure, focal length, import date.
//  Shown in Library's Info panel (⌘I / the toolbar's ⓘ, `LibraryInfo`; focused or first selected photo, plus the
//  selection's count and total size) and in Develop's Info section (DevelopInspectorView, live crop).
//

import AppKit
import SwiftUI

struct PhotoInfoView: View {
    @Environment(AppModel.self) private var model
    let photo: Photo
    /// The settings shown (Develop: the session's live ones); nil = the photo's saved edits.
    var settings: EditSettings? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            group("File", rows: fileRows)
            group("Capture", rows: captureRows)
            group("Catalog", rows: catalogRows)
            Button("Show in Finder") { PhotoActions.showInFinder(photo.id, model: model) }
                .controlSize(.small)
                .help(ShortcutStore.shared.help("Reveal the original file in the Finder", .showInFinder))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private struct Row: Identifiable {
        var label: String
        var value: String
        var help: String? = nil
        var id: String { label }
    }

    @ViewBuilder
    private func group(_ title: String, rows: [Row]) -> some View {
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 8, verticalSpacing: 3) {
                    ForEach(rows) { row in
                        GridRow {
                            Text(row.label).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                            Text(row.value)
                                .lineLimit(2)
                                .truncationMode(.middle)
                                .textSelection(.enabled)
                                .help(row.help ?? row.value)
                        }
                    }
                }
                .font(.callout)
            }
        }
    }

    private var fileRows: [Row] {
        var rows = [Row(label: "Name", value: photo.displayTitle)]
        if let copy = photo.virtualCopyDescription { rows.append(Row(label: "Copy", value: copy)) }
        let folder = (photo.path as NSString).deletingLastPathComponent
        rows.append(Row(label: "Folder", value: (folder as NSString).abbreviatingWithTildeInPath, help: folder))
        rows.append(Row(label: "Device", value: PhotoDevice(path: photo.path).title))
        if photo.fileSize > 0 { rows.append(Row(label: "Size", value: ByteCountFormatter.string(fromByteCount: photo.fileSize, countStyle: .file))) }
        var type = (photo.fileName as NSString).pathExtension.uppercased()
        if let sidecar = photo.sidecarPath { type += " + " + (sidecar as NSString).pathExtension.uppercased() }
        if !type.isEmpty { rows.append(Row(label: "Type", value: type)) }
        let size = photo.orientedSize
        if size.width > 0 {
            rows.append(Row(label: "Pixels", value: PhotoInfo.pixels(size)))
            let cropped = GeometryMath(sourceSize: size, geometry: (settings ?? photo.editSettings).geometry).croppedSize
            if abs(cropped.width - size.width) >= 1 || abs(cropped.height - size.height) >= 1 {
                rows.append(Row(label: "Cropped", value: PhotoInfo.pixels(cropped)))
            }
        }
        return rows
    }

    private var captureRows: [Row] {
        var rows: [Row] = []
        if let d = photo.captureDate { rows.append(Row(label: "Date", value: d.formatted(date: .abbreviated, time: .standard))) }
        if let camera = PhotoInfo.camera(make: photo.cameraMake, model: photo.cameraModel) { rows.append(Row(label: "Camera", value: camera)) }
        if let lens = photo.lens, !lens.isEmpty { rows.append(Row(label: "Lens", value: lens)) }
        if let exposure = PhotoInfo.exposure(shutter: photo.shutter, aperture: photo.aperture, iso: photo.iso) {
            rows.append(Row(label: "Exposure", value: exposure))
        }
        if let f = photo.focalLength, f > 0 { rows.append(Row(label: "Focal", value: PhotoInfo.number(f) + " mm")) }
        return rows
    }

    private var catalogRows: [Row] {
        [Row(label: "Imported", value: photo.importDate.formatted(date: .abbreviated, time: .shortened)),
         Row(label: "Edits", value: photo.hasEdits ? "Edited" : "None")]
    }
}

/// Formatting for the info panel (UI-free).
nonisolated enum PhotoInfo {
    /// "6000 × 4000 · 24.0 MP".
    static func pixels(_ size: CGSize) -> String {
        let w = Int(size.width.rounded()), h = Int(size.height.rounded())
        return "\(w) × \(h) · " + String(format: "%.1f MP", Double(w * h) / 1_000_000)
    }

    /// "Leica Q3", without the make repeated ("Canon Canon EOS R5" → "Canon EOS R5").
    static func camera(make: String?, model: String?) -> String? {
        let make = make?.trimmingCharacters(in: .whitespaces) ?? "", model = model?.trimmingCharacters(in: .whitespaces) ?? ""
        if model.isEmpty { return make.isEmpty ? nil : make }
        let firstWord = make.split(separator: " ").first.map(String.init) ?? make
        if make.isEmpty || model.lowercased().hasPrefix(firstWord.lowercased()) { return model }
        return make + " " + model
    }

    /// "1/250 s · ƒ/2.8 · ISO 400" (whatever is known).
    static func exposure(shutter: Double?, aperture: Double?, iso: Int?) -> String? {
        var parts: [String] = []
        if let s = shutter, s > 0 { parts.append(self.shutter(s)) }
        if let a = aperture, a > 0 { parts.append("ƒ/" + number(a)) }
        if let iso, iso > 0 { parts.append("ISO \(iso)") }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "1/250 s" below half a second, else "0.8 s" / "2 s" / "30 s".
    static func shutter(_ s: Double) -> String {
        if s < 0.5 { return "1/\(Int((1 / s).rounded())) s" }
        return number(s) + " s"
    }

    /// At most one decimal, none when whole ("2.8", "35").
    static func number(_ v: Double) -> String {
        let r = (v * 10).rounded() / 10
        return r == r.rounded() ? String(Int(r)) : String(format: "%.1f", r)
    }
}

// MARK: - Library Info panel

/// Library's Info panel (right side, ⌘I): shown or hidden, remembered.
enum LibraryInfo {
    static let key = "library.infoShown"

    static func toggle() {
        let d = UserDefaults.standard
        d.set(!d.bool(forKey: key), forKey: key)
    }
}

/// The Info panel's content: the focused (or first selected) photo; with several selected, their count and size.
struct LibraryInfoPanel: View {
    @Environment(AppModel.self) private var model

    private var photo: Photo? {
        model.focusedPhoto ?? model.photos.first { model.selection.contains($0.id) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if model.selection.count > 1 {
                    let selected = model.photos.filter { model.selection.contains($0.id) }
                    let bytes = selected.reduce(Int64(0)) { $0 + ($1.isVirtualCopy ? 0 : $1.fileSize) }
                    Text("\(selected.count) photos selected · \(ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file))")
                        .font(.callout.weight(.medium))
                    Divider()
                }
                if let photo {
                    PhotoInfoView(photo: photo)
                } else {
                    Text("No Photo Selected").foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .center).padding(.top, 40)
                }
            }
            .padding(12)
        }
    }
}
