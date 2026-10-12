//
//  DecodeDevScript.swift
//  sloproom
//
//  DevScript (DEBUG): `decode …` drives decode profiles.
//    decode expand                 expand Develop > Raw Decode
//    decode set <param> <v|nil>    this photo's override ("decode set boost 0", "decode set gamutMapping false")
//    decode profile <name>|none    choose a profile for this photo
//    decode default <name>|none    global default;  decode camera <name>|none  = this photo's camera default
//    decode settings               select Settings > Raw Decode (then `menu Sloproom/Settings…`)
//    decode dump                   chain, overrides, effective values, profiles
//

#if DEBUG
import AppKit
import SwiftUI

enum DecodeDevScript {
    static func run(_ arg: String, model: AppModel) {
        let parts = arg.split(separator: " ", maxSplits: 1).map(String.init)
        let cmd = parts.first ?? "", rest = parts.count > 1 ? parts[1] : ""
        let session = model.developSession
        func profileID(_ name: String) -> Int64?? {
            if name == "none" { return .some(nil) }
            guard let p = DecodeProfilesStore.shared.profiles.first(where: { $0.name == name }) else {
                print("DevScript: no decode profile \(name)"); return nil
            }
            return .some(p.id)
        }
        do {
            switch cmd {
            case "expand":
                UserDefaults.standard.set(true, forKey: "develop.section.Raw Decode.expanded")
            case "set":
                let kv = rest.split(separator: " ").map(String.init)
                guard kv.count == 2, let info = DecodeParamInfo.info(kv[0]), let session else { print("DevScript: decode set <param> <value>"); return }
                var o = session.settings.decode.overrides
                switch info.kind {
                case .number(let kp, _, _): o[keyPath: kp] = Double(kv[1])
                case .toggle(let kp): o[keyPath: kp] = kv[1] == "nil" ? nil : (kv[1] == "true")
                }
                session.settings.decode.overrides = o
            case "profile":
                if let id = profileID(rest) { session?.settings.decode.profileID = id }
            case "default":
                if let id = profileID(rest) { try model.catalog.setGlobalDecodeDefault(id) }
            case "camera":
                guard let camera = session?.source?.camera else { print("DevScript: no camera"); return }
                if let id = profileID(rest) { try model.catalog.setCameraDecodeDefault(camera, profileID: id) }
            case "settings":
                SettingsNavigation.shared.tab = .rawDecode
            case "dump":
                print("DevScript decode: profiles \(DecodeProfilesStore.shared.profiles.map(\.name))")
                if let session {
                    let r = session.resolvedDecode
                    print("DevScript decode: chain \(r.layers.map(\.label)), camera \(session.source?.camera?.displayName ?? "-")")
                    print("DevScript decode: photo \(session.settings.decode.jsonString)")
                    print("DevScript decode: effective \(DecodeProfileRegistry.json(r.params))")
                }
            default:
                print("DevScript: decode expand|set|profile|default|camera|settings|dump")
            }
        } catch { print("DevScript decode: \(error)") }
    }
}

extension DecodeSettings {
    var jsonString: String {
        let enc = JSONEncoder(); enc.outputFormatting = [.sortedKeys]
        return (try? enc.encode(self)).flatMap { String(data: $0, encoding: .utf8) } ?? "?"
    }
}
#endif
