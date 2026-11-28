use crate::{hid, Gamepad, Result};
use core_foundation::{
    base::{CFRelease, CFTypeRef, TCFType},
    data::CFData,
    dictionary::{CFDictionary, CFDictionaryRef},
    string::CFString,
};
use std::{
    ffi::c_void,
    ptr::{self, NonNull},
};

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOHIDUserDeviceCreate(allocator: *const c_void, properties: CFDictionaryRef) -> *mut c_void;
    fn IOHIDUserDeviceHandleReport(device: *mut c_void, report: *const u8, length: isize) -> i32;
}

pub struct Device(NonNull<c_void>);

impl Device {
    pub fn open() -> Result<Self> {
        let properties = CFDictionary::from_CFType_pairs(&[
            (
                CFString::new("ReportDescriptor"),
                CFData::from_buffer(hid::DESCRIPTOR).as_CFType(),
            ),
            (
                CFString::new("Product"),
                CFString::new("PadRelay Gamepad").as_CFType(),
            ),
            (
                CFString::new("Transport"),
                CFString::new("Virtual").as_CFType(),
            ),
        ]);
        // Create returns an owned CF object, released by Drop.
        let raw = unsafe { IOHIDUserDeviceCreate(ptr::null(), properties.as_concrete_TypeRef()) };
        let mut device = Self(NonNull::new(raw).ok_or("Cannot create the macOS gamepad. Sign and provision the receiver with com.apple.developer.hid.virtual.device, or use --monitor to test pairing.")?);
        device.update(&Gamepad::default())?;
        Ok(device)
    }

    pub fn update(&mut self, pad: &Gamepad) -> Result<()> {
        let report = hid::report(pad);
        let status = unsafe {
            IOHIDUserDeviceHandleReport(self.0.as_ptr(), report.as_ptr(), report.len() as isize)
        };
        if status != 0 {
            return Err(format!("Virtual HID input failed ({status:#x})").into());
        }
        Ok(())
    }
}

impl Drop for Device {
    fn drop(&mut self) {
        unsafe { CFRelease(self.0.as_ptr() as CFTypeRef) };
    }
}
