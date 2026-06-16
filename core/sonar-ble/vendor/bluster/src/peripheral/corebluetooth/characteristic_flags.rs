use super::ffi::{CBAttributePermissions, CBCharacteristicProperties};
use crate::gatt::characteristic::{Characteristic, Secure, Write};

pub fn get_properties_and_permissions(characteristic: &Characteristic) -> (u16, u8) {
    let mut properties: u16 = 0;
    let mut permissions: u8 = 0;

    if let Some(secure) = &characteristic.properties.read {
        properties |= CBCharacteristicProperties::CBCharacteristicPropertyRead as u16;

        match secure.0 {
            Secure::Secure(_) => {
                permissions |=
                    CBAttributePermissions::CBAttributePermissionsReadEncryptionRequired as u8;
            }
            Secure::Insecure(_) => {
                permissions |= CBAttributePermissions::CBAttributePermissionsReadable as u8;
            }
        };
    }

    if let Some(write) = &characteristic.properties.write {
        match write {
            Write::WithResponse(secure) => {
                properties |= CBCharacteristicProperties::CBCharacteristicPropertyWrite as u16;
                // PATCH (Sonar): also advertise write-WITHOUT-response. A real
                // bitchat peripheral exposes both (Android: PROPERTY_WRITE |
                // PROPERTY_WRITE_NO_RESPONSE); iOS clients write without response,
                // so without this the iPhone can't write to us. Both land in
                // didReceiveWriteRequests, which we capture.
                properties |=
                    CBCharacteristicProperties::CBCharacteristicPropertyWriteWithoutResponse as u16;
                match secure {
                    Secure::Secure(_) => {
                        permissions |=
                            CBAttributePermissions::CBAttributePermissionsWriteEncryptionRequired
                                as u8;
                    }
                    Secure::Insecure(_) => {
                        permissions |=
                            CBAttributePermissions::CBAttributePermissionsWriteable as u8;
                    }
                };
            }
            Write::WithoutResponse(_) => {
                properties |=
                    CBCharacteristicProperties::CBCharacteristicPropertyWriteWithoutResponse as u16;
            }
        };
    }

    if characteristic.properties.notify.is_some() {
        properties |= CBCharacteristicProperties::CBCharacteristicPropertyNotify as u16;
    }

    if characteristic.properties.indicate.is_some() {
        properties |= CBCharacteristicProperties::CBCharacteristicPropertyIndicate as u16;
    }

    (properties, permissions)
}
