
// The serializer itself remains untouched; observe source-PDF page-range
// rehydration before its platform-specific raster encoder runs.
extension OpenRouterService {
    func p0PDFSlice(_ reference: FileAttachmentReference, url: URL) throws -> [String: Any] {
        guard let bytes = dataForAttachmentReference(reference, url: url), let pdf = AdaPDF(data: bytes) else {
            throw P0Life.Failure("source PDF rehydration failed")
        }
        return ["pages": pdf.pageCount, "text": pdf.pageText(at: 0) ?? ""]
    }
}
