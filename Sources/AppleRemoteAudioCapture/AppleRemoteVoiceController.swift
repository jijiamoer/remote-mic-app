import Foundation
import IOKit.hid

final class AppleRemoteVoiceController {
    enum Result: Equatable {
        case accepted
        case deviceManagementInterfaceUnavailable
        case rejected(IOReturn)
    }

    private static let vendorID = 0x004C
    /// A2854（第 7 代）走管理接口 PTT 报告；A2540（第 6 代）走 Feature 0xFF 广播激活。
    private static let productIDA2854 = 0x0315
    private static let productIDA2540 = 0x0314
    private static let activationByte: UInt8 = 0xAF

    private let manager: IOHIDManager
    private var managementDevice: IOHIDDevice?
    /// A2540 的所有 HID 接口（每个接口是独立 IOHIDDevice），激活时逐接口写。
    private var a2540Interfaces: [IOHIDDevice] = []
    private var openedDevices: [IOHIDDevice] = []

    init?() {
        manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        IOHIDManagerSetDeviceMatchingMultiple(manager, [
            [
                kIOHIDVendorIDKey as String: Self.vendorID,
                kIOHIDProductIDKey as String: Self.productIDA2854,
            ],
            [
                kIOHIDVendorIDKey as String: Self.vendorID,
                kIOHIDProductIDKey as String: Self.productIDA2540,
            ],
        ] as CFArray)
        guard IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else {
            return nil
        }
        guard let devices = IOHIDManagerCopyDevices(manager) else { return }
        let count = CFSetGetCount(devices)
        var values = [UnsafeRawPointer?](repeating: nil, count: count)
        CFSetGetValues(devices, &values)
        for value in values {
            guard let value else { continue }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(value).takeUnretainedValue()
            let productID = Self.integerProperty(kIOHIDProductIDKey, device: device)
            switch productID {
            case Self.productIDA2854:
                let usagePage = Self.integerProperty(kIOHIDPrimaryUsagePageKey, device: device)
                let usage = Self.integerProperty(kIOHIDPrimaryUsageKey, device: device)
                if usagePage == 0xFF00, usage == 0x000B {
                    managementDevice = device
                }
            case Self.productIDA2540:
                a2540Interfaces.append(device)
            default:
                continue
            }
        }
    }

    deinit {
        // 只恢复 A2854 的 PTT 释放；A2540 依赖物理松键停流，不写停用命令。
        if let device = managementDevice {
            var report: [UInt8] = [0x98, 0x00]
            report.withUnsafeMutableBufferPointer { buffer in
                guard let baseAddress = buffer.baseAddress else { return }
                _ = IOHIDDeviceSetReport(
                    device,
                    kIOHIDReportTypeFeature,
                    0x98,
                    baseAddress,
                    buffer.count
                )
            }
        }
        for device in openedDevices {
            IOHIDDeviceClose(device, IOOptionBits(kIOHIDOptionsTypeNone))
        }
        IOHIDManagerClose(manager, IOOptionBits(kIOHIDOptionsTypeNone))
    }

    func setActive(_ active: Bool) -> Result {
        guard managementDevice != nil || !a2540Interfaces.isEmpty else {
            return .deviceManagementInterfaceUnavailable
        }
        var wrote = false
        var workRequired = false
        var lastError = kIOReturnSuccess
        if let device = managementDevice {
            workRequired = true
            var report: [UInt8] = [0x98, active ? 0x01 : 0x00]
            let result = writeReport(
                device: device,
                reportID: 0x98,
                bytes: &report,
                length: report.count
            )
            if result == kIOReturnSuccess { wrote = true } else { lastError = result }
        }
        if active, !a2540Interfaces.isEmpty {
            workRequired = true
            // A2540：向每个接口的 Feature 0xFF 写 [0xAF]（siri-remote-mic 实机验证路径；
            // 未声明 0xFF 的接口退化为遍历其全部 feature report）。
            for device in a2540Interfaces {
                guard ensureOpen(device) == kIOReturnSuccess else { continue }
                for reportID in Self.activationReportIDs(device: device) {
                    var byte = Self.activationByte
                    let result = writeReport(
                        device: device,
                        reportID: CFIndex(reportID),
                        bytes: &byte,
                        length: 1
                    )
                    if result == kIOReturnSuccess { wrote = true } else { lastError = result }
                }
            }
        }
        // A2540 的停用无写操作：遥控器物理松键即停流。
        guard workRequired else { return .accepted }
        return wrote ? .accepted : .rejected(lastError)
    }

    private func ensureOpen(_ device: IOHIDDevice) -> IOReturn {
        if openedDevices.contains(where: { $0 === device }) { return kIOReturnSuccess }
        let result = IOHIDDeviceOpen(device, IOOptionBits(kIOHIDOptionsTypeNone))
        if result == kIOReturnSuccess { openedDevices.append(device) }
        return result
    }

    private func writeReport(
        device: IOHIDDevice,
        reportID: CFIndex,
        bytes: UnsafeMutablePointer<UInt8>,
        length: Int
    ) -> IOReturn {
        IOHIDDeviceSetReport(device, kIOHIDReportTypeFeature, reportID, bytes, length)
    }

    /// 该接口上激活写入的目标 reportID：声明了 Feature 0xFF 则只写 0xFF，
    /// 否则遍历全部 feature report（与 siri-remote-mic 的实机验证行为一致）。
    static func activationReportIDs(device: IOHIDDevice) -> [Int] {
        guard let elements = IOHIDDeviceCopyMatchingElements(
            device,
            nil,
            IOOptionBits(kIOHIDOptionsTypeNone)
        ) as? [IOHIDElement] else { return [] }
        var featureIDs = Set<Int>()
        for element in elements {
            guard IOHIDElementGetType(element) == kIOHIDElementTypeFeature else { continue }
            featureIDs.insert(Int(IOHIDElementGetReportID(element)))
        }
        return featureIDs.contains(0xFF) ? [0xFF] : featureIDs.sorted()
    }

    private static func integerProperty(_ key: String, device: IOHIDDevice) -> Int? {
        (IOHIDDeviceGetProperty(device, key as CFString) as? NSNumber)?.intValue
    }
}
