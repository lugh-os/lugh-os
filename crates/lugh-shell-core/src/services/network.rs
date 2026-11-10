//! `Services.network` — Wi-Fi and connectivity through NetworkManager.
//!
//! Three layers:
//! - [`model`]: the pure state machine and the patch publisher (unit-tested,
//!   no I/O);
//! - [`nm`]: NetworkManager and BlueZ over the system bus, signal-driven;
//! - this file: the [`Service`] and the small driver task that connects them.
//!
//! Nothing polls. The driver sleeps until a D-Bus signal, a UI call or one of
//! its own one-shot timers (scan 10 s, connect 30 s, strength flush ≤ 2 s)
//! arrives. When NetworkManager is missing or restarts, the state says
//! `wifiAvailable: false` / `connected: false` and recovers by itself.

use std::future::Future;
use std::sync::{Arc, Mutex, MutexGuard};
use std::time::Instant;

use serde_json::Value;
use tokio::sync::mpsc::{UnboundedReceiver, UnboundedSender, unbounded_channel};

use super::{CallError, Context, Event, Service, Sink, args};

mod model;
mod nm;

use model::{Command, Effect, Input, Machine, Publisher, Request};

const NAME: &str = "network";

/// Executes [`Request`]s against the system. The answer is what the machine
/// must hear about it (often nothing: NetworkManager's signals tell the rest).
trait Backend: Send + Sync + 'static {
    fn run(&self, req: Request) -> impl Future<Output = Vec<Input>> + Send;
}

/// Starts the service (see `services` module docs for the rules).
#[must_use]
pub fn start(ctx: &Context) -> Box<dyn Service> {
    let backend = Arc::new(nm::Nm::default());
    let service = NetworkService::spawn(&ctx.runtime, ctx.sink.clone(), Arc::clone(&backend));
    ctx.runtime.spawn(nm::watch(backend, service.tx.clone()));
    Box::new(service)
}

#[derive(Debug)]
struct NetworkService {
    tx: UnboundedSender<Input>,
    publisher: Arc<Mutex<Publisher>>,
}

fn lock(p: &Mutex<Publisher>) -> MutexGuard<'_, Publisher> {
    p.lock().unwrap_or_else(std::sync::PoisonError::into_inner)
}

impl NetworkService {
    fn spawn<B: Backend>(runtime: &tokio::runtime::Handle, sink: Sink, backend: Arc<B>) -> Self {
        let (tx, rx) = unbounded_channel();
        let publisher = Arc::new(Mutex::new(Publisher::default()));
        // Requests run one at a time, in order (off then on stays off-on).
        let (req_tx, req_rx) = unbounded_channel();
        runtime.spawn(run_requests(backend, req_rx, tx.clone()));
        runtime.spawn(drive(rx, tx.clone(), req_tx, Arc::clone(&publisher), sink));
        Self { tx, publisher }
    }
}

impl Service for NetworkService {
    fn name(&self) -> &'static str {
        NAME
    }

    fn state(&self) -> Value {
        lock(&self.publisher).published().to_json()
    }

    fn call(&self, method: &str, a: &[Value]) -> Result<Value, CallError> {
        let command = match method {
            "setWifiEnabled" => Command::SetWifiEnabled(args::bool(a, 0)?),
            "setAirplaneMode" => Command::SetAirplaneMode(args::bool(a, 0)?),
            "rescan" => Command::Rescan,
            "connectTo" => Command::Connect {
                ssid: args::string(a, 0)?,
                password: args::string_or_empty(a, 1),
            },
            "disconnect" => Command::Disconnect,
            other => return Err(CallError::UnknownMethod(format!("{NAME}.{other}"))),
        };
        self.tx
            .send(Input::Command(command))
            .map_err(|_| CallError::Failed("network service stopped".to_owned()))?;
        Ok(Value::Null)
    }
}

async fn run_requests<B: Backend>(
    backend: Arc<B>,
    mut requests: UnboundedReceiver<Request>,
    tx: UnboundedSender<Input>,
) {
    while let Some(req) = requests.recv().await {
        for input in backend.run(req).await {
            if tx.send(input).is_err() {
                return;
            }
        }
    }
}

/// The one task that owns the machine: applies inputs, starts effects and
/// publishes what changed.
async fn drive(
    mut rx: UnboundedReceiver<Input>,
    tx: UnboundedSender<Input>,
    requests: UnboundedSender<Request>,
    publisher: Arc<Mutex<Publisher>>,
    sink: Sink,
) {
    let mut machine = Machine::default();
    // When a held-back strength patch is due.
    let mut flush: Option<tokio::time::Instant> = None;
    loop {
        let mut next = tokio::select! {
            input = rx.recv() => match input {
                Some(input) => Some(input),
                None => return,
            },
            () = async {
                match flush {
                    Some(at) => tokio::time::sleep_until(at).await,
                    None => std::future::pending().await,
                }
            } => None,
        };
        let mut force: Vec<&str> = Vec::new();
        // Bursts (a scan's worth of access points) become one patch.
        while let Some(input) = next {
            for effect in machine.handle(input) {
                match effect {
                    Effect::Io(req) => {
                        let _ = requests.send(req);
                    }
                    Effect::Timer(kind, id, after) => {
                        let tx = tx.clone();
                        tokio::spawn(async move {
                            tokio::time::sleep(after).await;
                            let _ = tx.send(Input::Timeout(kind, id));
                        });
                    }
                    Effect::Republish(keys) => force.extend(keys),
                }
            }
            next = rx.try_recv().ok();
        }
        let (patch, wait) = lock(&publisher).update(machine.view(), Instant::now(), &force);
        flush = wait.map(|w| tokio::time::Instant::now() + w);
        if let Some(data) = patch {
            sink.send(Event::Patch {
                service: NAME,
                data,
            });
        }
    }
}

#[cfg(test)]
mod tests {
    use std::collections::HashMap;
    use std::time::Duration;

    use serde_json::{Map, json};

    use super::model::{DeviceFacts, Loaded, RawAp};
    use super::*;

    /// Records requests; answers like NetworkManager and BlueZ would.
    #[derive(Debug, Default)]
    struct Fake {
        seen: Mutex<Vec<Request>>,
    }

    impl Backend for Fake {
        async fn run(&self, req: Request) -> Vec<Input> {
            let answer = match &req {
                Request::AddAndActivate { attempt, .. } => vec![Input::ProfileCreated {
                    attempt: *attempt,
                    path: "/profile/new".to_owned(),
                }],
                Request::BluetoothOff => {
                    vec![Input::BluetoothWasOn(vec!["/org/bluez/hci0".to_owned()])]
                }
                Request::SetWireless(on) => vec![Input::WirelessEnabled(*on)],
                _ => Vec::new(),
            };
            if let Ok(mut seen) = self.seen.lock() {
                seen.push(req);
            }
            answer
        }
    }

    struct Rig {
        service: NetworkService,
        backend: Arc<Fake>,
        patches: UnboundedReceiver<Map<String, Value>>,
    }

    impl Rig {
        fn new() -> Self {
            let (ptx, patches) = unbounded_channel();
            let sink = Sink::new(move |e| {
                if let Event::Patch { service, data } = e {
                    assert_eq!(service, NAME);
                    let _ = ptx.send(data);
                }
            });
            let backend = Arc::new(Fake::default());
            let service = NetworkService::spawn(
                &tokio::runtime::Handle::current(),
                sink,
                Arc::clone(&backend),
            );
            Self {
                service,
                backend,
                patches,
            }
        }

        fn feed(&self, input: Input) {
            assert!(self.service.tx.send(input).is_ok());
        }

        /// Patches until one carries `key`; that patch.
        async fn patch_with(&mut self, key: &str) -> Map<String, Value> {
            loop {
                let next = tokio::time::timeout(Duration::from_secs(5), self.patches.recv()).await;
                match next {
                    Ok(Some(p)) if p.contains_key(key) => return p,
                    Ok(Some(_)) => {}
                    _ => panic!("no patch with `{key}`"),
                }
            }
        }

        fn requests(&self) -> Vec<Request> {
            self.backend
                .seen
                .lock()
                .map(|s| s.clone())
                .unwrap_or_default()
        }
    }

    fn loaded() -> Loaded {
        let ap = |ssid: &str, strength, rsn| RawAp {
            ssid: ssid.to_owned(),
            strength,
            flags: u32::from(rsn != 0),
            wpa: 0,
            rsn,
        };
        Loaded {
            wireless_enabled: true,
            primary_type: "802-11-wireless".to_owned(),
            device: Some(DeviceFacts {
                path: "/dev/wifi".to_owned(),
                state: 100,
                active_ap: Some("/ap/1".to_owned()),
                last_scan: 1,
            }),
            aps: vec![
                ("/ap/1".to_owned(), ap("Home", 70, 0x188)),
                ("/ap/2".to_owned(), ap("Office", 50, 0x188)),
            ],
            known: HashMap::from([("Home".to_owned(), "/profile/home".to_owned())]),
        }
    }

    #[tokio::test]
    async fn starts_empty_then_publishes_what_networkmanager_says() {
        let mut rig = Rig::new();
        assert_eq!(rig.service.name(), "network");
        let empty = rig.service.state();
        assert_eq!(empty["wifiAvailable"], false);
        assert_eq!(empty["connected"], false);
        assert_eq!(empty["networks"], json!([]));

        rig.feed(Input::Loaded(Box::new(loaded())));
        let patch = rig.patch_with("networks").await;
        assert_eq!(patch["ssid"], "Home");
        assert_eq!(patch["wifiAvailable"], true);
        assert_eq!(patch["networks"][0]["connected"], true);
        assert_eq!(rig.service.state()["strength"], 70);

        // NetworkManager goes away: the state says so, nothing breaks.
        rig.feed(Input::Gone);
        let patch = rig.patch_with("wifiAvailable").await;
        assert_eq!(patch["wifiAvailable"], false);
        assert_eq!(patch["connected"], false);
        rig.feed(Input::Loaded(Box::new(loaded())));
        assert_eq!(rig.patch_with("connected").await["connected"], true);
    }

    #[tokio::test]
    async fn failed_connect_reports_and_removes_the_new_profile() {
        let mut rig = Rig::new();
        rig.feed(Input::Loaded(Box::new(loaded())));
        rig.patch_with("networks").await;

        let reply = rig
            .service
            .call("connectTo", &[json!("Office"), json!("wrong")]);
        assert_eq!(reply, Ok(Value::Null));
        let patch = rig.patch_with("connectingSsid").await;
        assert_eq!(patch["connectingSsid"], "Office");

        rig.feed(Input::DeviceState {
            new: 50,
            old: 40,
            reason: 0,
        });
        rig.feed(Input::DeviceState {
            new: 60,
            old: 50,
            reason: 0,
        });
        let patch = rig.patch_with("lastError").await;
        assert_eq!(
            patch["lastError"],
            "Couldn't connect to Office. Wrong password?"
        );
        assert_eq!(patch["connectingSsid"], "");

        // Cleanup reaches the backend in order.
        for _ in 0..200 {
            if rig.requests().len() >= 3 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        let seen = rig.requests();
        assert!(matches!(seen[0], Request::AddAndActivate { .. }));
        assert!(seen.contains(&Request::Disconnect {
            device: "/dev/wifi".to_owned()
        }));
        assert!(seen.contains(&Request::DeleteProfile("/profile/new".to_owned())));
    }

    #[tokio::test]
    async fn airplane_mode_round_trip() {
        let mut rig = Rig::new();
        rig.feed(Input::Loaded(Box::new(loaded())));
        rig.patch_with("networks").await;

        assert!(rig.service.call("setAirplaneMode", &[json!(true)]).is_ok());
        let patch = rig.patch_with("airplaneMode").await;
        assert_eq!(patch["airplaneMode"], true);
        assert_eq!(patch["wifiEnabled"], false);
        assert_eq!(patch["connected"], false);
        for _ in 0..200 {
            if rig.requests().len() >= 2 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        // Let the Bluetooth answer reach the machine before leaving.
        tokio::time::sleep(Duration::from_millis(20)).await;

        assert!(rig.service.call("setAirplaneMode", &[json!(false)]).is_ok());
        let patch = rig.patch_with("airplaneMode").await;
        assert_eq!(patch["airplaneMode"], false);
        assert_eq!(patch["wifiEnabled"], true);
        for _ in 0..200 {
            if rig.requests().len() >= 4 {
                break;
            }
            tokio::time::sleep(Duration::from_millis(5)).await;
        }
        assert_eq!(
            rig.requests(),
            [
                Request::SetWireless(false),
                Request::BluetoothOff,
                Request::SetWireless(true),
                Request::BluetoothOn(vec!["/org/bluez/hci0".to_owned()]),
            ]
        );
    }

    #[tokio::test]
    async fn calls_validate_and_never_block() {
        let rig = Rig::new();
        assert!(matches!(
            rig.service.call("nope", &[]),
            Err(CallError::UnknownMethod(_))
        ));
        assert!(matches!(
            rig.service.call("setWifiEnabled", &[json!("yes")]),
            Err(CallError::BadArgs(_))
        ));
        assert!(matches!(
            rig.service.call("connectTo", &[]),
            Err(CallError::BadArgs(_))
        ));
        // Without NetworkManager these are accepted and simply do nothing.
        assert_eq!(rig.service.call("rescan", &[]), Ok(Value::Null));
        assert_eq!(rig.service.call("disconnect", &[]), Ok(Value::Null));
        assert_eq!(
            rig.service.call("connectTo", &[json!("X"), Value::Null]),
            Ok(Value::Null)
        );
    }
}
