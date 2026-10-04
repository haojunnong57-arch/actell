// SPDX-License-Identifier: GPL-3.0-only
//! Authenticated DisplayService negotiation and discard-only media consumer.
//! No pixels/audio are decoded, logged, persisted, or sent outside the tunnel.
use crate::{Cause, Error, Stage, Stream, bounded, error};
use idevice::{
    RsdService,
    core_device::{
        DisplayServiceClient, TouchEvent, TouchPoint, UniversalHidServiceClient,
        display_stream::{
            RtpPacket, build_start_audio_parameters, build_start_video_parameters,
            negotiation::{
                CallInfoBlob, ScreenVideoStream, build_screen_audio_offer,
                build_screen_video_offer, parse_screen_video_answer,
            },
        },
    },
    rsd::RsdHandshake,
    tcp::handle::AdapterHandle,
};
use std::{
    sync::{
        Arc,
        atomic::{AtomicBool, Ordering},
    },
    time::Duration,
};
use tokio::{sync::watch, task::JoinHandle, time::Instant};
const AUDIO_PORT: u16 = 50000;
const VIDEO_PORT: u16 = 50001;
const FRESHNESS: Duration = Duration::from_secs(2);
#[derive(Default)]
struct Drains(Vec<JoinHandle<()>>);
impl Drop for Drains {
    fn drop(&mut self) {
        for task in &self.0 {
            task.abort();
        }
    }
}
pub(crate) struct Media {
    _audio: DisplayServiceClient<Stream>,
    _video: DisplayServiceClient<Stream>,
    hid: UniversalHidServiceClient<Stream>,
    _drains: Drains,
    latest: watch::Receiver<Option<Instant>>,
    healthy: Arc<AtomicBool>,
}
impl Media {
    pub async fn start(
        adapter: &mut AdapterHandle,
        handshake: &mut RsdHandshake,
    ) -> Result<Self, Error> {
        let fail = || error(Stage::Media, Cause::Protocol);
        let mut drains = Drains::default();
        let healthy = Arc::new(AtomicBool::new(true));
        let (latest_tx, mut latest) = watch::channel(None);
        let audio_udp = bounded(Stage::Media, adapter.bind_udp(0)).await?;
        let video_udp = bounded(Stage::Media, adapter.bind_udp(0)).await?;
        let receiver = adapter.host_ip().to_string();
        let sender = adapter.peer_ip().to_string();
        // Compatibility profile captured in Device Hub's protocol source, not
        // evidence of iOS27 compatibility or the actual controller model/OS.
        let info = CallInfoBlob {
            call_id: 0,
            client_version: 1,
            device_type: "Mac17,7".into(),
            framework_version: "2205.3.1".into(),
            os_version: "25F71".into(),
            device_name: None,
            audio_device_uid: None,
        };
        let session = uuid::Uuid::new_v4();
        let offer =
            build_screen_audio_offer(&uuid::Uuid::new_v4().to_string().to_uppercase(), &info)
                .map_err(|_| fail())?;
        let mut audio = bounded(
            Stage::Media,
            DisplayServiceClient::connect_rsd(adapter, handshake),
        )
        .await?;
        bounded(
            Stage::Media,
            audio.start_media_stream(build_start_audio_parameters(
                &receiver,
                audio_udp.local_port(),
                &sender,
                AUDIO_PORT,
                offer,
                140,
                session,
            )),
        )
        .await?;
        let audio_health = healthy.clone();
        drains.0.push(tokio::spawn(async move {
            while let Ok(datagram) = audio_udp.recv().await {
                drop(datagram);
            }
            audio_health.store(false, Ordering::SeqCst);
        }));
        let ssrc =
            u32::from_be_bytes(uuid::Uuid::new_v4().as_bytes()[..4].try_into().unwrap()).max(1);
        let offer = build_screen_video_offer(
            &uuid::Uuid::new_v4().to_string().to_uppercase(),
            &info,
            ssrc,
        )
        .map_err(|_| fail())?;
        // Independent reply-bearing connection for video; retain both until close.
        let mut video = bounded(
            Stage::Media,
            DisplayServiceClient::connect_rsd(adapter, handshake),
        )
        .await?;
        let answer = bounded(
            Stage::Media,
            video.start_media_stream(build_start_video_parameters(
                &receiver,
                video_udp.local_port(),
                &sender,
                VIDEO_PORT,
                offer,
                140,
                1,
                session,
            )),
        )
        .await?;
        let negotiated = parse_screen_video_answer(extract_answer(&answer)?).map_err(|_| fail())?;
        let video_health = healthy.clone();
        drains.0.push(tokio::spawn(async move {
            let mut sequence = None;
            let mut feedback = tokio::time::interval(Duration::from_secs(1));
            feedback.set_missed_tick_behavior(tokio::time::MissedTickBehavior::Skip);
            loop {
                tokio::select! {
                    packet=video_udp.recv()=>match packet {
                        Ok(p)=>if accept_rtp(&p.data,p.source_port,negotiated,&mut sequence)
                            && latest_tx.send(Some(Instant::now())).is_err() { break; },
                        Err(_)=>break,
                    },
                    _=feedback.tick()=> {
                        // RFC3550 empty receiver report, no invented loss stats.
                        let mut rr=vec![0x80,201,0,1];rr.extend_from_slice(&ssrc.to_be_bytes());
                        if video_udp.send_to(VIDEO_PORT,rr).await.is_err() { break; }
                    }
                }
            }
            video_health.store(false, Ordering::SeqCst);
            let _ = latest_tx.send(None);
        }));
        bounded(Stage::Media, latest.changed()).await?;
        if latest.borrow().is_none() || !healthy.load(Ordering::SeqCst) {
            return Err(fail());
        }
        let hid = bounded(
            Stage::Input,
            UniversalHidServiceClient::connect_rsd(adapter, handshake),
        )
        .await?;
        Ok(Self {
            _audio: audio,
            _video: video,
            hid,
            _drains: drains,
            latest,
            healthy,
        })
    }
    pub async fn tap(&mut self, x: u16, y: u16) -> Result<(), Error> {
        if !self.healthy.load(Ordering::SeqCst) || !fresh(*self.latest.borrow(), Instant::now()) {
            return Err(error(Stage::Input, Cause::MediaInactive));
        }
        let point = TouchPoint::new(x, y);
        if bounded(
            Stage::Input,
            self.hid.send_touch(TouchEvent::Down(point), None),
        )
        .await
        .is_err()
        {
            // An incomplete write may still have reached the device. Do not
            // replay Down or claim cancellation succeeded; close the generation.
            return Err(error(Stage::Input, Cause::DeliveryUncertain));
        }
        tokio::time::sleep(Duration::from_millis(50)).await;
        bounded(
            Stage::Input,
            self.hid.send_touch(TouchEvent::Up(point), None),
        )
        .await
        .map_err(|_| error(Stage::Input, Cause::DeliveryUncertain))
    }
}
fn fresh(last: Option<Instant>, now: Instant) -> bool {
    last.is_some_and(|t| now.saturating_duration_since(t) < FRESHNESS)
}
fn accept_rtp(data: &[u8], port: u16, expected: ScreenVideoStream, last: &mut Option<u16>) -> bool {
    if port != VIDEO_PORT {
        return false;
    }
    let Ok(p) = RtpPacket::parse_checked(data) else {
        return false;
    };
    if p.ssrc != expected.ssrc || p.payload_type != expected.payload_type || p.payload.is_empty() {
        return false;
    }
    if last.is_some_and(|v| {
        let d = p.sequence_number.wrapping_sub(v);
        d == 0 || d >= 0x8000
    }) {
        return false;
    }
    *last = Some(p.sequence_number);
    true
}
fn extract_answer(value: &plist::Value) -> Result<&[u8], Error> {
    fn visit<'a>(
        v: &'a plist::Value,
        depth: usize,
        count: &mut usize,
        answer: &mut Option<&'a [u8]>,
    ) {
        if depth > 4 {
            return;
        }
        match v {
            plist::Value::Dictionary(d) => {
                for (k, v) in d {
                    if k == "negotiatorAnswer" {
                        *count += 1;
                        *answer = v.as_data();
                    } else {
                        visit(v, depth + 1, count, answer);
                    }
                }
            }
            plist::Value::Array(a) => {
                for v in a {
                    visit(v, depth + 1, count, answer);
                }
            }
            _ => {}
        }
    }
    let mut count = 0;
    let mut answer = None;
    visit(value, 0, &mut count, &mut answer);
    answer
        .filter(|v| count == 1 && !v.is_empty() && v.len() <= 1024 * 1024)
        .ok_or(error(Stage::Media, Cause::Protocol))
}
#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn stale_media_never_opens_input() {
        let now = Instant::now();
        assert!(!fresh(None, now));
        assert!(!fresh(Some(now - FRESHNESS), now));
        assert!(fresh(Some(now), now));
    }
    #[test]
    fn media_requires_negotiated_identity_source_and_new_sequence() {
        let expected = ScreenVideoStream {
            payload_type: 100,
            ssrc: 7,
        };
        let mut last = None;
        let mut p = vec![0x80, 100, 255, 255, 0, 0, 0, 0, 0, 0, 0, 7, 1];
        assert!(!accept_rtp(&p, 123, expected, &mut last));
        assert!(accept_rtp(&p, VIDEO_PORT, expected, &mut last));
        assert!(!accept_rtp(&p, VIDEO_PORT, expected, &mut last));
        p[2] = 0;
        p[3] = 0;
        assert!(accept_rtp(&p, VIDEO_PORT, expected, &mut last));
        p[3] = 1;
        p[11] = 8;
        assert!(!accept_rtp(&p, VIDEO_PORT, expected, &mut last));
        p[11] = 7;
        p[1] = 101;
        assert!(!accept_rtp(&p, VIDEO_PORT, expected, &mut last));
        assert!(!accept_rtp(&[0; 11], VIDEO_PORT, expected, &mut last));
    }
    #[test]
    fn answer_must_be_unique_bounded_data() {
        let mut d = plist::Dictionary::new();
        d.insert("negotiatorAnswer".into(), plist::Value::Data(vec![1]));
        let one = plist::Value::Dictionary(d);
        assert_eq!(extract_answer(&one).unwrap(), &[1]);
        assert!(extract_answer(&plist::Value::Array(vec![one.clone(), one])).is_err());
        assert!(extract_answer(&plist::Value::Data(vec![])).is_err());
    }
    #[tokio::test]
    async fn dropping_drains_aborts_consumers() {
        let task = tokio::spawn(std::future::pending::<()>());
        let handle = task.abort_handle();
        drop(Drains(vec![task]));
        tokio::task::yield_now().await;
        assert!(handle.is_finished());
    }
}
