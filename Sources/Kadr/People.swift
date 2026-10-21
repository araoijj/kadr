import Foundation
import SwiftUI

/// A person found in the folder: faces grouped by SFace identity vectors.
struct Person: Identifiable, Hashable {
    let id: Int
    var name: String?
    var centroid: Data
    var faces: [FaceRef]
    var photos: Set<URL>
    var title: String { name ?? tr("Человек \(id)") }
}

struct FaceRef: Hashable {
    let photo: URL
    let index: Int
}

/// Names given to people, kept in the app's data folder (not in the shoot): a person named once is
/// recognized in other shoots too.
enum PeopleNames {
    private static var file: URL { AppFolders.support.appendingPathComponent("people.json") }
    private struct Entry: Codable { var name: String; var centroid: Data }

    static func load() -> [(name: String, centroid: Data)] {
        guard let d = try? Data(contentsOf: file), let e = try? JSONDecoder().decode([Entry].self, from: d) else { return [] }
        return e.map { ($0.name, $0.centroid) }
    }

    static func save(name: String, centroid: Data) {
        var e = load().filter { $0.name != name }.map { Entry(name: $0.name, centroid: $0.centroid) }
        e.append(Entry(name: name, centroid: centroid))
        if let d = try? JSONEncoder().encode(e) { try? d.write(to: file, options: .atomic) }
    }
}

extension Library {
    /// Groups faces into people: greedy clustering by cosine similarity of identity vectors
    /// (≥ 0.36 — OpenCV's SFace threshold), only faces large and clear enough to recognize.
    /// Checked on 2032 frames: separate groups for each person; profiles of the same person may form
    /// a second group (merge by giving both the same name).
    func computePeople() {
        guard aiEnabled.contains(.identity) else { people = []; return }
        var centroids: [[Float]] = [], members: [[FaceRef]] = [], vecs: [[Float]] = []
        for p in photos where !p.rejected {
            for (i, f) in (p.cull?.faces ?? []).enumerated() {
                guard let d = f.identity, (f.px ?? 0) >= 100, (f.quality ?? 0) >= 0.3 else { continue }
                let v = d.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
                vecs.append(v)
                var best = -1, bestSim: Float = 0.36
                for (k, c) in centroids.enumerated() {
                    var s: Float = 0
                    for j in 0..<min(c.count, v.count) { s += c[j] * v[j] }
                    if s >= bestSim { bestSim = s; best = k }
                }
                if best >= 0 {
                    members[best].append(FaceRef(photo: p.id, index: i))
                    let n = Float(members[best].count)
                    var c = centroids[best]
                    for j in 0..<c.count { c[j] += (v[j] - c[j]) / n }
                    let norm = c.reduce(0) { $0 + $1 * $1 }.squareRoot()
                    centroids[best] = c.map { $0 / max(norm, 1e-6) }
                } else {
                    centroids.append(v); members.append([FaceRef(photo: p.id, index: i)])
                }
            }
        }
        let names = PeopleNames.load()
        var result: [Person] = []
        for (k, m) in members.enumerated() where m.count >= 3 {
            let c = centroids[k].withUnsafeBufferPointer { Data(buffer: $0) }
            let name = names.map { ($0.name, FaceID.similarity($0.centroid, c)) }.filter { $0.1 >= 0.45 }.max { $0.1 < $1.1 }?.0
            result.append(Person(id: 0, name: name, centroid: c, faces: m, photos: Set(m.map(\.photo))))
        }
        result.sort { $0.photos.count > $1.photos.count }
        // Groups with the same name are one person (e.g. front and profile).
        var merged: [Person] = []
        for p in result {
            if let n = p.name, let j = merged.firstIndex(where: { $0.name == n }) {
                merged[j].faces += p.faces; merged[j].photos.formUnion(p.photos)
            } else { merged.append(p) }
        }
        people = merged.enumerated().map { i, p in var q = p; q = Person(id: i + 1, name: p.name, centroid: p.centroid, faces: p.faces, photos: p.photos); return q }
        personFilters = personFilters.filter { f in people.contains { $0.id == f } }
    }

    func person(_ id: Int) -> Person? { people.first { $0.id == id } }

    func namePerson(_ id: Int, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let p = person(id) else { return }
        PeopleNames.save(name: n, centroid: p.centroid)
        computePeople()
    }
}

/// Small face of a person for the sidebar.
struct PersonFace: View {
    @Environment(Library.self) private var lib
    let person: Person
    @State private var image: CGImage?

    var body: some View {
        ZStack {
            Circle().fill(.white.opacity(0.08))
            if let image { Image(decorative: image, scale: 1).resizable().aspectRatio(contentMode: .fill).clipShape(Circle()) }
            else { Image(systemName: "person.fill").font(.caption).foregroundStyle(.secondary) }
        }
        .frame(width: 22, height: 22)
        .task(id: person.id) {
            // The largest face of the person.
            guard let ref = person.faces.max(by: { a, b in
                (lib.photo(a.photo)?.cull?.faces[safe: a.index]?.px ?? 0) < (lib.photo(b.photo)?.cull?.faces[safe: b.index]?.px ?? 0)
            }), let p = lib.photo(ref.photo), let f = p.cull?.faces[safe: ref.index] else { return }
            let url = p.url
            image = await Task.detached(priority: .utility) {
                guard let img = ImageStore.shared.preview(url) else { return nil }
                let W = Double(img.width), H = Double(img.height), side = max(f.w * W, f.h * H) * 1.3
                return img.cropping(to: CGRect(x: (f.x + f.w / 2) * W - side / 2, y: (f.y + f.h / 2) * H - side / 2, width: side, height: side).integral)
            }.value
        }
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
