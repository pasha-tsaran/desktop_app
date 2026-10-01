use std::{ffi::OsString, io, os::windows::ffi::{OsStrExt, OsStringExt}, path::{Path, PathBuf}};
use windows_sys::Win32::Storage::FileSystem::GetLongPathNameW;

/// Expand existing 8.3 aliases before starting an engine that authorizes its
/// own executable via WFP. WFP application IDs retain short-name components.
pub fn current_executable() -> io::Result<PathBuf> {
    expand_long_path(&std::env::current_exe()?)
}

fn expand_long_path(path: &Path) -> io::Result<PathBuf> {
    let input: Vec<u16> = path.as_os_str().encode_wide().chain(Some(0)).collect();
    // SAFETY: input is NUL terminated; the first call only requests buffer size.
    let required = unsafe { GetLongPathNameW(input.as_ptr(), std::ptr::null_mut(), 0) };
    if required == 0 { return Err(io::Error::last_os_error()); }
    let mut output = vec![0_u16; required as usize];
    // SAFETY: output has the requested capacity, and input remains alive.
    let written = unsafe { GetLongPathNameW(input.as_ptr(), output.as_mut_ptr(), required) };
    if written == 0 { return Err(io::Error::last_os_error()); }
    if written >= required { return Err(io::Error::other("executable path changed")); }
    Ok(PathBuf::from(OsString::from_wide(&output[..written as usize])))
}

#[cfg(test)]
mod tests {
    use super::*;
    use windows_sys::Win32::Storage::FileSystem::GetShortPathNameW;

    #[test]
    fn short_executable_alias_expands_to_the_same_long_path() {
        let executable = std::env::current_exe().expect("test executable");
        let expected = expand_long_path(&executable).expect("long path");
        let input: Vec<u16> = executable.as_os_str().encode_wide().chain(Some(0)).collect();
        // SAFETY: input is terminated and the null output requests length only.
        let required = unsafe { GetShortPathNameW(input.as_ptr(), std::ptr::null_mut(), 0) };
        assert!(required > 0);
        let mut output = vec![0_u16; required as usize];
        // SAFETY: output has the size requested by Windows.
        let written = unsafe { GetShortPathNameW(input.as_ptr(), output.as_mut_ptr(), required) };
        assert!(written > 0 && written < required);
        let short = PathBuf::from(OsString::from_wide(&output[..written as usize]));
        assert_eq!(expand_long_path(&short).expect("expand alias"), expected);
    }

    #[test]
    fn missing_executable_is_rejected() {
        let missing = std::env::current_exe().expect("test executable")
            .join("nonexistent-engine.exe");
        assert!(expand_long_path(&missing).is_err());
    }
}
