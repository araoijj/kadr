import SwiftUI

/// Right-click menu for previews, in the filmstrip and in the viewer.
struct PhotoContextMenu: ViewModifier {
    let photo: Photo
    @Environment(Library.self) private var lib

    func body(content: Content) -> some View {
        content.contextMenu { menu }
    }

    @ViewBuilder
    private var menu: some View {
        let n = lib.contextCount(photo)
        let suffix = n > 1 ? " (\(n))" : ""

        Menu(tr("Оценка") + suffix) {
            ForEach((1...5).reversed(), id: \.self) { r in
                Button(String(repeating: "★", count: r)) { act { lib.setRating(r) } }
            }
            Divider()
            Button(tr("Снять оценку")) { act { lib.setRating(0) } }
        }
        Menu(tr("Цветная метка") + suffix) {
            ForEach(ColorLabel.allCases) { l in
                Button { act { lib.toggleLabel(l) } } label: {
                    Label { Text(l.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(l.color) }
                }
            }
        }
        Button(photo.rejected ? tr("Вернуть") + suffix : tr("Отклонить") + suffix,
               systemImage: photo.rejected ? "arrow.uturn.backward" : "xmark.circle") { act { lib.toggleReject() } }
        Button(tr("Перенести в «_Отклонённые»") + suffix, systemImage: "folder.badge.minus") { act { lib.moveTargetsToRejectedFolder() } }

        Menu(tr("Применить стиль") + suffix) {
            ForEach(lib.styles) { st in
                Button(st.name) { act { lib.applyStyle(st) } }
            }
        }
        if n == 1 {
            Button(tr("Копировать обработку"), systemImage: "doc.on.doc") { act { lib.copyAdjustments() } }
                .disabled(photo.adj.isIdentity)
        }
        Button(tr("Вставить обработку") + suffix, systemImage: "doc.on.clipboard") { act { lib.pasteAdjustments() } }
            .disabled(lib.copiedAdj == nil)
        Button(tr("Сбросить обработку") + suffix, systemImage: "arrow.counterclockwise") { act { lib.resetAdjustments() } }
        Button(tr("Выровнять экспозицию и баланс по этому кадру"), systemImage: "equal.square") {
            act { lib.matchToCurrent() }
        }
        Button(n > 1 ? tr("Предложить кадрирование") + suffix : tr("Предложить кадрирование (A)"), systemImage: "sparkles") {
            act { if lib.multiSelected { lib.startAutoCropReview(ratio: nil) } else { lib.autoCropCurrent() } }
        }

        Divider()

        if n == 1 && !lib.loupe {
            Button(tr("Открыть в просмотре"), systemImage: "rectangle") { act { lib.loupe = true } }
        }
        Button(tr("Открыть в Capture One") + suffix, systemImage: "camera.aperture") { act { lib.openTargetsInCaptureOne() } }
        Button(tr("Открыть в программе по умолчанию") + suffix, systemImage: "arrow.up.forward.app") { act { lib.openTargetsInDefaultApp() } }
        Button(tr("Показать в Finder") + suffix, systemImage: "folder") { act { lib.revealCurrent() } }
        Button(n > 1 ? tr("Скопировать пути") + suffix : tr("Скопировать путь"), systemImage: "doc.on.clipboard") { act { lib.copyTargetPaths() } }

        Divider()

        Button(tr("Отправить в папку сохранения") + suffix, systemImage: "paperplane") { act { lib.quickSend() } }
        Button(tr("Сохранить как JPEG…") + suffix, systemImage: "photo") { act { lib.exportTargets(as: .jpeg) } }
        Button(tr("Сохранить оригиналы в папку…") + suffix, systemImage: "square.and.arrow.down.on.square") { act { lib.exportTargets(as: .original) } }

        if n > 1 || photo.seriesID != nil {
            Divider()
            Button(n > 1 ? tr("Сравнить (\(min(n, 4)))") : tr("Сравнить кадры серии"), systemImage: "rectangle.split.2x1") { act { lib.startCompare() } }
        }
        if photo.seriesID != nil {
            Button(tr("Выделить всю серию"), systemImage: "square.stack.3d.up") { act { lib.selectSeries() } }
        }
        if n > 1 || photo.seriesID != nil {
            Button(tr("Турнир: выбрать лучший (T)"), systemImage: "trophy") { act { lib.startTournament() } }
        }
    }

    private func act(_ f: () -> Void) {
        lib.contextTarget(photo)
        f()
    }
}

extension View {
    func photoContextMenu(_ p: Photo) -> some View { modifier(PhotoContextMenu(photo: p)) }
}
