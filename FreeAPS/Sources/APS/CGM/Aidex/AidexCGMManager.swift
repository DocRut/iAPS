import Combine
import Foundation
import HealthKit
import LoopKit
import LoopKitUI
import UIKit
import UserNotifications

// MARK: - Сохраняемое состояние

public struct AidexCGMState: RawRepresentable, Equatable {
    public typealias RawValue = CGMManager.RawStateValue

    public var serialNumber: String = ""

    /// Мастер-ключ (java.cpp: keys[0]) — сохраняется, чтобы не проходить
    /// привязку askKey заново. Сессионный ключ не хранится: он новый на
    /// каждом подключении и расшифровывается мастер-ключом.
    public var masterKey: Data = .init()

    /// java.cpp: aidexXdat.hasTime
    public var hasTime: Bool = false

    /// java.cpp: getinfo()->starttime — базовое время, ставится один раз
    public var baseStart: Date?

    /// java.cpp: getinfo()->patchState — остаток в секундах
    public var secondsRemainder: Int = 0

    /// java.cpp: getinfo()->starthistory — сдвиг индексов в минутах
    public var indexShift: Int = 0

    /// Пояс, в котором записаны стеновые часы сенсора (секунды от UTC).
    /// Хранится, чтобы смена пояса телефона не сдвигала метки.
    public var sensorUTCOffsetSeconds: Int?

    /// Последний загруженный ID истории (абсолютный)
    public var lastReceivedID: Int = 0

    /// Срок жизни сенсора в днях (из deviceInfo)
    public var sensorLifeDays: Int = AidexBLE.defaultSensorLifetimeDays

    /// UUID конкретного BLE-устройства — для фонового переподключения
    /// без сканирования (retrievePeripherals).
    public var peripheralIdentifier: String?

    /// java.cpp: getRestartTime() — фактическое начало текущего цикла сенсора
    public var effectiveStart: Date? {
        guard let baseStart else { return nil }
        return baseStart.addingTimeInterval(
            Double(secondsRemainder) + Double(indexShift) * 60
        )
    }

    public init() {}

    public init(rawValue: RawValue) {
        serialNumber = rawValue["serialNumber"] as? String ?? ""
        masterKey = rawValue["masterKey"] as? Data ?? Data()
        hasTime = rawValue["hasTime"] as? Bool ?? false
        baseStart = rawValue["baseStart"] as? Date
        secondsRemainder = rawValue["secondsRemainder"] as? Int ?? 0
        indexShift = rawValue["indexShift"] as? Int ?? 0
        sensorUTCOffsetSeconds = rawValue["sensorUTCOffsetSeconds"] as? Int
        lastReceivedID = rawValue["lastReceivedID"] as? Int ?? 0
        sensorLifeDays = rawValue["sensorLifeDays"] as? Int ?? AidexBLE.defaultSensorLifetimeDays
        peripheralIdentifier = rawValue["peripheralIdentifier"] as? String
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "serialNumber": serialNumber,
            "masterKey": masterKey,
            "hasTime": hasTime,
            "secondsRemainder": secondsRemainder,
            "indexShift": indexShift,
            "lastReceivedID": lastReceivedID,
            "sensorLifeDays": sensorLifeDays
        ]
        if let baseStart { raw["baseStart"] = baseStart }
        if let sensorUTCOffsetSeconds { raw["sensorUTCOffsetSeconds"] = sensorUTCOffsetSeconds }
        if let peripheralIdentifier { raw["peripheralIdentifier"] = peripheralIdentifier }
        return raw
    }
}

// MARK: - Менеджер

public final class AidexCGMManager: CGMManager {
    public static let pluginIdentifier = "AidexCGM"

    public static let localizedTitle = NSLocalizedString(
        "Aidex / LumiFlex / LinX",
        comment: "Title for the Aidex CGM option"
    )

    public var localizedTitle: String { Self.localizedTitle }

    // MARK: Делегат LoopKit

    public let delegate = WeakSynchronizedDelegate<CGMManagerDelegate>()

    public var delegateQueue: DispatchQueue! {
        get { delegate.queue }
        set { delegate.queue = newValue }
    }

    public var cgmManagerDelegate: CGMManagerDelegate? {
        get { delegate.delegate }
        set { delegate.delegate = newValue }
    }

    // MARK: Состояние

    private let lockedState: Locked<AidexCGMState>

    public var state: AidexCGMState { lockedState.value }

    public var rawState: CGMManager.RawStateValue { state.rawValue }

    private func mutateState(_ change: (inout AidexCGMState) -> Void) {
        lockedState.mutate(change)
        delegate.notify { $0?.cgmManagerDidUpdateState(self) }
    }

    // MARK: Транспорт

    private let ble = AidexBLEManager()

    private var latestSample: AidexSample?
    private var sessionState: AidexBLEManager.SessionState = .idle
    private var deviceInfo: AidexDeviceInfo?

    /// Когда последний раз пришло новое показание (не дата сенсора, а
    /// момент прихода в приложение). Нужен для алярма «нет данных CGM»
    /// и восстановления после фона.
    private var lastSampleArrivalAt = Date()

    /// Уведомление «нет данных CGM» — страховка на случай, если приложение
    /// выгружено/зависло и обычный watchdog не успел сработать.
    private static let staleNotificationID = "FreeAPS.aidexCGMStale"
    private static let staleNotificationDelay: TimeInterval = 15 * 60
    private var foregroundObserver: NSObjectProtocol?

    /// Кольцевой буфер последних BLE-событий для показа в настройках.
    private(set) var logHistory: [String] = []

    // MARK: - Инициализация

    public init() {
        lockedState = Locked(AidexCGMState())
        ble.delegate = self
        observeForeground()
    }

    public required init?(rawState: RawStateValue) {
        lockedState = Locked(AidexCGMState(rawValue: rawState))
        ble.delegate = self
        observeForeground()
        restoreAndStart()
    }

    deinit {
        if let foregroundObserver {
            Foundation.NotificationCenter.default.removeObserver(foregroundObserver)
        }
    }

    private func observeForeground() {
        foregroundObserver = Foundation.NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.recoverAfterBackgroundIfNeeded()
        }
    }

    /// После возврата в приложение: если и данных, и показаний давно нет,
    /// делаем полный перезапуск BLE — то же, что закрыть/открыть приложение.
    private func recoverAfterBackgroundIfNeeded() {
        guard !state.serialNumber.isEmpty else { return }
        switch sessionState {
        case .failed,
             .running:
            break
        default:
            return
        }

        let noSample = Date().timeIntervalSince(lastSampleArrivalAt)
        let noData = Date().timeIntervalSince(ble.lastDataAt)
        guard noSample >= 10 * 60, noData >= 5 * 60 else { return }

        aidex(didLog: "приложение активно, данных нет \(Int(noSample / 60)) мин — полный перезапуск BLE")
        ble.restart()
    }

    /// Переставляет «мёртвый» алярм на 15 минут вперёд при каждом новом
    /// показании. Если показаний не будет, iOS покажет уведомление даже
    /// если приложение выгружено.
    private func scheduleStaleNotification() {
        let content = UNMutableNotificationContent()
        content.title = "Нет данных CGM"
        content.body = "Нет новых показаний глюкозы более 15 минут. Открой iAPS и проверь сенсор."
        content.sound = .default

        let request = UNNotificationRequest(
            identifier: Self.staleNotificationID,
            content: content,
            trigger: UNTimeIntervalNotificationTrigger(
                timeInterval: Self.staleNotificationDelay,
                repeats: false
            )
        )
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.staleNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.staleNotificationID])
        center.add(request)
    }

    private func cancelStaleNotification() {
        let center = UNUserNotificationCenter.current()
        center.removePendingNotificationRequests(withIdentifiers: [Self.staleNotificationID])
        center.removeDeliveredNotifications(withIdentifiers: [Self.staleNotificationID])
    }

    private func restoreAndStart() {
        let s = state
        guard !s.serialNumber.isEmpty else { return }
        ble.restore(
            masterKey: [UInt8](s.masterKey),
            hasTime: s.hasTime,
            baseStart: s.baseStart,
            secondsRemainder: s.secondsRemainder,
            indexShift: s.indexShift,
            lastReceivedID: s.lastReceivedID,
            peripheralIdentifier: s.peripheralIdentifier,
            utcOffsetSeconds: s.sensorUTCOffsetSeconds
        )
        ble.start(serialNumber: s.serialNumber)
    }

    // MARK: - Конфигурация

    public var serialNumber: String { state.serialNumber }

    /// Серийный номер — 10 символов с коробки сенсора.
    public func setSerialNumber(_ serial: String) {
        let normalized = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        let isDifferent = normalized != state.serialNumber

        mutateState {
            $0.serialNumber = normalized
            if isDifferent {
                // Новый сенсор — сбрасываем всё
                $0.masterKey = Data()
                $0.hasTime = false
                $0.baseStart = nil
                $0.secondsRemainder = 0
                $0.indexShift = 0
                $0.lastReceivedID = 0
                $0.sensorUTCOffsetSeconds = nil
            }
        }

        if normalized.isEmpty {
            ble.stop()
        } else {
            ble.start(serialNumber: normalized)
        }
    }

    public func disconnect() {
        ble.stop()
    }

    /// Ручное переподключение к сенсору (если соединение не восстановилось само).
    public func reconnect() {
        ble.reconnect()
    }

    /// Отвязать сенсор от телефона.
    public func unpairSensor() {
        ble.unpairSensor()
    }

    /// Команда Clear (0xF3): стирает с сенсора всю историю глюкозы,
    /// позволяя запустить его как новый. По документации Juggluco —
    /// только для тестов, показания после перезапуска недостоверны.
    public func clearSensor() {
        ble.clearSensor()
    }

    // MARK: - CGMManager

    /// ВАЖНО: должно быть всегда true.
    /// iAPS в cgmManagerOnboarding(didOnboardCGMManager:) делает
    /// precondition(cgmManager.isOnboarded) — при false приложение падает.
    /// Кроме того, CGMRootView показывает кнопку «CGM Configuration»
    /// только при isOnboarded == true, а без неё некуда ввести
    /// серийный номер. Образец: AppGroupCGM.isOnboarded { true }.
    public var isOnboarded: Bool { true }

    public var shouldSyncToRemoteService: Bool { true }

    /// Aidex шлёт нотификации сам — цикл iAPS будет просыпаться на приход глюкозы.
    public var providesBLEHeartbeat: Bool { true }

    public var managedDataInterval: TimeInterval? { nil }

    /// Дольше этого срока без свежего значения данные считаются устаревшими.
    private static let staleThreshold: TimeInterval = 15 * 60

    public var glucoseDisplay: GlucoseDisplayable? {
        guard let sample = latestSample else { return nil }
        let fresh = Date().timeIntervalSince(sample.date) < Self.staleThreshold
        return AidexGlucoseDisplay(sample: sample, isValid: sessionState == .running && fresh)
    }

    public var cgmManagerStatus: CGMManagerStatus {
        let fresh = latestSample.map { Date().timeIntervalSince($0.date) < Self.staleThreshold } ?? false
        return CGMManagerStatus(
            hasValidSensorSession: !state.serialNumber.isEmpty && sessionState == .running && fresh,
            device: device
        )
    }

    public var debugDescription: String {
        let s = state
        return """
        ## AidexCGMManager
        serial: \(s.serialNumber)
        session: \(sessionState)
        baseStart: \(s.baseStart.map(String.init(describing:)) ?? "-")
        effectiveStart: \(s.effectiveStart.map(String.init(describing:)) ?? "-")
        indexShift: \(s.indexShift) мин + \(s.secondsRemainder) с
        hasTime: \(s.hasTime)
        lastReceivedID: \(s.lastReceivedID)
        firmware: \(deviceInfo?.versionString ?? "-")
        latest: \(latestSample.map { "\($0.glucose) mg/dL @ \($0.date)" } ?? "-")
        """
    }

    /// Данные приходят push-нотификациями, опроса нет.
    public func fetchNewDataIfNeeded(_ completion: @escaping (CGMReadingResult) -> Void) {
        completion(.noData)
    }

    // MARK: Срок жизни сенсора

    /// Для отображения в iAPS (аналог KnownPlugins.cgmExpirationByPluginIdentifier).
    public var sensorExpiration: Date? {
        guard let start = state.effectiveStart else { return nil }
        return start.addingTimeInterval(Double(state.sensorLifeDays) * 86400)
    }

    /// Фактическое начало текущего цикла сенсора (java.cpp: getRestartTime)
    public var sensorStartDate: Date? { state.effectiveStart }

    private var device: HKDevice? {
        guard !state.serialNumber.isEmpty else { return nil }
        return HKDevice(
            name: "Aidex X",
            manufacturer: "MicroTech Medical",
            model: deviceInfo?.name ?? "Aidex X",
            hardwareVersion: nil,
            firmwareVersion: deviceInfo?.versionString,
            softwareVersion: nil,
            localIdentifier: state.serialNumber,
            udiDeviceIdentifier: nil
        )
    }

    /// Используется из AidexCGMManager+UI.swift — другой файл,
    /// поэтому не fileprivate.
    var currentSessionState: AidexBLEManager.SessionState { sessionState }
}

// MARK: - AlertResponder / AlertSoundVendor

public extension AidexCGMManager {
    func acknowledgeAlert(alertIdentifier _: Alert.AlertIdentifier, completion: @escaping (Error?) -> Void) {
        completion(nil)
    }

    func getSoundBaseURL() -> URL? { nil }
    func getSounds() -> [Alert.Sound] { [] }
}

// MARK: - AidexBLEManagerDelegate

extension AidexCGMManager: AidexBLEManagerDelegate {
    func aidex(didReceive samples: [AidexSample]) {
        guard !samples.isEmpty else { return }

        if let current = samples.first(where: { $0.isCurrent }) ?? samples.last {
            latestSample = current
        }

        lastSampleArrivalAt = Date()
        scheduleStaleNotification()

        // Сохраняем прогресс истории
        if let maxID = samples.map(\.id).max(), maxID > state.lastReceivedID {
            mutateState { $0.lastReceivedID = maxID }
        }

        let newSamples = samples.map { sample -> NewGlucoseSample in
            NewGlucoseSample(
                date: sample.date,
                quantity: HKQuantity(unit: .milligramsPerDeciliter, doubleValue: Double(sample.glucose)),
                condition: nil,
                trend: sample.rate.flatMap(GlucoseTrend.fromAidexRate),
                trendRate: sample.rate.map {
                    HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
                },
                isDisplayOnly: false,
                wasUserEntered: false,
                // Дедупликация по ID записи — устойчивее, чем по времени телефона
                syncIdentifier: "\(state.serialNumber)-\(sample.id)",
                device: device
            )
        }

        delegate.notify { $0?.cgmManager(self, hasNew: .newData(newSamples)) }
    }

    func aidex(didChangeState state: AidexBLEManager.SessionState) {
        sessionState = state

        // Сохраняем мастер-ключ, как только он появился
        if state == .running, !ble.masterKey.isEmpty,
           self.state.masterKey != Data(ble.masterKey)
        {
            mutateState {
                $0.masterKey = Data(ble.masterKey)
                $0.hasTime = ble.hasTime
            }
        }

        if state == .unpaired {
            mutateState {
                $0.masterKey = Data()
                $0.hasTime = false
                $0.baseStart = nil
                $0.secondsRemainder = 0
                $0.indexShift = 0
                $0.lastReceivedID = 0
                $0.sensorUTCOffsetSeconds = nil
            }
        }

        switch state {
        case .idle,
             .sensorEnded,
             .unpaired:
            cancelStaleNotification()
        default:
            break
        }

        delegate.notify { $0?.cgmManagerDidUpdateState(self) }
    }

    func aidex(didUpdateMasterKey key: [UInt8]) {
        // Сохраняем сразу, не дожидаясь .running: если сенсор сменил ключ
        // (перезапуск/перепривязка), неудачная попытка расшифровки не должна
        // оставить в хранилище старый ключ. Иначе при следующем запуске
        // приложения всё повторится по кругу.
        guard !key.isEmpty, state.masterKey != Data(key) else { return }
        mutateState { $0.masterKey = Data(key) }
        aidex(didLog: "Aidex: мастер-ключ сохранён (\(key.count) байт)")
    }

    func aidex(didUpdateTimeModel model: AidexTimeModel) {
        mutateState {
            $0.baseStart = model.baseStart
            $0.secondsRemainder = model.secondsRemainder
            $0.indexShift = model.indexShift
            $0.sensorUTCOffsetSeconds = model.utcOffsetSeconds
            $0.hasTime = true
        }
    }

    func aidex(didReceiveDeviceInfo info: AidexDeviceInfo) {
        deviceInfo = info
        if info.lifeDays > 0 {
            mutateState { $0.sensorLifeDays = Int(info.lifeDays) }
        }
    }

    func aidex(didUpdatePeripheralIdentifier id: String) {
        mutateState { $0.peripheralIdentifier = id }
    }

    func aidex(didLog message: String) {
        logHistory.append(message)
        if logHistory.count > 200 {
            logHistory.removeFirst(logHistory.count - 200)
        }
        debug(.deviceManager, message)
    }
}

// MARK: - Тренд

// java.cpp: rate2changeindex() — 5-уровневая шкала Abbott, мг/дл/мин.
//   rate <= -2.0 -> 1 (быстро вниз)
//   rate <= -1.0 -> 2 (вниз)
//   rate <=  1.0 -> 3 (ровно)
//   rate <=  2.0 -> 4 (вверх)
//   иначе        -> 5 (быстро вверх)
//
// LoopKit использует 7 уровней; крайние (upUpUp / downDownDown) в шкале
// Abbott отсутствуют, поэтому не используются.

extension GlucoseTrend {
    static func fromAidexRate(_ rate: Double) -> GlucoseTrend {
        switch rate {
        case ...(-2.0): return .downDown
        case ...(-1.0): return .down
        case ...1.0: return .flat
        case ...2.0: return .up
        default: return .upUp
        }
    }
}

// MARK: - GlucoseDisplayable

private struct AidexGlucoseDisplay: GlucoseDisplayable {
    let sample: AidexSample
    let isValid: Bool

    var isStateValid: Bool { isValid }

    var trendType: GlucoseTrend? {
        sample.rate.map(GlucoseTrend.fromAidexRate)
    }

    var trendRate: HKQuantity? {
        sample.rate.map {
            HKQuantity(unit: .milligramsPerDeciliterPerMinute, doubleValue: $0)
        }
    }

    var isLocal: Bool { true }
    var glucoseRangeCategory: GlucoseRangeCategory? { nil }
}

// MARK: - Единица скорости изменения

extension HKUnit {
    /// мг/дл/мин — используется LoopKit для trendRate.
    static let milligramsPerDeciliterPerMinute = HKUnit.milligramsPerDeciliter
        .unitDivided(by: .minute())
}
