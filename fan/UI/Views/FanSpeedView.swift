//
//  FanSpeedView.swift
//  ffan
//
//  Fan speed display with unified or per-fan manual sliders (bounds from SMC).
//

import SwiftUI

struct FanSpeedView: View {
    @ObservedObject var viewModel: FanControlViewModel
    @State private var localSpeed: Double = 2000
    @State private var localSpeeds: [Double] = []
    @State private var isApplying: Bool = false
    @State private var perFanApplying: Set<Int> = []
    @State private var unifiedDebounceTask: Task<Void, Never>?
    @State private var perFanDebounceTasks: [Int: Task<Void, Never>] = [:]

    private var unifiedSliderMin: Double {
        Double(viewModel.effectiveUnifiedMinRPM)
    }

    private var unifiedSliderMax: Double {
        let hi = viewModel.effectiveUnifiedMaxRPM
        let lo = viewModel.effectiveUnifiedMinRPM
        return Double(max(hi, lo + 1))
    }

    var body: some View {
        VStack(spacing: 14) {
            headerRow

            HStack(alignment: .center, spacing: 16) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(viewModel.currentFanSpeed)")
                        .font(.system(size: 38, weight: .bold, design: .rounded))
                        .foregroundStyle(
                            LinearGradient(
                                colors: [.primary, .primary.opacity(0.7)],
                                startPoint: .top,
                                endPoint: .bottom
                            )
                        )

                    Text("avg RPM")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundColor(.secondary)
                }

                Spacer()

                SpeedGauge(percentage: safePercentage)
                    .frame(width: 56, height: 56)
            }

            if viewModel.controlMode == .manual {
                manualControls
            } else {
                autoModeBanner
            }
        }
        .padding(14)
        .liquidGlass()
        .onChange(of: viewModel.manualSpeeds) { _, newVal in
            syncLocalSpeedsFromModel(newVal)
        }
        .onChange(of: viewModel.numberOfFans) { _, _ in
            syncLocalSpeedsFromModel(viewModel.manualSpeeds)
        }
    }

    private var headerRow: some View {
        HStack {
            HStack(spacing: 6) {
                Image(systemName: "fan.fill")
                    .font(.system(size: 12))
                    .foregroundColor(.blue.opacity(0.7))

                Text("Fan Speed")
                    .font(.system(size: 14, weight: .semibold))
            }

            Spacer()

            if viewModel.numberOfFans > 0 {
                HStack(spacing: 4) {
                    Image(systemName: "circle.fill")
                        .font(.system(size: 6))
                        .foregroundColor(.green)
                    Text("\(viewModel.numberOfFans) fan\(viewModel.numberOfFans > 1 ? "s" : "")")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    private var manualControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            if viewModel.numberOfFans > 1 {
                Toggle(isOn: Binding(
                    get: { viewModel.perFanManualControl },
                    set: { viewModel.setPerFanManualControl($0) }
                )) {
                    Text("Separate targets per fan")
                        .font(.system(size: 12, weight: .medium))
                }
                .toggleStyle(.switch)
                .disabled(viewModel.controlMode != .manual)
            }

            if viewModel.perFanManualControl && viewModel.numberOfFans > 1 {
                perFanSliders
            } else {
                unifiedSliderBlock
            }
        }
    }

    private var unifiedSliderBlock: some View {
        VStack(spacing: 10) {
            Slider(
                value: $localSpeed,
                in: unifiedSliderMin...unifiedSliderMax,
                step: 100
            )
            .accentColor(.blue)
            .onChange(of: localSpeed) { _, newValue in
                unifiedDebounceTask?.cancel()
                unifiedDebounceTask = Task {
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    guard !Task.isCancelled else { return }
                    await MainActor.run {
                        if Int(newValue) != viewModel.manualSpeed {
                            isApplying = true
                            viewModel.setManualSpeed(Int(newValue))
                        }
                    }
                }
            }
            .onChange(of: viewModel.manualSpeed) { _, newValue in
                let clamped = Double(
                    max(viewModel.effectiveUnifiedMinRPM, min(viewModel.effectiveUnifiedMaxRPM, newValue))
                )
                if abs(localSpeed - clamped) > 1 {
                    localSpeed = clamped
                }
                isApplying = false
            }
            .task(id: "\(viewModel.effectiveUnifiedMinRPM)-\(viewModel.effectiveUnifiedMaxRPM)-\(viewModel.manualSpeed)") {
                localSpeed = Double(
                    max(viewModel.effectiveUnifiedMinRPM, min(viewModel.effectiveUnifiedMaxRPM, viewModel.manualSpeed))
                )
            }

            HStack {
                Text("\(viewModel.effectiveUnifiedMinRPM)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)

                Spacer()

                HStack(spacing: 4) {
                    if isApplying {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    }
                    Text("Target: \(Int(localSpeed)) RPM")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(Int(localSpeed) != viewModel.manualSpeed ? .orange : .secondary)
                }

                Spacer()

                Text("\(viewModel.effectiveUnifiedMaxRPM)")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var perFanSliders: some View {
        VStack(alignment: .leading, spacing: 14) {
            ForEach(0..<viewModel.numberOfFans, id: \.self) { index in
                perFanRow(index: index)
            }
        }
    }

    private func perFanRow(index: Int) -> some View {
        let mn = Double(viewModel.minRPM(atFan: index))
        let mx = Double(max(viewModel.maxRPM(atFan: index), viewModel.minRPM(atFan: index) + 1))
        let binding = Binding<Double>(
            get: {
                if index < localSpeeds.count {
                    return localSpeeds[index]
                }
                let v = index < viewModel.manualSpeeds.count ? viewModel.manualSpeeds[index] : viewModel.manualSpeed
                return Double(max(viewModel.minRPM(atFan: index), min(viewModel.maxRPM(atFan: index), v)))
            },
            set: { newVal in
                if localSpeeds.count <= index {
                    syncLocalSpeedsFromModel(viewModel.manualSpeeds)
                }
                if index < localSpeeds.count {
                    localSpeeds[index] = newVal
                }
                debouncedApplyPerFan(index: index, value: newVal)
            }
        )

        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Fan \(index + 1)")
                    .font(.system(size: 11, weight: .semibold))
                Spacer()
                if index < viewModel.fanSpeeds.count {
                    Text("\(viewModel.fanSpeeds[index]) RPM")
                        .font(.system(size: 10))
                        .foregroundColor(.secondary)
                }
            }

            Slider(value: binding, in: mn...mx, step: 100)
                .accentColor(.blue)

            HStack {
                Text("\(Int(mn))")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
                Spacer()
                HStack(spacing: 4) {
                    if perFanApplying.contains(index) {
                        ProgressView()
                            .scaleEffect(0.6)
                            .frame(width: 10, height: 10)
                    }
                    Text("Target: \(Int(binding.wrappedValue)) RPM")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundColor(.secondary)
                }
                Spacer()
                Text("\(Int(mx))")
                    .font(.system(size: 9))
                    .foregroundColor(.secondary)
            }
        }
    }

    private func debouncedApplyPerFan(index: Int, value: Double) {
        perFanDebounceTasks[index]?.cancel()
        perFanDebounceTasks[index] = Task {
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run {
                perFanApplying.insert(index)
                viewModel.setManualSpeedForFan(index: index, speed: Int(value))
                perFanApplying.remove(index)
                perFanDebounceTasks[index] = nil
            }
        }
    }

    private func syncLocalSpeedsFromModel(_ speeds: [Int]) {
        localSpeeds = (0..<viewModel.numberOfFans).map { i in
            let v = i < speeds.count ? speeds[i] : viewModel.manualSpeed
            return Double(max(viewModel.minRPM(atFan: i), min(viewModel.maxRPM(atFan: i), v)))
        }
    }

    private var autoModeBanner: some View {
        HStack(spacing: 10) {
            ZStack {
                Circle()
                    .fill(Color.green.opacity(0.15))
                    .frame(width: 32, height: 32)

                Image(systemName: "waveform.path.ecg")
                    .font(.system(size: 14))
                    .foregroundColor(.green)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("Automatic Control")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.primary)
                Text("Speed adjusts with temperature")
                    .font(.system(size: 10))
                    .foregroundColor(.secondary)
            }

            Spacer()

            Image(systemName: "checkmark.seal.fill")
                .foregroundColor(.green.opacity(0.6))
                .font(.system(size: 16))
        }
        .padding(10)
        .background(Color.green.opacity(0.08))
        .cornerRadius(10)
    }

    private var safePercentage: Double {
        let percent = viewModel.getFanSpeedPercent()
        if percent.isNaN || percent.isInfinite {
            return 0
        }
        return max(0, min(1, percent))
    }
}

// MARK: - Speed Gauge

struct SpeedGauge: View {
    let percentage: Double

    private var safePercentage: Double {
        if percentage.isNaN || percentage.isInfinite {
            return 0
        }
        return max(0, min(1, percentage))
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.gray.opacity(0.15), lineWidth: 5)

            Circle()
                .trim(from: 0, to: safePercentage)
                .stroke(
                    AngularGradient(
                        colors: [gaugeColor.opacity(0.5), gaugeColor],
                        center: .center,
                        startAngle: .degrees(-90),
                        endAngle: .degrees(270)
                    ),
                    style: StrokeStyle(lineWidth: 5, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: safePercentage)

            VStack(spacing: 0) {
                Text("\(Int(safePercentage * 100))")
                    .font(.system(size: 14, weight: .bold, design: .rounded))
                    .foregroundColor(gaugeColor)
                Text("%")
                    .font(.system(size: 8, weight: .medium))
                    .foregroundColor(.secondary)
            }
        }
    }

    private var gaugeColor: Color {
        if safePercentage < 0.3 {
            return .blue
        } else if safePercentage < 0.6 {
            return .green
        } else if safePercentage < 0.8 {
            return .orange
        } else {
            return .red
        }
    }
}

#Preview {
    FanSpeedView(viewModel: FanControlViewModel())
        .padding()
        .background(Color.black)
}
