import Foundation

extension PhoneLibrary {
    /// Returns only source URLs that were actually removed. The caller can use
    /// them to remove stale entries from the local player's queue.
    @discardableResult
    func deleteTracks(_ tracks: [PhoneTrack]) -> [URL] {
        performBulkTrackOperation(tracks, completionKey: "已删除，但%@") { deleteTrack($0) }
    }

    /// Moving onto the current folder is a no-op. Existing destination files
    /// are rejected by moveTrack; a batch never overwrites another song.
    @discardableResult
    func moveTracks(_ tracks: [PhoneTrack], to folder: PhoneFolder) -> [URL] {
        guard folders.contains(where: { $0.name == folder.name }) else {
            errorMessage = "目标目录已被移动或删除，请重新选择。"
            return []
        }
        let candidates = tracks.filter { $0.folder != folder.name }
        guard !candidates.isEmpty else { errorMessage = nil; return [] }
        return performBulkTrackOperation(candidates, completionKey: "已移动，但%@") {
            moveTrack($0, to: folder)
        }
    }

    private func performBulkTrackOperation(
        _ tracks: [PhoneTrack], completionKey: String, operation: (PhoneTrack) -> Bool
    ) -> [URL] {
        guard !tracks.isEmpty else { return [] }
        guard !isImporting else {
            errorMessage = "正在导入文件，请完成后再修改歌曲。"
            return []
        }

        var visited = Set<String>()
        var removedURLs: [URL] = []
        var issues: [String] = []
        for track in tracks {
            let path = track.url.standardizedFileURL.path.precomposedStringWithCanonicalMapping
            guard visited.insert(path).inserted else { continue }
            errorMessage = nil
            let succeeded = operation(track)
            let detail = errorMessage
            if succeeded { removedURLs.append(track.url) }
            if !succeeded || detail != nil {
                let reason = detail ?? "操作未完成，请刷新后重试。"
                // File mutation can succeed while its subsequent refresh fails.
                // Keep the success result, and report that warning accurately.
                let detail = succeeded ? L10n.format(completionKey, L10n.message(reason)) : L10n.message(reason)
                issues.append(L10n.format("%@：%@", track.title, detail))
            }
        }
        if issues.isEmpty {
            errorMessage = nil
        } else {
            let visible = issues.prefix(3).joined(separator: "\n")
            let remainder = issues.count > 3 ? L10n.format("\n另有 %lld 项，请分别重试。", Int64(issues.count - 3)) : ""
            errorMessage = L10n.format("有 %lld 项需要处理：\n%@%@", Int64(issues.count), visible, remainder)
        }
        return removedURLs
    }
}
