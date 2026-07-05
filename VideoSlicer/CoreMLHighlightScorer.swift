import CoreML
import Foundation

struct HighlightScoreFeatures: Equatable {
    let brightnessScore: Double
    let sharpnessScore: Double
    let faceScore: Double
    let motionScore: Double
    let handcraftedScore: Double
}

struct CoreMLHighlightScorer {
    private let model: MLModel?

    init(bundle: Bundle = .main, modelName: String = "HighlightScorer") {
        guard let modelURL = bundle.url(forResource: modelName, withExtension: "mlmodelc") else {
            model = nil
            return
        }

        let configuration = MLModelConfiguration()
        configuration.computeUnits = .all
        model = try? MLModel(contentsOf: modelURL, configuration: configuration)
    }

    var isAvailable: Bool {
        model != nil
    }

    func score(features: HighlightScoreFeatures) -> Double? {
        guard let model else { return nil }

        do {
            let input = try MLDictionaryFeatureProvider(dictionary: [
                "brightnessScore": MLFeatureValue(double: features.brightnessScore),
                "sharpnessScore": MLFeatureValue(double: features.sharpnessScore),
                "faceScore": MLFeatureValue(double: features.faceScore),
                "motionScore": MLFeatureValue(double: features.motionScore),
                "handcraftedScore": MLFeatureValue(double: features.handcraftedScore)
            ])
            let prediction = try model.prediction(from: input)

            return Self.extractScore(from: prediction)
        } catch {
            return nil
        }
    }

    private static func extractScore(from prediction: MLFeatureProvider) -> Double? {
        for outputName in ["highlightScore", "score", "output"] {
            guard let value = prediction.featureValue(for: outputName) else { continue }

            switch value.type {
            case .double:
                return clamp(value.doubleValue)
            case .int64:
                return clamp(Double(value.int64Value))
            case .multiArray:
                guard let firstValue = value.multiArrayValue?.firstDouble else { continue }
                return clamp(firstValue)
            default:
                continue
            }
        }

        return nil
    }

    private static func clamp(_ value: Double) -> Double {
        min(max(value, 0), 1)
    }
}

private extension MLMultiArray {
    var firstDouble: Double? {
        guard count > 0 else { return nil }
        return self[0].doubleValue
    }
}
