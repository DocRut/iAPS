import CoreBluetooth
import Foundation

// MARK: - BLE идентификаторы

// AidexXGattCallback.java, строки 177–190

enum AidexBLE {
    static let service = CBUUID(string: "0000181F-0000-1000-8000-00805F9B34FB")

    /// F002 — основной канал: зашифрованные команды и ответы.
    static let charData = CBUUID(string: "0000F002-0000-1000-8000-00805F9B34FB")

    /// F001 — "private unbonded": запись askKey для получения сессионного ключа.
    static let charPrivateUnbonded = CBUUID(string: "0000F001-0000-1000-8000-00805F9B34FB")

    /// F003 — "private bonded": нотификации с текущей глюкозой.
    static let charPrivateBonded = CBUUID(string: "0000F003-0000-1000-8000-00805F9B34FB")

    /// Префиксы имён устройств (java.cpp: getMicroType).
    /// У Juggluco: LinX → "LinX_L", LumiFlex → "FlLumi", остальное — Aidex X.
    /// Сравнение регистронезависимое; старые варианты с дефисом оставлены,
    /// чтобы не потерять уже работающие сенсоры.
    static let namePrefixes = ["AiDEX X-", "LinX_L", "LinX-", "FlLumi", "LumiFlex-"]

    /// java.cpp: aidexXlowest / aidexXhighest, мг/дл
    static let glucoseLowest = 18
    static let glucoseHighest = 800

    /// java.cpp: validGlucose()
    static func isValidGlucose(_ mgdl: Int) -> Bool {
        mgdl >= glucoseLowest && mgdl <= glucoseHighest
    }

    /// java.cpp: id2time() — starttime + id*60.
    /// Записи истории идут с шагом в ОДНУ минуту.
    static let recordInterval: TimeInterval = 60

    /// java.cpp: AidexTrend2RateOfChange() — trend*.1f
    /// Поле trend хранит скорость в десятых долях мг/дл/мин.
    static func trendToRate(_ trend: Int8) -> Double {
        Double(trend) * 0.1
    }

    /// Срок жизни сенсора по умолчанию (README Juggluco: 15 дней).
    /// Фактическое значение приходит в deviceInfo (поле days).
    static let defaultSensorLifetimeDays = 15
}

// MARK: - Команды

// java.cpp. Все команды содержат CRC16 в хвосте и шифруются сессионным ключом.

enum AidexCommand {
    /// Первичная команда после получения сессионного ключа.
    static let start: [UInt8] = [0x10, 0xC1, 0xF3]

    /// Вариант start, когда время сенсора уже известно (java.cpp: late).
    static let startLate: [UInt8] = [0x35, 0x01, 0x4E, 0xF7]

    /// Ответ на 0x0020 / 0x0120 — запрос локального времени старта.
    static let askStartTime: [UInt8] = [0x21, 0xB3, 0xD5]

    /// java.cpp: askLastID() — запрос последнего доступного ID на сенсоре.
    static let askLastID: [UInt8] = [0x22, 0xD0, 0xE5]

    /// Ответ на 0x0134.
    static let cmd11: [UInt8] = [0x11, 0xE0, 0xE3]

    /// Ответ на 0x0135.
    static let cmd34: [UInt8] = [0x34, 0x01, 0x7F, 0xC4]

    /// deviceInfo при time0 == 1 — запрос записи времени.
    static let requestWriteTime: [UInt8] = [0x31, 0x01, 0x8A, 0x3B]

    /// Отвязать сенсор от устройства.
    static let unpair: [UInt8] = [0xF2, 0xAD, 0x2E]

    /// Полный сброс привязки (java.cpp: clearCMD).
    static let clear: [UInt8] = [0xF3, 0x8C, 0x3E]

    /// java.cpp: makeByteShort() — [cmd][arg lo][arg hi][crc16 lo][crc16 hi]
    static func byteShort(_ cmd: UInt8, _ arg: UInt16) -> [UInt8] {
        let body: [UInt8] = [cmd, UInt8(arg & 0xFF), UInt8(arg >> 8)]
        return AidexCRC.appendCRC16(body)
    }

    /// java.cpp: askHistory() — запрос истории начиная с относительного ID.
    /// relID = startID - starthistory, но не меньше 1.
    static func askHistory(relativeID: Int) -> [UInt8] {
        let rel = UInt16(max(1, relativeID))
        return byteShort(0x23, rel)
    }

    /// java.cpp: askRawHistory()
    static func askRawHistory(relativeID: Int) -> [UInt8] {
        byteShort(0x24, UInt16(max(1, relativeID)))
    }

    /// java.cpp: writeTime() — [0x20][LocalStartTime 9 байт][crc16]
    static func writeTime(_ date: Date = Date()) -> [UInt8] {
        let body: [UInt8] = [0x20] + AidexLocalTime(date: date).bytes
        return AidexCRC.appendCRC16(body)
    }
}

/// Коды ответов в первых двух байтах расшифрованного пакета F002
/// (java.cpp: switch(short1), little-endian uint16).
enum AidexResponse: UInt16 {
    case deviceInfo = 0x0110
    case onceOld = 0x0111
    case needTime0 = 0x0020
    case needTime1 = 0x0120
    case localStartTime = 0x0121
    case lastValue = 0x0122
    case pastValues = 0x0123
    case rawPastValues = 0x0124
    case wantTime = 0x0131
    case need11 = 0x0134
    case need34 = 0x0135
    case unpairOK = 0x01F2
    case unpairFail = 0x00F2
    case clearOK = 0x01F3
    case clearFail = 0x00F3
}

// MARK: - Текущая глюкоза

// glucose.h: CurrentGlucose — 15 байт, приходит по F003.

struct AidexCurrentGlucose {
    let type: UInt8 // байт 0; == 3 означает "сенсор завершён"
    let trend: Int8
    let minutesFromStart: UInt16
    let glucose: UInt16 // мг/дл
    let warmup: Bool
    let valid: Bool

    /// java.cpp: saveCurrent() требует ровно 15 байт
    static let packetLength = 15

    init?(_ b: [UInt8]) {
        guard b.count == Self.packetLength else { return nil }
        type = b[0]
        trend = Int8(bitPattern: b[3])
        minutesFromStart = UInt16(b[4]) | UInt16(b[5]) << 8
        let packed = UInt16(b[6]) | UInt16(b[7]) << 8
        glucose = packed & 0x03FF // биты 0..9
        warmup = (packed & 0x0400) != 0 // бит 10
        valid = (packed & 0x8000) != 0 // бит 15
    }

    var sensorEnded: Bool { type == 3 }

    /// java.cpp: saveGlucose() — valid && mgdL < 1023 && validGlucose()
    var isPlausible: Bool {
        valid && glucose < 1023 && AidexBLE.isValidGlucose(Int(glucose))
    }

    /// мг/дл/мин
    var rate: Double { AidexBLE.trendToRate(trend) }
}

// MARK: - Историческое значение

// glucose.h: HistoryGlucose — 2 байта, битовые поля.

struct AidexHistoryGlucose {
    let glucose: UInt16
    let warmup: Bool
    let valid: Bool

    static let length = 2

    init?(_ b: [UInt8], at o: Int) {
        guard b.count >= o + Self.length else { return nil }
        let packed = UInt16(b[o]) | UInt16(b[o + 1]) << 8
        glucose = packed & 0x03FF
        warmup = (packed & 0x0400) != 0
        valid = (packed & 0x8000) != 0
    }

    /// java.cpp: savepast() — valid && validGlucose()
    var isPlausible: Bool {
        valid && AidexBLE.isValidGlucose(Int(glucose))
    }
}

// MARK: - LastPast

// glucose.h: LastPast — 8 байт. Приходит в onceOld и в рекламных пакетах.

struct AidexLastPast {
    let minutesFromStart: UInt16
    let status: UInt8
    let calTemp: UInt8
    let trend: Int8
    let glucose: UInt16
    let valid: Bool
    let quality: UInt8

    static let length = 8

    init?(_ b: [UInt8], at o: Int = 0) {
        guard b.count >= o + Self.length else { return nil }
        minutesFromStart = UInt16(b[o]) | UInt16(b[o + 1]) << 8
        status = b[o + 2]
        calTemp = b[o + 3]
        trend = Int8(bitPattern: b[o + 4])
        let packed = UInt16(b[o + 5]) | UInt16(b[o + 6]) << 8
        glucose = packed & 0x03FF
        valid = (packed & 0x8000) != 0
        quality = b[o + 7]
    }

    var isPlausible: Bool {
        valid && AidexBLE.isValidGlucose(Int(glucose))
    }

    var rate: Double { AidexBLE.trendToRate(trend) }
}

// MARK: - NextGlucose

// glucose.h: NextGlucose — 3 байта. Два предыдущих значения в рекламе.

struct AidexNextGlucose {
    let glucose: UInt16
    let valid: Bool
    let quality: UInt8

    static let length = 3

    init?(_ b: [UInt8], at o: Int) {
        guard b.count >= o + Self.length else { return nil }
        let packed = UInt16(b[o]) | UInt16(b[o + 1]) << 8
        glucose = packed & 0x03FF
        valid = (packed & 0x8000) != 0
        quality = b[o + 2]
    }

    var isPlausible: Bool {
        valid && AidexBLE.isValidGlucose(Int(glucose))
    }
}

// MARK: - Локальное время старта сенсора

// java.cpp: struct LocalStartTime — 9 байт, packed.

struct AidexLocalTime {
    let year: UInt16
    let month: UInt8
    let day: UInt8
    let hour: UInt8
    let minute: UInt8
    let second: UInt8
    /// Смещение часового пояса в четвертях часа (БЕЗ учёта летнего времени)
    let timeZoneQuarterHours: Int8
    /// Смещение летнего времени в четвертях часа
    let dstOffsetQuarterHours: UInt8

    static let length = 9

    // MARK: Разбор ответа сенсора

    init?(_ b: [UInt8], at o: Int = 0) {
        guard b.count >= o + Self.length else { return nil }
        year = UInt16(b[o]) | UInt16(b[o + 1]) << 8
        month = b[o + 2]
        day = b[o + 3]
        hour = b[o + 4]
        minute = b[o + 5]
        second = b[o + 6]
        timeZoneQuarterHours = Int8(bitPattern: b[o + 7])
        dstOffsetQuarterHours = b[o + 8]
    }

    // MARK: Формирование для записи в сенсор

    // java.cpp: from_t_time() — использует ЛОКАЛЬНОЕ время устройства.

    init(date: Date) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone.current
        let c = calendar.dateComponents(
            [.year, .month, .day, .hour, .minute, .second], from: date
        )
        year = UInt16(c.year ?? 2000)
        month = UInt8(c.month ?? 1)
        day = UInt8(c.day ?? 1)
        hour = UInt8(c.hour ?? 0)
        minute = UInt8(c.minute ?? 0)
        second = UInt8(c.second ?? 0)

        let tz = TimeZone.current
        let isDST = tz.isDaylightSavingTime(for: date)
        let dstQuarters = isDST ? 4 : 0
        dstOffsetQuarterHours = UInt8(dstQuarters)
        // java.cpp: tm_gmtoff / (60*15) - dstOffsetQuarterHours
        let totalQuarters = tz.secondsFromGMT(for: date) / (60 * 15)
        timeZoneQuarterHours = Int8(clamping: totalQuarters - dstQuarters)
    }

    var bytes: [UInt8] {
        [
            UInt8(year & 0xFF), UInt8(year >> 8),
            month, day, hour, minute, second,
            UInt8(bitPattern: timeZoneQuarterHours),
            dstOffsetQuarterHours
        ]
    }

    // MARK: Преобразование в Date

    // java.cpp: unixtime() — timegm(tm) - (tz+dst)*15*60.
    //
    // ВАЖНО: поля сенсора — это «стеновые» часы, а не UTC. Раньше их
    // интерпретировали в ТЕКУЩЕМ поясе телефона. Это работало, пока телефон
    // не менял пояс: при перелёте baseStart уезжал на разницу поясов, и
    // handleLocalStartTime принимал это за «перезапуск сенсора».
    //
    // Теперь пояс, в котором записаны часы сенсора, ФИКСИРУЕТСЯ при записи
    // времени (или при первой привязке) и сохраняется. Смена пояса телефона
    // больше не влияет на baseStart. Если сохранённого пояса нет (сенсор
    // активирован другим телефоном), используется пояс, который сообщает
    // сам сенсор, но только если он не даёт старт в будущем.

    /// Unix-время «как есть»: поля трактуются как UTC (timegm).
    var utcEpoch: TimeInterval? {
        guard year >= 2010 else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!

        var c = DateComponents()
        c.year = Int(year)
        c.month = Int(month)
        c.day = Int(day)
        c.hour = Int(hour)
        c.minute = Int(minute)
        c.second = Int(second)

        return calendar.date(from: c)?.timeIntervalSince1970
    }

    /// Смещение, которое сообщает сам сенсор (tz + dst), в секундах.
    var sensorUTCOffsetSeconds: Int {
        (Int(timeZoneQuarterHours) + Int(dstOffsetQuarterHours)) * 15 * 60
    }

    /// Дата с явным смещением: UTC = timegm(поля) − offset.
    func date(utcOffsetSeconds offset: Int) -> Date? {
        guard let utc = utcEpoch else { return nil }
        return Date(timeIntervalSince1970: utc - Double(offset))
    }

    /// Текущее смещение телефона (с учётом DST) — запасной вариант.
    static func currentPhoneUTCOffset(for date: Date = Date()) -> Int {
        TimeZone.current.secondsFromGMT(for: date)
    }

    var debugDescription: String {
        String(
            format: "%04d-%02d-%02d %02d:%02d:%02d UTC%+.2f dst=%d",
            year, month, day, hour, minute, second,
            Double(timeZoneQuarterHours) / 4.0, dstOffsetQuarterHours
        )
    }
}

// MARK: - Информация об устройстве

// java.cpp: deviceInfo() — структура после двух байт кода.

struct AidexDeviceInfo {
    let deviceModel1: UInt16
    let version: (UInt8, UInt8, UInt8, UInt8)
    /// Срок жизни сенсора в днях
    let lifeDays: UInt8
    let deviceModel2: UInt8
    let name: String

    init?(_ b: [UInt8]) {
        // reg10, reg01, ofDeviceModel1(2), version0..3, days, ofDeviceModel2, name[10]
        guard b.count >= 20 else { return nil }
        deviceModel1 = UInt16(b[2]) | UInt16(b[3]) << 8
        version = (b[4], b[5], b[6], b[7])
        lifeDays = b[8]
        deviceModel2 = b[9]
        let nameBytes = Array(b[10 ..< min(20, b.count)])
        name = String(bytes: nameBytes.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""
    }

    var versionString: String {
        "\(version.0).\(version.1).\(version.2).\(version.3)"
    }
}

// MARK: - Рекламные пакеты

// glucose.h: union AdvertiseBytes.
// Пассивный канал: глюкоза без шифрования и без подключения.
//
// ВАЖНО про формат на iOS. Juggluco (Android) получает ПОЛНЫЙ 62-байтный
// scan record, поэтому читает last по смещению 11, prev — 19/22, CRC — 27.
// CoreBluetooth на iOS отдаёт в CBAdvertisementDataManufacturerDataKey
// только manufacturer data:
//
//   company ID (2) + last (8) + prev0 (3) + prev1 (3) + reserved (2) + CRC32 (4)
//
// то есть 22 байта. Те же поля лежат на 9 байт раньше: 2 / 10/13 / 18.
// Раньше парсер требовал минимум 31 байт и использовал смещения полного
// record — поэтому на iOS он не срабатывал ни разу.

enum AidexAdvertisement {
    /// Company ID Nordic (0x0059).
    static let companyID: UInt16 = 0x0059

    /// Минимальная длина manufacturer data Aidex: company + 20 байт payload.
    static let minimumLength = 22

    /// Смещения полей внутри manufacturer data (iOS).
    private enum Offset {
        static let last = 2
        static let previous = 10
        static let crc = 18
        static let crcRange = 2 ..< 18
    }

    /// glucose.h: mkseed() — сумма четырёх little-endian uint32
    /// по смещениям 2/6/10/14 (в полном record это 11/15/19/23),
    /// по модулю 0x7FA777.
    static func makeSeed(_ raw: [UInt8]) -> UInt32? {
        guard raw.count >= Self.minimumLength else { return nil }
        func le32(_ o: Int) -> UInt32 {
            UInt32(raw[o]) | UInt32(raw[o + 1]) << 8
                | UInt32(raw[o + 2]) << 16 | UInt32(raw[o + 3]) << 24
        }
        let sum = le32(2) &+ le32(6) &+ le32(10) &+ le32(14)
        return sum % 0x7FA777
    }

    /// glucose.h: goodcrc() — crc32_normal(mfg + 2, 0x10, seed) == crc32.
    static func verifyCRC(_ raw: [UInt8]) -> Bool {
        guard raw.count >= Self.minimumLength, let seed = makeSeed(raw) else { return false }
        let computed = AidexCRC.crc32Normal(raw[Offset.crcRange], seed: seed)
        let stored = UInt32(raw[Offset.crc]) | UInt32(raw[Offset.crc + 1]) << 8
            | UInt32(raw[Offset.crc + 2]) << 16 | UInt32(raw[Offset.crc + 3]) << 24
        return computed == stored
    }

    /// Последнее значение + два предыдущих (glucose.h: lastglucose, prev[2]).
    /// Возвращает пары (minutesFromStart, glucose мг/дл).
    static func parse(_ raw: [UInt8]) -> (last: AidexLastPast, previous: [(Int, Int)])? {
        guard raw.count >= Self.minimumLength,
              (UInt16(raw[0]) | UInt16(raw[1]) << 8) == Self.companyID,
              verifyCRC(raw),
              let last = AidexLastPast(raw, at: Offset.last)
        else { return nil }

        var previous: [(Int, Int)] = []
        var id = Int(last.minutesFromStart)
        for i in 0 ..< 2 {
            let offset = Offset.previous + i * AidexNextGlucose.length
            id -= 1
            guard let next = AidexNextGlucose(raw, at: offset), next.isPlausible else { continue }
            previous.append((id, Int(next.glucose)))
        }
        return (last, previous)
    }
}
