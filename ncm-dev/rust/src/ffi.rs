// SPDX-License-Identifier: GPL-3.0-only
//! Polling C ABI with integer handles, no callbacks or persistent keys.
//! Explicit start owns a worker/runtime; linking/ABI queries do no network I/O.
use crate::{
    Cause, Error, ExistingIdentity, NcmConnector, RelayConnector, RpPairingFile, Session, Stage,
    VerifiedPeerIdentity,
};
use std::{
    collections::HashMap,
    slice,
    sync::{
        Arc, Mutex, OnceLock,
        atomic::{AtomicBool, AtomicU64, AtomicUsize, Ordering},
    },
};
use tokio::sync::{OwnedSemaphorePermit, Semaphore, mpsc, watch};
use zeroize::Zeroizing;
const INVALID: i32 = 1;
const BUSY: i32 = 2;
const CLOSED: i32 = 3;
const EMPTY: i32 = 4;
const SMALL: i32 = 5;
const NOT_READY: i32 = 6;
const SCREEN: u32 = 1;
const MEDIA: u32 = 2;
const INPUT: u32 = 4;
const VERIFY: u32 = 8;
#[repr(C)]
pub struct Bytes {
    data: *const u8,
    size: usize,
}
#[repr(C)]
pub struct Identity {
    seed: Bytes,
    controller_id: Bytes,
    peer_id: Bytes,
    peer_public_key: Bytes,
    alt_irk: Bytes,
    peer_udid: Bytes,
    peer_model: Bytes,
}
#[repr(C)]
pub struct Config {
    abi: u32,
    interface_index: u32,
    generation: u32,
    endpoint_index: u32,
    permissions: u32,
}
#[repr(C)]
#[derive(Default, Clone, Copy)]
pub struct EventHeader {
    request_id: u64,
    kind: u32,
    stage: u32,
    cause: u32,
    reserved: u32,
    size: usize,
}
struct Event {
    header: EventHeader,
    data: Vec<u8>,
    credit: Option<OwnedSemaphorePermit>,
}
impl Event {
    fn ok(id: u64, kind: u32, data: Vec<u8>) -> Self {
        Self {
            header: EventHeader {
                request_id: id,
                kind,
                size: data.len(),
                ..Default::default()
            },
            data,
            credit: None,
        }
    }
    fn failed(id: u64, e: Error) -> Self {
        Self {
            header: EventHeader {
                request_id: id,
                kind: 3,
                stage: e.stage as u32 + 1,
                cause: e.cause as u32 + 1,
                ..Default::default()
            },
            data: Vec::new(),
            credit: None,
        }
    }
}
#[derive(Clone, Copy)]
struct Request {
    id: u64,
    action: u32,
    x: u16,
    y: u16,
}
struct Receiver {
    pending: Option<Event>,
    queue: mpsc::Receiver<Event>,
}
struct Entry {
    submit: Mutex<(u64, mpsc::Sender<Request>)>,
    receive: Mutex<Receiver>,
    cancel: watch::Sender<bool>,
    ready: AtomicBool,
    done: AtomicBool,
}
static ENTRIES: OnceLock<Mutex<HashMap<u64, Arc<Entry>>>> = OnceLock::new();
static NEXT: AtomicU64 = AtomicU64::new(1);
static WORKERS: AtomicUsize = AtomicUsize::new(0);
fn registry() -> &'static Mutex<HashMap<u64, Arc<Entry>>> {
    ENTRIES.get_or_init(|| Mutex::new(HashMap::new()))
}
fn get(id: u64) -> Option<Arc<Entry>> {
    registry().lock().ok()?.get(&id).cloned()
}
fn protect(f: impl FnOnce() -> i32) -> i32 {
    std::panic::catch_unwind(std::panic::AssertUnwindSafe(f)).unwrap_or(INVALID)
}
unsafe fn bytes<'a>(b: &Bytes, limit: usize) -> Result<&'a [u8], i32> {
    if b.data.is_null() || b.size == 0 || b.size > limit {
        return Err(INVALID);
    }
    Ok(unsafe { slice::from_raw_parts(b.data, b.size) })
}
unsafe fn text(b: &Bytes) -> Result<String, i32> {
    let b = unsafe { bytes(b, 256) }?;
    if b.contains(&0) {
        return Err(INVALID);
    }
    std::str::from_utf8(b)
        .map(str::to_owned)
        .map_err(|_| INVALID)
}
unsafe fn identity(raw: &Identity) -> Result<ExistingIdentity, i32> {
    let seed = Zeroizing::new(
        <[u8; 32]>::try_from(unsafe { bytes(&raw.seed, 32) }?).map_err(|_| INVALID)?,
    );
    let key = ed25519_dalek::SigningKey::from_bytes(&seed);
    let alt = unsafe { bytes(&raw.alt_irk, 16) }?.to_vec();
    if alt.len() != 16 {
        return Err(INVALID);
    }
    let peer_id = unsafe { text(&raw.peer_id) }?;
    let id = ExistingIdentity {
        controller: RpPairingFile {
            identifier: unsafe { text(&raw.controller_id) }?,
            e_public_key: key.verifying_key(),
            e_private_key: key,
            alt_irk: Some(alt.clone()),
        },
        peer: VerifiedPeerIdentity {
            pairing_identifier: peer_id.clone(),
            long_term_public_key: unsafe { bytes(&raw.peer_public_key, 32) }?
                .try_into()
                .map_err(|_| INVALID)?,
            peer: idevice::remote_pairing::PeerDevice {
                account_id: peer_id,
                alt_irk: alt,
                name: String::new(),
                remotepairing_udid: unsafe { text(&raw.peer_udid) }?,
                model: unsafe { text(&raw.peer_model) }?,
            },
        },
    };
    id.validate().map_err(|_| INVALID)?;
    Ok(id)
}
fn launch(
    connector: impl NcmConnector + 'static,
    mut identity: ExistingIdentity,
    permissions: u32,
) -> Result<u64, i32> {
    WORKERS
        .fetch_update(Ordering::SeqCst, Ordering::SeqCst, |n| {
            (n < 2).then_some(n + 1)
        })
        .map_err(|_| BUSY)?;
    let (tx, mut rx) = mpsc::channel::<Request>(1);
    let (events, queue) = mpsc::channel(1);
    let (cancel, mut cancelled) = watch::channel(false);
    let entry = Arc::new(Entry {
        submit: Mutex::new((0, tx)),
        receive: Mutex::new(Receiver {
            pending: None,
            queue,
        }),
        cancel,
        ready: AtomicBool::new(false),
        done: AtomicBool::new(false),
    });
    let id = NEXT.fetch_add(1, Ordering::SeqCst);
    if id == 0 {
        WORKERS.fetch_sub(1, Ordering::SeqCst);
        return Err(BUSY);
    }
    {
        let mut entries = registry().lock().map_err(|_| INVALID)?;
        if entries.len() >= 2 {
            WORKERS.fetch_sub(1, Ordering::SeqCst);
            return Err(BUSY);
        }
        entries.insert(id, entry.clone());
    }
    let worker_entry = entry.clone();
    let spawn = std::thread::Builder::new()
        .name("ncm-backend".into())
        .spawn(move || {
            struct Finished(Arc<Entry>);
            impl Drop for Finished {
                fn drop(&mut self) {
                    self.0.done.store(true, Ordering::SeqCst);
                    self.0.ready.store(false, Ordering::SeqCst);
                    WORKERS.fetch_sub(1, Ordering::SeqCst);
                }
            }
            let _finished = Finished(worker_entry.clone());
            let Ok(runtime) = tokio::runtime::Builder::new_current_thread()
                .enable_all()
                .build()
            else {
                return;
            };
            runtime.block_on(async {
                let work = async {
                    let connection = Session::connect(&connector, &mut identity).await;
                    drop(identity); // long-term signing seed no longer needed after PairVerify.
                    let mut session = match connection {
                        Ok(s) => s,
                        Err(e) => {
                            let _ = events.send(Event::failed(0, e)).await;
                            return;
                        }
                    };
                    let credit = Arc::new(Semaphore::new(1));
                    let names = session
                        .services()
                        .unwrap_or_default()
                        .into_iter()
                        .map(|s| s.name)
                        .collect::<Vec<_>>();
                    worker_entry.ready.store(true, Ordering::SeqCst);
                    let mut ready = Event::ok(0, 1, serde_json::to_vec(&names).unwrap_or_default());
                    ready.credit = credit.clone().acquire_owned().await.ok();
                    if events.send(ready).await.is_err() {
                        return;
                    }
                    while let Some(request) = rx.recv().await {
                        let permit = credit.clone().acquire_owned().await.ok();
                        let mut response = execute(&mut session, request, permissions).await;
                        response.credit = permit;
                        if events.send(response).await.is_err() {
                            break;
                        }
                    }
                };
                tokio::select! {biased;_ = cancelled.changed()=>{},_ = work=>{}}
            });
            // Dropping this owned runtime cancels every spawned adapter/media task;
            // all native sockets are owned by those tasks, never leaked to a global runtime.
        });
    if spawn.is_err() {
        registry().lock().map_err(|_| INVALID)?.remove(&id);
        WORKERS.fetch_sub(1, Ordering::SeqCst);
        return Err(INVALID);
    }
    Ok(id)
}
async fn execute(session: &mut Session, r: Request, permissions: u32) -> Event {
    let required = match r.action {
        1 => 0,
        2 => SCREEN,
        3 => MEDIA,
        4 => INPUT,
        _ => u32::MAX,
    };
    if permissions & required != required {
        return Event::failed(
            r.id,
            Error {
                stage: match r.action {
                    2 => Stage::Screenshot,
                    3 => Stage::Media,
                    _ => Stage::Input,
                },
                cause: Cause::Unprepared,
            },
        );
    }
    let result = match r.action {
        1 => session
            .check_developer_readiness()
            .await
            .map(|_| Event::ok(r.id, 2, Vec::new())),
        2 => session
            .screenshot()
            .await
            .map(|s| Event::ok(r.id, 4, s.png)),
        3 => session
            .start_touch_media()
            .await
            .map(|_| Event::ok(r.id, 2, Vec::new())),
        4 => session
            .tap(r.x, r.y)
            .await
            .map(|_| Event::ok(r.id, 2, Vec::new())),
        _ => Err(Error {
            stage: Stage::Closed,
            cause: Cause::InvalidParameters,
        }),
    };
    result.unwrap_or_else(|e| Event::failed(r.id, e))
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_abi() -> u32 {
    1
}
/// # Safety
/// Non-null pointers must reference valid, readable C structs/byte buffers for
/// this call; handle must be writable. Bytes are copied synchronously.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_start(
    config: *const Config,
    raw: *const Identity,
    handle: *mut u64,
) -> i32 {
    protect(|| {
        if config.is_null() || raw.is_null() || handle.is_null() {
            return INVALID;
        }
        unsafe { *handle = 0 };
        let config = unsafe { &*config };
        if config.abi != 1
            || config.endpoint_index >= 16
            || config.permissions & VERIFY == 0
            || config.permissions & !15 != 0
        {
            return INVALID;
        }
        let id = match unsafe { identity(&*raw) } {
            Ok(id) => id,
            Err(e) => return e,
        };
        let connector = match RelayConnector::new(
            config.interface_index,
            config.generation,
            config.endpoint_index as u8,
        ) {
            Ok(c) => c,
            Err(_) => return INVALID,
        };
        match launch(connector, id, config.permissions) {
            Ok(id) => {
                unsafe { *handle = id };
                0
            }
            Err(e) => e,
        }
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_submit(handle: u64, id: u64, action: u32, x: u16, y: u16) -> i32 {
    protect(|| {
        if id == 0 || !(1..=4).contains(&action) {
            return INVALID;
        }
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        if entry.done.load(Ordering::SeqCst) {
            return CLOSED;
        }
        if !entry.ready.load(Ordering::SeqCst) {
            return NOT_READY;
        }
        let Ok(mut submit) = entry.submit.lock() else {
            return INVALID;
        };
        if id <= submit.0 {
            return INVALID;
        }
        match submit.1.try_send(Request { id, action, x, y }) {
            Ok(()) => {
                submit.0 = id;
                0
            }
            Err(mpsc::error::TrySendError::Full(_)) => BUSY,
            Err(_) => CLOSED,
        }
    })
}
/// # Safety
/// header must be writable; non-null buffer must be writable for capacity bytes.
/// Passing null/zero is a size query. A SMALL result retains the event.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_backend_poll(
    handle: u64,
    header: *mut EventHeader,
    buffer: *mut u8,
    capacity: usize,
) -> i32 {
    protect(|| {
        if header.is_null() || capacity > 64 * 1024 * 1024 {
            return INVALID;
        }
        unsafe { *header = EventHeader::default() };
        let Some(entry) = get(handle) else {
            return CLOSED;
        };
        let Ok(mut receive) = entry.receive.lock() else {
            return INVALID;
        };
        if receive.pending.is_none() {
            match receive.queue.try_recv() {
                Ok(e) => receive.pending = Some(e),
                Err(mpsc::error::TryRecvError::Empty) => {
                    return if entry.done.load(Ordering::SeqCst) {
                        CLOSED
                    } else {
                        EMPTY
                    };
                }
                Err(_) => return CLOSED,
            }
        }
        let e = receive.pending.as_ref().unwrap();
        unsafe { *header = e.header };
        if e.data.len() > capacity || (!e.data.is_empty() && buffer.is_null()) {
            return SMALL;
        }
        if !e.data.is_empty() {
            unsafe { std::ptr::copy_nonoverlapping(e.data.as_ptr(), buffer, e.data.len()) };
        }
        receive.pending.take();
        0
    })
}
#[unsafe(no_mangle)]
pub extern "C" fn ncm_backend_close(handle: u64) {
    let _ = protect(|| {
        if let Some(entry) = registry().lock().ok().and_then(|mut r| r.remove(&handle)) {
            let _ = entry.cancel.send(true);
        }
        0
    });
}
#[cfg(any(test, feature = "offline-fixtures"))]
fn fixture_identity() -> ExistingIdentity {
    let key = ed25519_dalek::SigningKey::from_bytes(&[0x42; 32]);
    ExistingIdentity {
        controller: RpPairingFile {
            identifier: "SYNTHETIC-CONTROLLER".into(),
            e_public_key: key.verifying_key(),
            e_private_key: key,
            alt_irk: Some(vec![0x33; 16]),
        },
        peer: VerifiedPeerIdentity {
            pairing_identifier: "SYNTHETIC-PEER".into(),
            long_term_public_key: ed25519_dalek::SigningKey::from_bytes(&[0x44; 32])
                .verifying_key()
                .to_bytes(),
            peer: idevice::remote_pairing::PeerDevice {
                account_id: "SYNTHETIC-PEER".into(),
                alt_irk: vec![0x33; 16],
                model: "iPhone-SYNTHETIC".into(),
                name: String::new(),
                remotepairing_udid: "SYNTHETIC-UDID".into(),
            },
        },
    }
}
#[cfg(feature = "offline-fixtures")]
/// # Safety
/// handle must be writable. Target is restricted to IPv4 loopback.
#[unsafe(no_mangle)]
pub unsafe extern "C" fn ncm_test_start_loopback(port: u16, handle: *mut u64) -> i32 {
    protect(|| {
        if handle.is_null() || port == 0 {
            return INVALID;
        }
        unsafe { *handle = 0 };
        match launch(RelayConnector::loopback(port), fixture_identity(), VERIFY) {
            Ok(id) => {
                unsafe { *handle = id };
                0
            }
            Err(e) => e,
        }
    })
}
#[cfg(test)]
mod tests {
    static TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());
    use super::*;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    #[tokio::test]
    async fn polling_keeps_payload_until_sufficient_buffer_and_close_revokes_handle() {
        let _test = TEST_LOCK.lock().await;
        let (send, queue) = mpsc::channel(1);
        let (tx, _) = mpsc::channel(1);
        let (cancel, _) = watch::channel(false);
        let entry = Arc::new(Entry {
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: AtomicBool::new(false),
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry);
        send.try_send(Event::ok(9, 4, vec![1, 2, 3]))
            .unwrap_or_else(|_| panic!("queue"));
        let mut h = EventHeader::default();
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut h, std::ptr::null_mut(), 0) },
            SMALL
        );
        assert_eq!((h.request_id, h.size), (9, 3));
        let mut output = [0; 3];
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut h, output.as_mut_ptr(), 3) },
            0
        );
        assert_eq!(output, [1, 2, 3]);
        ncm_backend_close(id);
        assert_eq!(
            unsafe { ncm_backend_poll(id, &mut h, std::ptr::null_mut(), 0) },
            CLOSED
        );
        ncm_backend_close(id);
    }
    #[tokio::test]
    async fn command_queue_is_bounded_and_duplicate_ids_are_rejected() {
        let _test = TEST_LOCK.lock().await;
        let (tx, mut rx) = mpsc::channel(1);
        let (_send, queue) = mpsc::channel(1);
        let (cancel, _) = watch::channel(false);
        let entry = Arc::new(Entry {
            submit: Mutex::new((0, tx)),
            receive: Mutex::new(Receiver {
                pending: None,
                queue,
            }),
            cancel,
            ready: AtomicBool::new(true),
            done: AtomicBool::new(false),
        });
        let id = NEXT.fetch_add(1, Ordering::SeqCst);
        registry().lock().unwrap().insert(id, entry);
        assert_eq!(ncm_backend_submit(id, 1, 2, 0, 0), 0);
        assert_eq!(ncm_backend_submit(id, 1, 2, 0, 0), INVALID);
        assert_eq!(ncm_backend_submit(id, 2, 2, 0, 0), BUSY);
        assert_eq!(rx.try_recv().unwrap().id, 1);
        assert_eq!(ncm_backend_submit(id, 2, 2, 0, 0), 0);
        ncm_backend_close(id);
    }
    #[tokio::test]
    async fn closing_one_handle_preserves_another_sessions_reply() {
        let _test = TEST_LOCK.lock().await;
        let mut ids = Vec::new();
        for value in [11, 22] {
            let (tx, _) = mpsc::channel(1);
            let (events, queue) = mpsc::channel(1);
            let (cancel, _) = watch::channel(false);
            let entry = Arc::new(Entry {
                submit: Mutex::new((0, tx)),
                receive: Mutex::new(Receiver {
                    pending: None,
                    queue,
                }),
                cancel,
                ready: AtomicBool::new(true),
                done: AtomicBool::new(false),
            });
            let id = NEXT.fetch_add(1, Ordering::SeqCst);
            registry().lock().unwrap().insert(id, entry);
            events
                .try_send(Event::ok(1, 4, vec![value]))
                .unwrap_or_else(|_| panic!("fixture queue"));
            ids.push(id);
        }
        ncm_backend_close(ids[0]);
        let mut h = EventHeader::default();
        let mut byte = [0];
        assert_eq!(
            unsafe { ncm_backend_poll(ids[0], &mut h, byte.as_mut_ptr(), 1) },
            CLOSED
        );
        assert_eq!(
            unsafe { ncm_backend_poll(ids[1], &mut h, byte.as_mut_ptr(), 1) },
            0
        );
        assert_eq!(byte, [22]);
        ncm_backend_close(ids[1]);
    }
    #[tokio::test]
    async fn ffi_worker_reports_real_handshake_failure_and_cancels_pending_read() {
        let _test = TEST_LOCK.lock().await;
        struct Connector(Mutex<Option<tokio::io::DuplexStream>>);
        impl NcmConnector for Connector {
            fn connect(&self, _: crate::Purpose) -> crate::DialFuture<'_> {
                Box::pin(async move {
                    Ok(Box::new(self.0.lock().unwrap().take().unwrap()) as crate::Stream)
                })
            }
        }
        let (stream, mut peer) = tokio::io::duplex(4096);
        let id = launch(
            Connector(Mutex::new(Some(stream))),
            fixture_identity(),
            VERIFY,
        )
        .unwrap();
        let mut magic = [0; 9];
        peer.read_exact(&mut magic).await.unwrap();
        assert_eq!(&magic, b"RPPairing");
        peer.write_all(b"bad").await.unwrap();
        peer.shutdown().await.unwrap();
        let mut h = EventHeader::default();
        for _ in 0..100 {
            let r = unsafe { ncm_backend_poll(id, &mut h, std::ptr::null_mut(), 0) };
            if r == 0 {
                break;
            }
            assert_eq!(r, EMPTY);
            tokio::time::sleep(std::time::Duration::from_millis(2)).await;
        }
        assert_eq!(h.kind, 3);
        assert_eq!(h.stage, Stage::PairVerify as u32 + 1);
        ncm_backend_close(id);
        let (stream, mut peer) = tokio::io::duplex(4096);
        let id = launch(
            Connector(Mutex::new(Some(stream))),
            fixture_identity(),
            VERIFY,
        )
        .unwrap();
        peer.read_exact(&mut magic).await.unwrap();
        ncm_backend_close(id);
        let mut drain = Vec::new();
        tokio::time::timeout(
            std::time::Duration::from_secs(1),
            peer.read_to_end(&mut drain),
        )
        .await
        .unwrap()
        .unwrap();
        assert_eq!(ncm_backend_submit(id, 1, 2, 0, 0), CLOSED);
    }
}
