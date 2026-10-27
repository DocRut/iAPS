import AudioToolbox
import Foundation
import LoopKit
import SwiftUI
import Swinject
import UIKit
import UserNotifications

protocol UserNotificationsManager {}

enum GlucoseSourceKey: String {
    case transmitterBattery
    case nightscoutPing
    case description
}

enum NotificationAction: String {
    static let key = "action"

    case snooze
}

protocol BolusFailureObserver {
    func bolusDidFail()
}

protocol PumpNotificationObserver {
    func pumpNotification(alert: AlertEntry)
    func pumpRemoveNotification()
}

final class BaseUserNotificationsManager: NSObject, UserNotificationsManager, Injectable {
    private enum Identifier: String {
        case glucocoseNotification = "FreeAPS.glucoseNotification"
        case carbsRequiredNotification = "FreeAPS.carbsRequiredNotification"
        case noLoopFirstNotification = "FreeAPS.noLoopFirstNotification"
        case noLoopSecondNotification = "FreeAPS.noLoopSecondNotification"
        case bolusFailedNotification = "FreeAPS.bolusFailedNotification"
        case pumpNotification = "FreeAPS.pumpNotification"
    }

    @Injected() private var settingsManager: SettingsManager!
    @Injected() private var broadcaster: Broadcaster!
    @Injected() private var glucoseStorage: GlucoseStorage!
    @Injected() private var apsManager: APSManager!
    @Injected() private var deviceDataManager: DeviceDataManager!
    @Injected() private var router: Router!

    @Persisted(key: "UserNotificationsManager.snoozeUntilDate") private var snoozeUntilDate: Date = .distantPast

    private let center = UNUserNotificationCenter.current()
    private var lifetime = Lifetime()

    init(resolver: Resolver) {
        super.init()
        center.delegate = self
        injectServices(resolver)
        broadcaster.register(GlucoseObserver.self, observer: self)
        broadcaster.register(SuggestionObserver.self, observer: self)
        broadcaster.register(BolusFailureObserver.self, observer: self)
        broadcaster.register(PumpNotificationObserver.self, observer: self)

        requestNotificationPermissionsIfNeeded()
        sendGlucoseNotification()
        subscribeOnLoop()
    }

    private func subscribeOnLoop() {
        apsManager.lastLoopDateSubject
            .sink { [weak self] date in
                self?.scheduleMissingLoopNotifiactions(date: date)
            }
            .store(in: &lifetime)
    }

    private func addAppBadge(glucose: Int?) {
        guard let glucose = glucose, settingsManager.settings.glucoseBadge else {
            DispatchQueue.main.async {
                UIApplication.shared.applicationIconBadgeNumber = 0
            }
            return
        }

        let badge: Int
        if settingsManager.settings.units == .mmolL {
            badge = Int(round(Double((glucose * 10).asMmolL)))
        } else {
            badge = glucose
        }

        DispatchQueue.main.async {
            UIApplication.shared.applicationIconBadgeNumber = badge
        }
    }

    private func notifyCarbsRequired(_ carbs: Int) {
        guard settingsManager.settings.carbsRequiredAlert,
              Decimal(carbs) >= settingsManager.settings.carbsRequiredThreshold
        else { return
        }
        let sound = settingsManager.settings.carbSound

        ensureCanSendNotification {
            var titles: [String] = []

            let content = UNMutableNotificationContent()

            if self.snoozeUntilDate > Date() {
                titles.append(NSLocalizedString("(Snoozed)", comment: "(Snoozed)"))
            } else {
                if sound == "Default" {
                    if self.settingsManager.settings.useAlarmSound {
                        content.sound = .default
                    }
                } else if sound != "Silent" {
                    content.sound = self.notificationSound(for: sound)
                    self.playSoundIfNeeded(sound: sound)
                }
            }

            titles.append(String(format: NSLocalizedString("Carbs required: %d g", comment: "Carbs required"), carbs))

            content.title = titles.joined(separator: " ")
            content.body = String(
                format: NSLocalizedString(
                    "To prevent LOW required %d g of carbs",
                    comment: "To prevent LOW required %d g of carbs"
                ),
                carbs
            )

            self.addRequest(identifier: .carbsRequiredNotification, content: content, deleteOld: true)
        }
    }

    private func scheduleMissingLoopNotifiactions(date _: Date) {
        let sound = settingsManager.settings.missingLoopsSound
        ensureCanSendNotification {
            let title = NSLocalizedString("iAPS not active", comment: "iAPS not active")
            let body = NSLocalizedString("Last loop was more than %d min ago", comment: "Last loop was more than %d min ago")

            let firstInterval = 20 // min
            let secondInterval = 40 // min

            let firstContent = UNMutableNotificationContent()
            firstContent.title = title
            firstContent.body = String(format: body, firstInterval)

            let secondContent = UNMutableNotificationContent()
            secondContent.title = title
            secondContent.body = String(format: body, secondInterval)

            if let alertSound = self.notificationSound(for: sound) {
                firstContent.sound = alertSound
                secondContent.sound = alertSound
            }

            let firstTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 60 * TimeInterval(firstInterval), repeats: false)
            let secondTrigger = UNTimeIntervalNotificationTrigger(timeInterval: 60 * TimeInterval(secondInterval), repeats: false)

            self.addRequest(
                identifier: .noLoopFirstNotification,
                content: firstContent,
                deleteOld: true,
                trigger: firstTrigger
            )
            self.addRequest(
                identifier: .noLoopSecondNotification,
                content: secondContent,
                deleteOld: true,
                trigger: secondTrigger
            )
        }
    }

    private func notifyBolusFailure() {
        let sound = settingsManager.settings.bolusFailure
        ensureCanSendNotification {
            let title = NSLocalizedString("Bolus failed", comment: "Bolus failed")
            let body = NSLocalizedString(
                "Bolus failed or inaccurate. Check pump history before repeating.",
                comment: "Bolus failed or inaccurate. Check pump history before repeating."
            )

            let content = UNMutableNotificationContent()
            content.title = title
            content.body = body
            if sound == "Default" {
                if self.settingsManager.settings.useAlarmSound {
                    content.sound = .default
                }
            } else if sound != "Silent" {
                content.sound = self.notificationSound(for: sound)
                self.playSoundIfNeeded(sound: sound)
            }

            self.addRequest(
                identifier: .bolusFailedNotification,
                content: content,
                deleteOld: true
            )
        }
    }

    private func sendGlucoseNotification() {
        addAppBadge(glucose: nil)

        let glucose = glucoseStorage.retrieveRaw()
        guard let lastGlucose = glucose.last, let glucoseValue = lastGlucose.glucose else { return }

        addAppBadge(glucose: lastGlucose.glucose)

        guard glucoseStorage.alarm != nil || settingsManager.settings.glucoseNotificationsAlways else {
            return
        }

        ensureCanSendNotification {
            var titles: [String] = []
            var sound: String = "New/Anticipate.caf"
            var alert = true

            switch self.glucoseStorage.alarm {
            case .none:
                titles.append(NSLocalizedString("Glucose", comment: "Glucose"))
                sound = "Silent"
            case .low:
                titles.append(NSLocalizedString("LOWALERT!", comment: "LOWALERT!"))
                sound = self.settingsManager.settings.hypoSound
                alert = self.settingsManager.settings.lowAlert
            case .high:
                titles.append(NSLocalizedString("HIGHALERT!", comment: "HIGHALERT!"))
                sound = self.settingsManager.settings.hyperSound
                alert = self.settingsManager.settings.highAlert
            case .ascending:
                titles.append(NSLocalizedString("RAPIDLY ASCENDING GLUCOSE!", comment: "RAPIDLY ASCENDING GLUCOSE!"))
                sound = self.settingsManager.settings.ascending
                alert = self.settingsManager.settings.ascendingAlert
            case .descending:
                titles.append(NSLocalizedString("RAPIDLY DESCENDING GLUCOSE!", comment: "RAPIDLY DESCENDING GLUCOSE!"))
                sound = self.settingsManager.settings.descending
                alert = self.settingsManager.settings.descendingAlert
            }

            let delta = glucose.count >= 2 ? glucoseValue - (glucose[glucose.count - 2].glucose ?? 0) : nil
            let body = self.glucoseText(glucoseValue: glucoseValue, delta: delta, direction: lastGlucose.direction) + self
                .infoBody()

            if self.snoozeUntilDate > Date() {
                titles.append(NSLocalizedString("(Snoozed)", comment: "(Snoozed)"))
            } else if alert {
                let content = UNMutableNotificationContent()
                content.title = titles.joined(separator: " ")
                content.body = body

                if sound != "Silent", self.settingsManager.settings.useAlarmSound {
                    content.userInfo[NotificationAction.key] = NotificationAction.snooze.rawValue
                    if sound == "Default" {
                        content.sound = .default
                    } else {
                        content.sound = self.notificationSound(for: sound)
                        self.playSoundIfNeeded(sound: sound)
                    }
                }

                self.addRequest(identifier: .glucocoseNotification, content: content, deleteOld: true)
            }
        }
    }

    private func glucoseText(glucoseValue: Int, delta: Int?, direction: BloodGlucose.Direction?) -> String {
        let units = settingsManager.settings.units
        let glucoseText = glucoseFormatter
            .string(from: Double(
                units == .mmolL ? glucoseValue
                    .asMmolL : Decimal(glucoseValue)
            ) as NSNumber)! + " " + NSLocalizedString(units.rawValue, comment: "units")
        let directionText = direction?.symbol ?? "↔︎"
        let deltaText = delta
            .map {
                self.deltaFormatter
                    .string(from: Double(
                        units == .mmolL ? $0
                            .asMmolL : Decimal($0)
                    ) as NSNumber)!
            } ?? "--"

        return glucoseText + " " + directionText + " " + deltaText
    }

    private func infoBody() -> String {
        guard settingsManager.settings.addSourceInfoToGlucoseNotifications,
              let info = deviceDataManager.cgmInfo()
        else {
            return ""
        }

        var body = ""

        // Description
        if let description = info.description {
            body.append("\n" + description)
        }

        // Transmitter battery
        if let transmitterBattery = info.transmitterBattery {
            body.append(
                "\n"
                    + String(
                        format: NSLocalizedString("Transmitter: %@%%", comment: "Transmitter: %@%%"),
                        "\(transmitterBattery)"
                    )
            )
        }

        return body
    }

    private func requestNotificationPermissionsIfNeeded() {
        center.getNotificationSettings { settings in
            debug(.service, "UNUserNotificationCenter.authorizationStatus: \(String(describing: settings.authorizationStatus))")
            if ![.authorized, .provisional].contains(settings.authorizationStatus) {
                self.requestNotificationPermissions()
            }
        }
    }

    private func requestNotificationPermissions() {
        debug(.service, "requestNotificationPermissions")
        center.requestAuthorization(options: [.badge, .sound, .alert]) { granted, error in
            if granted {
                debug(.service, "requestNotificationPermissions was granted")
            } else {
                warning(.service, "requestNotificationPermissions failed", error: error)
            }
        }
    }

    private func ensureCanSendNotification(_ completion: @escaping () -> Void) {
        center.getNotificationSettings { settings in
            guard settings.authorizationStatus == .authorized || settings.authorizationStatus == .provisional else {
                warning(.service, "ensureCanSendNotification failed, authorization denied")
                return
            }

            debug(.service, "Sending notification was allowed")

            completion()
        }
    }

    private func addRequest(
        identifier: Identifier,
        content: UNMutableNotificationContent,
        deleteOld: Bool = false,
        trigger: UNNotificationTrigger? = nil
    ) {
        let request = UNNotificationRequest(identifier: identifier.rawValue, content: content, trigger: trigger)

        if deleteOld {
            DispatchQueue.main.async {
                self.center.removeDeliveredNotifications(withIdentifiers: [identifier.rawValue])
                self.center.removePendingNotificationRequests(withIdentifiers: [identifier.rawValue])
            }
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            self.center.add(request) { error in
                if let error = error {
                    warning(.service, "Unable to addNotificationRequest", error: error)
                    return
                }

                debug(.service, "Sending \(identifier) notification")
            }
        }
    }

    private func playSoundIfNeeded(sound: String) {
        guard settingsManager.settings.useAlarmSound, snoozeUntilDate < Date() else { return }
        guard sound != "Silent" else { return }
        startAlarm(sound: sound)
    }

    private func playSoundWithoutSnooze(_ sound: String) {
        guard settingsManager.settings.useAlarmSound else { return }
        guard sound != "Silent" else { return }
        startAlarm(sound: sound)
    }

    // MARK: - Тревожный звук

    /// Пауза между повторами, если звук короткий.
    private static let alarmGap: TimeInterval = 0.25
    /// Поколение тревоги: новая тревога или stopSound() отменяет предыдущий цикл.
    private static var alarmGeneration = 0
    /// Текущий SystemSoundID (0 — ничего не играет).
    private static var currentSoundID: SystemSoundID = 0
    private static var stopPlaying = false

    /// Запускает звук и повторяет его до stopSound() или новой тревоги.
    private func startAlarm(sound: String) {
        DispatchQueue.main.async {
            Self.alarmGeneration += 1
            let generation = Self.alarmGeneration
            Self.stopPlaying = false

            // Не даём новому звуку накладываться на предыдущий.
            if Self.currentSoundID != 0 {
                AudioServicesDisposeSystemSoundID(Self.currentSoundID)
                Self.currentSoundID = 0
            }

            self.playAlarm(sound: sound, generation: generation)
        }
    }

    private func playAlarm(sound: String, generation: Int) {
        guard !Self.stopPlaying, generation == Self.alarmGeneration else { return }

        let path = "/System/Library/Audio/UISounds/" + sound
        let soundURL = URL(fileURLWithPath: path)
        var id: SystemSoundID = 0
        guard AudioServicesCreateSystemSoundID(soundURL as CFURL, &id) == kAudioServicesNoError else {
            warning(.service, "Не удалось создать звук тревоги \(sound)")
            return
        }
        Self.currentSoundID = id

        AudioServicesPlaySystemSoundWithCompletion(id) {
            DispatchQueue.main.async {
                if Self.currentSoundID == id {
                    AudioServicesDisposeSystemSoundID(id)
                    Self.currentSoundID = 0
                }
                guard !Self.stopPlaying, generation == Self.alarmGeneration else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + Self.alarmGap) {
                    self.playAlarm(sound: sound, generation: generation)
                }
            }
        }
    }

    /// Останавливает тревожный звук. Вызывается при snooze, тапе по уведомлению
    /// и когда тревога снялась сама.
    static func stopSound() {
        DispatchQueue.main.async {
            stopPlaying = true
            alarmGeneration += 1
            if currentSoundID != 0 {
                AudioServicesDisposeSystemSoundID(currentSoundID)
                currentSoundID = 0
            }
        }
    }

    /// Готовит звук для UNNotificationContent.
    ///
    /// Системные звуки iOS лежат в /System/Library/Audio/UISounds, но iOS
    /// ищет пользовательский звук уведомления только в бандле приложения или
    /// в Library/Sounds его контейнера. Поэтому копируем выбранный системный
    /// звук в Library/Sounds и ссылаемся на копию по имени.
    private func notificationSound(for sound: String) -> UNNotificationSound? {
        guard sound != "Silent" else { return nil }
        if sound == "Default" { return .default }

        let source = URL(fileURLWithPath: "/System/Library/Audio/UISounds/" + sound)
        let fm = FileManager.default
        guard fm.fileExists(atPath: source.path),
              let library = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
        else { return .default }

        let directory = library.appendingPathComponent("Sounds", isDirectory: true)
        let name = "iaps_" + sound
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: " ", with: "_")
        let destination = directory.appendingPathComponent(name)

        if !fm.fileExists(atPath: destination.path) {
            do {
                try fm.createDirectory(at: directory, withIntermediateDirectories: true)
                try fm.copyItem(at: source, to: destination)
            } catch {
                warning(.service, "Не удалось подготовить звук уведомления \(sound)", error: error)
                return .default
            }
        }
        return UNNotificationSound(named: UNNotificationSoundName(name))
    }

    private var glucoseFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 0
        if settingsManager.settings.units == .mmolL {
            formatter.minimumFractionDigits = 1
            formatter.maximumFractionDigits = 1
        }
        formatter.roundingMode = .halfUp
        return formatter
    }

    private var deltaFormatter: NumberFormatter {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.maximumFractionDigits = 1
        formatter.positivePrefix = "+"
        return formatter
    }
}

extension BaseUserNotificationsManager: GlucoseObserver {
    func glucoseDidUpdate(_: [BloodGlucose]) {
        sendGlucoseNotification()
    }
}

extension BaseUserNotificationsManager: PumpNotificationObserver {
    func pumpNotification(alert: AlertEntry) {
        ensureCanSendNotification {
            let content = UNMutableNotificationContent()
            content.title = alert.contentTitle ?? "Unknown"
            content.body = alert.contentBody ?? "Unknown"
            content.sound = .default
            self.addRequest(
                identifier: .pumpNotification,
                content: content,
                deleteOld: true,
                trigger: nil
            )
        }
    }

    func pumpRemoveNotification() {
        let identifier: Identifier = .pumpNotification
        DispatchQueue.main.async {
            self.center.removeDeliveredNotifications(withIdentifiers: [identifier.rawValue])
            self.center.removePendingNotificationRequests(withIdentifiers: [identifier.rawValue])
        }
    }
}

extension BaseUserNotificationsManager: SuggestionObserver {
    func suggestionDidUpdate(_ suggestion: Suggestion) {
        guard let carndRequired = suggestion.carbsReq else { return }
        notifyCarbsRequired(Int(carndRequired))
    }
}

extension BaseUserNotificationsManager: BolusFailureObserver {
    func bolusDidFail() {
        notifyBolusFailure()
    }
}

extension BaseUserNotificationsManager: UNUserNotificationCenterDelegate {
    func userNotificationCenter(
        _: UNUserNotificationCenter,
        willPresent _: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
    ) {
        completionHandler([.banner, .badge, .sound])
    }

    func userNotificationCenter(
        _: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse,
        withCompletionHandler completionHandler: @escaping () -> Void
    ) {
        defer { completionHandler() }
        guard let actionRaw = response.notification.request.content.userInfo[NotificationAction.key] as? String,
              let action = NotificationAction(rawValue: actionRaw)
        else { return }

        switch action {
        case .snooze:
            // Пользователь подтвердил тревогу (тап по уведомлению) —
            // останавливаем звук, не дожидаясь кнопки в модальном окне.
            BaseUserNotificationsManager.stopSound()
            router.mainModalScreen.send(.snooze)
        }
    }
}
