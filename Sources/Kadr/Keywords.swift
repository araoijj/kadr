import AppKit

extension Library {
    /// AI tags → XMP keywords, so Capture One and Lightroom can find photos by them. Selected photos, or the whole
    /// folder; keywords already in the XMP stay. `ask: false` — the automatic run after AI analysis.
    func writeTagKeywords(ask: Bool = true) {
        guard aiEnabled.contains(.tags) else {
            if ask { flash(tr("Теги выключены в Настройки → AI")) }
            return
        }
        let list = (ask && multiSelected ? targets : photos).filter { !($0.cull?.tags ?? []).isEmpty }
        guard !list.isEmpty else {
            if ask { flash(tr("Тегов пока нет — запустите AI-анализ")) }
            return
        }
        if ask {
            let a = NSAlert()
            a.messageText = tr("Записать AI-теги в ключевые слова? Кадров: \(list.count)")
            a.informativeText = tr("Теги добавятся в XMP рядом с фото (поле «Ключевые слова»), их увидят Capture One и Lightroom. Ваши ключевые слова не удаляются. Где XMP ещё нет, он будет создан.")
            a.addButton(withTitle: tr("Записать"))
            a.addButton(withTitle: tr("Отмена"))
            guard a.runModal() == .alertFirstButtonReturn else { return }
        }
        let jobs = list.map { p in (p.url, Array(NSOrderedSet(array: (p.cull?.tags ?? []).map(TagNames.title))) as! [String]) }
        Task.detached(priority: .utility) {
            var files = 0, failed = 0
            for (url, words) in jobs {
                do { if try Sidecar.addKeywords(words, for: url) > 0 { files += 1 } } catch { failed += 1 }
            }
            let done = files, lost = failed
            await MainActor.run { [weak self] in
                let head = done > 0 ? tr("Ключевые слова добавлены, кадров: \(done)")
                    : lost > 0 ? tr("Ключевые слова не записаны") : tr("Ключевые слова уже записаны")
                self?.flashWritten(head, failed: lost)
            }
        }
    }
}
