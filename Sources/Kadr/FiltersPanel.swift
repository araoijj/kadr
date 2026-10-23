import AppKit
import SwiftUI

/// The sidebar's «Фильтры» tab: every way to narrow the folder, one click each, with counts.
/// Sections in the order of the work: decision → stars and colors → AI picks → problems → people →
/// tags → scenes → bursts → shoot (lenses, days). Between sections the filters combine with "and";
/// inside a section one choice at a time, except people and tags (several = any of them).
struct FiltersPanel: View {
    @Environment(Library.self) private var lib
    @State private var naming: Int?
    @State private var nameText = ""
    @State private var allTags = false

    var body: some View {
        @Bindable var lib = lib
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 2) {
                    decision
                    starsAndColors
                    ai
                    people
                    tags
                    scenes
                    bursts
                    shoot
                }
                .padding(8)
            }
            Divider()
            HStack {
                Toggle(tr("Скрыть брак"), isOn: $lib.hideRejected).toggleStyle(.switch).controlSize(.mini)
                Text("H").font(.caption2).foregroundStyle(.tertiary)
                Spacer()
            }
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
        .alert(tr("Как зовут?"), isPresented: Binding(get: { naming != nil }, set: { if !$0 { naming = nil } })) {
            TextField(tr("Имя"), text: $nameText)
            Button(tr("Сохранить")) { if let id = naming { lib.namePerson(id, nameText) }; naming = nil }
            Button(tr("Отмена"), role: .cancel) { naming = nil }
        } message: {
            Text(tr("Имя запомнится: этот человек будет узнаваться и в других съёмках. Дайте то же имя второй группе (например, профилю) — они объединятся."))
        }
    }

    // MARK: - Header: what is already chosen

    private var header: some View {
        let active = lib.filter != .all || lib.extraFiltersActive
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(active ? tr("Показано \(lib.visible.count) из \(lib.photos.count)") : tr("Все кадры: \(lib.photos.count)"))
                    .font(.caption.weight(.semibold)).monospacedDigit().lineLimit(1)
                Spacer()
                if active {
                    Button(tr("Сбросить всё")) { lib.resetFilters() }.buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor)
                        .help(tr("Снять все фильтры (⌥⌘F)"))
                }
            }
            if active { Flow(spacing: 5) { chips } }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    @ViewBuilder private var chips: some View {
        if lib.filter != .all { Chip(lib.filter.title) { set(.all) } }
        if let l = lib.lensFilter { Chip(l, icon: "camera.aperture") { lib.lensFilter = nil; lib.move(0) } }
        if let d = lib.dayFilter { Chip(d.formatted(.dateTime.day().month(.abbreviated).locale(I18n.locale)), icon: "calendar") { lib.dayFilter = nil; lib.move(0) } }
        ForEach(lib.people.filter { lib.personFilters.contains($0.id) }) { p in Chip(p.title, icon: "person.crop.circle") { lib.togglePerson(p.id, add: true) } }
        ForEach(lib.tagFilters.sorted(), id: \.self) { t in Chip(TagNames.title(t), icon: "tag") { lib.toggleTag(t, add: true) } }
        if lib.hideRejected && lib.filter != .rejected { Chip(tr("брак скрыт"), icon: "eye.slash") { lib.hideRejected = false } }
    }

    // MARK: - Sections

    private var decision: some View {
        FSection(tr("Решение"), key: "decision") {
            row(.all, tr("Все"), icon: "photo.on.rectangle")
            row(.undecided, tr("Без решения"), icon: "circle.dashed")
            row(.picked, tr("Оставлено"), icon: "checkmark.circle.fill", tint: .green)
            row(.rejected, tr("Брак"), icon: "xmark.circle.fill", tint: Theme.reject)
        }
    }

    private var starsAndColors: some View {
        let n: Int? = if case .stars(let k) = lib.filter { k } else { nil }
        // The captions are dropped first when the panel is narrow; the buttons never wrap.
        return FSection(tr("Оценка и цвет"), key: "stars") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) { starButtons(n); Text(tr("и выше")).font(.caption2).foregroundStyle(.tertiary).fixedSize() }
                HStack(spacing: 4) { starButtons(n) }
            }
            .padding(.horizontal, 8).padding(.vertical, 3)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { colorButtons; Text(tr("цветные метки")).font(.caption2).foregroundStyle(.tertiary).fixedSize() }
                HStack(spacing: 8) { colorButtons }
            }
            .padding(.horizontal, 10).padding(.vertical, 3)
        }
    }

    private func starButtons(_ n: Int?) -> some View {
        ForEach(1...5, id: \.self) { k in
            let on = n == k
            Button { set(on ? .all : .stars(k)) } label: {
                Text("★\(k)").font(.caption.weight(.semibold)).monospacedDigit().fixedSize()
                    .foregroundStyle(n != nil && k <= n! ? Theme.star : .secondary)
                    .padding(.horizontal, 7).padding(.vertical, 4)
                    .background(on ? Theme.selected : Theme.control, in: RoundedRectangle(cornerRadius: 6))
            }
            .buttonStyle(.plain)
            .help(String(repeating: "★", count: k) + (k < 5 ? tr(" и выше") : "") + " · \(lib.count(.stars(k)))")
        }
    }

    private var colorButtons: some View {
        ForEach(ColorLabel.allCases) { l in
            let on = lib.filter == .label(l)
            Button { set(on ? .all : .label(l)) } label: {
                Circle().fill(l.color).frame(width: 14, height: 14)
                    .overlay(Circle().strokeBorder(.white, lineWidth: on ? 2 : 0))
                    .opacity(on || lib.count(.label(l)) > 0 ? 1 : 0.35)
            }
            .buttonStyle(.plain)
            .help(l.title + " · \(lib.count(.label(l)))")
        }
    }

    @ViewBuilder private var ai: some View {
        if lib.aiReady && !lib.aiRunning {
            // Hints off: the section stays, so they can be turned back on; the AI queues hide with them.
            FSection(tr("AI-отбор"), key: "ai", hint: lib.aiOn ? tr("анализ готов") : tr("подсказки выключены")) {
                aiControls
                if lib.aiOn {
                    row(.recommended, PhotoFilter.recommended.title, icon: "sparkles", tint: Color.accentColor)
                    row(.leaders, PhotoFilter.leaders.title, icon: "crown")
                    row(.suspects, PhotoFilter.suspects.title, icon: "questionmark.circle")
                    if lib.count(.smiling) > 0 { row(.smiling, PhotoFilter.smiling.title, icon: "face.smiling") }
                }
            }
            let reasons = lib.aiOn ? CullReason.allCases.filter { lib.count(.reason($0)) > 0 } : []
            if !reasons.isEmpty {
                FSection(tr("Проблемы"), key: "problems", hint: tr("почему в сомнительных")) {
                    ForEach(reasons) { r in row(.reason(r), r.title, icon: "exclamationmark.triangle") }
                }
            }
        } else if lib.aiRunning {
            FSection(tr("AI-отбор"), key: "ai") {
                HStack(spacing: 6) {
                    ProgressView().controlSize(.mini)
                    Text(tr("Анализ идёт: \(lib.aiCount) из \(lib.photos.count)")).font(.caption).foregroundStyle(.secondary)
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
        } else if !lib.aiReady && !lib.photos.isEmpty {
            FSection(tr("AI-отбор"), key: "ai") {
                VStack(alignment: .leading, spacing: 6) {
                    Text(tr("Рекомендуемые, проблемы, люди и теги появятся после анализа.")).font(.caption).foregroundStyle(.secondary)
                    Button(tr("Запустить AI-анализ")) { lib.startAI() }.controlSize(.small)
                        .disabled(lib.analyzed < lib.photos.count)
                        .help(lib.analyzed < lib.photos.count ? tr("Дождитесь, пока папка проиндексируется") : "")
                }
                .padding(.horizontal, 8).padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder private var people: some View {
        if !lib.people.isEmpty {
            FSection(tr("Люди"), key: "people", hint: tr("человек: \(lib.people.count)")) {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 66), spacing: 6)], spacing: 6) {
                    ForEach(lib.people.prefix(24)) { p in
                        PersonTile(person: p, on: lib.personFilters.contains(p.id)) {
                            lib.togglePerson(p.id, add: NSEvent.modifierFlags.contains(.command))
                        }
                        .contextMenu {
                            Button(tr("Назвать…")) { naming = p.id; nameText = p.name ?? "" }
                            Button(lib.personFilters.contains(p.id) ? tr("Убрать из фильтра") : tr("Добавить к фильтру (⌘-клик)")) { lib.togglePerson(p.id, add: true) }
                        }
                    }
                }
                .padding(.horizontal, 6).padding(.vertical, 4)
                Text(tr("Клик — только этот человек, ⌘-клик — добавить ещё, правая кнопка — назвать."))
                    .font(.caption2).foregroundStyle(.tertiary).padding(.horizontal, 8)
            }
        }
    }

    /// What the former culling mode kept in its top bar: hints on/off, strictness, the bulk AI actions.
    private var aiControls: some View {
        @Bindable var lib = lib
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(tr("Подсказки"), isOn: $lib.cullHints).toggleStyle(.switch).controlSize(.mini)
                    .help(tr("Показывать находки AI-анализа: значки брака, AI-очереди и лица"))
                Spacer()
                if lib.aiPending > 0 {
                    Button(tr("Досчитать (\(lib.aiPending))")) { lib.startAI() }.controlSize(.mini)
                        .help(tr("Новые кадры или кадры, посчитанные до установки сетки лица"))
                }
            }
            if lib.cullHints {
                HStack(spacing: 6) {
                    Text(tr("мягко")).font(.caption2).foregroundStyle(.secondary).fixedSize()
                    Slider(value: $lib.cullStrictness, in: 0...1).controlSize(.mini)
                    Text(tr("строго")).font(.caption2).foregroundStyle(.secondary).fixedSize()
                }
                .help(tr("Строгость поиска брака: мягко — только явный, строго — всё сомнительное"))
                Menu(tr("AI-действия")) {
                    Button(tr("Отклонить предложенный брак…")) { lib.acceptSuggestions() }
                    Button(tr("Оставить лучшие в сериях, остальные в брак…")) { lib.keepBestInSeries() }
                    Divider()
                    AutoCropMenu(lib: lib)
                }
                .controlSize(.small).fixedSize()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 4)
    }

    @ViewBuilder private var tags: some View {
        let all = lib.aiReady && lib.aiEnabled.contains(.tags) ? lib.tags : []
        if !all.isEmpty {
            let shown = allTags ? all : Array(all.prefix(12))
            FSection(tr("Что на снимках"), key: "tags", hint: tr("теги")) {
                Flow(spacing: 5) {
                    ForEach(shown, id: \.id) { t in
                        let on = lib.tagFilters.contains(t.id)
                        Button { lib.toggleTag(t.id, add: NSEvent.modifierFlags.contains(.command)) } label: {
                            HStack(spacing: 4) {
                                Text(TagNames.title(t.id)).fontWeight(on ? .semibold : .regular).lineLimit(1)
                                Text("\(t.count)").foregroundStyle(on ? .primary : .tertiary).monospacedDigit()
                                    .lineLimit(1).layoutPriority(1)
                            }
                            .font(.caption)
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(on ? Theme.selected : Theme.control, in: Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    if all.count > 12 {
                        Button(allTags ? tr("Свернуть") : tr("Ещё \(all.count - 12)…")) { allTags.toggle() }
                            .buttonStyle(.plain).font(.caption).foregroundStyle(Color.accentColor).padding(.vertical, 3)
                    }
                }
                .padding(.horizontal, 8).padding(.vertical, 3)
            }
        }
    }

    @ViewBuilder private var scenes: some View {
        if lib.scenes.count > 1 {
            FSection(tr("Сцены"), key: "scenes", hint: tr("решено / всего"), open: false) {
                ForEach(lib.scenes) { sc in
                    row(.scene(sc.id), sc.title, icon: "rectangle.stack", trailing: "\(lib.sceneProgress(sc)) / \(sc.count)")
                }
            }
        }
    }

    private var bursts: some View {
        FSection(tr("Серии"), key: "bursts", open: false) {
            row(.best, PhotoFilter.best.title, icon: "square.stack.3d.up")
            row(.duplicates, PhotoFilter.duplicates.title, icon: "doc.on.doc")
        }
    }

    @ViewBuilder private var shoot: some View {
        if lib.lenses.count > 1 || lib.days.count > 1 {
            FSection(tr("Съёмка"), key: "shoot", hint: tr("объективы · даты"), open: false) {
                ForEach(lib.lenses, id: \.name) { l in
                    let on = lib.lensFilter == l.name
                    FRow(title: l.name, count: l.count, icon: "camera.aperture", on: on) { lib.lensFilter = on ? nil : l.name; lib.move(0) }
                }
                ForEach(lib.days, id: \.day) { d in
                    let on = lib.dayFilter == d.day
                    FRow(title: d.day.formatted(.dateTime.day().month(.abbreviated).year().locale(I18n.locale)), count: d.count, icon: "calendar", on: on) {
                        lib.dayFilter = on ? nil : d.day; lib.move(0)
                    }
                }
            }
        }
    }

    // MARK: - Helpers

    private func row(_ f: PhotoFilter, _ title: String, icon: String, tint: Color? = nil, trailing: String? = nil) -> some View {
        let on = lib.filter == f
        return FRow(title: title, count: trailing == nil ? lib.count(f) : nil, trailing: trailing, icon: icon, tint: tint, on: on) {
            set(on && f != .all ? .all : f)
        }
    }

    private func set(_ f: PhotoFilter) {
        lib.filter = f
        lib.move(0)
    }
}

/// Collapsible section; the state is remembered per section.
struct FSection<Content: View>: View {
    let title: String
    var hint: String?
    @AppStorage private var open: Bool
    @ViewBuilder let content: Content

    init(_ title: String, key: String, hint: String? = nil, open: Bool = true, @ViewBuilder content: () -> Content) {
        self.title = title
        self.hint = hint
        self._open = AppStorage(wrappedValue: open, "fs." + key)
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            Button { withAnimation(.easeOut(duration: 0.15)) { open.toggle() } } label: {
                HStack(spacing: 5) {
                    Image(systemName: "chevron.right").font(.caption2.weight(.bold)).foregroundStyle(.tertiary)
                        .rotationEffect(.degrees(open ? 90 : 0))
                    Text(title.uppercased()).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    if let hint { Text(hint).font(.caption2).foregroundStyle(.tertiary).lineLimit(1) }
                }
                .padding(.horizontal, 6).padding(.top, 8).padding(.bottom, 4)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open { content }
        }
    }
}

/// One filter line: icon, title, count on the right; highlighted when active. A zero count is dimmed.
struct FRow: View {
    let title: String
    var count: Int?
    var trailing: String?
    var icon: String
    var tint: Color?
    var on: Bool
    let action: () -> Void

    var body: some View {
        let empty = (count ?? 1) == 0 && !on
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: icon).font(.caption).frame(width: 14)
                    .foregroundStyle(on ? .primary : (tint ?? .secondary))
                Text(title).font(.callout).fontWeight(on ? .semibold : .regular).lineLimit(1).truncationMode(.tail)
                Spacer(minLength: 4)
                if let trailing {
                    Text(trailing).font(.caption).monospacedDigit().foregroundStyle(.secondary)
                } else if let count {
                    Text("\(count)").font(.caption).monospacedDigit().foregroundStyle(on ? .primary : .tertiary)
                }
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(on ? Color.accentColor.opacity(0.25) : .clear, in: RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .opacity(empty ? 0.5 : 1)
        }
        .buttonStyle(.plain)
    }
}

/// Active filter as a small capsule with a cross.
struct Chip: View {
    let text: String
    var icon: String?
    let clear: () -> Void

    init(_ text: String, icon: String? = nil, clear: @escaping () -> Void) {
        self.text = text; self.icon = icon; self.clear = clear
    }

    var body: some View {
        Button(action: clear) {
            HStack(spacing: 4) {
                if let icon { Image(systemName: icon) }
                Text(text).lineLimit(1)
                Image(systemName: "xmark").font(.caption2.weight(.bold)).foregroundStyle(.secondary)
            }
            .font(.caption)
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(Theme.selected, in: Capsule())
        }
        .buttonStyle(.plain)
        .help(tr("Снять этот фильтр"))
    }
}

/// A person as a face, not a line of text: the face is cut from the best-quality photo of theirs.
struct PersonTile: View {
    let person: Person
    let on: Bool
    let action: () -> Void
    @Environment(Library.self) private var lib
    @State private var face: CGImage?

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                ZStack {
                    Circle().fill(Theme.control)
                    if let face {
                        Image(decorative: face, scale: 1).resizable().scaledToFill()
                            .frame(width: 44, height: 44).clipShape(Circle())
                    } else {
                        Image(systemName: "person.fill").foregroundStyle(.tertiary)
                    }
                }
                .frame(width: 44, height: 44)
                .overlay(Circle().strokeBorder(on ? Color.accentColor : .clear, lineWidth: 2))
                Text(person.title).font(.caption2).fontWeight(on ? .semibold : .regular).lineLimit(1)
                Text("\(person.photos.count)").font(.caption2).monospacedDigit().foregroundStyle(.tertiary)
            }
            .padding(4)
            .background(on ? Color.accentColor.opacity(0.18) : .clear, in: RoundedRectangle(cornerRadius: 8))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(person.title + " · \(person.photos.count)")
        .task(id: person.faces.first) { face = await Self.crop(person, lib) }
    }

    /// The clearest face of the person, cut from its photo's thumbnail with some air around it.
    private static func crop(_ person: Person, _ lib: Library) async -> CGImage? {
        var best: (ref: FaceRef, info: FaceInfo, q: Double)?
        for r in person.faces.prefix(40) {
            guard let p = lib.photos.first(where: { $0.url == r.photo }), let f = p.cull?.faces[safe: r.index] else { continue }
            let q = (f.quality ?? 0) + (f.px ?? 0) / 2000
            if best == nil || q > best!.q { best = (r, f, q) }
        }
        guard let best, let p = lib.photos.first(where: { $0.url == best.ref.photo }) else { return nil }
        // The face coordinates are of the whole frame: the thumbnail keeps the edits' look but not the crop or straightening.
        var adj = p.adj
        adj.cropRect = CGRect(x: 0, y: 0, width: 1, height: 1); adj.angle = 0
        return await Task.detached(priority: .utility) {
            guard let img = await Renderer.shared.thumbnail(best.ref.photo, adj, size: 640) else { return nil }
            let f = best.info
            let W = CGFloat(img.width), H = CGFloat(img.height)
            let side = max(f.w * W, f.h * H) * 1.6
            let cx = (f.x + f.w / 2) * W, cy = (f.y + f.h / 2) * H
            let rect = CGRect(x: max(0, cx - side / 2), y: max(0, cy - side / 2), width: side, height: side)
                .intersection(CGRect(x: 0, y: 0, width: W, height: H))
            return img.cropping(to: rect)
        }.value
    }
}

/// Wrapping row of chips. Each chip is offered the row's width, not an unlimited one: a long person or
/// tag name then truncates inside its chip instead of running past the panel's edge.
struct Flow: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let w = proposal.width ?? 300
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: w, height: nil))
            if x > 0 && x + sz.width > w { x = 0; y += rowH + spacing; rowH = 0 }
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
        return CGSize(width: w, height: y + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, rowH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(ProposedViewSize(width: bounds.width, height: nil))
            if x > 0 && x + sz.width > bounds.width { x = 0; y += rowH + spacing; rowH = 0 }
            s.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            rowH = max(rowH, sz.height)
        }
    }
}
