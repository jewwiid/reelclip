import SwiftUI

enum RecipeDurationFormatter {
    /// "5s" / "5.5s" under a minute, "1m05s" / "1m05.5s" once a
    /// minute boundary is crossed. Delegates to the shared
    /// `ClipRangeFormatter.formatDuration` so the recipe chip and
    /// the clip-range duration column always agree — no more
    /// "60s" / "65s" in the picker when the export preview is
    /// already showing "1m00s" / "1m05s".
    static func format(_ seconds: Double) -> String {
        ClipRangeFormatter.formatDuration(seconds)
    }
}

struct RecipeDurationSelector: View {
    let title: String
    let systemImage: String
    @Binding var value: Double
    let range: ClosedRange<Double>
    var detail: String?
    var randomBinding: Binding<Bool>? = nil
    var randomMinimum: Binding<Double>? = nil
    var randomMaximum: Binding<Double>? = nil

    @State private var customDurationText = ""
    @State private var isCustomDurationPresented = false

    private var clampedValue: Double {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private var presetValues: [Int] {
        [5, 10, 15, 30, 60].filter { range.contains(Double($0)) }
    }

    private var presetColumns: [GridItem] {
        [GridItem(.adaptive(minimum: 54, maximum: 84), spacing: 6)]
    }

    private var isRandomEnabled: Bool {
        randomBinding?.wrappedValue == true
    }

    private var displayedValueLabel: String {
        if isRandomEnabled,
           let randomMinimum,
           let randomMaximum {
            let lower = clampedRandomLower(minimum: randomMinimum, maximum: randomMaximum)
            let upper = clampedRandomUpper(minimum: randomMinimum, maximum: randomMaximum)
            return "\(RecipeDurationFormatter.format(lower))-\(RecipeDurationFormatter.format(upper))"
        }
        return RecipeDurationFormatter.format(clampedValue)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            header

            if !presetValues.isEmpty {
                LazyVGrid(columns: presetColumns, alignment: .leading, spacing: 6) {
                    ForEach(presetValues, id: \.self) { preset in
                        presetButton(
                            seconds: preset,
                            isSelected: isPresetSelected(preset)
                        ) {
                            applyPreset(seconds: preset)
                        }
                    }
                }
            }

            sliderControls
        }
        .padding(.vertical, 12)
        .padding(.horizontal, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .alert("Custom duration", isPresented: $isCustomDurationPresented) {
            TextField("Seconds", text: $customDurationText)
                .keyboardType(.numberPad)
            Button("Set") {
                applyCustomDuration()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Between \(RecipeDurationFormatter.format(range.lowerBound)) and \(RecipeDurationFormatter.format(range.upperBound))")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .center, spacing: 8) {
                Image(systemName: systemImage)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.accent)
                    .frame(width: 22)

                Text(title)
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
                    .lineLimit(1)
                    .minimumScaleFactor(0.82)

                Spacer(minLength: 8)

                if let randomBinding {
                    randomButton(binding: randomBinding)
                }

                Text(displayedValueLabel)
                    .font(.subheadline.monospacedDigit().weight(.bold))
                    .foregroundStyle(AppPalette.primaryText)
                    .underline(color: AppPalette.accent.opacity(0.35))
                    .contentShape(Rectangle())
                    .onTapGesture {
                        customDurationText = "\(Int(clampedValue.rounded()))"
                        isCustomDurationPresented = true
                        PolishKit.Haptics.selection.play()
                    }
                    .accessibilityLabel("Custom duration")
                    .accessibilityValue(displayedValueLabel)
                    .accessibilityHint("Double-tap to enter a custom number of seconds.")
            }

            if let detail, !detail.isEmpty {
                Text(detail)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(AppPalette.mutedText)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func randomButton(binding: Binding<Bool>) -> some View {
        Button {
            binding.wrappedValue.toggle()
            PolishKit.Haptics.tap(.light).play()
        } label: {
            Image(systemName: "shuffle")
                .font(.caption.weight(.black))
                .foregroundStyle(binding.wrappedValue ? AppPalette.background : AppPalette.secondaryText)
                .frame(width: 32, height: 32)
                .background(
                    binding.wrappedValue ? AppPalette.accent : AppPalette.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(binding.wrappedValue ? AppPalette.accent : AppPalette.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .accessibilityLabel(binding.wrappedValue ? "Random \(title) on" : "Random \(title) off")
        .accessibilityHint("Toggles random values for this recipe control.")
    }

    @ViewBuilder
    private var sliderControls: some View {
        if isRandomEnabled,
           let randomMinimum,
           let randomMaximum {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 8) {
                    Text("Random range")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.mutedText)
                    Spacer(minLength: 8)
                    Text(displayedValueLabel)
                        .font(.caption.monospacedDigit().weight(.bold))
                        .foregroundStyle(AppPalette.accent)
                }

                RecipeRandomRangeSlider(
                    lowerValue: randomMinimumSliderBinding(minimum: randomMinimum, maximum: randomMaximum),
                    upperValue: randomMaximumSliderBinding(minimum: randomMinimum, maximum: randomMaximum),
                    bounds: range,
                    title: title
                )
            }
        } else {
            Slider(value: sliderBinding, in: range, step: 1)
                .tint(AppPalette.accent)
                .accessibilityLabel(title)
                .accessibilityValue(RecipeDurationFormatter.format(clampedValue))
        }
    }

    private var sliderBinding: Binding<Double> {
        Binding(
            get: { clampedValue },
            set: { newValue in
                let rounded = newValue.rounded()
                value = min(max(rounded, range.lowerBound), range.upperBound)
            }
        )
    }

    private func randomMinimumSliderBinding(
        minimum: Binding<Double>,
        maximum: Binding<Double>
    ) -> Binding<Double> {
        Binding(
            get: { clampedRandomLower(minimum: minimum, maximum: maximum) },
            set: { newValue in
                let upper = clampedRandomUpper(minimum: minimum, maximum: maximum)
                let rounded = newValue.rounded()
                minimum.wrappedValue = min(max(rounded, range.lowerBound), upper)
            }
        )
    }

    private func randomMaximumSliderBinding(
        minimum: Binding<Double>,
        maximum: Binding<Double>
    ) -> Binding<Double> {
        Binding(
            get: { clampedRandomUpper(minimum: minimum, maximum: maximum) },
            set: { newValue in
                let lower = clampedRandomLower(minimum: minimum, maximum: maximum)
                let rounded = newValue.rounded()
                maximum.wrappedValue = max(min(rounded, range.upperBound), lower)
            }
        )
    }

    private func clampedRandomLower(
        minimum: Binding<Double>,
        maximum: Binding<Double>
    ) -> Double {
        let lower = min(minimum.wrappedValue, maximum.wrappedValue)
        return min(max(lower.rounded(), range.lowerBound), range.upperBound)
    }

    private func clampedRandomUpper(
        minimum: Binding<Double>,
        maximum: Binding<Double>
    ) -> Double {
        let upper = max(minimum.wrappedValue, maximum.wrappedValue)
        return min(max(upper.rounded(), range.lowerBound), range.upperBound)
    }

    private func isPresetSelected(_ seconds: Int) -> Bool {
        if isRandomEnabled,
           let randomMaximum {
            return Int(clampedRandomUpper(minimum: randomMinimum ?? randomMaximum, maximum: randomMaximum).rounded()) == seconds
        }
        return Int(clampedValue.rounded()) == seconds
    }

    private func applyPreset(seconds: Int) {
        if isRandomEnabled,
           let randomMaximum {
            randomMaximum.wrappedValue = Double(seconds)
            value = Double(seconds)
        } else {
            value = Double(seconds)
        }
    }

    private func presetButton(
        seconds: Int,
        isSelected: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button {
            action()
            PolishKit.Haptics.tap(.light).play()
        } label: {
            Text(RecipeDurationFormatter.format(Double(seconds)))
                .font(.caption.monospacedDigit().weight(.black))
                .foregroundStyle(isSelected ? AppPalette.background : AppPalette.primaryText)
                .frame(maxWidth: .infinity)
                .frame(minHeight: 34)
                .background(
                    isSelected ? AppPalette.accent : AppPalette.raisedSurface,
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(isSelected ? AppPalette.accent : AppPalette.hairline, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
    }

    private func applyCustomDuration() {
        let trimmed = customDurationText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let seconds = Double(trimmed), seconds.isFinite, seconds > 0 else {
            PolishKit.Haptics.tap(.light).play()
            return
        }

        let rounded = seconds.rounded()
        value = min(max(rounded, range.lowerBound), range.upperBound)
        PolishKit.Haptics.tap(.medium).play()
    }
}

private struct RecipeRandomRangeSlider: View {
    @Binding var lowerValue: Double
    @Binding var upperValue: Double
    let bounds: ClosedRange<Double>
    let title: String

    @State private var activeHandle: Handle?
    @State private var editingHandle: Handle?
    @State private var editingText = ""

    private enum Handle {
        case lower
        case upper
    }

    private let handleHitWidth: CGFloat = 44
    private let thumbDiameter: CGFloat = 30
    private let trackHeight: CGFloat = 6
    private let minimumGap: Double = 1

    private var lowerDisplay: Double {
        min(max(min(lowerValue, upperValue), bounds.lowerBound), bounds.upperBound)
    }

    private var upperDisplay: Double {
        min(max(max(lowerValue, upperValue), bounds.lowerBound), bounds.upperBound)
    }

    private var effectiveGap: Double {
        max(0, min(minimumGap, bounds.upperBound - bounds.lowerBound))
    }

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let usableWidth = max(proxy.size.width - handleHitWidth, 1)
                let lowerX = xPosition(for: lowerDisplay, usableWidth: usableWidth) + handleHitWidth / 2
                let upperX = xPosition(for: upperDisplay, usableWidth: usableWidth) + handleHitWidth / 2
                let centerY = proxy.size.height / 2

                ZStack(alignment: .leading) {
                    Capsule()
                        .fill(AppPalette.raisedSurface)
                        .frame(height: trackHeight)
                        .position(x: proxy.size.width / 2, y: centerY)

                    Capsule()
                        .fill(AppPalette.accent)
                        .frame(width: max(upperX - lowerX, trackHeight), height: trackHeight)
                        .position(x: lowerX + max(upperX - lowerX, trackHeight) / 2, y: centerY)

                    rangeHandle(isActive: activeHandle == .lower)
                        .position(x: lowerX, y: centerY)
                        .zIndex(activeHandle == .lower ? 2 : 1)

                    rangeHandle(isActive: activeHandle == .upper)
                        .position(x: upperX, y: centerY)
                        .zIndex(activeHandle == .upper ? 2 : 1)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let rawValue = valueForLocation(
                                value.location.x - handleHitWidth / 2,
                                usableWidth: usableWidth
                            )
                            if activeHandle == nil {
                                activeHandle = closestHandle(to: rawValue)
                            }
                            update(activeHandle, to: rawValue)
                        }
                        .onEnded { _ in
                            activeHandle = nil
                        }
                )
            }
            .frame(height: 40)

            HStack(spacing: 8) {
                valueEditorButton(
                    handle: .lower,
                    label: "Min",
                    value: lowerDisplay
                )
                Spacer(minLength: 8)
                valueEditorButton(
                    handle: .upper,
                    label: "Max",
                    value: upperDisplay
                )
            }
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title) random range")
        .accessibilityValue("\(RecipeDurationFormatter.format(lowerDisplay)) to \(RecipeDurationFormatter.format(upperDisplay))")
        .accessibilityHint("Drag the left or right handle to set the minimum and maximum random value.")
        .alert(editingTitle, isPresented: editingBinding) {
            TextField("Seconds", text: $editingText)
                .keyboardType(.decimalPad)
            Button("Set") {
                applyTypedValue()
            }
            Button("Cancel", role: .cancel) {
                editingHandle = nil
            }
        } message: {
            Text("Between \(RecipeDurationFormatter.format(bounds.lowerBound)) and \(RecipeDurationFormatter.format(bounds.upperBound))")
        }
    }

    private var editingBinding: Binding<Bool> {
        Binding(
            get: { editingHandle != nil },
            set: { isPresented in
                if !isPresented {
                    editingHandle = nil
                }
            }
        )
    }

    private var editingTitle: String {
        switch editingHandle {
        case .lower:
            return "Minimum random value"
        case .upper:
            return "Maximum random value"
        case nil:
            return "Random value"
        }
    }

    private func valueEditorButton(handle: Handle, label: String, value: Double) -> some View {
        Button {
            editingHandle = handle
            editingText = "\(Int(value.rounded()))"
            PolishKit.Haptics.selection.play()
        } label: {
            Text("\(label) \(RecipeDurationFormatter.format(value))")
                .font(.caption2.monospacedDigit().weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)
                .underline(color: AppPalette.accent.opacity(0.3))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label) random \(title)")
        .accessibilityValue(RecipeDurationFormatter.format(value))
        .accessibilityHint("Double-tap to enter an exact value.")
    }

    private func rangeHandle(isActive: Bool) -> some View {
        Circle()
            .fill(Color.white)
            .frame(width: thumbDiameter, height: thumbDiameter)
            .overlay {
                Circle()
                    .stroke(isActive ? AppPalette.accent : Color.white.opacity(0.9), lineWidth: isActive ? 2 : 1)
            }
            .shadow(color: .black.opacity(isActive ? 0.24 : 0.16), radius: isActive ? 7 : 4, x: 0, y: 2)
            .frame(width: handleHitWidth, height: handleHitWidth)
            .contentShape(Rectangle())
            .scaleEffect(isActive ? 1.05 : 1)
            .animation(.snappy(duration: 0.16), value: isActive)
    }

    private func xPosition(for value: Double, usableWidth: CGFloat) -> CGFloat {
        guard bounds.upperBound > bounds.lowerBound else { return 0 }
        let clamped = min(max(value, bounds.lowerBound), bounds.upperBound)
        let ratio = (clamped - bounds.lowerBound) / (bounds.upperBound - bounds.lowerBound)
        return CGFloat(ratio) * usableWidth
    }

    private func valueForLocation(_ x: CGFloat, usableWidth: CGFloat) -> Double {
        guard bounds.upperBound > bounds.lowerBound else { return bounds.lowerBound }
        let clampedX = min(max(x, 0), usableWidth)
        let ratio = Double(clampedX / max(usableWidth, 1))
        let value = bounds.lowerBound + ratio * (bounds.upperBound - bounds.lowerBound)
        return value.rounded()
    }

    private func closestHandle(to value: Double) -> Handle {
        let lowerDistance = abs(value - lowerDisplay)
        let upperDistance = abs(value - upperDisplay)
        return lowerDistance <= upperDistance ? .lower : .upper
    }

    private func update(_ handle: Handle?, to rawValue: Double) {
        guard let handle else { return }
        switch handle {
        case .lower:
            let upperLimit = max(bounds.lowerBound, upperDisplay - effectiveGap)
            lowerValue = min(max(rawValue, bounds.lowerBound), upperLimit)
        case .upper:
            let lowerLimit = min(bounds.upperBound, lowerDisplay + effectiveGap)
            upperValue = max(min(rawValue, bounds.upperBound), lowerLimit)
        }
    }

    private func applyTypedValue() {
        let trimmed = editingText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Double(trimmed), value.isFinite else {
            PolishKit.Haptics.tap(.light).play()
            return
        }

        update(editingHandle, to: value.rounded())
        editingHandle = nil
        PolishKit.Haptics.tap(.medium).play()
    }
}

struct FixedRecipeEditor: View {
    let title: String
    @Binding var inputStyle: FixedModeInputStyle
    @Binding var queryDraft: String
    @Binding var buttonCount: Int
    @Binding var buttonDuration: Int
    @Binding var buttonInterval: Int
    var randomDurationBinding: Binding<Bool>? = nil
    var randomIntervalBinding: Binding<Bool>? = nil
    var randomDurationMinimum: Binding<Double>? = nil
    var randomDurationMaximum: Binding<Double>? = nil
    var randomIntervalMinimum: Binding<Double>? = nil
    var randomIntervalMaximum: Binding<Double>? = nil
    let durationRange: ClosedRange<Double>
    var parsedQuery: ClipQuery?
    var durationDetail: String?
    var intervalDetail: String?
    var textFocus: FocusState<Bool>.Binding?
    var repairState: VideoSplitterViewModel.RepairState?
    var isRepairAvailable = false
    var onRepair: (() -> Void)?
    var onApplyRepair: ((String) -> Void)?
    var onDismissRepair: (() -> Void)?

    @State private var customCountText = ""
    @State private var isCustomCountPresented = false

    private var effectiveQuery: ClipQuery? {
        switch inputStyle {
        case .text:
            return parsedQuery ?? ClipQueryParser.parse(queryDraft)
        case .buttons:
            return parsedQuery ?? ClipQuery(
                count: buttonCount,
                durationSeconds: Double(buttonDuration),
                intervalSeconds: Double(buttonInterval)
            )
        }
    }

    private var showsRepair: Bool {
        guard isRepairAvailable else { return false }
        guard !queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        return effectiveQuery?.isValid != true
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Cut mode is now buttons-only — the natural-language
            // text input previously exposed via the styleHeader
            // toggle belonged in the AI mode workflow
            // (`promptControl`), not here. Removing the toggle +
            // text input keeps Cut as a single coherent
            // "configure the grid" surface and stops the
            // duplication between Cut's text parser and AI's
            // Apple-Intelligence prompt.
            buttonInputs

            detectionChips
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .animation(.snappy(duration: 0.2), value: effectiveQuery)
        .animation(.snappy(duration: 0.2), value: repairState)
        .alert("Clip amount", isPresented: $isCustomCountPresented) {
            TextField("Clips", text: $customCountText)
                .keyboardType(.numberPad)
            Button("Set") {
                applyCustomCount()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Between 1 and 50 clips")
        }
    }

    private var styleHeader: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption.weight(.bold))
                .foregroundStyle(AppPalette.secondaryText)

            Picker("Input style", selection: Binding(
                get: { inputStyle },
                set: { newStyle in
                    inputStyle = newStyle
                    PolishKit.Haptics.tap(.light).play()
                }
            )) {
                ForEach(FixedModeInputStyle.allCases) { style in
                    Text(style.label).tag(style)
                }
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: .infinity)
        }
    }

    private var textInput: some View {
        let parsed = ClipQueryParser.parse(queryDraft)
        let queryEmpty = queryDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let parsedIsValid = parsed?.isValid == true

        return VStack(alignment: .leading, spacing: 8) {
            TextField(
                "e.g. 4 five-second clips cut every 10 seconds",
                text: $queryDraft,
                axis: .vertical
            )
            .lineLimit(2...3)
            .optionalBoolFocus(textFocus)
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .stroke(
                        parsedIsValid ? AppPalette.accent.opacity(0.55) : AppPalette.hairline,
                        lineWidth: parsedIsValid ? 1.5 : 1
                    )
            }
            .foregroundStyle(AppPalette.primaryText)
            .font(.subheadline)

            HStack(spacing: 6) {
                if queryEmpty {
                    Image(systemName: "info.circle")
                        .font(.caption.weight(.bold))
                    Text("Type a recipe, or switch to Buttons.")
                        .font(.caption)
                } else if parsedIsValid {
                    Image(systemName: "checkmark.seal.fill")
                        .font(.caption.weight(.bold))
                    Text(parsed?.summary ?? "")
                        .font(.caption.weight(.semibold))
                } else {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.caption.weight(.bold))
                    Text("Couldn't parse - try \"4 five-second clips every 10 seconds\"")
                        .font(.caption)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(
                queryEmpty
                    ? AppPalette.mutedText
                    : (parsedIsValid ? AppPalette.accent : AppPalette.secondaryText)
            )
            .lineLimit(2)
            .fixedSize(horizontal: false, vertical: true)

            if showsRepair {
                repairAffordance
            }
        }
    }

    private var buttonInputs: some View {
        VStack(spacing: 10) {
            countStepper

            RecipeDurationSelector(
                title: "Clip duration",
                systemImage: "clock",
                value: Binding(
                    get: { Double(buttonDuration) },
                    set: { buttonDuration = Int($0.rounded()) }
                ),
                range: durationRange,
                detail: durationDetail,
                randomBinding: randomDurationBinding,
                randomMinimum: randomDurationMinimum,
                randomMaximum: randomDurationMaximum
            )

            RecipeDurationSelector(
                title: "Space",
                systemImage: "arrow.left.and.right",
                value: Binding(
                    get: { Double(buttonInterval) },
                    set: { buttonInterval = Int($0.rounded()) }
                ),
                range: durationRange,
                detail: intervalDetail,
                randomBinding: randomIntervalBinding,
                randomMinimum: randomIntervalMinimum,
                randomMaximum: randomIntervalMaximum
            )
        }
    }

    private var countStepper: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                countLabel
                Spacer(minLength: 8)
                countStepperButtons
            }

            VStack(alignment: .leading, spacing: 10) {
                countLabel
                countStepperButtons
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
    }

    private var countLabel: some View {
        HStack(spacing: 10) {
            Image(systemName: "rectangle.stack")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(AppPalette.accent)
                .frame(width: 30, height: 30)
                .background(AppPalette.accent.opacity(0.12), in: Circle())

            Text("Clip amount")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(AppPalette.primaryText)
        }
    }

    private var countStepperButtons: some View {
        HStack(spacing: 0) {
            countStepButton(systemImage: "minus", disabled: buttonCount <= 1) {
                buttonCount = max(1, buttonCount - 1)
                PolishKit.Haptics.tap(.light).play()
            }

            Text("\(buttonCount)")
                .font(.subheadline.monospacedDigit().weight(.black))
                .foregroundStyle(AppPalette.primaryText)
                .frame(minWidth: 56)
                .padding(.horizontal, 4)
                .contentShape(Rectangle())
                .onTapGesture {
                    customCountText = "\(buttonCount)"
                    isCustomCountPresented = true
                    PolishKit.Haptics.tap(.light).play()
                }

            countStepButton(systemImage: "plus", disabled: buttonCount >= 50) {
                buttonCount = min(50, buttonCount + 1)
                PolishKit.Haptics.tap(.light).play()
            }
        }
        .background(AppPalette.raisedSurface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(AppPalette.hairline, lineWidth: 1)
        }
        .animation(.snappy(duration: 0.18), value: buttonCount)
    }

    private func countStepButton(
        systemImage: String,
        disabled: Bool,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.subheadline.weight(.bold))
                .frame(width: 44, height: 44)
                .foregroundStyle(disabled ? AppPalette.mutedText : AppPalette.primaryText)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .disabled(disabled)
    }

    private var detectionChips: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 96, maximum: 160), spacing: 8)],
            alignment: .leading,
            spacing: 8
        ) {
            chip(
                title: "Count",
                value: effectiveQuery?.count.map { "\($0)" },
                detected: effectiveQuery?.detectedCount == true
            )
            chip(
                title: "Duration",
                value: randomDurationBinding?.wrappedValue == true ? "Random" : effectiveQuery?.durationSeconds.map { "\(Int($0))s" },
                detected: randomDurationBinding?.wrappedValue == true || effectiveQuery?.detectedDuration == true
            )
            chip(
                title: "Spacing",
                value: randomIntervalBinding?.wrappedValue == true ? "Random" : effectiveQuery?.intervalSeconds.map { "\(Int($0))s" },
                detected: randomIntervalBinding?.wrappedValue == true || effectiveQuery?.detectedInterval == true
            )
        }
    }

    private func chip(title: String, value: String?, detected: Bool) -> some View {
        HStack(spacing: 5) {
            Image(systemName: detected ? "checkmark.circle.fill" : "circle.dashed")
                .font(.caption.weight(.bold))
                .foregroundStyle(detected ? AppPalette.accent : AppPalette.mutedText)
            VStack(alignment: .leading, spacing: 1) {
                Text(title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(AppPalette.mutedText)
                    .textCase(.uppercase)
                    .tracking(0.6)
                Text(value ?? "-")
                    .font(.caption.monospacedDigit().weight(.semibold))
                    .foregroundStyle(detected ? AppPalette.primaryText : AppPalette.mutedText)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            (detected ? AppPalette.accent.opacity(0.15) : AppPalette.controlSurface),
            in: RoundedRectangle(cornerRadius: 10, style: .continuous)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(detected ? AppPalette.accent.opacity(0.45) : AppPalette.hairline, lineWidth: 1)
        }
    }

    @ViewBuilder
    private var repairAffordance: some View {
        switch repairState ?? .idle {
        case .idle:
            Button {
                onRepair?()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.purple)
                    Text("Repair with Apple Intelligence")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(AppPalette.primaryText)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(AppPalette.mutedText)
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 10)
                .background(
                    LinearGradient(
                        colors: [Color.purple.opacity(0.10), Color.blue.opacity(0.06)],
                        startPoint: .leading, endPoint: .trailing
                    ),
                    in: RoundedRectangle(cornerRadius: 10, style: .continuous)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                        .stroke(Color.purple.opacity(0.25), lineWidth: 1)
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Repair recipe with Apple Intelligence")

        case .running:
            HStack(spacing: 8) {
                ProgressView()
                    .scaleEffect(0.75)
                Text("Asking Apple Intelligence...")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))

        case .repaired(let suggestion):
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "sparkles")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(.purple)
                    Text("Suggestion")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(AppPalette.mutedText)
                        .textCase(.uppercase)
                        .tracking(0.6)
                    Spacer(minLength: 0)
                }
                Text(suggestion)
                    .font(.subheadline)
                    .foregroundStyle(AppPalette.primaryText)
                    .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    Button {
                        onApplyRepair?(suggestion)
                    } label: {
                        Text("Use this")
                            .font(.caption.weight(.bold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .background(AppPalette.accent, in: Capsule())
                            .foregroundStyle(.white)
                    }
                    .buttonStyle(.plain)
                    Button {
                        onDismissRepair?()
                    } label: {
                        Text("Discard")
                            .font(.caption.weight(.semibold))
                            .padding(.horizontal, 14)
                            .padding(.vertical, 8)
                            .foregroundStyle(AppPalette.secondaryText)
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
            }
            .padding(12)
            .background(
                LinearGradient(
                    colors: [Color.purple.opacity(0.08), Color.blue.opacity(0.04)],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                ),
                in: RoundedRectangle(cornerRadius: 12, style: .continuous)
            )
            .overlay {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(Color.purple.opacity(0.25), lineWidth: 1)
            }

        case .failed(let reason):
            HStack(spacing: 6) {
                Image(systemName: "xmark.octagon.fill")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(AppPalette.secondaryText)
                Text(reason)
                    .font(.caption)
                    .foregroundStyle(AppPalette.secondaryText)
                Spacer(minLength: 0)
                Button("Try again") {
                    onRepair?()
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.plain)
                .foregroundStyle(AppPalette.accent)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(AppPalette.controlSurface, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func applyCustomCount() {
        let trimmed = customCountText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let parsed = Int(trimmed), (1...50).contains(parsed) else {
            PolishKit.Haptics.warning.play()
            return
        }

        buttonCount = parsed
        PolishKit.Haptics.tap(.light).play()
    }
}

private struct OptionalBoolFocusModifier: ViewModifier {
    let focus: FocusState<Bool>.Binding?

    @ViewBuilder
    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus)
        } else {
            content
        }
    }
}

private extension View {
    func optionalBoolFocus(_ focus: FocusState<Bool>.Binding?) -> some View {
        modifier(OptionalBoolFocusModifier(focus: focus))
    }
}
