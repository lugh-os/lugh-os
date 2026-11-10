//! `Services.audio` — volume, devices and per-app streams of PipeWire, through
//! its PulseAudio layer (`pactl`).
//!
//! - State is read with `pactl --format=json list …` and kept current by one
//!   long-lived `pactl subscribe`: an event marks its class dirty, and after a
//!   short debounce only the dirty classes are read again and the difference
//!   is patched. Nothing runs while nothing changes.
//! - Writes never block `call`: they queue per target (the last value wins)
//!   and go out at most 30 times a second.
//! - A value the UI set itself is not patched back for 250 ms
//!   ([`model::ECHO_HOLD`]), then confirmed, so a dragged slider never jumps.
//! - No `pactl`, or no sound server: empty lists, volume 0, and a retry with
//!   backoff (1 s → 30 s).
//!
//! [`model`] is the pure, unit-tested core; [`pactl`] the I/O behind the
//! [`pactl::Audio`] trait.

use std::io;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::{Duration, Instant};

use serde_json::Value;
use tokio::sync::Notify;
use tokio::task::JoinHandle;

use super::{CallError, Context, Service, Sink, args};
use model::{Dirty, Held, Pending, View, Write};
use pactl::{Audio, Pactl};

mod model;
mod pactl;

const NAME: &str = "audio";
/// Events closer together than this are read as one change.
const DEBOUNCE: Duration = Duration::from_millis(50);
/// Minimum time between two write rounds (≤ 30 per second).
const WRITE_INTERVAL: Duration = Duration::from_millis(33);
/// A second full read shortly after connecting catches what changed before
/// `pactl subscribe` was listening.
const CATCH_UP: Duration = Duration::from_millis(300);
const BACKOFF_MIN: Duration = Duration::from_secs(1);
const BACKOFF_MAX: Duration = Duration::from_secs(30);
/// A connection that lasted this long was healthy: retry quickly after it.
const HEALTHY: Duration = Duration::from_secs(10);

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    Box::new(AudioService::spawn(
        Arc::new(Pactl::default()),
        ctx.sink.clone(),
        &ctx.runtime,
    ))
}

#[derive(Debug)]
struct Inner {
    sink: Sink,
    view: Mutex<View>,
    pending: Mutex<Pending>,
    /// Wakes the writer when a write is queued.
    writer_wake: Notify,
    /// Wakes the watcher when a hold was set (its confirm timer changed).
    watcher_wake: Notify,
}

fn lock<T>(m: &Mutex<T>) -> MutexGuard<'_, T> {
    m.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl Inner {
    /// Patches the UI with what changed since the last patch.
    fn publish(&self) {
        let patch = lock(&self.view).reconcile(Instant::now());
        if !patch.is_empty() {
            self.sink.patch(NAME, Value::Object(patch));
        }
    }
}

/// The `audio` service: two background tasks around one [`View`].
#[derive(Debug)]
struct AudioService {
    inner: Arc<Inner>,
    tasks: [JoinHandle<()>; 2],
}

impl AudioService {
    fn spawn(backend: Arc<dyn Audio>, sink: Sink, runtime: &tokio::runtime::Handle) -> Self {
        let inner = Arc::new(Inner {
            sink,
            view: Mutex::default(),
            pending: Mutex::default(),
            writer_wake: Notify::new(),
            watcher_wake: Notify::new(),
        });
        let tasks = [
            runtime.spawn(watch(Arc::clone(&inner), Arc::clone(&backend))),
            runtime.spawn(write_loop(Arc::clone(&inner), backend)),
        ];
        Self { inner, tasks }
    }

    fn queue(&self, write: Write) {
        lock(&self.inner.pending).push(write);
        self.inner.writer_wake.notify_one();
    }
}

impl Drop for AudioService {
    fn drop(&mut self) {
        // Dropping the tasks drops their `pactl` children, which kills them.
        for t in &self.tasks {
            t.abort();
        }
    }
}

fn unit(v: f64) -> f64 {
    if v.is_nan() { 0.0 } else { v.clamp(0.0, 1.0) }
}

impl Service for AudioService {
    fn name(&self) -> &'static str {
        NAME
    }

    fn state(&self) -> Value {
        lock(&self.inner.view).shown.to_json()
    }

    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        let now = Instant::now();
        match method {
            "setVolume" => {
                let v = unit(args::f64(a, 0)?);
                let mut view = lock(&self.inner.view);
                // Like the UI: moving the slider above zero unmutes.
                let unmute = v > 0.0 && view.shown.muted;
                view.ui_set(Held::Volume, now, |s| s.volume = v);
                if unmute {
                    view.ui_set(Held::Muted, now, |s| s.muted = false);
                }
                drop(view);
                self.queue(Write::Volume(v));
                if unmute {
                    self.queue(Write::Muted(false));
                }
            }
            "setMuted" => {
                let m = args::bool(a, 0)?;
                lock(&self.inner.view).ui_set(Held::Muted, now, |s| s.muted = m);
                self.queue(Write::Muted(m));
            }
            "setMicVolume" => {
                let v = unit(args::f64(a, 0)?);
                lock(&self.inner.view).ui_set(Held::MicVolume, now, |s| s.mic_volume = v);
                self.queue(Write::MicVolume(v));
            }
            "setMicMuted" => {
                let m = args::bool(a, 0)?;
                lock(&self.inner.view).ui_set(Held::MicMuted, now, |s| s.mic_muted = m);
                self.queue(Write::MicMuted(m));
            }
            "setOutput" => {
                let id = args::string(a, 0)?;
                if !lock(&self.inner.view).model.has_sink(&id) {
                    return Err(CallError::Failed(format!("no output `{id}`")));
                }
                self.queue(Write::Output(id));
            }
            "setInput" => {
                let id = args::string(a, 0)?;
                if !lock(&self.inner.view).model.has_source(&id) {
                    return Err(CallError::Failed(format!("no input `{id}`")));
                }
                self.queue(Write::Input(id));
            }
            "setStreamVolume" => {
                let (id, v) = (args::i64(a, 0)?, unit(args::f64(a, 1)?));
                let mut view = lock(&self.inner.view);
                if !view.model.has_stream(id) {
                    return Err(CallError::Failed(format!("no stream {id}")));
                }
                view.ui_set(Held::StreamVolume(id), now, |s| {
                    for st in s.streams.iter_mut().filter(|st| st.id == id) {
                        st.volume = v;
                    }
                });
                drop(view);
                self.queue(Write::StreamVolume(id, v));
            }
            "setStreamMuted" => {
                let (id, m) = (args::i64(a, 0)?, args::bool(a, 1)?);
                let mut view = lock(&self.inner.view);
                if !view.model.has_stream(id) {
                    return Err(CallError::Failed(format!("no stream {id}")));
                }
                view.ui_set(Held::StreamMuted(id), now, |s| {
                    for st in s.streams.iter_mut().filter(|st| st.id == id) {
                        st.muted = m;
                    }
                });
                drop(view);
                self.queue(Write::StreamMuted(id, m));
            }
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        }
        self.inner.watcher_wake.notify_one();
        Ok(Value::Null)
    }
}

/// Sends queued writes: at once when idle, then at most one round per
/// [`WRITE_INTERVAL`] with the latest value of each target.
async fn write_loop(inner: Arc<Inner>, backend: Arc<dyn Audio>) {
    loop {
        inner.writer_wake.notified().await;
        loop {
            let batch = lock(&inner.pending).take();
            if batch.is_empty() {
                break;
            }
            let next_round = tokio::time::Instant::now() + WRITE_INTERVAL;
            for write in batch {
                if let Err(e) = backend.write(write.clone()).await {
                    tracing::debug!(%e, ?write, "audio write failed");
                }
            }
            tokio::time::sleep_until(next_round).await;
        }
    }
}

async fn sleep_until(at: Option<Instant>) {
    match at {
        Some(at) => tokio::time::sleep_until(at.into()).await,
        None => std::future::pending().await,
    }
}

/// Keeps a connection to the sound server, forever.
async fn watch(inner: Arc<Inner>, backend: Arc<dyn Audio>) {
    let mut backoff = BACKOFF_MIN;
    loop {
        let started = Instant::now();
        let e = connected(&inner, backend.as_ref()).await;
        tracing::debug!(%e, "sound server unavailable; retrying");
        lock(&inner.view).model.clear();
        inner.publish();
        if started.elapsed() >= HEALTHY {
            backoff = BACKOFF_MIN;
        }
        tokio::time::sleep(backoff).await;
        backoff = (backoff * 2).min(BACKOFF_MAX);
    }
}

/// One connection: reads everything, then follows events until the server
/// goes away. Returns why it ended.
async fn connected(inner: &Inner, backend: &dyn Audio) -> io::Error {
    let mut events = match backend.subscribe() {
        Ok(rx) => rx,
        Err(e) => return e,
    };
    if let Err(e) = refresh(inner, backend, Dirty::ALL).await {
        return e;
    }
    let mut dirty = Dirty::ALL;
    let mut read_at = Some(Instant::now() + CATCH_UP);
    loop {
        let confirm_at = lock(&inner.view).holds.next_expiry();
        tokio::select! {
            event = events.recv() => match event {
                Some(d) => {
                    dirty.add(d);
                    read_at.get_or_insert_with(|| Instant::now() + DEBOUNCE);
                }
                None => return io::Error::other("pactl subscribe ended"),
            },
            () = sleep_until(read_at), if read_at.is_some() => {
                read_at = None;
                if let Err(e) = refresh(inner, backend, std::mem::take(&mut dirty)).await {
                    return e;
                }
            }
            () = sleep_until(confirm_at), if confirm_at.is_some() => inner.publish(),
            () = inner.watcher_wake.notified() => {}
        }
    }
}

/// Reads the dirty classes again and patches the difference.
async fn refresh(inner: &Inner, backend: &dyn Audio, dirty: Dirty) -> io::Result<()> {
    let mut fresh = Vec::with_capacity(4);
    for class in dirty.classes() {
        fresh.push(backend.read(class).await?);
    }
    {
        let mut view = lock(&inner.view);
        for data in fresh {
            view.model.apply(data);
        }
    }
    inner.publish();
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::model::{Class, ClassData, Defaults, Device};
    use super::pactl::BoxFuture;
    use super::*;
    use crate::services::Event;
    use tokio::sync::mpsc;

    /// A sound server in memory.
    #[derive(Debug, Default)]
    struct Fake {
        volume: Mutex<f64>,
        writes: Mutex<Vec<Write>>,
        events: Mutex<Option<mpsc::Sender<Dirty>>>,
    }

    impl Audio for Fake {
        fn read(&self, class: Class) -> BoxFuture<'_, io::Result<ClassData>> {
            Box::pin(async move {
                Ok(match class {
                    Class::Sinks => ClassData::Sinks(vec![Device {
                        id: "spk".into(),
                        name: "Speakers".into(),
                        icon: "speaker",
                        volume: *lock(&self.volume),
                        muted: false,
                    }]),
                    Class::Sources => ClassData::Sources(vec![]),
                    Class::Streams => ClassData::Streams(vec![]),
                    Class::Server => ClassData::Server(Defaults {
                        sink: "spk".into(),
                        source: String::new(),
                    }),
                })
            })
        }
        fn write(&self, write: Write) -> BoxFuture<'_, io::Result<()>> {
            Box::pin(async move {
                lock(&self.writes).push(write);
                Ok(())
            })
        }
        fn subscribe(&self) -> io::Result<mpsc::Receiver<Dirty>> {
            let (tx, rx) = mpsc::channel(8);
            *lock(&self.events) = Some(tx);
            Ok(rx)
        }
    }

    async fn next_patch(rx: &mut mpsc::UnboundedReceiver<Event>) -> Value {
        match tokio::time::timeout(Duration::from_secs(5), rx.recv()).await {
            Ok(Some(Event::Patch { data, .. })) => Value::Object(data),
            other => panic!("expected a patch, got {other:?}"),
        }
    }

    #[tokio::test]
    async fn follows_the_server_and_does_not_echo_its_own_writes() {
        let fake = Arc::new(Fake::default());
        *lock(&fake.volume) = 0.4;
        let (tx, mut rx) = mpsc::unbounded_channel();
        let sink = Sink::new(move |e| {
            let _ = tx.send(e);
        });
        let backend: Arc<dyn Audio> = fake.clone();
        let svc = AudioService::spawn(backend, sink, &tokio::runtime::Handle::current());

        // First read: the whole visible state.
        let first = next_patch(&mut rx).await;
        assert_eq!(first["volume"], 0.4);
        assert_eq!(first["outputs"][0]["devId"], "spk");
        assert_eq!(svc.state()["outputs"][0]["active"], true);

        // Someone else changes the volume: one patch, one key.
        *lock(&fake.volume) = 0.6;
        let events = lock(&fake.events).clone();
        let Some(events) = events else {
            panic!("not subscribed")
        };
        assert!(events.send(Dirty::of(&[Class::Sinks])).await.is_ok());
        assert_eq!(
            next_patch(&mut rx).await,
            serde_json::json!({ "volume": 0.6 })
        );

        // The UI drags: the last value is written, nothing is echoed, and the
        // state already shows what the UI shows.
        for v in [0.61, 0.7, 0.8] {
            assert_eq!(svc.call("setVolume", &[v.into()]), Ok(Value::Null));
        }
        assert_eq!(svc.state()["volume"], 0.8);
        *lock(&fake.volume) = 0.8;
        assert!(events.send(Dirty::of(&[Class::Sinks])).await.is_ok());
        tokio::time::sleep(model::ECHO_HOLD + Duration::from_millis(150)).await;
        assert!(rx.try_recv().is_err(), "own change was echoed");
        let writes = lock(&fake.writes).clone();
        assert!(writes.len() <= 3, "writes were not coalesced: {writes:?}");
        assert_eq!(writes.last(), Some(&Write::Volume(0.8)));

        // Bad calls are refused without side effects.
        assert!(matches!(
            svc.call("setOutput", &["nope".into()]),
            Err(CallError::Failed(_))
        ));
        assert!(matches!(
            svc.call("setVolume", &[]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            svc.call("explode", &[]),
            Err(CallError::UnknownMethod(_))
        ));

        // The server goes away: everything empties.
        drop(events);
        *lock(&fake.events) = None;
        let gone = next_patch(&mut rx).await;
        assert_eq!(gone["outputs"], serde_json::json!([]));
        assert_eq!(gone["volume"], 0.0);
    }
}
