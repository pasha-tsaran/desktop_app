use std::{
    ffi::c_void,
    fs, io,
    path::{Path, PathBuf},
    ptr,
};

use vpn_contracts::{
    decode_amneziawg_profile, decode_vless_profile, decode_wireguard_profile,
    encode_amneziawg_profile, encode_vless_profile, encode_wireguard_profile, AmneziaWgProfile,
    VlessRealityProfile, WireGuardProfile,
};
use vpn_service_core::{CommandError, ProfileVault};
use windows_sys::Win32::{
    Foundation::LocalFree,
    Security::{
        Authorization::{ConvertStringSecurityDescriptorToSecurityDescriptorW, SDDL_REVISION_1},
        Cryptography::{
            BCryptGenRandom, CryptProtectData, CryptUnprotectData, BCRYPT_USE_SYSTEM_PREFERRED_RNG,
            CRYPTPROTECT_LOCAL_MACHINE, CRYPTPROTECT_UI_FORBIDDEN, CRYPT_INTEGER_BLOB,
        },
        SetFileSecurityW, DACL_SECURITY_INFORMATION, PROTECTED_DACL_SECURITY_INFORMATION,
    },
};

const ENTROPY: &[u8] = b"KenaiVPN.ProfileVault.v1";

#[derive(Debug)]
pub struct DpapiProfileVault {
    root: PathBuf,
}

impl DpapiProfileVault {
    pub fn system_default() -> io::Result<Self> {
        let program_data = std::env::var_os("ProgramData")
            .filter(|value| !value.is_empty())
            .ok_or_else(|| io::Error::new(io::ErrorKind::NotFound, "ProgramData unavailable"))?;
        Self::new(
            PathBuf::from(program_data)
                .join("KenaiVPN")
                .join("profiles"),
        )
    }

    fn new(root: PathBuf) -> io::Result<Self> {
        fs::create_dir_all(&root)?;
        apply_service_acl(&root)?;
        Ok(Self { root })
    }

    fn path(&self, profile_id: &str) -> Result<PathBuf, CommandError> {
        if !valid_handle(profile_id) {
            return Err(CommandError::ProfileNotFound);
        }
        Ok(self.root.join(format!("{profile_id}.bin")))
    }
}

impl ProfileVault for DpapiProfileVault {
    fn store_wireguard(&mut self, profile: &WireGuardProfile) -> Result<String, CommandError> {
        let mut plaintext =
            encode_wireguard_profile(profile).map_err(|_| CommandError::InvalidProfile)?;
        let encrypted = protect(&plaintext).map_err(|_| CommandError::ProfileStoreUnavailable);
        plaintext.fill(0);
        let encrypted = encrypted?;

        for _ in 0..8 {
            let profile_id =
                random_handle("wg-").map_err(|_| CommandError::ProfileStoreUnavailable)?;
            let path = self.path(&profile_id)?;
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(mut file) => {
                    use std::io::Write;
                    if file
                        .write_all(&encrypted)
                        .and_then(|()| file.sync_all())
                        .is_err()
                    {
                        let _ = fs::remove_file(path);
                        return Err(CommandError::ProfileStoreUnavailable);
                    }
                    return Ok(profile_id);
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(_) => return Err(CommandError::ProfileStoreUnavailable),
            }
        }
        Err(CommandError::ProfileStoreUnavailable)
    }

    fn load_wireguard(&self, profile_id: &str) -> Result<WireGuardProfile, CommandError> {
        let encrypted = fs::read(self.path(profile_id)?).map_err(|error| match error.kind() {
            io::ErrorKind::NotFound => CommandError::ProfileNotFound,
            _ => CommandError::ProfileStoreUnavailable,
        })?;
        let mut plaintext =
            unprotect(&encrypted).map_err(|_| CommandError::ProfileStoreUnavailable)?;
        let profile =
            decode_wireguard_profile(&plaintext).map_err(|_| CommandError::InvalidProfile);
        plaintext.fill(0);
        profile
    }

    fn store_amneziawg(&mut self, profile: &AmneziaWgProfile) -> Result<String, CommandError> {
        let mut plaintext =
            encode_amneziawg_profile(profile).map_err(|_| CommandError::InvalidProfile)?;
        let encrypted = protect(&plaintext).map_err(|_| CommandError::ProfileStoreUnavailable);
        plaintext.fill(0);
        let encrypted = encrypted?;
        for _ in 0..8 {
            let profile_id =
                random_handle("awg-").map_err(|_| CommandError::ProfileStoreUnavailable)?;
            let path = self.path(&profile_id)?;
            match fs::OpenOptions::new()
                .write(true)
                .create_new(true)
                .open(&path)
            {
                Ok(mut file) => {
                    use std::io::Write;
                    if file
                        .write_all(&encrypted)
                        .and_then(|()| file.sync_all())
                        .is_err()
                    {
                        let _ = fs::remove_file(path);
                        return Err(CommandError::ProfileStoreUnavailable);
                    }
                    return Ok(profile_id);
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
                Err(_) => return Err(CommandError::ProfileStoreUnavailable),
            }
        }
        Err(CommandError::ProfileStoreUnavailable)
    }

    fn load_amneziawg(&self, profile_id: &str) -> Result<AmneziaWgProfile, CommandError> {
        if !profile_id.starts_with("awg-") {
            return Err(CommandError::ProfileNotFound);
        }
        let encrypted = fs::read(self.path(profile_id)?).map_err(|error| match error.kind() {
            io::ErrorKind::NotFound => CommandError::ProfileNotFound,
            _ => CommandError::ProfileStoreUnavailable,
        })?;
        let mut plaintext =
            unprotect(&encrypted).map_err(|_| CommandError::ProfileStoreUnavailable)?;
        let profile =
            decode_amneziawg_profile(&plaintext).map_err(|_| CommandError::InvalidProfile);
        plaintext.fill(0);
        profile
    }

    fn store_vless(&mut self, profile: &VlessRealityProfile) -> Result<String, CommandError> {
        let mut plaintext =
            encode_vless_profile(profile).map_err(|_| CommandError::InvalidProfile)?;
        let encrypted = protect(&plaintext).map_err(|_| CommandError::ProfileStoreUnavailable);
        plaintext.fill(0);
        store_encrypted(self, "xray-", &encrypted?)
    }

    fn load_vless(&self, profile_id: &str) -> Result<VlessRealityProfile, CommandError> {
        if !profile_id.starts_with("xray-") {
            return Err(CommandError::ProfileNotFound);
        }
        let encrypted = read_encrypted(self, profile_id)?;
        let mut plaintext =
            unprotect(&encrypted).map_err(|_| CommandError::ProfileStoreUnavailable)?;
        let profile = decode_vless_profile(&plaintext).map_err(|_| CommandError::InvalidProfile);
        plaintext.fill(0);
        profile
    }

    fn delete(&mut self, profile_id: &str) -> Result<(), CommandError> {
        let path = self.path(profile_id)?;
        match fs::remove_file(path) {
            Ok(()) => Ok(()),
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                Err(CommandError::ProfileNotFound)
            }
            Err(_) => Err(CommandError::ProfileStoreUnavailable),
        }
    }
}

fn protect(plaintext: &[u8]) -> io::Result<Vec<u8>> {
    let data_len = u32::try_from(plaintext.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "profile too large"))?;
    let entropy_len = u32::try_from(ENTROPY.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "entropy too large"))?;
    let input = CRYPT_INTEGER_BLOB {
        cbData: data_len,
        pbData: plaintext.as_ptr().cast_mut(),
    };
    let entropy = CRYPT_INTEGER_BLOB {
        cbData: entropy_len,
        pbData: ENTROPY.as_ptr().cast_mut(),
    };
    let mut output = CRYPT_INTEGER_BLOB::default();
    // SAFETY: all input slices remain alive for the call; DPAPI initializes
    // `output` on success and its allocation is released with LocalFree.
    let protected = unsafe {
        CryptProtectData(
            ptr::from_ref(&input),
            ptr::null(),
            ptr::from_ref(&entropy),
            ptr::null(),
            ptr::null(),
            CRYPTPROTECT_LOCAL_MACHINE | CRYPTPROTECT_UI_FORBIDDEN,
            ptr::addr_of_mut!(output),
        )
    };
    if protected == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: DPAPI returned `cbData` readable bytes at `pbData`.
    let bytes = unsafe {
        std::slice::from_raw_parts(output.pbData.cast_const(), output.cbData as usize).to_vec()
    };
    // SAFETY: the output buffer is owned by LocalAlloc and released once.
    unsafe { LocalFree(output.pbData.cast::<c_void>()) };
    Ok(bytes)
}

fn store_encrypted(
    vault: &DpapiProfileVault,
    prefix: &str,
    encrypted: &[u8],
) -> Result<String, CommandError> {
    for _ in 0..8 {
        let profile_id =
            random_handle(prefix).map_err(|_| CommandError::ProfileStoreUnavailable)?;
        let path = vault.path(&profile_id)?;
        match fs::OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
        {
            Ok(mut file) => {
                use std::io::Write;
                if file
                    .write_all(encrypted)
                    .and_then(|()| file.sync_all())
                    .is_err()
                {
                    let _ = fs::remove_file(path);
                    return Err(CommandError::ProfileStoreUnavailable);
                }
                return Ok(profile_id);
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(_) => return Err(CommandError::ProfileStoreUnavailable),
        }
    }
    Err(CommandError::ProfileStoreUnavailable)
}

fn read_encrypted(vault: &DpapiProfileVault, profile_id: &str) -> Result<Vec<u8>, CommandError> {
    fs::read(vault.path(profile_id)?).map_err(|error| match error.kind() {
        io::ErrorKind::NotFound => CommandError::ProfileNotFound,
        _ => CommandError::ProfileStoreUnavailable,
    })
}

fn unprotect(encrypted: &[u8]) -> io::Result<Vec<u8>> {
    let data_len = u32::try_from(encrypted.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "profile too large"))?;
    let entropy_len = u32::try_from(ENTROPY.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "entropy too large"))?;
    let input = CRYPT_INTEGER_BLOB {
        cbData: data_len,
        pbData: encrypted.as_ptr().cast_mut(),
    };
    let entropy = CRYPT_INTEGER_BLOB {
        cbData: entropy_len,
        pbData: ENTROPY.as_ptr().cast_mut(),
    };
    let mut output = CRYPT_INTEGER_BLOB::default();
    // SAFETY: inputs remain valid for the call; output is released below.
    let unprotected = unsafe {
        CryptUnprotectData(
            ptr::from_ref(&input),
            ptr::null_mut(),
            ptr::from_ref(&entropy),
            ptr::null(),
            ptr::null(),
            CRYPTPROTECT_UI_FORBIDDEN,
            ptr::addr_of_mut!(output),
        )
    };
    if unprotected == 0 {
        return Err(io::Error::last_os_error());
    }
    // SAFETY: DPAPI returned `cbData` readable bytes at `pbData`.
    let bytes = unsafe {
        std::slice::from_raw_parts(output.pbData.cast_const(), output.cbData as usize).to_vec()
    };
    // SAFETY: the output buffer is owned by LocalAlloc and released once.
    unsafe { LocalFree(output.pbData.cast::<c_void>()) };
    Ok(bytes)
}

fn random_handle(prefix: &str) -> io::Result<String> {
    let mut random = [0_u8; 16];
    let length = u32::try_from(random.len())
        .map_err(|_| io::Error::new(io::ErrorKind::InvalidInput, "random buffer too large"))?;
    // SAFETY: the buffer is writable for exactly `length` bytes and the system
    // preferred CSPRNG does not require an algorithm handle.
    let status = unsafe {
        BCryptGenRandom(
            ptr::null_mut(),
            random.as_mut_ptr(),
            length,
            BCRYPT_USE_SYSTEM_PREFERRED_RNG,
        )
    };
    if status < 0 {
        return Err(io::Error::from_raw_os_error(status));
    }
    let mut handle = String::with_capacity(35);
    handle.push_str(prefix);
    for byte in random {
        use std::fmt::Write;
        let _ = write!(handle, "{byte:02x}");
    }
    Ok(handle)
}

fn valid_handle(value: &str) -> bool {
    ((value.len() == 35 && value.starts_with("wg-"))
        || (value.len() == 36 && value.starts_with("awg-"))
        || (value.len() == 37 && value.starts_with("xray-")))
        && value[value.find('-').unwrap_or(0) + 1..]
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit())
}

pub(super) fn apply_service_acl(path: &Path) -> io::Result<()> {
    let sddl = to_wide("D:P(A;;FA;;;SY)(A;;FA;;;BA)");
    let mut descriptor = ptr::null_mut();
    // SAFETY: the input is NUL terminated and the descriptor out-pointer is
    // released below after the synchronous ACL update.
    let converted = unsafe {
        ConvertStringSecurityDescriptorToSecurityDescriptorW(
            sddl.as_ptr(),
            SDDL_REVISION_1,
            ptr::addr_of_mut!(descriptor),
            ptr::null_mut(),
        )
    };
    if converted == 0 {
        return Err(io::Error::last_os_error());
    }
    let wide_path = to_wide(&path.to_string_lossy());
    // SAFETY: both pointers remain valid through the call.
    let applied = unsafe {
        SetFileSecurityW(
            wide_path.as_ptr(),
            DACL_SECURITY_INFORMATION | PROTECTED_DACL_SECURITY_INFORMATION,
            descriptor,
        )
    };
    // SAFETY: descriptor was allocated by the SDDL conversion API.
    unsafe { LocalFree(descriptor.cast::<c_void>()) };
    if applied == 0 {
        return Err(io::Error::last_os_error());
    }
    Ok(())
}

fn to_wide(value: &str) -> Vec<u16> {
    value.encode_utf16().chain(std::iter::once(0)).collect()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn handles_are_opaque_and_path_safe() {
        let handle = random_handle("wg-").expect("CSPRNG");
        assert!(valid_handle(&handle));
        assert!(valid_handle(&random_handle("awg-").expect("CSPRNG")));
        assert!(valid_handle(&random_handle("xray-").expect("CSPRNG")));
        assert!(!valid_handle("../profile"));
        assert!(!valid_handle("wg-not-hex"));
    }

    #[test]
    fn dpapi_never_leaves_plaintext_in_its_output() {
        let secret = b"private-profile-material";
        let encrypted = protect(secret).expect("DPAPI");
        assert!(!encrypted
            .windows(secret.len())
            .any(|window| window == secret));
        assert_eq!(unprotect(&encrypted).expect("DPAPI decrypt"), secret);
    }
}
