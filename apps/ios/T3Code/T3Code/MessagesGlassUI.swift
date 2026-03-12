import SwiftUI

struct GlassCapsuleSurface<Content: View>: View {
    let horizontalPadding: CGFloat
    let verticalPadding: CGFloat
    let content: Content

    init(
        horizontalPadding: CGFloat = 14,
        verticalPadding: CGFloat = 11,
        @ViewBuilder content: () -> Content
    ) {
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.content = content()
    }

    var body: some View {
        content
            .padding(.horizontal, horizontalPadding)
            .padding(.vertical, verticalPadding)
            .modifier(GlassCapsuleModifier())
    }
}

struct GlassCircleButton<Label: View>: View {
    let size: CGFloat
    let tint: Color?
    let isEnabled: Bool
    let action: () -> Void
    let label: Label

    init(
        size: CGFloat = 40,
        tint: Color? = nil,
        isEnabled: Bool = true,
        action: @escaping () -> Void,
        @ViewBuilder label: () -> Label
    ) {
        self.size = size
        self.tint = tint
        self.isEnabled = isEnabled
        self.action = action
        self.label = label()
    }

    var body: some View {
        Button(action: action) {
            label
                .frame(width: size, height: size)
        }
        .buttonStyle(.plain)
        .foregroundStyle(foregroundStyle)
        .opacity(isEnabled ? 1 : 0.55)
        .modifier(GlassCircleModifier(tint: tint))
        .disabled(!isEnabled)
    }

    private var foregroundStyle: some ShapeStyle {
        if tint != nil {
            return AnyShapeStyle(.white)
        }
        return AnyShapeStyle(.primary)
    }
}

struct GlassPanel<Content: View>: View {
    let cornerRadius: CGFloat
    let content: Content

    init(cornerRadius: CGFloat = 24, @ViewBuilder content: () -> Content) {
        self.cornerRadius = cornerRadius
        self.content = content()
    }

    var body: some View {
        content
            .modifier(GlassRoundedRectModifier(cornerRadius: cornerRadius))
    }
}

private struct GlassCapsuleModifier: ViewModifier {
    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(Color.clear)
                .glassEffect(in: Capsule())
        } else {
            content
                .background(.ultraThinMaterial, in: Capsule())
                .overlay {
                    Capsule()
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.06), radius: 18, y: 8)
        }
    }
}

struct GlassCircleModifier: ViewModifier {
    let tint: Color?

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if let tint {
                content
                    .background(tint.opacity(0.9))
                    .glassEffect(in: Circle())
            } else {
                content
                    .background(Color.clear)
                    .glassEffect(in: Circle())
            }
        } else {
            content
                .background(backgroundStyle, in: Circle())
                .overlay {
                    Circle()
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.08), radius: 16, y: 8)
        }
    }

    private var backgroundStyle: AnyShapeStyle {
        if let tint {
            return AnyShapeStyle(tint)
        }
        return AnyShapeStyle(.ultraThinMaterial)
    }
}

private struct GlassRoundedRectModifier: ViewModifier {
    let cornerRadius: CGFloat

    @ViewBuilder
    func body(content: Content) -> some View {
        if #available(iOS 26.0, *) {
            content
                .background(Color.clear)
                .glassEffect(in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
        } else {
            content
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                        .strokeBorder(.white.opacity(0.22), lineWidth: 0.7)
                }
                .shadow(color: .black.opacity(0.08), radius: 22, y: 10)
        }
    }
}

#Preview {
    VStack(spacing: 20) {
        GlassCapsuleSurface {
            Text("Capsule Surface")
        }
        
        GlassCircleButton(size: 44, action: {}) {
            Image(systemName: "plus")
        }
        
        GlassPanel {
            Text("Glass Panel Content")
                .padding()
        }
    }
    .padding()
    .background(Color.cyan.opacity(0.2))
}
