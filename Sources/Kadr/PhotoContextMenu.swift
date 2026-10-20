import SwiftUI

/// Меню по правому клику на превью, в ленте и в просмотре.
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

        Menu("Оценка" + suffix) {
            ForEach((1...5).reversed(), id: \.self) { r in
                Button(String(repeating: "★", count: r)) { act { lib.setRating(r) } }
            }
            Divider()
            Button("Снять оценку") { act { lib.setRating(0) } }
        }
        Menu("Цветная метка" + suffix) {
            ForEach(ColorLabel.allCases) { l in
                Button { act { lib.toggleLabel(l) } } label: {
                    Label { Text(l.title) } icon: { Image(systemName: "circle.fill").foregroundStyle(l.color) }
                }
            }
        }
        Button(photo.rejected ? "Вернуть" + suffix : "Отклонить" + suffix,
               systemImage: photo.rejected ? "arrow.uturn.backward" : "xmark.circle") { act { lib.toggleReject() } }

        Divider()

        if n == 1 && !lib.loupe {
            Button("Открыть в просмотре", systemImage: "rectangle") { act { lib.loupe = true } }
        }
        Button("Открыть в Capture One" + suffix, systemImage: "camera.aperture") { act { lib.openTargetsInCaptureOne() } }
        Button("Открыть в программе по умолчанию" + suffix, systemImage: "arrow.up.forward.app") { act { lib.openTargetsInDefaultApp() } }
        Button("Показать в Finder" + suffix, systemImage: "folder") { act { lib.revealCurrent() } }
        Button(n > 1 ? "Скопировать пути" + suffix : "Скопировать путь", systemImage: "doc.on.clipboard") { act { lib.copyTargetPaths() } }

        Divider()

        Button("Отправить в папку сохранения" + suffix, systemImage: "paperplane") { act { lib.quickSend() } }
        Button("Сохранить как JPEG…" + suffix, systemImage: "photo") { act { lib.exportTargets(as: .jpeg) } }
        Button("Сохранить оригиналы в папку…" + suffix, systemImage: "square.and.arrow.down.on.square") { act { lib.exportTargets(as: .original) } }

        if photo.seriesID != nil {
            Divider()
            Button("Выделить всю серию", systemImage: "square.stack.3d.up") { act { lib.selectSeries() } }
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
