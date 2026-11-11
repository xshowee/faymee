import SwiftUI

extension Binding {
    /// 把可选值绑定成 alert / confirmationDialog 的 isPresented：有值时显示，关掉时置空
    func isPresent<Wrapped>() -> Binding<Bool> where Value == Wrapped? {
        Binding<Bool>(get: { wrappedValue != nil }, set: { if !$0 { wrappedValue = nil } })
    }
}
