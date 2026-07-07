import Foundation

enum AIFeatureReadiness {
    static var foundationModelsFrameworkAvailable: Bool {
        #if canImport(FoundationModels)
        true
        #else
        false
        #endif
    }
}
