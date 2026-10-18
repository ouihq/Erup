import AppIntents

struct ScooterShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: TurnOnLightIntent(),
            phrases: ["Turn on the scooter light with \(.applicationName)"],
            shortTitle: "Scooter light on",
            systemImageName: "headlight.high.beam.fill"
        )
        AppShortcut(
            intent: LockScooterIntent(),
            phrases: ["Lock the scooter with \(.applicationName)"],
            shortTitle: "Lock scooter",
            systemImageName: "lock.fill"
        )
        AppShortcut(
            intent: ScooterBatteryIntent(),
            phrases: ["Scooter battery in \(.applicationName)", "How full is the scooter in \(.applicationName)"],
            shortTitle: "Scooter battery",
            systemImageName: "battery.75percent"
        )
        AppShortcut(
            intent: SetGearIntent(gear: .eco),
            phrases: ["Set the scooter to eco with \(.applicationName)"],
            shortTitle: "Scooter to eco",
            systemImageName: "leaf.fill"
        )
    }
}
