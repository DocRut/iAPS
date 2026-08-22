//
//  AidexBLEManager.swift
//  BLE-транспорт и полный конечный автомат сессии Aidex X / LumiFlex / LinX
//
//  Портировано с Juggluco (GPL-3.0):
//    AidexXGattCallback.java — последовательность подключения
//    java.cpp                — обмен ключами, диспетчер ответов, история
//

import CoreBluetooth
import Foundation

// MARK: - Результаты

/// Одно значение глюкозы с индексом записи.
/// id — минуты от старта сенсора (java.cpp: id2time = starttime + id*60).
struct AidexSample {
    let id: Int
    let glucose: Int          // мг/дл
    let rate: Double?         // мг/дл/мин, только для текущих значений
    let date: Date
    let isCurrent: Bool
}

/// Модель времени сенсора (java.cpp: starttime / patchState / starthistory).
/// Хранится целиком, потому что после перезапуска сенсора базовое время
/// НЕ меняется — меняются только сдвиги.
struct AidexTimeModel: Equatable {
    /// java.cpp: getinfo()->starttime — ставится один раз
    let baseStart: Date
    /// java.cpp: getinfo()->patchState — остаток в секундах
    let secondsRemainder: Int
    /// java.cpp: getinfo()->starthistory — сдвиг индексов в минутах
    let indexShift: Int

    /// java.cpp: getRestartTime()
    var effectiveStart: Date {
        baseStart.addingTimeInterval(
            Double(secondsRemainder) + Double(indexShift) * 60
        )
    }
}

protocol AidexBLEManagerDelegate: AnyObject {
    func aidex(didReceive samples: [AidexSample])
    func aidex(didChangeState state: AidexBLEManager.SessionState)
    func aidex(didUpdateTimeModel model: AidexTimeModel)
    func aidex(didReceiveDeviceInfo info: AidexDeviceInfo)
    func aidex(didUpdatePeripheralIdentifier id: String)
    func aidex(didLog message: String)
}

// MARK: - Менеджер

final class AidexBLEManager: NSObject {

    enum SessionState: Equatable {
        case idle
        case bluetoothUnavailable
        case scanning
        case connecting
        case discoveringServices
        case awaitingSessionKey
        case running
        case sensorEnded
        case unpaired
        case failed(String)
    }

    weak var delegate: AidexBLEManagerDelegate?

    private(set) var state: SessionState = .idle {
        didSet {
            guard state != oldValue else { return }
            log("состояние: \(state)")
            delegate?.aidex(didChangeState: state)
        }
    }

    // MARK: Сохраняемое между сессиями

    /// Мастер-ключ (java.cpp: keys[0]). Приходит НОТИФИКАЦИЕЙ на F001 после
    /// записи askKey, сохраняется между подключениями (aidexXSaveKey).
    /// Им расшифровывается сессионный ключ из F002.
    private(set) var masterKey: [UInt8] = []

    /// Сессионный ключ (java.cpp: keys[1]). НЕ сохраняется: при каждом
    /// подключении сенсор выдаёт новый, зашифрованный мастер-ключом,
    /// мы читаем его из F002 (aidexXstartCommand).
    private(set) var sessionKey: [UInt8] = []

    /// java.cpp: aidexXdat.hasTime
    private(set) var hasTime = false

    // MARK: Модель времени и индексов
    //
    // java.cpp хранит три величины и выводит из них всё остальное:
    //   getinfo()->starttime   — базовое время старта, ставится ОДИН раз
    //   getinfo()->patchState  — остаток в секундах  (addToStartTime())
    //   getinfo()->starthistory — сдвиг индексов в минутах (siAddedIndex)
    //
    //   getRestartTime() = starttime + patchState + starthistory*60
    //   id2time(id)      = starttime + patchState + id*60
    //   siAddedIndex(i)  = i + starthistory
    //   askHistory: relID = absID - starthistory
    //
    // Сенсор нумерует записи от СВОЕГО старта. После перезапуска сенсора
    // его нумерация обнуляется, а наша сквозная — нет; разницу держит
    // starthistory. Поэтому все приходящие ID нужно пропускать через
    // siAddedIndex, а в команду 0x23 отдавать обратно относительный.

    /// java.cpp: getinfo()->starttime — базовое время, ставится один раз
    private(set) var baseStart: Date?

    /// java.cpp: getinfo()->patchState — остаток в секундах
    private(set) var secondsRemainder = 0

    /// java.cpp: getinfo()->starthistory — сдвиг индексов в минутах
    private(set) var indexShift = 0

    /// java.cpp: lastLifeCountReceived — последний полученный ID (абсолютный)
    private var lastReceivedID = 0

    /// java.cpp: lastHistoricLifeCountReceivedPos — последний доступный на сенсоре (абсолютный)
    private var lastAvailableID = 0

    /// java.cpp: getRestartTime() — фактическое время старта текущего цикла
    var effectiveStart: Date? {
        guard let baseStart else { return nil }
        return baseStart.addingTimeInterval(
            Double(secondsRemainder) + Double(indexShift) * AidexBLE.recordInterval
        )
    }

    /// java.cpp: siAddedIndex() — из нумерации сенсора в сквозную
    private func absoluteID(_ reported: Int) -> Int { reported + indexShift }

    /// java.cpp: aidexXstream::time0
    private var time0 = 0

    // MARK: Приватное

    private var central: CBCentralManager?
    private var peripheral: CBPeripheral?

    private var charData: CBCharacteristic?
    private var charPrivateUnbonded: CBCharacteristic?
    private var charPrivateBonded: CBCharacteristic?

    private var serialNumber = ""
    private var iv: [UInt8] = []
    private var askKey: [UInt8] = []

    private var pendingUnpair = false
    private var pendingClear = false

    /// AidexXGattCallback: keywhenconnecting / java.cpp: aidexXstream::unbonded.
    /// true, если в ТЕКУЩЕМ подключении сессионный ключ запрашивался заново
    /// (не было сохранённого). Выставляется в didUpdateNotificationStateFor,
    /// используется в handleDeviceInfo — см. её комментарий.
    private var freshPairing = false

    /// Взведён в willRestoreState, снят при первом же centralManagerDidUpdateState.
    /// Нужен только чтобы не запускать beginScan() поверх уже идущего
    /// восстановленного подключения — сам peripheral никогда не обнуляется
    /// после дисконнекта (см. stop()/didDisconnectPeripheral), поэтому
    /// гейтить beginScan() по `peripheral == nil` было бы неверно: это
    /// заблокировало бы пересканирование навсегда после первого разрыва связи.
    private var restoredPeripheralPending = false

    /// java.cpp: writeChar(..., 20) — минимальный интервал между записями
    private static let writeGap: TimeInterval = 0.020
    private var lastWrite = Date.distantPast

    /// Интервал опроса истории в режиме ежеминутных показаний.
    private static let pollInterval: TimeInterval = 60

    /// Режим ежеминутных показаний: раз в минуту запрашиваем последний ID
    /// на сенсоре (askLastID), после чего существующая машинерия истории
    /// подтягивает новые поминутные записи.
    private(set) var minuteReadings = false

    /// Таймер опроса. Активен только когда minuteReadings == true.
    private var pollTimer: Timer?

    /// UUID конкретного CBPeripheral (сохраняется между запусками), чтобы
    /// переподключаться в фоне через retrievePeripherals, а не сканированием
    /// (сканирование в фоне не находит сенсор).
    private var peripheralIdentifier: String?

    // MARK: - Публичный интерфейс

    func setMinuteReadings(_ enabled: Bool) {
        minuteReadings = enabled
        schedulePolling()
    }

    /// Восстановление сессии между запусками приложения.
    func restore(masterKey key: [UInt8], hasTime time: Bool,
                 baseStart base: Date?, secondsRemainder seconds: Int,
                 indexShift shift: Int, lastReceivedID lastID: Int,
                 peripheralIdentifier identifier: String?)
    {
        masterKey = key
        hasTime = time
        baseStart = base
        secondsRemainder = seconds
        indexShift = shift
        lastReceivedID = lastID
        peripheralIdentifier = identifier
    }

    /// serial — полный серийный номер, 10 символов (напр. "222225C99G").
    func start(serialNumber serial: String) {
        let normalized = serial.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard !normalized.isEmpty else {
            state = .failed("пустой серийный номер")
            return
        }

        if normalized != serialNumber {
            // Новый сенсор — всё сбрасываем
            masterKey = []
            sessionKey = []
            hasTime = false
            baseStart = nil
            secondsRemainder = 0
            indexShift = 0
            lastReceivedID = 0
            lastAvailableID = 0
            peripheralIdentifier = nil
        }

        serialNumber = normalized
        iv = AidexCrypto.makeIV(serial: normalized)
        askKey = AidexCrypto.askKey(serial: normalized)

        log("старт, SN=\(normalized), мастер-ключ \(masterKey.isEmpty ? "отсутствует" : "сохранён")")

        if central == nil {
            // CBCentralManagerOptionRestoreIdentifierKey нужен, чтобы iOS
            // могла перезапустить приложение по Bluetooth-событию, если
            // процесс был выгружен из памяти в фоне. Без него BLE-транспорт
            // "тихо умирает" через несколько часов в фоне, даже если
            // providesBLEHeartbeat объявлен true. См. centralManager(_:willRestoreState:).
            central = CBCentralManager(
                delegate: self, queue: .main,
                options: [CBCentralManagerOptionRestoreIdentifierKey: Self.restoreIdentifier]
            )
        } else {
            reconnectOrScan()
        }
    }

    private static let restoreIdentifier = "com.iaps.aidex.centralManager"

    func stop() {
        if let p = peripheral { central?.cancelPeripheralConnection(p) }
        central?.stopScan()
        clearCharacteristics()
        pollTimer?.invalidate()
        pollTimer = nil
        state = .idle
    }

    /// Отвязать сенсор (java.cpp: unpaircmd). Ключ сохраняется.
    func unpairSensor() {
        guard !sessionKey.isEmpty else {
            log("unpair невозможен: нет сессионного ключа")
            return
        }
        pendingUnpair = true
        writeEncrypted(AidexCommand.unpair)
    }

    /// Clear (java.cpp: clearCMD, 0xF3) — стирает историю глюкозы
    /// на сенсоре, позволяя перезапустить его как новый.
    /// Ключ обнуляется, потребуется повторное подключение.
    func clearSensor() {
        guard !sessionKey.isEmpty else { return }
        pendingClear = true
        writeEncrypted(AidexCommand.clear)
    }

    // MARK: - Служебное

    private func clearCharacteristics() {
        charData = nil
        charPrivateUnbonded = nil
        charPrivateBonded = nil
    }

    private func log(_ message: String) {
        delegate?.aidex(didLog: "Aidex: \(message)")
    }

    private func beginScan() {
        guard central?.state == .poweredOn, !serialNumber.isEmpty else { return }
        state = .scanning
        central?.scanForPeripherals(withServices: [AidexBLE.service], options: nil)
    }

    /// Переподключение в фоне: сначала пробуем известный сенсор по UUID
    /// (retrievePeripherals + connect — работает в фоне), иначе сканируем.
    private func reconnectOrScan() {
        if !retrieveAndConnect() {
            beginScan()
        }
    }

    /// Переподключение к ранее сохранённому устройству по UUID.
    /// Возвращает true, если периферия найдена и подключение начато.
    @discardableResult
    private func retrieveAndConnect() -> Bool {
        guard let central, let id = peripheralIdentifier,
              let uuid = UUID(uuidString: id)
        else { return false }

        let known = central.retrievePeripherals(withIdentifiers: [uuid])
        guard let p = known.first else { return false }

        log("переподключение к известному сенсору \(id)")
        peripheral = p
        p.delegate = self
        state = .connecting
        central.connect(p, options: nil)
        return true
    }

    /// Запоминает UUID конкретной периферии, чтобы потом переподключаться
    /// без сканирования.
    private func rememberPeripheral(_ p: CBPeripheral) {
        let id = p.identifier.uuidString
        guard id != peripheralIdentifier else { return }
        peripheralIdentifier = id
        delegate?.aidex(didUpdatePeripheralIdentifier: id)
    }

    private func matches(name: String?) -> Bool {
        guard let name else { return false }
        // Сравниваем регистронезависимо целиком: и префикс, и серийник в
        // суффиксе. Раньше префикс сверялся точным регистром ("AiDEX X-"),
        // а суффикс — уже без учёта регистра; при другом реальном
        // написании имени по Bluetooth сканирование могло не найти сенсор.
        let upper = name.uppercased()
        guard AidexBLE.namePrefixes.contains(where: { upper.hasPrefix($0.uppercased()) }) else { return false }
        return upper.hasSuffix(serialNumber)
    }

    /// java.cpp: id2time() — starttime + patchState + id*60.
    /// id здесь АБСОЛЮТНЫЙ (уже после siAddedIndex).
    private func date(forID id: Int) -> Date {
        guard let baseStart else {
            // Без известного времени старта откатываемся на часы телефона
            return Date()
        }
        return baseStart.addingTimeInterval(
            Double(secondsRemainder) + Double(id) * AidexBLE.recordInterval
        )
    }

    // MARK: - Запись команд

    private func writeEncrypted(_ command: [UInt8]) {
        guard let charData, let peripheral, !sessionKey.isEmpty else { return }
        guard let encrypted = AidexCrypto.encrypt(command, key: sessionKey, iv: iv) else {
            log("ошибка шифрования команды")
            return
        }

        let elapsed = Date().timeIntervalSince(lastWrite)
        let doWrite = { [weak self] in
            guard let self else { return }
            self.lastWrite = Date()
            peripheral.writeValue(Data(encrypted), for: charData, type: .withoutResponse)
            self.log("-> F002 \(command.hexString)")
        }

        if elapsed < Self.writeGap {
            DispatchQueue.main.asyncAfter(deadline: .now() + (Self.writeGap - elapsed), execute: doWrite)
        } else {
            doWrite()
        }
    }

    // MARK: - Обмен ключами

    private func requestSessionKey() {
        guard let peripheral, let char = charPrivateUnbonded else { return }
        state = .awaitingSessionKey
        peripheral.writeValue(Data(askKey), for: char, type: .withResponse)
        log("-> F001 askKey")
    }

    /// java.cpp: aidexXstartCommand()
    /// Расшифровка сессионного ключа идёт МАСТЕР-КЛЮЧОМ (keys[0], полученным
    /// нотификацией на F001), а не askKey, который мы писали в F001.
    private func handleSessionKeyResponse(_ raw: [UInt8]) {
        guard !masterKey.isEmpty else {
            state = .failed("нет мастер-ключа для расшифровки сессионного ключа")
            return
        }
        guard raw.count == 17 else {
            state = .failed("ожидалось 17 байт ключа, получено \(raw.count)")
            return
        }
        guard let plain = AidexCrypto.decrypt(raw, key: masterKey, iv: iv), plain.count == 17 else {
            state = .failed("не удалось расшифровать сессионный ключ")
            return
        }

        let key = Array(plain[0 ..< 16])
        let expected = plain[16]
        let actual = AidexCRC.crc8Maxim(key)

        guard actual == expected else {
            state = .failed(String(format: "CRC8 ключа: %02X != %02X", actual, expected))
            return
        }

        sessionKey = key
        log("сессионный ключ принят")
        beginSession()
    }

    /// java.cpp: aidexXSaveKey() — мастер-ключ приходит нотификацией на F001.
    /// 16 байт. После сохранения читаем F002 (17 байт сессионного ключа).
    private func handleMasterKey(_ raw: [UInt8]) {
        guard raw.count == 16 else {
            state = .failed("ожидалось 16 байт мастер-ключа, получено \(raw.count)")
            return
        }
        masterKey = raw
        log("мастер-ключ принят")
        guard let charData else { return }
        peripheral?.readValue(for: charData)
    }

    /// Начало рабочей сессии — общая точка для нового и сохранённого ключа.
    private func beginSession() {
        state = .running

        if let peripheral, let f003 = charPrivateBonded {
            peripheral.setNotifyValue(true, for: f003)
        }

        // java.cpp: late = haskey && hasTime
        writeEncrypted(hasTime ? AidexCommand.startLate : AidexCommand.start)

        // Запускаем (или перезапускаем) опрос в режиме ежеминутных показаний.
        schedulePolling()
    }

    // MARK: Опрос для ежеминутных показаний

    private func schedulePolling() {
        pollTimer?.invalidate()
        pollTimer = nil
        guard minuteReadings else { return }

        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            self?.pollLatest()
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func pollLatest() {
        guard case .running = state, !sessionKey.isEmpty, charData != nil else { return }
        log("опрос: запрос последнего значения")
        writeEncrypted(AidexCommand.askLastID)
    }

    // MARK: - Диспетчер ответов F002
    // java.cpp: aidexXprocessHistoryData()

    private func handleDataNotification(_ raw: [UInt8]) {
        guard !sessionKey.isEmpty else { return }
        guard let plain = AidexCrypto.decrypt(raw, key: sessionKey, iv: iv), plain.count >= 4 else {
            log("F002: не удалось расшифровать")
            return
        }

        let body = Array(plain[0 ..< (plain.count - 2)])
        let expected = UInt16(plain[plain.count - 2]) | UInt16(plain[plain.count - 1]) << 8
        let actual = AidexCRC.crc16CCITTFalse(body)
        guard actual == expected else {
            log(String(format: "F002: CRC16 %04X != %04X", actual, expected))
            return
        }

        let code = UInt16(plain[0]) | UInt16(plain[1]) << 8
        guard let response = AidexResponse(rawValue: code) else {
            log(String(format: "F002: неизвестный код 0x%04X", code))
            return
        }

        switch response {
        case .deviceInfo:      handleDeviceInfo(body)
        case .onceOld:         handleOnceOld(body)
        case .needTime0, .needTime1:
            time0 = 2
            writeEncrypted(AidexCommand.askStartTime)
        case .localStartTime:  handleLocalStartTime(body)
        case .lastValue:       handleLastValue(body)
        case .pastValues:      handlePastValues(body)
        case .rawPastValues:   break   // java.cpp: возвращает sizeZero, ничего не делает
        case .wantTime:        writeEncrypted(AidexCommand.writeTime())
        case .need11:          writeEncrypted(AidexCommand.cmd11)
        case .need34:          writeEncrypted(AidexCommand.cmd34)
        case .unpairOK:
            log("сенсор отвязан")
            pendingUnpair = false
            state = .unpaired
            stop()
        case .unpairFail:
            log("отвязать не удалось")
            pendingUnpair = false
        case .clearOK:
            log("привязка сброшена")
            pendingClear = false
            // java.cpp: clearSuccessful() — clearKey() стирает только мастер-ключ
            masterKey = []
            sessionKey = []
            hasTime = false
            state = .unpaired
            stop()
        case .clearFail:
            log("сброс привязки не удался")
            pendingClear = false
        }
    }

    // MARK: Обработчики

    /// java.cpp: deviceInfo()
    private func handleDeviceInfo(_ body: [UInt8]) {
        if let info = AidexDeviceInfo(body) {
            log("прошивка \(info.versionString), срок \(info.lifeDays) дн, \(info.name)")
            delegate?.aidex(didReceiveDeviceInfo: info)
        }

        switch time0 {
        case 1:
            writeEncrypted(AidexCommand.requestWriteTime)
            return
        case 0:
            // java.cpp: hasTime && !stream->unbonded — "быстрый" старт
            // только на реконнекте с уже известным ключом, не на свежей
            // привязке (даже если hasTime почему-то уже true).
            if hasTime, !freshPairing {
                writeEncrypted(AidexCommand.startLate)
                return
            }
        default:
            break
        }
        writeEncrypted(AidexCommand.askStartTime)
    }

    /// java.cpp: onceOld() — одиночное историческое значение (LastPast).
    ///
    /// ИЗВЕСТНЫЙ ПРОБЕЛ: оригинал сверяет присланный id с sens->pollcount()
    /// (сколько записей уже реально сохранено в локальном буфере сенсора) и
    /// либо не сохраняет значение повторно, либо — если id заметно отстаёт
    /// от pollcount() — сбрасывает hasTime, требуя повторной синхронизации
    /// времени (защита от рассинхронизации после нештатной ситуации).
    /// pollcount() — свойство внутреннего буфера SensorGlucoseData, которому
    /// в этой архитектуре нет прямого аналога (тут нет истории "от нуля",
    /// только lastReceivedID/lastAvailableID), так что честно повторить эту
    /// проверку нельзя, не меняя модель хранения. Практическое следствие:
    /// дубли отфильтровываются позже, через syncIdentifier в LoopKit при
    /// сохранении в HealthKit, а не здесь; форсированный ресинк времени при
    /// рассинхронизации — не выполняется.
    private func handleOnceOld(_ body: [UInt8]) {
        guard let last = AidexLastPast(body, at: 2) else {
            log("onceOld: пакет короче \(AidexLastPast.length + 2)")
            return
        }

        // java.cpp:386 — siAddedIndex(preminfromstart)
        let id = absoluteID(Int(last.minutesFromStart))
        log("onceOld id=\(id) glucose=\(last.glucose)")

        if last.isPlausible, hasTime {
            delegate?.aidex(didReceive: [
                AidexSample(id: id, glucose: Int(last.glucose),
                            rate: last.rate, date: date(forID: id), isCurrent: false)
            ])
        }
        lastAvailableID = max(lastAvailableID, id)

        // java.cpp: if(!cur->minfromstart) — проверяется СЫРОЙ (несдвинутый)
        // индекс с сенсора, а не абсолютный id. После перезапуска сенсора
        // (indexShift != 0) эти два значения расходятся: абсолютный id==0
        // почти никогда не наступит, а сырой в этом месте протокола — наступает.
        if last.minutesFromStart == 0, hasTime { return }

        if !hasTime {
            writeEncrypted(AidexCommand.askStartTime)
        } else {
            requestNextHistoryIfNeeded()
        }
    }

    /// java.cpp: lastValue() — сообщает последний доступный ID на сенсоре.
    private func handleLastValue(_ body: [UInt8]) {
        // Проверка маркера: *(uint32*)(data+2) == 0x10001
        guard body.count >= 6 else { return }
        let mid = UInt32(body[2]) | UInt32(body[3]) << 8
            | UInt32(body[4]) << 16 | UInt32(body[5]) << 24
        guard mid == 0x0001_0001 else {
            log(String(format: "lastValue: маркер %08X != 00010001", mid))
            return
        }

        // lastOnSensor = *(uint16*)(data + len - 4)
        // len здесь — длина с CRC, у нас body уже без CRC => (len-4) == body.count-2
        guard body.count >= 2 else { return }
        let lastOnSensor = Int(UInt16(body[body.count - 2]) | UInt16(body[body.count - 1]) << 8)

        // java.cpp:446 — siAddedIndex(lastOnSensor)
        lastAvailableID = absoluteID(lastOnSensor)
        log("на сенсоре доступно до id=\(lastAvailableID) (сенсор говорит \(lastOnSensor)), получено до \(lastReceivedID)")
        requestNextHistoryIfNeeded()
    }

    /// java.cpp: getPastValues() — пачка исторических значений.
    /// Формат: [код 2][startID 2][HistoryGlucose × N по 2 байта]
    private func handlePastValues(_ body: [UInt8]) {
        guard body.count >= 4 else { return }
        let reportedStartID = Int(UInt16(body[2]) | UInt16(body[3]) << 8)
        // java.cpp:596 — siAddedIndex(startID)
        let startID = absoluteID(reportedStartID)

        // java.cpp: numhist = (len-6)/2, где len включает CRC.
        // body без CRC => numhist = (body.count - 4) / 2
        let count = (body.count - 4) / AidexHistoryGlucose.length
        guard count > 0 else { return }

        if startID <= lastReceivedID {
            log("getPastValues startID=\(startID) <= lastReceived=\(lastReceivedID), пропуск")
            // java.cpp: при startID==0 сбрасываем hasTime, иначе просто выходим
            if reportedStartID == 0 { hasTime = false }
            return
        }

        var samples: [AidexSample] = []
        var id = startID

        for i in 0 ..< count {
            let offset = 4 + i * AidexHistoryGlucose.length
            defer { id += 1 }
            guard let entry = AidexHistoryGlucose(body, at: offset) else { continue }
            guard entry.isPlausible else {
                log("история id=\(id) отброшена (valid=\(entry.valid) glucose=\(entry.glucose))")
                continue
            }
            samples.append(AidexSample(
                id: id, glucose: Int(entry.glucose),
                rate: nil, date: date(forID: id), isCurrent: false
            ))
        }

        lastReceivedID = id - 1
        log("получено \(samples.count) исторических значений, id \(startID)…\(lastReceivedID)")

        if !samples.isEmpty, hasTime {
            delegate?.aidex(didReceive: samples)
        }

        requestNextHistoryIfNeeded()
    }

    /// java.cpp: receiveLocalStarttime()
    ///
    /// ИЗВЕСТНЫЙ ПРОБЕЛ: оригинал (Android) в конце дополнительно проверяет
    /// `unbonded && bondednow` — если сейчас идёт первая привязка И только
    /// что завершился OS-уровневый BLE-bonding, ответ не отправляется,
    /// ждём следующего триггера. Это часть двухфазного bonding-автомата
    /// BluetoothGatt (AidexXGattCallback: onBondStateChanged/BOND_BONDED) —
    /// у CoreBluetooth такого явного колбэка о завершении OS bonding нет,
    /// шифрованные операции с характеристиками сами дожидаются его на
    /// уровне системы. Поэтому здесь этот guard сознательно не воспроизведён.
    private func handleLocalStartTime(_ body: [UInt8]) {
        guard let local = AidexLocalTime(body, at: 2) else {
            log("localStartTime: пакет короче \(AidexLocalTime.length + 2)")
            return
        }
        guard let newStart = local.date else {
            time0 = 1
            log("localStartTime: некорректная дата (\(local.debugDescription))")
            return
        }

        time0 = 0
        log("старт сенсора: \(local.debugDescription)")

        var isNewTime = false
        let currentEffective = effectiveStart

        if currentEffective != newStart {
            if baseStart == nil || lastReceivedID == 0 {
                // Первая привязка — ставим базу, сдвига нет
                baseStart = newStart
                secondsRemainder = 0
                indexShift = 0
                isNewTime = true
                log("базовое время старта установлено")
            } else if let base = baseStart, let effective = currentEffective,
                      effective < newStart
            {
                // java.cpp: сенсор перезапущен.
                // Разница считается от БАЗОВОГО времени, не от эффективного.
                let diff = Int(newStart.timeIntervalSince(base))
                let minutes = diff / 60
                let seconds = diff - minutes * 60
                secondsRemainder = seconds
                indexShift = minutes
                isNewTime = true
                log("перезапуск сенсора: сдвиг индексов \(minutes) мин + \(seconds) с")
            } else if let effective = currentEffective, effective > newStart {
                log("ОШИБКА: новое время старта \(newStart) раньше текущего \(effective), игнорируем")
                return
            }
        }

        hasTime = true
        notifyTimeModel()

        // java.cpp: if(newtime) startLate; else askLastID
        if isNewTime {
            writeEncrypted(AidexCommand.startLate)
        } else {
            writeEncrypted(AidexCommand.askLastID)
        }
    }

    private func notifyTimeModel() {
        guard let baseStart else { return }
        delegate?.aidex(didUpdateTimeModel: AidexTimeModel(
            baseStart: baseStart,
            secondsRemainder: secondsRemainder,
            indexShift: indexShift
        ))
    }

    /// java.cpp: whenPresent() / askHistory()
    ///   relID = startID - starthistory, но не меньше 1
    private func requestNextHistoryIfNeeded() {
        let next = lastReceivedID + 1
        guard next < lastAvailableID else {
            log("история загружена (следующий \(next), доступно до \(lastAvailableID))")
            return
        }
        let relative = max(1, next - indexShift)
        log("запрос истории с id=\(next) (rel=\(relative), сдвиг=\(indexShift))")
        writeEncrypted(AidexCommand.askHistory(relativeID: relative))
    }

    // MARK: - Текущая глюкоза (F003)
    // java.cpp: aidexXprocessCurrentData() -> saveCurrent()

    private func handleCurrentGlucose(_ raw: [UInt8]) {
        guard !sessionKey.isEmpty else { return }
        guard let plain = AidexCrypto.decrypt(raw, key: sessionKey, iv: iv), plain.count >= 4 else {
            return
        }

        let body = Array(plain[0 ..< (plain.count - 2)])
        let expected = UInt16(plain[plain.count - 2]) | UInt16(plain[plain.count - 1]) << 8
        guard AidexCRC.crc16CCITTFalse(body) == expected else {
            log("F003: CRC16 не сошёлся")
            return
        }

        // java.cpp: aidexXprocessCurrentData() обрабатывает ТОЛЬКО типы 1 и 3.
        // Тип 4 и прочие молча игнорируются.
        let packetType = body[0]
        guard packetType == 1 || packetType == 3 else {
            log("F003: тип \(packetType) не обрабатывается")
            return
        }

        guard let current = AidexCurrentGlucose(body) else {
            log("F003: длина \(body.count), ожидалось \(AidexCurrentGlucose.packetLength)")
            return
        }

        // java.cpp: saveCurrent() сохраняет значение ДО проверки на завершение
        // сенсора, поэтому последнее показание с пакета типа 3 не теряется.
        // Флаг обрабатываем после отправки значения — см. ниже.

        // java.cpp: saveGlucose() отказывается сохранять без известного времени
        guard hasTime else {
            log("F003: значение отброшено — время старта неизвестно")
            if current.sensorEnded {
                log("сенсор завершил работу")
                state = .sensorEnded
                stop()
            }
            return
        }

        guard current.isPlausible else {
            log("F003: отброшено (valid=\(current.valid) glucose=\(current.glucose))")
            return
        }

        // java.cpp:835 — siAddedIndex(cur->minfromstart)
        let id = absoluteID(Int(current.minutesFromStart))
        var timestamp = date(forID: id)

        // java.cpp: eventtime не должен быть в будущем более чем на 30 с
        let now = Date()
        if timestamp > now {
            guard timestamp.timeIntervalSince(now) <= 30 else {
                log("F003: метка времени в будущем (\(timestamp)), отброшено")
                return
            }
            timestamp = now
        }

        lastReceivedID = max(lastReceivedID, id)
        lastAvailableID = max(lastAvailableID, id)

        log("глюкоза \(current.glucose) мг/дл, \(String(format: "%.2f", current.rate)) мг/дл/мин, id=\(id)")

        delegate?.aidex(didReceive: [
            AidexSample(id: id, glucose: Int(current.glucose),
                        rate: current.rate, date: timestamp, isCurrent: true)
        ])

        // java.cpp: проверка data[0]==3 идёт ПОСЛЕ saveGlucose
        if current.sensorEnded {
            log("сенсор завершил работу")
            state = .sensorEnded
            stop()
        }
    }
}

// MARK: - CBCentralManagerDelegate

extension AidexBLEManager: CBCentralManagerDelegate {

    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            // willRestoreState (если был) успевает отработать раньше первого
            // вызова этого метода — не перебиваем восстановленное
            // подключение свежим сканированием.
            if restoredPeripheralPending {
                restoredPeripheralPending = false
            } else {
                reconnectOrScan()
            }
        case .poweredOff, .unauthorized, .unsupported:
            state = .bluetoothUnavailable
        default:
            break
        }
    }

    /// Вызывается системой при перезапуске процесса по Bluetooth-событию
    /// (см. CBCentralManagerOptionRestoreIdentifierKey в start()).
    /// Обязателен, если центральный менеджер создан с restoreIdentifier —
    /// иначе приложение падает.
    ///
    /// В отличие от AppGroupCGM (там достаточно пустой реализации — там BLE
    /// используется только как heartbeat-триггер), у Aidex сами данные идут
    /// через нотификации на восстановленном CBPeripheral, поэтому нужно
    /// заново привязать delegate и переоткрыть характеристики — после
    /// свежего запуска процесса charData/charPrivateUnbonded/charPrivateBonded
    /// в этом экземпляре ещё не заполнены.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String: Any]) {
        log("восстановление состояния Bluetooth после перезапуска процесса")
        guard let peripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral],
              let restored = peripherals.first
        else { return }

        restoredPeripheralPending = true
        peripheral = restored
        restored.delegate = self
        clearCharacteristics()

        switch restored.state {
        case .connected:
            state = .discoveringServices
            restored.discoverServices([AidexBLE.service])
        default:
            // Отключено/отключается/подключается — по рекомендации Apple
            // явно переподключаем именно этот CBPeripheral: центральный
            // менеджер уже знает конкретное устройство, пересканировать эфир
            // не нужно (и beginScan() пока не сработает — см. restoredPeripheralPending).
            state = .connecting
            central.connect(restored, options: nil)
        }
    }

    func centralManager(
        _ central: CBCentralManager,
        didDiscover peripheral: CBPeripheral,
        advertisementData: [String: Any],
        rssi RSSI: NSNumber
    ) {
        let advName = advertisementData[CBAdvertisementDataLocalNameKey] as? String
        guard matches(name: peripheral.name) || matches(name: advName) else { return }

        // Попутно можно вытащить глюкозу прямо из рекламы (пассивный канал)
        if let mfg = advertisementData[CBAdvertisementDataManufacturerDataKey] as? Data {
            parseAdvertisement([UInt8](mfg))
        }

        log("найден \(peripheral.name ?? advName ?? "?") RSSI=\(RSSI)")
        central.stopScan()

        self.peripheral = peripheral
        peripheral.delegate = self
        rememberPeripheral(peripheral)
        state = .connecting
        central.connect(peripheral, options: nil)
    }

    /// Пассивный разбор рекламы. Полезен, если подключение ещё не установлено.
    private func parseAdvertisement(_ raw: [UInt8]) {
        guard hasTime, let parsed = AidexAdvertisement.parse(raw) else { return }
        guard parsed.last.isPlausible else { return }

        var samples: [AidexSample] = []
        // java.cpp:198 — siAddedIndex(preid)
        let id = absoluteID(Int(parsed.last.minutesFromStart))
        samples.append(AidexSample(
            id: id, glucose: Int(parsed.last.glucose),
            rate: parsed.last.rate, date: date(forID: id), isCurrent: true
        ))
        // java.cpp: savepast(sens, --iditer, ...) — идут от уже сдвинутого id
        for (prevReportedID, glucose) in parsed.previous {
            let prevID = absoluteID(prevReportedID)
            samples.append(AidexSample(
                id: prevID, glucose: glucose,
                rate: nil, date: date(forID: prevID), isCurrent: false
            ))
        }
        log("реклама: \(samples.count) значений, последнее \(parsed.last.glucose) мг/дл")
        delegate?.aidex(didReceive: samples)
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        rememberPeripheral(peripheral)
        state = .discoveringServices
        peripheral.discoverServices([AidexBLE.service])
    }

    func centralManager(
        _ central: CBCentralManager,
        didFailToConnect peripheral: CBPeripheral,
        error: Error?
    ) {
        log("подключение не удалось: \(error?.localizedDescription ?? "-")")
        reconnectOrScan()
    }

    func centralManager(
        _ central: CBCentralManager,
        didDisconnectPeripheral peripheral: CBPeripheral,
        error: Error?
    ) {
        log("отключено: \(error?.localizedDescription ?? "штатно")")
        clearCharacteristics()
        switch state {
        case .idle, .sensorEnded, .unpaired:
            break
        default:
            reconnectOrScan()
        }
    }
}

// MARK: - CBPeripheralDelegate

extension AidexBLEManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil,
              let service = peripheral.services?.first(where: { $0.uuid == AidexBLE.service })
        else {
            state = .failed("сервис 181F не найден")
            return
        }
        peripheral.discoverCharacteristics(
            [AidexBLE.charData, AidexBLE.charPrivateUnbonded, AidexBLE.charPrivateBonded],
            for: service
        )
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didDiscoverCharacteristicsFor service: CBService,
        error: Error?
    ) {
        guard error == nil else {
            state = .failed("ошибка обнаружения характеристик")
            return
        }

        for char in service.characteristics ?? [] {
            switch char.uuid {
            case AidexBLE.charData:            charData = char
            case AidexBLE.charPrivateUnbonded: charPrivateUnbonded = char
            case AidexBLE.charPrivateBonded:   charPrivateBonded = char
            default: break
            }
        }

        guard charData != nil, charPrivateUnbonded != nil, charPrivateBonded != nil else {
            state = .failed("не все характеристики найдены")
            return
        }

        // AidexXGattCallback.discover(): при наличии ключа сразу F003, иначе F001.
        // На iOS порядок другой: сперва включаем нотификации F002 —
        // это общий канал и для ключа, и для данных.
        peripheral.setNotifyValue(true, for: charData!)
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateNotificationStateFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil else {
            log("нотификации \(characteristic.uuid) не включились: \(error!.localizedDescription)")
            return
        }

        switch characteristic.uuid {
        case AidexBLE.charData:
            // F002 — общий канал (и ключ, и данные). После включения нотификаций
            // решаем, что дальше. AidexXGattCallback: keywhenconnecting.
            if masterKey.isEmpty {
                // Новая привязка: включаем нотификации F001, откуда придёт
                // мастер-ключ, и только потом пишем askKey.
                freshPairing = true
                log("новая привязка — включаем нотификации F001")
                guard let charPrivateUnbonded else { return }
                peripheral.setNotifyValue(true, for: charPrivateUnbonded)
            } else {
                // Мастер-ключ сохранён: сразу читаем новый сессионный ключ из F002.
                freshPairing = false
                log("используем сохранённый мастер-ключ, читаем F002")
                guard let charData else { return }
                peripheral.readValue(for: charData)
            }
        case AidexBLE.charPrivateUnbonded:
            // Нотификации F001 включены — отправляем askKey.
            requestSessionKey()
        default:
            break
        }
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didWriteValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        if let error {
            log("ошибка записи \(characteristic.uuid): \(error.localizedDescription)")
            return
        }
        // После записи askKey ничего не делаем: ждём нотификацию F001
        // (мастер-ключ), она же инициирует чтение F002. См. handleMasterKey().
    }

    func peripheral(
        _ peripheral: CBPeripheral,
        didUpdateValueFor characteristic: CBCharacteristic,
        error: Error?
    ) {
        guard error == nil, let value = characteristic.value else { return }
        let raw = [UInt8](value)

        switch characteristic.uuid {
        case AidexBLE.charData:
            if sessionKey.isEmpty {
                handleSessionKeyResponse(raw)
            } else {
                handleDataNotification(raw)
            }
        case AidexBLE.charPrivateUnbonded:
            handleMasterKey(raw)
        case AidexBLE.charPrivateBonded:
            handleCurrentGlucose(raw)
        default:
            break
        }
    }
}

// MARK: - Утилиты

extension Array where Element == UInt8 {
    var hexString: String {
        map { String(format: "%02X", $0) }.joined(separator: " ")
    }
}
