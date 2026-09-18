import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum ImportKind: String, Identifiable { case files, photos; var id: String { rawValue } }

struct ImportPicker: UIViewControllerRepresentable {
    let kind: ImportKind
    let model: VMModel
    func makeCoordinator() -> Coordinator { Coordinator(model) }
    func makeUIViewController(context: Context) -> UIViewController {
        if kind == .photos {
            var config = PHPickerConfiguration()
            config.filter = .images; config.selectionLimit = 10
            let picker = PHPickerViewController(configuration: config)
            picker.delegate = context.coordinator
            return picker
        }
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: [.item], asCopy: true)
        picker.allowsMultipleSelection = true
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ controller: UIViewController, context: Context) {}
    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate, PHPickerViewControllerDelegate {
        let model: VMModel
        init(_ model: VMModel) { self.model = model }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { model.importPicker = nil }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            model.importPicker = nil
            for url in urls { model.importFile(url) }
        }
        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            model.importPicker = nil
            for result in results {
                result.itemProvider.loadObject(ofClass: UIImage.self) { [weak self] image, error in
                    guard let image = image as? UIImage, let data = image.jpegData(compressionQuality: 0.92) else {
                        Task { @MainActor in self?.model.conversationNotice("照片导入失败") }; return
                    }
                    Task { @MainActor in self?.model.importPhoto(data) }
                }
            }
        }
    }
}
