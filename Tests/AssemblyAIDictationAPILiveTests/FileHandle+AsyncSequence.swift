import Foundation

extension FileHandle: @retroactive AsyncSequence {
    /// A chunk of bytes read from the file.
    public typealias Element = ArraySlice<UInt8>

    /// Reads the file in bounded chunks and closes it at EOF.
    public struct AsyncFileIterator: AsyncIteratorProtocol {
        private let fileHandle: FileHandle
        private let chunkSize: Int
        private var isClosed = false

        init(fileHandle: FileHandle, chunkSize: Int = 65_536) {
            self.fileHandle = fileHandle
            self.chunkSize = chunkSize
        }

        /// Returns the next chunk, or nil once the file ends.
        public mutating func next() async throws -> ArraySlice<UInt8>? {
            guard !isClosed else { return nil }

            guard let data = try fileHandle.read(upToCount: chunkSize),
                !data.isEmpty
            else {
                isClosed = true
                try? fileHandle.close()
                return nil
            }

            return ArraySlice(data)
        }
    }

    /// Creates an iterator over this handle's current file position.
    public func makeAsyncIterator() -> AsyncFileIterator {
        AsyncFileIterator(fileHandle: self)
    }
}
