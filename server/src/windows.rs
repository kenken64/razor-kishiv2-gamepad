use crate::{Gamepad, Result};
use vigem_client::{Client, TargetId, XGamepad, Xbox360Wired};

pub struct Device(Xbox360Wired<Client>);

impl Device {
    pub fn open() -> Result<Self> {
        let client = Client::connect().map_err(|e| format!("Cannot open ViGEmBus ({e}). Install the ViGEmBus Windows driver and restart the receiver."))?;
        let mut pad = Xbox360Wired::new(client, TargetId::XBOX360_WIRED);
        pad.plugin()?;
        pad.wait_ready()?;
        Ok(Self(pad))
    }

    pub fn update(&mut self, pad: &Gamepad) -> Result<()> {
        self.0.update(&XGamepad {
            buttons: pad.buttons.into(),
            left_trigger: pad.left_trigger,
            right_trigger: pad.right_trigger,
            thumb_lx: pad.thumb_lx,
            thumb_ly: pad.thumb_ly,
            thumb_rx: pad.thumb_rx,
            thumb_ry: pad.thumb_ry,
        })?;
        Ok(())
    }
}
