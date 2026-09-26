use crate::gatt::{
    characteristic::{self, Properties as CharacteristicProperties},
    descriptor::{self, Properties as DescriptorProperties},
};

pub trait Flags {
    fn flags(self: &Self) -> Vec<String>;
}

impl Flags for CharacteristicProperties {
    fn flags(self: &Self) -> Vec<String> {
        let mut flags = vec![];
        if let Some(ref read) = self.read {
            let read_flags: &[&str] = match read.0 {
                characteristic::Secure::Secure(_) => &["secure-read", "encrypt-authenticated-read"],
                characteristic::Secure::Insecure(_) => &["read"],
            };
            flags.extend_from_slice(read_flags);
        }

        if let Some(ref write) = self.write {
            let write_flag: &[&str] = match write {
                characteristic::Write::WithResponse(secure) => match secure {
                    characteristic::Secure::Secure(_) => {
                        &["secure-write", "encrypt-authenticated-write"]
                    }
                    // PATCH (Sonar): advertise write-without-response alongside
                    // write. bluster models Write as either/or, so an insecure
                    // WithResponse characteristic advertised only "write" and a
                    // central that writes without a response got NOTSUPPORTED.
                    // Both phone platforms use both types on this characteristic
                    // (iOS [.write, .writeWithoutResponse], Android
                    // PROPERTY_WRITE | PROPERTY_WRITE_NO_RESPONSE), and the
                    // CoreBluetooth backend already carries the mirror of this
                    // patch in characteristic_flags.rs. BlueZ routes both to the
                    // same WriteValue handler, so one WriteRequest arm serves them.
                    characteristic::Secure::Insecure(_) => &["write", "write-without-response"],
                },
                characteristic::Write::WithoutResponse(_) => &["write-without-response"],
            };
            flags.extend_from_slice(write_flag);
        }

        if self.notify.is_some() {
            flags.push("notify");
        }

        if self.indicate.is_some() {
            flags.push("indicate");
        }

        flags.iter().map(|s| String::from(*s)).collect()
    }
}

impl Flags for DescriptorProperties {
    fn flags(self: &Self) -> Vec<String> {
        let mut flags = vec![];
        if let Some(ref read) = self.read {
            let read_flags: &[&str] = match read.0 {
                descriptor::Secure::Secure(_) => &["secure-read", "encrypt-authenticated-read"],
                descriptor::Secure::Insecure(_) => &["read"],
            };
            flags.extend_from_slice(read_flags);
        }

        if let Some(ref write) = self.write {
            let write_flags: &[&str] = match write.0 {
                descriptor::Secure::Secure(_) => &["secure-write", "encrypt-authenticated-write"],
                descriptor::Secure::Insecure(_) => &["write"],
            };
            flags.extend_from_slice(write_flags);
        }

        flags.iter().map(|s| String::from(*s)).collect()
    }
}
