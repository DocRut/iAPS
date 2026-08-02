//
//  AidexCGMManager.swift
//  Адаптер драйвера Aidex под плагинную архитектуру iAPS 8.x (LoopKit CGMManager)
//
//  Шаблон: FreeAPS/Sources/APS/CGM/AppGroupCGM/AppGroupCGM.swift (iAPS v8.0.4)
//  Размещать в: FreeAPS/Sources/APS/CGM/Aidex/
//

import Combine
import Foundation
import HealthKit
import LoopKit
import LoopKitUI

// MARK: - Сохраняемое состояние

public struct AidexCGMState: RawRepresentable, Equatable {
    public typealias RawValue = CGMManager.RawStateValue

    public var serialNumber: String = ""

    /// Сессионный ключ — чтобы не запрашивать заново при каждом подключении.
    public var sessionKey: Data = .init()

    /// java.cpp: aidexXdat.hasTime
    public var hasTime: Bool = false

    /// java.cpp: getinfo()->starttime — базовое время, ставится один раз
    public var baseStart: Date?

    /// java.cpp: getinfo()->patchState — остаток в секундах
    public var secondsRemainder: Int = 0

    /// java.cpp: getinfo()->starthistory — сдвиг индексов в минутах
    public var indexShift: Int = 0

    /// Последний загруженный ID истории (абсолютный)
    public var lastReceivedID: Int = 0

    /// Срок жизни сенсора в днях (из deviceInfo)
    public var sensorLifeDays: Int = AidexBLE.defaultSensorLifetimeDays

    /// java.cpp: getRestartTime() — фактическое начало текущего цикла сенсора
    public var effectiveStart: Date? {
        guard let baseStart else { return nil }
        return baseStart.addingTimeInterval(
            Double(secondsRemainder) + Double(indexShift) * 60
        )
    }

    public init() {}

    public init(rawValue: RawValue) {
        serialNumber   = rawValue["serialNumber"] as? String ?? ""
        sessionKey     = rawValue["sessionKey"] as? Data ?? Data()
        hasTime        = rawValue["hasTime"] as? Bool ?? false
        baseStart        = rawValue["baseStart"] as? Date
        secondsRemainder = rawValue["secondsRemainder"] as? Int ?? 0
        indexShift       = rawValue["indexShift"] as? Int ?? 0
        lastReceivedID   = rawValue["lastReceivedID"] as? Int ?? 0
        sensorLifeDays = rawValue["sensorLifeDays"] as? Int ?? AidexBLE.defaultSensorLifetimeDays
    }

    public var rawValue: RawValue {
        var raw: RawValue = [
            "serialNumber": serialNumber,
            "sessionKey": sessionKey,
            "hasTime": hasTime,
            "secondsRemainder": secondsRemainder,
            "indexShift": indexShift,
            "lastReceivedID": lastReceivedID,
            "sensorLifeDays": sensorLifeDays
        ]
        if let baseStart { raw["baseStart"] = baseStart }
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

    // MARK: - Инициализация

    public init() {
        lockedState = Locked(AidexCGMState())
        ble.delegate = self
    }

    public required init?(rawState: RawStateValue) {
        lockedState = Locked(AidexCGMState(rawValue: rawState))
        ble.delegate = self
        restoreAndStart()
    }

    private func restoreAndStart() {
        let s = state
        guard !s.serialNumber.isEmpty else { return }
        ble.restore(
            sessionKey: [UInt8](s.sessionKey),
            hasTime: s.hasTime,
            baseStart: s.baseStart,
            secondsRemainder: s.secondsRemainder,
            indexShift: s.indexShift,
            lastReceivedID: s.lastReceivedID
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
                $0.sessionKey = Data()
                $0.hasTime = false
                $0.baseStart = nil
                $0.secondsRemainder = 0
                $0.indexShift = 0
                $0.lastReceivedID = 0
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

    public var glucoseDisplay: GlucoseDisplayable? {
        guard let sample = latestSample else { return nil }
        return AidexGlucoseDisplay(sample: sample, isValid: sessionState == .running)
    }

    public var cgmManagerStatus: CGMManagerStatus {
        CGMManagerStatus(
            hasValidSensorSession: !state.serialNumber.isEmpty && sessionState == .running,
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

        // Сохраняем сессионный ключ, как только он появился
        if state == .running, !ble.sessionKey.isEmpty,
           self.state.sessionKey != Data(ble.sessionKey)
        {
            mutateState {
                $0.sessionKey = Data(ble.sessionKey)
                $0.hasTime = ble.hasTime
            }
        }

        if state == .unpaired {
            mutateState {
                $0.sessionKey = Data()
                $0.hasTime = false
                $0.baseStart = nil
                $0.secondsRemainder = 0
                $0.indexShift = 0
                $0.lastReceivedID = 0
            }
        }

        delegate.notify { $0?.cgmManagerDidUpdateState(self) }
    }

    func aidex(didUpdateTimeModel model: AidexTimeModel) {
        mutateState {
            $0.baseStart = model.baseStart
            $0.secondsRemainder = model.secondsRemainder
            $0.indexShift = model.indexShift
            $0.hasTime = true
        }
    }

    func aidex(didReceiveDeviceInfo info: AidexDeviceInfo) {
        deviceInfo = info
        if info.lifeDays > 0 {
            mutateState { $0.sensorLifeDays = Int(info.lifeDays) }
        }
    }

    func aidex(didLog message: String) {
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
        case ...1.0:    return .flat
        case ...2.0:    return .up
        default:        return .upUp
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
