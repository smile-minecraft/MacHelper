import Foundation

#if DEBUG
extension CachedNode {
    /// Debug builds only, for the synthetic README screenshots (`MacHelper --snapshot-demo`).
    ///
    /// Builds the tree the way a live scan leaves it, rooted at `rootPath`, so the Disk Analysis
    /// page draws it without the saved-scan banner. Nothing on disk is opened or read and the
    /// paths need not exist; sizes and counts are taken as given, so the caller must pass a tree
    /// whose directory sizes already add up.
    public func makeDemoLiveTree(rootPath: String) -> DiskNode {
        func make(_ cached: CachedNode, parent: DiskNode?, rootPath: String?) -> DiskNode {
            let node = DiskNode(name: cached.name, isDirectory: cached.isDirectory, modified: cached.modified,
                                parent: parent, rootPath: rootPath)
            node.size = cached.size
            node.fileCount = cached.fileCount
            node.smallFilesSize = cached.smallFilesSize
            node.smallFilesCount = cached.smallFilesCount
            node.children = cached.children.map { make($0, parent: node, rootPath: nil) }
                .sorted { $0.size > $1.size }
            return node
        }
        return make(self, parent: nil, rootPath: rootPath)
    }
}
#endif
