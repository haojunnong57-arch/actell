// SPDX-License-Identifier: GPL-3.0-only
//! Real protocol backend for an iOS-hosted controller. All device I/O must be
//! provided by an NCM/S3 connector; this backend does not discover a Mac tunnel or
//! read/write a pairing file. Nothing runs just by linking this static library.
mod media;
mod png;
mod transport;
pub use idevice::remote_pairing::{RpPairingFile, VerifiedPeerIdentity};
use idevice::{
    RemoteXpcClient, RsdService,
    core_device::{ImageFormat, ScreenCaptureServiceClient},
    remote_pairing::{RemotePairingClient, RpPairingSocket, connect_tls_psk_tunnel_native},
    rsd::RsdHandshake,
    services::mobile_image_mounter::ImageMounter,
    tcp::{
        adapter::Adapter,
        handle::{AdapterHandle, StreamHandle},
    },
};
use std::{future::Future, net::Ipv6Addr, time::Duration};
pub use transport::{DialFuture, NcmConnector, Purpose, Stream};
use transport::{Gated, OperationGuard, Owner};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Stage {
    Identity,
    NcmConnect,
    PairVerify,
    TunnelListener,
    TlsTunnel,
    Rsd,
    DeveloperMode,
    DeveloperImage,
    Screenshot,
    Media,
    Input,
    Closed,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Cause {
    Protocol,
    Timeout,
    InvalidParameters,
    MissingService,
    Unprepared,
    MediaInactive,
    DeliveryUncertain,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct Error {
    pub stage: Stage,
    pub cause: Cause,
}
impl std::fmt::Display for Error {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        write!(f, "{:?}/{:?}", self.stage, self.cause)
    }
}
impl std::error::Error for Error {}
fn error(stage: Stage, cause: Cause) -> Error {
    Error { stage, cause }
}
async fn bounded<T, E>(stage: Stage, f: impl Future<Output = Result<T, E>>) -> Result<T, Error> {
    tokio::time::timeout(Duration::from_secs(15), f)
        .await
        .map_err(|_| error(stage, Cause::Timeout))?
        .map_err(|_| error(stage, Cause::Protocol))
}
/// Only already-authorized, in-memory RemotePairing identities. Caller retains
/// original identifier/keys/peer binding. There is no Pair Setup or persistence.
pub struct ExistingIdentity {
    pub controller: RpPairingFile,
    pub peer: VerifiedPeerIdentity,
}
impl ExistingIdentity {
    fn validate(&self) -> Result<(), Error> {
        if self.controller.identifier.is_empty()
            || self.controller.identifier.len() > 256
            || self.controller.e_private_key.verifying_key() != self.controller.e_public_key
            || self.peer.pairing_identifier.is_empty()
            || self.peer.peer.remotepairing_udid.is_empty()
            || self.peer.peer.model.is_empty()
            || self.peer.peer.alt_irk.len() != 16
            || self.controller.alt_irk.as_deref() != Some(self.peer.peer.alt_irk.as_slice())
        {
            return Err(error(Stage::Identity, Cause::InvalidParameters));
        }
        Ok(())
    }
}
#[derive(Clone, Debug, Eq, PartialEq)]
pub struct Service {
    pub name: String,
    pub port: u16,
    pub remote_xpc: bool,
}
pub struct Screenshot {
    pub png: Vec<u8>,
    pub width: u32,
    pub height: u32,
}
/// Transport evidence, explicitly not evidence of visible UIKit effects.
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum TouchDelivery {
    ReportsWrittenVisualEffectUnverified,
}
#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum CloseReport {
    OwnedTransportRevokedRemoteMediaStopUnconfirmed,
}

pub struct Session {
    owner: Owner,
    _control: Option<RemotePairingClient<RpPairingSocket<Gated>>>,
    adapter: AdapterHandle,
    handshake: RsdHandshake,
    _rsd_control: Option<RemoteXpcClient<StreamHandle>>,
    prepared: bool,
    media: Option<media::Media>,
    valid: bool,
}
impl Session {
    /// No fallback: a rejected verify never triggers Pair Setup, lockdown record
    /// lookup, native TCP, QUIC, VPN configuration or any Mac service.
    pub async fn connect(
        connector: &impl NcmConnector,
        identity: &mut ExistingIdentity,
    ) -> Result<Self, Error> {
        identity.validate()?;
        let owner = Owner::default();
        let stream = bounded(Stage::NcmConnect, connector.connect(Purpose::PairVerify)).await?;
        let mut control = RemotePairingClient::new(
            RpPairingSocket::new(Gated::new(stream, owner.0.clone())),
            &identity.controller.identifier,
        );
        bounded(Stage::PairVerify, control.attempt_pair_verify()).await?;
        bounded(
            Stage::PairVerify,
            control.validate_pairing(&mut identity.controller, &identity.peer),
        )
        .await?;
        let port = bounded(Stage::TunnelListener, control.create_tcp_listener()).await?;
        if port == 0 {
            return Err(error(Stage::TunnelListener, Cause::InvalidParameters));
        }
        let stream = bounded(
            Stage::NcmConnect,
            connector.connect(Purpose::NegotiatedTunnel { port }),
        )
        .await?;
        let tunnel = bounded(
            Stage::TlsTunnel,
            connect_tls_psk_tunnel_native(
                Gated::new(stream, owner.0.clone()),
                control.encryption_key(),
            ),
        )
        .await?;
        let (client, server, rsd_port, mss) = tunnel_parameters(&tunnel.info)?;
        let mut raw = Adapter::new(Box::new(tunnel.into_inner()), client.into(), server.into());
        raw.set_mss(mss);
        let mut adapter = raw.to_async_handle();
        let rsd_stream = bounded(Stage::Rsd, adapter.connect(rsd_port)).await?;
        let (handshake, rsd_control) =
            bounded(Stage::Rsd, RsdHandshake::new_retained(rsd_stream)).await?;
        verify_rsd_identity(&handshake, &identity.peer)?;
        Ok(Self {
            owner,
            _control: Some(control),
            adapter,
            handshake,
            _rsd_control: Some(rsd_control),
            prepared: false,
            media: None,
            valid: true,
        })
    }
    fn check(&self) -> Result<(), Error> {
        if self.valid && !self.owner.0.is_closed() {
            Ok(())
        } else {
            Err(error(Stage::Closed, Cause::Unprepared))
        }
    }
    pub fn services(&self) -> Result<Vec<Service>, Error> {
        self.check()?;
        let mut services: Vec<_> = self
            .handshake
            .services
            .iter()
            .map(|(n, s)| Service {
                name: n.clone(),
                port: s.port,
                remote_xpc: s.uses_remote_xpc,
            })
            .collect();
        services.sort_by(|a, b| a.name.cmp(&b.name));
        Ok(services)
    }
    /// Read-only checks, never download/personalize/mount a DDI or toggle mode.
    pub async fn check_developer_readiness(&mut self) -> Result<(), Error> {
        self.check()?;
        self.prepared = false;
        let mut mounter = bounded(
            Stage::DeveloperImage,
            ImageMounter::connect_rsd(&mut self.adapter, &mut self.handshake),
        )
        .await?;
        if !bounded(Stage::DeveloperMode, mounter.query_developer_mode_status()).await? {
            return Err(error(Stage::DeveloperMode, Cause::Unprepared));
        }
        if !bounded(
            Stage::DeveloperImage,
            mounter.image_is_present("Personalized"),
        )
        .await?
        {
            return Err(error(Stage::DeveloperImage, Cause::Unprepared));
        }
        self.prepared = true;
        Ok(())
    }
    fn require(&self, name: &str, stage: Stage) -> Result<(), Error> {
        self.check()?;
        if !self.prepared {
            return Err(error(stage, Cause::Unprepared));
        }
        if self
            .handshake
            .services
            .get(name)
            .is_none_or(|s| s.port == 0 || !s.uses_remote_xpc)
        {
            return Err(error(stage, Cause::MissingService));
        }
        Ok(())
    }
    /// Actual CoreDevice request. Nothing is logged/saved/uploaded; bytes belong
    /// solely to caller. Caller must obtain screen-access consent before calling.
    pub async fn screenshot(&mut self) -> Result<Screenshot, Error> {
        self.require(
            "com.apple.coredevice.screencaptureservice",
            Stage::Screenshot,
        )?;
        let mut client = bounded(
            Stage::Screenshot,
            ScreenCaptureServiceClient::connect_rsd(&mut self.adapter, &mut self.handshake),
        )
        .await?;
        let png = bounded(
            Stage::Screenshot,
            client.take_screenshot(None, ImageFormat::Png),
        )
        .await?;
        let dimensions =
            png::validate_png(&png).map_err(|_| error(Stage::Screenshot, Cause::Protocol))?;
        Ok(Screenshot {
            png,
            width: dimensions.width,
            height: dimensions.height,
        })
    }
    /// Starts real DisplayService audio/video negotiation and drains packets in
    /// the owned tunnel. No HEVC decode. Explicit media consent is a caller duty.
    /// Failure invalidates the entire generation; no uncertain state is reused.
    pub async fn start_touch_media(&mut self) -> Result<(), Error> {
        self.require("com.apple.coredevice.displayservice", Stage::Media)?;
        self.require("com.apple.coredevice.hid.universalhidservice", Stage::Input)?;
        if self.media.is_some() {
            return Err(error(Stage::Media, Cause::InvalidParameters));
        }
        let mut guard = OperationGuard(Some(self.owner.0.clone()));
        match media::Media::start(&mut self.adapter, &mut self.handshake).await {
            Ok(media) => {
                self.media = Some(media);
                guard.0 = None;
                Ok(())
            }
            Err(e) => {
                self.invalidate();
                Err(e)
            }
        }
    }
    /// No replay on timeout/uncertain release. Valid media must be flowing in
    /// this same authenticated generation; result never claims a visible tap.
    pub async fn tap(&mut self, x: u16, y: u16) -> Result<TouchDelivery, Error> {
        self.check()?;
        let media = self
            .media
            .as_mut()
            .ok_or(error(Stage::Input, Cause::MediaInactive))?;
        let mut guard = OperationGuard(Some(self.owner.0.clone()));
        match media.tap(x, y).await {
            Ok(()) => {
                guard.0 = None;
                Ok(TouchDelivery::ReportsWrittenVisualEffectUnverified)
            }
            Err(e) => {
                self.invalidate();
                Err(e)
            }
        }
    }
    fn invalidate(&mut self) {
        self.valid = false;
        self.prepared = false;
        self.media.take();
        self.owner.0.close();
        self._rsd_control.take();
        self._control.take();
    }
    /// No stopAll: that could affect another controller. Remote media teardown
    /// after owned-tunnel close is UNVERIFIED and must be checked on hardware.
    pub async fn close(mut self) -> CloseReport {
        self.invalidate();
        let _ = self.adapter.close().await;
        CloseReport::OwnedTransportRevokedRemoteMediaStopUnconfirmed
    }
}
impl Drop for Session {
    fn drop(&mut self) {
        self.invalidate();
    }
}
fn tunnel_parameters(
    info: &idevice::tunnel::TunnelInfo,
) -> Result<(Ipv6Addr, Ipv6Addr, u16, usize), Error> {
    let fail = || error(Stage::TlsTunnel, Cause::InvalidParameters);
    let client: Ipv6Addr = info.client_address.parse().map_err(|_| fail())?;
    let server: Ipv6Addr = info.server_address.parse().map_err(|_| fail())?;
    if [client, server].iter().any(|a| {
        a.is_unspecified() || a.is_loopback() || a.is_multicast() || a.to_ipv4_mapped().is_some()
    }) || client == server
        || info.mtu < 1280
        || info.server_rsd_port == 0
    {
        return Err(fail());
    }
    Ok((
        client,
        server,
        info.server_rsd_port,
        usize::from(info.mtu) - 60,
    ))
}
fn verify_rsd_identity(h: &RsdHandshake, peer: &VerifiedPeerIdentity) -> Result<(), Error> {
    if h.protocol_version == 0
        || h.properties
            .get("UniqueDeviceID")
            .and_then(plist::Value::as_string)
            != Some(peer.peer.remotepairing_udid.as_str())
        || h.properties
            .get("ProductType")
            .and_then(plist::Value::as_string)
            != Some(peer.peer.model.as_str())
    {
        return Err(error(Stage::Rsd, Cause::InvalidParameters));
    }
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::sync::{
        Mutex,
        atomic::{AtomicUsize, Ordering},
    };
    use tokio::io::{AsyncReadExt, AsyncWriteExt, DuplexStream};
    fn fixture_identity() -> ExistingIdentity {
        // Public deterministic test-only seeds. Never persisted or used with a device.
        let key = ed25519_dalek::SigningKey::from_bytes(&[0x42; 32]);
        ExistingIdentity {
            controller: RpPairingFile {
                e_public_key: key.verifying_key(),
                e_private_key: key,
                identifier: "SYNTHETIC-CONTROLLER".into(),
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
                    name: "test".into(),
                    remotepairing_udid: "SYNTHETIC-UDID".into(),
                },
            },
        }
    }
    struct Connector {
        stream: Mutex<Option<DuplexStream>>,
        calls: AtomicUsize,
    }
    impl NcmConnector for Connector {
        fn connect(&self, purpose: Purpose) -> DialFuture<'_> {
            self.calls.fetch_add(1, Ordering::SeqCst);
            assert_eq!(
                purpose,
                Purpose::PairVerify,
                "failure must not dial a tunnel/fallback"
            );
            Box::pin(async move {
                Ok(Box::new(self.stream.lock().unwrap().take().expect("no retry")) as Stream)
            })
        }
    }
    async fn read_frame(peer: &mut DuplexStream) -> String {
        let mut magic = [0; 9];
        peer.read_exact(&mut magic).await.unwrap();
        assert_eq!(&magic, b"RPPairing");
        let size = peer.read_u16().await.unwrap();
        let mut b = vec![0; size as usize];
        peer.read_exact(&mut b).await.unwrap();
        String::from_utf8(b).unwrap()
    }
    #[tokio::test]
    async fn real_verify_m1_rejection_closes_without_pair_setup_or_tunnel() {
        let (stream, mut peer) = tokio::io::duplex(8192);
        let connector = Connector {
            stream: Mutex::new(Some(stream)),
            calls: AtomicUsize::new(0),
        };
        let mock = tokio::spawn(async move {
            let greeting = read_frame(&mut peer).await;
            assert!(greeting.contains("attemptPairVerify"));
            assert!(!greeting.contains("pairingData"));
            let body=br#"{"originatedBy":"device","sequenceNumber":0,"message":{"plain":{"_0":{"response":{"_1":{"handshake":{"_0":{"wireProtocolVersion":19}}}}}}}}"#;
            peer.write_all(b"RPPairing").await.unwrap();
            peer.write_u16(body.len() as u16).await.unwrap();
            peer.write_all(body).await.unwrap();
            let m1 = read_frame(&mut peer).await;
            assert!(m1.contains("verifyManualPairing"));
            assert!(m1.contains("startNewSession"));
            assert!(!m1.contains("setupManualPairing"));
            // Adversarial peer sends a truncated second envelope, not fake success.
            peer.write_all(b"BAD").await.unwrap();
            peer.shutdown().await.unwrap();
            let mut rest = Vec::new();
            peer.read_to_end(&mut rest).await.unwrap();
            assert!(rest.is_empty());
        });
        let result = Session::connect(&connector, &mut fixture_identity()).await;
        assert!(matches!(
            result,
            Err(Error {
                stage: Stage::PairVerify,
                ..
            })
        ));
        mock.await.unwrap();
        assert_eq!(connector.calls.load(Ordering::SeqCst), 1);
    }
    #[tokio::test]
    async fn invalid_identity_never_dials() {
        let connector = Connector {
            stream: Mutex::new(None),
            calls: AtomicUsize::new(0),
        };
        let mut id = fixture_identity();
        id.controller.alt_irk = None;
        assert!(matches!(
            Session::connect(&connector, &mut id).await,
            Err(Error {
                stage: Stage::Identity,
                ..
            })
        ));
        assert_eq!(connector.calls.load(Ordering::SeqCst), 0);
    }
    #[test]
    fn tunnel_uses_negotiated_ipv6_and_port_only() {
        let mut info = idevice::tunnel::TunnelInfo {
            client_address: "fdab::9".into(),
            server_address: "fdab::8".into(),
            netmask: String::new(),
            mtu: 1280,
            server_rsd_port: 43210,
        };
        let (_, _, port, mss) = tunnel_parameters(&info).unwrap();
        assert_eq!((port, mss), (43210, 1220));
        info.server_rsd_port = 0;
        assert!(tunnel_parameters(&info).is_err());
        info.server_rsd_port = 43210;
        for ip in [
            "192.168.7.2",
            "::ffff:192.168.7.2",
            "::1",
            "::",
            "ff02::fb",
            "fdab::9",
        ] {
            info.server_address = ip.into();
            assert!(tunnel_parameters(&info).is_err());
        }
    }
    #[test]
    fn rsd_metadata_must_match_verified_peer() {
        let id = fixture_identity();
        let mut h = RsdHandshake {
            services: Default::default(),
            properties: Default::default(),
            protocol_version: 1,
            uuid: String::new(),
        };
        assert!(verify_rsd_identity(&h, &id.peer).is_err());
        h.properties.insert(
            "UniqueDeviceID".into(),
            plist::Value::String(id.peer.peer.remotepairing_udid.clone()),
        );
        h.properties.insert(
            "ProductType".into(),
            plist::Value::String(id.peer.peer.model.clone()),
        );
        assert!(verify_rsd_identity(&h, &id.peer).is_ok());
        h.protocol_version = 0;
        assert!(verify_rsd_identity(&h, &id.peer).is_err());
    }
    #[test]
    fn canceled_operation_invalidates_transport_generation() {
        let owner = Owner::default();
        drop(OperationGuard(Some(owner.0.clone())));
        assert!(owner.0.is_closed());
    }
}
