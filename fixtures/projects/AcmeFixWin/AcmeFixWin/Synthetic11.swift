// Synthetic code for the xcblame fix fixture (compile-time weight only; never run).
import SwiftUI

protocol Metric11: Hashable {
    associatedtype Value: BinaryFloatingPoint & Hashable
    var samples: [Value] { get }
}

struct Series11<Value: BinaryFloatingPoint & Hashable>: Metric11 {
    var name: String
    var samples: [Value]

    var mean: Value { samples.isEmpty ? 0 : samples.reduce(0, +) / Value(samples.count) }
    var spread: Value { (samples.max() ?? 0) - (samples.min() ?? 0) }
    func scaled(by factor: Value) -> Series11 { Series11(name: name, samples: samples.map { $0 * factor + 1 }) }
}

enum Calc11 {
    static func value0(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 1.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 2) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value1(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 2.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 3) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value2(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 3.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 4) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value3(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 4.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 5) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value4(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 5.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 6) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value5(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 6.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 7) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value6(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 7.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 8) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value7(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 8.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 9) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value8(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 9.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 10) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value9(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 10.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 11) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value10(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 11.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 12) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

    static func value11(_ xs: [Double], _ k: Int) -> Double {
        let a = xs.enumerated().map { Double($0.offset) * 0.5 + $0.element * 12.25 }
        let b = a.filter { $0 > 1.5 }.map { ($0 * 2 - 1) / 3 }
        let c = Dictionary(grouping: b, by: { Int($0) % (k + 13) }).mapValues { $0.reduce(0, +) }
        return c.values.sorted().prefix(k + 3).reduce(0) { $0 + $1 * 0.75 - 0.125 } + Double(a.count)
    }

}

struct Card11x0: View {
    let series: [Series11<Double>]
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(series, id: \.name) { item in
                HStack(spacing: 8) {
                    Text(item.name).font(.headline).foregroundStyle(selected == item.name ? .primary : .secondary)
                    Spacer()
                    Text(String(format: "%.2f", item.mean * 1.5)).monospacedDigit()
                    Text(String(format: "%.1f", item.spread)).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(selected == item.name ? 0.2 : 0.05)))
                .onTapGesture { selected = selected == item.name ? nil : item.name }
            }
        }
        .padding()
    }
}

struct Card11x1: View {
    let series: [Series11<Double>]
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(series, id: \.name) { item in
                HStack(spacing: 8) {
                    Text(item.name).font(.headline).foregroundStyle(selected == item.name ? .primary : .secondary)
                    Spacer()
                    Text(String(format: "%.2f", item.mean * 2.5)).monospacedDigit()
                    Text(String(format: "%.1f", item.spread)).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(selected == item.name ? 0.2 : 0.05)))
                .onTapGesture { selected = selected == item.name ? nil : item.name }
            }
        }
        .padding()
    }
}

struct Card11x2: View {
    let series: [Series11<Double>]
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(series, id: \.name) { item in
                HStack(spacing: 8) {
                    Text(item.name).font(.headline).foregroundStyle(selected == item.name ? .primary : .secondary)
                    Spacer()
                    Text(String(format: "%.2f", item.mean * 3.5)).monospacedDigit()
                    Text(String(format: "%.1f", item.spread)).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(selected == item.name ? 0.2 : 0.05)))
                .onTapGesture { selected = selected == item.name ? nil : item.name }
            }
        }
        .padding()
    }
}

struct Card11x3: View {
    let series: [Series11<Double>]
    @State private var selected: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            ForEach(series, id: \.name) { item in
                HStack(spacing: 8) {
                    Text(item.name).font(.headline).foregroundStyle(selected == item.name ? .primary : .secondary)
                    Spacer()
                    Text(String(format: "%.2f", item.mean * 4.5)).monospacedDigit()
                    Text(String(format: "%.1f", item.spread)).font(.caption).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(RoundedRectangle(cornerRadius: 6).fill(Color.gray.opacity(selected == item.name ? 0.2 : 0.05)))
                .onTapGesture { selected = selected == item.name ? nil : item.name }
            }
        }
        .padding()
    }
}
