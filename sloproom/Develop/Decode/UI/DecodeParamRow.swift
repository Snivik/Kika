//
//  DecodeParamRow.swift
//  sloproom
//
//  One decode parameter, editing ONE layer (a photo's overrides or a profile's params):
//  shows the effective value (this layer's, else what it inherits) and where it comes from.
//  Moving a control sets the value on this layer; setting it back to the inherited value, the
//  reset button or double-clicking the slider title clears it (inherit again).
//

import SwiftUI

struct DecodeParamRow: View {
    let info: DecodeParamInfo
    /// The layer being edited.
    let layer: DecodeParams
    /// What this layer inherits (merged layers below, every field filled).
    let inherited: DecodeParams
    /// Where the inherited value comes from ("Camera: Flat for Editing"…); nil = a plain default
    /// (Apple's / Sloproom's), which gets no caption line.
    let inheritedSource: String?
    /// "This photo" / "This profile": the label when this layer sets the value.
    let layerName: String
    var supported = true
    let onChange: (DecodeParams) -> Void
    var onCommit: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            control
            if isSet || !supported || inheritedSource != nil {
                HStack(spacing: 4) {
                    if isSet {
                        Circle().fill(Color.accentColor).frame(width: 5, height: 5)
                        Text(layerName).foregroundStyle(Color.accentColor)
                        Button("Reset") { clear() }
                            .buttonStyle(.borderless)
                            .help("Inherit \(info.title) again (\(inheritedSource ?? defaultName))")
                    } else {
                        Text(supported ? inheritedSource ?? "" : "Not supported for this file")
                    }
                    Spacer()
                }
                .font(.caption2)
                .foregroundStyle(.secondary)
            }
        }
        .disabled(!supported)
        .help(info.help + "\nNow: " + (isSet ? layerName : inheritedSource ?? defaultName) + ".")
    }

    private var isSet: Bool { info.isSet(in: layer) }
    private var defaultName: String { info.isApple ? "Apple's default" : "Sloproom's default" }

    @ViewBuilder private var control: some View {
        switch info.kind {
        case .number(let kp, let range, let step):
            let base = inherited[keyPath: kp] ?? range.lowerBound
            DevelopSlider(title: info.title,
                          value: Binding(get: { layer[keyPath: kp] ?? base },
                                         set: { v in
                                             var p = layer
                                             p[keyPath: kp] = abs(v - base) < step / 2 ? nil : v
                                             if p != layer { onChange(p) }
                                         }),
                          range: range, defaultValue: base,
                          format: .custom { String(format: step < 0.1 ? "%.2f" : "%.1f", $0) },
                          step: step,
                          onEditingChanged: { if !$0 { onCommit() } })
        case .toggle(let kp):
            Toggle(info.title, isOn: Binding(get: { layer[keyPath: kp] ?? inherited[keyPath: kp] ?? true },
                                             set: { v in
                                                 var p = layer
                                                 p[keyPath: kp] = v == (inherited[keyPath: kp] ?? true) ? nil : v
                                                 onChange(p)
                                                 onCommit()
                                             }))
                .toggleStyle(.checkbox)
        }
    }

    private func clear() {
        var p = layer
        info.clear(in: &p)
        onChange(p)
        onCommit()
    }
}

/// Every parameter of one group, editing one layer.
struct DecodeParamGroup: View {
    let group: DecodeParamInfo.Group
    let layer: DecodeParams
    let inherited: DecodeParams
    let inheritedSource: (DecodeParamInfo) -> String?
    let layerName: String
    var supported: (DecodeParamInfo) -> Bool = { _ in true }
    let onChange: (DecodeParams) -> Void
    var onCommit: () -> Void = {}

    var body: some View {
        Text(group.rawValue).font(.caption.weight(.semibold)).foregroundStyle(.secondary).padding(.top, 4)
        ForEach(DecodeParamInfo.all.filter { $0.group == group }) { info in
            DecodeParamRow(info: info, layer: layer, inherited: inherited, inheritedSource: inheritedSource(info),
                           layerName: layerName, supported: supported(info), onChange: onChange, onCommit: onCommit)
        }
    }
}
