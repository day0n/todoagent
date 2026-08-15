use std::fs::{File, OpenOptions};
use std::io::{self, Write};
use std::os::unix::fs::{MetadataExt, OpenOptionsExt, PermissionsExt};
use std::path::Path;

use nix::errno::Errno;
use nix::fcntl::{Flock, FlockArg};

const LOCK_FILE_NAME: &str = ".engine-owner.lock";

/// Holds exclusive ownership of one TodoAgent data directory.
///
/// The lock file deliberately remains on disk after shutdown. Removing it
/// would let another process create and lock a different inode while an older
/// process still owns the original one. The kernel releases the advisory lock
/// automatically when this file descriptor is closed, including after a
/// crash. `O_CLOEXEC` prevents terminal children from extending its lifetime.
#[derive(Debug)]
pub struct DataDirectoryLease {
    _lock: Flock<File>,
}

impl DataDirectoryLease {
    pub fn acquire(data_directory: &Path) -> io::Result<Self> {
        let path = data_directory.join(LOCK_FILE_NAME);
        let file = OpenOptions::new()
            .read(true)
            .write(true)
            .create(true)
            .mode(0o600)
            .custom_flags(nix::libc::O_NOFOLLOW | nix::libc::O_CLOEXEC)
            .open(&path)?;
        let metadata = file.metadata()?;
        let current_uid = unsafe { nix::libc::geteuid() };
        if !metadata.is_file()
            || metadata.uid() != current_uid
            || metadata.nlink() != 1
            || metadata.permissions().mode() & 0o777 != 0o600
        {
            return Err(io::Error::new(
                io::ErrorKind::PermissionDenied,
                "Engine owner lock must be a current-user mode 0600 regular file with one link",
            ));
        }

        let mut lock =
            Flock::lock(file, FlockArg::LockExclusiveNonblock).map_err(|(_file, error)| {
                if error == Errno::EWOULDBLOCK {
                    io::Error::new(
                        io::ErrorKind::AlreadyExists,
                        "TodoAgent data directory is already owned by another Engine",
                    )
                } else {
                    io::Error::from_raw_os_error(error as i32)
                }
            })?;

        // This is diagnostic owner metadata, not the ownership primitive. A
        // stale PID is harmless because only the kernel-held flock is trusted.
        lock.set_len(0)?;
        writeln!(lock, "{}", std::process::id())?;
        lock.sync_data()?;

        Ok(Self { _lock: lock })
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;
    use std::os::unix::fs::symlink;

    fn private_directory() -> tempfile::TempDir {
        let directory = tempfile::tempdir().unwrap();
        fs::set_permissions(directory.path(), fs::Permissions::from_mode(0o700)).unwrap();
        directory
    }

    #[test]
    fn lease_is_exclusive_and_released_on_drop() {
        let directory = private_directory();
        let first = DataDirectoryLease::acquire(directory.path()).unwrap();

        let second = DataDirectoryLease::acquire(directory.path()).unwrap_err();
        assert_eq!(second.kind(), io::ErrorKind::AlreadyExists);
        assert!(second.to_string().contains("already owned"));

        drop(first);
        DataDirectoryLease::acquire(directory.path()).unwrap();
    }

    #[test]
    fn lease_rejects_a_symlink_without_touching_its_target() {
        let directory = private_directory();
        let target = directory.path().join("target");
        fs::write(&target, b"do not touch").unwrap();
        fs::set_permissions(&target, fs::Permissions::from_mode(0o600)).unwrap();
        symlink(&target, directory.path().join(LOCK_FILE_NAME)).unwrap();

        assert!(DataDirectoryLease::acquire(directory.path()).is_err());
        assert_eq!(fs::read(target).unwrap(), b"do not touch");
    }

    #[test]
    fn lease_rejects_an_insecure_existing_file() {
        let directory = private_directory();
        let path = directory.path().join(LOCK_FILE_NAME);
        fs::write(&path, b"stale").unwrap();
        fs::set_permissions(&path, fs::Permissions::from_mode(0o644)).unwrap();

        let error = DataDirectoryLease::acquire(directory.path()).unwrap_err();
        assert_eq!(error.kind(), io::ErrorKind::PermissionDenied);
    }
}
