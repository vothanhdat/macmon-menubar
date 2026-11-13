//! The connection to the running app.

use std::ffi::CStr;
use std::io::{BufRead, BufReader, ErrorKind, Write};
use std::os::fd::AsRawFd;
use std::os::unix::net::UnixStream;
use std::path::PathBuf;
use std::time::Duration;

use crate::proto::Request;

/// The app's data folder, as AppPaths.dataDirectory in TerminalServer.swift works it out.
fn data_dir() -> PathBuf {
    if let Some(d) = std::env::var_os("MACMON_INDICATOR_HISTORY_DIR") {
        return PathBuf::from(d);
    }
    let home = std::env::var_os("HOME").map(PathBuf::from).or_else(std::env::home_dir).unwrap_or_default();
    home.join("Library/Application Support/MacMonIndicator")
}

/// As AppPaths.socketPath: `terminal.sock` in the data folder, or the per-user temporary folder
/// when that path is too long for a socket address (104 bytes).
pub fn socket_path() -> PathBuf {
    let p = data_dir().join("terminal.sock");
    if p.as_os_str().len() < 104 {
        return p;
    }
    let mut buf = [0 as libc::c_char; 1024];
    // SAFETY: confstr writes at most buf.len() bytes, NUL-terminated.
    let n = unsafe { libc::confstr(libc::_CS_DARWIN_USER_TEMP_DIR, buf.as_mut_ptr(), buf.len()) };
    let tmp = if n > 0 {
        // SAFETY: NUL-terminated by confstr.
        PathBuf::from(unsafe { CStr::from_ptr(buf.as_ptr()) }.to_string_lossy().into_owned())
    } else {
        std::env::temp_dir()
    };
    tmp.join("macmon-indicator.sock")
}

pub struct Client {
    reader: BufReader<UnixStream>,
    writer: UnixStream,
}

impl Client {
    pub fn connect() -> Result<Client, String> {
        let path = socket_path();
        let stream = UnixStream::connect(&path).map_err(|e| match e.kind() {
            ErrorKind::NotFound | ErrorKind::ConnectionRefused => {
                "MacMon Indicator isn't running on this Mac (or it's a version without terminal support).".to_string()
            }
            _ => format!("Can't connect to MacMon Indicator ({}): {e}", path.display()),
        })?;
        // Only talk to the app running as you.
        let (mut uid, mut gid) = (0, 0);
        // SAFETY: a connected socket and two out-parameters.
        let ok = unsafe { libc::getpeereid(stream.as_raw_fd(), &mut uid, &mut gid) } == 0;
        if !ok || uid != unsafe { libc::getuid() } {
            return Err(format!("{} belongs to another user.", path.display()));
        }
        stream.set_read_timeout(Some(Duration::from_secs(5))).ok();
        stream.set_write_timeout(Some(Duration::from_secs(2))).ok();
        let writer = stream.try_clone().map_err(|e| e.to_string())?;
        Ok(Client { reader: BufReader::new(stream), writer })
    }

    /// Sends a request and returns the reply line.
    pub fn request(&mut self, req: &Request) -> Result<String, String> {
        let mut line = serde_json::to_string(req).map_err(|e| e.to_string())?;
        line.push('\n');
        self.writer.write_all(line.as_bytes()).map_err(|e| format!("Lost the connection to MacMon Indicator: {e}"))?;
        let mut reply = String::new();
        match self.reader.read_line(&mut reply) {
            Ok(0) => Err("MacMon Indicator closed the connection (it quit or restarted).".into()),
            Ok(_) => Ok(reply),
            Err(e) => Err(format!("No answer from MacMon Indicator: {e}")),
        }
    }
}
