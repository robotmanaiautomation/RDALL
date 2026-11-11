//! RDALL connection timing. No peer identifiers, credentials or screen contents.
//! Kept std-only so the timing/concurrency logic can be tested without native codecs.
use std::{
    sync::{
        atomic::{AtomicU64, Ordering},
        Arc, Mutex,
    },
    time::{Duration, Instant},
};

static NEXT_ATTEMPT: AtomicU64 = AtomicU64::new(1);
const REPORT_INTERVAL: Duration = Duration::from_secs(5);

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord)]
pub enum Phase {
    Transport,
    Authentication,
    AwaitVideo,
    Decode,
    Streaming,
    Closed,
}

impl Phase {
    fn name(self) -> &'static str {
        match self {
            Self::Transport => "transport",
            Self::Authentication => "authentication",
            Self::AwaitVideo => "await_video",
            Self::Decode => "decode",
            Self::Streaming => "streaming",
            Self::Closed => "closed",
        }
    }
}

#[derive(Default)]
struct Sample {
    payload_bytes: u64,
    video_messages: u64,
    decoded_frames: u64,
    decode_errors: u64,
    queue_overflows: u64,
    max_queue: usize,
    decode_us: u128,
    max_decode_us: u128,
}

struct State {
    phase: Phase,
    phase_since: Instant,
    last_report: Instant,
    last_video: Option<Instant>,
    sample: Sample,
}

#[derive(Clone)]
pub struct ConnectionDiagnostics {
    attempt: u64,
    started: Instant,
    state: Arc<Mutex<State>>,
    sink: Arc<dyn Fn(&str) + Send + Sync>,
}

impl ConnectionDiagnostics {
    pub fn new(sink: impl Fn(&str) + Send + Sync + 'static) -> Self {
        Self::at(Instant::now(), sink)
    }

    fn at(now: Instant, sink: impl Fn(&str) + Send + Sync + 'static) -> Self {
        let result = Self {
            attempt: NEXT_ATTEMPT.fetch_add(1, Ordering::Relaxed),
            started: now,
            state: Arc::new(Mutex::new(State {
                phase: Phase::Transport,
                phase_since: now,
                last_report: now,
                last_video: None,
                sample: Sample::default(),
            })),
            sink: Arc::new(sink),
        };
        result.event("attempt_started", "");
        result
    }

    // Only pass fixed event names and metadata generated from enums/numbers here.
    // Never pass upstream error text, peer addresses, tokens or user input.
    pub fn event(&self, event: &'static str, fields: &str) {
        self.emit(Instant::now(), event, fields);
    }

    fn emit(&self, now: Instant, event: &'static str, fields: &str) {
        (self.sink)(&format!(
            "RDALL_DIAG {{\"attempt\":{},\"elapsed_ms\":{},\"event\":\"{}\"{}}}",
            self.attempt,
            now.saturating_duration_since(self.started).as_millis(),
            event,
            fields,
        ));
    }

    pub fn advance(&self, phase: Phase) {
        self.advance_at(phase, Instant::now());
    }

    fn advance_at(&self, phase: Phase, now: Instant) {
        let fields = {
            let mut state = self.state.lock().unwrap();
            if phase <= state.phase {
                return;
            }
            let fields = format!(
                ",\"from\":\"{}\",\"to\":\"{}\",\"phase_ms\":{}",
                state.phase.name(),
                phase.name(),
                now.saturating_duration_since(state.phase_since).as_millis(),
            );
            state.phase = phase;
            state.phase_since = now;
            fields
        };
        self.emit(now, "phase", &fields);
    }

    pub fn received(&self, bytes: usize) {
        self.state.lock().unwrap().sample.payload_bytes += bytes as u64;
    }

    pub fn video_received(&self) {
        let mut state = self.state.lock().unwrap();
        state.sample.video_messages += 1;
        state.last_video = Some(Instant::now());
    }

    pub fn queue(&self, depth: usize, overflow: bool) {
        let mut state = self.state.lock().unwrap();
        state.sample.max_queue = state.sample.max_queue.max(depth);
        state.sample.queue_overflows += u64::from(overflow);
    }

    pub fn decoded(&self, duration: Duration) {
        {
            let mut state = self.state.lock().unwrap();
            state.sample.decoded_frames += 1;
            state.sample.decode_us += duration.as_micros();
            state.sample.max_decode_us = state.sample.max_decode_us.max(duration.as_micros());
        }
        self.advance(Phase::Streaming);
    }

    pub fn decode_error(&self) {
        self.state.lock().unwrap().sample.decode_errors += 1;
    }

    /// Runs independently of the IO loop, so even a stuck transport/login wait is visible.
    pub fn report(&self) {
        self.report_at(Instant::now());
    }

    fn report_at(&self, now: Instant) {
        self.report_sample_at(now, false);
    }

    pub fn finish(&self) {
        let now = Instant::now();
        self.report_sample_at(now, true);
        self.advance_at(Phase::Closed, now);
    }

    fn report_sample_at(&self, now: Instant, force: bool) {
        let fields = {
            let mut state = self.state.lock().unwrap();
            let interval = now.saturating_duration_since(state.last_report);
            if state.phase == Phase::Closed || (!force && interval < REPORT_INTERVAL) {
                return;
            }
            let sample = std::mem::take(&mut state.sample);
            state.last_report = now;
            let interval_ms = interval.as_millis().max(1);
            let video_age = state
                .last_video
                .map(|t| now.saturating_duration_since(t).as_millis().to_string())
                .unwrap_or_else(|| "null".to_owned());
            format!(
                ",\"phase\":\"{}\",\"phase_ms\":{},\"interval_ms\":{},\"payload_bytes\":{},\"payload_kbps\":{:.2},\"video_messages\":{},\"decoded_frames\":{},\"decoded_fps\":{:.2},\"decode_mean_ms\":{:.2},\"decode_max_ms\":{:.2},\"decode_errors\":{},\"queue_max\":{},\"queue_overflows\":{},\"last_video_age_ms\":{}",
                state.phase.name(), now.saturating_duration_since(state.phase_since).as_millis(),
                interval_ms, sample.payload_bytes, sample.payload_bytes as f64 * 8.0 / interval_ms as f64,
                sample.video_messages, sample.decoded_frames,
                sample.decoded_frames as f64 * 1000.0 / interval_ms as f64,
                sample.decode_us as f64 / sample.decoded_frames.max(1) as f64 / 1000.0,
                sample.max_decode_us as f64 / 1000.0, sample.decode_errors,
                sample.max_queue, sample.queue_overflows, video_age,
            )
        };
        self.emit(now, "sample", &fields);
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn capture() -> (ConnectionDiagnostics, Arc<Mutex<Vec<String>>>, Instant) {
        let lines = Arc::new(Mutex::new(Vec::new()));
        let output = lines.clone();
        let now = Instant::now();
        (
            ConnectionDiagnostics::at(now, move |line| {
                output.lock().unwrap().push(line.to_owned())
            }),
            lines,
            now,
        )
    }

    #[test]
    fn phases_measure_time_and_never_regress_on_repeated_authentication() {
        let (d, lines, now) = capture();
        d.advance_at(Phase::Authentication, now + Duration::from_millis(2300));
        d.advance_at(Phase::AwaitVideo, now + Duration::from_millis(7300));
        d.advance_at(Phase::Authentication, now + Duration::from_millis(8000));
        let lines = lines.lock().unwrap();
        assert_eq!(lines.len(), 3);
        assert!(lines[1].contains("\"phase_ms\":2300"));
        assert!(lines[2].contains("\"phase_ms\":5000"));
    }

    #[test]
    fn stalled_transport_reports_without_any_packets() {
        let (d, lines, now) = capture();
        d.report_at(now + Duration::from_secs(4));
        assert_eq!(lines.lock().unwrap().len(), 1);
        d.report_at(now + Duration::from_secs(5));
        let lines = lines.lock().unwrap();
        assert!(lines[1].contains("\"phase\":\"transport\",\"phase_ms\":5000"));
        assert!(lines[1].contains("\"last_video_age_ms\":null"));
    }

    #[test]
    fn short_failed_attempt_flushes_counters_before_closing() {
        let (d, lines, _) = capture();
        d.decode_error();
        d.received(123);
        d.finish();
        d.finish();
        let lines = lines.lock().unwrap();
        assert_eq!(lines.len(), 3);
        assert!(lines[1].contains("\"decode_errors\":1"));
        assert!(lines[1].contains("\"payload_bytes\":123"));
        assert!(lines[2].contains("\"to\":\"closed\""));
    }

    #[test]
    fn samples_measure_actual_interval_and_reset_counters() {
        let (d, lines, now) = capture();
        d.received(1_000_000);
        d.video_received();
        d.decoded(Duration::from_millis(20));
        d.decoded(Duration::from_millis(40));
        d.queue(8, true);
        d.decode_error();
        d.report_at(now + Duration::from_secs(10));
        d.report_at(now + Duration::from_secs(15));
        let lines = lines.lock().unwrap();
        let sample = &lines[2];
        assert!(sample.contains("\"payload_kbps\":800.00"));
        assert!(sample.contains("\"decoded_fps\":0.20"));
        assert!(sample.contains("\"decode_mean_ms\":30.00,\"decode_max_ms\":40.00"));
        assert!(sample.contains("\"queue_max\":8,\"queue_overflows\":1"));
        assert!(lines[3].contains("\"payload_bytes\":0"));
        assert!(lines[3].contains("\"decoded_frames\":0"));
    }

    #[test]
    fn decoder_thread_shares_only_its_own_attempt_and_closed_attempts_stop_reporting() {
        let (d, lines, now) = capture();
        let (other, other_lines, _) = capture();
        assert_ne!(d.attempt, other.attempt);
        let worker = d.clone();
        std::thread::spawn(move || worker.decoded(Duration::from_millis(8)))
            .join()
            .unwrap();
        d.report_at(now + Duration::from_secs(5));
        assert!(lines
            .lock()
            .unwrap()
            .last()
            .unwrap()
            .contains("\"decoded_frames\":1"));
        assert_eq!(other_lines.lock().unwrap().len(), 1);
        d.advance_at(Phase::Closed, now + Duration::from_secs(6));
        let count = lines.lock().unwrap().len();
        d.report_at(now + Duration::from_secs(20));
        assert_eq!(lines.lock().unwrap().len(), count);
    }
}
