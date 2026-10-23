import Foundation
import SwiftUI

/// A person found in the folder: faces grouped by SFace identity vectors.
struct Person: Identifiable, Hashable {
    let id: Int
    var name: String?
    var centroids: [Data]   // one per face group: several when groups were merged by name (front and profile)
    var faces: [FaceRef]
    var photos: Set<URL>
    /// The id, not a count: a gap after a merge or naming is better than "Person 3" turning into "Person 2"
    /// on screen and in an active filter's chip while it is the same person.
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

    /// Adds the person's centroids under `name`, keeping the ones already there: a name holds several
    /// centroids, so front and profile (or other shoots) all stay recognized. On a rename (`old`), the old
    /// name's centroids that matched this person go, or they would tie with the new ones.
    static func save(name: String, centroids: [Data], replacing old: String?) {
        var e = load().map { Entry(name: $0.name, centroid: $0.centroid) }
        if let old, old != name {
            e.removeAll { x in x.name == old && centroids.contains { FaceID.similarity(x.centroid, $0) >= 0.45 } }
        }
        for c in centroids {
            // A near copy of a stored centroid replaces it, so naming the same group again doesn't grow the file.
            e.removeAll { $0.name == name && FaceID.similarity($0.centroid, c) >= 0.9 }
            e.append(Entry(name: name, centroid: c))
        }
        // At most 16 per name, the newest kept.
        var count: [String: Int] = [:]
        e = e.reversed().filter { x in count[x.name, default: 0] += 1; return count[x.name]! <= 16 }.reversed()
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
            result.append(Person(id: 0, name: name, centroids: [c], faces: m, photos: Set(m.map(\.photo))))
        }
        result.sort { $0.photos.count > $1.photos.count }
        // Groups with the same name are one person (e.g. front and profile).
        var merged: [Person] = []
        for p in result {
            if let n = p.name, let j = merged.firstIndex(where: { $0.name == n }) {
                merged[j].faces += p.faces; merged[j].photos.formUnion(p.photos); merged[j].centroids += p.centroids
            } else { merged.append(p) }
        }
        // Stable ids: a group keeps the id of the previous person it is (same name, most shared faces, or a close
        // centroid), so a filter on "Person 2" stays on that person when a recompute reorders the groups.
        let old = people.map { (p: $0, faces: Set($0.faces)) }
        var used = Set<Int>(), ids = [Int?](repeating: nil, count: merged.count)
        for i in merged.indices {
            let p = merged[i], faces = Set(p.faces)
            let free = old.filter { !used.contains($0.p.id) }
            let byName = p.name.flatMap { n in free.first { $0.p.name == n } }
            let byFaces = free.map { ($0, $0.faces.intersection(faces).count) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
            let byLook = free.map { o in (o, o.p.centroids.flatMap { a in p.centroids.map { FaceID.similarity(a, $0) } }.max() ?? 0) }
                .filter { $0.1 >= 0.45 }.max { $0.1 < $1.1 }?.0
            if let o = byName ?? byFaces ?? byLook { ids[i] = o.p.id; used.insert(o.p.id) }
        }
        // New people take the smallest free number, so "Person N" stays near the count after many recomputes.
        // An id a filter still holds is skipped: the filter would jump to a stranger.
        var next = 1
        for i in merged.indices {
            let p = merged[i]
            let id = ids[i] ?? {
                while used.contains(next) || personFilters.contains(next) { next += 1 }
                return next
            }()
            used.insert(id)
            merged[i] = Person(id: id, name: p.name, centroids: p.centroids, faces: p.faces, photos: p.photos)
        }
        people = merged
        // Filters follow their person, also into a merge: an old id goes to the new person with most of its faces.
        personFilters = Set(personFilters.compactMap { f in
            guard let o = old.first(where: { $0.p.id == f }) else { return nil }
            return people.map { ($0.id, Set($0.faces).intersection(o.faces).count) }.filter { $0.1 > 0 }.max { $0.1 < $1.1 }?.0
                ?? (people.contains { $0.id == f } ? f : nil)
        })
    }

    func person(_ id: Int) -> Person? { people.first { $0.id == id } }

    func namePerson(_ id: Int, _ name: String) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let p = person(id) else { return }
        PeopleNames.save(name: n, centroids: p.centroids, replacing: p.name)
        computePeople()
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
