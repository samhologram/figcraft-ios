import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

enum PhotoCreationError: Error, LocalizedError, Sendable {
    case invalidImage
    case couldNotLoad

    var errorDescription: String? {
        switch self {
        case .invalidImage: "This photo could not be opened as a design."
        case .couldNotLoad: "The selected photo could not be loaded."
        }
    }
}

/// The system library opens before a FigCraft file exists. A cancelled picker throws instead of returning `nil`,
/// because `NewDocumentButton` interprets `nil` as a request for an empty document.
struct NewFromPhotoButton: View {
    @State private var pickerPresented = false
    @State private var creationContinuation: CheckedContinuation<FigCraftDocument?, any Error>?
    @State private var importError = ""
    @State private var showImportError = false

    var body: some View {
        NewDocumentButton("New from Photo", for: FigCraftDocument.self) {
            try await withCheckedThrowingContinuation { continuation in
                creationContinuation = continuation
                pickerPresented = true
            }
        }
        .accessibilityIdentifier("newFromPhoto")
        .fullScreenCover(isPresented: $pickerPresented, onDismiss: cancelIfPending) {
            SystemPhotoPicker { result in
                switch result {
                case .success(.none):
                    finish(.failure(CancellationError()))
                case .success(.some(let data)):
                    Task {
                        do {
                            let document = try await Task.detached(priority: .userInitiated) {
                                try FigCraftDocument.fromPhoto(data)
                            }.value
                            finish(.success(document))
                        } catch {
                            importError = error.localizedDescription
                            showImportError = true
                            finish(.failure(CancellationError()))
                        }
                    }
                case .failure(let error):
                    importError = error.localizedDescription
                    showImportError = true
                    finish(.failure(CancellationError()))
                }
            }
        }
        .alert("Could not import the photo", isPresented: $showImportError) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(importError)
        }
    }

    private func finish(_ result: Result<FigCraftDocument, any Error>) {
        guard let continuation = creationContinuation else { return }
        creationContinuation = nil
        pickerPresented = false
        switch result {
        case .success(let document): continuation.resume(returning: document)
        case .failure(let error): continuation.resume(throwing: error)
        }
    }

    private func cancelIfPending() {
        finish(.failure(CancellationError()))
    }
}

/// NSItemProvider crosses the picker delegate callback to the main actor once; its data is then loaded there.
private struct PhotoProviderBox: @unchecked Sendable {
    let provider: NSItemProvider?
}

private struct SystemPhotoPicker: UIViewControllerRepresentable {
    let onPick: @MainActor @Sendable (Result<Data?, PhotoCreationError>) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration(photoLibrary: .shared())
        config.filter = .images
        config.selectionLimit = 1
        config.preferredAssetRepresentationMode = .current
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ picker: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate, @unchecked Sendable {
        let onPick: @MainActor @Sendable (Result<Data?, PhotoCreationError>) -> Void

        init(onPick: @escaping @MainActor @Sendable (Result<Data?, PhotoCreationError>) -> Void) {
            self.onPick = onPick
        }

        nonisolated func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            let box = PhotoProviderBox(provider: results.first?.itemProvider)
            Task { @MainActor in load(box) }
        }

        @MainActor private func load(_ box: PhotoProviderBox) {
            guard let provider = box.provider else { onPick(.success(nil)); return }
            guard let type = provider.registeredTypeIdentifiers.first(where: {
                UTType($0)?.conforms(to: .image) == true
            }) else { onPick(.failure(.couldNotLoad)); return }
            provider.loadDataRepresentation(forTypeIdentifier: type) { [self] data, _ in
                Task { @MainActor in
                    if let data { onPick(.success(data)) }
                    else { onPick(.failure(.couldNotLoad)) }
                }
            }
        }
    }
}
