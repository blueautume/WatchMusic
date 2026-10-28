import Foundation

extension PhoneLibrary {
    /// Returns only source URLs that were actually removed. The caller can use
    /// them to remove stale entries from the local player's queue.
    @discardableResult
    func deleteTracks(_ tracks: [PhoneTrack]) -> [URL] {
        performBulkTrackOperation(tracks, verb: "删除") { deleteTrack($0) }
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
        return performBulkTrackOperation(candidates, verb: "移动") {
            moveTrack($0, to: folder)
        }
    }

    private func performBulkTrackOperation(
        _ tracks: [PhoneTrack], verb: String, operation: (PhoneTrack) -> Bool
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
                issues.append("\(track.title)：\(succeeded ? "已\(verb)，但" : "")\(reason)")
            }
        }
        if issues.isEmpty {
            errorMessage = nil
        } else {
            let visible = issues.prefix(3).joined(separator: "\n")
            let remainder = issues.count > 3 ? "\n另有 \(issues.count - 3) 项，请分别重试。" : ""
            errorMessage = "有 \(issues.count) 项需要处理：\n\(visible)\(remainder)"
        }
        return removedURLs
    }
}
