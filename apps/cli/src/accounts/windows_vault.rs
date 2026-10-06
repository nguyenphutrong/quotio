//! Per-user DPAPI storage. Open directory handles prevent reparse/rename races.
use super::{AccountError, vault::Backend};
use std::{
    fs::{File, OpenOptions},
    io::{Read, Write},
    os::windows::{
        ffi::OsStrExt,
        fs::{MetadataExt, OpenOptionsExt},
        io::AsRawHandle,
    },
    path::{Path, PathBuf},
};
use windows_sys::Win32::{
    Foundation::LocalFree,
    Security::{
        Authorization::{
            ConvertStringSecurityDescriptorToSecurityDescriptorW, SE_FILE_OBJECT, SetSecurityInfo,
        },
        Cryptography::{
            CRYPT_INTEGER_BLOB, CRYPTPROTECT_UI_FORBIDDEN, CryptProtectData, CryptUnprotectData,
        },
        DACL_SECURITY_INFORMATION, GetSecurityDescriptorDacl, PROTECTED_DACL_SECURITY_INFORMATION,
    },
    Storage::FileSystem::{
        FILE_ATTRIBUTE_REPARSE_POINT, FILE_FLAG_BACKUP_SEMANTICS, FILE_FLAG_OPEN_REPARSE_POINT,
        FILE_SHARE_READ, FILE_SHARE_WRITE,
    },
};

pub(super) struct WindowsVault {
    path: PathBuf,
}
impl WindowsVault {
    pub fn new(path: PathBuf) -> Self {
        Self { path }
    }
}

pub(crate) fn directory_guards(path: &Path) -> Result<Vec<File>, AccountError> {
    if !path.is_absolute() {
        return Err(AccountError::Storage);
    }
    let mut ancestors: Vec<_> = path.ancestors().collect();
    ancestors.reverse();
    let mut guards = Vec::new();
    for path in ancestors.into_iter().filter(|p| !p.as_os_str().is_empty()) {
        if !path.exists() {
            std::fs::create_dir(path).map_err(|_| AccountError::Storage)?;
        }
        let file = OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ | FILE_SHARE_WRITE)
            .custom_flags(FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT)
            .open(path)
            .map_err(|_| AccountError::Storage)?;
        let metadata = file.metadata().map_err(|_| AccountError::Storage)?;
        if !metadata.is_dir() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0 {
            return Err(AccountError::Storage);
        }
        guards.push(file);
    }
    Ok(guards)
}

fn protect(bytes: &[u8], encrypt: bool) -> Result<Vec<u8>, AccountError> {
    let input = CRYPT_INTEGER_BLOB {
        cbData: bytes.len().try_into().map_err(|_| AccountError::Storage)?,
        pbData: bytes.as_ptr().cast_mut(),
    };
    let mut output: CRYPT_INTEGER_BLOB = unsafe { std::mem::zeroed() };
    let success = unsafe {
        if encrypt {
            CryptProtectData(
                &input,
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        } else {
            CryptUnprotectData(
                &input,
                std::ptr::null_mut(),
                std::ptr::null(),
                std::ptr::null(),
                std::ptr::null(),
                CRYPTPROTECT_UI_FORBIDDEN,
                &mut output,
            )
        }
    };
    if success == 0 {
        return Err(AccountError::Storage);
    }
    let result =
        unsafe { std::slice::from_raw_parts(output.pbData, output.cbData as usize).to_vec() };
    unsafe {
        // Clear plaintext returned by DPAPI before releasing its allocation.
        for offset in 0..output.cbData as usize {
            std::ptr::write_volatile(output.pbData.add(offset), 0);
        }
        LocalFree(output.pbData.cast());
    }
    Ok(result)
}

pub(crate) fn restrict(file: &File) -> Result<(), AccountError> {
    let descriptor: Vec<u16> = "D:P(A;;FA;;;OW)".encode_utf16().chain([0]).collect();
    let mut security = std::ptr::null_mut();
    if unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            descriptor.as_ptr(),
            1,
            &mut security,
            std::ptr::null_mut(),
        )
    } == 0
    {
        return Err(AccountError::Storage);
    }
    let mut present = 0;
    let mut defaulted = 0;
    let mut acl = std::ptr::null_mut();
    let result = unsafe {
        if GetSecurityDescriptorDacl(security, &mut present, &mut acl, &mut defaulted) == 0
            || present == 0
        {
            1
        } else {
            SetSecurityInfo(
                file.as_raw_handle(),
                SE_FILE_OBJECT,
                DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
                std::ptr::null_mut(),
                std::ptr::null_mut(),
                acl,
                std::ptr::null(),
            )
        }
    };
    unsafe {
        LocalFree(security);
    }
    if result == 0 {
        Ok(())
    } else {
        Err(AccountError::Storage)
    }
}

impl Backend for WindowsVault {
    fn read(&self) -> Result<Option<Vec<u8>>, AccountError> {
        let _parents = directory_guards(self.path.parent().ok_or(AccountError::Storage)?)?;
        let file = match OpenOptions::new()
            .read(true)
            .share_mode(FILE_SHARE_READ)
            .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
            .open(&self.path)
        {
            Ok(file) => file,
            Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(None),
            Err(_) => return Err(AccountError::Storage),
        };
        let metadata = file.metadata().map_err(|_| AccountError::Storage)?;
        if !metadata.is_file()
            || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
            || metadata.len() > 2 * 1024 * 1024
        {
            return Err(AccountError::Storage);
        }
        let mut encrypted = Vec::new();
        file.take(2 * 1024 * 1024 + 1)
            .read_to_end(&mut encrypted)
            .map_err(|_| AccountError::Storage)?;
        if encrypted.len() > 2 * 1024 * 1024 {
            return Err(AccountError::Storage);
        }
        protect(&encrypted, false).map(Some)
    }
    fn write(&self, bytes: &[u8]) -> Result<(), AccountError> {
        if bytes.len() > 1024 * 1024 {
            return Err(AccountError::Storage);
        }
        let _parents = directory_guards(self.path.parent().ok_or(AccountError::Storage)?)?;
        if let Ok(metadata) = std::fs::symlink_metadata(&self.path) {
            if !metadata.is_file() || metadata.file_attributes() & FILE_ATTRIBUTE_REPARSE_POINT != 0
            {
                return Err(AccountError::Storage);
            }
        }
        let temporary = self.path.with_extension(super::random_string()?);
        let result = (|| {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .share_mode(0)
                .access_mode(0x40000000 | 0x00040000) // GENERIC_WRITE | WRITE_DAC
                .custom_flags(FILE_FLAG_OPEN_REPARSE_POINT)
                .open(&temporary)
                .map_err(|_| AccountError::Storage)?;
            restrict(&file)?;
            file.write_all(&protect(bytes, true)?)
                .map_err(|_| AccountError::Storage)?;
            file.sync_all().map_err(|_| AccountError::Storage)?;
            drop(file);
            replace(&temporary, &self.path).map_err(|_| AccountError::Storage)?;
            Ok(())
        })();
        if result.is_err() {
            let _ = std::fs::remove_file(&temporary);
        }
        result
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn encrypted_roundtrip_replacement_and_corruption() {
        let dir = std::env::temp_dir().join(super::super::random_string().unwrap());
        let vault = WindowsVault::new(dir.join("vault"));
        assert!(vault.read().unwrap().is_none());
        vault.write(b"synthetic-secret").unwrap();
        assert_eq!(vault.read().unwrap().unwrap(), b"synthetic-secret");
        assert!(
            !std::fs::read(&vault.path)
                .unwrap()
                .windows(16)
                .any(|v| v == b"synthetic-secret")
        );
        vault.write(b"replacement").unwrap();
        assert_eq!(vault.read().unwrap().unwrap(), b"replacement");
        std::fs::write(&vault.path, b"corrupt").unwrap();
        assert!(vault.read().is_err());
        std::fs::remove_dir_all(dir).unwrap();
    }
}

pub(crate) fn replace(from: &Path, to: &Path) -> std::io::Result<()> {
    let from: Vec<u16> = from.as_os_str().encode_wide().chain([0]).collect();
    let to: Vec<u16> = to.as_os_str().encode_wide().chain([0]).collect();
    use windows_sys::Win32::Storage::FileSystem::{
        MOVEFILE_REPLACE_EXISTING, MOVEFILE_WRITE_THROUGH, MoveFileExW,
    };
    if unsafe {
        MoveFileExW(
            from.as_ptr(),
            to.as_ptr(),
            MOVEFILE_REPLACE_EXISTING | MOVEFILE_WRITE_THROUGH,
        )
    } == 0
    {
        Err(std::io::Error::last_os_error())
    } else {
        Ok(())
    }
}
