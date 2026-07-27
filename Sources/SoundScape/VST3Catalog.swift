import CVST3Host
import Foundation

@MainActor
final class VST3Catalog: ObservableObject {
    @Published private(set) var components: [VST3Descriptor] = []
    @Published private(set) var isScanning = false
    @Published private(set) var errorMessage: String?

    init() {
        refresh()
    }

    func refresh() {
        guard !isScanning else { return }
        isScanning = true
        errorMessage = nil

        Task {
            do {
                let scanned = try await Task.detached(priority: .utility) {
                    var scanError: NSError?
                    let plugins = SSVST3Descriptor.scanInstalledPlugins(
                        &scanError
                    )
                    if let scanError {
                        throw scanError
                    }
                    return plugins.map {
                        VST3Descriptor(
                            modulePath: $0.modulePath,
                            classID: $0.classID,
                            name: $0.name,
                            vendor: $0.vendor,
                            version: $0.version,
                            subcategories: $0.subcategories
                        )
                    }
                }.value
                components = scanned
            } catch {
                components = []
                errorMessage = error.localizedDescription
            }
            isScanning = false
        }
    }
}
