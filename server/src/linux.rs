use crate::{Gamepad, Result};
use evdev::{
    uinput::VirtualDevice, AbsInfo, AbsoluteAxisCode as Axis, AttributeSet, EventType, InputEvent,
    KeyCode as Key, UinputAbsSetup,
};

const BUTTONS: [(u16, Key); 11] = [
    (0x1000, Key::BTN_SOUTH),
    (0x2000, Key::BTN_EAST),
    (0x4000, Key::BTN_NORTH),
    (0x8000, Key::BTN_WEST),
    (0x0100, Key::BTN_TL),
    (0x0200, Key::BTN_TR),
    (0x0020, Key::BTN_SELECT),
    (0x0010, Key::BTN_START),
    (0x0400, Key::BTN_MODE),
    (0x0040, Key::BTN_THUMBL),
    (0x0080, Key::BTN_THUMBR),
];

const AXES: [(Axis, i32, i32); 8] = [
    (Axis::ABS_X, -32768, 32767),
    (Axis::ABS_Y, -32768, 32767),
    (Axis::ABS_RX, -32768, 32767),
    (Axis::ABS_RY, -32768, 32767),
    (Axis::ABS_Z, 0, 255),
    (Axis::ABS_RZ, 0, 255),
    (Axis::ABS_HAT0X, -1, 1),
    (Axis::ABS_HAT0Y, -1, 1),
];

pub struct Device(VirtualDevice);

impl Device {
    pub fn open() -> Result<Self> {
        let mut keys = AttributeSet::<Key>::new();
        for (_, key) in BUTTONS {
            keys.insert(key);
        }
        let mut builder = VirtualDevice::builder()
            .map_err(|e| format!("Cannot open /dev/uinput ({e}). Load uinput and grant the receiver user read/write access."))?
            .name("PadRelay Gamepad").with_keys(&keys)?;
        for (axis, min, max) in AXES {
            builder = builder.with_absolute_axis(&UinputAbsSetup::new(
                axis,
                AbsInfo::new(0, min, max, 0, 0, 0),
            ))?;
        }
        Ok(Self(builder.build()?))
    }

    pub fn update(&mut self, pad: &Gamepad) -> Result<()> {
        let mut events = Vec::with_capacity(BUTTONS.len() + AXES.len());
        for (mask, key) in BUTTONS {
            events.push(InputEvent::new(
                EventType::KEY.0,
                key.0,
                i32::from(pad.buttons & mask != 0),
            ));
        }
        let (x, y) = pad.hat();
        let values = pad.sticks().map(i32::from).into_iter().chain([
            i32::from(pad.left_trigger),
            i32::from(pad.right_trigger),
            i32::from(x),
            i32::from(y),
        ]);
        for ((axis, _, _), value) in AXES.into_iter().zip(values) {
            events.push(InputEvent::new(EventType::ABSOLUTE.0, axis.0, value));
        }
        self.0.emit(&events)?;
        Ok(())
    }
}
