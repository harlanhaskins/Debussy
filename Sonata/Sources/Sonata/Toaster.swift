//
//  Toaster.swift
//  Sonata
//

import Foundation
import SwiftUI

struct Toast: Identifiable {
    var id: UUID = UUID()
    var message: String
    var subtitle: String? = nil
    var image: Image? = nil
    var color: Color
    var textColor: Color

    static func error(
        _ error: String,
        subtitle: String? = nil,
        image: Image = Image(systemName: "multiply.circle.fill")
    ) -> Toast {
        Toast(message: error, subtitle: subtitle, image: image, color: .red, textColor: .white)
    }

    static func warning(
        _ warning: String,
        subtitle: String? = nil,
        image: Image = Image(systemName: "exclamationmark.triangle.fill")
    ) -> Toast {
        Toast(message: warning, subtitle: subtitle, image: image, color: .yellow, textColor: .white)
    }
}

@MainActor @Observable
private final class Breadbox {
    var toasts = [Toast]()

    func addToast(_ toast: Toast) {
        toasts.append(toast)
    }

    func dismissToast(_ id: UUID) {
        toasts.removeAll { $0.id == id }
    }
}

private enum PresentToastKey: EnvironmentKey {
    static let defaultValue: @MainActor (Toast) -> Void = { _ in }
}

extension EnvironmentValues {
    var presentToast: @MainActor (Toast) -> Void {
        get { self[PresentToastKey.self] }
        set { self[PresentToastKey.self] = newValue }
    }
}

extension View {
    func toaster() -> some View {
        modifier(ToasterModifier())
    }
}

struct ToasterModifier: ViewModifier {
    @State private var breadbox = Breadbox()

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottom) {
                VStack {
                    ForEach(breadbox.toasts.suffix(8)) { toast in
                        HStack {
                            toast.image?.font(.title2)
                            VStack(alignment: .leading) {
                                Text(toast.message)
                                    .font(.subheadline)
                                    .fontWeight(.medium)
                                if let subtitle = toast.subtitle {
                                    Text(subtitle)
                                        .font(.caption)
                                        .opacity(0.9)
                                }
                            }
                            .padding(.trailing, 12)
                        }
                        .foregroundStyle(toast.textColor)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 10)
                        .background(toast.color.gradient, in: Capsule())
                        .onTapGesture {
                            breadbox.dismissToast(toast.id)
                        }
                        .task {
                            try? await Task.sleep(for: .seconds(3))
                            breadbox.dismissToast(toast.id)
                        }
                        .transition(
                            .asymmetric(
                                insertion: .opacity.animation(.spring().delay(0.25)),
                                removal: .opacity.animation(.spring())))
                    }
                    .animation(.spring(), value: breadbox.toasts.count)
                }
                .padding(.bottom, 100) // Above the input bar
            }
            .environment(\.presentToast) {
                breadbox.addToast($0)
            }
    }
}
