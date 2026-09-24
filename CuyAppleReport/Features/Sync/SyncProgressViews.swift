import SwiftUI

private enum SyncPalette {
    static let running: [Color] = [.cyan, .blue, .purple, .pink, .cyan]
    static let success: [Color] = [.mint, .green, .teal, .mint]
    static let failure: [Color] = [.orange, .red, .pink, .orange]

    static func colors(for progress: SyncProgress) -> [Color] {
        switch progress.phase {
        case .done: success
        case .failed: failure
        default: running
        }
    }
}

/// Indicador principal: anillo de progreso con degradado, un cometa orbitando, una órbita
/// punteada que gira al revés y el logo latiendo en el centro. Al terminar, check o error.
struct SyncLoader: View {
    let progress: SyncProgress
    var size: CGFloat = 68

    private var lineWidth: CGFloat { max(3, size * 0.085) }

    var body: some View {
        TimelineView(.animation(minimumInterval: nil, paused: progress.isFinished)) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            let colors = SyncPalette.colors(for: progress)
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [colors[1].opacity(0.35), .clear], center: .center,
                                         startRadius: 0, endRadius: size * 0.75))
                    .scaleEffect(progress.isFinished ? 1.1 : 1 + 0.07 * sin(t * 2.4))
                    .blur(radius: 6)

                Circle().stroke(.primary.opacity(0.08), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: max(0.03, progress.fraction))
                    .stroke(AngularGradient(colors: colors, center: .center),
                            style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                    .rotationEffect(.degrees(-90))
                    .shadow(color: colors[1].opacity(0.6), radius: 4)
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: progress.fraction)

                if !progress.isFinished {
                    Circle()
                        .trim(from: 0, to: 0.24)
                        .stroke(AngularGradient(colors: [.clear, .white.opacity(0.95)], center: .center,
                                                startAngle: .degrees(0), endAngle: .degrees(86)),
                                style: StrokeStyle(lineWidth: lineWidth * 0.55, lineCap: .round))
                        .padding(lineWidth * 1.7)
                        .rotationEffect(.degrees((t * 290).truncatingRemainder(dividingBy: 360)))

                    Circle()
                        .stroke(style: StrokeStyle(lineWidth: 1.2, dash: [1.5, 5]))
                        .foregroundStyle(.secondary.opacity(0.6))
                        .padding(lineWidth * 3.1)
                        .rotationEffect(.degrees(-(t * 45).truncatingRemainder(dividingBy: 360)))
                }

                center(t: t)
            }
            .frame(width: size, height: size)
        }
    }

    @ViewBuilder
    private func center(t: TimeInterval) -> some View {
        switch progress.phase {
        case .done:
            Image(systemName: "checkmark")
                .font(.system(size: size * 0.32, weight: .heavy))
                .foregroundStyle(.green)
                .symbolEffect(.bounce, value: progress.phase)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
        case .failed:
            Image(systemName: "xmark")
                .font(.system(size: size * 0.3, weight: .heavy))
                .foregroundStyle(.red)
                .symbolEffect(.bounce, value: progress.phase)
                .transition(.scale(scale: 0.3).combined(with: .opacity))
        default:
            Image("CuyAppleReportMark")
                .resizable()
                .scaledToFill()
                .frame(width: size * 0.42, height: size * 0.42)
                .clipShape(Circle())
                .scaleEffect(1 + 0.06 * sin(t * 3.2))
                .rotationEffect(.degrees(6 * sin(t * 1.6)))
        }
    }
}

/// Spinner compacto para la barra de herramientas y la barra de menús.
struct SyncSpinner: View {
    var size: CGFloat = 16

    var body: some View {
        TimelineView(.animation) { context in
            let t = context.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().stroke(.primary.opacity(0.1), lineWidth: size * 0.14)
                Circle()
                    .trim(from: 0.05, to: 0.72)
                    .stroke(AngularGradient(colors: [.cyan.opacity(0), .cyan, .blue, .purple], center: .center),
                            style: StrokeStyle(lineWidth: size * 0.14, lineCap: .round))
                    .rotationEffect(.degrees((t * 400).truncatingRemainder(dividingBy: 360)))
            }
            .frame(width: size, height: size)
        }
        .accessibilityLabel("Sincronizando")
    }
}

/// Barra de progreso con degradado, brillo y un reflejo que la recorre.
struct GlowingProgressBar: View {
    let fraction: Double
    let colors: [Color]
    var animating = true

    var body: some View {
        GeometryReader { proxy in
            let width = max(8, proxy.size.width * min(1, fraction))
            ZStack(alignment: .leading) {
                Capsule().fill(.primary.opacity(0.08))
                Capsule()
                    .fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing))
                    .frame(width: width)
                    .overlay(alignment: .leading) {
                        if animating {
                            TimelineView(.animation) { context in
                                let phase = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.6) / 1.6
                                LinearGradient(colors: [.clear, .white.opacity(0.6), .clear], startPoint: .leading, endPoint: .trailing)
                                    .frame(width: 70)
                                    .offset(x: phase * (width + 70) - 70)
                            }
                            .clipShape(Capsule())
                        }
                    }
                    .shadow(color: colors[1].opacity(0.55), radius: 5)
                    .animation(.spring(response: 0.6, dampingFraction: 0.85), value: fraction)
            }
        }
        .frame(height: 7)
    }
}

/// Tarjeta flotante con el detalle de la sincronización.
struct SyncProgressCard: View {
    let progress: SyncProgress
    var onClose: () -> Void
    var onSignIn: (() -> Void)?

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .center, spacing: 14) {
                SyncLoader(progress: progress, size: 66)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(headline).font(.headline)
                        Spacer()
                        if progress.isFinished {
                            Button(action: onClose) {
                                Image(systemName: "xmark").font(.caption.weight(.bold)).foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help("Cerrar")
                        } else {
                            Text("\(Int((progress.fraction * 100).rounded()))%")
                                .font(.title3.monospacedDigit().weight(.semibold))
                                .contentTransition(.numericText(value: progress.fraction))
                                .animation(.snappy, value: progress.fraction)
                        }
                    }
                    Text(subtitle)
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(3)
                        .contentTransition(.opacity)
                        .animation(.easeInOut(duration: 0.2), value: subtitle)
                    if let appName = progress.appName, !progress.isFinished, progress.appCount > 0 {
                        Text("\(appName) · app \(progress.appIndex + 1) de \(progress.appCount)")
                            .font(.caption).foregroundStyle(.tertiary).lineLimit(1)
                    }
                }
            }

            GlowingProgressBar(fraction: progress.fraction, colors: SyncPalette.colors(for: progress),
                               animating: !progress.isFinished)

            HStack(spacing: 0) {
                ForEach(Array(SyncProgress.Phase.steps.enumerated()), id: \.element) { offset, step in
                    StepIndicator(step: step, state: state(of: step))
                    if offset < SyncProgress.Phase.steps.count - 1 {
                        Capsule()
                            .fill(state(of: step) == .done ? AnyShapeStyle(Color.green.opacity(0.7)) : AnyShapeStyle(.quaternary))
                            .frame(height: 2)
                            .frame(maxWidth: .infinity)
                            .padding(.bottom, 16)
                            .animation(.easeInOut(duration: 0.3), value: state(of: step))
                    }
                }
            }

            HStack(spacing: 16) {
                counter("tray.full", "\(progress.found)", "revisados")
                counter("sparkles", "\(progress.newItems)", "nuevos")
                if progress.imagesTotal > 0 {
                    counter("photo.on.rectangle", "\(progress.imagesDone)/\(progress.imagesTotal)", "capturas")
                }
            }

            if progress.phase == .failed, progress.sessionExpired, let onSignIn {
                Button(action: onSignIn) {
                    Label("Iniciar sesión", systemImage: "person.badge.key")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(16)
        .frame(width: 390)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(LinearGradient(colors: SyncPalette.colors(for: progress).map { $0.opacity(0.45) },
                                             startPoint: .topLeading, endPoint: .bottomTrailing), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.28), radius: 26, y: 14)
    }

    private var headline: String {
        switch progress.phase {
        case .done: progress.newItems == 0 ? "¡Todo al día!" : (progress.newItems == 1 ? "¡1 elemento nuevo!" : "¡\(progress.newItems) elementos nuevos!")
        case .failed: progress.sessionExpired ? "Sesión expirada" : "No se pudo sincronizar"
        default: "Sincronizando"
        }
    }

    private var subtitle: String {
        switch progress.phase {
        case .done:
            let apps = progress.appCount == 1 ? "1 app" : "\(progress.appCount) apps"
            return "Se revisaron \(progress.found) elementos en \(apps)."
        case .failed:
            return progress.errorMessage ?? "Ocurrió un error inesperado."
        case .images where progress.imagesTotal > 0:
            return "\(progress.phase.title) · \(progress.imagesDone) de \(progress.imagesTotal)"
        default:
            return progress.phase.title + "…"
        }
    }

    private func state(of step: SyncProgress.Phase) -> StepIndicator.State {
        switch progress.phase {
        case .done, .saving: return .done
        case .failed:
            if step.rawValue < progress.lastStep.rawValue { return .done }
            return step == progress.lastStep ? .failed : .pending
        default:
            if step.rawValue < progress.phase.rawValue { return .done }
            return step == progress.phase ? .active : .pending
        }
    }

    private func counter(_ symbol: String, _ value: String, _ label: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).foregroundStyle(.secondary)
            Text(value).font(.callout.monospacedDigit().weight(.semibold))
                .contentTransition(.numericText())
                .animation(.snappy, value: value)
            Text(label).font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct StepIndicator: View {
    enum State: Equatable { case pending, active, done, failed }
    let step: SyncProgress.Phase
    let state: State

    var body: some View {
        VStack(spacing: 5) {
            ZStack {
                Circle()
                    .fill(fill)
                    .frame(width: 26, height: 26)
                if state == .active {
                    TimelineView(.animation) { context in
                        let t = context.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.3) / 1.3
                        Circle()
                            .stroke(Color.blue.opacity(1 - t), lineWidth: 2)
                            .frame(width: 26, height: 26)
                            .scaleEffect(1 + t * 0.6)
                    }
                }
                Image(systemName: icon)
                    .font(.system(size: 11, weight: .bold))
                    .foregroundStyle(state == .pending ? AnyShapeStyle(.secondary) : AnyShapeStyle(.white))
                    .contentTransition(.symbolEffect(.replace))
            }
            .frame(width: 34, height: 34)
            Text(step.shortTitle)
                .font(.caption2.weight(state == .active ? .semibold : .regular))
                .foregroundStyle(state == .pending ? .tertiary : .primary)
                .fixedSize()
        }
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: state)
    }

    private var icon: String {
        switch state {
        case .done: "checkmark"
        case .failed: "xmark"
        default: step.symbol
        }
    }

    private var fill: AnyShapeStyle {
        switch state {
        case .pending: AnyShapeStyle(.quaternary)
        case .active: AnyShapeStyle(LinearGradient(colors: [.cyan, .blue, .purple], startPoint: .topLeading, endPoint: .bottomTrailing))
        case .done: AnyShapeStyle(Color.green)
        case .failed: AnyShapeStyle(Color.red)
        }
    }
}
