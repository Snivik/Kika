//
//  MaskDevScript.swift
//  Kika
//
//  DevScript commands for headless checks of the mask tool (see App/DevTools.swift):
//    mask linear|radial [cx cy]|brush   add a demo mask (with adjustments) and select it
//    maskoverlay on|off         toggle the red coverage overlay
//    maskcreate linear|radial|brush|object   "Create New Mask" (pending creation state; object = Pick Object)
//    maskai subject|background|people|sky [exposure]   add a found (Vision) mask, as the panel's Select buttons
//    maskai object <x> <y> [exposure]                  pick the subject at a mask-space point
//    maskaistatus                     what Vision found for the selected mask (waits up to 20 s)
//    maskpart add|subtract <kind>     Add ▾ / Subtract ▾ on the selected mask (brush = paint / erase on it,
//                                     object = pick with clicks, linear / radial = drag)
//

#if DEBUG
import Foundation

enum MaskDevScript {
    static let commands: Set<String> = ["mask", "maskoverlay", "maskcreate", "maskai", "maskaistatus", "maskpart"]

    static func run(_ command: String, _ arg: String, session: DevelopSession?) {
        guard let session else { return }
        switch command {
        case "mask":
            var id: UUID
            let words = arg.split(separator: " ").map(String.init)   // "radial [cx cy]"
            switch words.first ?? "" {
            case "radial":
                var r = RadialGradientMask()
                r.radiusX = 0.3; r.radiusY = 0.35; r.rotation = 15; r.feather = 60
                if words.count == 3, let x = Double(words[1]), let y = Double(words[2]) {
                    r.center = NormPoint(x: x, y: y); r.radiusX = 0.12; r.radiusY = 0.2; r.feather = 20
                }
                id = session.addMask(.radial(r))
                session.updateMask(id) { $0.adjustments.exposure = 1; $0.inverted = false }
            case "brush":
                var stroke = BrushStroke()
                stroke.radius = 0.04
                for i in 0...40 {
                    let t = Double(i) / 40
                    MaskEditing.append(NormPoint(x: 0.2 + 0.6 * t, y: 0.6 + 0.05 * sin(t * 2 * .pi)), to: &stroke, aspect: 1.5)
                }
                var eraser = BrushStroke()
                eraser.radius = 0.02; eraser.isEraser = true
                eraser.points = [NormPoint(x: 0.5, y: 0.5), NormPoint(x: 0.5, y: 0.7)]
                var b = BrushMask(); b.strokes = [stroke, eraser]
                id = session.addMask(.brush(b))
                session.updateMask(id) { $0.adjustments.exposure = 2 }
            default:
                id = session.addMask(.linear(LinearGradientMask(start: NormPoint(x: 0.5, y: 0), end: NormPoint(x: 0.5, y: 0.4))))
                session.updateMask(id) { $0.adjustments.exposure = -1.5 }
            }
        case "maskoverlay":
            MaskToolState.shared.showOverlay = arg != "off"
        case "maskcreate":
            if arg == "object" { session.beginPickingObject() } else { session.beginCreatingMask(MaskKind(rawValue: arg) ?? .linear) }
        case "maskai":
            let words = arg.split(separator: " ").map(String.init)
            guard let target = words.first.flatMap(AIMask.Target.init(rawValue:)) else { print("DevScript maskai: bad target"); return }
            var numbers = words.dropFirst().compactMap(Double.init)
            var points: [NormPoint] = []
            if target == .object, numbers.count >= 2 { points = [NormPoint(x: numbers[0], y: numbers[1])]; numbers.removeFirst(2) }
            let id = session.addAIMask(AIMask(target: target, points: points))
            if let ev = numbers.first { session.updateMask(id) { $0.adjustments.exposure = ev } }
        case "maskpart":
            let words = arg.split(separator: " ").map(String.init)
            guard words.count == 2, let mode = MaskPart.Mode(rawValue: words[0]), let kind = MaskKind(rawValue: words[1]),
                  let id = session.selectedMaskID else { print("DevScript maskpart: needs add|subtract <kind> and a selected mask"); return }
            session.beginAddingPart(kind, mode: mode, to: id)
            print("DevScript maskpart: \(mode.rawValue) \(kind.rawValue) → \(session.mask(id: id)?.parts.count ?? 0) parts")
        case "maskaistatus":
            Task { @MainActor in
                guard let ai = session.selectedMask?.ai, let source = session.source else { print("DevScript maskaistatus: no AI mask"); return }
                let key = AIMaskEngine.key(ai, source: source)
                let start = Date()
                while Date().timeIntervalSince(start) < 20, AIMaskStatus.shared.states[key] == nil || AIMaskStatus.shared.states[key] == .computing {
                    try? await Task.sleep(for: .milliseconds(50))
                }
                print("DevScript maskaistatus: \(ai.target.rawValue) \(AIMaskStatus.shared.states[key].map { "\($0)" } ?? "none") in \(Int(Date().timeIntervalSince(start) * 1000)) ms")
            }
        default:
            break
        }
    }
}
#endif
