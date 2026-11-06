import FanControl
import SwiftUI

struct FanAutoSwitchSection: View {
    @Bindable var switcher: FanAutoSwitcher

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Toggle("Switch profiles automatically", isOn: $switcher.enabled).font(.mhHeadline)
                Spacer()
                Menu("Add Rule") {
                    Button("When an App Is Running…") { switcher.addAppRule() }
                    Button("On Battery") { switcher.addPowerRule(battery: true) }
                    Button("On the Power Adapter") { switcher.addPowerRule(battery: false) }
                }
                .fixedSize()
            }
            Text("The first matching rule wins. When none matches, the setting you applied above is used.")
                .font(.mhCaption).foregroundStyle(Palette.textMuted)
            ForEach($switcher.rules) { $rule in
                HStack {
                    Image(systemName: switcher.activeRule?.id == rule.id ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(switcher.activeRule?.id == rule.id ? Theme.mint : Palette.textMuted)
                    Text(rule.trigger.title)
                    Spacer()
                    Picker("Profile", selection: $rule.target) {
                        ForEach(FanAutoRule.Target.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().frame(width: 140)
                    Button { switcher.rules.removeAll { $0.id == rule.id } } label: { Image(systemName: "minus.circle") }
                        .buttonStyle(.plain)
                }
                .font(.mhCallout)
                .opacity(switcher.enabled ? 1 : 0.5)
            }
            if let active = switcher.activeRule {
                Text("Now: \(active.target.title) (\(active.trigger.title))").font(.mhCaption).foregroundStyle(Theme.mint)
            }
            if let e = switcher.lastError { Text(e).font(.mhCaption).foregroundStyle(Theme.orange) }
        }
    }
}
