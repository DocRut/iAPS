//
//  AidexCrypto.swift
//  Криптография и контрольные суммы протокола Aidex X / LumiFlex / LinX
//
//  Портировано с Juggluco (GPL-3.0), автор Jaap Korthals Altes:
//    Common/src/main/cpp/aidexx/mkiv.cpp    — вывод ключа и IV
//    Common/src/main/cpp/aidexx/decrypt.cpp — AES-128-CFB
//    Common/src/main/cpp/aidexx/crc.cpp     — CRC8/CRC16/CRC32
//
//  ВНИМАНИЕ О ЛИЦЕНЗИИ: Juggluco под GPL-3.0 (копилефт).
//  Для личной сборки это ограничений не создаёт. Для публикации форка
//  нужно проверить совместимость с лицензией iAPS.
//

import CommonCrypto
import Foundation

// MARK: - Контрольные суммы

enum AidexCRC {

    /// crc.cpp: crc8_maxim() — poly 0x8C (reflected 0x31), init 0x00
    /// Применение: проверка сессионного ключа (17-й байт).
    static func crc8Maxim(_ data: ArraySlice<UInt8>) -> UInt8 {
        var crc: UInt8 = 0x00
        for byte in data {
            crc ^= byte
            for _ in 0 ..< 8 {
                crc = (crc & 1) != 0 ? (crc >> 1) ^ 0x8C : crc >> 1
            }
        }
        return crc
    }

    static func crc8Maxim(_ data: [UInt8]) -> UInt8 { crc8Maxim(data[...]) }

    /// crc.cpp: crc16_ccitt_false() — poly 0x1021, init 0xFFFF
    /// Применение: последние 2 байта каждого расшифрованного пакета F002.
    static func crc16CCITTFalse(_ data: ArraySlice<UInt8>) -> UInt16 {
        var crc: UInt16 = 0xFFFF
        for byte in data {
            crc ^= UInt16(byte) << 8
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x1021 : crc << 1
            }
        }
        return crc
    }

    static func crc16CCITTFalse(_ data: [UInt8]) -> UInt16 { crc16CCITTFalse(data[...]) }

    /// crc.cpp: addcrc16() — дописывает CRC16 little-endian в конец команды.
    static func appendCRC16(_ data: [UInt8]) -> [UInt8] {
        let crc = crc16CCITTFalse(data)
        return data + [UInt8(crc & 0xFF), UInt8(crc >> 8)]
    }

    /// crc.cpp: crc32_normal() — poly 0x04C11DB7, без рефлексии,
    /// начальное значение задаётся снаружи (seed).
    /// Применение: проверка рекламных пакетов.
    static func crc32Normal(_ data: ArraySlice<UInt8>, seed: UInt32) -> UInt32 {
        var crc = seed
        for byte in data {
            crc ^= UInt32(byte) << 24
            for _ in 0 ..< 8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }
}

// MARK: - Криптография

enum AidexCrypto {

    // MARK: Серийный номер

    /// mkiv.cpp: snCharToVal()
    ///   '0'..'9' -> 0x00..0x09
    ///   'A'..'Z' -> 0x0A..0x23   (c - 0x37)
    ///   'a'..'z' -> 0x0A..0x23   (c - 0x57)
    ///   иначе    -> байт без изменений
    static func snCharToVal(_ c: UInt8) -> UInt8 {
        switch c {
        case 0x30 ... 0x39: return c &- 0x30
        case 0x41 ... 0x5A: return c &- 0x37
        case 0x61 ... 0x7A: return c &- 0x57
        default: return c
        }
    }

    /// mkiv.cpp: snToBytes()
    static func snToBytes(_ serial: String) -> [UInt8] {
        Array(serial.utf8).map(snCharToVal)
    }

    // MARK: MD5

    private static func md5(_ bytes: [UInt8]) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        bytes.withUnsafeBufferPointer { buf in
            _ = CC_MD5(buf.baseAddress, CC_LONG(bytes.count), &digest)
        }
        return digest
    }

    // MARK: Вывод IV и стартового ключа

    /// mkiv.cpp: mkiv() / mkAidexXiv()
    ///   b[i] = (snToBytes(serial)[i] * 17 + 0x13) & 0xFF ; iv = MD5(b)
    /// IV постоянен для сенсора и используется для ВСЕХ операций
    /// (java.cpp: decrypt/encrypt всегда берут aidexXdat.iv).
    static func makeIV(serial: String) -> [UInt8] {
        let bytes = snToBytes(serial).map { UInt8((Int($0) &* 17 &+ 0x13) & 0xFF) }
        return md5(bytes)
    }

    /// mkiv.cpp: aidexXaskKey()
    ///   t[i] = (snToBytes(serial)[i] * 13 + 61) & 0xFF ; out = MD5(t)
    /// Эти 16 байт пишутся в F001 (private unbonded) — запрос сессионного ключа.
    /// Они же служат ключом для расшифровки ответа с сессионным ключом (keys[0]).
    static func askKey(serial: String) -> [UInt8] {
        let bytes = snToBytes(serial).map { UInt8((Int($0) &* 13 &+ 61) & 0xFF) }
        return md5(bytes)
    }

    // MARK: AES-128-CFB
    // decrypt.cpp использует AES_cfb128_encrypt с num=0 => полноблочный CFB-128.
    // IV мутируется внутри вызова, но в оригинале каждый раз берётся свежая
    // копия постоянного IV (iv_local), поэтому состояние между пакетами
    // НЕ переносится.

    private static func aesCFB128(
        _ input: [UInt8],
        key: [UInt8],
        iv: [UInt8],
        operation: Int
    ) -> [UInt8]? {
        guard key.count == 16, iv.count == 16, !input.isEmpty else { return nil }

        var cryptorRef: CCCryptorRef?
        let createStatus = CCCryptorCreateWithMode(
            CCOperation(operation),
            CCMode(kCCModeCFB),
            CCAlgorithm(kCCAlgorithmAES),
            CCPadding(ccNoPadding),
            iv, key, key.count,
            nil, 0, 0,
            CCModeOptions(0),
            &cryptorRef
        )
        guard createStatus == kCCSuccess, let cryptor = cryptorRef else { return nil }
        defer { CCCryptorRelease(cryptor) }

        var output = [UInt8](repeating: 0, count: input.count)
        var moved = 0
        let status = CCCryptorUpdate(
            cryptor, input, input.count,
            &output, output.count, &moved
        )
        guard status == kCCSuccess, moved == input.count else { return nil }
        return output
    }

    static func decrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        aesCFB128(data, key: key, iv: iv, operation: kCCDecrypt)
    }

    static func encrypt(_ data: [UInt8], key: [UInt8], iv: [UInt8]) -> [UInt8]? {
        aesCFB128(data, key: key, iv: iv, operation: kCCEncrypt)
    }
}
